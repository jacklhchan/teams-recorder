using Recorder.Core;

namespace TeamsRecorder.Windows.Application;

/// <summary>Result returned by the host after it attempts to start an automatic Teams recording.</summary>
public sealed record TeamsAutomaticStartResult(bool Started, bool Blocked, string? Detail)
{
    public static TeamsAutomaticStartResult Succeeded() => new(true, false, null);
    public static TeamsAutomaticStartResult BlockedBy(string detail) => new(false, true, detail);
    public static TeamsAutomaticStartResult Failed(string detail) => new(false, false, detail);
}

/// <summary>
/// Connects the deterministic Teams auto-recording reducer to host recording I/O.
/// It never sends a Teams mute command: meeting presence is its only Teams input.
/// </summary>
public sealed class TeamsAutomaticRecordingController : IAsyncDisposable
{
    private readonly object gate = new();
    private readonly SemaphoreSlim dispatchGate = new(1, 1);
    private readonly TeamsAutoMeetingMachine machine;
    private readonly IRecordingDelay delay;
    private readonly Func<CancellationToken, Task<TeamsAutomaticStartResult>> start;
    private readonly Func<CancellationToken, Task> stop;
    private readonly CancellationTokenSource lifetime = new();
    private TeamsAutoMeetingSnapshot snapshot = TeamsAutoMeetingSnapshot.Initial;
    private CancellationTokenSource? tickCancellation;
    private CancellationTokenSource? startCancellation;
    private TaskCompletionSource? operationsIdle;
    private int activeOperations;
    private Task? deferredDispose;
    private long latestMeetingEvidenceGeneration = -1;
    private long latestMeetingEvidenceRevision = -1;
    private bool disposed;

    public TeamsAutomaticRecordingController(
        Func<CancellationToken, Task<TeamsAutomaticStartResult>> start,
        Func<CancellationToken, Task> stop,
        TeamsAutoMeetingMachine? machine = null,
        IRecordingDelay? delay = null)
    {
        this.start = start ?? throw new ArgumentNullException(nameof(start));
        this.stop = stop ?? throw new ArgumentNullException(nameof(stop));
        this.machine = machine ?? new TeamsAutoMeetingMachine();
        this.delay = delay ?? new SystemRecordingDelay();
    }

    public event EventHandler<TeamsAutoMeetingSnapshot>? SnapshotChanged;
    public event EventHandler<string>? OperationFailed;

    public TeamsAutoMeetingSnapshot Snapshot { get { lock (gate) return snapshot; } }

    public Task SetEnabledAsync(bool enabled, CancellationToken cancellationToken = default) =>
        DispatchAsync(new TeamsAutoMeetingEvent.AutoMeetingEnabled(enabled), cancellationToken);

    public Task SetMeetingPresenceAsync(bool inMeeting, CancellationToken cancellationToken = default) =>
        DispatchAsync(new TeamsAutoMeetingEvent.MeetingPresenceChanged(inMeeting), cancellationToken);

    /// <summary>
    /// Accepts one user-authorized local heuristic candidate. This deliberately
    /// bypasses, and never updates, authoritative Teams generation/revision state.
    /// It can only propose presence=true; there is no local meeting-left path.
    /// </summary>
    public Task SetLocalMeetingCandidateAsync(CancellationToken cancellationToken = default) =>
        DispatchAsync(new TeamsAutoMeetingEvent.MeetingPresenceChanged(true), cancellationToken);

    /// <summary>Accepts only non-stale, paired-transport meeting evidence.</summary>
    public Task SetMeetingEvidenceAsync(TeamsMeetingEvidence evidence, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(evidence);
        lock (gate)
        {
            if (evidence.ConnectionGeneration < latestMeetingEvidenceGeneration ||
                (evidence.ConnectionGeneration == latestMeetingEvidenceGeneration &&
                 evidence.Revision <= latestMeetingEvidenceRevision))
                return Task.CompletedTask;
            latestMeetingEvidenceGeneration = evidence.ConnectionGeneration;
            latestMeetingEvidenceRevision = evidence.Revision;
        }
        TeamsAutoMeetingEvent @event = evidence switch
        {
            TeamsMeetingEvidence.JoinedConfirmed => new TeamsAutoMeetingEvent.MeetingPresenceChanged(true),
            TeamsMeetingEvidence.LeftConfirmed => new TeamsAutoMeetingEvent.MeetingPresenceChanged(false),
            TeamsMeetingEvidence.StateUnavailable => new TeamsAutoMeetingEvent.MeetingStateUnavailable(),
            _ => throw new ArgumentOutOfRangeException(nameof(evidence)),
        };
        return DispatchAsync(@event, cancellationToken);
    }

