using Recorder.Core;

var tests = new (string Name, Action Run)[]
{
    ("storage policy uses exact thresholds", StoragePolicyUsesExactThresholds),
    ("meeting starts after countdown", MeetingStartsAfterCountdown),
    ("manual recording suppresses Teams until end", ManualRecordingSuppressesTeamsUntilEnd),
    ("meeting rejoin cancels stop debounce", MeetingRejoinCancelsStopDebounce),
    ("suppression during stop debounce survives a transient rejoin", SuppressionDuringStopDebounceSurvivesRejoin),
    ("meeting end commits exactly one stop", MeetingEndCommitsOneStop),
    ("committed stop waits for completion before restarting", CommittedStopWaitsForCompletion),
    ("disabling automatic recording transfers ownership", DisableTransfersOwnership),
    ("disabling while starting cancels automatic start", DisableWhileStartingCancelsStart),
    ("manual start does not steal active automatic ownership", ManualStartDoesNotStealAutomaticOwnership),
    ("late completions are idempotent", LateCompletionsAreIdempotent),
    ("failed automatic start waits for meeting end", FailedStartWaitsForMeetingEnd)
};

var failed = 0;
foreach (var (name, run) in tests)
{
    try { run(); Console.WriteLine($"PASS {name}"); }
    catch (Exception error) { failed++; Console.Error.WriteLine($"FAIL {name}: {error.Message}"); }
}
return failed == 0 ? 0 : 1;

static void StoragePolicyUsesExactThresholds()
{
    var policy = new RecordingStoragePolicy();
    Equal(RecordingStorageDecision.Normal, policy.Decide(RecordingStoragePolicy.WarningBytes));
    Equal(RecordingStorageDecision.Warn, policy.Decide(RecordingStoragePolicy.WarningBytes - 1));
    Equal(RecordingStorageDecision.AudioOnly, policy.Decide(RecordingStoragePolicy.VideoMinimumBytes - 1));
    Equal(RecordingStorageDecision.Stop, policy.Decide(RecordingStoragePolicy.DefaultAudioStopBytes - 1));
}

static void MeetingStartsAfterCountdown()
{
    var machine = new TeamsAutoMeetingMachine(startCountdownSeconds: 2);
    var snapshot = EnableAndEnterMeeting(machine);
    Equal(new TeamsAutoMeetingState.StartCountdown(2), snapshot.State);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.StartCountdownTicked()).Snapshot;
    var transition = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.StartCountdownTicked());
    Equal(new TeamsAutoMeetingState.Starting(), transition.Snapshot.State);
    Commands(transition, new TeamsAutoMeetingCommand.StartAutomaticRecording());
    snapshot = machine.Reduce(transition.Snapshot, new TeamsAutoMeetingEvent.AutomaticStartSucceeded()).Snapshot;
    Equal(RecordingOwner.TeamsAutomatic, snapshot.RecordingOwner);
    Equal(new TeamsAutoMeetingState.AutomaticRecording(), snapshot.State);
}

static void ManualRecordingSuppressesTeamsUntilEnd()
{
    var machine = new TeamsAutoMeetingMachine();
    var snapshot = EnableAndEnterMeeting(machine);
    var transition = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.ManualRecordingStarted());
    Equal(RecordingOwner.Manual, transition.Snapshot.RecordingOwner);
    Equal(new TeamsAutoMeetingState.SuppressedUntilMeetingEnd(), transition.Snapshot.State);
    snapshot = machine.Reduce(transition.Snapshot, new TeamsAutoMeetingEvent.MeetingPresenceChanged(false)).Snapshot;
    Equal(new TeamsAutoMeetingState.WaitingForMeeting(), snapshot.State);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.MeetingPresenceChanged(true)).Snapshot;
    Equal(new TeamsAutoMeetingState.StartCountdown(5), snapshot.State);
}

static void MeetingRejoinCancelsStopDebounce()
{
    var machine = new TeamsAutoMeetingMachine(startCountdownSeconds: 1, stopDebounceSeconds: 2);
    var snapshot = StartAutomaticRecording(machine);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.MeetingPresenceChanged(false)).Snapshot;
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.StopDebounceTicked()).Snapshot;
    Equal(new TeamsAutoMeetingState.StopCountdown(1), snapshot.State);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.MeetingPresenceChanged(true)).Snapshot;
    Equal(new TeamsAutoMeetingState.AutomaticRecording(), snapshot.State);
}

static void MeetingEndCommitsOneStop()
{
    var machine = new TeamsAutoMeetingMachine(startCountdownSeconds: 1, stopDebounceSeconds: 1);
    var snapshot = StartAutomaticRecording(machine);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.MeetingPresenceChanged(false)).Snapshot;
    var transition = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.StopDebounceTicked());
    Commands(transition, new TeamsAutoMeetingCommand.StopAutomaticRecording());
    Equal(new TeamsAutoMeetingState.Stopping(), transition.Snapshot.State);
    Equal(0, machine.Reduce(transition.Snapshot, new TeamsAutoMeetingEvent.StopDebounceTicked()).Commands.Count);
}

static void SuppressionDuringStopDebounceSurvivesRejoin()
{
    var machine = new TeamsAutoMeetingMachine(startCountdownSeconds: 1, stopDebounceSeconds: 2);
    var snapshot = StartAutomaticRecording(machine);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.MeetingPresenceChanged(false)).Snapshot;
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.SuppressUntilMeetingEnd()).Snapshot;
    Equal(new TeamsAutoMeetingState.StopCountdown(2), snapshot.State);
    if (!snapshot.SuppressesStopUntilEndDebounce) throw new InvalidOperationException("Expected deferred suppression.");
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.MeetingPresenceChanged(true)).Snapshot;
    Equal(new TeamsAutoMeetingState.SuppressedUntilMeetingEnd(), snapshot.State);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.MeetingPresenceChanged(false)).Snapshot;
    Equal(new TeamsAutoMeetingState.WaitingForMeeting(), snapshot.State);
}

