namespace TeamsRecorder.Windows.Application;

public sealed class CaptureSourceSelectionPolicy
{
    private readonly IProcessCatalog processCatalog;
    public CaptureSourceSelectionPolicy(IProcessCatalog? processCatalog = null) => this.processCatalog = processCatalog ?? new ProcessCatalog();

    public void EnsureSelectedProcessIsCurrent(RecordingStartRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        request.Validate();
        if (request.AudioSource == RecordingAudioSource.SelectedProcessLoopback && !processCatalog.IsCurrent(request.ProcessTarget!))
            throw new InvalidOperationException("The selected process has exited or its PID was reused.");
    }

    /// <summary>
    /// Produces only the current M4A selected-audio ABI request. A stale process
    /// is rejected before native activation; no branch maps it to system audio.
    /// </summary>
    public NativeSelectedAudioRequest CreateSelectedAudioRequest(RecordingStartRequest request, string outputPath)
    {
        ArgumentNullException.ThrowIfNull(request);
        request.Validate();
        if (string.IsNullOrWhiteSpace(outputPath) || outputPath.IndexOf('\0') >= 0)
        {
            throw new ArgumentException("A valid output path is required.", nameof(outputPath));
        }

        return request.AudioSource switch
        {
            RecordingAudioSource.SystemLoopback => new NativeSelectedAudioRequest(
                NativeSelectedAudioSource.SystemLoopback,
                outputPath,
                request.RenderEndpointId,
                request.MicrophoneEndpointId),
            RecordingAudioSource.SelectedProcessLoopback when request.ProcessTarget is { } target && processCatalog.IsCurrent(target) =>
                new NativeSelectedAudioRequest(
                    NativeSelectedAudioSource.ProcessTreeLoopback,
                    outputPath,
                    RenderEndpointId: null,
                    MicrophoneEndpointId: request.MicrophoneEndpointId,
                    TargetProcessId: target.ProcessId,
                    IncludedProcessTree: true,
                    ExpectedProcessCreationTime100Nanoseconds: checked((ulong)target.StartedAt.UtcDateTime.ToFileTimeUtc())),
            RecordingAudioSource.SelectedProcessLoopback => throw new InvalidOperationException(
                "The selected process has exited or its PID was reused."),
            _ => throw new ArgumentOutOfRangeException(nameof(request)),
        };
    }

    /// <summary>Legacy single-source translation. A microphone mix needs the selected-audio bridge.</summary>
    public NativeRecordingRequest CreateNativeRequest(RecordingStartRequest request, string outputPath)
    {
        ArgumentNullException.ThrowIfNull(request); request.Validate();
        if (string.IsNullOrWhiteSpace(outputPath) || outputPath.IndexOf('\0') >= 0) throw new ArgumentException("A valid output path is required.", nameof(outputPath));
        if (request.MicrophoneEndpointId is not null)
            throw new NotSupportedException("A microphone mix requires the selected-audio native bridge.");
        return request.AudioSource switch
        {
            RecordingAudioSource.SystemLoopback => new(RecordingCaptureMode.SystemLoopback, outputPath, request.RenderEndpointId),
            RecordingAudioSource.SelectedProcessLoopback when request.ProcessTarget is { } target && processCatalog.IsCurrent(target) => new(RecordingCaptureMode.ProcessLoopback, outputPath, null, target.ProcessId),
            RecordingAudioSource.SelectedProcessLoopback => throw new InvalidOperationException("The selected process has exited or its PID was reused."),
            _ => throw new ArgumentOutOfRangeException(nameof(request)),
        };
    }
}
