using System.Globalization;
using System.Text;
using System.Text.Json;
using Recorder.Core;
using TeamsRecorder.Windows.Application.Storage;
using TeamsRecorder.Windows.Application.Transcription;

namespace TeamsRecorder.Windows.Application.Library;

/// <summary>
/// Immutable identity captured when a library row is projected.  It is deliberately
/// more specific than a path: every action re-resolves this fingerprint against a
/// fresh library enumeration before it opens, changes, or recycles a session.
/// </summary>
public sealed record RecordingLibrarySessionIdentity(
    string FolderPath,
    string MediaPath,
    long MediaLength,
    long MediaCreationUtcTicks,
    long MediaLastWriteUtcTicks,
    long? MetadataLastWriteUtcTicks,
    bool IsManaged)
{
    public static RecordingLibrarySessionIdentity Create(RecordingSessionLibraryItem item)
    {
        ArgumentNullException.ThrowIfNull(item);
        var media = new FileInfo(item.MediaPath);
        if (!media.Exists)
        {
            throw new FileNotFoundException("The recording media disappeared while the library was being read.", item.MediaPath);
        }

        long? metadataTicks = null;
        if (item.IsManaged)
        {
            var metadataPath = Path.Combine(item.FolderPath, RecordingSessionLayout.MetadataFileName);
            if (File.Exists(metadataPath) && IsSafeRegularFile(metadataPath))
            {
                metadataTicks = File.GetLastWriteTimeUtc(metadataPath).Ticks;
            }
        }

        return new(
            Path.GetFullPath(item.FolderPath),
            Path.GetFullPath(item.MediaPath),
            media.Length,
            media.CreationTimeUtc.Ticks,
            media.LastWriteTimeUtc.Ticks,
            metadataTicks,
            item.IsManaged);
    }

    public bool Matches(RecordingSessionLibraryItem item)
    {
        ArgumentNullException.ThrowIfNull(item);
        try
        {
            if (item.IsManaged != IsManaged ||
                !PathEquals(FolderPath, item.FolderPath) ||
                !PathEquals(MediaPath, item.MediaPath))
            {
                return false;
            }

            var current = Create(item);
            return current.MediaLength == MediaLength &&
                   current.MediaCreationUtcTicks == MediaCreationUtcTicks &&
                   current.MediaLastWriteUtcTicks == MediaLastWriteUtcTicks &&
                   current.MetadataLastWriteUtcTicks == MetadataLastWriteUtcTicks;
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
        catch (ArgumentException) { return false; }
    }

    private static bool PathEquals(string left, string right) =>
        string.Equals(Path.GetFullPath(left), Path.GetFullPath(right), StringComparison.OrdinalIgnoreCase);

    internal static bool IsSafeRegularFile(string path)
    {
        try
        {
            var attributes = File.GetAttributes(path);
            return (attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) == 0;
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }
}

/// <summary>
/// Bounded, local-only search projection.  The search index never follows a
/// reparse point and reads at most four MiB of a session's canonical transcript.
/// </summary>
public sealed class RecordingLibrarySearchDocument
{
    public const int MaximumTranscriptBytes = 4 * 1024 * 1024;

    private RecordingLibrarySearchDocument(string metadataText, string transcriptText)
    {
        MetadataText = metadataText;
        TranscriptText = transcriptText;
        NormalizedText = Normalize(metadataText + "\n" + transcriptText);
    }

    public string MetadataText { get; }

    public string TranscriptText { get; }

    public string NormalizedText { get; }

    public bool HasTranscript => !string.IsNullOrWhiteSpace(TranscriptText);

    public static RecordingLibrarySearchDocument Create(
        RecordingSessionLibraryItem item,
        string displayName)
    {
        ArgumentNullException.ThrowIfNull(item);
        var metadata = string.Join("\n", new[]
        {
            displayName,
            item.Metadata.Title ?? string.Empty,
            string.Join(" ", item.Metadata.Tags),
            item.Metadata.Source,
            item.Kind.ToString(),
        });

        var transcript = item.IsManaged
            ? ReadCanonicalTranscript(item.FolderPath)
            : string.Empty;
        return new RecordingLibrarySearchDocument(metadata, transcript);
    }

    public bool Matches(string? query)
    {
        var needle = Normalize(query ?? string.Empty).Trim();
        return needle.Length == 0 || NormalizedText.Contains(needle, StringComparison.Ordinal);
    }

    public string? TranscriptSnippet(string? query, int maximumCharacters = 220)
    {
        if (maximumCharacters < 1 || string.IsNullOrWhiteSpace(query) || string.IsNullOrWhiteSpace(TranscriptText))
        {
            return null;
        }

        var match = TranscriptText.IndexOf(query.Trim(), StringComparison.OrdinalIgnoreCase);
        if (match < 0)
        {
            // For case/diacritic/width-insensitive metadata matching, avoid
            // inventing a transcript offset when the original scalar sequence
            // cannot be located safely.
            return null;
        }

        var matchLength = Math.Min(query.Trim().Length, TranscriptText.Length - match);
        var context = Math.Max(0, (maximumCharacters - matchLength - 2) / 2);
        var start = Math.Max(0, match - context);
        var end = Math.Min(TranscriptText.Length, match + matchLength + context);
        var snippet = TranscriptText[start..end].Trim();
        if (start > 0) snippet = "…" + snippet;
        if (end < TranscriptText.Length) snippet += "…";
        return snippet.Length <= maximumCharacters
            ? snippet
            : snippet[..maximumCharacters].TrimEnd() + "…";
    }

    private static string ReadCanonicalTranscript(string folderPath)
    {
        try
        {
            var path = Path.Combine(folderPath, TranscriptionArtifactPublisher.TranscriptFileName);
            if (!File.Exists(path) || !RecordingLibrarySessionIdentity.IsSafeRegularFile(path))
            {
                return string.Empty;
            }

            var info = new FileInfo(path);
            if (info.Length > MaximumTranscriptBytes)
            {
                return string.Empty;
            }

            using var stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                16 * 1024,
                FileOptions.SequentialScan);
            using var output = new MemoryStream((int)Math.Min(stream.Length, MaximumTranscriptBytes));
            stream.CopyTo(output);
            if (output.Length > MaximumTranscriptBytes)
            {
                return string.Empty;
            }

            return new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: false)
                .GetString(output.GetBuffer(), 0, (int)output.Length);
        }
        catch (IOException) { return string.Empty; }
        catch (UnauthorizedAccessException) { return string.Empty; }
        catch (ArgumentException) { return string.Empty; }
    }

    internal static string Normalize(string value)
    {
        if (string.IsNullOrEmpty(value)) return string.Empty;
        var builder = new StringBuilder(value.Length);
        foreach (var character in value.Normalize(NormalizationForm.FormKD))
        {
            if (CharUnicodeInfo.GetUnicodeCategory(character) is not UnicodeCategory.NonSpacingMark and not UnicodeCategory.SpacingCombiningMark)
            {
                builder.Append(character);
            }
        }

        return builder.ToString().ToUpperInvariant();
    }
}

