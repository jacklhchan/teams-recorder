using TeamsRecorder.Windows.WinUI;

internal static class CaptureSourceChoiceTests
{
    public static void DefaultsToRecommendedSystemLoopback()
    {
        Equal(CaptureSourceKind.SystemAudio, CaptureSourceChoice.Default.Kind);
        Contains("建議", CaptureSourceChoice.Default.DisplayName);
        Contains("loopback", CaptureSourceChoice.Default.Description);
    }

    public static void SupportsAnyApplicationAndNeverSilentlyFallsBack()
    {
        var process = CaptureSourceChoice.SelectedApplication;

        Equal("指定應用程式", process.DisplayName);
        Contains("所選應用程式", process.Description);
        Contains("絕不回退至系統音訊", process.Description);
        Equal(process, CaptureSourceChoice.ResolveSelection(requested: null, current: process));
    }

    private static void Equal<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new InvalidOperationException($"Expected {expected}; got {actual}.");
    }

    private static void Contains(string expected, string actual)
    {
        if (!actual.Contains(expected, StringComparison.Ordinal))
            throw new InvalidOperationException($"Expected '{actual}' to contain '{expected}'.");
    }
}
