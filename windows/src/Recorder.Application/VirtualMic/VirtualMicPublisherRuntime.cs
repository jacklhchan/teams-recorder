using System.Diagnostics;
using System.Threading.Channels;

namespace TeamsRecorder.Windows.Application.VirtualMic;

public enum VirtualMicPublisherRuntimeState
{
    Disabled,
    Starting,
    Ready,
    Unavailable,
    Stopped,
}

/// <summary>
/// Mirrors the macOS publisher boundary without allowing virtual-microphone
/// failure to stop or corrupt the authoritative local recording.
/// </summary>
public sealed class VirtualMicPublisherRuntime : IAsyncDisposable
{
    private readonly INativeMicrophonePcmSource source;
    private readonly Channel<NativeMicrophonePcmFrameEventArgs> frames;
    private readonly CancellationTokenSource lifetime = new();
    private Process? brokerProcess;
    private VirtualMicPcmBrokerConnection? connection;
    private Task? pump;
    private bool disposed;

    private VirtualMicPublisherRuntime(INativeMicrophonePcmSource source)
    {
        this.source = source;
        frames = Channel.CreateBounded<NativeMicrophonePcmFrameEventArgs>(
            new BoundedChannelOptions(8)
            {
                SingleReader = true,
                SingleWriter = false,
                FullMode = BoundedChannelFullMode.DropOldest,
                AllowSynchronousContinuations = false,
            });
    }

    public VirtualMicPublisherRuntimeState State { get; private set; } =
        VirtualMicPublisherRuntimeState.Disabled;
    public string? FailureReason { get; private set; }

    public static async Task<VirtualMicPublisherRuntime> StartAsync(
        INativeMicrophonePcmSource source,
        VirtualMicTrustedEndpointIdentity identity,
        IReadOnlyList<NativeCaptureEndpoint> endpoints,
        string? brokerExecutablePath = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(source);
        ArgumentNullException.ThrowIfNull(identity);
        ArgumentNullException.ThrowIfNull(endpoints);
        var runtime = new VirtualMicPublisherRuntime(source)
        {
            State = VirtualMicPublisherRuntimeState.Starting,
        };
        try
        {
            if (!VirtualMicPreviewBuildPolicy.IsTestSignedPreviewCompiled)
                throw new InvalidOperationException(VirtualMicPreviewBuildPolicy.ReleaseDisabledReason);
            var capability = VirtualMicPreviewHandshake.Evaluate(identity, endpoints);
            if (!capability.IsAvailable)
                throw new InvalidOperationException(capability.Reason);

            var executable = brokerExecutablePath ?? Path.Combine(
                AppContext.BaseDirectory, "Recorder.VirtualMicBroker.exe");
            if (!File.Exists(executable))
                throw new FileNotFoundException("The isolated virtual microphone broker is missing.", executable);

            var session = VirtualMicPcmBrokerSession.Create(identity);
            var process = Process.Start(new ProcessStartInfo
            {
                FileName = executable,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardInput = true,
                RedirectStandardOutput = false,
                RedirectStandardError = false,
            }) ?? throw new InvalidOperationException("Starting the virtual microphone broker failed.");
            runtime.brokerProcess = process;
            await process.StandardInput.WriteLineAsync(
                VirtualMicBrokerLaunchEnvelope.Create(session).Serialize()).ConfigureAwait(false);
            process.StandardInput.Close();

            runtime.connection = await VirtualMicPreviewHandshake.ConnectBrokerAsync(
                capability, session, TimeSpan.FromSeconds(8), cancellationToken).ConfigureAwait(false);
            runtime.source.MicrophonePcmFrameAvailable += runtime.OnMicrophonePcmFrame;
            runtime.pump = runtime.PumpAsync(runtime.lifetime.Token);
            runtime.State = VirtualMicPublisherRuntimeState.Ready;
            return runtime;
        }
        catch (Exception error)
        {
            runtime.State = VirtualMicPublisherRuntimeState.Unavailable;
            runtime.FailureReason = error.Message;
            await runtime.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }

    private void OnMicrophonePcmFrame(
        object? sender,
        NativeMicrophonePcmFrameEventArgs frame)
    {
        if (!disposed && State == VirtualMicPublisherRuntimeState.Ready)
            frames.Writer.TryWrite(frame);
    }

    private async Task PumpAsync(CancellationToken cancellationToken)
    {
        try
        {
            await foreach (var frame in frames.Reader.ReadAllAsync(cancellationToken).ConfigureAwait(false))
            {
                if (frame.SampleRate != VirtualMicPcmProtocol.SampleRate || frame.FrameCount <= 0)
                    continue;
                var pcm = ConvertFloatStereoToPcm16(frame.InterleavedStereo);
                await connection!.WritePcmAsync(pcm, cancellationToken).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
        catch (Exception error)
        {
            FailureReason = error.Message;
            State = VirtualMicPublisherRuntimeState.Unavailable;
        }
    }

    public static byte[] ConvertFloatStereoToPcm16(ReadOnlySpan<float> samples)
    {
        if (samples.IsEmpty || samples.Length % 2 != 0 ||
            samples.Length / 2 > VirtualMicPcmProtocol.MaximumPcmPayloadBytes /
                VirtualMicPcmProtocol.BlockAlign)
            throw new ArgumentOutOfRangeException(nameof(samples));
        var result = new byte[checked(samples.Length * sizeof(short))];
        for (var index = 0; index < samples.Length; ++index)
        {
            var value = float.IsFinite(samples[index])
                ? Math.Clamp(samples[index], -1f, 1f)
                : 0f;
            var encoded = value <= -1f
                ? short.MinValue
                : checked((short)MathF.Round(value * short.MaxValue));
            System.Buffers.Binary.BinaryPrimitives.WriteInt16LittleEndian(
                result.AsSpan(index * sizeof(short), sizeof(short)), encoded);
        }
        return result;
    }

    public async ValueTask DisposeAsync()
    {
        if (disposed) return;
        disposed = true;
        source.MicrophonePcmFrameAvailable -= OnMicrophonePcmFrame;
        frames.Writer.TryComplete();
        lifetime.Cancel();
        if (pump is not null)
        {
            try { await pump.ConfigureAwait(false); }
            catch (OperationCanceledException) { }
        }
        if (connection is not null)
            await connection.DisposeAsync().ConfigureAwait(false);
        if (brokerProcess is not null)
        {
            try
            {
                using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(3));
                await brokerProcess.WaitForExitAsync(deadline.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                try { brokerProcess.Kill(entireProcessTree: true); }
                catch (InvalidOperationException) { }
            }
            brokerProcess.Dispose();
        }
        lifetime.Dispose();
        if (State != VirtualMicPublisherRuntimeState.Unavailable)
            State = VirtualMicPublisherRuntimeState.Stopped;
    }
}
