using TeamsRecorder.Windows.Application;

internal static class TeamsProcessCatalogPolicyTests
{
    public static void ExposesOnlyMicrosoftTeamsWithoutUsingWindowTitles()
    {
        var started = new DateTimeOffset(2026, 7, 30, 5, 0, 0, TimeSpan.Zero);
        var entries = new[]
        {
            Entry(10, started, "ms-teams", "Microsoft Teams"),
            Entry(11, started, "MS-TEAMS.EXE", "Microsoft Teams helper"),
            Entry(12, started, "notepad", "Teams meeting notes"),
            Entry(13, started, "teams-updater", "Microsoft Teams"),
        };

        var filtered = TeamsProcessCatalogPolicy.FilterForTeams(entries);

        Equal(2, filtered.Count);
        Equal((uint)10, filtered[0].ProcessId);
        Equal((uint)11, filtered[1].ProcessId);
    }

    private static ProcessCatalogEntry Entry(
        uint processId,
        DateTimeOffset startedAt,
        string processName,
        string windowTitle) => new(processId, startedAt, processName)
    {
        ApplicationName = processName,
        ProcessName = processName,
        WindowTitle = windowTitle,
        HasWindow = true,
        Availability = ProcessCatalogAvailability.Available,
    };

    private static void Equal<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new InvalidOperationException($"Expected {expected}; got {actual}.");
    }
}
