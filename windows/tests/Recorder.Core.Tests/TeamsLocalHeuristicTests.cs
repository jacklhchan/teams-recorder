using TeamsRecorder.Windows.Application;

internal static class TeamsLocalHeuristicTests
{
    public static void StartsAfterThreeActiveSamplesAndNeverStopsForSilenceOrProbeFailure()
    {
        var heuristic = new TeamsLocalMeetingHeuristic();
        var policy = new TeamsLocalHeuristicPolicy(true);
        var at = DateTimeOffset.UtcNow;
        for (var index = 0; index < 2; index++)
        {
            var result = heuristic.Observe(new TeamsLocalHeuristicObservation(at, true, true, ["render"]), policy);
            if (result.ShouldTriggerAutomaticStart) throw new InvalidOperationException("A transient signal started recording.");
        }

        var started = heuristic.Observe(new TeamsLocalHeuristicObservation(at, true, true, ["render"]), policy);
        if (!started.ShouldTriggerAutomaticStart) throw new InvalidOperationException("Three active samples did not start recording.");
        var silence = heuristic.Observe(new TeamsLocalHeuristicObservation(at, true, true, []), policy);
        var unavailable = heuristic.Observe(TeamsLocalHeuristicObservation.ProbeFailure(at, true), policy);
        if (silence.ShouldTriggerAutomaticStop || unavailable.ShouldTriggerAutomaticStop)
            throw new InvalidOperationException("Silence or a probe fault stopped an active recording.");
    }

    public static void StopsOnlyAfterThreeHealthyMissingTeamsProcessSamples()
    {
        var heuristic = new TeamsLocalMeetingHeuristic();
        var policy = new TeamsLocalHeuristicPolicy(true);
        var at = DateTimeOffset.UtcNow;
        for (var index = 0; index < 3; index++) _ = heuristic.Observe(new TeamsLocalHeuristicObservation(at, true, true, ["render"]), policy);
        for (var index = 0; index < 2; index++)
        {
            var result = heuristic.Observe(new TeamsLocalHeuristicObservation(at, true, false, []), policy);
            if (result.ShouldTriggerAutomaticStop) throw new InvalidOperationException("Stopped before the bounded missing-process threshold.");
        }
        if (!heuristic.Observe(new TeamsLocalHeuristicObservation(at, true, false, []), policy).ShouldTriggerAutomaticStop)
            throw new InvalidOperationException("Three missing Teams process samples did not request one stop.");
    }

    public static void StopsAfterThreeConfirmedMeetingSurfaceAbsences()
    {
        var heuristic = new TeamsLocalMeetingHeuristic();
        var policy = new TeamsLocalHeuristicPolicy(true);
        var at = DateTimeOffset.UtcNow;
        for (var index = 0; index < 3; index++)
        {
            _ = heuristic.Observe(Observation(at, hasAudio: true, TeamsMeetingSurfaceState.Present), policy);
        }

        for (var index = 0; index < 2; index++)
        {
            var result = heuristic.Observe(Observation(at, hasAudio: false, TeamsMeetingSurfaceState.Absent), policy);
            if (result.ShouldTriggerAutomaticStop)
                throw new InvalidOperationException("A transient missing meeting surface stopped recording.");
        }

        var stopped = heuristic.Observe(Observation(at, hasAudio: false, TeamsMeetingSurfaceState.Absent), policy);
        if (!stopped.ShouldTriggerAutomaticStop)
            throw new InvalidOperationException("Three confirmed meeting-surface absences did not stop recording.");
    }

    public static void MeetingSurfaceStopRequiresPriorPresenceAndHealthyConsecutiveAbsence()
    {
        var heuristic = new TeamsLocalMeetingHeuristic();
        var policy = new TeamsLocalHeuristicPolicy(true);
        var at = DateTimeOffset.UtcNow;
        for (var index = 0; index < 3; index++)
        {
            _ = heuristic.Observe(new TeamsLocalHeuristicObservation(
                at, true, true, ["render"], TeamsMeetingSurfaceState.Unavailable), policy);
        }

        for (var index = 0; index < 4; index++)
        {
            if (heuristic.Observe(Observation(at, hasAudio: false, TeamsMeetingSurfaceState.Absent), policy).ShouldTriggerAutomaticStop)
                throw new InvalidOperationException("An unarmed meeting-surface probe stopped recording.");
        }

        _ = heuristic.Observe(Observation(at, hasAudio: false, TeamsMeetingSurfaceState.Present), policy);
        _ = heuristic.Observe(Observation(at, hasAudio: false, TeamsMeetingSurfaceState.Absent), policy);
        _ = heuristic.Observe(Observation(at, hasAudio: false, TeamsMeetingSurfaceState.Unavailable), policy);
        _ = heuristic.Observe(Observation(at, hasAudio: false, TeamsMeetingSurfaceState.Absent), policy);
        var rejoined = heuristic.Observe(Observation(at, hasAudio: false, TeamsMeetingSurfaceState.Present), policy);
        if (rejoined.ShouldTriggerAutomaticStop)
            throw new InvalidOperationException("Probe failure or meeting reappearance must cancel the stop debounce.");

        for (var index = 0; index < 2; index++)
        {
            if (heuristic.Observe(Observation(at, hasAudio: false, TeamsMeetingSurfaceState.Absent), policy).ShouldTriggerAutomaticStop)
                throw new InvalidOperationException("Stop debounce was not reset by meeting reappearance.");
        }
    }

    private static TeamsLocalHeuristicObservation Observation(
        DateTimeOffset at,
        bool hasAudio,
        TeamsMeetingSurfaceState surface) =>
        new(at, true, true, hasAudio ? ["render"] : [], surface);
}
