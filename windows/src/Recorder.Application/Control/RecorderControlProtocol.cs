using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;

namespace TeamsRecorder.Windows.Application.Control;

public static class RecorderControlProtocol
{
    public const int SchemaVersion = 1;
    public const int MaxRequestBytes = 8 * 1024;
    public const int MaxResponseBytes = 64 * 1024;

    public const string Status = "status";
    public const string Watch = "watch";
    public const string RefreshDevices = "devices.refresh";
    public const string Start = "recording.start";
    public const string Test = "recording.test";
    public const string Stop = "recording.stop";
    public const string SetMicrophoneMute = "microphone.setMuted";
    public const string Diagnostics = "diagnostics.snapshot";

    private static readonly HashSet<string> SupportedCommands = new(StringComparer.Ordinal)
    {
        Status,
        RefreshDevices,
        Start,
        Test,
        Stop,
        SetMicrophoneMute,
        Diagnostics,
    };

    public static bool IsSupportedCommand(string? command) =>
        command is not null && SupportedCommands.Contains(command);

    public static byte[] SerializeRequest(RecorderControlRequest request) =>
        JsonSerializer.SerializeToUtf8Bytes(request, JsonSerializerOptions.Web);

    public static RecorderControlRequest? DeserializeRequest(ReadOnlySpan<byte> payload) =>
        JsonSerializer.Deserialize<RecorderControlRequest>(payload, JsonSerializerOptions.Web);

    public static string PipeName()
    {
        var identity = OperatingSystem.IsWindows()
            ? WindowsIdentity.GetCurrent().User?.Value
            : Environment.UserName;
        identity ??= "unknown";
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(identity)))[..16];
        return $"TeamsRecorder.Control.v1.{hash}";
    }
}

public sealed record RecorderControlRequest(
    int SchemaVersion,
    string RequestId,
    string Command,
    long? ExpectedGeneration = null,
    bool? Muted = null);

public sealed record RecorderControlError(string Code, string Message);

public sealed class RecorderControlException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}

public sealed record RecorderControlResponse(
    int SchemaVersion,
    string RequestId,
    bool Ok,
    object? Result = null,
    RecorderControlError? Error = null)
{
    public static RecorderControlResponse Success(string requestId, object? result) =>
        new(RecorderControlProtocol.SchemaVersion, requestId, true, result);

    public static RecorderControlResponse Failure(string requestId, string code, string message) =>
        new(RecorderControlProtocol.SchemaVersion, requestId, false, null, new(code, message));
}

public sealed record RecorderControlTimelineStatus(
    ulong DriftCorrections,
    ulong LatePackets,
    ulong LateFramesDropped,
    ulong QueueOverflows,
    ulong SourceDisconnects,
    ulong Discontinuities);

public sealed record RecorderControlAudioStatus(
    string Mode,
    uint SourceSampleRate,
    uint SourceChannels,
    ulong Packets,
    ulong InputFrames,
    ulong OutputFrames,
    ulong SilentPackets,
    ulong Discontinuities,
    float Peak,
    float OutputLevelPeak,
    float OutputLevelRms,
    float MicrophoneLevelPeak,
    float MicrophoneLevelRms,
    RecorderControlTimelineStatus RenderTimeline,
    RecorderControlTimelineStatus MicrophoneTimeline,
    NativeImpulseRepairStats ImpulseRepair,
    ulong RenderTimestampErrors,
    ulong MicrophoneTimestampErrors);

public sealed record RecorderControlTeamsStatus(
    bool LocalHeuristicEnabled,
    string LocalEvidenceHealth,
    int ConsecutiveActiveObservations,
    int ConsecutiveMissingObservations,
    bool AutomaticRecordingEnabled,
    string AutomaticState,
    bool CanReadTeamsMute);

public sealed record RecorderControlStatus(
    DateTimeOffset TimestampUtc,
    bool Initialized,
    long Generation,
    string RecordingState,
    bool IsRecording,
    bool IsTestRecording,
    bool MicrophoneMuted,
    string SelectedRenderDevice,
    string SelectedMicrophoneDevice,
    string CaptureSource,
    string StatusText,
    string? Error,
    RecorderControlAudioStatus Audio,
    RecorderControlTeamsStatus Teams);
