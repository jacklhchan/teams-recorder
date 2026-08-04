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
    bool? LastMeetingUpdateCanPair,
    bool? LastMeetingUpdateCanToggleMute,
    DateTimeOffset? LastAuthoritativeMeetingStateUtc,
    int StateLessMeetingUpdateCount,
    int ReconnectCount,
    string? LastConnectionError)
{
    /// <summary>
    /// A local, bounded interpretation of transport evidence.  A WebSocket and a stored
    /// credential alone do not prove that this Teams build is providing meeting state.
    /// </summary>
    public TeamsTransportHealthAssessment Health => TeamsTransportHealthAdvisor.Assess(this, DateTimeOffset.UtcNow);

    public static TeamsTransportDiagnosticSnapshot Initial { get; } = new(
        0, false, false, false, null, null, null, null, null, null,
        null, null, null, null, null, null, 0, 0, null);
}
