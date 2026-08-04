namespace TeamsRecorder.Windows.Application;

public sealed record TeamsTransportDiagnosticSnapshot(
    long Generation,
    bool IsRunning,
    bool IsConnected,
    bool PairingCredentialPresent,
    DateTimeOffset? ConnectedAtUtc,
    DateTimeOffset? LastReceiveUtc,
    DateTimeOffset? LastQuerySentUtc,
    DateTimeOffset? LastQueryReplyUtc,
    string? LastQueryOutcome,
    string? LastEventKind,
    bool? LastMeetingUpdateHadState,
    bool? LastMeetingUpdateHadIsInMeeting,
    bool? LastMeetingUpdateHadIsMuted,
    int ReconnectCount,
    string? LastConnectionError)
{
    public static TeamsTransportDiagnosticSnapshot Initial { get; } = new(
        0, false, false, false, null, null, null, null, null, null,
        null, null, null, 0, null);
}
