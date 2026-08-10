using Recorder.Core;
using TeamsRecorder.Windows.Application.Diagnostics;
using TeamsRecorder.Windows.Application.Recovery;
using TeamsRecorder.Windows.Application.Storage;

namespace TeamsRecorder.Windows.Application;

/// <summary>
/// Serializes native capture with session allocation and publication.  A UI can
/// request operations concurrently (for example manual and Teams automation),
/// but this service makes each transition atomic at the application boundary.
/// </summary>
public sealed class RecordingLifecycleService : IDisposable, INativeTeamsRenderEndpointProbe
{
    private readonly INativeRecorderBridge nativeBridge;
    private readonly RecordingCoordinator coordinator;
    private readonly SemaphoreSlim operationGate = new(1, 1);
    private readonly object stateGate = new();
    private SessionStorageService storage;
    private RecordingSessionPlan? activeSession;
    private RecordingSessionActiveLock? activeSessionLock;
    private Task<RecordingSessionPublicationResult>? publication;
    private Task recoveryJournalWrite = Task.CompletedTask;
    private ulong lastAudioCheckpointSequence;
    private ulong lastVideoCheckpointSequence;
    private long recoveryJournalSequence;
    private readonly CaptureSourceSelectionPolicy captureSourcePolicy;
    private readonly IRecordingDiagnostics diagnostics;
    private readonly IVideoCaptureTargetCatalog videoTargets;
    // Release remains fail-closed until the acceptance evidence is complete.
    // Test harnesses may opt in explicitly, but production construction never
    // turns a partial implementation into an announced capture capability.
    private readonly bool verifiedVideoCapturePipeline;
    private CancellationTokenSource? pendingStartCancellation;
    private long generation;
    private RecordingSessionKind? activeSessionKind;
    private WindowsCaptureMetadata? activeWindowsCapture;
    private bool activeWindowVideo;
    private bool disposed;

    public RecordingLifecycleService(
        INativeRecorderBridge nativeBridge,
        string storageRoot,
        IProcessCatalog? processCatalog = null,
        IRecordingDelay? recordingDelay = null,
        IRecordingDiagnostics? diagnostics = null,
        IVideoCaptureTargetCatalog? videoTargets = null,
        bool verifiedVideoCapturePipeline = false,
        IAudioBackupValidator? audioValidator = null)
    {
        this.nativeBridge = nativeBridge ?? throw new ArgumentNullException(nameof(nativeBridge));
        coordinator = new RecordingCoordinator(nativeBridge, recordingDelay);
        coordinator.SnapshotChanged += OnSnapshotChanged;
        storage = new SessionStorageService(storageRoot, audioValidator: audioValidator);
        captureSourcePolicy = new CaptureSourceSelectionPolicy(processCatalog);
        this.diagnostics = diagnostics ?? LocalDiagnosticLog.CreateDefault();
        this.videoTargets = videoTargets ?? new WindowsVideoCaptureTargetCatalog();
        this.verifiedVideoCapturePipeline = verifiedVideoCapturePipeline;
    }

    public event EventHandler<RecordingCoordinatorSnapshot>? SnapshotChanged;
    public RecordingCoordinatorSnapshot Snapshot => coordinator.Snapshot;
    /// <summary>Monotonically increases for accepted application start requests.</summary>
    public long Generation { get { lock (stateGate) return generation; } }
    public RecordingSessionKind? ActiveSessionKind { get { lock (stateGate) return activeSessionKind; } }
    public RecordingOwner Owner
    {
        get
        {
            lock (stateGate)
            {
                return activeSessionKind switch
                {
                    RecordingSessionKind.Meeting => RecordingOwner.TeamsAutomatic,
                    RecordingSessionKind.Manual or RecordingSessionKind.Test => RecordingOwner.Manual,
                    _ => RecordingOwner.None,
                };
            }
        }
    }
    public bool HasPublicationInProgress { get { lock (stateGate) return publication is { IsCompleted: false }; } }
    public StorageCapacityStatus GetCapacityStatus() { lock (stateGate) return storage.GetCapacityStatus(); }

