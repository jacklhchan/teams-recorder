namespace Recorder.Core;

public enum RecordingOwner { None, Manual, TeamsAutomatic }

public abstract record TeamsAutoMeetingState
{
    public sealed record Disabled : TeamsAutoMeetingState;
    public sealed record WaitingForMeeting : TeamsAutoMeetingState;
    public sealed record StartCountdown(int SecondsRemaining) : TeamsAutoMeetingState;
    public sealed record Starting : TeamsAutoMeetingState;
    public sealed record AutomaticRecording : TeamsAutoMeetingState;
    public sealed record StopCountdown(int SecondsRemaining) : TeamsAutoMeetingState;
    public sealed record Stopping : TeamsAutoMeetingState;
    public sealed record SuppressedUntilMeetingEnd : TeamsAutoMeetingState;
    public sealed record StartBlocked(string Reason) : TeamsAutoMeetingState;
    public sealed record StartFailed(string Reason) : TeamsAutoMeetingState;
}

public abstract record TeamsAutoMeetingEvent
{
    public sealed record AutoMeetingEnabled(bool Enabled) : TeamsAutoMeetingEvent;
    public sealed record MeetingPresenceChanged(bool IsInMeeting) : TeamsAutoMeetingEvent;
    public sealed record StartCountdownTicked : TeamsAutoMeetingEvent;
    public sealed record StopDebounceTicked : TeamsAutoMeetingEvent;
    public sealed record AutomaticStartSucceeded : TeamsAutoMeetingEvent;
    public sealed record AutomaticStartBlocked(string Reason) : TeamsAutoMeetingEvent;
    public sealed record AutomaticStartFailed(string Reason) : TeamsAutoMeetingEvent;
    public sealed record AutomaticStopCompleted : TeamsAutoMeetingEvent;
    public sealed record ManualRecordingStarted : TeamsAutoMeetingEvent;
    public sealed record ManualRecordingStopped : TeamsAutoMeetingEvent;
    public sealed record StartCountdownCancelled : TeamsAutoMeetingEvent;
    public sealed record SuppressUntilMeetingEnd : TeamsAutoMeetingEvent;
}

public abstract record TeamsAutoMeetingCommand
{
    public sealed record StartAutomaticRecording : TeamsAutoMeetingCommand;
    public sealed record CancelAutomaticStart : TeamsAutoMeetingCommand;
    public sealed record StopAutomaticRecording : TeamsAutoMeetingCommand;
    public sealed record TransferAutomaticRecordingToManual : TeamsAutoMeetingCommand;
}

public sealed record TeamsAutoMeetingSnapshot(
    bool IsEnabled,
    bool IsInMeeting,
    RecordingOwner RecordingOwner,
    TeamsAutoMeetingState State,
    bool SuppressesStopUntilEndDebounce = false)
{
    public static TeamsAutoMeetingSnapshot Initial { get; } = new(false, false, RecordingOwner.None, new TeamsAutoMeetingState.Disabled());
}

public sealed record TeamsAutoMeetingTransition(
    TeamsAutoMeetingSnapshot Snapshot,
    IReadOnlyList<TeamsAutoMeetingCommand> Commands)
{
    public static TeamsAutoMeetingTransition NoCommand(TeamsAutoMeetingSnapshot snapshot) => new(snapshot, Array.Empty<TeamsAutoMeetingCommand>());
}

/// <summary>
/// A deterministic reducer. The host owns clocks and recording I/O: dispatch a tick or completion
/// event, then execute the returned commands and dispatch their result.
/// </summary>
public sealed class TeamsAutoMeetingMachine
{
    private readonly int startCountdownSeconds;
    private readonly int stopDebounceSeconds;

    public TeamsAutoMeetingMachine(int startCountdownSeconds = 5, int stopDebounceSeconds = 10)
    {
        if (startCountdownSeconds <= 0) throw new ArgumentOutOfRangeException(nameof(startCountdownSeconds));
        if (stopDebounceSeconds <= 0) throw new ArgumentOutOfRangeException(nameof(stopDebounceSeconds));
        this.startCountdownSeconds = startCountdownSeconds;
        this.stopDebounceSeconds = stopDebounceSeconds;
    }

