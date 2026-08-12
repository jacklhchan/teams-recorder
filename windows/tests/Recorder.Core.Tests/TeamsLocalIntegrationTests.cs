using Recorder.Core;
using TeamsRecorder.Windows.Application;

internal static class TeamsLocalIntegrationTests
{
    public static void OtherWindowsAreNeverRecognizedAsTeamsMeetings()
    {
        var meeting = Candidate(processId: 41, window: (nint)0x101, created: 1001, processName: "ms-teams.exe");
        var otherApp = Candidate(processId: 42, window: (nint)0x102, created: 1002, processName: "notepad.exe");
        var cloakedTeams = Candidate(processId: 43, window: (nint)0x103, created: 1003, processName: "ms-teams.exe") with
        {
            IsCloaked = true,
        };
        var settingsSurface = Candidate(processId: 44, window: (nint)0x104, created: 1004, processName: "ms-teams.exe");

        if (TeamsLocalMeetingWindowAdmission.TryCreate(otherApp) is not null ||
            TeamsLocalMeetingWindowAdmission.TryCreate(cloakedTeams) is not null)
        {
            throw new InvalidOperationException("A non-Teams or unsafe top-level window was admitted as a meeting surface.");
        }

        var inventory = new WindowsTeamsLocalWindowInventory(
            new FakeWindowSnapshots([meeting, otherApp, cloakedTeams, settingsSurface]),
            new FakeEvidence(identity => identity.WindowHandle == meeting.WindowHandle
                ? TeamsMeetingSurfaceEvidence.Confirmed
                : TeamsMeetingSurfaceEvidence.NotMeeting));
        var observation = inventory.Inspect();

        if (observation.Kind != TeamsLocalMeetingObservationKind.Complete ||
            observation.Candidates.Count != 1 ||
            observation.Candidates[0].Identity.WindowHandle != meeting.WindowHandle)
        {
            throw new InvalidOperationException("The local detector did not fail closed for unrelated or non-meeting windows.");
        }
    }

    public static void PidAndHwndReuseEndsTheOldMeetingBeforeReconfirmation()
    {
        var detector = new TeamsLocalMeetingDetector(new TeamsLocalMeetingDetectorOptions
        {
            ConfirmObservations = 1,
            EndObservations = 5,
            MinimumObservationSpacing = TimeSpan.Zero,
        });
        var before = DateTimeOffset.UnixEpoch;
        var original = new TeamsLocalMeetingWindow(new TeamsWindowIdentity(42, (nint)0x1234, 100));
        var reused = new TeamsLocalMeetingWindow(new TeamsWindowIdentity(42, (nint)0x1234, 200));

        var entered = detector.Observe(TeamsLocalMeetingObservation.Complete([original]), before);
        if (entered.MeetingPresenceChanged != true || detector.ActiveIdentity != original.Identity)
        {
            throw new InvalidOperationException("The original verified meeting did not enter.");
        }

        var replacement = detector.Observe(
            TeamsLocalMeetingObservation.Complete([reused]),
            before.AddSeconds(1));
        if (replacement.MeetingPresenceChanged != false ||
            replacement.Snapshot.IsMeetingPresent || detector.ActiveIdentity is not null)
        {
            throw new InvalidOperationException("A PID/HWND reuse inherited authority from the old meeting.");
        }

        var reentered = detector.Observe(
            TeamsLocalMeetingObservation.Complete([reused]),
            before.AddSeconds(2));
        if (reentered.MeetingPresenceChanged != true || detector.ActiveIdentity != reused.Identity)
        {
            throw new InvalidOperationException("The replacement did not require a fresh confirmation sequence.");
        }
    }

