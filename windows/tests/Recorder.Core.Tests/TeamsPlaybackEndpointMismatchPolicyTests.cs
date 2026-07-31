using Recorder.Core;
using TeamsRecorder.Windows.Application;

internal static class TeamsPlaybackEndpointMismatchPolicyTests
{
    public static void DoesNotWarnWithoutAnIndependentTeamsObservation()
    {
        var warning = TeamsPlaybackEndpointMismatchPolicy.Evaluate(
            SystemRequest(renderEndpointId: null),
            windowsConsoleDefaultRenderEndpointId: "windows-default",
            TeamsPlaybackEndpointObservation.Unknown);

        Equal(TeamsPlaybackEndpointWarningKind.None, warning.Kind);
    }

    public static void WarnsWhenTeamsDiffersFromTheWindowsDefault()
    {
        var warning = TeamsPlaybackEndpointMismatchPolicy.Evaluate(
            SystemRequest(renderEndpointId: null),
            windowsConsoleDefaultRenderEndpointId: "windows-speakers",
            TeamsPlaybackEndpointObservation.Known("teams-headphones"));

        Equal(TeamsPlaybackEndpointWarningKind.DefaultRenderEndpointMismatch, warning.Kind);
        Contains("Windows 預設", warning.Message!);
    }

    public static void WarnsWhenTeamsDiffersFromAnExplicitSelection()
    {
        var warning = TeamsPlaybackEndpointMismatchPolicy.Evaluate(
            SystemRequest(renderEndpointId: "chosen-speakers"),
            windowsConsoleDefaultRenderEndpointId: "windows-speakers",
            TeamsPlaybackEndpointObservation.Known("teams-headphones"));

        Equal(TeamsPlaybackEndpointWarningKind.SelectedRenderEndpointMismatch, warning.Kind);
    }

    public static void DoesNotWarnForMatchingOrProcessAudioRequests()
    {
        var matching = TeamsPlaybackEndpointMismatchPolicy.Evaluate(
            SystemRequest(renderEndpointId: "teams-headphones"),
            windowsConsoleDefaultRenderEndpointId: "windows-speakers",
            TeamsPlaybackEndpointObservation.Known("teams-headphones"));
        Equal(TeamsPlaybackEndpointWarningKind.None, matching.Kind);

        var process = new RecordingStartRequest(
            RecordingSessionKind.Manual,
            RecordingAudioSource.SelectedProcessLoopback,
            ProcessTarget: new SelectedProcessTarget(42, DateTimeOffset.UtcNow, "ms-teams"),
            IncludeProcessTree: true);
        var ignored = TeamsPlaybackEndpointMismatchPolicy.Evaluate(
            process,
            "windows-speakers",
            TeamsPlaybackEndpointObservation.Known("teams-headphones"));
        Equal(TeamsPlaybackEndpointWarningKind.None, ignored.Kind);
    }

    public static void DoesNotWarnWhenAnyObservedTeamsEndpointMatches()
    {
        var warning = TeamsPlaybackEndpointMismatchPolicy.Evaluate(
            SystemRequest(renderEndpointId: "teams-headphones"),
            windowsConsoleDefaultRenderEndpointId: "windows-speakers",
            TeamsPlaybackEndpointObservation.Known(["teams-speakers", "teams-headphones"]));

        Equal(TeamsPlaybackEndpointWarningKind.None, warning.Kind);
    }

    private static RecordingStartRequest SystemRequest(string? renderEndpointId) => new(
        RecordingSessionKind.Manual,
        RecordingAudioSource.SystemLoopback,
        RenderEndpointId: renderEndpointId);

    private static void Equal<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new InvalidOperationException($"Expected {expected}; got {actual}.");
    }

    private static void Contains(string expected, string actual)
    {
        if (!actual.Contains(expected, StringComparison.Ordinal))
            throw new InvalidOperationException($"Expected '{expected}' to occur in '{actual}'.");
    }
}