    public TeamsAutoMeetingTransition Reduce(TeamsAutoMeetingSnapshot snapshot, TeamsAutoMeetingEvent @event) => @event switch
    {
        TeamsAutoMeetingEvent.AutoMeetingEnabled enabled => SetEnabled(snapshot, enabled.Enabled),
        TeamsAutoMeetingEvent.MeetingPresenceChanged presence => MeetingChanged(snapshot, presence.IsInMeeting),
        TeamsAutoMeetingEvent.StartCountdownTicked => StartTick(snapshot),
        TeamsAutoMeetingEvent.StopDebounceTicked => StopTick(snapshot),
        TeamsAutoMeetingEvent.AutomaticStartSucceeded => snapshot.State is TeamsAutoMeetingState.Starting
            ? TeamsAutoMeetingTransition.NoCommand(snapshot with { RecordingOwner = RecordingOwner.TeamsAutomatic, State = new TeamsAutoMeetingState.AutomaticRecording() }) : TeamsAutoMeetingTransition.NoCommand(snapshot),
        TeamsAutoMeetingEvent.AutomaticStartBlocked blocked => snapshot.State is TeamsAutoMeetingState.Starting
            ? TeamsAutoMeetingTransition.NoCommand(snapshot with { State = new TeamsAutoMeetingState.StartBlocked(blocked.Reason) }) : TeamsAutoMeetingTransition.NoCommand(snapshot),
        TeamsAutoMeetingEvent.AutomaticStartFailed failed => snapshot.State is TeamsAutoMeetingState.Starting
            ? TeamsAutoMeetingTransition.NoCommand(snapshot with { State = new TeamsAutoMeetingState.StartFailed(failed.Reason) }) : TeamsAutoMeetingTransition.NoCommand(snapshot),
        TeamsAutoMeetingEvent.AutomaticStopCompleted => snapshot.State is TeamsAutoMeetingState.Stopping
            ? TeamsAutoMeetingTransition.NoCommand(WaitingOrCountdown(snapshot with { RecordingOwner = RecordingOwner.None })) : TeamsAutoMeetingTransition.NoCommand(snapshot),
        TeamsAutoMeetingEvent.ManualRecordingStarted => ManualStarted(snapshot),
        TeamsAutoMeetingEvent.ManualRecordingStopped => TeamsAutoMeetingTransition.NoCommand(snapshot with { RecordingOwner = snapshot.RecordingOwner == RecordingOwner.Manual ? RecordingOwner.None : snapshot.RecordingOwner }),
        TeamsAutoMeetingEvent.StartCountdownCancelled => snapshot.State is TeamsAutoMeetingState.StartCountdown
            ? TeamsAutoMeetingTransition.NoCommand(snapshot with { State = new TeamsAutoMeetingState.SuppressedUntilMeetingEnd() }) : TeamsAutoMeetingTransition.NoCommand(snapshot),
        TeamsAutoMeetingEvent.SuppressUntilMeetingEnd => Suppress(snapshot),
        _ => TeamsAutoMeetingTransition.NoCommand(snapshot)
    };

    private TeamsAutoMeetingTransition SetEnabled(TeamsAutoMeetingSnapshot snapshot, bool enabled)
    {
        if (snapshot.IsEnabled == enabled) return TeamsAutoMeetingTransition.NoCommand(snapshot);
        if (enabled) return TeamsAutoMeetingTransition.NoCommand(WaitingOrCountdown(snapshot with { IsEnabled = true }));

        var commands = new List<TeamsAutoMeetingCommand>();
        var owner = snapshot.RecordingOwner;
        if (snapshot.State is TeamsAutoMeetingState.Starting) commands.Add(new TeamsAutoMeetingCommand.CancelAutomaticStart());
        if (owner == RecordingOwner.TeamsAutomatic)
        {
            commands.Add(new TeamsAutoMeetingCommand.TransferAutomaticRecordingToManual());
            owner = RecordingOwner.Manual;
        }
        return new(snapshot with { IsEnabled = false, RecordingOwner = owner, State = new TeamsAutoMeetingState.Disabled(), SuppressesStopUntilEndDebounce = false }, commands);
    }

    private TeamsAutoMeetingTransition MeetingChanged(TeamsAutoMeetingSnapshot snapshot, bool isInMeeting)
    {
        snapshot = snapshot with { IsInMeeting = isInMeeting };
        if (!snapshot.IsEnabled) return TeamsAutoMeetingTransition.NoCommand(snapshot);
        if (isInMeeting)
        {
            if (snapshot.State is TeamsAutoMeetingState.WaitingForMeeting) return TeamsAutoMeetingTransition.NoCommand(StartCountdown(snapshot));
            if (snapshot.State is TeamsAutoMeetingState.StopCountdown)
            {
                TeamsAutoMeetingState state = snapshot.SuppressesStopUntilEndDebounce
                    ? new TeamsAutoMeetingState.SuppressedUntilMeetingEnd()
                    : new TeamsAutoMeetingState.AutomaticRecording();
                return TeamsAutoMeetingTransition.NoCommand(snapshot with { State = state, SuppressesStopUntilEndDebounce = false });
            }
            return TeamsAutoMeetingTransition.NoCommand(snapshot);
        }
        return snapshot.State switch
        {
            TeamsAutoMeetingState.StartCountdown => TeamsAutoMeetingTransition.NoCommand(snapshot with { State = new TeamsAutoMeetingState.WaitingForMeeting() }),
            TeamsAutoMeetingState.Starting => new(snapshot with { State = new TeamsAutoMeetingState.WaitingForMeeting() }, new TeamsAutoMeetingCommand[] { new TeamsAutoMeetingCommand.CancelAutomaticStart() }),
            TeamsAutoMeetingState.AutomaticRecording => TeamsAutoMeetingTransition.NoCommand(snapshot with { State = new TeamsAutoMeetingState.StopCountdown(stopDebounceSeconds) }),
            TeamsAutoMeetingState.SuppressedUntilMeetingEnd or TeamsAutoMeetingState.StartBlocked or TeamsAutoMeetingState.StartFailed => TeamsAutoMeetingTransition.NoCommand(snapshot with { State = new TeamsAutoMeetingState.WaitingForMeeting() }),
            _ => TeamsAutoMeetingTransition.NoCommand(snapshot)
        };
    }

