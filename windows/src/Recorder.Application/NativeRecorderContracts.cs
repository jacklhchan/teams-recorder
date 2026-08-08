using Recorder.Core;

namespace TeamsRecorder.Windows.Application;

public enum RecordingCaptureMode
{
    SystemLoopback = 0,
    Microphone = 1,
    ProcessLoopback = 2,
    Mixed = 3,
    SelectedAppMixed = 4,
    SelectedWindowAv = 5,
}

/// <summary>
/// The root timeline source for the additive selected-audio C ABI.  A process
/// request always means the selected root PID plus its complete process tree;
/// it never degrades into an all-system loopback request.
/// </summary>
public enum NativeSelectedAudioSource : uint
{
    SystemLoopback = 0,
    ProcessTreeLoopback = 1,
}

public enum NativeRecorderState
{
    Ready = 0,
    Recording = 1,
    Stopped = 2,
    Faulted = 3,
    Starting = 4,
    Stopping = 5,
}

public enum NativeRecorderResult
{
    Ok = 0,
    InvalidArgument = 1,
    InvalidState = 2,
    NotImplemented = 3,
    InternalError = 4,
    IoError = 5,
    CaptureError = 6,
    UnsupportedFormat = 7,
}

public enum CaptureEndpointFlow : uint
{
    Render = 0,
    Capture = 1,
}

[Flags]
public enum EndpointDefaultRole : uint
{
    None = 0,
    Console = 1U << 0,
    Multimedia = 1U << 1,
    Communications = 1U << 2,
}

public interface INativeRecordingRequest
{
    RecordingCaptureMode Mode { get; }

    string OutputPath { get; }

    void Validate();
}

public sealed record NativeRecordingRequest(
    RecordingCaptureMode Mode,
    string OutputPath,
    string? EndpointId = null,
    uint TargetProcessId = 0) : INativeRecordingRequest
{
    public void Validate()
    {
        if (!Enum.IsDefined(Mode) ||
            Mode is RecordingCaptureMode.Mixed or RecordingCaptureMode.SelectedAppMixed)
        {
            throw new ArgumentOutOfRangeException(nameof(Mode), "The capture mode is not supported.");
        }

        if (string.IsNullOrWhiteSpace(OutputPath))
        {
            throw new ArgumentException("An output path is required.", nameof(OutputPath));
        }

        if (OutputPath.IndexOf('\0') >= 0)
        {
            throw new ArgumentException("The output path contains a null character.", nameof(OutputPath));
        }

        if (EndpointId is { Length: > 0 } && string.IsNullOrWhiteSpace(EndpointId))
        {
            throw new ArgumentException("The endpoint ID cannot consist only of whitespace.", nameof(EndpointId));
        }

        if (EndpointId?.IndexOf('\0') >= 0)
        {
            throw new ArgumentException("The endpoint ID contains a null character.", nameof(EndpointId));
        }

        if (Mode == RecordingCaptureMode.ProcessLoopback)
        {
            if (TargetProcessId == 0)
            {
                throw new ArgumentException(
                    "Process-loopback capture requires a target process ID.",
                    nameof(TargetProcessId));
            }

            if (!string.IsNullOrEmpty(EndpointId))
            {
                throw new ArgumentException(
                    "Process-loopback capture does not accept an endpoint ID.",
                    nameof(EndpointId));
            }

            return;
        }

        if (TargetProcessId != 0)
        {
            throw new ArgumentException(
                "Only process-loopback capture accepts a target process ID.",
                nameof(TargetProcessId));
        }
    }
}

