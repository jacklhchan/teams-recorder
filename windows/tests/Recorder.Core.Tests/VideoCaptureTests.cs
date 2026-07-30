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
        var selected = new VideoCaptureTarget(42, (nint)0x1234, "Teams", "Meeting");
        var current = new VideoCaptureTarget(42, (nint)0x1234, "Teams", "Meeting renamed");
        var resolved = VideoCaptureTargetSelection.Resolve(selected, [current]);
        if (resolved != current) throw new InvalidOperationException("Expected the current matching target.");

        var replaced = new VideoCaptureTarget(42, (nint)0x9999, "Teams", "New meeting");
        if (VideoCaptureTargetSelection.Resolve(selected, [replaced]) is not null)
            throw new InvalidOperationException("A recycled process with a new window must require reselection.");
        if (VideoCaptureTargetSelection.Resolve(new VideoCaptureTarget(0, nint.Zero, "", ""), [current]) is not null)
            throw new InvalidOperationException("Invalid target was accepted.");
    }
}
