using Recorder.Core;
using TeamsRecorder.Windows.Application.Diagnostics;
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
    private Task<RecordingSessionPublicationResult>? publication;
    private readonly CaptureSourceSelectionPolicy captureSourcePolicy;
    private readonly IRecordingDiagnostics diagnostics;
    private CancellationTokenSource? pendingStartCancellation;
    private long generation;
    private RecordingSessionKind? activeSessionKind;
    private WindowsCaptureMetadata? activeWindowsCapture;
    private readonly List<VideoPublicationSegment> completedVideoSegments = [];
    private string? activeVideoFileName;
    private int nextVideoSegmentOrdinal;
    private bool videoLossDetected;
    private bool disposed;

    public RecordingLifecycleService(
        INativeRecorderBridge nativeBridge,
        string storageRoot,
        IProcessCatalog? processCatalog = null,
        IRecordingDelay? recordingDelay = null,
        IRecordingDiagnostics? diagnostics = null)
    {
        this.nativeBridge = nativeBridge ?? throw new ArgumentNullException(nameof(nativeBridge));
        coordinator = new RecordingCoordinator(nativeBridge, recordingDelay);
        coordinator.SnapshotChanged += OnSnapshotChanged;
        storage = new SessionStorageService(storageRoot);
        captureSourcePolicy = new CaptureSourceSelectionPolicy(processCatalog);
        this.diagnostics = diagnostics ?? LocalDiagnosticLog.CreateDefault();
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

    /// <summary>
    /// True only when the loaded bridge has the WGC/MP4 companion entry points.
    /// This probes the installed DLL rather than inferring availability from the
    /// managed type, so an older deployed DLL keeps the WinUI control disabled.
    /// </summary>
    public bool IsWindowVideoCaptureAvailable => nativeBridge is INativeWindowVideoRecorderBridge video &&
        video.GetWindowVideoSnapshot().Operation.Result != NativeRecorderResult.NotImplemented;

    /// <summary>Returns the next owned MP4 artifact without reserving it.</summary>
    public string GetNextWindowVideoOutputPath()
    {
        ThrowIfDisposed();
        lock (stateGate)
        {
            if (activeSession is null || activeVideoFileName is not null)
                throw new InvalidOperationException("A new Teams window video segment is not currently startable.");
            return Path.Combine(activeSession.FolderPath,
                RecordingSessionLayout.VideoSegmentFileName(nextVideoSegmentOrdinal + 1));
        }
    }

    /// <summary>
    /// Starts an optional MP4 companion for the current audio-first session.
    /// The path is constrained to that session's owned folder, so UI callers
    /// cannot redirect native video output outside the recording library.
    /// </summary>
    public NativeOperationResult StartWindowVideo(NativeWindowVideoRecordingRequest request)
    {
        operationGate.Wait();
        try { return StartWindowVideoCore(request); }
        finally { operationGate.Release(); }
    }

    private NativeOperationResult StartWindowVideoCore(NativeWindowVideoRecordingRequest request)
    {
        ThrowIfDisposed();
        ArgumentNullException.ThrowIfNull(request);
        request.Validate();
        RecordingSessionPlan? plan;
        lock (stateGate) plan = activeSession;
        if (plan is null || coordinator.Snapshot.State != RecordingCoordinatorState.Recording)
            return NativeOperationResult.Failure(NativeRecorderResult.InvalidState,
                "Window video can start only while an audio session is recording.");

        string expected;
        lock (stateGate)
        {
            if (activeVideoFileName is not null)
                return NativeOperationResult.Failure(NativeRecorderResult.InvalidState,
                    "A Teams window video segment is already active.");
            expected = Path.Combine(plan.FolderPath,
                RecordingSessionLayout.VideoSegmentFileName(nextVideoSegmentOrdinal + 1));
        }
        if (!string.Equals(Path.GetFullPath(request.OutputPath), expected, StringComparison.OrdinalIgnoreCase))
            return NativeOperationResult.Failure(NativeRecorderResult.InvalidArgument,
                "Window video output must be the current session companion path.");
        if (File.Exists(expected))
            return NativeOperationResult.Failure(NativeRecorderResult.InvalidState,
                "The next Teams window video segment already exists and will not be overwritten.");
        lock (stateGate)
        {
            // Consume an ordinal before native ingress. A failed capture can
            // leave recoverable partial media, which a later restart must never overwrite.
            if (activeVideoFileName is not null || !string.Equals(expected,
                Path.Combine(plan.FolderPath, RecordingSessionLayout.VideoSegmentFileName(nextVideoSegmentOrdinal + 1)),
                StringComparison.OrdinalIgnoreCase))
                return NativeOperationResult.Failure(NativeRecorderResult.InvalidState,
                    "The Teams window video segment changed before capture could start.");
            nextVideoSegmentOrdinal++;
        }
        var result = nativeBridge is INativeWindowVideoRecorderBridge video
            ? video.StartWindowVideo(request)
            : NativeOperationResult.Failure(NativeRecorderResult.NotImplemented,
                "The installed native recorder does not include Teams window video capture.");
        lock (stateGate)
        {
            if (result.IsSuccess)
            {
                activeVideoFileName = Path.GetFileName(expected);
            }
            else videoLossDetected = true;
        }
        return result;
    }

    public NativeOperationResult StopWindowVideo()
    {
        operationGate.Wait();
        try { return StopWindowVideoCore(); }
        finally { operationGate.Release(); }
    }

    private NativeOperationResult StopWindowVideoCore()
    {
        ThrowIfDisposed();
        string? fileName;
        lock (stateGate) fileName = activeVideoFileName;
        if (fileName is null) return NativeOperationResult.Failure(NativeRecorderResult.InvalidState,
            "No Teams window video segment is active.");
        var stopped = nativeBridge is INativeWindowVideoRecorderBridge video
            ? video.StopWindowVideo()
            : NativeOperationResult.Failure(NativeRecorderResult.NotImplemented,
                "The installed native recorder does not include Teams window video capture.");
        lock (stateGate)
        {
            activeVideoFileName = null;
            // The interval is valid only after the native writer has finalized;
            // pre-stop stats can omit its drained tail or report a later fault.
            var final = GetWindowVideoSnapshot();
            if (stopped.IsSuccess && final.Operation.IsSuccess && TryCreateVideoInterval(final, out var interval) &&
                activeSession is { } plan && IsNonEmptyFile(Path.Combine(plan.FolderPath, fileName)))
                completedVideoSegments.Add(new VideoPublicationSegment(fileName, interval));
            else videoLossDetected = true;
        }
        return stopped;
    }

    public NativeWindowVideoSnapshot GetWindowVideoSnapshot() => nativeBridge is INativeWindowVideoRecorderBridge video
        ? video.GetWindowVideoSnapshot()
        : new NativeWindowVideoSnapshot(NativeOperationResult.Failure(NativeRecorderResult.NotImplemented,
            "The installed native recorder does not include Teams window video capture."), false, 0, 0, 0, 0, 0, 0);

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
                activeSession = plan;
                activeSessionKind = request.Kind;
                activeWindowsCapture = RecordingStartMetadataPolicy.CreateWindowsCaptureMetadata(request);
                ResetVideoState();
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
                activeSession = plan;
                activeSessionKind = kind;
                activeWindowsCapture = WindowsCaptureMetadata.ForSystemLoopback(renderEndpointId);
                ResetVideoState();
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
        try
        {
            // recorder_native_stop owns the shared stop boundary: it first
            // freezes both companion ingresses, drains/finalizes M4A, then
            // finalizes MP4. Calling StopWindowVideo here would cut the MP4
            // audio tail before that coordinated drain.
            string? activeFile;
            lock (stateGate) activeFile = activeVideoFileName;
            var stopped = await coordinator.StopAsync().ConfigureAwait(false);
            if (activeFile is not null)
            {
                lock (stateGate)
                {
                    activeVideoFileName = null;
                    // coordinator.StopAsync reaches native's coordinated finalizer;
                    // query only afterwards so MP4 tail/drain stats are authoritative.
                    var final = GetWindowVideoSnapshot();
                    if (stopped.State == RecordingCoordinatorState.Stopped && final.Operation.IsSuccess &&
                        TryCreateVideoInterval(final, out var interval) &&
                        activeSession is { } plan && IsNonEmptyFile(Path.Combine(plan.FolderPath, activeFile)))
                        completedVideoSegments.Add(new VideoPublicationSegment(activeFile, interval));
                    else videoLossDetected = true;
                }
            }
            return stopped;
        }
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
            ResetVideoState();
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
                ResetVideoState();
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
            VideoPublicationOutcome videoOutcome;
            VideoPublicationSegment[] videoSegments;
            lock (stateGate)
            {
                current = storage;
                capture = activeWindowsCapture;
                videoOutcome = videoLossDetected
                    ? VideoPublicationOutcome.LostAudioPreserved
                    : completedVideoSegments.Count > 0
                        ? VideoPublicationOutcome.Completed
                        : VideoPublicationOutcome.None;
                videoSegments = completedVideoSegments.ToArray();
            }
            await current.PublishCompletedMediaAsync(plan, title: null, windowsCapture: capture,
                videoOutcome: videoOutcome, videoSegments: videoSegments).ConfigureAwait(false);
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
                ResetVideoState();
                }
                publication = null;
            }
        }
    }

    private static bool TryCreateVideoInterval(NativeWindowVideoSnapshot snapshot, out VideoPublicationInterval interval)
    {
        interval = default;
        if (snapshot.FirstAcceptedVideoPts100Nanoseconds > long.MaxValue ||
            snapshot.LastAcceptedVideoEnd100Nanoseconds > long.MaxValue)
            return false;
        interval = new VideoPublicationInterval(
            TimeSpan.FromTicks((long)snapshot.FirstAcceptedVideoPts100Nanoseconds),
            TimeSpan.FromTicks((long)snapshot.LastAcceptedVideoEnd100Nanoseconds));
        return interval.IsValid;
    }

    private static bool IsNonEmptyFile(string path) => File.Exists(path) && new FileInfo(path).Length > 0;

    // Must be called under stateGate.
    private void ResetVideoState()
    {
        completedVideoSegments.Clear();
        activeVideoFileName = null;
        nextVideoSegmentOrdinal = 0;
        videoLossDetected = false;
    }

    private void OnSnapshotChanged(object? sender, RecordingCoordinatorSnapshot snapshot)
    {
        diagnostics.RecordSnapshot(snapshot);
        SnapshotChanged?.Invoke(this, snapshot);
    }
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
