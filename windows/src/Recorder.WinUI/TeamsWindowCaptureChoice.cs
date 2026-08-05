using Recorder.Core;

namespace TeamsRecorder.Windows.WinUI;

/// <summary>
/// Presentation-only view of a live Teams top-level window. The target identity
/// is intentionally transient: it is never written to app settings.
/// </summary>
public sealed record TeamsWindowCaptureChoice(VideoCaptureTarget Target)
{
    public string DisplayName => string.IsNullOrWhiteSpace(Target.WindowTitle)
        ? $"Microsoft Teams (PID {Target.ProcessId})"
        : Target.WindowTitle;

    public string Description => $"{Target.ProcessName} · PID {Target.ProcessId}";

    public bool HasSameIdentity(TeamsWindowCaptureChoice? other) =>
        other is not null && Target.Identity == other.Target.Identity;
}
