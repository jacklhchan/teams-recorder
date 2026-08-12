using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Recorder.Core;
using TeamsRecorder.Windows.Application.AI;
using TeamsRecorder.Windows.Application.Storage;

namespace TeamsRecorder.Windows.Application.Transcription;

public enum MeetingIntelligenceContentOrigin { Generated, Edited }
public enum MeetingIntelligenceGenerationIntent { Automatic, Generate, Regenerate, RetryGeneration }

public sealed record MeetingIntelligenceArtifact(
    int SchemaVersion,
    string Summary,
    string SuggestedTitle,
    string SourceTranscriptSha256,
    int SourceTranscriptByteCount,
    string Model,
    DateTimeOffset GeneratedAt,
    MeetingIntelligenceGenerationIntent Intent,
    MeetingIntelligenceContentOrigin ContentOrigin,
    DateTimeOffset? EditedAt)
{
    public const int CurrentSchemaVersion = 2;
}

public enum MeetingIntelligenceSessionState
{
    NotGenerated,
    Checking,
    Generating,
    Ready,
    Stale,
    Interrupted,
    NeedsAttention,
}

public sealed record MeetingIntelligenceStateDocument(
    int SchemaVersion,
    MeetingIntelligenceSessionState State,
    string Message,
    string? SourceTranscriptSha256,
    long Generation,
    DateTimeOffset StartedAt,
    DateTimeOffset? FinishedAt = null)
{
    public const int CurrentSchemaVersion = 1;
}

public sealed record PublishedMeetingIntelligenceArtifact(string ArtifactPath, string StatePath, MeetingIntelligenceArtifact Artifact);

public interface IMeetingIntelligenceCanonicalTranscriptReader
{
    Task<MeetingIntelligenceCanonicalTranscript> ReadAsync(RecordingSessionPlan plan, CancellationToken cancellationToken = default);
}

/// <summary>Reads only the app-owned canonical transcript.txt with strict UTF-8 and a 4 MiB + 1 overflow probe.</summary>
public sealed class MeetingIntelligenceCanonicalTranscriptReader : IMeetingIntelligenceCanonicalTranscriptReader
{
    public async Task<MeetingIntelligenceCanonicalTranscript> ReadAsync(RecordingSessionPlan plan, CancellationToken cancellationToken = default)
    {
        var folder = MeetingIntelligenceArtifactPublisher.ValidatePlan(plan);
        var path = Path.Combine(folder, TranscriptionArtifactPublisher.TranscriptFileName);
        if (!File.Exists(path)) throw new IOException("No canonical transcript is available for this recording session.");
        MeetingIntelligenceArtifactPublisher.EnsureSafeRegularFile(path, TranscriptionArtifactPublisher.TranscriptFileName);
        var before = new FileInfo(path);
        if (before.Length > MeetingIntelligencePipeline.MaximumSourceBytes)
            throw new MeetingIntelligencePipelineException(MeetingIntelligencePipelineFailure.SourceTooLarge, "The canonical transcript exceeds 4 MiB.");
        await using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
            64 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
        using var output = new MemoryStream((int)Math.Min(input.Length, MeetingIntelligencePipeline.MaximumSourceBytes));
        var buffer = new byte[64 * 1024];
        int read;
        while ((read = await input.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) != 0)
        {
            if (output.Length + read > MeetingIntelligencePipeline.MaximumSourceBytes)
                throw new MeetingIntelligencePipelineException(MeetingIntelligencePipelineFailure.SourceTooLarge, "The canonical transcript exceeds 4 MiB.");
            output.Write(buffer, 0, read);
        }
        var bytes = output.ToArray();
        string text;
        try { text = new UTF8Encoding(false, true).GetString(bytes); }
        catch (DecoderFallbackException error)
        {
            throw new MeetingIntelligencePipelineException(MeetingIntelligencePipelineFailure.InvalidSource, "The canonical transcript is not valid UTF-8.") { Data = { ["decoder"] = error.GetType().Name } };
        }
        if (string.IsNullOrWhiteSpace(text))
            throw new MeetingIntelligencePipelineException(MeetingIntelligencePipelineFailure.InvalidSource, "The canonical transcript is empty.");
        MeetingIntelligenceArtifactPublisher.EnsureSafeRegularFile(path, TranscriptionArtifactPublisher.TranscriptFileName);
        var after = new FileInfo(path);
        if (before.Length != after.Length || before.LastWriteTimeUtc != after.LastWriteTimeUtc)
            throw new IOException("The canonical transcript changed while it was being read.");
        return new(text, bytes, MeetingIntelligenceTranscriptRevision.FromBytes(bytes));
    }
}

