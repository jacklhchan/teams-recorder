using System.Text.Json.Nodes;
using System.Text.Json;

namespace Recorder.Core;

public enum RecordingSessionKind { Meeting, Test, Manual }

public enum RecordingRecoveryState { None, VideoLostAudioPreserved, RecoveredAfterInterruption }

public enum VideoPublicationOutcome { None, Completed, LostAudioPreserved }

/// <summary>Actual accepted MP4 timeline bounds, measured from the recording start.</summary>
public readonly record struct VideoPublicationInterval(TimeSpan Start, TimeSpan End)
{
    public bool IsValid => Start >= TimeSpan.Zero && End > Start;
}

/// <summary>
/// The deliberately small, portable description of a Windows audio capture.
/// It identifies a capture *kind*, never the transient process that supplied it.
/// </summary>
public sealed record WindowsCaptureMetadata(
    string AudioSource,
    string? ProcessName,
    bool IncludedProcessTree,
    string? EndpointId)
{
    public const string SystemLoopback = "systemLoopback";
    public const string SelectedProcessLoopback = "selectedProcessLoopback";

    public static WindowsCaptureMetadata ForSystemLoopback(string? endpointId = null) =>
        new(SystemLoopback, null, false, endpointId);

    public static WindowsCaptureMetadata ForSelectedProcessLoopback(string processName) =>
        new(SelectedProcessLoopback, WindowsExecutableBasename.ToExecutableBasename(processName), true, null);
}

public static class RecordingSessionLayout
{
    public const string FinalAudioFileName = "recording.m4a";
    public const string BackupAudioFileName = "recording.audio-backup.m4a";
    public const string PartialAudioFileName = "recording.audio-backup.m4a.partial";
    /// <summary>Optional WGC companion; the canonical session artifact remains M4A audio.</summary>
    public const string FinalVideoFileName = "recording.mp4";
    public const string MetadataFileName = "recording-info.json";

    public static string Prefix(RecordingSessionKind kind) => kind switch
    {
        RecordingSessionKind.Meeting => "meeting-",
        RecordingSessionKind.Test => "test-",
        _ => "manual-",
    };

    public static bool TryGetKind(string? folderName, out RecordingSessionKind kind)
    {
        kind = default;
        if (string.IsNullOrWhiteSpace(folderName) || folderName.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0) return false;
        if (folderName.StartsWith("meeting-", StringComparison.Ordinal)) { kind = RecordingSessionKind.Meeting; return folderName.Length > 8; }
        if (folderName.StartsWith("test-", StringComparison.Ordinal)) { kind = RecordingSessionKind.Test; return folderName.Length > 5; }
        if (folderName.StartsWith("manual-", StringComparison.Ordinal)) { kind = RecordingSessionKind.Manual; return folderName.Length > 7; }
        return false;
    }

    public static string FolderName(RecordingSessionKind kind, DateTimeOffset createdUtc, int collisionNumber = 0)
    {
        if (collisionNumber < 0) throw new ArgumentOutOfRangeException(nameof(collisionNumber));
        var suffix = createdUtc.UtcDateTime.ToString("yyyyMMdd-HHmmssfff", System.Globalization.CultureInfo.InvariantCulture);
        return Prefix(kind) + suffix + (collisionNumber == 0 ? string.Empty : $"-{collisionNumber}");
    }
}

public sealed record RecordingInfo(
    string? Title,
    IReadOnlyList<string> Tags,
    bool IsFavorite,
    string MediaKind,
    RecordingRecoveryState RecoveryState,
    string Source,
    JsonArray Participants,
    int? SchemaVersion,
    JsonObject Document,
    WindowsCaptureMetadata? WindowsCapture = null)
{
    public static RecordingInfo AudioOnly(string? title = null) =>
        RecordingInfoJson.CreateAudioOnly(null, title, RecordingRecoveryState.None, RecordingSessionKind.Manual);
}

/// <summary>Defensive metadata parser. Unknown valid fields are retained for forward compatibility.</summary>
public static class RecordingInfoJson
{
    public static RecordingInfo Parse(string? json)
    {
        try { return Normalize(JsonNode.Parse(json ?? string.Empty) as JsonObject, null, null); }
        catch (JsonException) { return Normalize(null, null, null); }
    }

