using System.Diagnostics;

namespace TeamsRecorder.Windows.Application;

public enum ProcessCatalogAvailability { Available, AccessDenied, Exited }

public sealed record ProcessCatalogEntry(uint ProcessId, DateTimeOffset StartedAt, string DisplayName)
{
    public string ApplicationName { get; init; } = DisplayName;
    public string ProcessName { get; init; } = DisplayName;
    public string? WindowTitle { get; init; }
    public bool HasWindow { get; init; }
    public ProcessCatalogAvailability Availability { get; init; } = ProcessCatalogAvailability.Available;
    public DateTimeOffset StartedAtUtc => StartedAt.ToUniversalTime();
    public SelectedProcessTarget ToTarget() => new(ProcessId, StartedAt, DisplayName);
}

public interface IProcessCatalog
{
    IReadOnlyList<ProcessCatalogEntry> GetProcesses();
    bool IsCurrent(SelectedProcessTarget target);
}

/// <summary>
/// Produces transient, presentation-safe process choices. It never reads or
/// persists executable paths, command lines, credentials, or tokens. A window
/// title is UI-only and is not passed to storage metadata.
/// </summary>
public sealed class ProcessCatalog : IProcessCatalog
{
    public IReadOnlyList<ProcessCatalogEntry> GetProcesses() => Process.GetProcesses()
        .Select(process => { using (process) return TryRead(process, out var entry) ? entry : null; })
        .Where(entry => entry is not null).Select(entry => entry!).OrderBy(entry => entry.DisplayName, StringComparer.OrdinalIgnoreCase).ThenBy(entry => entry.ProcessId).ToArray();

    public bool IsCurrent(SelectedProcessTarget target)
    {
        ArgumentNullException.ThrowIfNull(target); target.Validate();
        try { using var process = Process.GetProcessById(checked((int)target.ProcessId)); return TryRead(process, out var entry) && entry.ProcessId == target.ProcessId && entry.StartedAt == target.StartedAt; }
        catch (ArgumentException) { return false; } catch (InvalidOperationException) { return false; } catch (System.ComponentModel.Win32Exception) { return false; }
    }

    private static bool TryRead(Process process, out ProcessCatalogEntry entry)
    {
        try
        {
            if (process.Id <= 0 || process.StartTime == default || string.IsNullOrWhiteSpace(process.ProcessName))
            {
                entry = null!;
                return false;
            }

            var hasWindow = process.MainWindowHandle != IntPtr.Zero;
            var title = hasWindow ? SafeWindowTitle(process.MainWindowTitle) : null;
            entry = new((uint)process.Id, new DateTimeOffset(process.StartTime), process.ProcessName)
            {
                ApplicationName = process.ProcessName,
                ProcessName = process.ProcessName,
                WindowTitle = title,
                HasWindow = hasWindow,
                Availability = ProcessCatalogAvailability.Available,
            };
            return true;
        }
        catch (InvalidOperationException) { entry = null!; return false; } catch (System.ComponentModel.Win32Exception) { entry = null!; return false; }
    }

    private static string? SafeWindowTitle(string? value)
    {
        var title = value?.Trim();
        if (string.IsNullOrEmpty(title) || title.Any(char.IsControl)) return null;
        return title.Length <= 160 ? title : title[..160];
    }
}