    /// <summary>Exports the in-process, privacy-filtered diagnostic trail to a user-selected folder.</summary>
    public Task<DiagnosticExportResult> ExportDiagnosticsAsync(string destinationDirectory, CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        return diagnostics.ExportAsync(destinationDirectory, cancellationToken);
    }

    public void SetStorageRoot(string storageRoot)
    {
        ThrowIfDisposed();
        var replacement = new SessionStorageService(storageRoot);
        lock (stateGate)
        {
            if (activeSession is not null || publication is { IsCompleted: false })
                throw new InvalidOperationException("The recording storage location cannot change while a session is active.");
            storage = replacement;
        }
    }

    public Task<NativeEndpointEnumerationResult> RefreshEndpointsAsync()
    {
        ThrowIfDisposed();
        return coordinator.RefreshEndpointsAsync();
    }

    /// <summary>
    /// Reads the transient Windows audio-session hint for Teams playback. This
    /// is strictly a non-blocking preflight: an unavailable capability or an
    /// empty session snapshot must never change the requested capture source.
    /// </summary>
    public NativeTeamsRenderEndpointProbeResult ProbeTeamsRenderEndpoints()
    {
        ThrowIfDisposed();
        return nativeBridge is INativeTeamsRenderEndpointProbe probe
            ? probe.ProbeTeamsRenderEndpoints()
            : new NativeTeamsRenderEndpointProbeResult(
                NativeOperationResult.Failure(
                    NativeRecorderResult.NotImplemented,
                    "The native recorder bridge does not support the Teams playback endpoint preflight."),
                Array.Empty<NativeCaptureEndpoint>());
    }

    public Task<RecordingCoordinatorSnapshot> RefreshAsync()
    {
        ThrowIfDisposed();
        return coordinator.RefreshAsync();
    }

    /// <summary>
    /// Starts one selected native source. Process identities are verified before
    /// any native call; an unavailable process is an error, never a fallback.
    /// Cancellation is an ownership seam for Teams countdowns and manual UI.
    /// </summary>
    public async Task<RecordingLifecycleStartResult> StartAsync(
        RecordingStartRequest request,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        ArgumentNullException.ThrowIfNull(request);
        request.Validate();
        diagnostics.RecordStart(request);
        await operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        CancellationTokenSource? operationCancellation = null;
        RecordingSessionPlan? plan = null;
        WindowsCaptureMetadata? capture = null;
        SessionStorageService? currentStorage = null;
        try
        {
            lock (stateGate)
            {
                if (activeSession is not null || publication is { IsCompleted: false } || pendingStartCancellation is not null)
                    throw new InvalidOperationException("A recording session is already active or being published.");
                plan = storage.CreateSessionPlan(request.Kind);
                activeSessionLock = storage.AcquireActiveLock(plan);
                activeSession = plan;
                activeSessionKind = request.Kind;
                activeWindowsCapture = RecordingStartMetadataPolicy.CreateWindowsCaptureMetadata(request);
                activeWindowVideo = false;
                capture = activeWindowsCapture;
                currentStorage = storage;
                ResetRecoveryJournalState();
                generation = checked(generation + 1);
                operationCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                pendingStartCancellation = operationCancellation;
            }

            operationCancellation.Token.ThrowIfCancellationRequested();
            await currentStorage!.WriteProvisionalMetadataAsync(plan, capture, operationCancellation.Token).ConfigureAwait(false);
            RecordingCoordinatorSnapshot started;
            if (request.AudioSource == RecordingAudioSource.SelectedProcessLoopback)
            {
                // Verify PID plus start time immediately before native activation.
                // A stale selection fails and the cleanup path can remove only an
                // empty owned folder; it never substitutes system loopback.
                captureSourcePolicy.EnsureSelectedProcessIsCurrent(request);
                var nativeRequest = captureSourcePolicy.CreateSelectedAudioRequest(
                    request,
                    plan.AudioSafetyPartialPath);
                var videoStart = await StartForVideoIfRequestedAsync(request, plan, nativeRequest).ConfigureAwait(false);
                started = videoStart.Snapshot;
                if (nativeBridge is INativeSelectedWindowAvRecorderBridge)
                {
                    lock (stateGate)
                    {
                        activeWindowVideo = started.State == RecordingCoordinatorState.Recording &&
                            videoStart.ExactTargetWasPassed;
                    }
                }
            }
            else
            {
                if (nativeBridge is INativeSelectedWindowAvRecorderBridge)
                {
                    var selected = ResolveInitialVideoTarget(request.VideoTarget, plan);
                    var videoRequest = new NativeSelectedWindowAvRequest(
                        NativeSelectedAudioSource.SystemLoopback,
                        plan.AudioSafetyPartialPath,
                        plan.PartialVideoPath,
                        selected,
                        request.RenderEndpointId,
                        request.MicrophoneEndpointId);
                    started = await StartSelectedWindowAvAsync(videoRequest, request).ConfigureAwait(false);
                    lock (stateGate)
                    {
                        activeWindowVideo = started.State == RecordingCoordinatorState.Recording &&
                            selected is not null;
                    }
                }
                else
                {
                    var nativeRequest = new NativeMixedRecordingRequest(
                        plan.AudioSafetyPartialPath,
                        request.RenderEndpointId,
                        request.MicrophoneEndpointId);
                    started = request.Kind == RecordingSessionKind.Test
                        ? await coordinator.StartMixedTestAsync(nativeRequest, request.TestDuration!.Value).ConfigureAwait(false)
                        : await coordinator.StartMixedAsync(nativeRequest).ConfigureAwait(false);
                }
            }

            if (operationCancellation.IsCancellationRequested)
            {
                if (started.State == RecordingCoordinatorState.Recording)
                    await coordinator.StopAsync().ConfigureAwait(false);
                ClearFailedStart(plan);
                throw new OperationCanceledException(operationCancellation.Token);
            }
            if (started.State != RecordingCoordinatorState.Recording) ClearFailedStart(plan);
            return new RecordingLifecycleStartResult(started, plan);
        }
        catch (Exception error)
        {
            diagnostics.RecordFailure("start", error);
            if (plan is not null) ClearFailedStart(plan);
            throw;
        }
        finally
        {
            lock (stateGate)
            {
                if (ReferenceEquals(pendingStartCancellation, operationCancellation)) pendingStartCancellation = null;
            }
            operationCancellation?.Dispose();
            operationGate.Release();
        }
    }

