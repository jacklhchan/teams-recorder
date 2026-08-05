using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Recorder.Core;

namespace TeamsRecorder.Windows.Application;

/// <summary>Snapshot of only the Win32 facts needed for safe Teams-window admission.</summary>
public sealed record TeamsTopLevelWindowCandidate(
    nint WindowHandle, int ProcessId, string ProcessName, long ProcessStartTimeUtcTicks,
    string WindowTitle, bool IsVisible, bool IsCloaked, bool IsToolWindow,
    bool IsChildWindow, bool HasOwner, bool HasNonZeroSize);

/// <summary>Fail-closed filter which is testable independently of Win32 calls.</summary>
public static class TeamsTopLevelWindowPolicy
{
    public static bool IsEligible(TeamsTopLevelWindowCandidate candidate, int recorderProcessId) =>
        candidate.WindowHandle != nint.Zero && candidate.ProcessId > 0 &&
        candidate.ProcessId != recorderProcessId && candidate.ProcessStartTimeUtcTicks > 0 &&
        string.Equals(candidate.ProcessName, "ms-teams", StringComparison.OrdinalIgnoreCase) &&
        candidate.IsVisible && !candidate.IsCloaked && !candidate.IsToolWindow &&
        !candidate.IsChildWindow && !candidate.HasOwner && candidate.HasNonZeroSize;
}

/// <summary>
/// Enumerates all capture-eligible ms-teams top-level windows for a future WGC picker.
/// Window titles are display-only and deliberately never form part of persistent identity.
/// </summary>
public sealed class WindowsVideoCaptureTargetCatalog : IVideoCaptureTargetCatalog
{
    public IReadOnlyList<VideoCaptureTarget> ListTargets()
    {
        var result = new List<VideoCaptureTarget>();
        _ = EnumWindows((window, _) =>
        {
            if (!TryGetCandidate(window, out var candidate) ||
                !TeamsTopLevelWindowPolicy.IsEligible(candidate, Environment.ProcessId)) return true;
            result.Add(new VideoCaptureTarget(
                new VideoCaptureTargetIdentity(candidate.ProcessId,
                    candidate.ProcessStartTimeUtcTicks, candidate.WindowHandle),
                candidate.ProcessName, candidate.WindowTitle));
            return true;
        }, nint.Zero);

        return result.OrderBy(target => target.WindowTitle, StringComparer.OrdinalIgnoreCase)
            .ThenBy(target => target.ProcessId).ThenBy(target => target.WindowHandle).ToArray();
    }

    private static bool TryGetCandidate(nint window, out TeamsTopLevelWindowCandidate candidate)
    {
        candidate = default!;
        if (window == nint.Zero) return false;
        _ = GetWindowThreadProcessId(window, out var rawProcessId);
        if (rawProcessId == 0 || rawProcessId > int.MaxValue) return false;
        try
        {
            using var process = Process.GetProcessById((int)rawProcessId);
            var style = GetWindowLongPtr(window, GwlStyle).ToInt64();
            var extendedStyle = GetWindowLongPtr(window, GwlExStyle).ToInt64();
            var cloaked = DwmGetWindowAttribute(window, DwmwaCloaked, out var value, sizeof(int)) == 0 && value != 0;
            var hasBounds = GetWindowRect(window, out var bounds) && bounds.Right > bounds.Left && bounds.Bottom > bounds.Top;
            candidate = new(window, process.Id, process.ProcessName,
                process.StartTime.ToUniversalTime().Ticks, GetWindowTitle(window),
                IsWindowVisible(window), cloaked, (extendedStyle & WsExToolWindow) != 0,
                (style & WsChild) != 0, GetWindow(window, GwOwner) != nint.Zero, hasBounds);
            return true;
        }
        catch (ArgumentException) { return false; }
        catch (InvalidOperationException) { return false; }
        catch (System.ComponentModel.Win32Exception) { return false; }
    }

    private static string GetWindowTitle(nint window)
    {
        var length = GetWindowTextLength(window);
        if (length <= 0 || length > 32_768) return string.Empty;
        var text = new StringBuilder(length + 1);
        return GetWindowText(window, text, text.Capacity) > 0 ? text.ToString() : string.Empty;
    }

    private const int GwlStyle = -16, GwlExStyle = -20;
    private const long WsChild = 0x40000000L, WsExToolWindow = 0x00000080L;
    private const uint GwOwner = 4, DwmwaCloaked = 14;
    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    private delegate bool EnumWindowsProc(nint window, nint parameter);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, nint parameter);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(nint window);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint window, out uint processId);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern nint GetWindowLongPtr(nint window, int index);
    [DllImport("user32.dll")] private static extern nint GetWindow(nint window, uint command);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(nint window, out Rect rect);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextLength(nint window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(nint window, StringBuilder text, int maxCount);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(nint window, uint attribute, out int value, int valueSize);
}