    public static void WinEventJitterSchedulesOneRefreshAndOneTransition()
    {
        var clock = new ControlledClock(DateTimeOffset.UnixEpoch);
        var changes = new FakeChangeSource();
        var window = new TeamsLocalMeetingWindow(new TeamsWindowIdentity(42, (nint)0x991, 100));
        var inventory = new FakeInventory(TeamsLocalMeetingObservation.Complete([window]));
        var monitor = new TeamsLocalMeetingMonitor(
            inventory,
            changes,
            new TeamsLocalMeetingDetector(new TeamsLocalMeetingDetectorOptions
            {
                ConfirmObservations = 1,
                MinimumObservationSpacing = TimeSpan.Zero,
            }),
            clock,
            new TeamsLocalMeetingMonitorOptions
            {
                PollInterval = TimeSpan.FromSeconds(1),
                EventDebounce = TimeSpan.FromMilliseconds(250),
            });
        var transitions = 0;
        monitor.DetectionChanged += (_, update) =>
        {
            if (update.MeetingPresenceChanged is not null)
            {
                transitions++;
            }
        };

        try
        {
            monitor.StartAsync().GetAwaiter().GetResult();
            if (inventory.Calls != 1 || transitions != 1)
            {
                throw new InvalidOperationException("Initial local meeting detection did not publish exactly once.");
            }

            for (var index = 0; index < 20; index++)
            {
                changes.Raise();
            }

            if (clock.PendingCount(TimeSpan.FromMilliseconds(250)) != 1)
            {
                throw new InvalidOperationException("A WinEvent burst scheduled more than one debounced refresh.");
            }

            clock.ReleaseNext(TimeSpan.FromMilliseconds(250));
            WaitUntil(() => inventory.Calls == 2);
            if (inventory.Calls != 2 || transitions != 1)
            {
                throw new InvalidOperationException("WinEvent jitter changed local meeting presence more than once.");
            }
        }
        finally
        {
            monitor.DisposeAsync().AsTask().GetAwaiter().GetResult();
        }
    }

    public static void StaleOrRejectedUiaNeverChangesRecorderMute()
    {
        AssertNoRecorderChangeFor(new FakeControl(
            readFailure: TeamsUiAutomationFailure.StaleElement,
            initialToggleState: false,
            toggleFailure: TeamsUiAutomationFailure.None));
        AssertNoRecorderChangeFor(new FakeControl(
            readFailure: TeamsUiAutomationFailure.None,
            initialToggleState: false,
            toggleFailure: TeamsUiAutomationFailure.ActionRejected));
    }

    public static void LocalIntegrationPayloadsAreBoundedAndPrivacySafe()
    {
        var overflow = TeamsLocalMeetingObservation.Complete(Enumerable.Range(1, 33).Select(index =>
            new TeamsLocalMeetingWindow(new TeamsWindowIdentity(index, (nint)index, index))));
        if (overflow.Kind != TeamsLocalMeetingObservationKind.Ambiguous)
        {
            throw new InvalidOperationException("An oversized local window payload was not rejected.");
        }

        var unsafeStatusProperty = typeof(TeamsLocalIntegrationSnapshot)
            .GetProperties()
            .FirstOrDefault(property => property.PropertyType == typeof(string) ||
                property.PropertyType == typeof(TeamsWindowIdentity) ||
                property.PropertyType == typeof(nint));
        if (unsafeStatusProperty is not null)
        {
            throw new InvalidOperationException("The UI/IPC status projection exposes runtime identity or free-form content.");
        }

        try
        {
            new TeamsMuteAutomationBinding { AutomationId = new string('x', 129) }.Validate();
            throw new InvalidOperationException("An unbounded UIA binding was accepted.");
        }
        catch (ArgumentException)
        {
        }
    }

    private static void AssertNoRecorderChangeFor(FakeControl control)
    {
        var clock = new ControlledClock(DateTimeOffset.UnixEpoch);
        var identity = new TeamsWindowIdentity(42, (nint)0x321, 100);
        var monitor = new TeamsLocalMeetingMonitor(
            new FakeInventory(TeamsLocalMeetingObservation.Complete([new TeamsLocalMeetingWindow(identity)])),
            new FakeChangeSource(),
            new TeamsLocalMeetingDetector(new TeamsLocalMeetingDetectorOptions
            {
                ConfirmObservations = 1,
                MinimumObservationSpacing = TimeSpan.Zero,
            }),
            clock);
        var coordinator = new TeamsLocalIntegrationCoordinator(
            monitor,
            new WindowsTeamsMuteAutomation(
                new TeamsMuteAutomationBinding { AutomationId = "teams.microphone.toggle" },
                new AlwaysCurrentIdentityVerifier(),
                new FakeAutomationBackend(() => control)),
            new FakeMeetingPresenceSink());

        try
        {
            coordinator.StartAsync().GetAwaiter().GetResult();
            var result = coordinator.SetMutedAsync(true).GetAwaiter().GetResult();
            if (result.IsVerified)
            {
                throw new InvalidOperationException("A stale or rejected UIA control was accepted.");
            }
        }
        finally
        {
            coordinator.DisposeAsync().AsTask().GetAwaiter().GetResult();
        }
    }

