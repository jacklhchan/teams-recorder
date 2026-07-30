using System.Text.Json.Nodes;
using System.Text.Json;

namespace Recorder.Core;

public enum RecordingSessionKind { Meeting, Test, Manual }

public enum RecordingRecoveryState { None, VideoLostAudioPreserved, RecoveredAfterInterruption }

public static class RecordingSessionLayout
{
    public const string FinalAudioFileName = "recording.m4a";
    public const string BackupAudioFileName = "recording.audio-backup.m4a";
    public const string PartialAudioFileName = "recording.audio-backup.m4a.partial";
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
    JsonObject Document)
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
        return new RecordingInfo(title, tags, favorite, mediaKind, recovery, sessionSource, participants.DeepClone() as JsonArray ?? new JsonArray(), schemaVersion, document);
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
            document);
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
}

public sealed record StorageCapacityStatus(long? AvailableBytes, RecordingStorageDecision Decision)
{
    public bool CanStart => Decision != RecordingStorageDecision.Stop;
    public bool ShouldWarn => Decision is RecordingStorageDecision.Warn or RecordingStorageDecision.AudioOnly;
}
