namespace TeamsRecorder.Windows.Application;

public enum RecordingCaptureMode
{
    SystemLoopback = 0,
    Microphone = 1,
    ProcessLoopback = 2,
    Mixed = 3,
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
        if (!Enum.IsDefined(Mode) || Mode == RecordingCaptureMode.Mixed)
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
    float Peak)
{
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
        Peak: 0);
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

public interface INativeRecorderBridge : IDisposable
{
    NativeOperationResult Start(NativeRecordingRequest request);

    NativeOperationResult StartMixed(NativeMixedRecordingRequest request);

    NativeOperationResult Stop();

    NativeRecorderSnapshot GetSnapshot();

    NativeEndpointEnumerationResult EnumerateEndpoints();
}
