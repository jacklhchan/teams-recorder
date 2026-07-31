using Recorder.Core;
using TeamsRecorder.Windows.Application;

internal static class TeamsAutomaticRecordingControllerTests
{
    public static void StartsAfterCountdownAndStopsAfterDebounce()
    {
        var delay = new ControllableDelay();
        var starts = 0;
        var stops = 0;
        var controller = new TeamsAutomaticRecordingController(
            _ => { Interlocked.Increment(ref starts); return Task.FromResult(TeamsAutomaticStartResult.Succeeded()); },
            _ => { Interlocked.Increment(ref stops); return Task.CompletedTask; },
            new TeamsAutoMeetingMachine(startCountdownSeconds: 2, stopDebounceSeconds: 2),
            delay);

        controller.SetEnabledAsync(true).GetAwaiter().GetResult();
        controller.SetMeetingPresenceAsync(true).GetAwaiter().GetResult();
        delay.Tick(); delay.Tick();
        WaitUntil(() => Volatile.Read(ref starts) == 1, "Automatic start did not run after the countdown.");
        WaitUntil(() => controller.Snapshot.State is TeamsAutoMeetingState.AutomaticRecording, "Automatic start did not complete.");

        controller.SetMeetingPresenceAsync(false).GetAwaiter().GetResult();
        delay.Tick(); delay.Tick();
        WaitUntil(() => Volatile.Read(ref stops) == 1, "Automatic stop did not run after the debounce.");
        WaitUntil(() => controller.Snapshot.State is TeamsAutoMeetingState.WaitingForMeeting, "Automatic stop did not return to waiting.");
        controller.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    public static void CancelsLateAutomaticStartAndStopsLateCapture()
    {
        var delay = new ControllableDelay();
        var started = new TaskCompletionSource<TeamsAutomaticStartResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var stops = 0;
        var stopToken = new CancellationToken(canceled: true);
        var controller = new TeamsAutomaticRecordingController(
            _ => started.Task,
            token => { stopToken = token; Interlocked.Increment(ref stops); return Task.CompletedTask; },
            new TeamsAutoMeetingMachine(startCountdownSeconds: 1),
            delay);

        controller.SetEnabledAsync(true).GetAwaiter().GetResult();
        controller.SetMeetingPresenceAsync(true).GetAwaiter().GetResult();
        delay.Tick();
        WaitUntil(() => controller.Snapshot.State is TeamsAutoMeetingState.Starting, "Controller did not enter start state.");
        controller.SetMeetingPresenceAsync(false).GetAwaiter().GetResult();
        started.TrySetResult(TeamsAutomaticStartResult.Succeeded());
        WaitUntil(() => Volatile.Read(ref stops) == 1, "A start completing after cancellation was not stopped.");
        if (stopToken.IsCancellationRequested)
            throw new InvalidOperationException("Late capture cleanup received a cancelled token.");
        if (controller.Snapshot.RecordingOwner != RecordingOwner.None)
            throw new InvalidOperationException("A cancelled automatic start took recording ownership.");
        controller.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    public static void SnapshotHandlerCanSynchronouslyReenterWithoutDeadlock()
    {
        var delay = new ControllableDelay();
        var controller = new TeamsAutomaticRecordingController(
            _ => Task.FromResult(TeamsAutomaticStartResult.Succeeded()),
            _ => Task.CompletedTask,
            new TeamsAutoMeetingMachine(startCountdownSeconds: 1),
            delay);
        var reentered = new ManualResetEventSlim(false);
        controller.SnapshotChanged += (_, snapshot) =>
        {
            if (snapshot.State is TeamsAutoMeetingState.StartCountdown)
            {
                controller.SetMeetingPresenceAsync(false).GetAwaiter().GetResult();
                reentered.Set();
            }
        };

        controller.SetEnabledAsync(true).GetAwaiter().GetResult();
        controller.SetMeetingPresenceAsync(true).GetAwaiter().GetResult();
        if (!reentered.Wait(TimeSpan.FromSeconds(2)))
            throw new InvalidOperationException("Snapshot handler could not reenter the controller.");
        controller.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    public static void DisposeDoesNotWaitForAnUncooperativeStartAndStillStopsItLater()
    {
        var delay = new ControllableDelay();
        var started = new TaskCompletionSource<TeamsAutomaticStartResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var stops = 0;
        var stopToken = new CancellationToken(canceled: true);
        var controller = new TeamsAutomaticRecordingController(
            _ => started.Task,
            token => { stopToken = token; Interlocked.Increment(ref stops); return Task.CompletedTask; },
            new TeamsAutoMeetingMachine(startCountdownSeconds: 1),
            delay);

        controller.SetEnabledAsync(true).GetAwaiter().GetResult();
        controller.SetMeetingPresenceAsync(true).GetAwaiter().GetResult();
        delay.Tick();
        WaitUntil(() => controller.Snapshot.State is TeamsAutoMeetingState.Starting, "Controller did not enter start state.");

        var dispose = controller.DisposeAsync().AsTask();
        if (!dispose.Wait(TimeSpan.FromSeconds(2)))
            throw new InvalidOperationException("Dispose waited for an uncooperative start.");
        started.TrySetResult(TeamsAutomaticStartResult.Succeeded());
        WaitUntil(() => Volatile.Read(ref stops) == 1, "Late capture was not stopped after disposal.");
        if (stopToken.IsCancellationRequested)
            throw new InvalidOperationException("Disposed controller used a cancelled token to stop late capture.");
    }

    public static void BlockedStartWaitsForMeetingEndBeforeRetrying()
    {
        var delay = new ControllableDelay();
        var starts = 0;
        var controller = new TeamsAutomaticRecordingController(
            _ =>
            {
                Interlocked.Increment(ref starts);
                return Task.FromResult(TeamsAutomaticStartResult.BlockedBy("No writable recording location."));
            },
            _ => Task.CompletedTask,
            new TeamsAutoMeetingMachine(startCountdownSeconds: 1),
            delay);

        controller.SetEnabledAsync(true).GetAwaiter().GetResult();
        controller.SetMeetingPresenceAsync(true).GetAwaiter().GetResult();
        delay.Tick();
        WaitUntil(() => Volatile.Read(ref starts) == 1, "Blocked automatic start did not run.");
        WaitUntil(() => controller.Snapshot.State is TeamsAutoMeetingState.StartBlocked, "Blocked automatic start was not surfaced.");

        controller.SetMeetingPresenceAsync(true).GetAwaiter().GetResult();
        Thread.Sleep(50);
        if (Volatile.Read(ref starts) != 1)
            throw new InvalidOperationException("A blocked start retried without a meeting boundary.");

        controller.SetMeetingPresenceAsync(false).GetAwaiter().GetResult();
        controller.SetMeetingPresenceAsync(true).GetAwaiter().GetResult();
        delay.Tick();
        WaitUntil(() => Volatile.Read(ref starts) == 2, "Automatic recording did not retry after the meeting re-entered.");
        controller.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    private static void WaitUntil(Func<bool> condition, string message)
    {
        var deadline = DateTime.UtcNow.AddSeconds(2);
        while (!condition() && DateTime.UtcNow < deadline) Thread.Sleep(10);
        if (!condition()) throw new InvalidOperationException(message);
    }

    private sealed class ControllableDelay : IRecordingDelay
    {
        private readonly SemaphoreSlim ticks = new(0);
        public Task DelayAsync(TimeSpan duration, CancellationToken cancellationToken) => ticks.WaitAsync(cancellationToken);
        public void Tick() => ticks.Release();
    }
}
