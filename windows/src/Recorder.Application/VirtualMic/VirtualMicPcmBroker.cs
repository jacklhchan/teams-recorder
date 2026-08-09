using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

namespace TeamsRecorder.Windows.Application.VirtualMic;

// The broker is test-preview-only Windows code. The application project stays
// portable so the analyser cannot infer all guards across pipe boundaries.
#pragma warning disable CA1416

/// <summary>
/// Per-run broker address and unguessable proof. The proof never has a string
/// representation, is not persisted, and is discarded when the broker stops.
/// </summary>
public sealed class VirtualMicPcmBrokerSession
{
    private readonly byte[] capabilityToken;

    private VirtualMicPcmBrokerSession(string pipeName, VirtualMicTrustedEndpointIdentity identity, byte[] capabilityToken)
    {
        PipeName = pipeName;
        Identity = identity;
        this.capabilityToken = capabilityToken;
    }

    public string PipeName { get; }
    public VirtualMicTrustedEndpointIdentity Identity { get; }

    internal ReadOnlySpan<byte> CapabilityToken => capabilityToken;

    public static VirtualMicPcmBrokerSession Create(VirtualMicTrustedEndpointIdentity identity)
    {
        ArgumentNullException.ThrowIfNull(identity);
        if (!identity.IsWellFormed)
        {
            throw new ArgumentException("A broker session requires the exact trusted virtual-microphone identity.", nameof(identity));
        }

        var token = RandomNumberGenerator.GetBytes(VirtualMicPcmProtocol.CapabilityTokenBytes);
        return new(
            $"TeamsRecorder.VirtualMic.Pcm.v1.{Guid.NewGuid():N}",
            identity,
            token);
    }
}

/// <summary>
/// The sole sink seam for the test broker. A production driver integration must
/// add a separately reviewed, bounded kernel transport; this scaffold does not
/// open a device handle or claim to route audio into a .sys driver.
/// </summary>
public interface IVirtualMicPcmSink
{
    Task WriteAsync(VirtualMicPcmFrame frame, CancellationToken cancellationToken);
}

/// <summary>
/// Current-user-only, one-session PCM broker. It is intentionally usable only
/// in a Debug build compiled with the explicit test-preview property.
/// </summary>
public sealed class VirtualMicPcmBroker : IAsyncDisposable, IDisposable
{
    private static readonly TimeSpan HandshakeTimeout = TimeSpan.FromSeconds(5);
    private readonly object gate = new();
    private readonly VirtualMicPcmBrokerSession session;
    private readonly IVirtualMicPcmSink sink;
    private CancellationTokenSource? lifetime;
    private NamedPipeServerStream? pendingPipe;
    private Task? worker;
    private bool disposed;

    public VirtualMicPcmBroker(
        VirtualMicPreviewCapability capability,
        VirtualMicPcmBrokerSession session,
        IVirtualMicPcmSink sink)
    {
        ArgumentNullException.ThrowIfNull(capability);
        ArgumentNullException.ThrowIfNull(session);
        ArgumentNullException.ThrowIfNull(sink);
        if (!VirtualMicPreviewBuildPolicy.IsTestSignedPreviewCompiled)
        {
            throw new InvalidOperationException(VirtualMicPreviewBuildPolicy.ReleaseDisabledReason);
        }

        if (!capability.IsAvailable || string.IsNullOrWhiteSpace(capability.EndpointId) ||
            !string.Equals(capability.EndpointId, session.Identity.EndpointId, StringComparison.Ordinal))
        {
            throw new InvalidOperationException("A broker may start only for the exact available virtual microphone endpoint.");
        }

        this.session = session;
        this.sink = sink;
    }

    public VirtualMicPcmBrokerSession Session => session;

    public bool IsRunning
    {
        get
        {
            lock (gate)
            {
                return lifetime is not null && !lifetime.IsCancellationRequested;
            }
        }
    }

