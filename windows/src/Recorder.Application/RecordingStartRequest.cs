using Recorder.Core;

namespace TeamsRecorder.Windows.Application;

public enum RecordingAudioSource
{
    SystemLoopback = 0,
    SelectedProcessLoopback = 1,
    SystemAudio = SystemLoopback,
    ProcessAudio = SelectedProcessLoopback,
}

/// <summary>
/// Stable process identity. DisplayName is a presentation-safe process name,
/// never an executable path or command line.
/// </summary>
public sealed record SelectedProcessTarget(uint ProcessId, DateTimeOffset StartedAt, string DisplayName)
{
    public string ProcessName => DisplayName;

    public void Validate()
    {
        if (ProcessId == 0) throw new ArgumentOutOfRangeException(nameof(ProcessId));
        if (StartedAt == default || StartedAt.UtcDateTime <= DateTime.FromFileTimeUtc(0))
            throw new ArgumentOutOfRangeException(nameof(StartedAt));
        if (!WindowsExecutableBasename.TryNormalize(
                DisplayName,
                requireExeExtension: false,
                out _))
        {
            throw new ArgumentException("A safe process name is required.", nameof(DisplayName));
        }
    }
}

/// <summary>Strict application intent; process capture never falls back to system audio.</summary>
public sealed record RecordingStartRequest(
    RecordingSessionKind Kind,
    RecordingAudioSource AudioSource,
    string? RenderEndpointId = null,
    string? MicrophoneEndpointId = null,
    SelectedProcessTarget? ProcessTarget = null,
    bool IncludeProcessTree = false,
    TimeSpan? TestDuration = null,
    VideoCaptureTarget? VideoTarget = null)
{
    public void Validate()
    {
        if (!Enum.IsDefined(Kind)) throw new ArgumentOutOfRangeException(nameof(Kind));
        if (!Enum.IsDefined(AudioSource)) throw new ArgumentOutOfRangeException(nameof(AudioSource));
        ValidateEndpoint(RenderEndpointId, nameof(RenderEndpointId));
        ValidateEndpoint(MicrophoneEndpointId, nameof(MicrophoneEndpointId));
        if (Kind == RecordingSessionKind.Test)
        {
            if (TestDuration is not { } duration || duration <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(TestDuration));
        }
        else if (TestDuration is not null) throw new ArgumentException("Only test sessions accept a duration.", nameof(TestDuration));
        if (VideoTarget is not null && !VideoTarget.IsUsable)
            throw new ArgumentException("Video capture requires one admitted live Teams window.", nameof(VideoTarget));

        switch (AudioSource)
        {
            case RecordingAudioSource.SystemLoopback when ProcessTarget is null && !IncludeProcessTree: return;
            case RecordingAudioSource.SelectedProcessLoopback when RenderEndpointId is null && ProcessTarget is not null && IncludeProcessTree:
                ProcessTarget.Validate(); return;
            case RecordingAudioSource.SelectedProcessLoopback: throw new ArgumentException("Selected-process loopback requires a process, its tree, and no render endpoint.", nameof(ProcessTarget));
            default: throw new ArgumentException("The selected source accepts incompatible inputs.");
        }
    }

    private static void ValidateEndpoint(string? value, string parameterName)
    {
        if (value is not null && (string.IsNullOrWhiteSpace(value) || value.IndexOf('\0') >= 0)) throw new ArgumentException("Invalid endpoint ID.", parameterName);
    }
}
