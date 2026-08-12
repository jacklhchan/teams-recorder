namespace Recorder.Core;

public enum RecordingStorageDecision { Normal, Warn, AudioOnly, Stop }

/// <summary>Portable storage thresholds. Callers provide the platform-specific free-space value.</summary>
public sealed record RecordingStoragePolicy(long AudioStopBytes = 256L * 1024 * 1024)
{
    public const long WarningBytes = 5L * 1024 * 1024 * 1024;
    public const long VideoMinimumBytes = 1L * 1024 * 1024 * 1024;
    public const long DefaultAudioStopBytes = 256L * 1024 * 1024;

    public RecordingStorageDecision Decide(long availableBytes) => availableBytes switch
    {
        var bytes when bytes < AudioStopBytes => RecordingStorageDecision.Stop,
        var bytes when bytes < VideoMinimumBytes => RecordingStorageDecision.AudioOnly,
        var bytes when bytes < WarningBytes => RecordingStorageDecision.Warn,
        _ => RecordingStorageDecision.Normal
    };

    /// <summary>An unavailable volume is deliberately treated like a stop condition.</summary>
    public RecordingStorageDecision Decide(long? availableBytes) =>
        availableBytes is { } bytes && bytes >= 0 ? Decide(bytes) : RecordingStorageDecision.Stop;
}