/// <summary>
/// Describes the audio-first Windows recording path: system render loopback,
/// optionally mixed with one explicitly selected microphone, encoded as AAC M4A.
/// Empty endpoint IDs deliberately mean the Windows default render endpoint and
/// no microphone respectively; the native bridge never substitutes another
/// explicitly selected endpoint.
/// </summary>
public sealed record NativeMixedRecordingRequest(
    string OutputPath,
    string? RenderEndpointId = null,
    string? MicrophoneEndpointId = null,
    uint AacBitRate = 128_000) : INativeRecordingRequest
{
    public RecordingCaptureMode Mode => RecordingCaptureMode.Mixed;

    public bool IncludesMicrophone => !string.IsNullOrEmpty(MicrophoneEndpointId);

    public void Validate()
    {
        if (string.IsNullOrWhiteSpace(OutputPath))
        {
            throw new ArgumentException("An output path is required.", nameof(OutputPath));
        }

        if (OutputPath.IndexOf('\0') >= 0)
        {
            throw new ArgumentException("The output path contains a null character.", nameof(OutputPath));
        }

        if (!string.Equals(Path.GetExtension(OutputPath), ".m4a", StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException("Mixed recording output must use the .m4a extension.", nameof(OutputPath));
        }

        ValidateEndpointId(RenderEndpointId, nameof(RenderEndpointId));
        ValidateEndpointId(MicrophoneEndpointId, nameof(MicrophoneEndpointId));

        if (AacBitRate is < 64_000 or > 320_000)
        {
            throw new ArgumentOutOfRangeException(
                nameof(AacBitRate),
                "AAC bitrate must be between 64,000 and 320,000 bits per second.");
        }
    }

    private static void ValidateEndpointId(string? endpointId, string parameterName)
    {
        if (endpointId is { Length: > 0 } && string.IsNullOrWhiteSpace(endpointId))
        {
            throw new ArgumentException("The endpoint ID cannot consist only of whitespace.", parameterName);
        }

        if (endpointId?.IndexOf('\0') >= 0)
        {
            throw new ArgumentException("The endpoint ID contains a null character.", parameterName);
        }
    }
}

/// <summary>
/// M4A request for the selected-audio C ABI.  This is deliberately separate
/// from <see cref="NativeRecordingRequest"/> so legacy WAV/process entry
/// points cannot accidentally be used for the selected-app product path.
/// </summary>
public sealed record NativeSelectedAudioRequest(
    NativeSelectedAudioSource AudioSource,
    string OutputPath,
    string? RenderEndpointId = null,
    string? MicrophoneEndpointId = null,
    uint TargetProcessId = 0,
    bool IncludedProcessTree = false,
    ulong ExpectedProcessCreationTime100Nanoseconds = 0,
    uint AacBitRate = 128_000) : INativeRecordingRequest
{
    public RecordingCaptureMode Mode => RecordingCaptureMode.SelectedAppMixed;

    public bool IncludesMicrophone => !string.IsNullOrEmpty(MicrophoneEndpointId);

    public void Validate()
    {
        if (!Enum.IsDefined(AudioSource))
        {
            throw new ArgumentOutOfRangeException(nameof(AudioSource));
        }

        if (string.IsNullOrWhiteSpace(OutputPath) || OutputPath.IndexOf('\0') >= 0)
        {
            throw new ArgumentException("An output path is required.", nameof(OutputPath));
        }

        if (!string.Equals(Path.GetExtension(OutputPath), ".m4a", StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException("Selected-audio output must use the .m4a extension.", nameof(OutputPath));
        }

        ValidateEndpointId(RenderEndpointId, nameof(RenderEndpointId));
        ValidateEndpointId(MicrophoneEndpointId, nameof(MicrophoneEndpointId));

        if (AacBitRate is < 64_000 or > 320_000)
        {
            throw new ArgumentOutOfRangeException(nameof(AacBitRate));
        }

        switch (AudioSource)
        {
            case NativeSelectedAudioSource.SystemLoopback when
                TargetProcessId == 0 && !IncludedProcessTree &&
                ExpectedProcessCreationTime100Nanoseconds == 0:
                return;
            case NativeSelectedAudioSource.ProcessTreeLoopback when
                TargetProcessId != 0 && IncludedProcessTree &&
                ExpectedProcessCreationTime100Nanoseconds != 0 &&
                string.IsNullOrEmpty(RenderEndpointId):
                return;
            case NativeSelectedAudioSource.ProcessTreeLoopback:
                throw new ArgumentException(
                    "Selected-process audio requires a root PID, its complete tree, and no render endpoint.");
            default:
                throw new ArgumentException(
                    "System loopback cannot include a process identity or process-tree declaration.");
        }
    }

    private static void ValidateEndpointId(string? endpointId, string parameterName)
    {
        if (endpointId is { Length: > 0 } && string.IsNullOrWhiteSpace(endpointId))
        {
            throw new ArgumentException("The endpoint ID cannot consist only of whitespace.", parameterName);
        }

        if (endpointId?.IndexOf('\0') >= 0)
        {
            throw new ArgumentException("The endpoint ID contains a null character.", parameterName);
        }
    }
}

/// <summary>
/// Exact-HWND WGC plus mixed audio.  The M4A path is retained until the MP4
/// has been decoder-validated and atomically published, so a video or mux
/// failure never turns an otherwise playable audio recording into data loss.
/// </summary>
public sealed record NativeSelectedWindowAvRequest(
    NativeSelectedAudioSource AudioSource,
    string AudioRecoveryPath,
    string VideoOutputPath,
    VideoCaptureTarget WindowTarget,
    string? RenderEndpointId = null,
    string? MicrophoneEndpointId = null,
    uint AudioTargetProcessId = 0,
    bool IncludedProcessTree = false,
    ulong AudioProcessCreationTime100Nanoseconds = 0,
    uint VideoWidth = 1280,
    uint VideoHeight = 720,
    uint VideoFrameRate = 30,
    uint VideoBitRate = 2_500_000,
    uint AacBitRate = 128_000) : INativeRecordingRequest
{
    public RecordingCaptureMode Mode => RecordingCaptureMode.SelectedWindowAv;
    public string OutputPath => VideoOutputPath;

    public void Validate()
    {
        if (!Enum.IsDefined(AudioSource) || WindowTarget is null || !WindowTarget.IsUsable)
            throw new ArgumentException("A live exact window target is required.", nameof(WindowTarget));
        ValidatePath(AudioRecoveryPath, ".m4a", nameof(AudioRecoveryPath));
        ValidatePath(VideoOutputPath, ".mp4", nameof(VideoOutputPath));
        NativeSelectedAudioRequest audio = new(
            AudioSource, AudioRecoveryPath, RenderEndpointId, MicrophoneEndpointId,
            AudioTargetProcessId, IncludedProcessTree,
            AudioProcessCreationTime100Nanoseconds, AacBitRate);
        audio.Validate();
        if (VideoWidth is < 2 or > 1920 || VideoHeight is < 2 or > 1080 ||
            VideoWidth % 2 != 0 || VideoHeight % 2 != 0 ||
            VideoFrameRate is < 1 or > 60 || VideoBitRate is < 250_000 or > 12_000_000)
            throw new ArgumentOutOfRangeException(nameof(VideoWidth), "Video settings are outside the safe MP4 profile.");
    }

    private static void ValidatePath(string value, string extension, string parameterName)
    {
        if (string.IsNullOrWhiteSpace(value) || value.IndexOf('\0') >= 0 ||
            !string.Equals(Path.GetExtension(value), extension, StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException($"A {extension} path is required.", parameterName);
    }
}

public sealed record NativeCaptureStats(
    RecordingCaptureMode Mode,
    uint SourceSampleRate,
    uint SourceChannels,
    uint OutputSampleRate,
    uint OutputChannels,
    bool EventDriven,
    ulong Packets,
    ulong InputFrames,
    ulong OutputFrames,
    ulong SilentPackets,
    ulong Discontinuities,
    ulong FirstQpc100Nanoseconds,
    ulong LastQpc100Nanoseconds,
    float Peak,
    NativeSourceTimelineStats RenderTimeline,
    NativeSourceTimelineStats MicrophoneTimeline)
{
    /// <summary>Latest normalized output/primary-source envelope for live UI metering.</summary>
    public float PrimaryLevelPeak { get; init; }
    public float PrimaryLevelRms { get; init; }
    /// <summary>Latest normalized optional-microphone envelope for live UI metering.</summary>
    public float MicrophoneLevelPeak { get; init; }
    public float MicrophoneLevelRms { get; init; }

    public static NativeCaptureStats Empty(RecordingCaptureMode mode) => new(
        mode,
        SourceSampleRate: 0,
        SourceChannels: 0,
        OutputSampleRate: 48_000,
        OutputChannels: 2,
        EventDriven: false,
        Packets: 0,
        InputFrames: 0,
        OutputFrames: 0,
        SilentPackets: 0,
        Discontinuities: 0,
        FirstQpc100Nanoseconds: 0,
        LastQpc100Nanoseconds: 0,
        Peak: 0,
        RenderTimeline: NativeSourceTimelineStats.Empty,
        MicrophoneTimeline: NativeSourceTimelineStats.Empty);
}

public sealed record NativeSourceTimelineStats(
    ulong DriftCorrections,
    ulong LatePackets,
    ulong LateFramesDropped,
    ulong QueueOverflows,
    ulong SourceDisconnects,
    ulong Discontinuities)
{
    public static NativeSourceTimelineStats Empty { get; } = new(0, 0, 0, 0, 0, 0);
}

public sealed record NativeRecorderSnapshot(
    NativeRecorderResult Result,
    NativeRecorderState State,
    NativeCaptureStats Stats,
    string? Error);

public sealed record NativeOperationResult(NativeRecorderResult Result, string? Error)
{
    public bool IsSuccess => Result == NativeRecorderResult.Ok;

    public static NativeOperationResult Success() => new(NativeRecorderResult.Ok, null);

    public static NativeOperationResult Failure(NativeRecorderResult result, string? error) =>
        new(result, error);
}

public sealed record NativeCaptureEndpoint(
    CaptureEndpointFlow Flow,
    EndpointDefaultRole DefaultRoles,
    string EndpointId,
    string FriendlyName);

public sealed record NativeEndpointEnumerationResult(
    NativeOperationResult Operation,
    IReadOnlyList<NativeCaptureEndpoint> Endpoints)
{
    public bool IsSuccess => Operation.IsSuccess;
}

/// <summary>
/// In-memory preflight hint describing render endpoints on which Windows sees
/// an active Teams audio session. An empty successful result is deliberately
/// non-blocking: Teams may be silent, use a broker process, or have no active
/// render session at the instant of the probe.
/// </summary>
public sealed record NativeTeamsRenderEndpointProbeResult(
    NativeOperationResult Operation,
    IReadOnlyList<NativeCaptureEndpoint> ActiveEndpoints)
{
    public bool IsSuccess => Operation.IsSuccess;
}

public interface INativeRecorderBridge : IDisposable
{
    NativeOperationResult Start(NativeRecordingRequest request);

    NativeOperationResult StartMixed(NativeMixedRecordingRequest request);

    NativeOperationResult Stop();

    NativeRecorderSnapshot GetSnapshot();

    NativeEndpointEnumerationResult EnumerateEndpoints();
}

/// <summary>
/// Optional capability implemented by native bridges that can set the
/// microphone contribution of an active mixed M4A recording. The state is
/// absolute, never a toggle; callers that do not need this capability can
/// continue to depend on <see cref="INativeRecorderBridge"/> alone.
/// </summary>
public interface INativeRecorderMicrophoneMuteControl
{
    NativeOperationResult SetMicrophoneMuted(bool muted);
}

/// <summary>
/// Optional additive capability for bridges that expose the selected-process
/// M4A ABI. Callers that depend only on the original bridge remain source
/// compatible, while selected-process starts fail closed when the capability
/// is absent.
/// </summary>
public interface INativeSelectedAudioRecorderBridge
{
    NativeOperationResult StartSelectedAudio(NativeSelectedAudioRequest request);
}

public interface INativeSelectedWindowAvRecorderBridge
{
    NativeOperationResult StartSelectedWindowAv(NativeSelectedWindowAvRequest request);
}

/// <summary>Optional native capability used only for a non-blocking Teams endpoint preflight.</summary>
public interface INativeTeamsRenderEndpointProbe
{
    NativeTeamsRenderEndpointProbeResult ProbeTeamsRenderEndpoints();
}
