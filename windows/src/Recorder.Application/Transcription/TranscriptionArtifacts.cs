using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Recorder.Core;
using TeamsRecorder.Windows.Application.Storage;

namespace TeamsRecorder.Windows.Application.Transcription;

/// <summary>Durable, session-local progress. This deliberately never contains a provider URL, API key, or audio path.</summary>
public sealed record TranscriptionState(
    TranscriptionPhase Phase,
    string Message,
    DateTimeOffset StartedAt,
    DateTimeOffset? FinishedAt = null);

public enum TranscriptionPhase { Queued, Uploading, Transcribing, Completed, Failed, Cancelled, Interrupted }

public sealed record TranscriptionPublicationManifest(
    int SchemaVersion,
    DateTimeOffset CreatedAt,
    string Model,
    string Language,
    int ChunkCount,
    IReadOnlyList<string> ResponseFormats)
{
    public TranscriptionPublicationManifest(string model, string language, int chunkCount, IReadOnlyList<string> responseFormats)
        : this(1, DateTimeOffset.UtcNow, model, language, chunkCount, responseFormats) { }
}

public sealed record PublishedTranscriptionArtifacts(string TranscriptPath, string RawTranscriptPath, string ManifestPath, string LogPath);

/// <summary>
/// Owns the portable transcription files inside a session folder. All replacement is staged and
/// previous regular files are retained as bounded backups; reparse points are never followed.
/// </summary>
public sealed class TranscriptionArtifactPublisher
{
    public const string StateFileName = "transcription-state.json";
    public const string TranscriptFileName = "transcript.txt";
    public const string RawTranscriptFileName = "transcript.raw.txt";
    public const string ManifestFileName = "transcription.json";
    public const string LogFileName = "transcription.log";
    private static readonly string[] CanonicalNames = [TranscriptFileName, RawTranscriptFileName, ManifestFileName, LogFileName, StateFileName];
    private static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };
    private static readonly Regex Secret = new(@"(?ix)(?:api[_-]?key|token|authorization)\s*[:=]\s*(?:bearer\s+)?\S+|\bsk-[a-z0-9_-]{8,}\b", RegexOptions.Compiled);
    private static readonly Regex WindowsPath = new("(?i)\\b[a-z]:\\\\[^\\r\\n\\\"']+", RegexOptions.Compiled);
    private readonly int maximumBackupsPerArtifact;

    public TranscriptionArtifactPublisher(int maximumBackupsPerArtifact = 3) =>
        this.maximumBackupsPerArtifact = Math.Max(0, maximumBackupsPerArtifact);

    public Task SaveStateAsync(RecordingSessionPlan plan, TranscriptionState state, CancellationToken cancellationToken = default)
    {
        var folder = ValidatePlan(plan);
        cancellationToken.ThrowIfCancellationRequested();
        var safeState = state with { Message = SanitizeDiagnosticText(state.Message, 1_000) };
        return AtomicWriteAsync(Path.Combine(folder, StateFileName), JsonSerializer.SerializeToUtf8Bytes(safeState, Json), cancellationToken);
    }

    public TranscriptionState? LoadState(RecordingSessionPlan plan)
    {
        var folder = ValidatePlan(plan);
        var path = Path.Combine(folder, StateFileName);
        if (!File.Exists(path)) return null;
        EnsureSafeRegularFile(path, StateFileName);
        return JsonSerializer.Deserialize<TranscriptionState>(File.ReadAllText(path), Json);
    }

    public async Task<PublishedTranscriptionArtifacts> PublishAsync(
        RecordingSessionPlan plan,
        string rawText,
        string finalText,
        TranscriptionPublicationManifest manifest,
        IEnumerable<string>? logLines = null,
        DateTimeOffset? now = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(manifest);
        var folder = ValidatePlan(plan);
        var timestamp = (now ?? DateTimeOffset.UtcNow).ToUniversalTime().ToString("yyyyMMddHHmmssfff", System.Globalization.CultureInfo.InvariantCulture);
        var content = new Dictionary<string, byte[]>(StringComparer.Ordinal)
        {
            [RawTranscriptFileName] = Encoding.UTF8.GetBytes(rawText ?? string.Empty),
            [TranscriptFileName] = Encoding.UTF8.GetBytes(finalText ?? string.Empty),
            [ManifestFileName] = JsonSerializer.SerializeToUtf8Bytes(SanitizeManifest(manifest), Json),
            [LogFileName] = Encoding.UTF8.GetBytes(SanitizeLog(logLines).ToString())
        };
        var staging = Path.Combine(folder, ".transcription-publish-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(staging);
        try
        {
            foreach (var (name, bytes) in content)
            {
                cancellationToken.ThrowIfCancellationRequested();
                await AtomicWriteAsync(Path.Combine(staging, name), bytes, cancellationToken).ConfigureAwait(false);
            }
            foreach (var name in content.Keys)
            {
                var destination = Path.Combine(folder, name);
                if (File.Exists(destination))
                {
                    EnsureSafeRegularFile(destination, name);
                    File.Copy(destination, Path.Combine(folder, $"{name}.previous-{timestamp}-{Guid.NewGuid():N}"), false);
                }
            }
            foreach (var (name, bytes) in content)
            {
                cancellationToken.ThrowIfCancellationRequested();
                await AtomicWriteAsync(Path.Combine(folder, name), bytes, cancellationToken).ConfigureAwait(false);
                PruneBackups(folder, name);
            }
        }
        finally
        {
            // This is the exact GUID-named staging directory created above. It may
            // still contain a temporary file after an interrupted staged write, so
            // remove only this verified non-reparse directory recursively.
            if (Directory.Exists(staging) && !IsReparsePoint(staging)) Directory.Delete(staging, recursive: true);
        }
        return new(Path.Combine(folder, TranscriptFileName), Path.Combine(folder, RawTranscriptFileName), Path.Combine(folder, ManifestFileName), Path.Combine(folder, LogFileName));
    }

    public async Task<TranscriptionState?> MarkInterruptedIfNeededAsync(RecordingSessionPlan plan, DateTimeOffset? now = null, CancellationToken cancellationToken = default)
    {
        var state = LoadState(plan);
        if (state is null || state.Phase is not (TranscriptionPhase.Queued or TranscriptionPhase.Uploading or TranscriptionPhase.Transcribing)) return state;
        var interrupted = state with { Phase = TranscriptionPhase.Interrupted, Message = "Transcription interrupted. You can start it again.", FinishedAt = now ?? DateTimeOffset.UtcNow };
        await SaveStateAsync(plan, interrupted, cancellationToken).ConfigureAwait(false);
        return interrupted;
    }

    private static TranscriptionPublicationManifest SanitizeManifest(TranscriptionPublicationManifest manifest) => new(
        Math.Max(1, manifest.SchemaVersion), manifest.CreatedAt, BoundedText(manifest.Model, 128), BoundedText(manifest.Language, 32), Math.Max(0, manifest.ChunkCount),
        manifest.ResponseFormats.Take(8).Select(x => BoundedText(x, 64)).ToArray());

    private static StringBuilder SanitizeLog(IEnumerable<string>? lines)
    {
        var output = new StringBuilder();
        if (lines is null) return output;
        foreach (var line in lines)
        {
            var cleaned = SanitizeDiagnosticText(line, 1_000);
            if (output.Length + cleaned.Length + 1 > 64 * 1024) break;
            output.AppendLine(cleaned);
        }
        return output;
    }

    private static string BoundedText(string? value, int max) => (value ?? string.Empty).Replace('\r', ' ').Replace('\n', ' ').Trim()[..Math.Min((value ?? string.Empty).Replace('\r', ' ').Replace('\n', ' ').Trim().Length, max)];

    private static string SanitizeDiagnosticText(string? value, int max) =>
        BoundedText(WindowsPath.Replace(Secret.Replace((value ?? string.Empty).Replace('\r', ' ').Replace('\n', ' '), "[redacted-secret]"), "[redacted-path]"), max);

    private void PruneBackups(string folder, string name)
    {
        var prefix = name + ".previous-";
        var backups = Directory.EnumerateFiles(folder, prefix + "*")
            .Where(path => !IsReparsePoint(path) && (File.GetAttributes(path) & FileAttributes.Directory) == 0)
            .OrderByDescending(Path.GetFileName, StringComparer.Ordinal)
            .Skip(maximumBackupsPerArtifact);
        foreach (var backup in backups) File.Delete(backup);
    }

    private static string ValidatePlan(RecordingSessionPlan plan)
    {
        ArgumentNullException.ThrowIfNull(plan);
        var folder = Path.GetFullPath(plan.FolderPath);
        if (!Directory.Exists(folder) || IsReparsePoint(folder) || !RecordingSessionLayout.TryGetKind(Path.GetFileName(folder), out var kind) || kind != plan.Kind)
            throw new IOException("Transcription artifacts may only be written to an owned recording session folder.");
        if (!Path.GetFullPath(plan.FinalAudioPath).StartsWith(folder + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
            !Path.GetFullPath(plan.MetadataPath).StartsWith(folder + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new IOException("The recording session plan does not own its declared paths.");
        return folder;
    }

    private static async Task AtomicWriteAsync(string path, byte[] contents, CancellationToken cancellationToken)
    {
        if (File.Exists(path)) EnsureSafeRegularFile(path, Path.GetFileName(path));
        var temp = path + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            await File.WriteAllBytesAsync(temp, contents, cancellationToken).ConfigureAwait(false);
            File.Move(temp, path, true);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }

    private static void EnsureSafeRegularFile(string path, string name)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
            throw new IOException($"Refusing to replace unsafe transcription artifact {name}.");
    }

    private static bool IsReparsePoint(string path) => (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
}

/// <summary>Startup hook for callers that already enumerate their owned session plans.</summary>
public sealed class TranscriptionRecoveryService
{
    private readonly TranscriptionArtifactPublisher publisher;
    public TranscriptionRecoveryService(TranscriptionArtifactPublisher? publisher = null) => this.publisher = publisher ?? new();

    public async Task<IReadOnlyList<string>> MarkInterruptedAsync(IEnumerable<RecordingSessionPlan> plans, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(plans);
        var interrupted = new List<string>();
        foreach (var plan in plans)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var state = await publisher.MarkInterruptedIfNeededAsync(plan, cancellationToken: cancellationToken).ConfigureAwait(false);
            if (state?.Phase == TranscriptionPhase.Interrupted) interrupted.Add(plan.FolderPath);
        }
        return interrupted;
    }
}