    /// <summary>Cancels only an as-yet-uncommitted start; it does not stop an owned recording.</summary>
    public void CancelPendingStart()
    {
        lock (stateGate) pendingStartCancellation?.Cancel();
    }

    public async Task<RecordingLifecycleStartResult> StartMixedAsync(RecordingSessionKind kind, string? renderEndpointId, string? microphoneEndpointId, TimeSpan? testDuration = null)
    {
        ThrowIfDisposed();
        await operationGate.WaitAsync().ConfigureAwait(false);
        try
        {
            RecordingSessionPlan plan;
            lock (stateGate)
            {
                if (activeSession is not null || publication is { IsCompleted: false })
                    throw new InvalidOperationException("A recording session is already active or being published.");
                plan = storage.CreateSessionPlan(kind);
                activeSessionLock = storage.AcquireActiveLock(plan);
                activeSession = plan;
                activeSessionKind = kind;
                activeWindowsCapture = WindowsCaptureMetadata.ForSystemLoopback(renderEndpointId);
                activeWindowVideo = false;
                ResetRecoveryJournalState();
                generation = checked(generation + 1);
            }

            try
            {
                await storage.WriteProvisionalMetadataAsync(plan, activeWindowsCapture).ConfigureAwait(false);
                var request = new NativeMixedRecordingRequest(plan.AudioSafetyPartialPath, renderEndpointId, microphoneEndpointId);
                var snapshot = testDuration is { } duration
                    ? await coordinator.StartMixedTestAsync(request, duration).ConfigureAwait(false)
                    : await coordinator.StartMixedAsync(request).ConfigureAwait(false);
                if (snapshot.State != RecordingCoordinatorState.Recording)
                    ClearFailedStart(plan);
                return new RecordingLifecycleStartResult(snapshot, plan);
            }
            catch
            {
                ClearFailedStart(plan);
                throw;
            }
        }
        finally { operationGate.Release(); }
    }