    private static VideoCaptureTargetCandidate Candidate(
        int processId,
        nint window,
        long created,
        string processName) => new(
            processId,
            window,
            created,
            processName,
            "Untrusted caption must never be consulted",
            IsTopLevel: true,
            IsVisible: true,
            IsCloaked: false,
            IsCaptureProtected: false,
            IsHigherIntegrity: false,
            Width: 1280,
            Height: 720);

    private static void WaitUntil(Func<bool> condition)
    {
        for (var index = 0; index < 100; index++)
        {
            if (condition())
            {
                return;
            }
            Thread.Sleep(5);
        }
        throw new TimeoutException("The expected debounced local detector action did not complete.");
    }

    private sealed class FakeWindowSnapshots(IReadOnlyList<VideoCaptureTargetCandidate> values)
        : IVideoCaptureWindowSnapshotProvider
    {
        public IReadOnlyList<VideoCaptureTargetCandidate> ListCandidates() => values;
    }

    private sealed class FakeEvidence(Func<TeamsWindowIdentity, TeamsMeetingSurfaceEvidence> probe)
        : ITeamsMeetingSurfaceEvidenceProbe
    {
        public TeamsMeetingSurfaceEvidence Probe(TeamsWindowIdentity identity) => probe(identity);
    }

    private sealed class FakeInventory(TeamsLocalMeetingObservation observation) : ITeamsLocalWindowInventory
    {
        public int Calls { get; private set; }
        public TeamsLocalMeetingObservation Inspect()
        {
            Calls++;
            return observation;
        }
    }

    private sealed class FakeChangeSource : ITeamsWindowChangeSource
    {
        public event EventHandler? Changed;
        public void Start() { }
        public void Stop() { }
        public void Raise() => Changed?.Invoke(this, EventArgs.Empty);
        public void Dispose() { }
    }

    private sealed class ControlledClock(DateTimeOffset now) : ITeamsLocalMeetingClock
    {
        private readonly object gate = new();
        private readonly List<Waiter> waiters = [];
        private DateTimeOffset current = now;

        public DateTimeOffset UtcNow
        {
            get { lock (gate) return current; }
        }

        public Task DelayAsync(TimeSpan delay, CancellationToken cancellationToken)
        {
            var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            lock (gate)
            {
                waiters.Add(new Waiter(delay, completion));
            }
            _ = cancellationToken.Register(() => completion.TrySetCanceled(cancellationToken));
            return completion.Task;
        }

        public int PendingCount(TimeSpan delay)
        {
            lock (gate) return waiters.Count(waiter => waiter.Delay == delay && !waiter.Completion.Task.IsCompleted);
        }

        public void ReleaseNext(TimeSpan delay)
        {
            Waiter? waiter;
            lock (gate)
            {
                waiter = waiters.FirstOrDefault(entry => entry.Delay == delay && !entry.Completion.Task.IsCompleted);
                if (waiter is not null)
                {
                    current += delay;
                }
            }
            if (waiter is null)
            {
                throw new InvalidOperationException("No matching test delay is pending.");
            }
            waiter.Completion.TrySetResult();
        }

        private sealed record Waiter(TimeSpan Delay, TaskCompletionSource Completion);
    }

    private sealed class AlwaysCurrentIdentityVerifier : ITeamsWindowIdentityVerifier
    {
        public bool IsCurrent(TeamsWindowIdentity identity) => identity.IsWellFormed;
    }

    private sealed class FakeAutomationBackend(Func<ITeamsUiAutomationControl> create)
        : ITeamsUiAutomationBackend
    {
        public TeamsUiAutomationFailure TryFindExactControl(
            TeamsWindowIdentity identity,
            TeamsMuteAutomationBinding binding,
            out ITeamsUiAutomationControl? control)
        {
            control = create();
            return TeamsUiAutomationFailure.None;
        }
    }

    private sealed class FakeControl(
        TeamsUiAutomationFailure readFailure,
        bool initialToggleState,
        TeamsUiAutomationFailure toggleFailure) : ITeamsUiAutomationControl
    {
        private bool isOn = initialToggleState;

        public TeamsUiAutomationFailure ReadToggleState(out bool value)
        {
            value = isOn;
            return readFailure;
        }

        public TeamsUiAutomationFailure Toggle()
        {
            if (toggleFailure == TeamsUiAutomationFailure.None)
            {
                isOn = !isOn;
            }
            return toggleFailure;
        }

        public void Dispose() { }
    }

    private sealed class FakeMeetingPresenceSink : ITeamsMeetingPresenceSink
    {
        public Task SetMeetingPresenceAsync(bool isInMeeting, CancellationToken cancellationToken = default) => Task.CompletedTask;
    }
}
