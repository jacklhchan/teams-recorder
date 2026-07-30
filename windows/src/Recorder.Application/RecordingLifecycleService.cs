using Recorder.Core;
using TeamsRecorder.Windows.Application.Storage;

namespace TeamsRecorder.Windows.Application;

/// <summary>
/// Serializes native capture with session allocation and publication.  A UI can
/// request operations concurrently (for example manual and Teams automation),
/// but this service makes each transition atomic at the application boundary.
/// </summary>
public sealed class RecordingLifecycleService : IDisposable
{
    private readonly INativeRecorderBridge nativeBridge;
    private readonly RecordingCoordinator coordinator;
    private readonly SemaphoreSlim operationGate = new(1, 1);
    private readonly object stateGate = new();
    private SessionStorageService storage;
    private RecordingSessionPlan? activeSession;
    private Task<RecordingSessionPublicationResult>? publication;
    private readonly CaptureSourceSelectionPolicy captureSourcePolicy;
    private CancellationTokenSource? pendingStartCancellation;
    private long generation;
    private RecordingSessionKind? activeSessionKind;
    private WindowsCaptureMetadata? activeWindowsCapture;
    private bool disposed;

    public RecordingLifecycleService(
        INativeRecorderBridge nativeBridge,
        string storageRoot,
        IProcessCatalog? processCatalog = null,
        IRecordingDelay? recordingDelay = null)
    {
        this.nativeBridge = nativeBridge ?? throw new ArgumentNullException(nameof(nativeBridge));
        coordinator = new RecordingCoordinator(nativeBridge, recordingDelay);
        coordinator.SnapshotChanged += OnSnapshotChanged;
        storage = new SessionStorageService(storageRoot);
        captureSourcePolicy = new CaptureSourceSelectionPolicy(processCatalog);
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
                activeSession = plan;
                activeSessionKind = request.Kind;
                activeWindowsCapture = RecordingStartMetadataPolicy.CreateWindowsCaptureMetadata(request);
                capture = activeWindowsCapture;
                currentStorage = storage;
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
                    plan.BackupAudioPath);
                started = request.Kind == RecordingSessionKind.Test
                    ? await coordinator.StartSelectedAudioTestAsync(nativeRequest, request.TestDuration!.Value).ConfigureAwait(false)
                    : await coordinator.StartSelectedAudioAsync(nativeRequest).ConfigureAwait(false);
            }
            else
            {
                var nativeRequest = new NativeMixedRecordingRequest(
                    plan.BackupAudioPath,
                    request.RenderEndpointId,
                    request.MicrophoneEndpointId);
                started = request.Kind == RecordingSessionKind.Test
                    ? await coordinator.StartMixedTestAsync(nativeRequest, request.TestDuration!.Value).ConfigureAwait(false)
                    : await coordinator.StartMixedAsync(nativeRequest).ConfigureAwait(false);
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
        catch
        {
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
                activeSession = plan;
                activeSessionKind = kind;
                activeWindowsCapture = WindowsCaptureMetadata.ForSystemLoopback(renderEndpointId);
                generation = checked(generation + 1);
            }

            try
            {
                await storage.WriteProvisionalMetadataAsync(plan, activeWindowsCapture).ConfigureAwait(false);
                var request = new NativeMixedRecordingRequest(plan.BackupAudioPath, renderEndpointId, microphoneEndpointId);
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
        if (stopped.State == RecordingCoordinatorState.Stopped && !stopped.HasRecoverableFault)
            return await PublishCompletedAsync().ConfigureAwait(false);

        RecordingSessionPlan? plan;
        lock (stateGate)
        {
            plan = activeSession;
            activeSession = null;
            activeSessionKind = null;
            activeWindowsCapture = null;
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

    private void ClearFailedStart(RecordingSessionPlan plan)
    {
        lock (stateGate)
        {
            if (activeSession == plan)
            {
                activeSession = null;
                activeSessionKind = null;
                activeWindowsCapture = null;
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
            lock (stateGate)
            {
                current = storage;
                capture = activeWindowsCapture;
            }
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
                }
                publication = null;
            }
        }
    }

    private void OnSnapshotChanged(object? sender, RecordingCoordinatorSnapshot snapshot) => SnapshotChanged?.Invoke(this, snapshot);
    private void ThrowIfDisposed() { if (disposed) throw new ObjectDisposedException(nameof(RecordingLifecycleService)); }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        coordinator.SnapshotChanged -= OnSnapshotChanged;
        lock (stateGate) pendingStartCancellation?.Cancel();
        nativeBridge.Dispose();
        operationGate.Dispose();
    }
}

public sealed record RecordingLifecycleStartResult(RecordingCoordinatorSnapshot Snapshot, RecordingSessionPlan Session);
public sealed record RecordingSessionPublicationResult(RecordingSessionPlan? Session, bool Published, Exception? Error)
{
    public static RecordingSessionPublicationResult NoActiveSession { get; } = new(null, false, null);
}
