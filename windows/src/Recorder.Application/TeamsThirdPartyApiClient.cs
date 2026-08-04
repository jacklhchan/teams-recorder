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
    private readonly Dictionary<int, StateQueryRequest> pendingStateQueries = [];
    private TeamsTransportDiagnosticSnapshot transportSnapshot = TeamsTransportDiagnosticSnapshot.Initial;
    private long generation;
    private int requestId;

    private sealed record StateQueryRequest(
        long Generation,
        ITeamsWebSocketConnection Connection,
        int RequestId,
        DateTimeOffset SentAtUtc);

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
    public TeamsTransportDiagnosticSnapshot TransportSnapshot { get { lock (gate) return transportSnapshot; } }

    public Task StartAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        lock (gate)
        {
            if (lifetime is not null) return Task.CompletedTask;
            lifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            var nextGeneration = ++generation;
            transportSnapshot = transportSnapshot with
            {
                Generation = nextGeneration,
                IsRunning = true,
                LastConnectionError = null,
            };
            runTask = RunAsync(nextGeneration, lifetime.Token);
        }
        return Task.CompletedTask;
    }

    public async Task StopAsync(CancellationToken cancellationToken = default)
    {
        Task? running; ITeamsWebSocketConnection? active; CancellationTokenSource? source;
        lock (gate)
        {
            source = lifetime;
            lifetime = null;
            running = runTask;
            runTask = null;
            active = connection;
            connection = null;
            pendingStateQueries.Clear();
            ++generation;
            transportSnapshot = transportSnapshot with
            {
                Generation = generation,
                IsRunning = false,
                IsConnected = false,
            };
        }
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

    public Task RefreshStateAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ITeamsWebSocketConnection? active;
        long activeGeneration;
        lock (gate)
        {
            active = connection;
            activeGeneration = generation;
        }

        // A disconnected client will reconnect on its own. Do not turn a normal reconnect gap
        // into a user-visible failure just because the recording timer requested a refresh.
        return active is null
            ? Task.CompletedTask
            : TryQueryStateAfterReceiveStartsAsync(activeGeneration, active, cancellationToken);
    }

    private async Task<int> SendCommandAsync(TeamsThirdPartyApiAction action, CancellationToken cancellationToken)
    {
        ITeamsWebSocketConnection? active;
        lock (gate) active = connection;
        if (active is null || active.State != WebSocketState.Open) throw new InvalidOperationException("Teams Third-party API is not connected.");
        var nextRequestId = Interlocked.Increment(ref requestId);
        await SendCommandAsync(action, nextRequestId, active, cancellationToken).ConfigureAwait(false);
        return nextRequestId;
    }

    private async Task SendCommandAsync(
        TeamsThirdPartyApiAction action,
        int commandRequestId,
        ITeamsWebSocketConnection expectedConnection,
        CancellationToken cancellationToken)
    {
        lock (gate)
        {
            if (!ReferenceEquals(connection, expectedConnection) || expectedConnection.State != WebSocketState.Open)
                throw new InvalidOperationException("Teams Third-party API is not connected.");
        }
        var json = TeamsThirdPartyApi.CreateCommand(action, commandRequestId);
        await sendGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            lock (gate)
            {
                if (!ReferenceEquals(connection, expectedConnection) || expectedConnection.State != WebSocketState.Open)
                    throw new InvalidOperationException("Teams Third-party API is not connected.");
            }
            await expectedConnection.SendAsync(Encoding.UTF8.GetBytes(json), cancellationToken).ConfigureAwait(false);
        }
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
                UpdateTransport(runGeneration, value => value with
                {
                    IsConnected = true,
                    PairingCredentialPresent = !string.IsNullOrWhiteSpace(token),
                    ConnectedAtUtc = DateTimeOffset.UtcNow,
                    LastConnectionError = null,
                });
                PublishConnection(runGeneration, null);
                // Teams can acknowledge an authenticated device without including meetingState.
                // Start receiving first, then issue one best-effort current-state query. This is
                // the same order used by the macOS client: a query failure cannot suppress later
                // push updates or take a paired connection offline.
                var receive = ReceiveLoopAsync(
                    runGeneration,
                    current,
                    !string.IsNullOrWhiteSpace(token),
                    cancellationToken);
                await TryQueryStateAfterReceiveStartsAsync(runGeneration, current, cancellationToken).ConfigureAwait(false);
                await receive.ConfigureAwait(false);
                if (!cancellationToken.IsCancellationRequested && IsCurrent(runGeneration, current))
                    PublishConnection(runGeneration, "Teams API connection unavailable");
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { return; }
            catch (Exception)
            {
                // Deliberately publish only a generic message: websocket implementations may include URLs.
                UpdateTransport(runGeneration, value => value with
                {
                    IsConnected = false,
                    LastConnectionError = "connection unavailable",
                    ReconnectCount = checked(value.ReconnectCount + 1),
                });
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
        var hasPairingCredential = isPairingAuthenticated;
        var automaticPairingRequested = false;
        using var payload = new MemoryStream();
        while (!cancellationToken.IsCancellationRequested && IsCurrent(runGeneration, current))
        {
            var result = await current.ReceiveAsync(buffer, cancellationToken).ConfigureAwait(false);
            UpdateTransport(runGeneration, value => value with { LastReceiveUtc = DateTimeOffset.UtcNow });
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
            UpdateTransportFromEvent(runGeneration, @event);
            if (IsStateQueryReply(runGeneration, current, @event))
            {
                // A state-query acknowledgement/error is informational. In particular, it is
                // not a user-requested pairing outcome and must not change pairing trust.
                continue;
            }
            if (@event is TeamsThirdPartyApiEvent.TokenRefresh(var token))
            {
                await tokens.WriteAsync(token, cancellationToken).ConfigureAwait(false);
                // Teams issues the credential on this active localhost connection.  Retain the
                // socket and refresh its state instead of reconnecting into a race that can
                // suppress the automatic-recording countdown.
                hasPairingCredential = true;
                UpdateTransport(runGeneration, value => value with { PairingCredentialPresent = true });
                // The unauthenticated pairing query is no longer useful once Teams issues a
                // credential on this socket. Replace it with one authenticated state query.
                await TryQueryStateAfterReceiveStartsAsync(
                    runGeneration,
                    current,
                    cancellationToken,
                    allowCredentialRefreshSupersede: true).ConfigureAwait(false);
                continue;
            }
            if (@event is TeamsThirdPartyApiEvent.Error(_, var message) && IsInvalidPairingToken(message))
            {
                // A revoked/expired token otherwise causes every reconnect to fail before
                // Teams can advertise that this instance is eligible to pair again.
                await tokens.ClearAsync(cancellationToken).ConfigureAwait(false);
                return false;
            }
            if (@event is TeamsThirdPartyApiEvent.MeetingUpdate { Update.CanPair: true } &&
                !hasPairingCredential && !automaticPairingRequested)
            {
                // Teams shows its user-approval prompt only after a local client sends a
                // command while a meeting is joined. Request it once; Teams still requires the
                // user to approve that prompt before the device can interact with the meeting.
                automaticPairingRequested = true;
                var pairingRequestId = Interlocked.Increment(ref requestId);
                await SendCommandAsync(TeamsThirdPartyApiAction.Pair, pairingRequestId, current, cancellationToken).ConfigureAwait(false);
            }
            if (IsCurrent(runGeneration, current))
            {
                if (@event is TeamsThirdPartyApiEvent.MeetingUpdate update)
                    @event = update with { IsPairingAuthenticated = hasPairingCredential };
                EventReceived?.Invoke(this, @event);
            }
        }
        return false;
    }

    private async Task TryQueryStateAfterReceiveStartsAsync(
        long runGeneration,
        ITeamsWebSocketConnection current,
        CancellationToken cancellationToken,
        bool allowCredentialRefreshSupersede = false)
    {
        var queryRequestId = Interlocked.Increment(ref requestId);
        if (!TryRegisterStateQuery(
                runGeneration,
                current,
                queryRequestId,
                allowCredentialRefreshSupersede)) return;
        UpdateTransport(runGeneration, value => value with
        {
            LastQuerySentUtc = DateTimeOffset.UtcNow,
            LastQueryOutcome = "pending",
        });
        try
        {
            await SendCommandAsync(TeamsThirdPartyApiAction.QueryState, queryRequestId, current, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            UpdateTransport(runGeneration, value => value with { LastQueryOutcome = "cancelled" });
            ClearStateQuery(runGeneration, current, queryRequestId);
        }
        catch
        {
            // A Teams build may reject query-state. It must never stop reception of subsequent
            // meeting pushes, which are still authoritative when they arrive.
            UpdateTransport(runGeneration, value => value with { LastQueryOutcome = "send-failed" });
            ClearStateQuery(runGeneration, current, queryRequestId);
        }
    }

    private bool TryRegisterStateQuery(
        long expectedGeneration,
        ITeamsWebSocketConnection expectedConnection,
        int queryRequestId,
        bool allowCredentialRefreshSupersede)
    {
        lock (gate)
        {
            if (generation != expectedGeneration || !ReferenceEquals(connection, expectedConnection) || lifetime is null)
                return false;
            var now = DateTimeOffset.UtcNow;
            var expired = pendingStateQueries
                .Where(pair => pair.Value.Generation == expectedGeneration &&
                    ReferenceEquals(pair.Value.Connection, expectedConnection) &&
                    now - pair.Value.SentAtUtc >= TimeSpan.FromSeconds(10))
                .Select(pair => pair.Key)
                .ToArray();
            foreach (var expiredRequestId in expired)
            {
                pendingStateQueries.Remove(expiredRequestId);
                transportSnapshot = transportSnapshot with { LastQueryOutcome = "timed-out" };
            }

            // Normal idle polling never overlaps a query. A credential refresh may issue one
            // authenticated replacement while retaining the old request ID solely so its late
            // acknowledgement/error remains classified as query traffic.
            if (!allowCredentialRefreshSupersede && pendingStateQueries.Values.Any(query =>
                    query.Generation == expectedGeneration &&
                    ReferenceEquals(query.Connection, expectedConnection)))
                return false;
            if (pendingStateQueries.Count >= 8) return false;
            return pendingStateQueries.TryAdd(queryRequestId, new StateQueryRequest(
                expectedGeneration,
                expectedConnection,
                queryRequestId,
                now));
        }
    }

    private bool IsStateQueryReply(long expectedGeneration, ITeamsWebSocketConnection expectedConnection, TeamsThirdPartyApiEvent @event)
    {
        var responseId = @event switch
        {
            TeamsThirdPartyApiEvent.Response(var requestId, _) => requestId,
            TeamsThirdPartyApiEvent.Error(var requestId, _) => requestId,
            _ => null,
        };
        if (!responseId.HasValue) return false;
        lock (gate)
        {
            if (!pendingStateQueries.TryGetValue(responseId.Value, out var query) ||
                query.Generation != expectedGeneration ||
                !ReferenceEquals(query.Connection, expectedConnection) ||
                query.RequestId != responseId.Value)
                return false;
            pendingStateQueries.Remove(responseId.Value);
            transportSnapshot = transportSnapshot with
            {
                LastQueryReplyUtc = DateTimeOffset.UtcNow,
                LastQueryOutcome = @event is TeamsThirdPartyApiEvent.Error ? "rejected" : "acknowledged",
            };
            return true;
        }
    }

    private void ClearStateQuery(long expectedGeneration, ITeamsWebSocketConnection expectedConnection, int queryRequestId)
    {
        lock (gate)
        {
            if (pendingStateQueries.TryGetValue(queryRequestId, out var query) &&
                query.Generation == expectedGeneration &&
                ReferenceEquals(query.Connection, expectedConnection))
                pendingStateQueries.Remove(queryRequestId);
        }
    }

    private bool TrySetConnection(long expectedGeneration, ITeamsWebSocketConnection value) { lock (gate) { if (generation != expectedGeneration || lifetime is null) return false; connection = value; return true; } }
    private void UpdateTransport(long expectedGeneration, Func<TeamsTransportDiagnosticSnapshot, TeamsTransportDiagnosticSnapshot> update)
    {
        lock (gate)
        {
            if (generation == expectedGeneration && lifetime is not null)
                transportSnapshot = update(transportSnapshot);
        }
    }

    private void UpdateTransportFromEvent(long expectedGeneration, TeamsThirdPartyApiEvent @event)
    {
        UpdateTransport(expectedGeneration, value => @event switch
        {
            TeamsThirdPartyApiEvent.MeetingUpdate(var update, _) => value with
            {
                LastEventKind = "meetingUpdate",
                LastMeetingUpdateHadState = update.HasMeetingState,
                LastMeetingUpdateHadIsInMeeting = update.HasIsInMeeting,
                LastMeetingUpdateHadIsMuted = update.HasIsMuted,
            },
            TeamsThirdPartyApiEvent.TokenRefresh => value with { LastEventKind = "tokenRefresh" },
            TeamsThirdPartyApiEvent.Response => value with { LastEventKind = "response" },
            TeamsThirdPartyApiEvent.Error => value with { LastEventKind = "error" },
            _ => value with { LastEventKind = "ignored" },
        });
    }
    private static bool IsInboundMessageTooLarge(long accumulatedBytes, int receivedBytes) =>
        receivedBytes < 0 || accumulatedBytes > MaxInboundMessageBytes || receivedBytes > MaxInboundMessageBytes - accumulatedBytes;
    private static bool IsInvalidPairingToken(string message) =>
        message.Contains("invalid token", StringComparison.OrdinalIgnoreCase);
    private void ClearConnection(long expectedGeneration, ITeamsWebSocketConnection? value)
    {
        lock (gate)
        {
            foreach (var queryRequestId in pendingStateQueries
                         .Where(entry => entry.Value.Generation == expectedGeneration &&
                             ReferenceEquals(entry.Value.Connection, value))
                         .Select(entry => entry.Key)
                         .ToArray())
                pendingStateQueries.Remove(queryRequestId);
            if (generation == expectedGeneration && ReferenceEquals(connection, value)) connection = null;
            if (generation == expectedGeneration)
                transportSnapshot = transportSnapshot with { IsConnected = false };
        }
    }
    private bool IsCurrent(long expectedGeneration, ITeamsWebSocketConnection value) { lock (gate) return generation == expectedGeneration && ReferenceEquals(connection, value) && lifetime is not null; }
    private void PublishConnection(long expectedGeneration, string? error) { if (IsCurrentGeneration(expectedGeneration)) ConnectionChanged?.Invoke(this, error); }
    private bool IsCurrentGeneration(long expectedGeneration) { lock (gate) return generation == expectedGeneration && lifetime is not null; }
    public async ValueTask DisposeAsync() { await StopAsync().ConfigureAwait(false); sendGate.Dispose(); }
}
