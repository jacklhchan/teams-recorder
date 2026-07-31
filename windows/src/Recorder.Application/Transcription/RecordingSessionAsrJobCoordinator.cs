using Recorder.Core;
using TeamsRecorder.Windows.Application.AI;
using TeamsRecorder.Windows.Application.Storage;

namespace TeamsRecorder.Windows.Application.Transcription;

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
    private long generation;
    private ActiveJob? active;
    private bool disposed;

    public RecordingSessionAsrJobCoordinator(
        Func<CancellationToken, Task<OpenAICompatibleProviderSnapshot>> snapshotGetter,
        IRecordingSessionAsrTranscriber transcriber,
        TranscriptionArtifactPublisher? publisher = null)
    {
        this.snapshotGetter = snapshotGetter ?? throw new ArgumentNullException(nameof(snapshotGetter));
        this.transcriber = transcriber ?? throw new ArgumentNullException(nameof(transcriber));
        this.publisher = publisher ?? new TranscriptionArtifactPublisher();
    }

    public static RecordingSessionAsrJobCoordinator CreateOpenAiCompatible(
        OpenAICompatibleProviderRepository providers,
        OpenAICompatibleAsrClient client,
        TranscriptionArtifactPublisher? publisher = null)
    {
        ArgumentNullException.ThrowIfNull(providers);
        ArgumentNullException.ThrowIfNull(client);
        return new(providers.SnapshotAsync, new OpenAICompatibleRecordingSessionAsrTranscriber(client), publisher);
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
        ValidateCompletedM4a(plan);
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
            await SetStateAsync(job, TranscriptionPhase.Uploading, "Preparing the completed M4A for upload.", null).ConfigureAwait(false);
            var audio = await ReadCompletedAudioAsync(job.Plan, job.Cancellation.Token).ConfigureAwait(false);
            var snapshot = await snapshotGetter(job.Cancellation.Token).ConfigureAwait(false);
            ThrowIfStale(job);
            await SetStateAsync(job, TranscriptionPhase.Transcribing, "Transcribing the completed recording.", null).ConfigureAwait(false);
            var result = await transcriber.TranscribeAsync(snapshot, audio, RecordingSessionLayout.FinalAudioFileName, job.Cancellation.Token).ConfigureAwait(false);
            ThrowIfStale(job);
            var profile = OpenAICompatibleProviderProfile.ValidateStored(snapshot.Profile);
            await publisher.PublishAsync(job.Plan, result.Text, result.Text,
                new TranscriptionPublicationManifest(profile.AsrModel, profile.Language, 1, [result.ResponseFormat.ToString()]),
                ["Completed transcription."], cancellationToken: job.Cancellation.Token).ConfigureAwait(false);
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

    private static async Task<byte[]> ReadCompletedAudioAsync(RecordingSessionPlan plan, CancellationToken cancellationToken)
    {
        ValidateCompletedM4a(plan);
        return await File.ReadAllBytesAsync(plan.FinalAudioPath, cancellationToken).ConfigureAwait(false);
    }

    private static void ValidateCompletedM4a(RecordingSessionPlan plan)
    {
        ArgumentNullException.ThrowIfNull(plan);
        var folder = Path.GetFullPath(plan.FolderPath);
        var finalPath = Path.GetFullPath(plan.FinalAudioPath);
        if (!Directory.Exists(folder) || (File.GetAttributes(folder) & FileAttributes.ReparsePoint) != 0 ||
            !RecordingSessionLayout.TryGetKind(Path.GetFileName(folder), out var kind) || kind != plan.Kind ||
            !string.Equals(finalPath, Path.Combine(folder, RecordingSessionLayout.FinalAudioFileName), StringComparison.OrdinalIgnoreCase) ||
            !File.Exists(finalPath) || (File.GetAttributes(finalPath) & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
            throw new IOException("Transcription requires an owned session with a completed recording.m4a.");
        var length = new FileInfo(finalPath).Length;
        if (length <= 0) throw new IOException("The completed recording.m4a is empty.");
        if (length > OpenAICompatibleAsrClient.MaximumAudioBytes)
            throw new OpenAICompatibleAsrException(OpenAICompatibleAsrFailure.AudioChunkTooLarge,
                message: "The completed M4A exceeds the 32 MiB transcription upload limit and was not uploaded.");
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
public sealed class OpenAICompatibleRecordingSessionAsrTranscriber(OpenAICompatibleAsrClient client) : IRecordingSessionAsrTranscriber
{
    public Task<OpenAICompatibleAsrResult> TranscribeAsync(OpenAICompatibleProviderSnapshot snapshot, ReadOnlyMemory<byte> completedM4a, string fileName, CancellationToken cancellationToken) =>
        client.TranscribeAsync(snapshot, completedM4a, fileName, cancellationToken);
}

public sealed record RecordingSessionAsrJobSnapshot(long Generation, TranscriptionPhase Phase, string Message);
public sealed record RecordingSessionAsrJob(long Generation, Task Completion, Action Cancel);