    public Task NotifyManualRecordingStartedAsync(CancellationToken cancellationToken = default) =>
        DispatchAsync(new TeamsAutoMeetingEvent.ManualRecordingStarted(), cancellationToken);

    public Task NotifyManualRecordingStoppedAsync(CancellationToken cancellationToken = default) =>
        DispatchAsync(new TeamsAutoMeetingEvent.ManualRecordingStopped(), cancellationToken);

    /// <summary>
    /// Cancels only the pending automatic start for the current meeting. The opt-in setting
    /// remains enabled; automation becomes eligible again after Teams reports meeting end.
    /// </summary>
    public Task CancelStartCountdownAsync(CancellationToken cancellationToken = default) =>
        DispatchAsync(new TeamsAutoMeetingEvent.StartCountdownCancelled(), cancellationToken);

    public Task SuppressUntilMeetingEndsAsync(CancellationToken cancellationToken = default) =>
        DispatchAsync(new TeamsAutoMeetingEvent.SuppressUntilMeetingEnd(), cancellationToken);

    private async Task DispatchAsync(TeamsAutoMeetingEvent @event, CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        await dispatchGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        EventHandler<TeamsAutoMeetingSnapshot>? snapshotChanged = null;
        TeamsAutoMeetingSnapshot? changedSnapshot = null;
        try
        {
            ThrowIfDisposed();
            TeamsAutoMeetingTransition transition;
            lock (gate)
            {
                transition = machine.Reduce(snapshot, @event);
                if (snapshot != transition.Snapshot)
                {
                    snapshot = transition.Snapshot;
                    snapshotChanged = SnapshotChanged;
                    changedSnapshot = snapshot;
                }
                RefreshTickerLocked();
            }

            foreach (var command in transition.Commands)
            {
                Execute(command);
            }
        }
        finally
        {
            dispatchGate.Release();
        }

        // Event handlers may synchronously call back into the controller (or dispose it),
        // so never invoke them while either controller lock is held.
        snapshotChanged?.Invoke(this, changedSnapshot!);
    }

    private void Execute(TeamsAutoMeetingCommand command)
    {
        switch (command)
        {
            case TeamsAutoMeetingCommand.StartAutomaticRecording:
                CancelStart();
                lock (gate)
                {
                    startCancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
                    TrackOperationLocked(StartAsync(startCancellation));
                }
                break;
            case TeamsAutoMeetingCommand.CancelAutomaticStart:
                CancelStart();
                break;
            case TeamsAutoMeetingCommand.StopAutomaticRecording:
                lock (gate)
                {
                    TrackOperationLocked(StopAsync(lifetime.Token));
                }
                break;
            case TeamsAutoMeetingCommand.TransferAutomaticRecordingToManual:
                // The reducer has already changed ownership.  Existing capture continues.
                break;
        }
    }

