using Recorder.Core;
using System.Text.Json.Serialization;
using TeamsRecorder.Windows.Application;

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
        var selected = new VideoCaptureTarget(new(42, 100, (nint)0x1234), "ms-teams", "Meeting");
        var current = new VideoCaptureTarget(new(42, 100, (nint)0x1234), "ms-teams", "Meeting renamed");
        var resolved = VideoCaptureTargetSelection.Resolve(selected, [current]);
        if (resolved != current) throw new InvalidOperationException("Expected the current matching target.");

        var replaced = new VideoCaptureTarget(new(42, 100, (nint)0x9999), "ms-teams", "New meeting");
        if (VideoCaptureTargetSelection.Resolve(selected, [replaced]) is not null)
            throw new InvalidOperationException("A recycled process with a new window must require reselection.");
        var pidReused = new VideoCaptureTarget(new(42, 101, (nint)0x1234), "ms-teams", "New process");
        if (VideoCaptureTargetSelection.Resolve(selected, [pidReused]) is not null)
            throw new InvalidOperationException("PID reuse was accepted without matching process start time.");
        if (VideoCaptureTargetSelection.Resolve(new VideoCaptureTarget(new(0, 0, nint.Zero), "", ""), [current]) is not null)
            throw new InvalidOperationException("Invalid target was accepted.");
    }

    public static void TeamsWindowPolicyRejectsUnsafeOrNonTeamsWindows()
    {
        var accepted = Candidate();
        if (!TeamsTopLevelWindowPolicy.IsEligible(accepted, recorderProcessId: 7))
            throw new InvalidOperationException("A visible, unowned ms-teams top-level window was rejected.");
        foreach (var rejected in new[]
        {
            accepted with { ProcessName = "teams" }, accepted with { IsVisible = false },
            accepted with { IsCloaked = true }, accepted with { IsToolWindow = true },
            accepted with { IsChildWindow = true }, accepted with { HasOwner = true },
            accepted with { HasNonZeroSize = false }, accepted with { WindowHandle = nint.Zero },
            accepted with { ProcessId = 7 }, accepted with { ProcessStartTimeUtcTicks = 0 },
        })
            if (TeamsTopLevelWindowPolicy.IsEligible(rejected, recorderProcessId: 7))
                throw new InvalidOperationException("An unsafe Teams capture target was accepted.");
    }

    private static TeamsTopLevelWindowCandidate Candidate() => new(
        (nint)0x1234, 42, "ms-teams", 100, "Meeting", true, false, false, false, false, true);

    public static void WindowTitleIsNeverPartOfPersistedTargetData()
    {
        var title = typeof(VideoCaptureTarget).GetProperty(nameof(VideoCaptureTarget.WindowTitle));
        if (title?.GetCustomAttributes(typeof(JsonIgnoreAttribute), inherit: false).Length != 1)
            throw new InvalidOperationException("Window titles must remain display-only and non-persistent.");
        if (typeof(VideoCaptureTargetIdentity).GetProperties().Any(property =>
                property.Name.Contains("Title", StringComparison.OrdinalIgnoreCase) ||
                property.Name.Contains("Path", StringComparison.OrdinalIgnoreCase)))
            throw new InvalidOperationException("Persistent target identity must not contain a title or path.");
    }
}