    public async Task<RecordingCoordinatorSnapshot> StopAsync()
    {
        ThrowIfDisposed();
        await operationGate.WaitAsync().ConfigureAwait(false);
        try { return await coordinator.StopAsync().ConfigureAwait(false); }
        finally { operationGate.Release(); }
    }

    /// <summary>Publishes a clean stop once. On failure, the backup stays untouched for startup recovery.</summary>
    public async Task<RecordingSessionPublicationResult> PublishCompletedAsync()
    {
        ThrowIfDisposed();
        await operationGate.WaitAsync().ConfigureAwait(false);
        try
        {
            RecordingSessionPlan? plan;
            lock (stateGate)
            {
                plan = activeSession;
                if (plan is null) return RecordingSessionPublicationResult.NoActiveSession;
                if (publication is not null) return publication.GetAwaiter().GetResult();
                publication = PublishCoreAsync(plan);
            }
            return await publication.ConfigureAwait(false);
        }
        finally { operationGate.Release(); }
    }

    /// <summary>
    /// Stops capture during shutdown or a capture fault. Only a confirmed Stopped
    /// state is published; otherwise the session plan is released while every
    /// backup/partial artifact is retained for recovery.
    /// </summary>
    public async Task<RecordingSessionPublicationResult> FinalizeForRecoveryAsync()
    {
        ThrowIfDisposed();
        var stopped = await StopAsync().ConfigureAwait(false);
        if (stopped.State == RecordingCoordinatorState.Stopped &&
            !stopped.HasRecoverableFault)
            return await PublishCompletedAsync().ConfigureAwait(false);

        RecordingSessionPlan? plan;
        lock (stateGate)
        {
            plan = activeSession;
            activeSession = null;
            activeSessionKind = null;
            activeWindowsCapture = null;
            activeWindowVideo = false;
            ReleaseActiveSessionLock();
        }
        coordinator.CompleteFaultRecovery();
        var diagnostic = string.IsNullOrWhiteSpace(stopped.Error)
            ? "Native capture did not finish."
            : stopped.Error;
        return new RecordingSessionPublicationResult(plan, false,
            plan is null ? null : new IOException(
                $"Native capture did not finish; retained session evidence for startup recovery. Cause: {diagnostic}"));
    }

    public NativeOperationResult SetMicrophoneMuted(bool muted)
    {
        ThrowIfDisposed();
        return nativeBridge is INativeRecorderMicrophoneMuteControl control
            ? control.SetMicrophoneMuted(muted)
            : NativeOperationResult.Failure(NativeRecorderResult.NotImplemented, "The native recorder does not support microphone mute control.");
    }

    /// <summary>
    /// Enables or replaces the current exact-HWND target without ending the
    /// recording. The native layer revalidates HWND + PID + creation time and
    /// fences stale callbacks; a target that vanished simply remains black
    /// video while audio keeps recording.
    /// </summary>
    public async Task<NativeOperationResult> SetVideoTargetAsync(VideoCaptureTarget target)
    {
        ThrowIfDisposed();
        ArgumentNullException.ThrowIfNull(target);
        await operationGate.WaitAsync().ConfigureAwait(false);
        try
        {
            RecordingSessionPlan? plan;
            lock (stateGate) plan = activeSession;
            if (plan is null)
                return NativeOperationResult.Failure(NativeRecorderResult.InvalidState,
                    "No recording is active.");

            var selected = VideoCaptureTargetSelection.Resolve(target, videoTargets.ListTargets());
            if (selected is null)
                return NativeOperationResult.Failure(NativeRecorderResult.CaptureError,
                    "The selected capture window changed before video could be enabled.");
            EnsureVideoCapability(plan);
            var result = await coordinator.SetVideoTargetAsync(selected).ConfigureAwait(false);
            if (result.IsSuccess)
            {
                lock (stateGate) activeWindowVideo = true;
            }
            return result;
        }
        finally { operationGate.Release(); }
    }

    /// <summary>Stops exact-window pixels but preserves the running MP4/audio timeline as privacy-black video.</summary>
    public async Task<NativeOperationResult> DisableVideoTargetAsync()
    {
        ThrowIfDisposed();
        await operationGate.WaitAsync().ConfigureAwait(false);
        try
        {
            lock (stateGate)
            {
                if (activeSession is null)
                    return NativeOperationResult.Failure(NativeRecorderResult.InvalidState,
                        "No recording is active.");
            }
            return await coordinator.DisableVideoTargetAsync().ConfigureAwait(false);
        }
        finally { operationGate.Release(); }
    }

