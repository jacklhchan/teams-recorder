using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Recorder.Core;

namespace TeamsRecorder.Windows.Application;

/// <summary>
/// Produces transient facts for each user-visible top-level window.  A failed
/// native inspection is deliberately omitted rather than guessed: callers must
/// not offer a target that could turn into a desktop or another-window capture.
/// </summary>
public interface IVideoCaptureWindowSnapshotProvider
{
    IReadOnlyList<VideoCaptureTargetCandidate> ListCandidates();
}

/// <summary>
/// Enumerates all top-level windows rather than Process.MainWindowHandle, which
/// only exposes one window and misses Teams meeting and shared-content pop-outs.
/// This component only inventories candidates; native WGC preflight is still
/// required immediately before capture starts.
/// </summary>
public sealed class WindowsVideoCaptureWindowSnapshotProvider : IVideoCaptureWindowSnapshotProvider
{
    private const int GaRoot = 2;
    private const int GwlStyle = -16;
    private const nint WsChild = 0x40000000;
    private const uint DwmwaCloaked = 14;
    private const uint WdaMonitor = 1;
    private const uint WdaExcludeFromCapture = 0x11;
    private const uint ProcessQueryLimitedInformation = 0x1000;
    private const uint TokenQuery = 0x0008;
    private const int TokenIntegrityLevel = 25;

