using TeamsRecorder.Windows.Application;

internal static class ApplicationProcessCatalogPolicyTests
{
    public static void ExposesEligibleAppsInCurrentSessionOnly()
    {
        var started = new DateTimeOffset(2026, 8, 9, 1, 2, 3, TimeSpan.Zero);
        var entries = new[]
        {
            Entry(10, "recorder", 4, true),
            Entry(11, "notes", 4, false),
            Entry(12, "browser.exe", 4, true),
            Entry(13, "other-session", 8, true),
            Entry(14, "denied", 4, true) with { Availability = ProcessCatalogAvailability.AccessDenied },
        };

        var filtered = ApplicationProcessCatalogPolicy.FilterEligible(entries, recorderProcessId: 10, recorderSessionId: 4);

        Equal(2, filtered.Count);
        Equal((uint)12, filtered[0].ProcessId);
        Equal((uint)11, filtered[1].ProcessId);

        ProcessCatalogEntry Entry(uint id, string name, int session, bool hasWindow) => new(id, started, name)
        {
            ApplicationName = name,
            ProcessName = name,
            SessionId = session,
            HasWindow = hasWindow,
        };
    }

    private static void Equal<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new InvalidOperationException($"Expected {expected}; got {actual}.");
    }
}
