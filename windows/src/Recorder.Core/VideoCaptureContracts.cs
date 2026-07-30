namespace Recorder.Core;

/// <summary>
/// A stable description of a top-level Windows window that may be offered to a
/// user for video capture.  It deliberately is not proof that WGC can capture
/// it: protected/elevated windows can still be rejected by the platform.
/// </summary>
public sealed record VideoCaptureTarget(
    int ProcessId,
    nint WindowHandle,
    string ProcessName,
    string WindowTitle)
{
    public bool IsUsable => ProcessId > 0 && WindowHandle != nint.Zero &&
                            !string.IsNullOrWhiteSpace(ProcessName);
}

public enum VideoCaptureAvailability
{
    Ready,
    UnsupportedWindowsVersion,
    StoragePolicyAudioOnly,
    CapturePipelineNotInstalled,
}

public sealed record VideoCaptureCapability(
    VideoCaptureAvailability Availability,
    string Message)
{
    public bool CanStart => Availability == VideoCaptureAvailability.Ready;
}

/// <summary>
/// Keeps target selection and feature gating independent from the UI and from
/// Windows.Graphics.Capture.  Until a verified frame pipeline exists, the
/// gate intentionally returns CapturePipelineNotInstalled rather than letting
/// callers create a session that falsely claims to contain video.
/// </summary>
public static class VideoCaptureFeatureGate
{
    public const int MinimumWindowsBuild = 19041;

    public static VideoCaptureCapability Evaluate(
        int windowsBuild,
        RecordingStorageDecision storageDecision,
        bool framePipelineInstalled)
    {
        if (windowsBuild < MinimumWindowsBuild)
            return new(VideoCaptureAvailability.UnsupportedWindowsVersion,
                $"Window capture requires Windows 10 build {MinimumWindowsBuild} or later.");
        if (storageDecision is RecordingStorageDecision.Stop or RecordingStorageDecision.AudioOnly)
            return new(VideoCaptureAvailability.StoragePolicyAudioOnly,
                "Available storage only permits audio recording.");
        if (!framePipelineInstalled)
            return new(VideoCaptureAvailability.CapturePipelineNotInstalled,
                "Window video capture is not installed in this Windows build; audio recording remains available.");
        return new(VideoCaptureAvailability.Ready, "Window video capture is available.");
    }
}

public static class VideoCaptureTargetSelection
{
    /// <summary>Returns a current target only when the selected HWND still belongs to the same process.</summary>
    public static VideoCaptureTarget? Resolve(
        VideoCaptureTarget? selected,
        IEnumerable<VideoCaptureTarget> available)
    {
        if (selected is null || !selected.IsUsable) return null;
        return available.FirstOrDefault(candidate => candidate.IsUsable &&
            candidate.ProcessId == selected.ProcessId &&
            candidate.WindowHandle == selected.WindowHandle);
    }
}

public interface IVideoCaptureTargetCatalog
{
    IReadOnlyList<VideoCaptureTarget> ListTargets();
}