    public void Start()
    {
        ThrowIfDisposed();
        lock (gate)
        {
            if (lifetime is not null && !lifetime.IsCancellationRequested)
            {
                return;
            }

            var nextLifetime = new CancellationTokenSource();
            NamedPipeServerStream? nextPipe = null;
            try
            {
                nextPipe = new NamedPipeServerStream(
                    session.PipeName,
                    PipeDirection.InOut,
                    maxNumberOfServerInstances: 1,
                    PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly | PipeOptions.FirstPipeInstance,
                    VirtualMicPcmProtocol.MaximumPayloadBytes + VirtualMicPcmProtocol.HeaderBytes,
                    VirtualMicPcmProtocol.MaximumPayloadBytes + VirtualMicPcmProtocol.HeaderBytes);
                lifetime = nextLifetime;
                pendingPipe = nextPipe;
                worker = RunAsync(nextPipe, nextLifetime.Token);
            }
            catch
            {
                nextPipe?.Dispose();
                nextLifetime.Dispose();
                throw;
            }
        }
    }

    public void Dispose() => DisposeAsync().AsTask().GetAwaiter().GetResult();

    public async ValueTask DisposeAsync()
    {
        CancellationTokenSource? cancellation;
        NamedPipeServerStream? pipe;
        Task? running;
        lock (gate)
        {
            if (disposed)
            {
                return;
            }

            disposed = true;
            cancellation = lifetime;
            lifetime = null;
            pipe = pendingPipe;
            pendingPipe = null;
            running = worker;
            worker = null;
        }

        cancellation?.Cancel();
        pipe?.Dispose();
        try
        {
            if (running is not null)
            {
                await running.ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException)
        {
            // Expected while shutting down a waiting test-preview listener.
        }
        finally
        {
            cancellation?.Dispose();
        }
    }

    private async Task RunAsync(NamedPipeServerStream pipe, CancellationToken cancellationToken)
    {
        try
        {
            await pipe.WaitForConnectionAsync(cancellationToken).ConfigureAwait(false);
            lock (gate)
            {
                if (ReferenceEquals(pendingPipe, pipe))
                {
                    pendingPipe = null;
                }
            }

            // CurrentUserOnly supplies the Windows access check. A local PID
            // proof closes the remote-pipe case before parsing any bytes.
            if (!VirtualMicPcmBrokerPeer.IsAuthorized(pipe))
            {
                return;
            }

            using var handshakeDeadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            handshakeDeadline.CancelAfter(HandshakeTimeout);
            var hello = await VirtualMicPcmProtocol.ReadAsync(pipe, handshakeDeadline.Token).ConfigureAwait(false);
            if (hello.Kind != VirtualMicPcmMessageKind.Hello ||
                !CryptographicOperations.FixedTimeEquals(hello.Payload.Span, session.CapabilityToken))
            {
                return;
            }

            await VirtualMicPcmProtocol.WriteAsync(
                pipe,
                VirtualMicPcmProtocol.CreateAcknowledgement(),
                handshakeDeadline.Token).ConfigureAwait(false);

            var hasSequence = false;
            ulong lastSequence = 0;
            while (!cancellationToken.IsCancellationRequested)
            {
                var message = await VirtualMicPcmProtocol.ReadAsync(pipe, cancellationToken).ConfigureAwait(false);
                if (message.Kind == VirtualMicPcmMessageKind.Stop)
                {
                    return;
                }

                if (message.Kind != VirtualMicPcmMessageKind.Pcm)
                {
                    return;
                }

                var frame = VirtualMicPcmProtocol.ParsePcm(message);
                if (hasSequence && frame.Sequence <= lastSequence)
                {
                    return;
                }

                hasSequence = true;
                lastSequence = frame.Sequence;
                await sink.WriteAsync(frame, cancellationToken).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // Normal shutdown.
        }
        catch (IOException)
        {
            // Client disconnected; there is no retry or fallback endpoint.
        }
        catch (VirtualMicPcmProtocolException)
        {
            // Invalid input is fail-closed by closing this one session.
        }
        finally
        {
            pipe.Dispose();
        }
    }

    private void ThrowIfDisposed()
    {
        if (disposed)
        {
            throw new ObjectDisposedException(nameof(VirtualMicPcmBroker));
        }
    }
}

/// <summary>Current-user client used only after the app capability handshake.</summary>
public static class VirtualMicPcmBrokerClient
{
    public static async Task<VirtualMicPcmBrokerConnection> ConnectAsync(
        VirtualMicPcmBrokerSession session,
        TimeSpan timeout,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(session);
        if (!VirtualMicPreviewBuildPolicy.IsTestSignedPreviewCompiled)
        {
            throw new InvalidOperationException(VirtualMicPreviewBuildPolicy.ReleaseDisabledReason);
        }

        if (timeout <= TimeSpan.Zero || timeout > TimeSpan.FromSeconds(30))
        {
            throw new ArgumentOutOfRangeException(nameof(timeout));
        }

        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(timeout);
        var pipe = new NamedPipeClientStream(
            ".",
            session.PipeName,
            PipeDirection.InOut,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        try
        {
            await pipe.ConnectAsync(deadline.Token).ConfigureAwait(false);
            await VirtualMicPcmProtocol.WriteAsync(
                pipe,
                VirtualMicPcmProtocol.CreateHello(session.CapabilityToken),
                deadline.Token).ConfigureAwait(false);
            var acknowledgement = await VirtualMicPcmProtocol.ReadAsync(pipe, deadline.Token).ConfigureAwait(false);
            if (acknowledgement.Kind != VirtualMicPcmMessageKind.Acknowledgement)
            {
                throw new VirtualMicPcmProtocolException(VirtualMicPcmProtocolError.UnexpectedMessage);
            }

            return new VirtualMicPcmBrokerConnection(pipe);
        }
        catch
        {
            pipe.Dispose();
            throw;
        }
    }
}

public sealed class VirtualMicPcmBrokerConnection : IAsyncDisposable
{
    private readonly NamedPipeClientStream pipe;
    private readonly SemaphoreSlim writeLock = new(1, 1);
    private ulong nextSequence = 1;
    private bool stopped;

    internal VirtualMicPcmBrokerConnection(NamedPipeClientStream pipe) => this.pipe = pipe;

    public async Task WritePcmAsync(ReadOnlyMemory<byte> pcm16LeStereo, CancellationToken cancellationToken = default)
    {
        await writeLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ThrowIfStopped();
            await VirtualMicPcmProtocol.WriteAsync(
                pipe,
                VirtualMicPcmProtocol.CreatePcm(nextSequence++, pcm16LeStereo.Span),
                cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            writeLock.Release();
        }
    }

    public async Task StopAsync(CancellationToken cancellationToken = default)
    {
        await writeLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (stopped)
            {
                return;
            }

            stopped = true;
            await VirtualMicPcmProtocol.WriteAsync(
                pipe,
                VirtualMicPcmProtocol.CreateStop(),
                cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            writeLock.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        try
        {
            await StopAsync().ConfigureAwait(false);
        }
        catch (IOException)
        {
            // Closing a broken test-only pipe is already fail-closed.
        }
        finally
        {
            pipe.Dispose();
            writeLock.Dispose();
        }
    }

    private void ThrowIfStopped()
    {
        if (stopped)
        {
            throw new InvalidOperationException("The virtual microphone PCM broker connection has stopped.");
        }
    }
}

internal static partial class VirtualMicPcmBrokerPeer
{
    public static bool IsAuthorized(NamedPipeServerStream pipe)
    {
        if (!OperatingSystem.IsWindows() || !pipe.IsConnected)
        {
            return false;
        }

        // A local process ID is available only to a local named-pipe peer. The
        // server's CurrentUserOnly option remains the SID authorization check.
        return GetNamedPipeClientProcessId(pipe.SafePipeHandle, out _);
    }

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint clientProcessId);
}

#pragma warning restore CA1416
