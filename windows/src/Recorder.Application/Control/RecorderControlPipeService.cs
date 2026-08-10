using System.Collections.Concurrent;
using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Runtime.InteropServices;

namespace TeamsRecorder.Windows.Application.Control;

// This file guards construction and use of the transport with
// OperatingSystem.IsWindows().  The application project is intentionally a
// portable net10.0 library, so the analyser cannot infer that guard across the
// server/client object boundary.
#pragma warning disable CA1416

/// <summary>
/// The fixed production endpoint.  The endpoint itself is intentionally not a
/// secret; the Windows DACL, current-user option, local-peer check, and request
/// validation are the authorization boundary.
/// </summary>
public sealed class RecorderControlEndpoint
{
    public const string ProductionPipeName = "TeamsRecorder.Control.v1";

    public RecorderControlEndpoint(string pipeName)
    {
        if (string.IsNullOrWhiteSpace(pipeName) || pipeName.Length > 128 ||
            pipeName.Any(character => !(char.IsAsciiLetterOrDigit(character) || character is '.' or '-' or '_')))
        {
            throw new ArgumentException("The named-pipe endpoint is invalid.", nameof(pipeName));
        }

        PipeName = pipeName;
    }

    public string PipeName { get; }

    public static RecorderControlEndpoint Production { get; } = new(ProductionPipeName);
}

/// <summary>
/// The only seam the WinUI lifecycle owner needs to implement.  The control
/// runtime serializes calls into this object, but the implementation must still
/// marshal back to its UI/lifecycle dispatcher where that owner requires it.
/// It must honour cancellation so a dead UI cannot indefinitely retain the
/// lifecycle gate after the pipe client has timed out.
/// </summary>
public interface IRecorderControlLifecycleOwner
{
    Task<RecorderControlStatus> GetStatusAsync(CancellationToken cancellationToken);

    Task<RecorderControlActionResult> StartAsync(CancellationToken cancellationToken);

    Task<RecorderControlActionResult> StopAsync(CancellationToken cancellationToken);

    Task<RecorderControlActionResult> SetAutomaticModeAsync(bool enabled, CancellationToken cancellationToken) =>
        Task.FromResult(RecorderControlActionResult.Unsupported());

    Task<RecorderControlActionResult> SetMicrophoneMutedAsync(bool muted, CancellationToken cancellationToken) =>
        Task.FromResult(RecorderControlActionResult.Unsupported());
}

public enum RecorderControlActionDisposition
{
    Accepted,
    NoOp,
    Rejected,
}

/// <summary>
/// An action outcome carries only a bounded, catalogue-backed error code; it
/// intentionally cannot carry exception text or a user-derived diagnostic.
/// </summary>
public sealed record RecorderControlActionResult(
    RecorderControlActionDisposition Disposition,
    RecorderControlErrorCode? ErrorCode = null)
{
    public static RecorderControlActionResult Accepted() => new(RecorderControlActionDisposition.Accepted);
    public static RecorderControlActionResult NoOp() => new(RecorderControlActionDisposition.NoOp);
    public static RecorderControlActionResult Rejected(RecorderControlErrorCode error) =>
        new(RecorderControlActionDisposition.Rejected, error);
    public static RecorderControlActionResult Unsupported() => Rejected(RecorderControlErrorCode.UnsupportedCommand);

    public void Validate()
    {
        if ((Disposition == RecorderControlActionDisposition.Rejected) != ErrorCode.HasValue)
        {
            throw new InvalidOperationException("Recorder control action result is invalid.");
        }
    }
}

/// <summary>
/// Activates the named-pipe transport around one lifecycle owner.  This type is
/// deliberately independent of RecordingViewModel so the eventual WinUI
/// adapter can be created on the UI thread without exposing that object over
/// IPC.
/// </summary>
public sealed class RecorderControlServerRuntime : IAsyncDisposable, IDisposable
{
    private readonly RecorderControlPipeServer server;