    private void ClearFailedStart(RecordingSessionPlan plan)
    {
        lock (stateGate)
        {
            if (activeSession == plan)
            {
                activeSession = null;
                activeSessionKind = null;
                activeWindowsCapture = null;
                activeWindowVideo = false;
                ReleaseActiveSessionLock();
            }
            // CleanupEmptyOwnedSession itself refuses any media, partial media,
            // diagnostics, or recovery evidence; it can only remove an empty folder.
            storage.CleanupFailedProvisionalStart(plan);
        }
    }

    private async Task<RecordingSessionPublicationResult> PublishCoreAsync(RecordingSessionPlan plan)
    {
        try
        {
            SessionStorageService current;
            WindowsCaptureMetadata? capture;
            bool video;
            lock (stateGate)
            {
                current = storage;
                capture = activeWindowsCapture;
                video = activeWindowVideo;
            }
            if (video)
                await current.PublishCompletedVideoAsync(plan, title: null, windowsCapture: capture).ConfigureAwait(false);
            else
                await current.PublishCompletedMediaAsync(plan, title: null, windowsCapture: capture).ConfigureAwait(false);
            return new RecordingSessionPublicationResult(plan, true, null);
        }
        catch (Exception exception) { return new RecordingSessionPublicationResult(plan, false, exception); }
        finally
        {
            lock (stateGate)
            {
                if (activeSession == plan)
                {
                    activeSession = null;
                    activeSessionKind = null;
                    activeWindowsCapture = null;
                    activeWindowVideo = false;
                    ReleaseActiveSessionLock();
                }
                publication = null;
            }
        }
    }

    private void EnsureVideoCapability(RecordingSessionPlan plan)
    {
        var capability = VideoCaptureFeatureGate.Evaluate(
            Environment.OSVersion.Version.Build, plan.Capacity.Decision, verifiedVideoCapturePipeline);
        if (!capability.CanStart) throw new InvalidOperationException(capability.Message);
    }

    private async Task<InitialVideoStartResult> StartForVideoIfRequestedAsync(
        RecordingStartRequest request,
        RecordingSessionPlan plan,
        NativeSelectedAudioRequest audioRequest)
    {
        if (nativeBridge is not INativeSelectedWindowAvRecorderBridge)
        {
            var snapshot = await (request.Kind == RecordingSessionKind.Test
                ? coordinator.StartSelectedAudioTestAsync(audioRequest, request.TestDuration!.Value)
                : coordinator.StartSelectedAudioAsync(audioRequest)).ConfigureAwait(false);
            return new InitialVideoStartResult(snapshot, ExactTargetWasPassed: false);
        }
        var selected = ResolveInitialVideoTarget(request.VideoTarget, plan);
        var videoRequest = new NativeSelectedWindowAvRequest(
            audioRequest.AudioSource,
            plan.AudioSafetyPartialPath,
            plan.PartialVideoPath,
            selected,
            audioRequest.RenderEndpointId,
            audioRequest.MicrophoneEndpointId,
            audioRequest.TargetProcessId,
            audioRequest.IncludedProcessTree,
            audioRequest.ExpectedProcessCreationTime100Nanoseconds,
            AacBitRate: audioRequest.AacBitRate);
        var started = await StartSelectedWindowAvAsync(videoRequest, request).ConfigureAwait(false);
        return new InitialVideoStartResult(started, ExactTargetWasPassed: selected is not null);
    }

    private sealed record InitialVideoStartResult(
        RecordingCoordinatorSnapshot Snapshot,
        bool ExactTargetWasPassed);

    private VideoCaptureTarget? ResolveInitialVideoTarget(
        VideoCaptureTarget? requested,
        RecordingSessionPlan plan)
    {
        if (requested is null) return null;
        EnsureVideoCapability(plan);
        // A target may disappear between UI selection and native start. The
        // native session starts audio plus black video in that case; it never
        // substitutes a similarly titled window or a desktop capture.
        return VideoCaptureTargetSelection.Resolve(requested, videoTargets.ListTargets());
    }

