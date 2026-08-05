using TeamsRecorder.Windows.Application;

internal static class TeamsLocalMeetingDetectorTests
{
    public static void DebouncesActiveAudioAndEmitsOneStartSignal()
    {
        var detector = new TeamsLocalMeetingDetector(requiredActiveObservations: 3);
        var at = new DateTimeOffset(2026, 8, 5, 4, 0, 0, TimeSpan.Zero);

        var optedIn = new TeamsLocalHeuristicPolicy(EnableLocalHeuristicAutoStart: true);
        Equal(TeamsLocalMeetingHealth.Candidate, detector.Observe(Active(at), optedIn).Health);
        Equal(false, detector.Observe(Active(at.AddSeconds(2)), optedIn).ShouldTriggerAutomaticStart);
        var confirmed = detector.Observe(Active(at.AddSeconds(4)), optedIn);
        Equal(TeamsLocalMeetingHealth.MeetingLikely, confirmed.Health);
        Equal(true, confirmed.ShouldTriggerAutomaticStart);
        Equal(false, detector.Observe(Active(at.AddSeconds(6)), optedIn).ShouldTriggerAutomaticStart);
    }

    public static void TransientAudioDoesNotTriggerAndNegativeEvidenceResetsCandidate()
    {
        var detector = new TeamsLocalMeetingDetector(3);
        var at = DateTimeOffset.UtcNow;

        detector.Observe(Active(at));
        var quiet = detector.Observe(new(at.AddSeconds(2), true, true, Array.Empty<string>()));
        Equal(TeamsLocalMeetingHealth.WaitingForAudio, quiet.Health);
        Equal(0, quiet.ConsecutiveActiveObservations);
        Equal(false, detector.Observe(Active(at.AddSeconds(4))).ShouldTriggerAutomaticStart);
    }

    public static void LostEvidenceNeverClaimsMeetingEndOrChangesTeamsMute()
    {
        var detector = new TeamsLocalMeetingDetector(2);
        var at = DateTimeOffset.UtcNow;
        detector.Observe(Active(at));
        detector.Observe(Active(at.AddSeconds(2)));

        var lost = detector.Observe(new(at.AddSeconds(4), true, false, Array.Empty<string>()));
        Equal(TeamsLocalMeetingHealth.EvidenceLost, lost.Health);
        Equal(true, lost.StartSignalLatched);
        Equal(false, lost.ShouldTriggerAutomaticStart);
        Equal(false, lost.MuteCapability.CanReadTeamsMute);
        Equal(false, lost.MuteCapability.CanWriteTeamsMute);
        Equal(true, lost.MuteCapability.CanMuteRecorderMicrophone);
    }

    public static void ProbeFailureFailsClosedUntilExplicitReset()
    {
        var detector = new TeamsLocalMeetingDetector(2);
        var at = DateTimeOffset.UtcNow;
        var failed = detector.Observe(TeamsLocalMeetingObservation.ProbeFailure(at, true));
        Equal(TeamsLocalMeetingHealth.Unavailable, failed.Health);
        Equal(false, failed.ShouldTriggerAutomaticStart);

        var optedIn = new TeamsLocalHeuristicPolicy(EnableLocalHeuristicAutoStart: true);
        detector.Observe(Active(at.AddSeconds(1)), optedIn);
        Equal(true, detector.Observe(Active(at.AddSeconds(2)), optedIn).ShouldTriggerAutomaticStart);
        detector.Reset();
        Equal(false, detector.Observe(Active(at.AddSeconds(3)), optedIn).ShouldTriggerAutomaticStart);
    }

    public static void DefaultPolicyOnlyReportsLikelyMeetingUntilUserOptsIn()
    {
        var detector = new TeamsLocalMeetingDetector(2);
        var at = DateTimeOffset.UtcNow;

        detector.Observe(Active(at));
        var likely = detector.Observe(Active(at.AddSeconds(2)));
        Equal(TeamsLocalMeetingHealth.MeetingLikely, likely.Health);
        Equal(false, likely.ShouldTriggerAutomaticStart);
        Contains("尚未啟用", likely.Detail);

        var optedIn = detector.Observe(
            Active(at.AddSeconds(4)),
            new TeamsLocalHeuristicPolicy(EnableLocalHeuristicAutoStart: true));
        Equal(true, optedIn.ShouldTriggerAutomaticStart);
        Equal(false, detector.Observe(
            Active(at.AddSeconds(6)),
            new TeamsLocalHeuristicPolicy(EnableLocalHeuristicAutoStart: true)).ShouldTriggerAutomaticStart);
    }

