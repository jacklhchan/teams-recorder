using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text;
using Recorder.Core;
using TeamsRecorder.Windows.Application.AI;
using TeamsRecorder.Windows.Application.Storage;

namespace TeamsRecorder.Windows.Application.Transcription;

public sealed record RecordingSessionAsrChunkConstraints(TimeSpan MaximumDuration, int MaximumBytes)
{
    public static RecordingSessionAsrChunkConstraints ProviderDefault { get; } =
        new(TimeSpan.FromSeconds(120), OpenAICompatibleAsrClient.MaximumAudioBytes);
}

/// <summary>A complete, independently decodable provider upload; never a byte slice of a media container.</summary>
public sealed record RecordingSessionAsrChunk(int Sequence, TimeSpan Duration, byte[] Audio, string FileName);

/// <summary>
/// Production seam for Media Foundation audio extraction/chunk export. Implementations must yield
/// complete containers in chronological order and delete their private staging files after enumeration.
/// </summary>
public interface IRecordingSessionAsrChunkSource
{
    IAsyncEnumerable<RecordingSessionAsrChunk> ReadChunksAsync(
        RecordingSessionPlan plan,
        RecordingSessionAsrChunkConstraints constraints,
        CancellationToken cancellationToken);
}

/// <summary>
/// Compatibility path for an already-small completed M4A. Duration cannot be probed in managed code;
/// long recordings must use an injected Media Foundation chunk source rather than this adapter.
/// </summary>
public sealed class CompletedM4aAsrChunkSource : IRecordingSessionAsrChunkSource
{
    public async IAsyncEnumerable<RecordingSessionAsrChunk> ReadChunksAsync(
        RecordingSessionPlan plan,
        RecordingSessionAsrChunkConstraints constraints,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        var audio = await File.ReadAllBytesAsync(plan.FinalAudioPath, cancellationToken).ConfigureAwait(false);
        if (audio.Length == 0) throw new IOException("The completed recording.m4a is empty.");
        if (audio.Length > constraints.MaximumBytes)
            throw new OpenAICompatibleAsrException(OpenAICompatibleAsrFailure.AudioChunkTooLarge,
                message: "The recording needs Media Foundation chunk export before transcription; no oversized whole-file upload was sent.");
        // Zero means that this compatibility adapter did not assert a media duration. Strict long-
        // recording exporters must provide a positive duration no greater than MaximumDuration.
        yield return new RecordingSessionAsrChunk(0, TimeSpan.Zero, audio, RecordingSessionLayout.FinalAudioFileName);
    }
}

public interface IRecordingSessionAsrChunkTranscriber : IRecordingSessionAsrTranscriber
{
    Task<OpenAICompatibleAsrResult> TranscribeChunkAsync(
        OpenAICompatibleProviderSnapshot snapshot,
        ReadOnlyMemory<byte> completeChunk,
        string fileName,
        string rollingPrompt,
        CancellationToken cancellationToken);
}

public static class RecordingSessionAsrRollingPrompt
{
    public const int MaximumContextCharacters = 240;

    public static string Build(string? basePrompt, string priorTranscript)
    {
        var prefix = basePrompt?.Trim() ?? string.Empty;
        if (string.IsNullOrWhiteSpace(priorTranscript)) return prefix;
        var indices = StringInfo.ParseCombiningCharacters(priorTranscript);
        var start = indices.Length <= MaximumContextCharacters ? 0 : indices[^MaximumContextCharacters];
        var context = priorTranscript[start..].Trim();
        if (context.Length == 0) return prefix;
        return prefix.Length == 0
            ? "Previous transcript context:\n" + context
            : prefix + "\n\nPrevious transcript context:\n" + context;
    }
}

/// <summary>
/// Runs an explicitly requested transcription only after an owned M4A recording has been
/// published. It never observes an in-progress capture and intentionally does not split a
/// container by bytes: providers receive one complete M4A or the job fails before upload.
/// </summary>
public sealed class RecordingSessionAsrJobCoordinator : IDisposable
{
    private readonly object gate = new();
    private readonly TranscriptionArtifactPublisher publisher;
    private readonly Func<CancellationToken, Task<OpenAICompatibleProviderSnapshot>> snapshotGetter;
    private readonly IRecordingSessionAsrTranscriber transcriber;
    private readonly IRecordingSessionAsrChunkSource chunkSource;
    private long generation;
    private ActiveJob? active;
    private bool disposed;