    public static RecordingInfo Normalize(JsonObject? source, string? titleOverride, RecordingRecoveryState? recoveryOverride)
    {
        var document = source?.DeepClone() as JsonObject ?? new JsonObject();
        var title = titleOverride ?? StringValue(document["title"]);
        var tags = StringArray(document["tags"]);
        var favorite = BoolValue(document["isFavorite"]);
        var mediaKind = StringValue(document["mediaKind"]) is "video" ? "video" : "audio";
        var recovery = recoveryOverride ?? RecoveryValue(StringValue(document["recoveryState"]));
        var windowsCapture = NormalizeWindowsCapture(document);
        var schemaVersion = SchemaVersion(document["schemaVersion"]);
        // A newer writer may have added semantics that this app does not understand.
        // Keep its version byte-for-byte rather than relabelling its document as v1.
        if (schemaVersion is null || schemaVersion < 1)
        {
            schemaVersion = 1;
            document["schemaVersion"] = schemaVersion;
        }
        if (title is null) document.Remove("title"); else document["title"] = title;
        document["tags"] = new JsonArray(tags.Select(tag => JsonValue.Create(tag)).ToArray());
        document["isFavorite"] = favorite;
        document["mediaKind"] = mediaKind;
        document["recoveryState"] = RecoveryText(recovery);
        var sessionSource = StringValue(document["source"]) ?? "manual";
        if (document["source"] is null) document["source"] = sessionSource;
        var participants = document["participants"] as JsonArray;
        if (participants is null)
        {
            participants = new JsonArray();
            document["participants"] = participants;
        }
        return new RecordingInfo(title, tags, favorite, mediaKind, recovery, sessionSource, participants.DeepClone() as JsonArray ?? new JsonArray(), schemaVersion, document, windowsCapture);
    }

    /// <summary>
    /// Produces metadata for an audio-only session while retaining fields the
    /// current app does not understand. Video-only fields are deliberately
    /// removed so Windows Phase 1 never claims a captured screen or Teams
    /// window that it did not produce.
    /// </summary>
    public static RecordingInfo CreateAudioOnly(
        JsonObject? source,
        string? titleOverride,
        RecordingRecoveryState recoveryState,
        RecordingSessionKind sessionKind = RecordingSessionKind.Manual)
    {
        var sourceWasMissing = source?["source"] is null;
        var participantsWereMissing = source?["participants"] is not JsonArray;
        var normalized = Normalize(source, titleOverride, recoveryState);
        var document = normalized.Document.DeepClone() as JsonObject ?? new JsonObject();
        document["mediaKind"] = "audio";
        document["screenIntervals"] = new JsonArray();
        document.Remove("capturedTeamsWindow");
        if (sourceWasMissing) document["source"] = SessionSource(sessionKind);
        if (participantsWereMissing) document["participants"] = new JsonArray();
        return new RecordingInfo(
            normalized.Title,
            normalized.Tags,
            normalized.IsFavorite,
            "audio",
            recoveryState,
            StringValue(document["source"]) ?? SessionSource(sessionKind),
            document["participants"]?.DeepClone() as JsonArray ?? new JsonArray(),
            normalized.SchemaVersion,
            document,
            normalized.WindowsCapture);
    }

    public static string SessionSource(RecordingSessionKind kind) =>
        kind == RecordingSessionKind.Meeting ? "teamsAutomatic" : "manual";