static void CommittedStopWaitsForCompletion()
{
    var machine = new TeamsAutoMeetingMachine(startCountdownSeconds: 1, stopDebounceSeconds: 1);
    var snapshot = StartAutomaticRecording(machine);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.MeetingPresenceChanged(false)).Snapshot;
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.StopDebounceTicked()).Snapshot;
    Equal(new TeamsAutoMeetingState.Stopping(), snapshot.State);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.MeetingPresenceChanged(true)).Snapshot;
    Equal(new TeamsAutoMeetingState.Stopping(), snapshot.State);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.AutomaticStopCompleted()).Snapshot;
    Equal(new TeamsAutoMeetingState.StartCountdown(1), snapshot.State);
}

static void DisableTransfersOwnership()
{
    var machine = new TeamsAutoMeetingMachine(startCountdownSeconds: 1);
    var transition = machine.Reduce(StartAutomaticRecording(machine), new TeamsAutoMeetingEvent.AutoMeetingEnabled(false));
    Equal(new TeamsAutoMeetingState.Disabled(), transition.Snapshot.State);
    Equal(RecordingOwner.Manual, transition.Snapshot.RecordingOwner);
    Commands(transition, new TeamsAutoMeetingCommand.TransferAutomaticRecordingToManual());
}

static void DisableWhileStartingCancelsStart()
{
    var machine = new TeamsAutoMeetingMachine(startCountdownSeconds: 1);
    var snapshot = EnableAndEnterMeeting(machine);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.StartCountdownTicked()).Snapshot;
    var transition = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.AutoMeetingEnabled(false));
    Equal(new TeamsAutoMeetingState.Disabled(), transition.Snapshot.State);
    Commands(transition, new TeamsAutoMeetingCommand.CancelAutomaticStart());
}

static void ManualStartDoesNotStealAutomaticOwnership()
{
    var machine = new TeamsAutoMeetingMachine(startCountdownSeconds: 1);
    var transition = machine.Reduce(StartAutomaticRecording(machine), new TeamsAutoMeetingEvent.ManualRecordingStarted());
    Equal(RecordingOwner.TeamsAutomatic, transition.Snapshot.RecordingOwner);
    Equal(new TeamsAutoMeetingState.SuppressedUntilMeetingEnd(), transition.Snapshot.State);
    Equal(0, transition.Commands.Count);
}

static void LateCompletionsAreIdempotent()
{
    var machine = new TeamsAutoMeetingMachine(startCountdownSeconds: 1, stopDebounceSeconds: 1);
    var snapshot = StartAutomaticRecording(machine);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.MeetingPresenceChanged(false)).Snapshot;
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.StopDebounceTicked()).Snapshot;
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.AutomaticStopCompleted()).Snapshot;
    var repeatedStop = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.AutomaticStopCompleted());
    Equal(snapshot, repeatedStop.Snapshot);
    Equal(0, repeatedStop.Commands.Count);

    var disabled = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.AutoMeetingEnabled(false)).Snapshot;
    var lateStart = machine.Reduce(disabled, new TeamsAutoMeetingEvent.AutomaticStartSucceeded());
    Equal(disabled, lateStart.Snapshot);
    Equal(0, lateStart.Commands.Count);
}

static void FailedStartWaitsForMeetingEnd()
{
    var machine = new TeamsAutoMeetingMachine(startCountdownSeconds: 1);
    var snapshot = EnableAndEnterMeeting(machine);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.StartCountdownTicked()).Snapshot;
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.AutomaticStartFailed("capture unavailable")).Snapshot;
    Equal(new TeamsAutoMeetingState.StartFailed("capture unavailable"), snapshot.State);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.MeetingPresenceChanged(true)).Snapshot;
    Equal(new TeamsAutoMeetingState.StartFailed("capture unavailable"), snapshot.State);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.MeetingPresenceChanged(false)).Snapshot;
    Equal(new TeamsAutoMeetingState.WaitingForMeeting(), snapshot.State);
}

static TeamsAutoMeetingSnapshot EnableAndEnterMeeting(TeamsAutoMeetingMachine machine)
{
    var snapshot = machine.Reduce(TeamsAutoMeetingSnapshot.Initial, new TeamsAutoMeetingEvent.AutoMeetingEnabled(true)).Snapshot;
    return machine.Reduce(snapshot, new TeamsAutoMeetingEvent.MeetingPresenceChanged(true)).Snapshot;
}

static TeamsAutoMeetingSnapshot StartAutomaticRecording(TeamsAutoMeetingMachine machine)
{
    var snapshot = EnableAndEnterMeeting(machine);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.StartCountdownTicked()).Snapshot;
    return machine.Reduce(snapshot, new TeamsAutoMeetingEvent.AutomaticStartSucceeded()).Snapshot;
}

static void Commands(TeamsAutoMeetingTransition transition, params TeamsAutoMeetingCommand[] expected)
{
    Equal(expected.Length, transition.Commands.Count);
    for (var i = 0; i < expected.Length; i++) Equal(expected[i], transition.Commands[i]);
}

static void Equal<T>(T expected, T actual) where T : notnull
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual))
        throw new InvalidOperationException($"Expected {expected}; got {actual}.");
}