/// <summary>
/// Small, non-sensitive artifact projection for library chips.  It reads only
/// app-owned file names and bounded JSON state; no transcript, prompt, provider
/// URL, or credential is exposed by the library list.
/// </summary>
public sealed record RecordingLibraryArtifactStatus(
    bool HasTranscript,
    string? TranscriptionPhase,
    string? MeetingIntelligenceState)
{
    public static RecordingLibraryArtifactStatus Empty { get; } = new(false, null, null);

    public bool HasAiArtifact => HasTranscript || !string.IsNullOrWhiteSpace(MeetingIntelligenceState);

    public string? AiChipText => MeetingIntelligenceState?.ToLowerInvariant() switch
    {
        "ready" => "AI 摘要",
        "generating" or "checking" => "AI 處理中",
        "stale" => "AI 需要重產生",
        "failed" or "cancelled" or "interrupted" => "AI 需要注意",
        _ when HasTranscript => TranscriptionPhase?.ToLowerInvariant() switch
        {
            "queued" or "uploading" or "transcribing" => "轉錄中",
            "failed" or "cancelled" or "interrupted" => "轉錄需要注意",
            _ => "逐字稿",
        },
        _ => null,
    };

    public static RecordingLibraryArtifactStatus Read(string folderPath, bool isManaged)
    {
        if (!isManaged) return Empty;
        var transcript = SafeFileExists(Path.Combine(folderPath, TranscriptionArtifactPublisher.TranscriptFileName));
        return new(
            transcript,
            ReadState(Path.Combine(folderPath, TranscriptionArtifactPublisher.StateFileName), "phase"),
            ReadState(Path.Combine(folderPath, MeetingIntelligenceArtifactPublisher.StateFileName), "state"));
    }

    private static bool SafeFileExists(string path) =>
        File.Exists(path) && RecordingLibrarySessionIdentity.IsSafeRegularFile(path);

    private static string? ReadState(string path, string propertyName)
    {
        try
        {
            if (!SafeFileExists(path) || new FileInfo(path).Length > 16 * 1024)
            {
                return null;
            }

            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 4096, FileOptions.SequentialScan);
            using var document = JsonDocument.Parse(stream);
            return document.RootElement.TryGetProperty(propertyName, out var property) &&
                   property.ValueKind == JsonValueKind.String
                ? property.GetString()?.Trim()
                : null;
        }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
        catch (JsonException) { return null; }
    }
}