    private static string? StringValue(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<string>(out var text)
            ? TrimToNull(text)
            : null;
    private static bool BoolValue(JsonNode? node) => node is JsonValue value && value.TryGetValue<bool>(out var result) && result;
    private static IReadOnlyList<string> StringArray(JsonNode? node) => node is JsonArray array
        ? array.Select(StringValue).Where(x => !string.IsNullOrWhiteSpace(x)).Cast<string>().ToArray() : Array.Empty<string>();
    private static RecordingRecoveryState RecoveryValue(string? value) => value switch
    {
        "videoLostAudioPreserved" => RecordingRecoveryState.VideoLostAudioPreserved,
        "recoveredAfterInterruption" => RecordingRecoveryState.RecoveredAfterInterruption,
        _ => RecordingRecoveryState.None,
    };
    private static int? SchemaVersion(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<int>(out var version) ? version : null;
    private static string RecoveryText(RecordingRecoveryState value) => value switch
    {
        RecordingRecoveryState.VideoLostAudioPreserved => "videoLostAudioPreserved",
        RecordingRecoveryState.RecoveredAfterInterruption => "recoveredAfterInterruption",
        _ => "none",
    };

    private static string? TrimToNull(string value)
    {
        var trimmed = value.Trim();
        return trimmed.Length == 0 ? null : trimmed;
    }

    public static RecordingInfo CreateVideo(
        JsonObject? source,
        string? titleOverride,
        RecordingSessionKind sessionKind,
        VideoPublicationInterval interval)
    {
        if (!interval.IsValid) throw new ArgumentOutOfRangeException(nameof(interval));
        var sourceWasMissing = source?["source"] is null;
        var participantsWereMissing = source?["participants"] is not JsonArray;
        var normalized = Normalize(source, titleOverride, RecordingRecoveryState.None);
        var document = normalized.Document.DeepClone() as JsonObject ?? new JsonObject();
        document["mediaKind"] = "video";
        document["recoveryState"] = "none";
        document["screenIntervals"] = new JsonArray(new JsonObject
        {
            ["startSeconds"] = interval.Start.TotalSeconds,
            ["endSeconds"] = interval.End.TotalSeconds,
        });
        document.Remove("capturedTeamsWindow");
        if (sourceWasMissing) document["source"] = SessionSource(sessionKind);
        if (participantsWereMissing) document["participants"] = new JsonArray();
        return new RecordingInfo(normalized.Title, normalized.Tags, normalized.IsFavorite, "video",
            RecordingRecoveryState.None, StringValue(document["source"]) ?? SessionSource(sessionKind),
            document["participants"]?.DeepClone() as JsonArray ?? new JsonArray(),
            normalized.SchemaVersion, document, normalized.WindowsCapture);
    }

    /// <summary>Applies the bounded Windows capture envelope to compatible metadata.</summary>
    public static RecordingInfo WithWindowsCapture(RecordingInfo info, WindowsCaptureMetadata? windowsCapture)
    {
        ArgumentNullException.ThrowIfNull(info);
        var document = info.Document.DeepClone() as JsonObject ?? new JsonObject();
        if (windowsCapture is null)
        {
            document.Remove("windowsCapture");
        }
        else
        {
            if (windowsCapture.AudioSource == WindowsCaptureMetadata.SelectedProcessLoopback &&
                (!windowsCapture.IncludedProcessTree ||
                 !WindowsExecutableBasename.TryNormalize(
                     windowsCapture.ProcessName,
                     requireExeExtension: true,
                     out _)))
            {
                throw new ArgumentException(
                    "Selected-process capture metadata requires a safe executable basename and process-tree declaration.",
                    nameof(windowsCapture));
            }
            var capture = new JsonObject
            {
                ["audioSource"] = windowsCapture.AudioSource,
                ["includedProcessTree"] = windowsCapture.IncludedProcessTree,
            };
            if (windowsCapture.ProcessName is not null) capture["processName"] = windowsCapture.ProcessName;
            if (windowsCapture.EndpointId is not null) capture["endpointId"] = windowsCapture.EndpointId;
            document["windowsCapture"] = capture;
        }
        return Normalize(document, null, null);
    }

    private static WindowsCaptureMetadata? NormalizeWindowsCapture(JsonObject document)
    {
        // Never retain arbitrary values from this Windows-only envelope. In
        // particular, a PID, executable path, command line, token, or profile
        // path is not useful session metadata and can expose private data.
        if (document["windowsCapture"] is not JsonObject source)
        {
            document.Remove("windowsCapture");
            return null;
        }

        var audioSource = StringValue(source["audioSource"]);
        audioSource = audioSource switch
        {
            WindowsCaptureMetadata.SystemLoopback => WindowsCaptureMetadata.SystemLoopback,
            WindowsCaptureMetadata.SelectedProcessLoopback => WindowsCaptureMetadata.SelectedProcessLoopback,
            _ => null,
        };

        var endpointId = SafeEndpointId(StringValue(source["endpointId"]));
        var processName = audioSource == WindowsCaptureMetadata.SelectedProcessLoopback &&
            WindowsExecutableBasename.TryNormalize(
                StringValue(source["processName"]), requireExeExtension: true, out var safeProcessName)
            ? safeProcessName
            : null;

        // A selected-process declaration without a safe executable basename
        // is not useful and would violate the contract. Retain a legacy
        // endpoint ID, if any, but discard the unsafe selection claim.
        if (audioSource == WindowsCaptureMetadata.SelectedProcessLoopback && processName is null)
        {
            audioSource = null;
        }

        // Older writers may have persisted only endpointId. Preserve that
        // compatible value, but do not infer an app selection from it.
        if (audioSource is null && endpointId is null)
        {
            document.Remove("windowsCapture");
            return null;
        }

        var sanitized = new JsonObject();
        if (audioSource is not null)
        {
            sanitized["audioSource"] = audioSource;
            if (audioSource == WindowsCaptureMetadata.SelectedProcessLoopback)
            {
                // A selected-process capture always includes its process tree;
                // a supplied false value cannot change the recorded meaning.
                sanitized["includedProcessTree"] = true;
                if (processName is not null) sanitized["processName"] = processName;
            }
            else
            {
                sanitized["includedProcessTree"] = false;
            }
        }
        if (endpointId is not null) sanitized["endpointId"] = endpointId;
        document["windowsCapture"] = sanitized;
        return new WindowsCaptureMetadata(
            audioSource ?? WindowsCaptureMetadata.SystemLoopback,
            processName,
            audioSource == WindowsCaptureMetadata.SelectedProcessLoopback,
            endpointId);
    }

    private static string? SafeEndpointId(string? value)
    {
        if (value is null || value.Length > 512 || value.Any(char.IsControl)) return null;
        return value;
    }

}

public sealed record StorageCapacityStatus(long? AvailableBytes, RecordingStorageDecision Decision)
{
    public bool CanStart => Decision != RecordingStorageDecision.Stop;
    public bool ShouldWarn => Decision is RecordingStorageDecision.Warn or RecordingStorageDecision.AudioOnly;
}