    private async Task StartAsync(CancellationTokenSource cancellation)
    {
        try
        {
            var result = await start(cancellation.Token).ConfigureAwait(false);
            if (cancellation.IsCancellationRequested)
            {
                if (result.Started)
                {
                    // A host may finish a start after ignoring cancellation.  Its capture
                    // still has to be stopped, even when the controller is shutting down.
                    await StopLateCaptureAsync().ConfigureAwait(false);
                }
                return;
            }

            if (result.Started)
            {
                await DispatchOperationResultAsync(new TeamsAutoMeetingEvent.AutomaticStartSucceeded()).ConfigureAwait(false);
            }
            else if (result.Blocked)
            {
                await DispatchOperationResultAsync(new TeamsAutoMeetingEvent.AutomaticStartBlocked(result.Detail ?? "Automatic recording is not currently available.")).ConfigureAwait(false);
            }
            else
            {
                await DispatchOperationResultAsync(new TeamsAutoMeetingEvent.AutomaticStartFailed(result.Detail ?? "Automatic recording could not start.")).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
            // The reducer deliberately cancelled a countdown/start after meeting state changed.
        }
        catch (Exception error)
        {
            if (!IsDisposed)
            {
                await DispatchOperationResultAsync(new TeamsAutoMeetingEvent.AutomaticStartFailed(error.Message)).ConfigureAwait(false);
            }
        }
        finally
        {
            lock (gate)
            {
                if (ReferenceEquals(startCancellation, cancellation)) startCancellation = null;
            }
            cancellation.Dispose();
        }
    }

    private async Task StopAsync(CancellationToken cancellationToken)
    {
        try
        {
            await stop(cancellationToken).ConfigureAwait(false);
            await DispatchOperationResultAsync(new TeamsAutoMeetingEvent.AutomaticStopCompleted()).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
            // Shutdown preserves the recoverable work file; it does not start another recording.
        }
        catch (Exception error)
        {
            OperationFailed?.Invoke(this, error.Message);
        }
    }

    private async Task StopLateCaptureAsync()
    {
        try
        {
            await stop(CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            OperationFailed?.Invoke(this, error.Message);
        }
    }

    private async Task DispatchOperationResultAsync(TeamsAutoMeetingEvent @event)
    {
        if (IsDisposed) return;
        try
        {
            await DispatchAsync(@event, lifetime.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
        }
        catch (ObjectDisposedException) when (IsDisposed)
        {
        }
    }

    private void RefreshTickerLocked()
    {
        var shouldTick = snapshot.State is TeamsAutoMeetingState.StartCountdown or TeamsAutoMeetingState.StopCountdown;
        if (!shouldTick)
        {
            tickCancellation?.Cancel();
            tickCancellation = null;
            return;
        }
        if (tickCancellation is not null) return;
        tickCancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        TrackOperationLocked(TickAsync(tickCancellation));
    }

    private async Task TickAsync(CancellationTokenSource cancellation)
    {
        try
        {
            while (!cancellation.IsCancellationRequested)
            {
                await delay.DelayAsync(TimeSpan.FromSeconds(1), cancellation.Token).ConfigureAwait(false);
                TeamsAutoMeetingEvent? @event = Snapshot.State switch
                {
                    TeamsAutoMeetingState.StartCountdown => new TeamsAutoMeetingEvent.StartCountdownTicked(),
                    TeamsAutoMeetingState.StopCountdown => new TeamsAutoMeetingEvent.StopDebounceTicked(),
                    _ => null,
                };
                if (@event is null) return;
                await DispatchAsync(@event, lifetime.Token).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
        }
        finally
        {
            lock (gate)
            {
                if (ReferenceEquals(tickCancellation, cancellation)) tickCancellation = null;
            }
            cancellation.Dispose();
        }
    }

    private void CancelStart()
    {
        lock (gate)
        {
            startCancellation?.Cancel();
            startCancellation = null;
        }
    }

    private bool IsDisposed
    {
        get { lock (gate) return disposed; }
    }

    private void TrackOperationLocked(Task operation)
    {
        if (activeOperations++ == 0)
        {
            operationsIdle = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        }

        _ = operation.ContinueWith(
            _ =>
            {
                lock (gate)
                {
                    if (--activeOperations == 0) operationsIdle!.TrySetResult();
                }
            },
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }

    public async ValueTask DisposeAsync()
    {
        lock (gate)
        {
            if (disposed) return;
            disposed = true;
            tickCancellation?.Cancel();
            tickCancellation = null;
            startCancellation?.Cancel();
            startCancellation = null;
            lifetime.Cancel();
        }
        await dispatchGate.WaitAsync().ConfigureAwait(false);
        dispatchGate.Release();
        Task idle;
        lock (gate)
        {
            idle = activeOperations == 0 ? Task.CompletedTask : operationsIdle!.Task;
            deferredDispose ??= DisposeWhenOperationsFinishAsync(idle);
        }
        await Task.CompletedTask.ConfigureAwait(false);
    }

    private async Task DisposeWhenOperationsFinishAsync(Task idle)
    {
        await idle.ConfigureAwait(false);
        lifetime.Dispose();
        dispatchGate.Dispose();
    }

    private void ThrowIfDisposed()
    {
        lock (gate)
        {
            if (disposed) throw new ObjectDisposedException(nameof(TeamsAutomaticRecordingController));
        }
    }
}
