using TeamsRecorder.Windows.Application;

internal static class TeamsMuteFollowTests
{
    public static void ExactTeamsActionNamesMapToRecorderMute()
    {
        var unmuted = TeamsMuteFollowInterpreter.Interpret(["Mute mic"]);
        var muted = TeamsMuteFollowInterpreter.Interpret(["Unmute mic"]);
        if (unmuted.State != TeamsMuteFollowState.Unmuted || unmuted.ShouldMuteRecorder ||
            muted.State != TeamsMuteFollowState.Muted || !muted.ShouldMuteRecorder)
            throw new InvalidOperationException("Verified Teams action names were interpreted incorrectly.");
    }

    public static void MissingControlMeansNotInCallButAmbiguityFailsClosed()
    {
        var absent = TeamsMuteFollowInterpreter.Interpret([]);
        var ambiguous = TeamsMuteFollowInterpreter.Interpret(["Mute mic", "Mute mic"]);
        var unsupported = TeamsMuteFollowInterpreter.Interpret(["localized or changed label"]);
        if (absent.State != TeamsMuteFollowState.NotInCall || absent.ShouldMuteRecorder ||
            ambiguous.State != TeamsMuteFollowState.Unavailable || !ambiguous.ShouldMuteRecorder ||
            unsupported.State != TeamsMuteFollowState.Unavailable || !unsupported.ShouldMuteRecorder)
            throw new InvalidOperationException("Teams mute following did not apply its strict no-guess policy.");
    }
}