    public RecordingSessionAsrJobCoordinator(
        Func<CancellationToken, Task<OpenAICompatibleProviderSnapshot>> snapshotGetter,
        IRecordingSessionAsrTranscriber transcriber,
        TranscriptionArtifactPublisher? publisher = null,
        IRecordingSessionAsrChunkSource? chunkSource = null)
    {
        this.snapshotGetter = snapshotGetter ?? throw new ArgumentNullException(nameof(snapshotGetter));
        this.transcriber = transcriber ?? throw new ArgumentNullException(nameof(transcriber));
        this.publisher = publisher ?? new TranscriptionArtifactPublisher();
        this.chunkSource = chunkSource ?? new CompletedM4aAsrChunkSource();
    }

    public static RecordingSessionAsrJobCoordinator CreateOpenAiCompatible(
        OpenAICompatibleProviderRepository providers,
        OpenAICompatibleAsrClient client,
        TranscriptionArtifactPublisher? publisher = null)
    {
        ArgumentNullException.ThrowIfNull(providers);
        ArgumentNullException.ThrowIfNull(client);
        // New Windows recordings are MP4, and legacy M4A files may exceed a
        // provider's single-request cap. The decoder is deliberately isolated
        // so a blocked Media Foundation open/read is killable and cannot hold
        // the app's ASR cancellation or staging cleanup hostage.
        return new(providers.SnapshotAsync, new OpenAICompatibleRecordingSessionAsrTranscriber(client), publisher,
            new IsolatedMediaFoundationAsrChunkSource());
    }

    public RecordingSessionAsrJobSnapshot? Snapshot
    {
        get { lock (gate) return active?.Snapshot; }
    }

    /// <summary>Queues a caller-opted-in job. A second job is refused until the first is terminal.</summary>
    public async Task<RecordingSessionAsrJob> StartAsync(
        RecordingSessionPlan plan,
        bool explicitlyOptedIn,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        if (!explicitlyOptedIn)
            throw new InvalidOperationException("Transcription requires an explicit user opt-in.");
        ValidateCompletedMedia(plan, requireSingleUploadBound: chunkSource is CompletedM4aAsrChunkSource);
        cancellationToken.ThrowIfCancellationRequested();

        ActiveJob job;
        lock (gate)
        {
            if (active is { IsTerminal: false })
                throw new InvalidOperationException("A transcription job is already running.");
            job = new ActiveJob(++generation, plan, new CancellationTokenSource());
            active = job;
        }

        try
        {
            await publisher.SaveStateAsync(plan, new TranscriptionState(TranscriptionPhase.Queued, "Queued for transcription.", DateTimeOffset.UtcNow), cancellationToken).ConfigureAwait(false);
            job.SetSnapshot(TranscriptionPhase.Queued, "Queued for transcription.");
            job.Completion = RunAsync(job);
            return new RecordingSessionAsrJob(job.Generation, job.Completion, () => Cancel(job.Generation));
        }
        catch
        {
            lock (gate) if (ReferenceEquals(active, job)) active = null;
            job.Dispose();
            throw;
        }
    }

    public Task CancelAsync()
    {
        ActiveJob? job;
        lock (gate) job = active;
        if (job is null || job.IsTerminal) return Task.CompletedTask;
        return CancelAndObserveAsync(job);
    }

    private void Cancel(long requestedGeneration)
    {
        ActiveJob? job;
        lock (gate) job = active is { Generation: var value } current && value == requestedGeneration ? current : null;
        job?.Cancellation.Cancel();
    }

    private async Task CancelAndObserveAsync(ActiveJob job)
    {
        job.Cancellation.Cancel();
        try { await job.Completion.ConfigureAwait(false); }
        catch (OperationCanceledException) { }
    }