    public RecorderControlServerRuntime(
        IRecorderControlLifecycleOwner lifecycleOwner,
        RecorderControlEndpoint? endpoint = null,
        TimeSpan? requestTimeout = null)
    {
        ArgumentNullException.ThrowIfNull(lifecycleOwner);
        server = new RecorderControlPipeServer(
            endpoint ?? RecorderControlEndpoint.Production,
            new RecorderControlRequestDispatcher(lifecycleOwner, requestTimeout ?? RecorderControlPipeServer.DefaultRequestTimeout),
            requestTimeout ?? RecorderControlPipeServer.DefaultRequestTimeout);
    }

    public bool IsRunning => server.IsRunning;

    public void Start() => server.Start();

    public Task StopAsync() => server.StopAsync();

    public void Dispose() => server.Dispose();

    public ValueTask DisposeAsync() => server.DisposeAsync();
}

/// <summary>
/// Windows-only pipe server.  It uses a protected DACL containing only the
/// current user SID, a client-side PipeOptions.CurrentUserOnly verification,
/// and a local client process-ID query.  The DACL is the authoritative
/// other-user SID check; a remote connection cannot satisfy the local PID
/// query and is closed before a byte of control traffic is read.
/// </summary>
public sealed class RecorderControlPipeServer : IAsyncDisposable, IDisposable
{
    public static readonly TimeSpan DefaultRequestTimeout = TimeSpan.FromSeconds(5);
    private const int MaximumConcurrentClients = 1;

    private readonly RecorderControlEndpoint endpoint;
    private readonly RecorderControlRequestDispatcher dispatcher;
    private readonly TimeSpan requestTimeout;
    private readonly IRecorderControlPeerIdentityVerifier peerIdentityVerifier;
    private readonly SecurityIdentifier currentUserSid;
    private readonly object lifecycleLock = new();
    private readonly ConcurrentDictionary<int, NamedPipeServerStream> connectedClients = new();
    // One same-user request is dispatched at a time through the reusable,
    // protected server instance. Every request also has a bounded deadline.
    private readonly SemaphoreSlim connectedClientCapacity = new(MaximumConcurrentClients, MaximumConcurrentClients);

    private CancellationTokenSource? lifetime;
    private Task? acceptTask;
    private NamedPipeServerStream? pendingAccept;
    private int clientSequence;
    private bool disposed;

    public RecorderControlPipeServer(
        RecorderControlEndpoint endpoint,
        IRecorderControlLifecycleOwner lifecycleOwner,
        TimeSpan? requestTimeout = null,
        IRecorderControlPeerIdentityVerifier? peerIdentityVerifier = null)
        : this(
            endpoint,
            new RecorderControlRequestDispatcher(lifecycleOwner, requestTimeout ?? DefaultRequestTimeout),
            requestTimeout ?? DefaultRequestTimeout,
            peerIdentityVerifier)
    {
    }

