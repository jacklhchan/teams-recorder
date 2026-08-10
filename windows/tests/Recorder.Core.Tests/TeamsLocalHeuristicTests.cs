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
}
