using System.Runtime.InteropServices;

namespace TeamsRecorder.Windows.Application;

/// <summary>
/// Privacy-safe, read-only projection of the current Teams microphone button.
/// No HWND, PID, caption, account data, or accessibility text leaves the probe.
/// </summary>
public enum TeamsMuteFollowState
{
    NotInCall,
    Muted,
    Unmuted,
    Unavailable,
}

public sealed record TeamsMuteFollowObservation(
    TeamsMuteFollowState State,
    TeamsUiAutomationFailure Failure = TeamsUiAutomationFailure.None)
{
    public bool ShouldMuteRecorder => State is TeamsMuteFollowState.Muted or TeamsMuteFollowState.Unavailable;

    public static TeamsMuteFollowObservation NotInCall { get; } = new(TeamsMuteFollowState.NotInCall);
    public static TeamsMuteFollowObservation Muted { get; } = new(TeamsMuteFollowState.Muted);
    public static TeamsMuteFollowObservation Unmuted { get; } = new(TeamsMuteFollowState.Unmuted);
    public static TeamsMuteFollowObservation Unavailable(TeamsUiAutomationFailure failure) =>
        new(TeamsMuteFollowState.Unavailable, failure);
}

public interface ITeamsMuteFollowProbe
{
    TeamsMuteFollowObservation Observe();
}

/// <summary>
/// Interprets only the two action names verified on the current Teams desktop
/// microphone button. An unknown localization or duplicate button fails closed
/// instead of guessing whether the user's microphone should enter the recording.
/// </summary>
public static class TeamsMuteFollowInterpreter
{
    public static TeamsMuteFollowObservation Interpret(IReadOnlyList<string> buttonActionNames)
    {
        ArgumentNullException.ThrowIfNull(buttonActionNames);
        if (buttonActionNames.Count == 0)
        {
            return TeamsMuteFollowObservation.NotInCall;
        }

        if (buttonActionNames.Count != 1)
        {
            return TeamsMuteFollowObservation.Unavailable(TeamsUiAutomationFailure.AmbiguousControls);
        }

        return buttonActionNames[0] switch
        {
            // UIA Name describes the action the button will perform.
            "Mute mic" => TeamsMuteFollowObservation.Unmuted,
            "Unmute mic" => TeamsMuteFollowObservation.Muted,
            _ => TeamsMuteFollowObservation.Unavailable(TeamsUiAutomationFailure.ControlRejected),
        };
    }
}

/// <summary>
/// Reads the exact Teams microphone button. This class never invokes UIA and
/// therefore cannot alter Teams mute, join/leave state, or meeting controls.
/// </summary>
public sealed class WindowsTeamsMuteFollowProbe : ITeamsMuteFollowProbe
{
    public const string MicrophoneButtonAutomationId = "microphone-button";
    private const int MaximumNativeCandidates = 512;
    private readonly IVideoCaptureWindowSnapshotProvider windows;
    private readonly ITeamsWindowIdentityVerifier identityVerifier;

    public WindowsTeamsMuteFollowProbe(
        IVideoCaptureWindowSnapshotProvider? windows = null,
        ITeamsWindowIdentityVerifier? identityVerifier = null)
    {
        this.windows = windows ?? new WindowsVideoCaptureWindowSnapshotProvider();
        this.identityVerifier = identityVerifier ?? new WindowsTeamsWindowIdentityVerifier();
    }

    public TeamsMuteFollowObservation Observe()
    {
        if (!OperatingSystem.IsWindows())
        {
            return TeamsMuteFollowObservation.Unavailable(TeamsUiAutomationFailure.PlatformUnavailable);
        }

        try
        {
            var candidates = windows.ListCandidates();
            if (candidates.Count > MaximumNativeCandidates)
            {
                return TeamsMuteFollowObservation.Unavailable(TeamsUiAutomationFailure.AmbiguousControls);
            }

            var teamsWindows = candidates
                .Select(TeamsLocalMeetingWindowAdmission.TryCreate)
                .Where(candidate => candidate is not null)
                .Select(candidate => candidate!)
                .ToArray();
            if (teamsWindows.Length == 0)
            {
                return TeamsMuteFollowObservation.NotInCall;
            }

            var observations = new List<TeamsMuteFollowState>(1);
            foreach (var window in teamsWindows)
            {
                if (!identityVerifier.IsCurrent(window.Identity))
                {
                    return TeamsMuteFollowObservation.Unavailable(TeamsUiAutomationFailure.WindowIdentityInvalid);
                }

                var result = NativeMethods.ReadTeamsMuteButtonState(
                    checked((ulong)window.Identity.WindowHandle.ToInt64()),
                    out var nativeState);
                if (result != 0)
                {
                    return TeamsMuteFollowObservation.Unavailable(TeamsUiAutomationFailure.PlatformUnavailable);
                }

                var state = nativeState switch
                {
                    0 => TeamsMuteFollowState.NotInCall,
                    1 => TeamsMuteFollowState.Muted,
                    2 => TeamsMuteFollowState.Unmuted,
                    _ => TeamsMuteFollowState.Unavailable,
                };
                if (state == TeamsMuteFollowState.Unavailable)
                {
                    return TeamsMuteFollowObservation.Unavailable(TeamsUiAutomationFailure.ControlRejected);
                }
                if (state == TeamsMuteFollowState.NotInCall)
                {
                    continue;
                }

                observations.Add(state);
                if (observations.Count > 1)
                {
                    return TeamsMuteFollowObservation.Unavailable(TeamsUiAutomationFailure.AmbiguousControls);
                }
            }

            return observations.Count == 0
                ? TeamsMuteFollowObservation.NotInCall
                : observations[0] == TeamsMuteFollowState.Muted
                    ? TeamsMuteFollowObservation.Muted
                    : TeamsMuteFollowObservation.Unmuted;
        }
        catch
        {
            return TeamsMuteFollowObservation.Unavailable(TeamsUiAutomationFailure.StaleElement);
        }
    }

    private static class NativeMethods
    {
        [DllImport("Recorder.NativeBridge", EntryPoint = "recorder_native_read_teams_mute_button_state")]
        internal static extern int ReadTeamsMuteButtonState(ulong windowHandle, out uint state);
    }
}