    internal RecorderControlPipeServer(
        RecorderControlEndpoint endpoint,
        RecorderControlRequestDispatcher dispatcher,
        TimeSpan requestTimeout,
        IRecorderControlPeerIdentityVerifier? peerIdentityVerifier = null)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Recorder control named pipes require Windows.");
        }

        ArgumentNullException.ThrowIfNull(endpoint);
        ArgumentNullException.ThrowIfNull(dispatcher);
        if (requestTimeout <= TimeSpan.Zero || requestTimeout > TimeSpan.FromSeconds(30))
        {
            throw new ArgumentOutOfRangeException(nameof(requestTimeout));
        }

        this.endpoint = endpoint;
        this.dispatcher = dispatcher;
        this.requestTimeout = requestTimeout;
        this.peerIdentityVerifier = peerIdentityVerifier ?? new WindowsRecorderControlPeerIdentityVerifier();
        currentUserSid = WindowsIdentity.GetCurrent().User
            ?? throw new InvalidOperationException("The current Windows user SID is unavailable.");
    }

    public bool IsRunning
    {
        get
        {
            lock (lifecycleLock)
            {
                return lifetime is not null && !lifetime.IsCancellationRequested;
            }
        }
    }

    public void Start()
    {
        ThrowIfDisposed();
        lock (lifecycleLock)
        {
            if (lifetime is not null && !lifetime.IsCancellationRequested)
            {
                return;
            }

            var nextLifetime = new CancellationTokenSource();
            NamedPipeServerStream? firstPipe = null;
            try
            {
                // Create synchronously so an existing hostile/squatting pipe
                // fails app startup rather than becoming a silent background fault.
                firstPipe = CreateServerPipe(firstInstance: true);
                lifetime = nextLifetime;
                pendingAccept = firstPipe;
                acceptTask = AcceptLoopAsync(firstPipe, nextLifetime);
            }
            catch
            {
                firstPipe?.Dispose();
                nextLifetime.Dispose();
                throw;
            }
        }
    }

    public async Task StopAsync()
    {
        CancellationTokenSource? cancellation;
        Task? accepting;
        NamedPipeServerStream? waiting;
        lock (lifecycleLock)
        {
            cancellation = lifetime;
            lifetime = null;
            accepting = acceptTask;
            acceptTask = null;
            waiting = pendingAccept;
            pendingAccept = null;
        }

        if (cancellation is null)
        {
            return;
        }

        cancellation.Cancel();
        waiting?.Dispose();
        foreach (var client in connectedClients.Values)
        {
            client.Dispose();
        }

        try
        {
            if (accepting is not null)
            {
                await accepting.ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException)
        {
            // Expected while disposing a listener with a pending accept.
        }
        finally
        {
            cancellation.Dispose();
        }
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        StopAsync().GetAwaiter().GetResult();
        dispatcher.Dispose();
    }

    public async ValueTask DisposeAsync()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        await StopAsync().ConfigureAwait(false);
        dispatcher.Dispose();
    }

    private async Task AcceptLoopAsync(NamedPipeServerStream firstPipe, CancellationTokenSource ownerLifetime)
    {
        var cancellationToken = ownerLifetime.Token;
        NamedPipeServerStream? pipe = firstPipe;
        var acceptFaulted = false;
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var capacityReserved = false;
                try
                {
                    if (pipe is null)
                    {
                        try
                        {
                            // Create one protected listener and reuse it across
                            // sequential connections. A replacement created
                            // before the prior client handle disappeared could
                            // inherit an unusable Windows ACL.
                            pipe = CreateServerPipe(firstInstance: true);
                            lock (lifecycleLock)
                            {
                                if (!cancellationToken.IsCancellationRequested)
                                {
                                    pendingAccept = pipe;
                                }
                            }
                        }
                        catch (IOException)
                        {
                            // A just-disconnected kernel handle may remain in
                            // teardown briefly. Do not turn that transient slot
                            // pressure into a permanently dead control service.
                            await Task.Delay(TimeSpan.FromMilliseconds(10), cancellationToken).ConfigureAwait(false);
                            continue;
                        }
                    }

                    await connectedClientCapacity.WaitAsync(cancellationToken).ConfigureAwait(false);
                    capacityReserved = true;
                    await pipe.WaitForConnectionAsync(cancellationToken).ConfigureAwait(false);

                    lock (lifecycleLock)
                    {
                        if (ReferenceEquals(pendingAccept, pipe))
                        {
                            pendingAccept = null;
                        }
                    }

                    var connectedPipe = pipe;
                    var clientId = Interlocked.Increment(ref clientSequence);
                    connectedClients.TryAdd(clientId, connectedPipe);
                    await ProcessClientAndDisposeAsync(clientId, connectedPipe, cancellationToken)
                        .ConfigureAwait(false);
                    // Reuse this exact protected server instance. Recreating
                    // the named pipe before the client process had released
                    // its final handle left the replacement namespace with an
                    // ACL that rejected every later desktop client.
                    capacityReserved = false;
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    break;
                }
                catch (ObjectDisposedException) when (cancellationToken.IsCancellationRequested)
                {
                    break;
                }
                catch (IOException) when (!cancellationToken.IsCancellationRequested)
                {
                    // A client may connect and disconnect while all seven
                    // dispatch slots are occupied, before this loop reaches
                    // WaitForConnectionAsync. Retire that abandoned listener
                    // instance and continue accepting; it is not a server fault.
                    lock (lifecycleLock)
                    {
                        if (ReferenceEquals(pendingAccept, pipe))
                        {
                            pendingAccept = null;
                        }
                    }
                    pipe?.Dispose();
                    pipe = null;
                    await Task.Delay(TimeSpan.FromMilliseconds(10), cancellationToken).ConfigureAwait(false);
                }
                finally
                {
                    if (capacityReserved)
                    {
                        connectedClientCapacity.Release();
                    }
                }
            }
        }
        catch (Exception exception)
        {
            // No exception text is retained or sent through the control protocol.
            // Mark the lifetime faulted so IsRunning is truthful and Start may
            // retry after all old instances have been synchronously closed.
            RecorderControlHealthLog.WriteAcceptFault(exception);
            acceptFaulted = !cancellationToken.IsCancellationRequested;
        }
        finally
        {
            lock (lifecycleLock)
            {
                if (ReferenceEquals(pendingAccept, pipe))
                {
                    pendingAccept = null;
                }
            }
            pipe?.Dispose();
            if (acceptFaulted)
            {
                foreach (var client in connectedClients.Values)
                {
                    client.Dispose();
                }
                ownerLifetime.Cancel();
            }
        }
    }

    private async Task ProcessClientAndDisposeAsync(
        int clientId,
        NamedPipeServerStream pipe,
        CancellationToken serviceCancellation)
    {
        try
        {
            // This is deliberately before frame parsing: peer identity failures
            // never get an oracle response, even for a syntactically valid frame.
            if (!peerIdentityVerifier.IsAuthorized(pipe, currentUserSid))
            {
                RecorderControlHealthLog.WriteEvent("peer-rejected");
                return;
            }

            using var requestCancellation = CancellationTokenSource.CreateLinkedTokenSource(serviceCancellation);
            requestCancellation.CancelAfter(requestTimeout);
            var cancellationToken = requestCancellation.Token;

            RecorderControlRequest request;
            try
            {
                var frame = await RecorderControlPipeFrame.ReadAsync(pipe, cancellationToken).ConfigureAwait(false);
                request = RecorderControlProtocol.DeserializeRequest(frame);
            }
            catch (RecorderControlProtocolException exception) when (
                exception.Error is RecorderControlProtocolError.MalformedFrame or
                    RecorderControlProtocolError.InvalidRequest)
            {
                await TryWriteFailureAsync(pipe, "invalid", RecorderControlErrorCode.MalformedRequest, cancellationToken)
                    .ConfigureAwait(false);
                return;
            }
            catch (RecorderControlProtocolException)
            {
                // Oversized frames are closed without a response so a hostile
                // client cannot use the service as a large-message reflector.
                return;
            }
            catch (OperationCanceledException)
            {
                RecorderControlHealthLog.WriteEvent("request-read-timeout");
                return;
            }
            catch (IOException)
            {
                RecorderControlHealthLog.WriteEvent("request-read-io");
                return;
            }

            var response = await dispatcher.HandleAsync(request, cancellationToken).ConfigureAwait(false);
            await RecorderControlPipeFrame.WriteAsync(
                    pipe,
                    RecorderControlProtocol.SerializeResponse(response),
                    cancellationToken)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            // The caller timed out or the service stopped; no late response.
        }
        catch (IOException)
        {
            // A client disconnect is expected and has no side effects.
            RecorderControlHealthLog.WriteEvent("client-io");
        }
        catch (RecorderControlProtocolException)
        {
            // A response that cannot meet the strict protocol is not sent.
        }
        finally
        {
            connectedClients.TryRemove(clientId, out _);
            try
            {
                if (pipe.IsConnected)
                {
                    pipe.Disconnect();
                }
            }
            catch (IOException)
            {
                // Closing a failed/remote connection has no recovery path.
            }
            connectedClientCapacity.Release();
        }
    }

    private async Task TryWriteFailureAsync(
        NamedPipeServerStream pipe,
        string requestId,
        RecorderControlErrorCode error,
        CancellationToken cancellationToken)
    {
        try
        {
            var response = RecorderControlResponse.Failure(requestId, error);
            await RecorderControlPipeFrame.WriteAsync(
                    pipe,
                    RecorderControlProtocol.SerializeResponse(response),
                    cancellationToken)
                .ConfigureAwait(false);
        }
        catch (IOException)
        {
            // The invalid peer may close first; do not attempt another write.
        }
        catch (OperationCanceledException)
        {
            // The bounded request deadline has elapsed.
        }
    }

    private NamedPipeServerStream CreateServerPipe(bool firstInstance)
    {
        // .NET deliberately rejects supplying PipeOptions.CurrentUserOnly and
        // an explicit PipeSecurity together.  We need an inspectable, exact
        // SID-only DACL, so the server uses that protected DACL plus its
        // impersonated-SID/local-PID proof; the client still sets
        // CurrentUserOnly to verify the server identity and elevation.
        var options = PipeOptions.Asynchronous;
        if (firstInstance)
        {
            options |= PipeOptions.FirstPipeInstance;
        }

        return NamedPipeServerStreamAcl.Create(
            endpoint.PipeName,
            PipeDirection.InOut,
            // The application-level semaphore remains the authoritative bound.
            // MaxAllowed avoids a framework-level instance-count conflict while
            // this exact server stream is disconnected and reused.
            NamedPipeServerStream.MaxAllowedServerInstances,
            PipeTransmissionMode.Byte,
            options,
            RecorderControlProtocol.MaximumFrameBytes,
            RecorderControlProtocol.MaximumFrameBytes,
            RecorderControlPipeSecurityPolicy.CreateForCurrentUser(currentUserSid),
            HandleInheritability.None,
            (PipeAccessRights)0);
    }

    private void ThrowIfDisposed()
    {
        if (disposed)
        {
            throw new ObjectDisposedException(nameof(RecorderControlPipeServer));
        }
    }
}

