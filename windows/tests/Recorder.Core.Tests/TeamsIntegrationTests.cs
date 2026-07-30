using TeamsRecorder.Windows.Application;

internal static class TeamsIntegrationTests
{
    public static void ProtocolUsesLocalEndpointAndAbsoluteCommands()
    {
        var endpoint = TeamsThirdPartyApi.CreateEndpoint(TeamsThirdPartyApiIdentity.Recorder("1.2 test"), "token+/=");
        if (endpoint.Scheme != "ws" || endpoint.Host != "127.0.0.1" || endpoint.Port != 8124) throw new InvalidOperationException("Teams endpoint must remain local.");
        if (!endpoint.Query.Contains("token=token%2B%2F%3D", StringComparison.Ordinal)) throw new InvalidOperationException("Pairing token was not safely encoded.");
        var command = TeamsThirdPartyApi.CreateCommand(TeamsThirdPartyApiAction.QueryState, 7);
        if (command != "{\"action\":\"query-state\",\"parameters\":{},\"requestId\":7}") throw new InvalidOperationException($"Unexpected Teams command: {command}");
        if (command.Contains("mute", StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Mute synchronization must not issue a Teams mute command.");
    }

    public static void ProtocolDecodesCompleteMeetingStateOnly()
    {
        var parsed = TeamsThirdPartyApi.Decode("""{"meetingUpdate":{"meetingState":{"isInMeeting":true,"isMuted":false},"meetingPermissions":{"canToggleMute":true,"canPair":false}}}""");
        if (parsed is not TeamsThirdPartyApiEvent.MeetingUpdate { Update.State: { } state }) throw new InvalidOperationException("Expected a complete meeting state.");
        Equal(true, state.IsInMeeting); Equal(false, state.IsMuted); Equal(true, state.CanToggleMute);
        var incomplete = TeamsThirdPartyApi.Decode("""{"meetingUpdate":{"meetingState":{"isInMeeting":true},"meetingPermissions":{"canPair":true}}}""");
        if (incomplete is not TeamsThirdPartyApiEvent.MeetingUpdate { Update.State: null, Update.CanPair: true }) throw new InvalidOperationException("A partial Teams state must not be treated as authoritative.");
    }

    public static void MuteCoordinatorUsesAbsoluteStateAndFailsClosed()
    {
        var client = new FakeTeamsClient(); var microphone = new RecordingMuteSink();
        using var coordinator = new TeamsMuteSyncCoordinator(client, microphone);
        var presence = new List<bool>(); coordinator.MeetingPresenceChanged += (_, inMeeting) => presence.Add(inMeeting);
        coordinator.SetEnabledAsync(true).GetAwaiter().GetResult();
        client.Publish(new TeamsThirdPartyApiEvent.MeetingUpdate(new(new(true, false, true, false), true, false)));
        client.Publish(new TeamsThirdPartyApiEvent.MeetingUpdate(new(new(true, true, true, false), true, false)));
        client.Disconnect("Teams API unavailable");
        if (!microphone.Calls.SequenceEqual([false, true, true]) || !presence.SequenceEqual([true, true])) throw new InvalidOperationException("Mute or meeting updates were not absolute and ordered.");
        Equal(TeamsMuteSyncStatus.WaitingForTeamsApi, coordinator.Snapshot.Status); Equal("Teams API unavailable", coordinator.Snapshot.Detail!);
    }

    public static void MuteCoordinatorDoesNotChangeMicForOutOfMeetingState()
    {
        var client = new FakeTeamsClient(); var microphone = new RecordingMuteSink();
        using var coordinator = new TeamsMuteSyncCoordinator(client, microphone);
        coordinator.SetEnabledAsync(true).GetAwaiter().GetResult();
        client.Publish(new TeamsThirdPartyApiEvent.MeetingUpdate(new(new(false, true, true, false), true, false)));
        Equal(0, microphone.Calls.Count); Equal(TeamsMuteSyncStatus.Ready, coordinator.Snapshot.Status);
    }

    public static void MuteCoordinatorOnlyReportsPairingAfterEnabledClientAcceptsIt()
    {
        var client = new FakeTeamsClient(); var microphone = new RecordingMuteSink();
        using var coordinator = new TeamsMuteSyncCoordinator(client, microphone);
        Throws<InvalidOperationException>(() => coordinator.RequestPairingAsync().GetAwaiter().GetResult());
        Equal(0, client.PairingRequests);
        Equal(TeamsMuteSyncStatus.Disabled, coordinator.Snapshot.Status);

        coordinator.SetEnabledAsync(true).GetAwaiter().GetResult();
        coordinator.RequestPairingAsync().GetAwaiter().GetResult();
        Equal(1, client.PairingRequests);
        Equal(TeamsMuteSyncStatus.WaitingForPairingApproval, coordinator.Snapshot.Status);
    }

    private static void Equal<T>(T expected, T actual) where T : notnull { if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new InvalidOperationException($"Expected {expected}; got {actual}."); }
    private sealed class FakeTeamsClient : ITeamsThirdPartyApiClient
    {
        public event EventHandler<TeamsThirdPartyApiEvent>? EventReceived;
        public event EventHandler<string?>? ConnectionChanged;
        public Task StartAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public Task StopAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public int PairingRequests { get; private set; }
        public Task RequestPairingAsync(CancellationToken cancellationToken = default) { PairingRequests++; return Task.CompletedTask; }
        public void Publish(TeamsThirdPartyApiEvent value) => EventReceived?.Invoke(this, value);
        public void Disconnect(string detail) => ConnectionChanged?.Invoke(this, detail);
    }
    private sealed class RecordingMuteSink : IRecorderMicrophoneMuteSink { public List<bool> Calls { get; } = []; public void SetMuted(bool muted) => Calls.Add(muted); }
    private static void Throws<TException>(Action action) where TException : Exception
    {
        try { action(); }
        catch (TException) { return; }
        throw new InvalidOperationException($"Expected {typeof(TException).Name}.");
    }
}
