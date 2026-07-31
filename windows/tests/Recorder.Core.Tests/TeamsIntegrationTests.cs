using TeamsRecorder.Windows.Application;

internal static class TeamsIntegrationTests
{
    public static void ProtocolUsesLocalEndpointAndPairingOnly()
    {
        var endpoint = TeamsThirdPartyApi.CreateEndpoint(TeamsThirdPartyApiIdentity.Recorder("1.2 test"), "token+/=");
        if (endpoint.Scheme != "ws" || endpoint.Host != "127.0.0.1" || endpoint.Port != 8124) throw new InvalidOperationException("Teams endpoint must remain local.");
        if (!endpoint.Query.Contains("token=token%2B%2F%3D", StringComparison.Ordinal)) throw new InvalidOperationException("Pairing token was not safely encoded.");
        var command = TeamsThirdPartyApi.CreateCommand(TeamsThirdPartyApiAction.Pair, 7);
        if (command != "{\"action\":\"pair\",\"parameters\":{},\"requestId\":7}") throw new InvalidOperationException($"Unexpected Teams command: {command}");
        var stateQuery = TeamsThirdPartyApi.CreateCommand(TeamsThirdPartyApiAction.QueryState, 8);
        if (stateQuery != "{\"action\":\"query-state\",\"parameters\":{},\"requestId\":8}") throw new InvalidOperationException($"Unexpected Teams state query: {stateQuery}");
        if (command.Contains("mute", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Teams integration must not issue a Teams mute command.");
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
        client.Publish(new TeamsThirdPartyApiEvent.MeetingUpdate(new(new(true, false, true, false), true, false), true));
        client.Publish(new TeamsThirdPartyApiEvent.MeetingUpdate(new(new(true, true, true, false), true, false), true));
        client.Publish(new TeamsThirdPartyApiEvent.MeetingUpdate(new(new(true, false, true, false), true, false), true));
        client.Disconnect("Teams API unavailable");
        if (!microphone.Calls.SequenceEqual([true, false, true]) || !presence.SequenceEqual([true, true, true, false])) throw new InvalidOperationException("Mute routing or meeting updates were not ordered and fail-closed.");
        Equal(TeamsMuteSyncStatus.WaitingForTeamsApi, coordinator.Snapshot.Status); Equal("Teams API unavailable", coordinator.Snapshot.Detail!);
        Equal(false, coordinator.Snapshot.IsPairingAuthenticated);
        if (coordinator.Snapshot.LastMeetingState is not null) throw new InvalidOperationException("A disconnected meeting state must not remain trusted.");
    }

    public static void MuteCoordinatorDoesNotChangeMicForOutOfMeetingState()
    {
        var client = new FakeTeamsClient(); var microphone = new RecordingMuteSink();
        using var coordinator = new TeamsMuteSyncCoordinator(client, microphone);
        coordinator.SetEnabledAsync(true).GetAwaiter().GetResult();
        client.Publish(new TeamsThirdPartyApiEvent.MeetingUpdate(new(new(false, true, true, false), true, false), true));
        Equal(0, microphone.Calls.Count); Equal(TeamsMuteSyncStatus.Ready, coordinator.Snapshot.Status);
    }

    public static void MuteCoordinatorRejectsUnauthenticatedMeetingState()
    {
        var client = new FakeTeamsClient(); var microphone = new RecordingMuteSink();
        using var coordinator = new TeamsMuteSyncCoordinator(client, microphone);
        var presence = new List<bool>(); coordinator.MeetingPresenceChanged += (_, inMeeting) => presence.Add(inMeeting);
        coordinator.SetEnabledAsync(true).GetAwaiter().GetResult();

        client.Publish(new TeamsThirdPartyApiEvent.MeetingUpdate(new(new(true, false, true, true), true, true)));

        Equal(0, microphone.Calls.Count);
        Equal(0, presence.Count);
        Equal(TeamsMuteSyncStatus.WaitingForPairingApproval, coordinator.Snapshot.Status);
        Equal(false, coordinator.Snapshot.IsPairingAuthenticated);
        if (coordinator.Snapshot.LastMeetingState is not null) throw new InvalidOperationException("Unauthenticated meeting state must not be retained.");
    }

    public static void MuteCoordinatorKeepsIssuedCredentialWhenTeamsOffersPairing()
    {
        var client = new FakeTeamsClient(); var microphone = new RecordingMuteSink();
        using var coordinator = new TeamsMuteSyncCoordinator(client, microphone);
        coordinator.SetEnabledAsync(true).GetAwaiter().GetResult();

        // The current macOS implementation keeps a Teams-issued credential authoritative even
        // when Teams also advertises canPair. This preserves existing auto-recording users.
        client.Publish(new TeamsThirdPartyApiEvent.MeetingUpdate(new(new(true, false, true, true), true, true), true));

        Equal(TeamsMuteSyncStatus.InMeeting, coordinator.Snapshot.Status);
        Equal(true, coordinator.Snapshot.IsPairingAuthenticated);
        Equal(true, coordinator.Snapshot.IsPairingKnown);
        if (coordinator.Snapshot.LastMeetingState is null) throw new InvalidOperationException("An issued credential must retain the meeting state.");
    }

    public static void MuteCoordinatorFailsClosedOnApiError()
    {
        var client = new FakeTeamsClient(); var microphone = new RecordingMuteSink();
        using var coordinator = new TeamsMuteSyncCoordinator(client, microphone);
        coordinator.SetEnabledAsync(true).GetAwaiter().GetResult();
        client.Publish(new TeamsThirdPartyApiEvent.MeetingUpdate(new(new(true, true, true, false), true, false), true));
        client.Publish(new TeamsThirdPartyApiEvent.Error(null, "Teams API request failed"));

        if (!microphone.Calls.SequenceEqual([true, true])) throw new InvalidOperationException("An API error after Teams routed a mute must fail closed.");
        Equal(TeamsMuteSyncStatus.Failed, coordinator.Snapshot.Status);
        Equal(false, coordinator.Snapshot.IsPairingAuthenticated);
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

    public static void MuteCoordinatorOnlyTreatsAlreadyPairedAsAReplyToAnExplicitPairCommand()
    {
        var client = new FakeTeamsClient(); var microphone = new RecordingMuteSink();
        using var coordinator = new TeamsMuteSyncCoordinator(client, microphone);
        coordinator.SetEnabledAsync(true).GetAwaiter().GetResult();
        client.Publish(new TeamsThirdPartyApiEvent.MeetingUpdate(new(new(false, false, true, false), true, false), true));
        client.Publish(new TeamsThirdPartyApiEvent.Error(99, "Device already paired"));

        Equal(TeamsMuteSyncStatus.Ready, coordinator.Snapshot.Status);
        Equal(true, coordinator.Snapshot.IsPairingAuthenticated);
        Equal(true, coordinator.Snapshot.IsPairingKnown);
        if (coordinator.Snapshot.LastMeetingState is null)
        {
            throw new InvalidOperationException("An unrelated already-paired response must not discard trusted meeting state.");
        }

        var waitingClient = new FakeTeamsClient(); var waitingMicrophone = new RecordingMuteSink();
        using var waiting = new TeamsMuteSyncCoordinator(waitingClient, waitingMicrophone);
        waiting.SetEnabledAsync(true).GetAwaiter().GetResult();
        waitingClient.Publish(new TeamsThirdPartyApiEvent.Error(99, "Device already paired"));
        Equal(TeamsMuteSyncStatus.WaitingForTeamsApi, waiting.Snapshot.Status);
        Equal(false, waiting.Snapshot.IsPairingKnown);
        Equal(false, waiting.Snapshot.IsPairingAuthenticated);

        waiting.RequestPairingAsync().GetAwaiter().GetResult();
        waitingClient.Publish(new TeamsThirdPartyApiEvent.Error(null, "Device already paired"));
        Equal(TeamsMuteSyncStatus.Failed, waiting.Snapshot.Status);
        Equal(false, waiting.Snapshot.IsPairingKnown);
        if (!waiting.Snapshot.Detail!.Contains("Manage API", StringComparison.Ordinal))
            throw new InvalidOperationException("An explicit pairing conflict must explain how to reset the Teams pairing.");
    }

    private static void Equal<T>(T expected, T actual) where T : notnull { if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new InvalidOperationException($"Expected {expected}; got {actual}."); }
    private sealed class FakeTeamsClient : ITeamsThirdPartyApiClient
    {
        public event EventHandler<TeamsThirdPartyApiEvent>? EventReceived;
        public event EventHandler<string?>? ConnectionChanged;
        public Task StartAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public Task StopAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public int PairingRequests { get; private set; }
        public Task RequestPairingAsync(CancellationToken cancellationToken = default)
        {
            PairingRequests++;
            return Task.CompletedTask;
        }
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
