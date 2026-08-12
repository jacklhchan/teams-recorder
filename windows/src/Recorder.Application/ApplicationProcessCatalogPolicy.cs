using Recorder.Core;

namespace TeamsRecorder.Windows.Application;

/// <summary>
/// Product admission policy for application-loopback capture. Only a live,
/// presentation-safe process in the recorder user's interactive session is
/// exposed. The recorder itself is excluded and the policy never broadens a
/// failed application selection into system-loopback capture.
/// </summary>
public static class ApplicationProcessCatalogPolicy
{
    public static IReadOnlyList<ProcessCatalogEntry> FilterEligible(
        IEnumerable<ProcessCatalogEntry> entries,
        uint recorderProcessId,
        int recorderSessionId)
    {
        ArgumentNullException.ThrowIfNull(entries);
        if (recorderProcessId == 0) throw new ArgumentOutOfRangeException(nameof(recorderProcessId));
        if (recorderSessionId < 0) throw new ArgumentOutOfRangeException(nameof(recorderSessionId));

        return entries
            .Where(entry => entry is not null &&
                entry.Availability == ProcessCatalogAvailability.Available &&
                entry.ProcessId != recorderProcessId &&
                entry.SessionId == recorderSessionId &&
                WindowsExecutableBasename.TryCreateExecutableBasename(entry.ProcessName, out _))
            .OrderByDescending(entry => entry.HasWindow)
            .ThenBy(entry => entry.ApplicationName, StringComparer.OrdinalIgnoreCase)
            .ThenBy(entry => entry.ProcessId)
            .ToArray();
    }
}
