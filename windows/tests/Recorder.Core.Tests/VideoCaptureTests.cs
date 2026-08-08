using Recorder.Core;

internal static class VideoCaptureTests
{
    public static void FeatureGateFailsClosedUntilFramePipelineExists()
    {
        var unavailable = VideoCaptureFeatureGate.Evaluate(22621, RecordingStorageDecision.Normal, framePipelineInstalled: false);
        if (unavailable.CanStart || unavailable.Availability != VideoCaptureAvailability.CapturePipelineNotInstalled)
            throw new InvalidOperationException("An unimplemented video pipeline must not be startable.");

        var audioOnly = VideoCaptureFeatureGate.Evaluate(22621, RecordingStorageDecision.AudioOnly, framePipelineInstalled: true);
        if (audioOnly.Availability != VideoCaptureAvailability.StoragePolicyAudioOnly)
            throw new InvalidOperationException("Storage policy must take precedence over video availability.");

        var oldWindows = VideoCaptureFeatureGate.Evaluate(19040, RecordingStorageDecision.Normal, framePipelineInstalled: true);
        if (oldWindows.Availability != VideoCaptureAvailability.UnsupportedWindowsVersion)
            throw new InvalidOperationException("Unsupported Windows versions must be rejected.");
    }

    public static void TargetSelectionRequiresTheSameLiveWindow()
    {
        var selected = new VideoCaptureTarget(42, (nint)0x1234, 101, "Teams", "Meeting");
        var current = new VideoCaptureTarget(42, (nint)0x1234, 101, "Teams", "Meeting renamed");
        var resolved = VideoCaptureTargetSelection.Resolve(selected, [current]);
        if (resolved != current) throw new InvalidOperationException("Expected the current matching target.");

        var replaced = new VideoCaptureTarget(42, (nint)0x9999, 101, "Teams", "New meeting");
        if (VideoCaptureTargetSelection.Resolve(selected, [replaced]) is not null)
            throw new InvalidOperationException("A recycled process with a new window must require reselection.");
        var reusedProcess = new VideoCaptureTarget(42, (nint)0x1234, 202, "Teams", "Meeting");
        if (VideoCaptureTargetSelection.Resolve(selected, [reusedProcess]) is not null)
            throw new InvalidOperationException("A reused PID must require the user to select the current Teams window again.");
        if (VideoCaptureTargetSelection.Resolve(new VideoCaptureTarget(0, nint.Zero, 0, "", ""), [current]) is not null)
            throw new InvalidOperationException("Invalid target was accepted.");
    }

    public static void TargetAdmissionFailsClosedForUnsafeOrUnrelatedWindows()
    {
        var valid = Candidate();
        var accepted = VideoCaptureTargetAdmission.TryCreate(valid);
        if (accepted is null || accepted.ProcessName != "ms-teams.exe")
            throw new InvalidOperationException("A visible Teams top-level window should be available for explicit selection.");

        foreach (var unsafeCandidate in new[]
                 {
                     valid with { IsTopLevel = false },
                     valid with { IsVisible = false },
                     valid with { IsCloaked = true },
                     valid with { IsCaptureProtected = true },
                     valid with { IsHigherIntegrity = true },
                     valid with { Width = 0 },
                     valid with { ProcessName = "notepad.exe" },
                     valid with { ProcessCreationTimeFileTimeUtc = 0 },
                 })
        {
            if (VideoCaptureTargetAdmission.TryCreate(unsafeCandidate) is not null)
                throw new InvalidOperationException("An unsafe or unrelated window was offered for video capture.");
        }
    }

    private static VideoCaptureTargetCandidate Candidate() => new(
        ProcessId: 42,
        WindowHandle: (nint)0x1234,
        ProcessCreationTimeFileTimeUtc: 101,
        ProcessName: "ms-teams.exe",
        WindowTitle: "Test meeting",
        IsTopLevel: true,
        IsVisible: true,
        IsCloaked: false,
        IsCaptureProtected: false,
        IsHigherIntegrity: false,
        Width: 1280,
        Height: 720);
}