/// <summary>Atomic, bounded, session-local persistence with no provider URL, key, prompt, or transcript content.</summary>
public sealed partial class MeetingIntelligenceArtifactPublisher
{
    public const string ArtifactFileName = "meeting-intelligence.json";
    public const string StateFileName = "meeting-intelligence-state.json";
    public const int MaximumArtifactBytes = 256 * 1024;
    public const int MaximumStateBytes = 16 * 1024;
    private static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };
    [GeneratedRegex(@"(?ix)(?:api[_-]?key|token|authorization)\s*[:=]\s*(?:bearer\s+)?\S+|\bsk-[a-z0-9_-]{8,}\b")]
    private static partial Regex Secret();
    [GeneratedRegex("(?i)\\b[a-z]:\\\\[^\\r\\n\\\"']+")]
    private static partial Regex WindowsPath();
    private readonly int maximumBackupsPerArtifact;

    public MeetingIntelligenceArtifactPublisher(int maximumBackupsPerArtifact = 3) =>
        this.maximumBackupsPerArtifact = Math.Max(0, maximumBackupsPerArtifact);

    public async Task<MeetingIntelligenceArtifact?> LoadArtifactAsync(RecordingSessionPlan plan, CancellationToken cancellationToken = default)
    {
        var folder = ValidatePlan(plan);
        var path = Path.Combine(folder, ArtifactFileName);
        var data = await ReadBoundedAsync(path, MaximumArtifactBytes, cancellationToken).ConfigureAwait(false);
        if (data is null) return null;
        try
        {
            var artifact = JsonSerializer.Deserialize<MeetingIntelligenceArtifact>(data, Json) ?? throw new JsonException();
            ValidateArtifact(artifact);
            return artifact;
        }
        catch (JsonException error) { throw new IOException("The meeting intelligence artifact is malformed.", error); }
    }

    public async Task<MeetingIntelligenceStateDocument?> LoadStateAsync(RecordingSessionPlan plan, CancellationToken cancellationToken = default)
    {
        var folder = ValidatePlan(plan);
        var data = await ReadBoundedAsync(Path.Combine(folder, StateFileName), MaximumStateBytes, cancellationToken).ConfigureAwait(false);
        if (data is null) return null;
        try
        {
            var state = JsonSerializer.Deserialize<MeetingIntelligenceStateDocument>(data, Json) ?? throw new JsonException();
            if (state.SchemaVersion != MeetingIntelligenceStateDocument.CurrentSchemaVersion) throw new JsonException();
            return state;
        }
        catch (JsonException error) { throw new IOException("The meeting intelligence state is malformed.", error); }
    }

    public async Task SaveStateAsync(RecordingSessionPlan plan, MeetingIntelligenceStateDocument state, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(state);
        var folder = ValidatePlan(plan);
        var safe = state with
        {
            SchemaVersion = MeetingIntelligenceStateDocument.CurrentSchemaVersion,
            Message = SanitizeDiagnostic(state.Message, 1024),
            SourceTranscriptSha256 = IsSha256(state.SourceTranscriptSha256) ? state.SourceTranscriptSha256 : null,
        };
        var bytes = JsonSerializer.SerializeToUtf8Bytes(safe, Json);
        if (bytes.Length > MaximumStateBytes) throw new IOException("The meeting intelligence state exceeds its bound.");
        await AtomicReplaceWithBackupsAsync(folder, StateFileName, bytes, cancellationToken).ConfigureAwait(false);
    }

    public async Task<PublishedMeetingIntelligenceArtifact> PublishAsync(
        RecordingSessionPlan plan,
        MeetingIntelligenceArtifact artifact,
        CancellationToken cancellationToken = default)
    {
        ValidateArtifact(artifact);
        var folder = ValidatePlan(plan);
        var bytes = JsonSerializer.SerializeToUtf8Bytes(artifact, Json);
        if (bytes.Length > MaximumArtifactBytes) throw new IOException("The meeting intelligence artifact exceeds 256 KiB.");
        await AtomicReplaceWithBackupsAsync(folder, ArtifactFileName, bytes, cancellationToken).ConfigureAwait(false);
        return new(Path.Combine(folder, ArtifactFileName), Path.Combine(folder, StateFileName), artifact);
    }

    public async Task<MeetingIntelligenceStateDocument?> MarkInterruptedIfNeededAsync(
        RecordingSessionPlan plan,
        DateTimeOffset? now = null,
        CancellationToken cancellationToken = default)
    {
        var state = await LoadStateAsync(plan, cancellationToken).ConfigureAwait(false);
        if (state is null || state.State is not (MeetingIntelligenceSessionState.Checking or MeetingIntelligenceSessionState.Generating)) return state;
        var interrupted = state with
        {
            State = MeetingIntelligenceSessionState.Interrupted,
            Message = "Meeting intelligence was interrupted. Generate it again when ready.",
            FinishedAt = now ?? DateTimeOffset.UtcNow,
        };
        await SaveStateAsync(plan, interrupted, cancellationToken).ConfigureAwait(false);
        return interrupted;
    }

    internal static string ValidatePlan(RecordingSessionPlan plan)
    {
        ArgumentNullException.ThrowIfNull(plan);
        var folder = Path.GetFullPath(plan.FolderPath);
        if (!Directory.Exists(folder) || IsReparsePoint(folder) ||
            !RecordingSessionLayout.TryGetKind(Path.GetFileName(folder), out var kind) || kind != plan.Kind)
            throw new IOException("Meeting intelligence may only use an owned recording session folder.");
        var prefix = folder + Path.DirectorySeparatorChar;
        if (!Path.GetFullPath(plan.FinalAudioPath).StartsWith(prefix, StringComparison.OrdinalIgnoreCase) ||
            !Path.GetFullPath(plan.MetadataPath).StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            throw new IOException("The recording session plan does not own its declared paths.");
        return folder;
    }

    internal static void EnsureSafeRegularFile(string path, string name)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
            throw new IOException($"Refusing to use unsafe meeting intelligence artifact {name}.");
    }

    private async Task AtomicReplaceWithBackupsAsync(string folder, string name, byte[] bytes, CancellationToken cancellationToken)
    {
        var destination = Path.Combine(folder, name);
        if (File.Exists(destination))
        {
            EnsureSafeRegularFile(destination, name);
            var stamp = DateTimeOffset.UtcNow.ToString("yyyyMMddHHmmssfff", System.Globalization.CultureInfo.InvariantCulture);
            File.Copy(destination, Path.Combine(folder, $"{name}.previous-{stamp}-{Guid.NewGuid():N}"), false);
        }
        var temporary = destination + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            await using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 16 * 1024, FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await stream.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                stream.Flush(flushToDisk: true);
            }
            if (File.Exists(destination)) EnsureSafeRegularFile(destination, name);
            File.Move(temporary, destination, true);
            PruneBackups(folder, name);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    private void PruneBackups(string folder, string name)
    {
        foreach (var path in Directory.EnumerateFiles(folder, name + ".previous-*")
            .Where(path => !IsReparsePoint(path) && (File.GetAttributes(path) & FileAttributes.Directory) == 0)
            .OrderByDescending(Path.GetFileName, StringComparer.Ordinal)
            .Skip(maximumBackupsPerArtifact)) File.Delete(path);
    }

    private static async Task<byte[]?> ReadBoundedAsync(string path, int maximumBytes, CancellationToken cancellationToken)
    {
        if (!File.Exists(path)) return null;
        EnsureSafeRegularFile(path, Path.GetFileName(path));
        await using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 16 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
        if (input.Length > maximumBytes) throw new IOException("The meeting intelligence artifact exceeds its bound.");
        using var output = new MemoryStream((int)input.Length);
        await input.CopyToAsync(output, cancellationToken).ConfigureAwait(false);
        if (output.Length > maximumBytes) throw new IOException("The meeting intelligence artifact exceeds its bound.");
        return output.ToArray();
    }

    private static void ValidateArtifact(MeetingIntelligenceArtifact artifact)
    {
        ArgumentNullException.ThrowIfNull(artifact);
        if (artifact.SchemaVersion is not (1 or MeetingIntelligenceArtifact.CurrentSchemaVersion) ||
            !IsSha256(artifact.SourceTranscriptSha256) ||
            artifact.SourceTranscriptByteCount is < 1 or > MeetingIntelligencePipeline.MaximumSourceBytes ||
            Encoding.UTF8.GetByteCount(artifact.Model ?? string.Empty) is < 1 or > 512 ||
            artifact.ContentOrigin == MeetingIntelligenceContentOrigin.Generated && artifact.EditedAt is not null ||
            artifact.ContentOrigin == MeetingIntelligenceContentOrigin.Edited && artifact.EditedAt is null)
            throw new IOException("The meeting intelligence artifact provenance is invalid.");
        _ = MeetingIntelligenceOutputValidator.ValidateSummary(artifact.Summary);
        _ = MeetingIntelligenceOutputValidator.ValidateTitle(artifact.SuggestedTitle);
    }

    private static bool IsSha256(string? value) => value is { Length: 71 } && value.StartsWith("sha256:", StringComparison.Ordinal) &&
        value.AsSpan(7).ToString().All(character => character is >= '0' and <= '9' or >= 'a' and <= 'f');
    private static string SanitizeDiagnostic(string? value, int maximum) =>
        WindowsPath().Replace(Secret().Replace((value ?? string.Empty).Replace('\r', ' ').Replace('\n', ' '), "[redacted-secret]"), "[redacted-path]")[..Math.Min(maximum, WindowsPath().Replace(Secret().Replace((value ?? string.Empty).Replace('\r', ' ').Replace('\n', ' '), "[redacted-secret]"), "[redacted-path]").Length)];
    private static bool IsReparsePoint(string path) => (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
}