    private async Task RunAsync(ActiveJob job)
    {
        try
        {
            await SetStateAsync(job, TranscriptionPhase.Uploading, "Preparing complete 120-second transcription chunks.", null).ConfigureAwait(false);
            var snapshot = await snapshotGetter(job.Cancellation.Token).ConfigureAwait(false);
            ThrowIfStale(job);
            var raw = new StringBuilder();
            var final = new StringBuilder();
            var formats = new List<string>();
            var log = new List<string>();
            var expectedSequence = 0;
            await foreach (var chunk in chunkSource.ReadChunksAsync(job.Plan, RecordingSessionAsrChunkConstraints.ProviderDefault, job.Cancellation.Token).ConfigureAwait(false))
            {
                ThrowIfStale(job);
                ValidateChunk(chunk, expectedSequence++);
                await SetStateAsync(job, TranscriptionPhase.Transcribing, $"Transcribing complete chunk {chunk.Sequence + 1}.", null).ConfigureAwait(false);
                var prompt = RecordingSessionAsrRollingPrompt.Build(snapshot.Profile.Prompt, final.ToString());
                OpenAICompatibleAsrResult result;
                if (transcriber is IRecordingSessionAsrChunkTranscriber chunkTranscriber)
                    result = await chunkTranscriber.TranscribeChunkAsync(snapshot, chunk.Audio, chunk.FileName, prompt, job.Cancellation.Token).ConfigureAwait(false);
                else
                {
                    if (chunk.Sequence > 0 || !string.Equals(prompt, snapshot.Profile.Prompt, StringComparison.Ordinal))
                        throw new NotSupportedException("Long transcription requires an IRecordingSessionAsrChunkTranscriber so rolling context remains request-scoped.");
                    result = await transcriber.TranscribeAsync(snapshot, chunk.Audio, chunk.FileName, job.Cancellation.Token).ConfigureAwait(false);
                }
                ThrowIfStale(job);
                if (raw.Length > 0) raw.AppendLine();
                if (final.Length > 0) final.AppendLine();
                raw.Append(result.Text.Trim());
                final.Append(result.Text.Trim());
                formats.Add(result.ResponseFormat.ToString());
                log.Add($"Completed chunk {chunk.Sequence + 1}.");
            }
            if (expectedSequence == 0) throw new IOException("The media chunk source produced no complete transcription chunks.");
            var profile = OpenAICompatibleProviderProfile.ValidateStored(snapshot.Profile);
            await publisher.PublishAsync(job.Plan, raw.ToString(), final.ToString(),
                new TranscriptionPublicationManifest(profile.AsrModel, profile.Language, expectedSequence, formats),
                log.Append("Completed transcription."), cancellationToken: job.Cancellation.Token).ConfigureAwait(false);
            await SetStateAsync(job, TranscriptionPhase.Completed, "Transcription completed.", DateTimeOffset.UtcNow).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (job.Cancellation.IsCancellationRequested)
        {
            await TrySetTerminalStateAsync(job, TranscriptionPhase.Cancelled, "Transcription cancelled.").ConfigureAwait(false);
            throw;
        }
        catch (Exception error)
        {
            await TrySetTerminalStateAsync(job, TranscriptionPhase.Failed, "Transcription failed: " + error.Message).ConfigureAwait(false);
            throw;
        }
        finally
        {
            job.MarkTerminal();
            lock (gate) if (ReferenceEquals(active, job)) active = job;
        }
    }

    private async Task SetStateAsync(ActiveJob job, TranscriptionPhase phase, string message, DateTimeOffset? finishedAt)
    {
        ThrowIfStale(job);
        await publisher.SaveStateAsync(job.Plan, new TranscriptionState(phase, message, job.StartedAt, finishedAt), job.Cancellation.Token).ConfigureAwait(false);
        ThrowIfStale(job);
        job.SetSnapshot(phase, message);
    }

    private async Task TrySetTerminalStateAsync(ActiveJob job, TranscriptionPhase phase, string message)
    {
        if (!IsCurrent(job)) return;
        try
        {
            // A cancellation state is useful only if it survives the cancellation that
            // caused it. The job token is therefore never used to write this final,
            // local-only state file.
            await publisher.SaveStateAsync(job.Plan, new TranscriptionState(phase, message, job.StartedAt, DateTimeOffset.UtcNow)).ConfigureAwait(false);
            if (IsCurrent(job)) job.SetSnapshot(phase, message);
        }
        catch (OperationCanceledException) when (!IsCurrent(job)) { }
    }

    private bool IsCurrent(ActiveJob job)
    {
        lock (gate) return !disposed && ReferenceEquals(active, job) && generation == job.Generation;
    }

    private void ThrowIfStale(ActiveJob job)
    {
        if (!IsCurrent(job)) throw new OperationCanceledException("The transcription job is no longer current.");
    }

    private static void ValidateChunk(RecordingSessionAsrChunk chunk, int expectedSequence)
    {
        ArgumentNullException.ThrowIfNull(chunk);
        if (chunk.Sequence != expectedSequence || chunk.Audio is not { Length: > 0 } ||
            chunk.Audio.Length > RecordingSessionAsrChunkConstraints.ProviderDefault.MaximumBytes ||
            chunk.Duration < TimeSpan.Zero || chunk.Duration > RecordingSessionAsrChunkConstraints.ProviderDefault.MaximumDuration ||
            string.IsNullOrWhiteSpace(chunk.FileName) || Path.GetFileName(chunk.FileName) != chunk.FileName)
            throw new IOException("The media chunk source produced an invalid or oversized complete chunk.");
    }

    private static void ValidateCompletedMedia(RecordingSessionPlan plan, bool requireSingleUploadBound)
    {
        var media = RecordingSessionAsrMediaResolver.Resolve(plan);
        var length = new FileInfo(media.Path).Length;
        if (length <= 0) throw new IOException("The completed recording media is empty.");
        if (requireSingleUploadBound && length > OpenAICompatibleAsrClient.MaximumAudioBytes)
            throw new OpenAICompatibleAsrException(OpenAICompatibleAsrFailure.AudioChunkTooLarge,
                message: "The completed M4A needs Media Foundation chunk export and no oversized whole-file upload was sent.");
    }

    private void ThrowIfDisposed()
    {
        lock (gate) if (disposed) throw new ObjectDisposedException(nameof(RecordingSessionAsrJobCoordinator));
    }

    public void Dispose()
    {
        ActiveJob? job;
        lock (gate) { if (disposed) return; disposed = true; job = active; }
        job?.Cancellation.Cancel();
    }

    private sealed class ActiveJob(long generation, RecordingSessionPlan plan, CancellationTokenSource cancellation) : IDisposable
    {
        private RecordingSessionAsrJobSnapshot snapshot = new(generation, TranscriptionPhase.Queued, "Queued for transcription.");
        public long Generation { get; } = generation;
        public RecordingSessionPlan Plan { get; } = plan;
        public CancellationTokenSource Cancellation { get; } = cancellation;
        public DateTimeOffset StartedAt { get; } = DateTimeOffset.UtcNow;
        public Task Completion { get; set; } = Task.CompletedTask;
        public bool IsTerminal { get; private set; }
        public RecordingSessionAsrJobSnapshot Snapshot => snapshot;
        public void SetSnapshot(TranscriptionPhase phase, string message) => snapshot = new(Generation, phase, message);
        public void MarkTerminal() => IsTerminal = true;
        public void Dispose() => Cancellation.Dispose();
    }
}

public interface IRecordingSessionAsrTranscriber
{
    Task<OpenAICompatibleAsrResult> TranscribeAsync(OpenAICompatibleProviderSnapshot snapshot, ReadOnlyMemory<byte> completedM4a, string fileName, CancellationToken cancellationToken);
}

/// <summary>Production adapter that keeps provider credential snapshots request-scoped.</summary>
public sealed class OpenAICompatibleRecordingSessionAsrTranscriber(OpenAICompatibleAsrClient client) : IRecordingSessionAsrChunkTranscriber
{
    public Task<OpenAICompatibleAsrResult> TranscribeAsync(OpenAICompatibleProviderSnapshot snapshot, ReadOnlyMemory<byte> completedM4a, string fileName, CancellationToken cancellationToken) =>
        client.TranscribeAsync(snapshot, completedM4a, fileName, cancellationToken);

    public Task<OpenAICompatibleAsrResult> TranscribeChunkAsync(OpenAICompatibleProviderSnapshot snapshot, ReadOnlyMemory<byte> completeChunk, string fileName, string rollingPrompt, CancellationToken cancellationToken) =>
        client.TranscribeAsync(snapshot, completeChunk, fileName, rollingPrompt, cancellationToken);
}

public sealed record RecordingSessionAsrJobSnapshot(long Generation, TranscriptionPhase Phase, string Message);
public sealed record RecordingSessionAsrJob(long Generation, Task Completion, Action Cancel);