    public IReadOnlyList<VideoCaptureTargetCandidate> ListCandidates()
    {
        if (!TryGetIntegrityRid(checked((uint)Environment.ProcessId), out var currentIntegrity)) return Array.Empty<VideoCaptureTargetCandidate>();
        var candidates = new List<VideoCaptureTargetCandidate>();
        _ = EnumWindows((window, _) =>
        {
            try
            {
                if (TryReadCandidate(window, currentIntegrity, out var candidate)) candidates.Add(candidate);
            }
            catch (ArgumentException) { }
            catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception) { }
            return true;
        }, nint.Zero);
        return candidates;
    }

    private static bool TryReadCandidate(nint window, uint currentIntegrity, out VideoCaptureTargetCandidate candidate)
    {
        candidate = null!;
        var cloaked = true;
        var captureProtected = true;
        if (GetAncestor(window, GaRoot) != window || !IsWindowVisible(window) ||
            (GetWindowLongPtrW(window, GwlStyle) & WsChild) != 0 ||
            !GetWindowRect(window, out var rect) || rect.Right <= rect.Left || rect.Bottom <= rect.Top ||
            !TryGetDwmCloaked(window, out cloaked) ||
            !TryGetCaptureProtected(window, out captureProtected))
        {
            return false;
        }

        _ = GetWindowThreadProcessId(window, out var processId);
        if (processId == 0 || processId > int.MaxValue || !TryGetIntegrityRid(processId, out var targetIntegrity)) return false;
        using var process = Process.GetProcessById((int)processId);
        // Native PID-reuse validation uses Windows FILETIME, not .NET ticks.
        // Keep this identity value in the exact representation passed to the
        // C ABI so no epoch conversion can silently select a reused process.
        var created = process.StartTime.ToUniversalTime().ToFileTimeUtc();
        var processName = process.ProcessName;
        var title = GetWindowTitle(window);
        if (created <= 0 || string.IsNullOrWhiteSpace(processName) || string.IsNullOrWhiteSpace(title)) return false;

        candidate = new VideoCaptureTargetCandidate(
            (int)processId,
            window,
            created,
            processName,
            title,
            IsTopLevel: true,
            IsVisible: true,
            IsCloaked: cloaked,
            IsCaptureProtected: captureProtected,
            IsHigherIntegrity: targetIntegrity > currentIntegrity,
            Width: rect.Right - rect.Left,
            Height: rect.Bottom - rect.Top);
        return true;
    }

    private static bool TryGetDwmCloaked(nint window, out bool cloaked)
    {
        cloaked = true;
        var value = 0;
        if (DwmGetWindowAttribute(window, DwmwaCloaked, ref value, sizeof(int)) != 0) return false;
        cloaked = value != 0;
        return true;
    }

    private static bool TryGetCaptureProtected(nint window, out bool protectedWindow)
    {
        protectedWindow = true;
        if (!GetWindowDisplayAffinity(window, out var affinity)) return false;
        protectedWindow = affinity is WdaMonitor or WdaExcludeFromCapture;
        return true;
    }

    private static string GetWindowTitle(nint window)
    {
        var length = GetWindowTextLengthW(window);
        if (length <= 0 || length > 160) return string.Empty;
        var builder = new StringBuilder(length + 1);
        var written = GetWindowTextW(window, builder, builder.Capacity);
        if (written <= 0) return string.Empty;
        var title = builder.ToString().Trim();
        return title.Any(char.IsControl) ? string.Empty : title;
    }

    private static bool TryGetIntegrityRid(uint processId, out uint rid)
    {
        rid = 0;
        var process = OpenProcess(ProcessQueryLimitedInformation, false, processId);
        if (process == nint.Zero) return false;
        try
        {
            if (!OpenProcessToken(process, TokenQuery, out var token) || token == nint.Zero) return false;
            try
            {
                _ = GetTokenInformation(token, TokenIntegrityLevel, nint.Zero, 0, out var size);
                if (size == 0) return false;
                var buffer = Marshal.AllocHGlobal(checked((int)size));
                try
                {
                    if (!GetTokenInformation(token, TokenIntegrityLevel, buffer, size, out _)) return false;
                    var sid = Marshal.ReadIntPtr(buffer);
                    if (sid == nint.Zero) return false;
                    var countPointer = GetSidSubAuthorityCount(sid);
                    if (countPointer == nint.Zero) return false;
                    var count = Marshal.ReadByte(countPointer);
                    if (count == 0) return false;
                    var ridPointer = GetSidSubAuthority(sid, (uint)(count - 1));
                    if (ridPointer == nint.Zero) return false;
                    rid = unchecked((uint)Marshal.ReadInt32(ridPointer));
                    return true;
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
            finally { _ = CloseHandle(token); }
        }
        finally { _ = CloseHandle(process); }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect { public int Left; public int Top; public int Right; public int Bottom; }
    private delegate bool EnumWindowsProc(nint window, nint parameter);

    [DllImport("user32.dll", SetLastError = true)] private static extern bool EnumWindows(EnumWindowsProc callback, nint parameter);
    [DllImport("user32.dll")] private static extern nint GetAncestor(nint window, int flags);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(nint window);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern nint GetWindowLongPtrW(nint window, int index);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool GetWindowRect(nint window, out NativeRect rect);
    [DllImport("user32.dll", SetLastError = true)] private static extern uint GetWindowThreadProcessId(nint window, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextLengthW(nint window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextW(nint window, StringBuilder text, int maximumCount);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool GetWindowDisplayAffinity(nint window, out uint affinity);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(nint window, uint attribute, ref int value, int valueSize);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern nint OpenProcess(uint access, bool inheritHandle, uint processId);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CloseHandle(nint handle);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(nint process, uint access, out nint token);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool GetTokenInformation(nint token, int informationClass, nint buffer, uint bufferLength, out uint returnLength);
    [DllImport("advapi32.dll")] private static extern nint GetSidSubAuthorityCount(nint sid);
    [DllImport("advapi32.dll")] private static extern nint GetSidSubAuthority(nint sid, uint subAuthority);
}

public sealed class WindowsVideoCaptureTargetCatalog : IVideoCaptureTargetCatalog
{
    private readonly IVideoCaptureWindowSnapshotProvider snapshotProvider;

    public WindowsVideoCaptureTargetCatalog() : this(new WindowsVideoCaptureWindowSnapshotProvider()) { }

    public WindowsVideoCaptureTargetCatalog(IVideoCaptureWindowSnapshotProvider snapshotProvider) =>
        this.snapshotProvider = snapshotProvider ?? throw new ArgumentNullException(nameof(snapshotProvider));

    public IReadOnlyList<VideoCaptureTarget> ListTargets() => snapshotProvider.ListCandidates()
        .Select(VideoCaptureTargetAdmission.TryCreate)
        .Where(target => target is not null)
        .Cast<VideoCaptureTarget>()
        .OrderBy(target => target.WindowTitle, StringComparer.OrdinalIgnoreCase)
        .ThenBy(target => target.WindowHandle)
        .ToArray();
}
