using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Text;

namespace TeamsRecorder.Windows.Application;

/// <summary>Persists the local Teams pairing credential without exposing its plaintext to callers.</summary>
public interface ITeamsPairingTokenStore
{
    Task<string?> ReadAsync(CancellationToken cancellationToken = default);
    Task WriteAsync(string token, CancellationToken cancellationToken = default);
    Task ClearAsync(CancellationToken cancellationToken = default);
}

/// <summary>DPAPI-backed, per-user token store. The token is only ever written as an encrypted byte blob.</summary>
public sealed class WindowsDpapiTeamsPairingTokenStore : ITeamsPairingTokenStore
{
    private const string Entropy = "TeamsRecorder.Windows.TeamsThirdPartyApi.v1";
    private readonly string path;

    public WindowsDpapiTeamsPairingTokenStore(string? path = null) => this.path = path ?? Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TeamsRecorder", "teams-pairing-token.bin");

    public async Task<string?> ReadAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!File.Exists(path)) return null;
        var protectedBytes = await File.ReadAllBytesAsync(path, cancellationToken).ConfigureAwait(false);
        if (protectedBytes.Length == 0) return null;
        return Encoding.UTF8.GetString(Dpapi.Unprotect(protectedBytes, Encoding.UTF8.GetBytes(Entropy)));
    }

    public async Task WriteAsync(string token, CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(token);
        cancellationToken.ThrowIfCancellationRequested();
        var directory = Path.GetDirectoryName(path) ?? throw new InvalidOperationException("The token path must have a directory.");
        Directory.CreateDirectory(directory);
        var protectedBytes = Dpapi.Protect(Encoding.UTF8.GetBytes(token), Encoding.UTF8.GetBytes(Entropy));
        var temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            await File.WriteAllBytesAsync(temporary, protectedBytes, cancellationToken).ConfigureAwait(false);
            File.Move(temporary, path, true);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    public Task ClearAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (File.Exists(path)) File.Delete(path);
        return Task.CompletedTask;
    }

    private static class Dpapi
    {
        [StructLayout(LayoutKind.Sequential)] private struct DataBlob { public int Length; public IntPtr Data; }
        [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool CryptProtectData(ref DataBlob input, string? description, ref DataBlob entropy, IntPtr reserved, IntPtr prompt, int flags, out DataBlob output);
        [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool CryptUnprotectData(ref DataBlob input, IntPtr description, ref DataBlob entropy, IntPtr reserved, IntPtr prompt, int flags, out DataBlob output);
        [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
        private const int CryptprotectUiForbidden = 0x1;

        public static byte[] Protect(byte[] input, byte[] entropy) => Transform(input, entropy, protect: true);
        public static byte[] Unprotect(byte[] input, byte[] entropy) => Transform(input, entropy, protect: false);
        private static byte[] Transform(byte[] input, byte[] entropy, bool protect)
        {
            if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Teams pairing storage requires Windows DPAPI.");
            var inputHandle = GCHandle.Alloc(input, GCHandleType.Pinned);
            var entropyHandle = GCHandle.Alloc(entropy, GCHandleType.Pinned);
            try
            {
                var source = new DataBlob { Length = input.Length, Data = inputHandle.AddrOfPinnedObject() };
                var optionalEntropy = new DataBlob { Length = entropy.Length, Data = entropyHandle.AddrOfPinnedObject() };
                var success = protect
                    ? CryptProtectData(ref source, null, ref optionalEntropy, IntPtr.Zero, IntPtr.Zero, CryptprotectUiForbidden, out var result)
                    : CryptUnprotectData(ref source, IntPtr.Zero, ref optionalEntropy, IntPtr.Zero, IntPtr.Zero, CryptprotectUiForbidden, out result);
                if (!success) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Windows DPAPI could not protect the Teams pairing credential.");
                try { var output = new byte[result.Length]; Marshal.Copy(result.Data, output, 0, output.Length); return output; }
                finally { if (result.Data != IntPtr.Zero) LocalFree(result.Data); }
            }
            finally { entropyHandle.Free(); inputHandle.Free(); }
        }
    }
}

/// <summary>Small transport seam so WebSocket lifecycle behaviour can be tested without a Teams client.</summary>
public interface ITeamsWebSocketConnection : IAsyncDisposable
{
    WebSocketState State { get; }
    Task ConnectAsync(Uri endpoint, CancellationToken cancellationToken);
    Task SendAsync(ReadOnlyMemory<byte> message, CancellationToken cancellationToken);
    Task<WebSocketReceiveResult> ReceiveAsync(Memory<byte> buffer, CancellationToken cancellationToken);
    Task CloseAsync(CancellationToken cancellationToken);
}

public sealed class ClientWebSocketTeamsConnection : ITeamsWebSocketConnection
{
    private readonly ClientWebSocket socket = new();
    public WebSocketState State => socket.State;
    public Task ConnectAsync(Uri endpoint, CancellationToken cancellationToken) => socket.ConnectAsync(endpoint, cancellationToken);
    public Task SendAsync(ReadOnlyMemory<byte> message, CancellationToken cancellationToken) => socket.SendAsync(message, WebSocketMessageType.Text, true, cancellationToken).AsTask();
    public async Task<WebSocketReceiveResult> ReceiveAsync(Memory<byte> buffer, CancellationToken cancellationToken)
    {
        var result = await socket.ReceiveAsync(buffer, cancellationToken).ConfigureAwait(false);
        return new WebSocketReceiveResult(result.Count, result.MessageType, result.EndOfMessage);
    }
    public async Task CloseAsync(CancellationToken cancellationToken)
    {
        if (socket.State is WebSocketState.Open or WebSocketState.CloseReceived) await socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, "Recorder stopping", cancellationToken).ConfigureAwait(false);
    }
    public ValueTask DisposeAsync() { socket.Dispose(); return ValueTask.CompletedTask; }
}

/// <summary>
/// Cancellable Teams Third-party API client. A connection generation is captured by each receive
/// loop so a delayed old socket cannot publish events after stop/reconnect. It never logs the token.
/// </summary>
public sealed class TeamsThirdPartyApiClient : ITeamsThirdPartyApiClient, IAsyncDisposable
{
    // WebSocket messages are assembled across receive frames. Keep this bounded so a peer cannot
    // make the recorder retain an unbounded payload before it reaches the JSON decoder.
    private const int MaxInboundMessageBytes = 64 * 1024;
    private readonly object gate = new();
    private readonly TeamsThirdPartyApiIdentity identity;
    private readonly ITeamsPairingTokenStore tokens;
    private readonly Func<ITeamsWebSocketConnection> connectionFactory;
    private readonly TimeSpan reconnectDelay;
    private readonly SemaphoreSlim sendGate = new(1, 1);
    private CancellationTokenSource? lifetime;
    private Task? runTask;
    private ITeamsWebSocketConnection? connection;
    private long generation;
    private int requestId;

    public TeamsThirdPartyApiClient(
        TeamsThirdPartyApiIdentity identity,
        ITeamsPairingTokenStore tokens,
        Func<ITeamsWebSocketConnection>? connectionFactory = null,
        TimeSpan? reconnectDelay = null)
    {
        this.identity = identity ?? throw new ArgumentNullException(nameof(identity));
        this.tokens = tokens ?? throw new ArgumentNullException(nameof(tokens));
        this.connectionFactory = connectionFactory ?? (() => new ClientWebSocketTeamsConnection());
        this.reconnectDelay = reconnectDelay ?? TimeSpan.FromSeconds(2);
        if (this.reconnectDelay < TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(reconnectDelay));
    }

    public event EventHandler<TeamsThirdPartyApiEvent>? EventReceived;
    public event EventHandler<string?>? ConnectionChanged;

    public Task StartAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        lock (gate)
        {
            if (lifetime is not null) return Task.CompletedTask;
            lifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            runTask = RunAsync(++generation, lifetime.Token);
        }
        return Task.CompletedTask;
    }

    public async Task StopAsync(CancellationToken cancellationToken = default)
    {
        Task? running; ITeamsWebSocketConnection? active; CancellationTokenSource? source;
        lock (gate) { source = lifetime; lifetime = null; running = runTask; runTask = null; active = connection; connection = null; ++generation; }
        if (source is null) return;
        source.Cancel();
        try { if (active is not null) await active.CloseAsync(cancellationToken).ConfigureAwait(false); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch { }
        try { if (running is not null) await running.WaitAsync(cancellationToken).ConfigureAwait(false); }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { }
        finally { source.Dispose(); }
    }

    public Task RequestPairingAsync(CancellationToken cancellationToken = default) => SendCommandAsync(TeamsThirdPartyApiAction.Pair, cancellationToken);

    private async Task SendCommandAsync(TeamsThirdPartyApiAction action, CancellationToken cancellationToken)
    {
        ITeamsWebSocketConnection? active;
        lock (gate) active = connection;
        if (active is null || active.State != WebSocketState.Open) throw new InvalidOperationException("Teams Third-party API is not connected.");
        var json = TeamsThirdPartyApi.CreateCommand(action, Interlocked.Increment(ref requestId));
        await sendGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { await active.SendAsync(Encoding.UTF8.GetBytes(json), cancellationToken).ConfigureAwait(false); }
        finally { sendGate.Release(); }
    }

    private async Task RunAsync(long runGeneration, CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            ITeamsWebSocketConnection? current = null;
            try
            {
                current = connectionFactory();
                var token = await tokens.ReadAsync(cancellationToken).ConfigureAwait(false);
                await current.ConnectAsync(TeamsThirdPartyApi.CreateEndpoint(identity, token), cancellationToken).ConfigureAwait(false);
                if (!TrySetConnection(runGeneration, current)) { await current.DisposeAsync().ConfigureAwait(false); return; }
                PublishConnection(runGeneration, null);
                // The Teams Third-party API was only verified to send meeting presence as a
                // push event. Do not poll query-state: some Teams builds reject it and the
                // proven Meet Now flow is to wait for the next authenticated push.
                var credentialWasRefreshed = await ReceiveLoopAsync(
                    runGeneration,
                    current,
                    !string.IsNullOrWhiteSpace(token),
                    cancellationToken).ConfigureAwait(false);
                // tokenRefresh is a normal, authenticated credential rotation.  Reporting it
                // as a connection failure makes the coordinator discard its trusted meeting
                // state and disable automatic recording just before this loop reconnects with
                // the replacement token.
                if (!credentialWasRefreshed && !cancellationToken.IsCancellationRequested && IsCurrent(runGeneration, current))
                    PublishConnection(runGeneration, "Teams API connection unavailable");
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { return; }
            catch (Exception)
            {
                // Deliberately publish only a generic message: websocket implementations may include URLs.
                PublishConnection(runGeneration, "Teams API connection unavailable");
            }
            finally
            {
                ClearConnection(runGeneration, current);
                if (current is not null) await current.DisposeAsync().ConfigureAwait(false);
            }
            try { await Task.Delay(reconnectDelay, cancellationToken).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
        }
    }

    private async Task<bool> ReceiveLoopAsync(
        long runGeneration,
        ITeamsWebSocketConnection current,
        bool isPairingAuthenticated,
        CancellationToken cancellationToken)
    {
        var buffer = new byte[8192];
        using var payload = new MemoryStream();
        while (!cancellationToken.IsCancellationRequested && IsCurrent(runGeneration, current))
        {
            var result = await current.ReceiveAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (result.MessageType == WebSocketMessageType.Close) return false;
            if (result.MessageType != WebSocketMessageType.Text) continue;
            if (IsInboundMessageTooLarge(payload.Length, result.Count))
            {
                // Treat this connection as unusable rather than retaining or decoding a partial,
                // oversized message. Returning lets the owning run loop dispose and reconnect it.
                await current.CloseAsync(cancellationToken).ConfigureAwait(false);
                return false;
            }
            payload.Write(buffer, 0, result.Count);
            if (!result.EndOfMessage) continue;
            var json = Encoding.UTF8.GetString(payload.GetBuffer(), 0, (int)payload.Length);
            payload.SetLength(0);
            var @event = TeamsThirdPartyApi.Decode(json);
            if (@event is TeamsThirdPartyApiEvent.TokenRefresh(var token))
            {
                await tokens.WriteAsync(token, cancellationToken).ConfigureAwait(false);
                // A credential refresh is transport-private; do not pass its plaintext to UI subscribers.
                // Reconnect so the next socket proves it was opened with the newly issued token.
                // State received on this unauthenticated pairing socket must not drive recording.
                return true;
            }
            if (@event is TeamsThirdPartyApiEvent.Error(_, var message) && IsInvalidPairingToken(message))
            {
                // A revoked/expired token otherwise causes every reconnect to fail before
                // Teams can advertise that this instance is eligible to pair again.
                await tokens.ClearAsync(cancellationToken).ConfigureAwait(false);
                return false;
            }
            if (IsCurrent(runGeneration, current))
            {
                if (@event is TeamsThirdPartyApiEvent.MeetingUpdate update)
                    @event = update with { IsPairingAuthenticated = isPairingAuthenticated };
                EventReceived?.Invoke(this, @event);
            }
        }
        return false;
    }

    private bool TrySetConnection(long expectedGeneration, ITeamsWebSocketConnection value) { lock (gate) { if (generation != expectedGeneration || lifetime is null) return false; connection = value; return true; } }
    private static bool IsInboundMessageTooLarge(long accumulatedBytes, int receivedBytes) =>
        receivedBytes < 0 || accumulatedBytes > MaxInboundMessageBytes || receivedBytes > MaxInboundMessageBytes - accumulatedBytes;
    private static bool IsInvalidPairingToken(string message) =>
        message.Contains("invalid token", StringComparison.OrdinalIgnoreCase);
    private void ClearConnection(long expectedGeneration, ITeamsWebSocketConnection? value) { lock (gate) { if (generation == expectedGeneration && ReferenceEquals(connection, value)) connection = null; } }
    private bool IsCurrent(long expectedGeneration, ITeamsWebSocketConnection value) { lock (gate) return generation == expectedGeneration && ReferenceEquals(connection, value) && lifetime is not null; }
    private void PublishConnection(long expectedGeneration, string? error) { if (IsCurrentGeneration(expectedGeneration)) ConnectionChanged?.Invoke(this, error); }
    private bool IsCurrentGeneration(long expectedGeneration) { lock (gate) return generation == expectedGeneration && lifetime is not null; }
    public async ValueTask DisposeAsync() { await StopAsync().ConfigureAwait(false); sendGate.Dispose(); }
}
