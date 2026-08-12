using TeamsRecorder.Windows.Application.AI;
using Recorder.Core;
using TeamsRecorder.Windows.Application.Storage;

namespace TeamsRecorder.Windows.Application.Transcription;

public sealed record MeetingIntelligenceSessionSnapshot(
    long Generation,
    MeetingIntelligenceSessionState State,
    string StatusMessage,
    string? Summary,
    string? SuggestedTitle,
    string? Model,
    bool TitleIsProtected,
    MeetingIntelligenceProgress? Progress = null);

public sealed record MeetingIntelligenceSessionJob(long Generation, Task Completion, Action Cancel);

/// <summary>
/// One mutation boundary per session. Transcript editors and metadata owners can share this
/// instance with the coordinator to make transcript/artifact/title compare-and-publish atomic.
/// </summary>
public sealed class MeetingIntelligenceSessionMutationBoundary
{
    private readonly SemaphoreSlim gate = new(1, 1);

    public async Task<T> RunAsync<T>(Func<CancellationToken, Task<T>> action, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(action);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { return await action(cancellationToken).ConfigureAwait(false); }
        finally { gate.Release(); }
    }

    public Task RunAsync(Func<CancellationToken, Task> action, CancellationToken cancellationToken = default) =>
        RunAsync(async token => { await action(token).ConfigureAwait(false); return true; }, cancellationToken);
}

/// <summary>
/// Session-owned lifecycle for provider availability, bounded generation, revision fencing,
/// atomic artifact publication, cancellation, and manual-title protection.
/// </summary>
public sealed class MeetingIntelligenceSessionCoordinator : IDisposable
{
    private readonly object gate = new();
    private readonly RecordingSessionPlan plan;
    private readonly Func<CancellationToken, Task<OpenAICompatibleProviderSnapshot>> snapshotGetter;
    private readonly IMeetingIntelligenceAvailabilityChecker availability;
    private readonly MeetingIntelligencePipeline pipeline;
    private readonly MeetingIntelligenceArtifactPublisher publisher;
    private readonly IMeetingIntelligenceCanonicalTranscriptReader transcriptReader;
    private readonly IMeetingIntelligenceTitlePublisher titlePublisher;
    private readonly MeetingIntelligenceSessionMutationBoundary mutationBoundary;
    private long generation;
    private ActiveAttempt? active;
    private bool disposed;
    private MeetingIntelligenceSessionSnapshot current = new(0, MeetingIntelligenceSessionState.NotGenerated, "Not generated.", null, null, null, false);

    public MeetingIntelligenceSessionCoordinator(
        RecordingSessionPlan plan,
        Func<CancellationToken, Task<OpenAICompatibleProviderSnapshot>> snapshotGetter,
        IMeetingIntelligenceAvailabilityChecker availability,
        MeetingIntelligencePipeline pipeline,
        MeetingIntelligenceArtifactPublisher? publisher = null,
        IMeetingIntelligenceCanonicalTranscriptReader? transcriptReader = null,
        IMeetingIntelligenceTitlePublisher? titlePublisher = null,
        MeetingIntelligenceSessionMutationBoundary? mutationBoundary = null)
    {
        this.plan = plan ?? throw new ArgumentNullException(nameof(plan));
        MeetingIntelligenceArtifactPublisher.ValidatePlan(plan);
        this.snapshotGetter = snapshotGetter ?? throw new ArgumentNullException(nameof(snapshotGetter));
        this.availability = availability ?? throw new ArgumentNullException(nameof(availability));
        this.pipeline = pipeline ?? throw new ArgumentNullException(nameof(pipeline));
        this.publisher = publisher ?? new();
        this.transcriptReader = transcriptReader ?? new MeetingIntelligenceCanonicalTranscriptReader();
        this.titlePublisher = titlePublisher ?? new PreserveMeetingIntelligenceTitlePublisher();
        this.mutationBoundary = mutationBoundary ?? new MeetingIntelligenceSessionMutationBoundary();
    }

    public event EventHandler<MeetingIntelligenceSessionSnapshot>? SnapshotChanged;
    public MeetingIntelligenceSessionMutationBoundary MutationBoundary => mutationBoundary;

    public MeetingIntelligenceSessionSnapshot Snapshot
    {
        get { lock (gate) return current; }
    }

