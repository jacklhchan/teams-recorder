using TeamsRecorder.Windows.Application;

internal static class TeamsTransportHealthAdvisorTests
{
    public static void DoesNotTreatCredentialAndAcknowledgementAsMeetingStateHealth()
    {
        var connectedAt = new DateTimeOffset(2026, 8, 4, 10, 0, 0, TimeSpan.Zero);
        var snapshot = TeamsTransportDiagnosticSnapshot.Initial with
        {
            Generation = 7,
            IsRunning = true,
            IsConnected = true,
            PairingCredentialPresent = true,
            ConnectedAtUtc = connectedAt,
            LastQueryReplyUtc = connectedAt + TimeSpan.FromSeconds(3),
            LastQueryOutcome = "acknowledged",
            LastMeetingUpdateHadState = false,
            LastMeetingUpdateHadIsInMeeting = false,
            StateLessMeetingUpdateCount = 4,
        };

        var duringGrace = TeamsTransportHealthAdvisor.Assess(snapshot, connectedAt + TimeSpan.FromSeconds(14));
        Equal(TeamsTransportHealth.Unknown, duringGrace.Status);

        var afterGrace = TeamsTransportHealthAdvisor.Assess(snapshot, connectedAt + TimeSpan.FromSeconds(15));
        Equal(TeamsTransportHealth.Degraded, afterGrace.Status);
        if (afterGrace.IsTrustedForAutomaticRecording)
            throw new InvalidOperationException("An acknowledged state query without meetingState must not be healthy.");
    }

    public static void KeepsCompleteStateHealthyForItsConnectionGenerationAndHandlesDisconnects()
    {
        var connectedAt = new DateTimeOffset(2026, 8, 4, 10, 0, 0, TimeSpan.Zero);
        var healthy = TeamsTransportDiagnosticSnapshot.Initial with
        {
            IsRunning = true,
            IsConnected = true,
            PairingCredentialPresent = true,
            ConnectedAtUtc = connectedAt,
            LastAuthoritativeMeetingStateUtc = connectedAt + TimeSpan.FromSeconds(5),
        };
        Equal(TeamsTransportHealth.Healthy, TeamsTransportHealthAdvisor.Assess(healthy, connectedAt + TimeSpan.FromSeconds(25)).Status);
        Equal(TeamsTransportHealth.Healthy, TeamsTransportHealthAdvisor.Assess(healthy, connectedAt + TimeSpan.FromHours(2)).Status);
        Equal(TeamsTransportHealth.Unavailable, TeamsTransportHealthAdvisor.Assess(healthy with { IsConnected = false }, connectedAt + TimeSpan.FromSeconds(6)).Status);
        Equal(TeamsTransportHealth.PairingRequired, TeamsTransportHealthAdvisor.Assess(healthy with { PairingCredentialPresent = false }, connectedAt + TimeSpan.FromSeconds(6)).Status);
    }

    private static void Equal<T>(T expected, T actual) where T : notnull
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new InvalidOperationException($"Expected {expected}; got {actual}.");
    }
}
