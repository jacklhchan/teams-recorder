namespace TeamsRecorder.Windows.Application;

public enum RecordingCoordinatorState
{
    Ready,
    Starting,
    Recording,
    Stopping,
    Failed,
    Faulted,
    Stopped,
}

public sealed record RecordingCoordinatorSnapshot(
    long Generation,
    RecordingCoordinatorState State,
    NativeRecordingRequest? Request,
    NativeCaptureStats Stats,
    string? Error,
    bool IsTestRecording,
    bool NeedsNativeCleanup)
{
    public static RecordingCoordinatorSnapshot Initial { get; } = new(
        Generation: 0,
        State: RecordingCoordinatorState.Ready,
        Request: null,
        Stats: NativeCaptureStats.Empty(RecordingCaptureMode.SystemLoopback),
        Error: null,
        IsTestRecording: false,
        NeedsNativeCleanup: false);
}

public interface IRecordingDelay
{
    Task DelayAsync(TimeSpan duration, CancellationToken cancellationToken);
}

public sealed class SystemRecordingDelay : IRecordingDelay
{
    public Task DelayAsync(TimeSpan duration, CancellationToken cancellationToken) =>
        Task.Delay(duration, cancellationToken);
}

public sealed class RecordingCoordinator
{
    private readonly object stateGate = new();
    private readonly object nativeQueueGate = new();
    private readonly INativeRecorderBridge nativeBridge;
    private readonly IRecordingDelay delay;
    private readonly SynchronizationContext? notificationContext;
    private Task nativeTail = Task.CompletedTask;
    private RecordingCoordinatorSnapshot snapshot = RecordingCoordinatorSnapshot.Initial;
    private Task<RecordingCoordinatorSnapshot>? stopTask;
    private Task<RecordingCoordinatorSnapshot>? refreshTask;
    private Task<NativeEndpointEnumerationResult>? endpointRefreshTask;
    private CancellationTokenSource? testCancellation;

    public RecordingCoordinator(
        INativeRecorderBridge nativeBridge,
        IRecordingDelay? delay = null,
        SynchronizationContext? notificationContext = null)
    {
        this.nativeBridge = nativeBridge ?? throw new ArgumentNullException(nameof(nativeBridge));
        this.delay = delay ?? new SystemRecordingDelay();
        this.notificationContext = notificationContext ?? SynchronizationContext.Current;
    }

    public event EventHandler<RecordingCoordinatorSnapshot>? SnapshotChanged;

    public RecordingCoordinatorSnapshot Snapshot
    {
        get
        {
            lock (stateGate)
            {
                return snapshot;
            }
        }
    }

    public Task<RecordingCoordinatorSnapshot> StartAsync(NativeRecordingRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        request.Validate();

        RecordingCoordinatorSnapshot starting;
        Task<RecordingCoordinatorSnapshot> operation;
        lock (stateGate)
        {
            if (snapshot.State is RecordingCoordinatorState.Starting or
                RecordingCoordinatorState.Recording or
                RecordingCoordinatorState.Stopping or
                RecordingCoordinatorState.Faulted)
            {
                throw new InvalidOperationException("A recording lifecycle operation is already active.");
            }

            CancelTestLocked();
            starting = new RecordingCoordinatorSnapshot(
                Generation: checked(snapshot.Generation + 1),
                State: RecordingCoordinatorState.Starting,
                Request: request,
                Stats: NativeCaptureStats.Empty(request.Mode),
                Error: null,
                IsTestRecording: false,
                NeedsNativeCleanup: false);
            snapshot = starting;
            stopTask = null;
            refreshTask = null;
            operation = Enqueue(() => StartCore(starting.Generation, request));
        }

        Publish(starting);
        return operation;
    }

    public async Task<RecordingCoordinatorSnapshot> StartTestAsync(
        NativeRecordingRequest request,
        TimeSpan duration)
    {
        if (duration <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(duration), "The test duration must be positive.");
        }

        var started = await StartAsync(request).ConfigureAwait(false);
        if (started.State != RecordingCoordinatorState.Recording)
        {
            return started;
        }

        RecordingCoordinatorSnapshot testing;
        CancellationTokenSource cancellation;
        lock (stateGate)
        {
            if (snapshot.Generation != started.Generation ||
                snapshot.State != RecordingCoordinatorState.Recording)
            {
                return snapshot;
            }

            CancelTestLocked();
            cancellation = new CancellationTokenSource();
            testCancellation = cancellation;
            testing = snapshot with { IsTestRecording = true };
            snapshot = testing;
        }