public enum MeetingIntelligenceTitleOrigin { Unset, MeetingIntelligence, Manual }
public sealed record MeetingIntelligenceTitleSnapshot(string? Title, MeetingIntelligenceTitleOrigin Origin, string RevisionToken);
public enum MeetingIntelligenceTitlePublicationOutcome { Applied, Preserved, Conflict, Failed }

/// <summary>
/// Hook implemented by the metadata owner. Capture and compare-and-apply must use the owner's
/// serialized mutation boundary so a manual rename/clear can never be overwritten.
/// </summary>
public interface IMeetingIntelligenceTitlePublisher
{
    Task<MeetingIntelligenceTitleSnapshot> CaptureAsync(RecordingSessionPlan plan, CancellationToken cancellationToken);
    Task<MeetingIntelligenceTitlePublicationOutcome> TryApplyAsync(
        RecordingSessionPlan plan,
        MeetingIntelligenceTitleSnapshot captured,
        string suggestedTitle,
        MeetingIntelligenceTranscriptRevision sourceRevision,
        CancellationToken cancellationToken);
}

public sealed class PreserveMeetingIntelligenceTitlePublisher : IMeetingIntelligenceTitlePublisher
{
    public Task<MeetingIntelligenceTitleSnapshot> CaptureAsync(RecordingSessionPlan plan, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(new MeetingIntelligenceTitleSnapshot(null, MeetingIntelligenceTitleOrigin.Manual, "preserve"));
    }

