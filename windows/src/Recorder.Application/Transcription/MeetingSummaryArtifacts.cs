using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Recorder.Core;
using TeamsRecorder.Windows.Application.AI;
using TeamsRecorder.Windows.Application.Storage;

namespace TeamsRecorder.Windows.Application.Transcription;

/// <summary>Session-local state only. It deliberately excludes provider URLs, credentials, and transcript text.</summary>
public sealed record MeetingSummaryState(MeetingSummaryPhase Phase, string Message, DateTimeOffset StartedAt, DateTimeOffset? FinishedAt = null);

public enum MeetingSummaryPhase { Queued, Summarizing, Completed, Failed, Cancelled, Interrupted }

public sealed record MeetingSummaryPublication(int SchemaVersion, DateTimeOffset CreatedAt, string Model, string Summary, IReadOnlyList<string> ActionItems, IReadOnlyList<string> Decisions);

public sealed record PublishedMeetingSummaryArtifacts(string MarkdownPath, string JsonPath, string StatePath);

/// <summary>
/// Publishes AI meeting summaries only into a recorder-owned session. Replacements are staged/atomic,
/// prior regular files are retained in bounded copies, and reparse points are never followed.
/// </summary>
public sealed class MeetingSummaryArtifactPublisher
{
    public const string SummaryMarkdownFileName = "summary.md";
    public const string SummaryJsonFileName = "summary.json";
    public const string StateFileName = "summary-state.json";
    private static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };
    private static readonly Regex Secret = new(@"(?ix)(?:api[_-]?key|token|authorization)\s*[:=]\s*(?:bearer\s+)?\S+|\bsk-[a-z0-9_-]{8,}\b", RegexOptions.Compiled);
    private static readonly Regex WindowsPath = new("(?i)\\b[a-z]:\\\\[^\\r\\n\\\"']+", RegexOptions.Compiled);
    private readonly int maximumBackupsPerArtifact;

    public MeetingSummaryArtifactPublisher(int maximumBackupsPerArtifact = 3) =>
        this.maximumBackupsPerArtifact = Math.Max(0, maximumBackupsPerArtifact);

    /// <summary>Reads only the canonical transcript published by this application for this session.</summary>
    public async Task<string> ReadOwnedTranscriptAsync(RecordingSessionPlan plan, CancellationToken cancellationToken = default)
    {
        var folder = ValidatePlan(plan);
        var path = Path.Combine(folder, TranscriptionArtifactPublisher.TranscriptFileName);
        if (!File.Exists(path)) throw new IOException("No canonical transcript is available for this recording session.");
        EnsureSafeRegularFile(path, TranscriptionArtifactPublisher.TranscriptFileName);
        await using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 81920, useAsync: true);
        if (input.Length > OpenAiCompatibleMeetingSummaryClient.MaximumTranscriptBytes)
            throw new MeetingSummaryException(MeetingSummaryErrorKind.TranscriptTooLarge, "The canonical transcript exceeds the AI summary limit.");
        using var output = new MemoryStream((int)input.Length);
        await input.CopyToAsync(output, cancellationToken).ConfigureAwait(false);
        return Encoding.UTF8.GetString(output.ToArray());
    }

    public Task SaveStateAsync(RecordingSessionPlan plan, MeetingSummaryState state, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(state);
        var folder = ValidatePlan(plan);
        var safe = state with { Message = SanitizeDiagnosticText(state.Message, 500) };
        return AtomicWriteWithBackupAsync(folder, StateFileName, JsonSerializer.SerializeToUtf8Bytes(safe, Json), cancellationToken);
    }

    public MeetingSummaryState? LoadState(RecordingSessionPlan plan)
    {
        var folder = ValidatePlan(plan);
        var path = Path.Combine(folder, StateFileName);
        if (!File.Exists(path)) return null;
        EnsureSafeRegularFile(path, StateFileName);
        return JsonSerializer.Deserialize<MeetingSummaryState>(File.ReadAllText(path), Json);
    }

    public async Task<PublishedMeetingSummaryArtifacts> PublishAsync(RecordingSessionPlan plan, string model, MeetingSummary summary, DateTimeOffset? now = null, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(summary);
        var folder = ValidatePlan(plan);
        var publication = SanitizePublication(new MeetingSummaryPublication(1, now ?? DateTimeOffset.UtcNow, model, summary.Summary, summary.ActionItems, summary.Decisions));
        var content = new Dictionary<string, byte[]>(StringComparer.Ordinal)
        {
            [SummaryMarkdownFileName] = Encoding.UTF8.GetBytes(ToMarkdown(publication)),
            [SummaryJsonFileName] = JsonSerializer.SerializeToUtf8Bytes(publication, Json)
        };
        var timestamp = publication.CreatedAt.ToUniversalTime().ToString("yyyyMMddHHmmssfff", System.Globalization.CultureInfo.InvariantCulture);
        var staging = Path.Combine(folder, ".summary-publish-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(staging);
        try
        {
            foreach (var (name, bytes) in content)
                await AtomicWriteAsync(Path.Combine(staging, name), bytes, cancellationToken).ConfigureAwait(false);
            foreach (var name in content.Keys)
            {
                var destination = Path.Combine(folder, name);
                if (!File.Exists(destination)) continue;
                EnsureSafeRegularFile(destination, name);
                File.Copy(destination, Path.Combine(folder, $"{name}.previous-{timestamp}-{Guid.NewGuid():N}"), false);
            }
            foreach (var (name, bytes) in content)
            {
                await AtomicWriteAsync(Path.Combine(folder, name), bytes, cancellationToken).ConfigureAwait(false);
                PruneBackups(folder, name);
            }
        }
        finally
        {
            if (Directory.Exists(staging) && !IsReparsePoint(staging)) Directory.Delete(staging, recursive: true);
        }
        return new(Path.Combine(folder, SummaryMarkdownFileName), Path.Combine(folder, SummaryJsonFileName), Path.Combine(folder, StateFileName));
    }

    private static MeetingSummaryPublication SanitizePublication(MeetingSummaryPublication source) => new(
        1, source.CreatedAt, BoundedText(source.Model, 128), BoundedText(source.Summary, 16 * 1024),
        BoundedList(source.ActionItems, 64, 1024), BoundedList(source.Decisions, 64, 1024));

    private static IReadOnlyList<string> BoundedList(IReadOnlyList<string>? values, int maximumCount, int maximumLength) =>
        (values ?? Array.Empty<string>()).Take(maximumCount).Select(value => BoundedText(value, maximumLength)).Where(value => value.Length > 0).ToArray();

    private static string ToMarkdown(MeetingSummaryPublication value)
    {
        var output = new StringBuilder("# Meeting summary\n\n").AppendLine(value.Summary.Trim()).AppendLine();
        AppendSection(output, "Action items", value.ActionItems);
        AppendSection(output, "Decisions", value.Decisions);
        return output.ToString();
    }

    private static void AppendSection(StringBuilder output, string title, IReadOnlyList<string> items)
    {
        if (items.Count == 0) return;
        output.Append("## ").AppendLine(title);
        foreach (var item in items) output.Append("- ").AppendLine(item);
        output.AppendLine();
    }

    private void PruneBackups(string folder, string name)
    {
        var backups = Directory.EnumerateFiles(folder, name + ".previous-*")
            .Where(path => !IsReparsePoint(path) && (File.GetAttributes(path) & FileAttributes.Directory) == 0)
            .OrderByDescending(Path.GetFileName, StringComparer.Ordinal)
            .Skip(maximumBackupsPerArtifact);
        foreach (var backup in backups) File.Delete(backup);
    }

    private async Task AtomicWriteWithBackupAsync(string folder, string name, byte[] contents, CancellationToken cancellationToken)
    {
        var destination = Path.Combine(folder, name);
        if (File.Exists(destination))
        {
            EnsureSafeRegularFile(destination, name);
            var stamp = DateTimeOffset.UtcNow.ToString("yyyyMMddHHmmssfff", System.Globalization.CultureInfo.InvariantCulture);
            File.Copy(destination, Path.Combine(folder, $"{name}.previous-{stamp}-{Guid.NewGuid():N}"), false);
        }
        await AtomicWriteAsync(destination, contents, cancellationToken).ConfigureAwait(false);
        PruneBackups(folder, name);
    }

    private static string ValidatePlan(RecordingSessionPlan plan)
    {
        ArgumentNullException.ThrowIfNull(plan);
        var folder = Path.GetFullPath(plan.FolderPath);
        if (!Directory.Exists(folder) || IsReparsePoint(folder) || !RecordingSessionLayout.TryGetKind(Path.GetFileName(folder), out var kind) || kind != plan.Kind)
            throw new IOException("Meeting summary artifacts may only be written to an owned recording session folder.");
        if (!Path.GetFullPath(plan.FinalAudioPath).StartsWith(folder + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
            !Path.GetFullPath(plan.MetadataPath).StartsWith(folder + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new IOException("The recording session plan does not own its declared paths.");
        return folder;
    }

    private static async Task AtomicWriteAsync(string path, byte[] contents, CancellationToken cancellationToken)
    {
        if (File.Exists(path)) EnsureSafeRegularFile(path, Path.GetFileName(path));
        var temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            await File.WriteAllBytesAsync(temporary, contents, cancellationToken).ConfigureAwait(false);
            File.Move(temporary, path, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    private static void EnsureSafeRegularFile(string path, string name)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
            throw new IOException($"Refusing to use unsafe meeting-summary artifact {name}.");
    }

    private static bool IsReparsePoint(string path) => (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
    private static string BoundedText(string? value, int maximum)
    {
        var normalized = (value ?? string.Empty).Replace('\r', ' ').Replace('\n', ' ').Trim();
        return normalized[..Math.Min(normalized.Length, maximum)];
    }
    private static string SanitizeDiagnosticText(string? value, int maximum) =>
        BoundedText(WindowsPath.Replace(Secret.Replace(value ?? string.Empty, "[redacted-secret]"), "[redacted-path]"), maximum);
}

public delegate Task<MeetingSummary> MeetingSummaryInvoker(OpenAICompatibleProviderSnapshot snapshot, MeetingSummaryRequest request, CancellationToken cancellationToken);

/// <summary>Coordinates an explicitly-consented summary request with owned-session artifact publication.</summary>
public sealed class MeetingSummaryCoordinator
{
    private readonly MeetingSummaryInvoker summarize;
    private readonly MeetingSummaryArtifactPublisher publisher;

    public MeetingSummaryCoordinator(OpenAiCompatibleMeetingSummaryClient client, MeetingSummaryArtifactPublisher? publisher = null)
    {
        ArgumentNullException.ThrowIfNull(client);
        summarize = client.SummarizeAsync;
        this.publisher = publisher ?? new MeetingSummaryArtifactPublisher();
    }

    public MeetingSummaryCoordinator(MeetingSummaryInvoker summarize, MeetingSummaryArtifactPublisher? publisher = null)
    {
        this.summarize = summarize ?? throw new ArgumentNullException(nameof(summarize));
        this.publisher = publisher ?? new MeetingSummaryArtifactPublisher();
    }

    public async Task<PublishedMeetingSummaryArtifacts> SummarizeAndPublishAsync(RecordingSessionPlan plan, OpenAICompatibleProviderSnapshot snapshot, bool userConsentGranted, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        if (!userConsentGranted) throw new MeetingSummaryException(MeetingSummaryErrorKind.ConsentRequired, "Explicit user consent is required before a transcript is sent to an AI provider.");
        var startedAt = DateTimeOffset.UtcNow;
        await publisher.SaveStateAsync(plan, new(MeetingSummaryPhase.Summarizing, "Preparing an explicitly-consented meeting summary.", startedAt), cancellationToken).ConfigureAwait(false);
        try
        {
            var transcript = await publisher.ReadOwnedTranscriptAsync(plan, cancellationToken).ConfigureAwait(false);
            var result = await summarize(snapshot, new MeetingSummaryRequest(transcript, true), cancellationToken).ConfigureAwait(false);
            var artifacts = await publisher.PublishAsync(plan, snapshot.Profile.LlmModel, result, cancellationToken: cancellationToken).ConfigureAwait(false);
            await publisher.SaveStateAsync(plan, new(MeetingSummaryPhase.Completed, "Meeting summary completed.", startedAt, DateTimeOffset.UtcNow), cancellationToken).ConfigureAwait(false);
            return artifacts;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            await TrySaveTerminalStateAsync(plan, new(MeetingSummaryPhase.Cancelled, "Meeting summary cancelled.", startedAt, DateTimeOffset.UtcNow)).ConfigureAwait(false);
            throw;
        }
        catch (Exception error)
        {
            var message = error is MeetingSummaryException summary
                ? "Meeting summary failed: " + summary.Kind + "."
                : "Meeting summary did not complete.";
            await TrySaveTerminalStateAsync(plan, new(MeetingSummaryPhase.Failed, message, startedAt, DateTimeOffset.UtcNow)).ConfigureAwait(false);
            throw;
        }
    }

    private async Task TrySaveTerminalStateAsync(RecordingSessionPlan plan, MeetingSummaryState state)
    {
        try { await publisher.SaveStateAsync(plan, state).ConfigureAwait(false); }
        catch (IOException) { /* Preserve the original request error when session evidence cannot be safely updated. */ }
    }
}