    private TeamsAutoMeetingTransition StartTick(TeamsAutoMeetingSnapshot snapshot) => snapshot.State is TeamsAutoMeetingState.StartCountdown(var seconds) && snapshot.IsEnabled && snapshot.IsInMeeting
        ? seconds > 1 ? TeamsAutoMeetingTransition.NoCommand(snapshot with { State = new TeamsAutoMeetingState.StartCountdown(seconds - 1) })
            : new(snapshot with { State = new TeamsAutoMeetingState.Starting() }, new TeamsAutoMeetingCommand[] { new TeamsAutoMeetingCommand.StartAutomaticRecording() })
        : TeamsAutoMeetingTransition.NoCommand(snapshot);

    private TeamsAutoMeetingTransition StopTick(TeamsAutoMeetingSnapshot snapshot) => snapshot.State is TeamsAutoMeetingState.StopCountdown(var seconds) && snapshot.IsEnabled && !snapshot.IsInMeeting
        ? seconds > 1 ? TeamsAutoMeetingTransition.NoCommand(snapshot with { State = new TeamsAutoMeetingState.StopCountdown(seconds - 1) })
            : snapshot.SuppressesStopUntilEndDebounce
                ? TeamsAutoMeetingTransition.NoCommand(snapshot with { State = new TeamsAutoMeetingState.WaitingForMeeting(), SuppressesStopUntilEndDebounce = false })
                : new(snapshot with { State = new TeamsAutoMeetingState.Stopping() }, new TeamsAutoMeetingCommand[] { new TeamsAutoMeetingCommand.StopAutomaticRecording() })
        : TeamsAutoMeetingTransition.NoCommand(snapshot);

    private TeamsAutoMeetingTransition ManualStarted(TeamsAutoMeetingSnapshot snapshot)
    {
        var commands = snapshot.State is TeamsAutoMeetingState.Starting
            ? new TeamsAutoMeetingCommand[] { new TeamsAutoMeetingCommand.CancelAutomaticStart() } : Array.Empty<TeamsAutoMeetingCommand>();
        var state = snapshot.IsEnabled && snapshot.IsInMeeting ? new TeamsAutoMeetingState.SuppressedUntilMeetingEnd() : snapshot.State;
        // A user cannot replace an already-running automatic capture merely by pressing Start.
        // This mirrors the macOS coordinator: suppress automation, while the host retains ownership.
        var owner = snapshot.RecordingOwner == RecordingOwner.TeamsAutomatic
            ? RecordingOwner.TeamsAutomatic : RecordingOwner.Manual;
        return new(snapshot with { RecordingOwner = owner, State = state, SuppressesStopUntilEndDebounce = false }, commands);
    }

    private TeamsAutoMeetingTransition Suppress(TeamsAutoMeetingSnapshot snapshot) => snapshot.IsEnabled && !snapshot.IsInMeeting && snapshot.State is TeamsAutoMeetingState.StopCountdown
        ? TeamsAutoMeetingTransition.NoCommand(snapshot with { SuppressesStopUntilEndDebounce = true })
        : snapshot.IsEnabled
        // The host uses this when a user explicitly stops an automatic capture.  That capture
        // is no longer controller-owned, so do not retain a stale TeamsAutomatic owner while
        // suppressing re-starts for the remainder of the meeting.
        ? TeamsAutoMeetingTransition.NoCommand(snapshot with
        {
            RecordingOwner = snapshot.RecordingOwner == RecordingOwner.TeamsAutomatic ? RecordingOwner.None : snapshot.RecordingOwner,
            State = new TeamsAutoMeetingState.SuppressedUntilMeetingEnd(),
            SuppressesStopUntilEndDebounce = false,
        })
        : TeamsAutoMeetingTransition.NoCommand(snapshot);

    private TeamsAutoMeetingSnapshot WaitingOrCountdown(TeamsAutoMeetingSnapshot snapshot) => snapshot.IsEnabled && snapshot.IsInMeeting ? StartCountdown(snapshot) : snapshot with { State = new TeamsAutoMeetingState.WaitingForMeeting() };
    private TeamsAutoMeetingSnapshot StartCountdown(TeamsAutoMeetingSnapshot snapshot) => snapshot with { State = new TeamsAutoMeetingState.StartCountdown(startCountdownSeconds) };
}