    public Task<MeetingIntelligenceTitlePublicationOutcome> TryApplyAsync(RecordingSessionPlan plan, MeetingIntelligenceTitleSnapshot captured, string suggestedTitle, MeetingIntelligenceTranscriptRevision sourceRevision, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(MeetingIntelligenceTitlePublicationOutcome.Preserved);
    }
}

public enum MeetingIntelligenceAvailabilityFailure { MissingModel, DiscoveryUnsupported, ModelNotAdvertised, AuthenticationRejected, ConnectionFailed }
public sealed record MeetingIntelligenceAvailability(bool IsConfirmed, MeetingIntelligenceAvailabilityFailure? Failure = null);

public interface IMeetingIntelligenceAvailabilityChecker
{
    Task<MeetingIntelligenceAvailability> CheckAsync(OpenAICompatibleProviderSnapshot snapshot, CancellationToken cancellationToken);
}

public sealed class OpenAICompatibleMeetingIntelligenceAvailabilityChecker(OpenAICompatibleProviderConnectionClient client)
    : IMeetingIntelligenceAvailabilityChecker
{
    public async Task<MeetingIntelligenceAvailability> CheckAsync(OpenAICompatibleProviderSnapshot snapshot, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        var model = snapshot.Profile.LlmModel.Trim();
        if (model.Length == 0 || model == "legacy-unconfigured-llm") return new(false, MeetingIntelligenceAvailabilityFailure.MissingModel);
        try
        {
            var report = await client.TestConnectionAsync(snapshot.Profile, snapshot.ApiKey, cancellationToken).ConfigureAwait(false);
            if (!report.SupportsModelDiscovery) return new(false, MeetingIntelligenceAvailabilityFailure.DiscoveryUnsupported);
            return report.Models.Contains(model, StringComparer.Ordinal)
                ? new(true)
                : new(false, MeetingIntelligenceAvailabilityFailure.ModelNotAdvertised);
        }
        catch (ProviderConnectionException error) when (error.Failure == ProviderConnectionFailure.AuthenticationRejected)
        { return new(false, MeetingIntelligenceAvailabilityFailure.AuthenticationRejected); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch { return new(false, MeetingIntelligenceAvailabilityFailure.ConnectionFailed); }
    }
}