internal static class RecorderControlHealthLog
{
    private const int MaximumBytes = 16 * 1024;

    public static void WriteAcceptFault(Exception exception)
        => WriteEvent($"accept-fault-{exception.GetType().Name}");

    public static void WriteEvent(string eventName)
    {
        try
        {
            var directory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Teams Recorder");
            Directory.CreateDirectory(directory);
            var logPath = Path.Combine(directory, "control-health.log");
            if (File.Exists(logPath) && new FileInfo(logPath).Length >= MaximumBytes)
            {
                File.Delete(logPath);
            }

            // Deliberately retain only a framework exception type and time.
            // Messages, paths, identities, requests, and command arguments are
            // excluded from this local bounded health breadcrumb.
            File.AppendAllText(
                logPath,
                $"{DateTimeOffset.UtcNow:O} {eventName}{Environment.NewLine}");
        }
        catch
        {
            // Diagnostics must never change recorder or pipe lifecycle.
        }
    }
}

/// <summary>
/// Produces the protected Windows DACL used by the control pipe.  It has one
/// allow rule for exactly the current user SID; it never inherits broad user,
/// administrator, network, or anonymous access.
/// </summary>
public static class RecorderControlPipeSecurityPolicy
{
    public static PipeSecurity CreateForCurrentUser(SecurityIdentifier currentUserSid)
    {
        ArgumentNullException.ThrowIfNull(currentUserSid);
        var security = new PipeSecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new PipeAccessRule(
            currentUserSid,
            // Async clients also request Synchronize. FullControl remains
            // private because the protected DACL contains exactly this one
            // user SID; granting an incomplete right set made the replacement
            // listener reject every client after the first connection.
            PipeAccessRights.FullControl,
            AccessControlType.Allow));
        return security;
    }
}

