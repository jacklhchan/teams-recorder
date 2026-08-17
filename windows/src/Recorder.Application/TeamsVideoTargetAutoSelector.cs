using System.Runtime.InteropServices;
using Recorder.Core;

namespace TeamsRecorder.Windows.Application;

/// <summary>
/// Chooses only from the already-admitted Teams window catalog. The selector
/// uses the exact, read-only Teams microphone control as meeting evidence and
/// never examines a localized meeting title or falls back to desktop capture.
/// </summary>
public interface ITeamsVideoTargetAutoSelector
{
    VideoCaptureTarget? Select(
        VideoCaptureTarget? selected,
        bool selectedWasExplicit,
        IReadOnlyList<VideoCaptureTarget> available);
}

public sealed class WindowsTeamsVideoTargetAutoSelector : ITeamsVideoTargetAutoSelector
{
    private readonly ITeamsWindowIdentityVerifier identityVerifier;

    public WindowsTeamsVideoTargetAutoSelector(
        ITeamsWindowIdentityVerifier? identityVerifier = null)
    {
        this.identityVerifier = identityVerifier ?? new WindowsTeamsWindowIdentityVerifier();
    }

    public VideoCaptureTarget? Select(
        VideoCaptureTarget? selected,
        bool selectedWasExplicit,
        IReadOnlyList<VideoCaptureTarget> available)
    {
        ArgumentNullException.ThrowIfNull(available);
        if (!OperatingSystem.IsWindows())
        {
            return VideoCaptureTargetSelection.SelectAutomatically(
                selected,
                selectedWasExplicit,
                available,
                Array.Empty<VideoCaptureTarget>(),
                nint.Zero);
        }

        var confirmed = new List<VideoCaptureTarget>();
        foreach (var target in available)
        {
            var identity = new TeamsWindowIdentity(
                target.ProcessId,
                target.WindowHandle,
                target.ProcessCreationTimeFileTimeUtc);
            if (!identityVerifier.IsCurrent(identity))
            {
                continue;
            }

            try
            {
                var result = NativeMethods.ReadTeamsMuteButtonState(
                    checked((ulong)target.WindowHandle.ToInt64()),
                    out var state);
                if (result == 0 && state is 1 or 2)
                {
                    confirmed.Add(target);
                }
            }
            catch (DllNotFoundException) { }
            catch (EntryPointNotFoundException) { }
            catch (BadImageFormatException) { }
        }

        return VideoCaptureTargetSelection.SelectAutomatically(
            selected,
            selectedWasExplicit,
            available,
            confirmed,
            GetForegroundWindow());
    }

    private static class NativeMethods
    {
        [DllImport("Recorder.NativeBridge", EntryPoint = "recorder_native_read_teams_mute_button_state")]
        internal static extern int ReadTeamsMuteButtonState(ulong windowHandle, out uint state);
    }

    [DllImport("user32.dll")]
    private static extern nint GetForegroundWindow();
}
