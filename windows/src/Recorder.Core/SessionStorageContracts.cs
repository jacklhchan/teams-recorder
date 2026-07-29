using System.Text.Json.Nodes;
using System.Text.Json;

namespace Recorder.Core;

public enum RecordingSessionKind { Meeting, Test, Manual }

public enum RecordingRecoveryState { None, VideoLostAudioPreserved, RecoveredAfterInterruption }

public static class RecordingSessionLayout
{
    public const string FinalAudioFileName = "recording.m4a";
    public const string BackupAudioFileName = "recording.audio-backup.m4a";
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
    JsonObject Document)
{
    public static RecordingInfo AudioOnly(string? title = null) =>
        RecordingInfoJson.CreateAudioOnly(null, title, RecordingRecoveryState.None);
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
        document["schemaVersion"] = 1;
        if (title is null) document.Remove("title"); else document["title"] = title;
        document["tags"] = new JsonArray(tags.Select(tag => JsonValue.Create(tag)).ToArray());
        document["isFavorite"] = favorite;
        document["mediaKind"] = mediaKind;
        document["recoveryState"] = RecoveryText(recovery);
        return new RecordingInfo(title, tags, favorite, mediaKind, recovery, document);
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
        RecordingRecoveryState recoveryState)
    {
        var normalized = Normalize(source, titleOverride, recoveryState);
        var document = normalized.Document.DeepClone() as JsonObject ?? new JsonObject();
        document["mediaKind"] = "audio";
        document["screenIntervals"] = new JsonArray();
        document.Remove("capturedTeamsWindow");
        return new RecordingInfo(
            normalized.Title,
            normalized.Tags,
            normalized.IsFavorite,
            "audio",
            recoveryState,
            document);
    }

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
}

public sealed record StorageCapacityStatus(long? AvailableBytes, RecordingStorageDecision Decision)
{
    public bool CanStart => Decision != RecordingStorageDecision.Stop;
    public bool ShouldWarn => Decision is RecordingStorageDecision.Warn or RecordingStorageDecision.AudioOnly;
}
