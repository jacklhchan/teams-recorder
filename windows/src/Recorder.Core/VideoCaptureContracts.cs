namespace Recorder.Core;

/// <summary>
/// A stable description of a top-level Windows window that may be offered to a
/// user for video capture.  It deliberately is not proof that WGC can capture
/// it: protected/elevated windows can still be rejected by the platform.
/// </summary>
public sealed record VideoCaptureTarget(
    int ProcessId,
    nint WindowHandle,
    long ProcessCreationTimeFileTimeUtc,
    string ProcessName,
    string WindowTitle)
{
    public bool IsUsable => ProcessId > 0 && WindowHandle != nint.Zero &&
                            ProcessCreationTimeFileTimeUtc > 0 &&
                            !string.IsNullOrWhiteSpace(ProcessName);
}

/// <summary>
/// An untrusted snapshot obtained while enumerating a native top-level window.
/// It contains only transient runtime facts and must not be persisted to session
/// metadata or diagnostics.
/// </summary>
public sealed record VideoCaptureTargetCandidate(
    int ProcessId,
    nint WindowHandle,
    long ProcessCreationTimeFileTimeUtc,
    string ProcessName,
    string WindowTitle,
    bool IsTopLevel,
    bool IsVisible,
    bool IsCloaked,
    bool IsCaptureProtected,
    bool IsHigherIntegrity,
    int Width,
    int Height);

/// <summary>
/// The managed admission boundary for a native window inventory.  It is
/// deliberately conservative: failure to prove that a window is a normal,
/// currently-running Teams top-level window leaves it out of the picker.
/// WGC preflight remains a separate native check immediately before start.
/// </summary>
public static class VideoCaptureTargetAdmission
{
    public static VideoCaptureTarget? TryCreate(VideoCaptureTargetCandidate candidate)
    {
        ArgumentNullException.ThrowIfNull(candidate);
        if (candidate.ProcessId <= 0 || candidate.WindowHandle == nint.Zero ||
            candidate.ProcessCreationTimeFileTimeUtc <= 0 || !candidate.IsTopLevel ||
            !candidate.IsVisible || candidate.IsCloaked || candidate.IsCaptureProtected ||
            candidate.IsHigherIntegrity || candidate.Width <= 0 || candidate.Height <= 0 ||
            !WindowsExecutableBasename.TryCreateExecutableBasename(candidate.ProcessName, out var executable) ||
            !string.Equals(executable, "ms-teams.exe", StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        var title = candidate.WindowTitle.Trim();
        if (title.Length == 0 || title.Any(char.IsControl)) return null;
        if (title.Length > 160) title = title[..160];
        return new(candidate.ProcessId, candidate.WindowHandle, candidate.ProcessCreationTimeFileTimeUtc,
            executable, title);
    }
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
    /// <summary>
    /// Returns a current target only when the selected HWND still belongs to the
    /// same process instance.  A PID alone is not an identity: Windows can
    /// recycle it after Teams exits, so process creation time is required to
    /// fail closed before a native WGC session is created.
    /// </summary>
    public static VideoCaptureTarget? Resolve(
        VideoCaptureTarget? selected,
        IEnumerable<VideoCaptureTarget> available)
    {
        if (selected is null || !selected.IsUsable) return null;
        return available.FirstOrDefault(candidate => candidate.IsUsable &&
            candidate.ProcessId == selected.ProcessId &&
            candidate.WindowHandle == selected.WindowHandle &&
            candidate.ProcessCreationTimeFileTimeUtc == selected.ProcessCreationTimeFileTimeUtc);
    }

    /// <summary>
    /// Retains the selected exact window when it is still current. If Teams
    /// replaced the meeting window after the chooser last refreshed, the
    /// catalog contains only admitted Teams top-level windows, so select its
    /// current entry instead of carrying a stale HWND into WGC. Lifecycle code
    /// must still validate the result immediately before native capture.
    /// </summary>
    public static VideoCaptureTarget? RetainOrSelectCurrent(
        VideoCaptureTarget? selected,
        IReadOnlyList<VideoCaptureTarget> available) =>
        Resolve(selected, available) ?? available.FirstOrDefault(candidate => candidate.IsUsable);

    /// <summary>
    /// Selects a Teams meeting window without guessing from a localized title.
    /// An explicit user choice wins while its complete identity remains live.
    /// Otherwise a single independently-confirmed meeting surface wins, then a
    /// retained automatic choice, a sole Teams window, or the current admitted
    /// foreground Teams window. Multiple confirmed meetings remain ambiguous.
    /// </summary>
    public static VideoCaptureTarget? SelectAutomatically(
        VideoCaptureTarget? selected,
        bool selectedWasExplicit,
        IReadOnlyList<VideoCaptureTarget> available,
        IReadOnlyList<VideoCaptureTarget> confirmedMeetingTargets,
        nint foregroundWindowHandle)
    {
        ArgumentNullException.ThrowIfNull(available);
        ArgumentNullException.ThrowIfNull(confirmedMeetingTargets);

        var retained = Resolve(selected, available);
        if (selectedWasExplicit && retained is not null)
        {
            return retained;
        }

        var confirmed = confirmedMeetingTargets
            .Select(candidate => Resolve(candidate, available))
            .Where(candidate => candidate is not null)
            .Cast<VideoCaptureTarget>()
            .Distinct()
            .ToArray();
        if (confirmed.Length == 1)
        {
            return confirmed[0];
        }
        if (confirmed.Length > 1)
        {
            return retained is not null && confirmed.Contains(retained)
                ? retained
                : null;
        }

        if (retained is not null)
        {
            return retained;
        }

        var usable = available.Where(candidate => candidate.IsUsable).ToArray();
        if (usable.Length == 1)
        {
            return usable[0];
        }

        return foregroundWindowHandle == nint.Zero
            ? null
            : usable.FirstOrDefault(candidate => candidate.WindowHandle == foregroundWindowHandle);
    }
}

public interface IVideoCaptureTargetCatalog
{
    IReadOnlyList<VideoCaptureTarget> ListTargets();
}