/// <summary>Peer proof is injectable only to make the security boundary testable.</summary>
public interface IRecorderControlPeerIdentityVerifier
{
    bool IsAuthorized(NamedPipeServerStream pipe, SecurityIdentifier expectedCurrentUserSid);
}

public sealed class WindowsRecorderControlPeerIdentityVerifier : IRecorderControlPeerIdentityVerifier
{
    public bool IsAuthorized(NamedPipeServerStream pipe, SecurityIdentifier expectedCurrentUserSid)
    {
        ArgumentNullException.ThrowIfNull(pipe);
        ArgumentNullException.ThrowIfNull(expectedCurrentUserSid);
        if (!OperatingSystem.IsWindows() || !pipe.IsConnected)
        {
            return false;
        }

        // The protected pipe DACL is evaluated by Windows before this point
        // and contains only expectedCurrentUserSid. Prefer the local PID proof;
        // Windows can transiently refuse that query after reconnecting the
        // same server instance, so accept only a client in this exact local
        // Windows logon session as the bounded fallback.
        return NativePipeIdentity.TryGetLocalClientProcessId(pipe, out _) ||
            NativePipeIdentity.IsSameLocalSession(pipe);
    }
}

internal static partial class NativePipeIdentity
{
    public static bool TryGetLocalClientProcessId(NamedPipeServerStream pipe, out uint processId)
    {
        processId = 0;
        try
        {
            return GetNamedPipeClientProcessId(pipe.SafePipeHandle, out processId) && processId != 0;
        }
        catch (DllNotFoundException)
        {
            return false;
        }
        catch (EntryPointNotFoundException)
        {
            return false;
        }
    }

