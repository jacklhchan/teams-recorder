using System.Diagnostics;
using Recorder.Core;

namespace TeamsRecorder.Windows.Application;

/// <summary>
/// Enumerates user-visible top-level process windows for a future WGC picker.
/// Enumeration has no capture side effects and is safe to use even while the
/// video encoder/muxer feature remains gated off.
/// </summary>
public sealed class WindowsVideoCaptureTargetCatalog : IVideoCaptureTargetCatalog
{
    public IReadOnlyList<VideoCaptureTarget> ListTargets()
    {
        var result = new List<VideoCaptureTarget>();
        foreach (var process in Process.GetProcesses())
        {
            using (process)
            {
                try
                {
                    var handle = process.MainWindowHandle;
                    var title = process.MainWindowTitle?.Trim() ?? string.Empty;
                    if (handle == nint.Zero || string.IsNullOrEmpty(title)) continue;
                    result.Add(new VideoCaptureTarget(process.Id, handle, process.ProcessName, title));
                }
                catch (InvalidOperationException) { }
                catch (System.ComponentModel.Win32Exception) { }
            }
        }

        return result
            .OrderBy(target => target.ProcessName, StringComparer.OrdinalIgnoreCase)
            .ThenBy(target => target.WindowTitle, StringComparer.OrdinalIgnoreCase)
            .ThenBy(target => target.ProcessId)
            .ToArray();
    }
}
