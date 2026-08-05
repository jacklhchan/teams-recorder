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

    public static void PublishesEachCountdownSnapshot()
    {
        var delay = new ControllableDelay();
        var snapshots = new List<TeamsAutoMeetingSnapshot>();
        var controller = new TeamsAutomaticRecordingController(
            _ => Task.FromResult(TeamsAutomaticStartResult.Succeeded()),
            _ => Task.CompletedTask,
            new TeamsAutoMeetingMachine(startCountdownSeconds: 3),
            delay);
        controller.SnapshotChanged += (_, snapshot) => snapshots.Add(snapshot);

        controller.SetEnabledAsync(true).GetAwaiter().GetResult();
        controller.SetMeetingPresenceAsync(true).GetAwaiter().GetResult();
        delay.Tick();
        WaitUntil(() => snapshots.Any(snapshot => snapshot.State is TeamsAutoMeetingState.StartCountdown(2)), "Countdown did not publish two seconds remaining.");
        delay.Tick();
        WaitUntil(() => snapshots.Any(snapshot => snapshot.State is TeamsAutoMeetingState.StartCountdown(1)), "Countdown did not publish one second remaining.");

        var countdowns = snapshots
            .Where(snapshot => snapshot.State is TeamsAutoMeetingState.StartCountdown)
            .Select(snapshot => ((TeamsAutoMeetingState.StartCountdown)snapshot.State).SecondsRemaining)
            .ToArray();
        if (!countdowns.SequenceEqual(new[] { 3, 2, 1 }))
            throw new InvalidOperationException($"Countdown snapshots were [{string.Join(", ", countdowns)}], not [3, 2, 1].");
        controller.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    public static void UserCancellationSuppressesUntilMeetingEndsThenAllowsReentry()
    {
        var delay = new ControllableDelay();
        var starts = 0;
        var controller = new TeamsAutomaticRecordingController(
            _ => { Interlocked.Increment(ref starts); return Task.FromResult(TeamsAutomaticStartResult.Succeeded()); },
            _ => Task.CompletedTask,
            new TeamsAutoMeetingMachine(startCountdownSeconds: 1),
            delay);

        controller.SetEnabledAsync(true).GetAwaiter().GetResult();
        controller.SetMeetingPresenceAsync(true).GetAwaiter().GetResult();
        controller.CancelStartCountdownAsync().GetAwaiter().GetResult();
        if (controller.Snapshot.State is not TeamsAutoMeetingState.SuppressedUntilMeetingEnd)
            throw new InvalidOperationException("User cancellation did not suppress automatic recording for the meeting.");
        delay.Tick();
        Thread.Sleep(50);
        if (Volatile.Read(ref starts) != 0)
            throw new InvalidOperationException("Automatic recording started after the user cancelled the countdown.");

        controller.SetMeetingPresenceAsync(false).GetAwaiter().GetResult();
        controller.SetMeetingPresenceAsync(true).GetAwaiter().GetResult();
        if (controller.Snapshot.State is not TeamsAutoMeetingState.StartCountdown(1))
            throw new InvalidOperationException("Re-entering a meeting did not restore the automatic-recording countdown.");
        delay.Tick();
        WaitUntil(() => Volatile.Read(ref starts) == 1, "Automatic recording did not restart after entering a new meeting.");
        controller.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    public static void ManualStopDuringAutomaticRecordingDoesNotRestartUntilMeetingReentry()
    {
        var delay = new ControllableDelay();
        var starts = 0;
        var controller = new TeamsAutomaticRecordingController(
            _ => { Interlocked.Increment(ref starts); return Task.FromResult(TeamsAutomaticStartResult.Succeeded()); },
            _ => Task.CompletedTask,
            new TeamsAutoMeetingMachine(startCountdownSeconds: 1),
            delay);

        controller.SetEnabledAsync(true).GetAwaiter().GetResult();
        controller.SetMeetingPresenceAsync(true).GetAwaiter().GetResult();
        delay.Tick();
        WaitUntil(() => controller.Snapshot.State is TeamsAutoMeetingState.AutomaticRecording, "Automatic recording did not start.");

        controller.SuppressUntilMeetingEndsAsync().GetAwaiter().GetResult();
        controller.NotifyManualRecordingStoppedAsync().GetAwaiter().GetResult();
        if (controller.Snapshot.State is not TeamsAutoMeetingState.SuppressedUntilMeetingEnd || controller.Snapshot.RecordingOwner != RecordingOwner.None)
            throw new InvalidOperationException("Manual stop did not release automatic ownership and suppress the remainder of the meeting.");
        controller.SetMeetingPresenceAsync(true).GetAwaiter().GetResult();
        Thread.Sleep(50);
        if (Volatile.Read(ref starts) != 1)
            throw new InvalidOperationException("Manual stop allowed automatic recording to restart in the same meeting.");

        controller.SetMeetingPresenceAsync(false).GetAwaiter().GetResult();
        controller.SetMeetingPresenceAsync(true).GetAwaiter().GetResult();
        delay.Tick();
        WaitUntil(() => Volatile.Read(ref starts) == 2, "Automatic recording did not become eligible after meeting re-entry.");
        controller.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    public static void UnavailableEvidenceCancelsCountdownWithoutStarting()
    {
        var delay = new ControllableDelay();
        var starts = 0;
        var controller = new TeamsAutomaticRecordingController(
            _ => { Interlocked.Increment(ref starts); return Task.FromResult(TeamsAutomaticStartResult.Succeeded()); },
            _ => Task.CompletedTask,
            new TeamsAutoMeetingMachine(startCountdownSeconds: 1),
            delay);

        controller.SetEnabledAsync(true).GetAwaiter().GetResult();
        controller.SetMeetingEvidenceAsync(new TeamsMeetingEvidence.JoinedConfirmed(4)).GetAwaiter().GetResult();
        controller.SetMeetingEvidenceAsync(new TeamsMeetingEvidence.StateUnavailable(5)).GetAwaiter().GetResult();
        if (controller.Snapshot.State is not TeamsAutoMeetingState.WaitingForMeeting || controller.Snapshot.IsInMeeting)
            throw new InvalidOperationException("Unavailable evidence did not fail closed before automatic start.");
        delay.Tick();
        Thread.Sleep(50);
        if (Volatile.Read(ref starts) != 0)
            throw new InvalidOperationException("Unavailable evidence allowed a countdown to start recording.");
        controller.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    public static void UnavailableEvidenceDoesNotStopRecordingButConfirmedLeaveDoes()
    {
        var delay = new ControllableDelay();
        var stops = 0;
        var controller = new TeamsAutomaticRecordingController(
            _ => Task.FromResult(TeamsAutomaticStartResult.Succeeded()),
            _ => { Interlocked.Increment(ref stops); return Task.CompletedTask; },
            new TeamsAutoMeetingMachine(startCountdownSeconds: 1, stopDebounceSeconds: 1),
            delay);

        controller.SetEnabledAsync(true).GetAwaiter().GetResult();
        controller.SetMeetingEvidenceAsync(new TeamsMeetingEvidence.JoinedConfirmed(7, 1)).GetAwaiter().GetResult();
        delay.Tick();
        WaitUntil(() => controller.Snapshot.State is TeamsAutoMeetingState.AutomaticRecording, "Confirmed join did not start recording.");

        controller.SetMeetingEvidenceAsync(new TeamsMeetingEvidence.StateUnavailable(8, 1)).GetAwaiter().GetResult();
        if (controller.Snapshot.State is not TeamsAutoMeetingState.AutomaticRecording)
            throw new InvalidOperationException("Unavailable evidence stopped an active recording.");
        Thread.Sleep(50);
        if (Volatile.Read(ref stops) != 0)
            throw new InvalidOperationException("Unavailable evidence scheduled a stop.");

        controller.SetMeetingEvidenceAsync(new TeamsMeetingEvidence.LeftConfirmed(8, 2)).GetAwaiter().GetResult();
        delay.Tick();
        WaitUntil(() => Volatile.Read(ref stops) == 1, "Confirmed leave did not stop recording after debounce.");
        controller.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    public static void SameGenerationLateJoinCannotReverseConfirmedLeave()
    {
        var delay = new ControllableDelay();
        var controller = new TeamsAutomaticRecordingController(
            _ => Task.FromResult(TeamsAutomaticStartResult.Succeeded()),
            _ => Task.CompletedTask,
            new TeamsAutoMeetingMachine(startCountdownSeconds: 1, stopDebounceSeconds: 2),
            delay);

        controller.SetEnabledAsync(true).GetAwaiter().GetResult();
        controller.SetMeetingEvidenceAsync(new TeamsMeetingEvidence.JoinedConfirmed(12, 4)).GetAwaiter().GetResult();
        delay.Tick();
        WaitUntil(() => controller.Snapshot.State is TeamsAutoMeetingState.AutomaticRecording, "Confirmed join did not start recording.");
        controller.SetMeetingEvidenceAsync(new TeamsMeetingEvidence.LeftConfirmed(12, 5)).GetAwaiter().GetResult();
        if (controller.Snapshot.State is not TeamsAutoMeetingState.StopCountdown)
            throw new InvalidOperationException("Confirmed leave did not begin stop debounce.");

        controller.SetMeetingEvidenceAsync(new TeamsMeetingEvidence.JoinedConfirmed(12, 4)).GetAwaiter().GetResult();
        if (controller.Snapshot.State is not TeamsAutoMeetingState.StopCountdown || controller.Snapshot.IsInMeeting)
            throw new InvalidOperationException("A same-generation late join reversed a confirmed leave.");
        controller.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    public static void LocalCandidateDoesNotMutateAuthoritativeEvidenceRevision()
    {
        var delay = new ControllableDelay();
        var starts = 0;
        var controller = new TeamsAutomaticRecordingController(
            _ => { Interlocked.Increment(ref starts); return Task.FromResult(TeamsAutomaticStartResult.Succeeded()); },
            _ => Task.CompletedTask,
            new TeamsAutoMeetingMachine(startCountdownSeconds: 1, stopDebounceSeconds: 1),
            delay);

        controller.SetEnabledAsync(true).GetAwaiter().GetResult();
        controller.SetMeetingEvidenceAsync(new TeamsMeetingEvidence.StateUnavailable(21, 8)).GetAwaiter().GetResult();
        controller.SetLocalMeetingCandidateAsync().GetAwaiter().GetResult();
        if (controller.Snapshot.State is not TeamsAutoMeetingState.StartCountdown)
            throw new InvalidOperationException("A user-authorized local candidate did not enter the countdown.");
        delay.Tick();
        WaitUntil(() => Volatile.Read(ref starts) == 1, "The local candidate did not start recording.");

        // A later confirmed Teams event in the same generation remains authoritative,
        // proving that the local candidate did not overwrite generation/revision state.
        controller.SetMeetingEvidenceAsync(new TeamsMeetingEvidence.LeftConfirmed(21, 9)).GetAwaiter().GetResult();
        if (controller.Snapshot.State is not TeamsAutoMeetingState.StopCountdown)
            throw new InvalidOperationException("A confirmed Teams leave was ignored after a local candidate.");
        controller.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    public static void LocalSignalReturnCancelsLocalStopDebounce()
    {
        var delay = new ControllableDelay();
        var stops = 0;
        var controller = new TeamsAutomaticRecordingController(
            _ => Task.FromResult(TeamsAutomaticStartResult.Succeeded()),
            _ => { Interlocked.Increment(ref stops); return Task.CompletedTask; },
            new TeamsAutoMeetingMachine(startCountdownSeconds: 1, stopDebounceSeconds: 2),
            delay);

        controller.SetEnabledAsync(true).GetAwaiter().GetResult();
        controller.SetLocalMeetingCandidateAsync().GetAwaiter().GetResult();
        delay.Tick();
        WaitUntil(() => controller.Snapshot.State is TeamsAutoMeetingState.AutomaticRecording, "Local candidate did not start recording.");
        controller.SetLocalMeetingEndedAsync().GetAwaiter().GetResult();
        if (controller.Snapshot.State is not TeamsAutoMeetingState.StopCountdown)
            throw new InvalidOperationException("Bounded local leave did not begin stop debounce.");
        controller.SetLocalMeetingCandidateAsync().GetAwaiter().GetResult();
        if (controller.Snapshot.State is not TeamsAutoMeetingState.AutomaticRecording)
            throw new InvalidOperationException("Returned local evidence did not cancel stop debounce.");
        delay.Tick();
        Thread.Sleep(50);
        if (Volatile.Read(ref stops) != 0)
            throw new InvalidOperationException("A cancelled local stop debounce still stopped recording.");
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