    public static bool IsSameLocalSession(NamedPipeServerStream pipe)
    {
        return GetNamedPipeClientSessionId(pipe.SafePipeHandle, out var clientSessionId) &&
            ProcessIdToSessionId((uint)Environment.ProcessId, out var serverSessionId) &&
            clientSessionId == serverSessionId;
    }

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetNamedPipeClientProcessId(
        Microsoft.Win32.SafeHandles.SafePipeHandle pipe,
        out uint clientProcessId);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetNamedPipeClientSessionId(
        Microsoft.Win32.SafeHandles.SafePipeHandle pipe,
        out uint clientSessionId);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ProcessIdToSessionId(uint processId, out uint sessionId);
}

/// <summary>All public requests enter one bounded, serialized lifecycle gate.</summary>
public sealed class RecorderControlRequestDispatcher : IDisposable
{
    private readonly IRecorderControlLifecycleOwner lifecycleOwner;
    private readonly SemaphoreSlim lifecycleGate = new(1, 1);
    private readonly TimeSpan requestTimeout;
    private int startInFlight;
    private bool disposed;

    public RecorderControlRequestDispatcher(IRecorderControlLifecycleOwner lifecycleOwner, TimeSpan requestTimeout)
    {
        this.lifecycleOwner = lifecycleOwner ?? throw new ArgumentNullException(nameof(lifecycleOwner));
        this.requestTimeout = requestTimeout;
    }

    public async Task<RecorderControlResponse> HandleAsync(
        RecorderControlRequest request,
        CancellationToken serviceCancellation)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (disposed)
        {
            return RecorderControlResponse.Failure(request.RequestId, RecorderControlErrorCode.ServerStopped);
        }

        if (request.ProtocolVersion != RecorderControlProtocol.CurrentVersion)
        {
            return RecorderControlResponse.Failure(request.RequestId, RecorderControlErrorCode.UnsupportedProtocol);
        }

        if (!IsValidArgument(request))
        {
            return RecorderControlResponse.Failure(request.RequestId, RecorderControlErrorCode.InvalidArgument);
        }

        var ownsStartFlight = request.Command == RecorderControlCommand.Start &&
            Interlocked.CompareExchange(ref startInFlight, 1, 0) == 0;
        if (request.Command == RecorderControlCommand.Start && !ownsStartFlight)
        {
            return RecorderControlResponse.Failure(request.RequestId, RecorderControlErrorCode.Busy);
        }