    public static void HostPollsOnlyForOptedInDegradedTransport()
    {
        var sampler = new QueueSampler(Active(DateTimeOffset.UtcNow));
        var forwarded = 0;
        var host = new TeamsLocalHeuristicAutoStartHost(
            sampler,
            _ => { forwarded++; return Task.CompletedTask; },
            _ => Task.CompletedTask,
            new TeamsLocalMeetingDetector(2));

        host.PollAsync(TeamsLocalHeuristicPolicy.Disabled).GetAwaiter().GetResult();
        Equal(0, sampler.CallCount);

        host.PollAsync(new(true)).GetAwaiter().GetResult();
        host.PollAsync(new(true)).GetAwaiter().GetResult();
        Equal(2, sampler.CallCount);
        Equal(1, forwarded);
        host.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    public static void HostRejectsOverlappingPollsAndNeverForwardsEvidenceLoss()
    {
        var sampler = new BlockingSampler(Active(DateTimeOffset.UtcNow));
        var forwarded = 0;
        var host = new TeamsLocalHeuristicAutoStartHost(
            sampler,
            _ => { forwarded++; return Task.CompletedTask; },
            _ => Task.CompletedTask,
            new TeamsLocalMeetingDetector(2));

        var first = host.PollAsync(new(true));
        sampler.WaitUntilEntered();
        var overlapping = host.PollAsync(new(true)).GetAwaiter().GetResult();
        Equal<TeamsLocalMeetingSnapshot?>(null, overlapping);
        Equal(1, sampler.CallCount);
        sampler.Release();
        first.GetAwaiter().GetResult();

        // Confirm once, then lose evidence. The host has no leave callback by design.
        host.PollAsync(new(true)).GetAwaiter().GetResult();
        sampler.Next = new TeamsLocalMeetingObservation(DateTimeOffset.UtcNow, true, false, Array.Empty<string>());
        var lost = host.PollAsync(new(true)).GetAwaiter().GetResult();
        Equal(TeamsLocalMeetingHealth.EvidenceLost, lost!.Health);
        Equal(1, forwarded);
        host.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    public static void HostCancellationPreventsLateForwardingAndDisposeIsIdempotent()
    {
        var sampler = new BlockingSampler(Active(DateTimeOffset.UtcNow));
        var forwarded = 0;
        var host = new TeamsLocalHeuristicAutoStartHost(
            sampler,
            _ => { forwarded++; return Task.CompletedTask; },
            _ => Task.CompletedTask,
            new TeamsLocalMeetingDetector(2));
        using var cancellation = new CancellationTokenSource();

        var poll = host.PollAsync(new(true), cancellation.Token);
        sampler.WaitUntilEntered();
        cancellation.Cancel();
        sampler.Release();
        Throws<OperationCanceledException>(() => poll.GetAwaiter().GetResult());
        Equal(0, forwarded);
        host.DisposeAsync().AsTask().GetAwaiter().GetResult();
        host.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    public static void SilentMeetingAndProbeFailureNeverTriggerStop()
    {
        var detector = new TeamsLocalMeetingDetector(2, requiredMissingProcessObservations: 3);
        var policy = new TeamsLocalHeuristicPolicy(true);
        var at = DateTimeOffset.UtcNow;
        detector.Observe(Active(at), policy);
        detector.Observe(Active(at.AddSeconds(2)), policy);

        for (var index = 0; index < 100; index++)
        {
            var silent = detector.Observe(Missing(at.AddSeconds(4 + index * 2), teamsPresent: true), policy);
            Equal(false, silent.ShouldTriggerAutomaticStop);
            Equal(TeamsLocalMeetingHealth.EvidenceLost, silent.Health);
            Equal(0, silent.ConsecutiveMissingObservations);
        }

        detector.Reset();
        detector.Observe(Active(at), policy);
        detector.Observe(Active(at.AddSeconds(2)), policy);
        for (var index = 0; index < 5; index++)
            Equal(false, detector.Observe(TeamsLocalMeetingObservation.ProbeFailure(at.AddSeconds(204 + index * 2), true), policy).ShouldTriggerAutomaticStop);
    }

    public static void ProcessExitUsesBoundedFastStopAndReturnedAudioCancelsStop()
    {
        var detector = new TeamsLocalMeetingDetector(2, requiredMissingProcessObservations: 3);
        var policy = new TeamsLocalHeuristicPolicy(true);
        var at = DateTimeOffset.UtcNow;
        detector.Observe(Active(at), policy);
        detector.Observe(Active(at.AddSeconds(2)), policy);
        Equal(false, detector.Observe(Missing(at.AddSeconds(4), teamsPresent: false), policy).ShouldTriggerAutomaticStop);
        Equal(false, detector.Observe(Missing(at.AddSeconds(6), teamsPresent: false), policy).ShouldTriggerAutomaticStop);
        Equal(true, detector.Observe(Missing(at.AddSeconds(8), teamsPresent: false), policy).ShouldTriggerAutomaticStop);

        var returned = detector.Observe(Active(at.AddSeconds(10)), policy);
        Equal(true, returned.ShouldTriggerAutomaticStart);
        Contains("取消", returned.Detail);
    }

    public static void HostForwardsOneBoundedStopAndARejoin()
    {
        var at = DateTimeOffset.UtcNow;
        var sampler = new QueueSampler(Active(at));
        var joins = 0;
        var leaves = 0;
        var host = new TeamsLocalHeuristicAutoStartHost(
            sampler,
            _ => { joins++; return Task.CompletedTask; },
            _ => { leaves++; return Task.CompletedTask; },
            new TeamsLocalMeetingDetector(2, 3));

        host.PollAsync(new(true)).GetAwaiter().GetResult();
        host.PollAsync(new(true)).GetAwaiter().GetResult();
        sampler.Next = Missing(at.AddSeconds(4), teamsPresent: false);
        host.PollAsync(new(true)).GetAwaiter().GetResult();
        host.PollAsync(new(true)).GetAwaiter().GetResult();
        host.PollAsync(new(true)).GetAwaiter().GetResult();
        host.PollAsync(new(true)).GetAwaiter().GetResult();
        Equal(1, joins);
        Equal(1, leaves);

        sampler.Next = Active(at.AddSeconds(10));
        host.PollAsync(new(true)).GetAwaiter().GetResult();
        Equal(2, joins);
        Equal(1, leaves);
        host.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    private static TeamsLocalMeetingObservation Active(DateTimeOffset at) =>
        new(at, true, true, ["render-endpoint"]);

    private static TeamsLocalMeetingObservation Missing(DateTimeOffset at, bool teamsPresent) =>
        new(at, true, teamsPresent, Array.Empty<string>());

    private static void Equal<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new InvalidOperationException($"Expected {expected}; got {actual}.");
    }

    private static void Contains(string expected, string actual)
    {
        if (!actual.Contains(expected, StringComparison.Ordinal))
            throw new InvalidOperationException($"Expected '{expected}' in '{actual}'.");
    }

    private static void Throws<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }

    private sealed class QueueSampler(TeamsLocalMeetingObservation next) : ITeamsLocalMeetingSignalSampler
    {
        public int CallCount { get; private set; }
        public TeamsLocalMeetingObservation Next { get; set; } = next;
        public TeamsLocalMeetingObservation Sample(DateTimeOffset observedAtUtc)
        {
            CallCount++;
            return Next with { ObservedAtUtc = observedAtUtc };
        }
    }

    private sealed class BlockingSampler(TeamsLocalMeetingObservation next) : ITeamsLocalMeetingSignalSampler
    {
        private readonly ManualResetEventSlim entered = new(false);
        private readonly ManualResetEventSlim release = new(false);
        public int CallCount { get; private set; }
        public TeamsLocalMeetingObservation Next { get; set; } = next;

        public TeamsLocalMeetingObservation Sample(DateTimeOffset observedAtUtc)
        {
            CallCount++;
            entered.Set();
            release.Wait();
            return Next with { ObservedAtUtc = observedAtUtc };
        }

        public void WaitUntilEntered()
        {
            if (!entered.Wait(TimeSpan.FromSeconds(5)))
                throw new TimeoutException("The local Teams sampler did not start.");
        }

        public void Release() => release.Set();
    }
}