    private Task<RecordingCoordinatorSnapshot> StartSelectedWindowAvAsync(
        NativeSelectedWindowAvRequest request,
        RecordingStartRequest originalRequest) =>
        originalRequest.Kind == RecordingSessionKind.Test
            ? coordinator.StartSelectedWindowAvTestAsync(request, originalRequest.TestDuration!.Value)
            : coordinator.StartSelectedWindowAvAsync(request);

    private void OnSnapshotChanged(object? sender, RecordingCoordinatorSnapshot snapshot)
    {
        diagnostics.RecordSnapshot(snapshot);
        QueueRecoveryJournal(snapshot);
        SnapshotChanged?.Invoke(this, snapshot);
    }

    private void QueueRecoveryJournal(RecordingCoordinatorSnapshot snapshot)
    {
        var audio = snapshot.Stats.AudioDurableCheckpoint;
        var video = snapshot.Stats.VideoDurableCheckpoint;
        if (!audio.IsDurable && !video.IsDurable) return;

        lock (stateGate)
        {
            if (activeSession is not { } plan || activeSessionLock is null) return;
            if (audio.Sequence <= lastAudioCheckpointSequence &&
                video.Sequence <= lastVideoCheckpointSequence) return;

            lastAudioCheckpointSequence = Math.Max(lastAudioCheckpointSequence, audio.Sequence);
            lastVideoCheckpointSequence = Math.Max(lastVideoCheckpointSequence, video.Sequence);
            var sequence = checked(++recoveryJournalSequence);
            var journal = RecordingRecoveryJournal.Create(
                sequence,
                ToRecoveryCheckpoint(video),
                ToRecoveryCheckpoint(audio),
                DateTimeOffset.UtcNow);
            var currentStorage = storage;

            // Serialize journal replacements. A failed write is diagnostic-only:
            // the previous complete journal remains authoritative after a crash.
            recoveryJournalWrite = recoveryJournalWrite.ContinueWith(
                async _ =>
                {
                    try
                    {
                        await currentStorage.WriteRecoveryJournalAsync(plan, journal).ConfigureAwait(false);
                    }
                    catch (Exception error)
                    {
                        diagnostics.RecordFailure("recovery-journal", error);
                    }
                },
                CancellationToken.None,
                TaskContinuationOptions.ExecuteSynchronously,
                TaskScheduler.Default).Unwrap();
        }
    }

    private static RecordingRecoveryCheckpoint? ToRecoveryCheckpoint(NativeDurableCheckpoint checkpoint)
    {
        if (!checkpoint.IsDurable ||
            checkpoint.DurableBytes > long.MaxValue ||
            checkpoint.PresentationTime100Nanoseconds > long.MaxValue)
        {
            return null;
        }

        return new RecordingRecoveryCheckpoint(
            checked((long)checkpoint.DurableBytes),
            checked((long)checkpoint.PresentationTime100Nanoseconds));
    }

    private void ResetRecoveryJournalState()
    {
        lastAudioCheckpointSequence = 0;
        lastVideoCheckpointSequence = 0;
        recoveryJournalSequence = 0;
        recoveryJournalWrite = Task.CompletedTask;
    }

    private void ReleaseActiveSessionLock()
    {
        activeSessionLock?.Dispose();
        activeSessionLock = null;
    }
    private void ThrowIfDisposed() { if (disposed) throw new ObjectDisposedException(nameof(RecordingLifecycleService)); }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        coordinator.SnapshotChanged -= OnSnapshotChanged;
        lock (stateGate) pendingStartCancellation?.Cancel();
        nativeBridge.Dispose();
        lock (stateGate) ReleaseActiveSessionLock();
        operationGate.Dispose();
    }
}

public sealed record RecordingLifecycleStartResult(RecordingCoordinatorSnapshot Snapshot, RecordingSessionPlan Session);
public sealed record RecordingSessionPublicationResult(RecordingSessionPlan? Session, bool Published, Exception? Error)
{
    public static RecordingSessionPublicationResult NoActiveSession { get; } = new(null, false, null);
}