        using var operationCancellation = CancellationTokenSource.CreateLinkedTokenSource(serviceCancellation);
        operationCancellation.CancelAfter(requestTimeout);
        var cancellationToken = operationCancellation.Token;
        var gateHeld = false;
        try
        {
            await lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
            gateHeld = true;

            if (request.Command == RecorderControlCommand.Status)
            {
                var currentStatusTask = lifecycleOwner.GetStatusAsync(cancellationToken);
                var currentStatus = await AwaitOwnerOperationAsync(currentStatusTask, request, false, cancellationToken).ConfigureAwait(false);
                if (currentStatus is null)
                {
                    gateHeld = false;
                    return RecorderControlResponse.Failure(request.RequestId, RecorderControlErrorCode.TimedOut);
                }
                return RecorderControlResponse.Success(request.RequestId, currentStatus);
            }

            var actionTask = InvokeActionAsync(request, cancellationToken);
            var action = await AwaitOwnerOperationAsync(actionTask, request, ownsStartFlight, cancellationToken).ConfigureAwait(false);
            if (action is null)
            {
                gateHeld = false;
                ownsStartFlight = false;
                return RecorderControlResponse.Failure(request.RequestId, RecorderControlErrorCode.TimedOut);
            }

            action.Validate();
            if (action.Disposition == RecorderControlActionDisposition.Rejected)
            {
                return RecorderControlResponse.Failure(request.RequestId, action.ErrorCode!.Value);
            }

            var statusTask = lifecycleOwner.GetStatusAsync(cancellationToken);
            var status = await AwaitOwnerOperationAsync(statusTask, request, ownsStartFlight, cancellationToken).ConfigureAwait(false);
            if (status is null)
            {
                gateHeld = false;
                ownsStartFlight = false;
                return RecorderControlResponse.Failure(request.RequestId, RecorderControlErrorCode.TimedOut);
            }

            return RecorderControlResponse.Success(request.RequestId, status);
        }
        catch (OperationCanceledException)
        {
            return RecorderControlResponse.Failure(request.RequestId, RecorderControlErrorCode.TimedOut);
        }
        catch
        {
            // Do not expose native/managed exception text, paths, or account data.
            return RecorderControlResponse.Failure(request.RequestId, RecorderControlErrorCode.NotReady);
        }
        finally
        {
            if (gateHeld)
            {
                lifecycleGate.Release();
            }
            if (ownsStartFlight)
            {
                Interlocked.Exchange(ref startInFlight, 0);
            }
        }
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }
        disposed = true;
        lifecycleGate.Dispose();
    }

    private async Task<T?> AwaitOwnerOperationAsync<T>(
        Task<T> operation,
        RecorderControlRequest request,
        bool releaseStartFlightWhenFinished,
        CancellationToken cancellationToken)
        where T : class
    {
        try
        {
            return await operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // Keep the lifecycle semaphore reserved until a non-cooperative
            // owner actually completes.  Returning it now would allow two
            // lifecycle transitions to run concurrently after a timeout.
            _ = ReleaseGateAfterOwnerCompletionAsync(operation, releaseStartFlightWhenFinished);
            return null;
        }
    }

    private async Task ReleaseGateAfterOwnerCompletionAsync<T>(
        Task<T> operation,
        bool releaseStartFlightWhenFinished)
    {
        try
        {
            await operation.ConfigureAwait(false);
        }
        catch
        {
            // The timeout response has already been fixed and privacy-safe.
        }
        finally
        {
            if (releaseStartFlightWhenFinished)
            {
                Interlocked.Exchange(ref startInFlight, 0);
            }
            try
            {
                lifecycleGate.Release();
            }
            catch (ObjectDisposedException)
            {
                // Shutdown has already made the dispatcher unreachable.
            }
        }
    }

    private Task<RecorderControlActionResult> InvokeActionAsync(
        RecorderControlRequest request,
        CancellationToken cancellationToken) => request.Command switch
    {
        RecorderControlCommand.Start => lifecycleOwner.StartAsync(cancellationToken),
        RecorderControlCommand.Stop => lifecycleOwner.StopAsync(cancellationToken),
        RecorderControlCommand.SetAuto => lifecycleOwner.SetAutomaticModeAsync(request.Argument == "on", cancellationToken),
        RecorderControlCommand.SetMic => lifecycleOwner.SetMicrophoneMutedAsync(request.Argument == "mute", cancellationToken),
        _ => Task.FromResult(RecorderControlActionResult.Unsupported()),
    };

    private static bool IsValidArgument(RecorderControlRequest request) => request.Command switch
    {
        RecorderControlCommand.Status or RecorderControlCommand.Start or RecorderControlCommand.Stop => request.Argument is null,
        RecorderControlCommand.SetAuto => request.Argument is "on" or "off",
        RecorderControlCommand.SetMic => request.Argument is "mute" or "unmute",
        _ => false,
    };
}