        Publish(testing);
        _ = StopTestAfterDelayAsync(testing.Generation, duration, cancellation);
        return testing;
    }

    public Task<RecordingCoordinatorSnapshot> StopAsync()
    {
        RecordingCoordinatorSnapshot stopping;
        Task<RecordingCoordinatorSnapshot> operation;
        lock (stateGate)
        {
            if (snapshot.State == RecordingCoordinatorState.Ready ||
                snapshot.State == RecordingCoordinatorState.Stopped ||
                snapshot.State == RecordingCoordinatorState.Failed ||
                (snapshot.State == RecordingCoordinatorState.Faulted &&
                 !snapshot.NeedsNativeCleanup))
            {
                return Task.FromResult(snapshot);
            }

            if (snapshot.State == RecordingCoordinatorState.Stopping)
            {
                return stopTask ?? Task.FromResult(snapshot);
            }

            CancelTestLocked();
            stopping = snapshot with
            {
                State = RecordingCoordinatorState.Stopping,
                Error = null,
                IsTestRecording = false,
                NeedsNativeCleanup = false,
            };
            snapshot = stopping;
            operation = Enqueue(() => StopCore(stopping.Generation));
            stopTask = operation;
        }

        Publish(stopping);
        return operation;
    }

    public Task<RecordingCoordinatorSnapshot> RefreshAsync()
    {
        lock (stateGate)
        {
            if (snapshot.State != RecordingCoordinatorState.Recording)
            {
                return Task.FromResult(snapshot);
            }

            if (refreshTask is { IsCompleted: false })
            {
                return refreshTask;
            }

            var generation = snapshot.Generation;
            refreshTask = Enqueue(() => RefreshCore(generation));
            return refreshTask;
        }
    }

    public Task<NativeEndpointEnumerationResult> RefreshEndpointsAsync()
    {
        lock (stateGate)
        {
            if (endpointRefreshTask is { IsCompleted: false })
            {
                return endpointRefreshTask;
            }

            endpointRefreshTask = Enqueue(RefreshEndpointsCore);
            return endpointRefreshTask;
        }
    }

    private RecordingCoordinatorSnapshot StartCore(long generation, NativeRecordingRequest request)
    {
        var result = InvokeNative(() => nativeBridge.Start(request), "start audio capture");
        RecordingCoordinatorSnapshot completed;
        var shouldPublish = false;
        lock (stateGate)
        {
            if (snapshot.Generation != generation ||
                snapshot.State != RecordingCoordinatorState.Starting)
            {
                return snapshot;
            }

            completed = result.IsSuccess
                ? snapshot with
                {
                    State = RecordingCoordinatorState.Recording,
                    Error = null,
                    NeedsNativeCleanup = false,
                }
                : snapshot with
                {
                    State = RecordingCoordinatorState.Failed,
                    Error = UserMessage(result, "Audio capture could not start."),
                    NeedsNativeCleanup = false,
                };
            snapshot = completed;
            shouldPublish = true;
        }

        if (shouldPublish)
        {
            Publish(completed);
        }
        return completed;
    }

    private RecordingCoordinatorSnapshot StopCore(long generation)
    {
        var result = InvokeNative(nativeBridge.Stop, "stop audio capture");
        var nativeSnapshot = ReadNativeSnapshot();
        RecordingCoordinatorSnapshot completed;
        var shouldPublish = false;
        lock (stateGate)
        {
            if (snapshot.Generation != generation ||
                snapshot.State != RecordingCoordinatorState.Stopping)
            {
                return snapshot;
            }

            var stats = nativeSnapshot?.Stats ?? snapshot.Stats;
            completed = result.IsSuccess
                ? snapshot with
                {
                    State = RecordingCoordinatorState.Stopped,
                    Stats = stats,
                    Error = null,
                    IsTestRecording = false,
                    NeedsNativeCleanup = false,
                }
                : snapshot with
                {
                    State = RecordingCoordinatorState.Faulted,
                    Stats = stats,
                    Error = UserMessage(result, "Audio capture could not stop cleanly."),
                    IsTestRecording = false,
                    NeedsNativeCleanup = false,
                };
            snapshot = completed;
            stopTask = null;
            shouldPublish = true;
        }

        if (shouldPublish)
        {
            Publish(completed);
        }
        return completed;
    }

    private RecordingCoordinatorSnapshot RefreshCore(long generation)
    {
        var nativeSnapshot = ReadNativeSnapshot();
        RecordingCoordinatorSnapshot refreshed;
        var shouldPublish = false;
        lock (stateGate)
        {
            if (snapshot.Generation != generation ||
                snapshot.State != RecordingCoordinatorState.Recording)
            {
                return snapshot;
            }

            if (nativeSnapshot is null || nativeSnapshot.Result != NativeRecorderResult.Ok)
            {
                refreshed = snapshot with
                {
                    State = RecordingCoordinatorState.Faulted,
                    Error = nativeSnapshot?.Error ?? "Audio capture status is unavailable.",
                    IsTestRecording = false,
                    NeedsNativeCleanup = true,
                };
            }
            else if (nativeSnapshot.State == NativeRecorderState.Recording)
            {
                refreshed = snapshot with
                {
                    Stats = nativeSnapshot.Stats,
                    Error = null,
                };
            }
            else
            {
                refreshed = snapshot with
                {
                    State = RecordingCoordinatorState.Faulted,
                    Stats = nativeSnapshot.Stats,
                    Error = nativeSnapshot.Error ?? "Audio capture ended unexpectedly.",
                    IsTestRecording = false,
                    NeedsNativeCleanup = nativeSnapshot.State == NativeRecorderState.Faulted,
                };
            }

            snapshot = refreshed;
            refreshTask = null;
            shouldPublish = true;
        }

        if (shouldPublish)
        {
            Publish(refreshed);
        }
        return refreshed;
    }

    private NativeEndpointEnumerationResult RefreshEndpointsCore()
    {
        try
        {
            return nativeBridge.EnumerateEndpoints();
        }
        catch
        {
            return new NativeEndpointEnumerationResult(
                NativeOperationResult.Failure(
                    NativeRecorderResult.InternalError,
                    "The native audio bridge could not refresh audio devices."),
                Array.Empty<NativeCaptureEndpoint>());
        }
        finally
        {
            lock (stateGate)
            {
                endpointRefreshTask = null;
            }
        }
    }

    private async Task StopTestAfterDelayAsync(
        long generation,
        TimeSpan duration,
        CancellationTokenSource cancellation)
    {
        try
        {
            await delay.DelayAsync(duration, cancellation.Token).ConfigureAwait(false);

            lock (stateGate)
            {
                if (!ReferenceEquals(testCancellation, cancellation) ||
                    snapshot.Generation != generation ||
                    snapshot.State != RecordingCoordinatorState.Recording ||
                    !snapshot.IsTestRecording)
                {
                    return;
                }
            }

            await StopAsync().ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
            // A manual stop or replacement session owns the lifecycle now.
        }
        finally
        {
            lock (stateGate)
            {
                if (ReferenceEquals(testCancellation, cancellation))
                {
                    testCancellation = null;
                }
            }
            cancellation.Dispose();
        }
    }

    private NativeRecorderSnapshot? ReadNativeSnapshot()
    {
        try
        {
            return nativeBridge.GetSnapshot();
        }
        catch
        {
            return null;
        }
    }

    private static NativeOperationResult InvokeNative(
        Func<NativeOperationResult> operation,
        string action)
    {
        try
        {
            return operation();
        }
        catch
        {
            return NativeOperationResult.Failure(
                NativeRecorderResult.InternalError,
                $"The native audio bridge could not {action}.");
        }
    }

    private static string UserMessage(NativeOperationResult result, string fallback) =>
        string.IsNullOrWhiteSpace(result.Error) ? fallback : result.Error;

    private Task<T> Enqueue<T>(Func<T> operation)
    {
        lock (nativeQueueGate)
        {
            var next = nativeTail.ContinueWith(
                _ => operation(),
                CancellationToken.None,
                TaskContinuationOptions.None,
                TaskScheduler.Default);
            nativeTail = next.ContinueWith(
                static _ => { },
                CancellationToken.None,
                TaskContinuationOptions.None,
                TaskScheduler.Default);
            return next;
        }
    }

    private void CancelTestLocked()
    {
        if (testCancellation is null)
        {
            return;
        }

        testCancellation.Cancel();
        testCancellation = null;
    }

    private void Publish(RecordingCoordinatorSnapshot changedSnapshot)
    {
        var subscribers = SnapshotChanged;
        if (subscribers is null)
        {
            return;
        }

        void Dispatch()
        {
            foreach (EventHandler<RecordingCoordinatorSnapshot> subscriber in subscribers.GetInvocationList())
            {
                try
                {
                    subscriber(this, changedSnapshot);
                }
                catch
                {
                    // UI observers must not turn a completed native operation into a fault.
                }
            }
        }

        if (notificationContext is not null &&
            !ReferenceEquals(notificationContext, SynchronizationContext.Current))
        {
            try
            {
                notificationContext.Post(static state => ((Action)state!).Invoke(), (Action)Dispatch);
                return;
            }
            catch
            {
                // Fall through when an application is shutting down its dispatcher.
            }
        }

        Dispatch();
    }
}
