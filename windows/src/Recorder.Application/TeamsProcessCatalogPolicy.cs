using Recorder.Core;

namespace TeamsRecorder.Windows.Application;

/// <summary>
/// Limits the product capture picker to the Microsoft Teams desktop process.
/// The general process catalog remains deliberately generic for application
/// services, but the Teams recorder UI must not encourage unrelated-app
/// capture. Matching is based only on the safe executable basename; no path,
/// command line, or window text participates in the decision.
/// </summary>
public static class TeamsProcessCatalogPolicy
{
    public static IReadOnlyList<ProcessCatalogEntry> FilterForTeams(
        IEnumerable<ProcessCatalogEntry> entries)
    {
        ArgumentNullException.ThrowIfNull(entries);
        return entries.Where(IsTeamsProcess).ToArray();
    }

    public static bool IsTeamsProcess(ProcessCatalogEntry entry)
    {
        ArgumentNullException.ThrowIfNull(entry);
        return IsTeamsExecutable(entry.ProcessName) || IsTeamsExecutable(entry.ApplicationName);
    }

    public static bool IsTeamsExecutable(string value) =>
        WindowsExecutableBasename.TryCreateExecutableBasename(value, out var executable) &&
        (string.Equals(executable, "ms-teams.exe", StringComparison.OrdinalIgnoreCase) ||
         string.Equals(executable, "teams.exe", StringComparison.OrdinalIgnoreCase));
}