internal static class RecorderControlPipeFrame
{
    public static async Task<byte[]> ReadAsync(Stream stream, CancellationToken cancellationToken)
    {
        var frame = new byte[RecorderControlProtocol.MaximumFrameBytes];
        var length = 0;
        while (length < frame.Length)
        {
            var count = await stream.ReadAsync(frame.AsMemory(length, frame.Length - length), cancellationToken)
                .ConfigureAwait(false);
            if (count == 0)
            {
                throw new IOException("The control pipe closed before a complete frame.");
            }

            var end = length + count;
            for (var index = length; index < end; index++)
            {
                if (frame[index] == (byte)'\n')
                {
                    var jsonLength = index;
                    var result = new byte[jsonLength];
                    Buffer.BlockCopy(frame, 0, result, 0, jsonLength);
                    return result;
                }
            }

            length = end;
        }

        throw new RecorderControlProtocolException(RecorderControlProtocolError.OversizedFrame);
    }

    public static async Task WriteAsync(Stream stream, byte[] utf8Json, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(utf8Json);
        if (utf8Json.Length >= RecorderControlProtocol.MaximumFrameBytes)
        {
            throw new RecorderControlProtocolException(RecorderControlProtocolError.OversizedFrame);
        }

        var frame = new byte[utf8Json.Length + 1];
        Buffer.BlockCopy(utf8Json, 0, frame, 0, utf8Json.Length);
        frame[^1] = (byte)'\n';
        await stream.WriteAsync(frame, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
    }
}

/// <summary>Current-user-only local client used by the CLI and future WinUI adapters.</summary>
public sealed class RecorderControlPipeClient
{
    private readonly RecorderControlEndpoint endpoint;

    public RecorderControlPipeClient(RecorderControlEndpoint? endpoint = null)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Recorder control named pipes require Windows.");
        }
        this.endpoint = endpoint ?? RecorderControlEndpoint.Production;
    }

    public Task<RecorderControlResponse> SendAsync(
        RecorderControlCommand command,
        string? argument = null,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default) =>
        SendAsync(new RecorderControlRequest(Guid.NewGuid().ToString("N"), command, argument), timeout, cancellationToken);

    public async Task<RecorderControlResponse> SendAsync(
        RecorderControlRequest request,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        request.Validate();
        var effectiveTimeout = timeout ?? RecorderControlPipeServer.DefaultRequestTimeout;
        if (effectiveTimeout <= TimeSpan.Zero || effectiveTimeout > TimeSpan.FromSeconds(30))
        {
            throw new ArgumentOutOfRangeException(nameof(timeout));
        }

        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(effectiveTimeout);
        const int maximumConnectAttempts = 20;
        for (var attempt = 0; attempt < maximumConnectAttempts; attempt++)
        {
            await using var pipe = new NamedPipeClientStream(
                ".",
                endpoint.PipeName,
                PipeDirection.InOut,
                // The server already enforces a protected exact-user DACL,
                // FirstPipeInstance ownership, and same-session peer proof.
                // .NET's redundant client-side CurrentUserOnly check rejects
                // every external-process reconnect after the first use of a
                // reusable server stream on Windows.
                PipeOptions.Asynchronous);
            try
            {
                await pipe.ConnectAsync(deadline.Token).ConfigureAwait(false);
                await RecorderControlPipeFrame.WriteAsync(
                        pipe,
                        RecorderControlProtocol.SerializeRequest(request),
                        deadline.Token)
                    .ConfigureAwait(false);
                var frame = await RecorderControlPipeFrame.ReadAsync(pipe, deadline.Token).ConfigureAwait(false);
                return RecorderControlProtocol.DeserializeResponse(frame);
            }
            catch (IOException) when (attempt < maximumConnectAttempts - 1 && !deadline.IsCancellationRequested)
            {
                // A listener can retire an abandoned kernel instance exactly
                // as this client connects. All protocol commands are absolute
                // or idempotent (start/stop included), so retrying the same
                // bounded request is safe and avoids exposing that pipe race.
                await Task.Delay(TimeSpan.FromMilliseconds(25), deadline.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (deadline.IsCancellationRequested)
            {
                throw new RecorderControlProtocolException(RecorderControlProtocolError.TimedOut);
            }
        }

        throw new RecorderControlProtocolException(RecorderControlProtocolError.TimedOut);
    }
}

#pragma warning restore CA1416