    /// <summary>Projects durable state on startup and marks an abandoned network job interrupted.</summary>
    public async Task<MeetingIntelligenceSessionSnapshot> InitializeAsync(CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        try
        {
            var state = await publisher.MarkInterruptedIfNeededAsync(plan, cancellationToken: cancellationToken).ConfigureAwait(false);
            var transcript = await transcriptReader.ReadAsync(plan, cancellationToken).ConfigureAwait(false);
            var artifact = await publisher.LoadArtifactAsync(plan, cancellationToken).ConfigureAwait(false);
            if (state?.State == MeetingIntelligenceSessionState.Interrupted)
                return PublishSnapshot(new(generation, MeetingIntelligenceSessionState.Interrupted, state.Message,
                    artifact?.Summary, artifact?.SuggestedTitle, artifact?.Model, false));
            if (artifact is null)
                return PublishSnapshot(new(generation, MeetingIntelligenceSessionState.NotGenerated, "Not generated.", null, null, null, false));
            var matches = Matches(artifact, transcript.Revision);
            return PublishSnapshot(new(generation,
                matches ? MeetingIntelligenceSessionState.Ready : MeetingIntelligenceSessionState.Stale,
                matches ? "Meeting intelligence is ready." : "The transcript changed. Regenerate meeting intelligence.",
                artifact.Summary, artifact.SuggestedTitle, artifact.Model, false));
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch
        {
            return PublishSnapshot(new(generation, MeetingIntelligenceSessionState.NeedsAttention,
                "Meeting intelligence cannot read the canonical transcript or artifact.", null, null, null, false));
        }
    }

    public Task<MeetingIntelligenceSessionJob> StartAutomaticAsync(bool providerProcessingAllowed, CancellationToken cancellationToken = default) =>
        StartAsync(MeetingIntelligenceGenerationIntent.Automatic, providerProcessingAllowed, cancellationToken);

    public Task<MeetingIntelligenceSessionJob> GenerateAsync(
        MeetingIntelligenceGenerationIntent intent = MeetingIntelligenceGenerationIntent.Generate,
        CancellationToken cancellationToken = default) =>
        StartAsync(intent == MeetingIntelligenceGenerationIntent.Automatic ? MeetingIntelligenceGenerationIntent.Generate : intent,
            providerProcessingAllowed: true, cancellationToken);

    /// <summary>
    /// A replacement invalidates the old generation before it can publish. The provider snapshot,
    /// transcript revision and title stamp are then captured exactly once by the new attempt.
    /// </summary>
    public async Task<MeetingIntelligenceSessionJob> StartAsync(
        MeetingIntelligenceGenerationIntent intent,
        bool providerProcessingAllowed,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        if (!providerProcessingAllowed)
            throw new InvalidOperationException("Sending a transcript to the configured provider requires user authorization.");
        cancellationToken.ThrowIfCancellationRequested();

        var attempt = await mutationBoundary.RunAsync(_ =>
        {
            lock (gate)
            {
                active?.Cancellation.Cancel();
                var replacement = new ActiveAttempt(++generation, Guid.NewGuid(), new CancellationTokenSource(), intent);
                active = replacement;
                return Task.FromResult(replacement);
            }
        }, cancellationToken).ConfigureAwait(false);
        attempt.Completion = RunAsync(attempt);
        return new(attempt.Generation, attempt.Completion, () => Cancel(attempt.Generation));
    }

    public async Task CheckAvailabilityAsync(CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        var snapshot = await snapshotGetter(cancellationToken).ConfigureAwait(false);
        PublishSnapshot(new(generation, MeetingIntelligenceSessionState.Checking, "Checking LLM model availability.",
            Snapshot.Summary, Snapshot.SuggestedTitle, snapshot.Profile.LlmModel, Snapshot.TitleIsProtected));
        var result = await availability.CheckAsync(snapshot, cancellationToken).ConfigureAwait(false);
        PublishSnapshot(new(generation,
            result.IsConfirmed ? MeetingIntelligenceSessionState.NotGenerated : MeetingIntelligenceSessionState.NeedsAttention,
            result.IsConfirmed ? "The configured LLM model is available. Choose Generate to continue." : AvailabilityMessage(result),
            Snapshot.Summary, Snapshot.SuggestedTitle, snapshot.Profile.LlmModel, Snapshot.TitleIsProtected));
    }

    /// <summary>Cancels active work even for a byte-identical save, then derives Ready/Stale from the canonical digest.</summary>
    public async Task<MeetingIntelligenceSessionSnapshot> NotifyTranscriptSavedAsync(CancellationToken cancellationToken = default)
    {
        await CancelAsync().ConfigureAwait(false);
        return await InitializeAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task CancelAsync()
    {
        ActiveAttempt? attempt;
        lock (gate) attempt = active;
        if (attempt is null || attempt.Terminal) return;
        attempt.Cancellation.Cancel();
        try { await attempt.Completion.ConfigureAwait(false); }
        catch (OperationCanceledException) { }
    }

    public void Dispose()
    {
        lock (gate)
        {
            if (disposed) return;
            disposed = true;
            active?.Cancellation.Cancel();
        }
    }

    private async Task RunAsync(ActiveAttempt attempt)
    {
        var startedAt = DateTimeOffset.UtcNow;
        MeetingIntelligenceCanonicalTranscript? source = null;
        try
        {
            ThrowIfStale(attempt);
            source = await transcriptReader.ReadAsync(plan, attempt.Cancellation.Token).ConfigureAwait(false);
            ThrowIfStale(attempt);
            var provider = await snapshotGetter(attempt.Cancellation.Token).ConfigureAwait(false);
            ThrowIfStale(attempt);
            var title = await titlePublisher.CaptureAsync(plan, attempt.Cancellation.Token).ConfigureAwait(false);
            ThrowIfStale(attempt);

            if (attempt.Intent == MeetingIntelligenceGenerationIntent.Automatic)
            {
                await SetStateAsync(attempt, MeetingIntelligenceSessionState.Checking, "Checking LLM model availability.", source.Revision, provider.Profile.LlmModel, startedAt).ConfigureAwait(false);
                var available = await availability.CheckAsync(provider, attempt.Cancellation.Token).ConfigureAwait(false);
                ThrowIfStale(attempt);
                if (!available.IsConfirmed)
                {
                    await SetStateAsync(attempt, MeetingIntelligenceSessionState.NeedsAttention, AvailabilityMessage(available), source.Revision, provider.Profile.LlmModel, startedAt, DateTimeOffset.UtcNow).ConfigureAwait(false);
                    return;
                }
            }

            await SetStateAsync(attempt, MeetingIntelligenceSessionState.Generating, "Generating meeting intelligence.", source.Revision, provider.Profile.LlmModel, startedAt).ConfigureAwait(false);
            var progress = new InlineProgress(value =>
            {
                if (!IsCurrent(attempt)) return;
                PublishSnapshot(new(attempt.Generation, MeetingIntelligenceSessionState.Generating,
                    ProgressMessage(value), null, null, provider.Profile.LlmModel,
                    title.Origin == MeetingIntelligenceTitleOrigin.Manual, value));
            });
            var content = await pipeline.GenerateAsync(source, provider, progress, attempt.Cancellation.Token).ConfigureAwait(false);
            ThrowIfStale(attempt);

            await mutationBoundary.RunAsync(async token =>
            {
                ThrowIfStale(attempt);
                var currentTranscript = await transcriptReader.ReadAsync(plan, token).ConfigureAwait(false);
                if (currentTranscript.Revision != source.Revision)
                {
                    await SetStateAsync(attempt, MeetingIntelligenceSessionState.Stale, "The transcript changed before publication. Regenerate meeting intelligence.",
                        currentTranscript.Revision, provider.Profile.LlmModel, startedAt, DateTimeOffset.UtcNow).ConfigureAwait(false);
                    return;
                }
                var artifact = new MeetingIntelligenceArtifact(
                    MeetingIntelligenceArtifact.CurrentSchemaVersion,
                    content.Summary,
                    content.SuggestedTitle,
                    source.Revision.Sha256,
                    source.Revision.ByteCount,
                    provider.Profile.LlmModel,
                    DateTimeOffset.UtcNow,
                    attempt.Intent,
                    MeetingIntelligenceContentOrigin.Generated,
                    null);
                await publisher.PublishAsync(plan, artifact, token).ConfigureAwait(false);
                ThrowIfStale(attempt);
                var titleOutcome = await titlePublisher.TryApplyAsync(plan, title, artifact.SuggestedTitle, source.Revision, token).ConfigureAwait(false);
                ThrowIfStale(attempt);
                var titleProtected = title.Origin == MeetingIntelligenceTitleOrigin.Manual ||
                    titleOutcome is MeetingIntelligenceTitlePublicationOutcome.Preserved or MeetingIntelligenceTitlePublicationOutcome.Conflict;
                await SetStateAsync(attempt, MeetingIntelligenceSessionState.Ready,
                    titleProtected ? "Meeting intelligence is ready; the manual title was preserved." : "Meeting intelligence is ready.",
                    source.Revision, provider.Profile.LlmModel, startedAt, DateTimeOffset.UtcNow, artifact, titleProtected).ConfigureAwait(false);
            }, attempt.Cancellation.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (attempt.Cancellation.IsCancellationRequested || !IsCurrent(attempt))
        {
            await TrySetTerminalAsync(attempt, MeetingIntelligenceSessionState.Interrupted, "Meeting intelligence was interrupted.", source?.Revision, startedAt).ConfigureAwait(false);
            throw;
        }
        catch (Exception)
        {
            await TrySetTerminalAsync(attempt, MeetingIntelligenceSessionState.NeedsAttention,
                "Meeting intelligence could not be completed. Retry generation.", source?.Revision, startedAt).ConfigureAwait(false);
            throw;
        }
        finally
        {
            attempt.Terminal = true;
        }
    }

    private async Task SetStateAsync(
        ActiveAttempt attempt,
        MeetingIntelligenceSessionState state,
        string message,
        MeetingIntelligenceTranscriptRevision? revision,
        string? model,
        DateTimeOffset startedAt,
        DateTimeOffset? finishedAt = null,
        MeetingIntelligenceArtifact? artifact = null,
        bool titleProtected = false)
    {
        ThrowIfStale(attempt);
        await publisher.SaveStateAsync(plan, new(MeetingIntelligenceStateDocument.CurrentSchemaVersion, state, message,
            revision?.Sha256, attempt.Generation, startedAt, finishedAt), attempt.Cancellation.Token).ConfigureAwait(false);
        ThrowIfStale(attempt);
        PublishSnapshot(new(attempt.Generation, state, message, artifact?.Summary, artifact?.SuggestedTitle, model, titleProtected));
    }

    private async Task TrySetTerminalAsync(ActiveAttempt attempt, MeetingIntelligenceSessionState state, string message,
        MeetingIntelligenceTranscriptRevision? revision, DateTimeOffset startedAt)
    {
        if (!IsCurrent(attempt)) return;
        try
        {
            await publisher.SaveStateAsync(plan, new(MeetingIntelligenceStateDocument.CurrentSchemaVersion, state, message,
                revision?.Sha256, attempt.Generation, startedAt, DateTimeOffset.UtcNow)).ConfigureAwait(false);
            if (IsCurrent(attempt)) PublishSnapshot(new(attempt.Generation, state, message, Snapshot.Summary,
                Snapshot.SuggestedTitle, Snapshot.Model, Snapshot.TitleIsProtected));
        }
        catch (IOException) { }
    }

    private void Cancel(long requestedGeneration)
    {
        lock (gate)
        {
            if (active?.Generation == requestedGeneration) active.Cancellation.Cancel();
        }
    }

    private bool IsCurrent(ActiveAttempt attempt)
    {
        lock (gate) return !disposed && ReferenceEquals(active, attempt) && generation == attempt.Generation;
    }

    private void ThrowIfStale(ActiveAttempt attempt)
    {
        if (!IsCurrent(attempt)) throw new OperationCanceledException("The meeting intelligence generation is stale.");
        attempt.Cancellation.Token.ThrowIfCancellationRequested();
    }

    private MeetingIntelligenceSessionSnapshot PublishSnapshot(MeetingIntelligenceSessionSnapshot value)
    {
        EventHandler<MeetingIntelligenceSessionSnapshot>? handler;
        lock (gate)
        {
            current = value;
            handler = SnapshotChanged;
        }
        handler?.Invoke(this, value);
        return value;
    }

    private void ThrowIfDisposed()
    {
        lock (gate) if (disposed) throw new ObjectDisposedException(nameof(MeetingIntelligenceSessionCoordinator));
    }

    private static bool Matches(MeetingIntelligenceArtifact artifact, MeetingIntelligenceTranscriptRevision revision) =>
        artifact.SourceTranscriptSha256 == revision.Sha256 && artifact.SourceTranscriptByteCount == revision.ByteCount;

    private static string ProgressMessage(MeetingIntelligenceProgress progress) => progress.Stage switch
    {
        MeetingIntelligencePipelineStage.SummarizingChunks => $"Summarizing transcript chunk {progress.Current} of {progress.Total}.",
        MeetingIntelligencePipelineStage.ReducingSummaries => $"Reducing summary group {progress.Current} of {progress.Total}.",
        _ => "Generating final summary and contextual title.",
    };

    private static string AvailabilityMessage(MeetingIntelligenceAvailability availability) => availability.Failure switch
    {
        MeetingIntelligenceAvailabilityFailure.MissingModel => "Configure a real LLM model before generating meeting intelligence.",
        MeetingIntelligenceAvailabilityFailure.DiscoveryUnsupported => "The provider does not confirm model discovery. Manual Generate can still try it.",
        MeetingIntelligenceAvailabilityFailure.ModelNotAdvertised => "The configured LLM model was not advertised. Manual Generate can still try it.",
        MeetingIntelligenceAvailabilityFailure.AuthenticationRejected => "The provider rejected the API key.",
        _ => "LLM model availability could not be confirmed. Manual Generate can still try it.",
    };

    private sealed class ActiveAttempt(long generation, Guid attemptId, CancellationTokenSource cancellation, MeetingIntelligenceGenerationIntent intent)
    {
        public long Generation { get; } = generation;
        public Guid AttemptId { get; } = attemptId;
        public CancellationTokenSource Cancellation { get; } = cancellation;
        public MeetingIntelligenceGenerationIntent Intent { get; } = intent;
        public Task Completion { get; set; } = Task.CompletedTask;
        public bool Terminal { get; set; }
    }

    private sealed class InlineProgress(Action<MeetingIntelligenceProgress> report) : IProgress<MeetingIntelligenceProgress>
    {
        public void Report(MeetingIntelligenceProgress value) => report(value);
    }
}
