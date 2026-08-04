using System.Net.WebSockets;
using System.Text;
using TeamsRecorder.Windows.Application;

internal static class TeamsTransportTests
{
    public static void ClientReconnectsAfterTokenRefreshBeforeTrustingPushes()
    {
        var socket = new FakeSocket(); var authenticatedSocket = new FakeSocket();
        var sockets = new Queue<FakeSocket>([socket, authenticatedSocket]);
        var store = new FakeTokenStore();
        var client = new TeamsThirdPartyApiClient(
            TeamsThirdPartyApiIdentity.Recorder("test"),
            store,
            () => sockets.Dequeue(),
            TimeSpan.Zero);
        var events = 0; client.EventReceived += (_, _) => Interlocked.Increment(ref events);
        var connectionErrors = new List<string?>();
        client.ConnectionChanged += (_, error) =>
        {
            if (error is not null)
            {
                lock (connectionErrors) connectionErrors.Add(error);
            }
        };
        client.StartAsync().GetAwaiter().GetResult();
        Wait(socket.Connected.Task, "The pairing socket did not connect.");
        Wait(socket.ReceiveEntered.Task, "The pairing socket did not begin receiving.");
        Equal(0, socket.Sent.Count);
        socket.Publish("""{"tokenRefresh":"stored-only-in-fake"}""");
        WaitUntil(() => store.Token == "stored-only-in-fake", "The refreshed token was not saved.");
        Wait(authenticatedSocket.Connected.Task, "The token refresh did not reconnect.");
        Wait(authenticatedSocket.ReceiveEntered.Task, "The authenticated socket did not begin receiving.");
        if (!authenticatedSocket.Endpoint!.Query.Contains("token=stored-only-in-fake", StringComparison.Ordinal))
            throw new InvalidOperationException("The replacement socket did not use the refreshed token.");
        lock (connectionErrors)
        {
            if (connectionErrors.Count != 0)
                throw new InvalidOperationException("A token refresh must not be reported as a Teams API disconnect.");
        }
        authenticatedSocket.Publish("""{"meetingUpdate":{"meetingState":{"isInMeeting":true,"isMuted":false},"meetingPermissions":{"canToggleMute":true,"canPair":true}}}""");
        WaitUntil(() => Volatile.Read(ref events) == 1, "The WebSocket event was not delivered.");
        Equal("stored-only-in-fake", store.Token!);
        client.RequestPairingAsync().GetAwaiter().GetResult();
        WaitUntil(() => authenticatedSocket.Sent.Count == 1, "The pairing command was not sent.");
        AssertAction(authenticatedSocket.Sent[0], "pair");
        client.StopAsync().GetAwaiter().GetResult(); client.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    public static void ClientCorrelatesOverlappingStateQueryReplies()
    {
        var socket = new FakeSocket();
        var store = new FakeTokenStore { Token = "paired-token" };
        var client = new TeamsThirdPartyApiClient(
            TeamsThirdPartyApiIdentity.Recorder("test"),
            store,
            () => socket,
            TimeSpan.FromHours(1));
        var events = 0;
        var connectionErrors = 0;
        client.EventReceived += (_, _) => Interlocked.Increment(ref events);
        client.ConnectionChanged += (_, error) =>
        {
            if (error is not null) Interlocked.Increment(ref connectionErrors);
        };

        client.StartAsync().GetAwaiter().GetResult();
        Wait(socket.Connected.Task, "The overlapping-query socket did not connect.");
        Wait(socket.ReceiveEntered.Task, "The overlapping-query socket did not begin receiving.");
        Equal(0, socket.Sent.Count);
        client.RefreshStateAsync().GetAwaiter().GetResult();
        client.RefreshStateAsync().GetAwaiter().GetResult();
        Equal(1, socket.Sent.Count);
        socket.Publish("""{"requestId":1,"errorMsg":"First query completed late"}""");
        Thread.Sleep(50);
        Equal(0, Volatile.Read(ref events));
        Equal(0, Volatile.Read(ref connectionErrors));

        socket.Publish("""{"meetingUpdate":{"meetingState":{"isInMeeting":true,"isMuted":false},"meetingPermissions":{"canToggleMute":true}}}""");
        WaitUntil(() => Volatile.Read(ref events) == 1,
            "A delayed state-query reply escaped correlation and blocked a later meeting push.");
        client.StopAsync().GetAwaiter().GetResult();
        client.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    public static void ClientDropsLateEventsAfterStop()
    {
        var socket = new FakeSocket(); var client = new TeamsThirdPartyApiClient(TeamsThirdPartyApiIdentity.Recorder("test"), new FakeTokenStore(), () => socket, TimeSpan.FromHours(1));
        var events = 0; client.EventReceived += (_, _) => Interlocked.Increment(ref events);
        client.StartAsync().GetAwaiter().GetResult(); Wait(socket.Connected.Task, "The fake socket did not connect.");
        Wait(socket.ReceiveEntered.Task, "The fake socket did not begin receiving.");
        client.StopAsync().GetAwaiter().GetResult();
        socket.Publish("""{"meetingUpdate":{"meetingState":{"isInMeeting":true,"isMuted":true}}}""");
        Thread.Sleep(50);
        Equal(0, events);
        client.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    public static void ClientDeliversAuthenticatedPushUpdates()
    {
        var socket = new FakeSocket();
        var client = new TeamsThirdPartyApiClient(
            TeamsThirdPartyApiIdentity.Recorder("test"),
            new FakeTokenStore { Token = "paired-token" },
            () => socket,
            TimeSpan.FromHours(1));
        var states = new List<TeamsMeetingState>();
        client.EventReceived += (_, value) =>
        {
            if (value is TeamsThirdPartyApiEvent.MeetingUpdate { Update.State: { } state, IsPairingAuthenticated: true })
            {
                lock (states) states.Add(state);
            }
        };

        client.StartAsync().GetAwaiter().GetResult();
        Wait(socket.Connected.Task, "The push socket did not connect.");
        Wait(socket.ReceiveEntered.Task, "The push socket did not begin receiving.");
        Equal(0, socket.Sent.Count);

        socket.Publish("""{"meetingUpdate":{"meetingState":{"isInMeeting":true,"isMuted":false},"meetingPermissions":{"canToggleMute":true}}}""");
        WaitUntil(() => { lock (states) return states.Count == 1; }, "The initial authenticated state was not delivered.");

        socket.Publish("""{"meetingUpdate":{"meetingState":{"isInMeeting":true,"isMuted":true},"meetingPermissions":{"canToggleMute":true}}}""");
        WaitUntil(() => { lock (states) return states.Count == 2; }, "The second pushed state was not delivered.");
        bool secondStateMuted;
        lock (states) secondStateMuted = states[1].IsMuted;
        Equal(true, secondStateMuted);

        client.StopAsync().GetAwaiter().GetResult();
        Wait(socket.Closed.Task, "Stopping the client did not close the push socket.");
        Equal(0, socket.Sent.Count);
        client.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    public static void StateQueryFailureDoesNotBlockLaterMeetingPush()
    {
        var socket = new FakeSocket();
        var client = new TeamsThirdPartyApiClient(
            TeamsThirdPartyApiIdentity.Recorder("test"),
            new FakeTokenStore { Token = "paired-token" },
            () => socket,
            TimeSpan.FromHours(1));
        var states = new List<TeamsMeetingState>();
        client.EventReceived += (_, @event) =>
        {
            if (@event is TeamsThirdPartyApiEvent.MeetingUpdate { Update.State: { } state })
            {
                lock (states) states.Add(state);
            }
        };

        client.StartAsync().GetAwaiter().GetResult();
        Wait(socket.Connected.Task, "The query-failure socket did not connect.");
        Wait(socket.ReceiveEntered.Task, "The client must start receiving before a manual state query is sent.");
        client.RefreshStateAsync().GetAwaiter().GetResult();
        WaitUntil(() => socket.Sent.Count == 1, "The manual state query was not sent.");
        socket.Publish("""{"requestId":1,"errorMsg":"Device already paired"}""");
        socket.Publish("""{"meetingUpdate":{"meetingState":{"isInMeeting":true,"isMuted":false},"meetingPermissions":{"canToggleMute":true}}}""");

        WaitUntil(() => { lock (states) return states.Count == 1; }, "A state-query failure blocked the later Teams meeting push.");
        Equal(true, states[0].IsInMeeting);
        client.StopAsync().GetAwaiter().GetResult(); client.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    public static void ClientDoesNotOverlapStateQueries()
    {
        var socket = new FakeSocket();
        var client = new TeamsThirdPartyApiClient(
            TeamsThirdPartyApiIdentity.Recorder("test"),
            new FakeTokenStore { Token = "paired-token" },
            () => socket,
            TimeSpan.FromHours(1));

        client.StartAsync().GetAwaiter().GetResult();
        Wait(socket.Connected.Task, "The overlap-test socket did not connect.");
        Wait(socket.ReceiveEntered.Task, "The overlap-test receive loop did not start.");
        client.RefreshStateAsync().GetAwaiter().GetResult();
        client.RefreshStateAsync().GetAwaiter().GetResult();
        Equal(1, socket.Sent.Count);

        socket.Publish("""{"requestId":1,"response":"ok"}""");
        WaitUntil(() => client.TransportSnapshot.LastQueryOutcome == "acknowledged", "The first query reply was not observed.");
        client.RefreshStateAsync().GetAwaiter().GetResult();
        WaitUntil(() => socket.Sent.Count == 2, "A later query was not allowed after the reply.");

        client.StopAsync().GetAwaiter().GetResult();
        client.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    public static void ClientResetPairingClearsCredentialReconnectsAndRequestsFreshPairing()
    {
        var firstSocket = new FakeSocket(); var repairedSocket = new FakeSocket();
        var sockets = new Queue<FakeSocket>([firstSocket, repairedSocket]);
        var store = new FakeTokenStore { Token = "old-paired-token" };
        var client = new TeamsThirdPartyApiClient(
            TeamsThirdPartyApiIdentity.Recorder("test"),
            store,
            () => sockets.Dequeue(),
            TimeSpan.FromHours(1));

        client.StartAsync().GetAwaiter().GetResult();
        Wait(firstSocket.ReceiveEntered.Task, "The initial pairing socket did not begin receiving.");
        client.RefreshStateAsync().GetAwaiter().GetResult();
        firstSocket.Publish("""{"requestId":1,"response":"ok"}""");
        WaitUntil(() => client.TransportSnapshot.LastQueryOutcome == "acknowledged",
            "The pre-repair diagnostic query did not complete.");
        client.ResetPairingAsync().GetAwaiter().GetResult();

        Wait(firstSocket.Closed.Task, "Pairing repair did not stop the old socket.");
        Wait(repairedSocket.Connected.Task, "Pairing repair did not start a fresh socket.");
        Wait(repairedSocket.ReceiveEntered.Task, "The repaired socket did not begin receiving.");
        Equal(1, store.ClearCalls);
        if (client.TransportSnapshot.LastQuerySentUtc is not null ||
            client.TransportSnapshot.LastQueryReplyUtc is not null ||
            client.TransportSnapshot.LastQueryOutcome is not null)
            throw new InvalidOperationException("Pairing repair retained query evidence from the previous connection generation.");
        if (repairedSocket.Endpoint!.Query.Contains("token=", StringComparison.Ordinal))
            throw new InvalidOperationException("Pairing repair reconnected using the removed credential.");

        repairedSocket.Publish("""{"meetingUpdate":{"meetingPermissions":{"canPair":true}}}""");
        WaitUntil(() => repairedSocket.Sent.Any(message => message.Contains("\"action\":\"pair\"", StringComparison.Ordinal)),
            "The repaired unauthenticated connection did not request fresh Teams pairing.");
        client.StopAsync().GetAwaiter().GetResult(); client.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    public static void ClientResetPairingRestartsWhenCredentialClearFails()
    {
        var firstSocket = new FakeSocket(); var replacementSocket = new FakeSocket();
        var sockets = new Queue<FakeSocket>([firstSocket, replacementSocket]);
        var store = new FakeTokenStore { Token = "old-paired-token", ClearError = new IOException("simulated clear failure") };
        var client = new TeamsThirdPartyApiClient(
            TeamsThirdPartyApiIdentity.Recorder("test"), store, () => sockets.Dequeue(), TimeSpan.FromHours(1));
        client.StartAsync().GetAwaiter().GetResult();
        Wait(firstSocket.ReceiveEntered.Task, "The initial socket did not begin receiving.");
        try { client.ResetPairingAsync().GetAwaiter().GetResult(); }
        catch (IOException) { }
        Wait(replacementSocket.Connected.Task, "A failed credential clear left Teams integration offline.");
        if (!replacementSocket.Endpoint!.Query.Contains("token=old-paired-token", StringComparison.Ordinal))
            throw new InvalidOperationException("A failed credential clear must retain the original local credential.");
        client.StopAsync().GetAwaiter().GetResult(); client.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    public static void TransportDiagnosticsExposePermissionsWithoutPayloads()
    {
        var socket = new FakeSocket(); var authenticatedSocket = new FakeSocket();
        var sockets = new Queue<FakeSocket>([socket, authenticatedSocket]);
        var client = new TeamsThirdPartyApiClient(
            TeamsThirdPartyApiIdentity.Recorder("test"),
            new FakeTokenStore { Token = "paired-token" },
            () => sockets.Dequeue(),
            TimeSpan.FromHours(1));
        client.StartAsync().GetAwaiter().GetResult();
        Wait(socket.ReceiveEntered.Task, "The diagnostic socket did not begin receiving.");
        socket.Publish("""{"meetingUpdate":{"meetingPermissions":{"canPair":true,"canToggleMute":false}}}""");
        WaitUntil(() => client.TransportSnapshot.LastMeetingUpdateCanPair == true, "The permission shape was not diagnosed.");
        Equal(false, client.TransportSnapshot.LastMeetingUpdateCanToggleMute!.Value);
        Equal(false, client.TransportSnapshot.LastMeetingUpdateHadState!.Value);
        Equal(1, client.TransportSnapshot.StateLessMeetingUpdateCount);
        if (client.TransportSnapshot.LastAuthoritativeMeetingStateUtc is not null)
            throw new InvalidOperationException("A permission-only update must not become an authoritative meeting state.");
        client.StopAsync().GetAwaiter().GetResult();
        client.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    public static void ClientFailsClosedWhenRemoteSocketClosesDuringMeeting()
    {
        var socket = new FakeSocket();
        var client = new TeamsThirdPartyApiClient(
            TeamsThirdPartyApiIdentity.Recorder("test"),
            new FakeTokenStore { Token = "paired-token" },
            () => socket,
            TimeSpan.FromHours(1));
        var microphone = new RecordingMuteSink();
        using var coordinator = new TeamsMuteSyncCoordinator(client, microphone);

        coordinator.SetEnabledAsync(true).GetAwaiter().GetResult();
        Wait(socket.Connected.Task, "The close-test socket did not connect.");
        Wait(socket.ReceiveEntered.Task, "The close-test socket did not begin receiving.");
        Equal(0, socket.Sent.Count);
        socket.Publish("""{"meetingUpdate":{"meetingState":{"isInMeeting":true,"isMuted":true},"meetingPermissions":{"canToggleMute":true}}}""");
        WaitUntil(() => coordinator.Snapshot.Status == TeamsMuteSyncStatus.InMeeting, "The authenticated meeting state was not applied.");
        socket.PublishClose();

        WaitUntil(() => coordinator.Snapshot.Status == TeamsMuteSyncStatus.WaitingForTeamsApi, "A remote close did not clear trusted meeting state.");
        if (!microphone.Calls.SequenceEqual([true, true])) throw new InvalidOperationException("A remote close during a routed mute must fail closed.");
        Equal(false, coordinator.Snapshot.IsPairingAuthenticated);
        if (coordinator.Snapshot.LastMeetingState is not null) throw new InvalidOperationException("A closed socket must not retain a trusted meeting state.");

        coordinator.SetEnabledAsync(false).GetAwaiter().GetResult();
        client.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    public static void ClientClosesAndReconnectsAfterOversizedFragmentedPayload()
    {
        var oversizedSocket = new FakeSocket(); var replacementSocket = new FakeSocket();
        var sockets = new Queue<FakeSocket>([oversizedSocket, replacementSocket]);
        var client = new TeamsThirdPartyApiClient(
            TeamsThirdPartyApiIdentity.Recorder("test"),
            new FakeTokenStore(),
            () => sockets.Dequeue(),
            TimeSpan.Zero);
        var events = 0; client.EventReceived += (_, _) => Interlocked.Increment(ref events);

        client.StartAsync().GetAwaiter().GetResult();
        Wait(oversizedSocket.Connected.Task, "The initial fake socket did not connect.");
        Wait(oversizedSocket.ReceiveEntered.Task, "The initial fake socket did not begin receiving.");
        var otherwiseValidEvent = """{"meetingUpdate":{"meetingState":{"isInMeeting":true,"isMuted":false}}}""";
        oversizedSocket.PublishFragments(otherwiseValidEvent + new string(' ', 64 * 1024), 8192);

        Wait(oversizedSocket.Closed.Task, "The oversized fragmented payload did not close the socket.");
        Wait(replacementSocket.Connected.Task, "The client did not reconnect after rejecting an oversized payload.");
        Equal(0, events);
        client.StopAsync().GetAwaiter().GetResult(); client.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    public static void ClientClearsAnInvalidPairingTokenBeforeReconnecting()
    {
        var rejectedSocket = new FakeSocket(); var replacementSocket = new FakeSocket();
        var sockets = new Queue<FakeSocket>([rejectedSocket, replacementSocket]);
        var store = new FakeTokenStore { Token = "expired-token" };
        var client = new TeamsThirdPartyApiClient(
            TeamsThirdPartyApiIdentity.Recorder("test"), store, () => sockets.Dequeue(), TimeSpan.Zero);

        client.StartAsync().GetAwaiter().GetResult();
        Wait(rejectedSocket.Connected.Task, "The initial fake socket did not connect.");
        Wait(rejectedSocket.ReceiveEntered.Task, "The initial fake socket did not begin receiving.");
        client.RefreshStateAsync().GetAwaiter().GetResult();
        WaitUntil(() => rejectedSocket.Sent.Count == 1, "The manual query was not sent before the invalid-token reply.");
        rejectedSocket.Publish("""{"requestId":1,"errorMsg":"Invalid token"}""");

        WaitUntil(() => store.ClearCalls == 1, "The invalid pairing token was not cleared.");
        Wait(replacementSocket.Connected.Task, "The client did not reconnect after clearing the invalid token.");
        if (replacementSocket.Endpoint?.Query.Contains("token=", StringComparison.Ordinal) == true)
            throw new InvalidOperationException("The replacement connection reused an invalid pairing token.");
        client.StopAsync().GetAwaiter().GetResult(); client.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    public static void ClientRequestsPairingOnceForAnUncredentialedConnection()
    {
        var socket = new FakeSocket();
        var store = new FakeTokenStore();
        var client = new TeamsThirdPartyApiClient(
            TeamsThirdPartyApiIdentity.Recorder("test"), store, () => socket, TimeSpan.Zero);
        var pairingOffers = 0;
        client.EventReceived += (_, @event) =>
        {
            if (@event is TeamsThirdPartyApiEvent.MeetingUpdate { Update.CanPair: true, IsPairingAuthenticated: false })
                Interlocked.Increment(ref pairingOffers);
        };

        client.StartAsync().GetAwaiter().GetResult();
        Wait(socket.Connected.Task, "The uncredentialed socket did not connect.");
        Wait(socket.ReceiveEntered.Task, "The uncredentialed socket did not begin receiving.");
        if (socket.Endpoint?.Query.Contains("token=", StringComparison.Ordinal) == true)
            throw new InvalidOperationException("The initial pairing socket must not include a token.");
        socket.Publish("""{"meetingUpdate":{"meetingPermissions":{"canPair":true}}}""");
        WaitUntil(() => Volatile.Read(ref pairingOffers) == 1, "The unauthenticated fresh pairing offer was not delivered.");
        WaitUntil(() => socket.Sent.Count == 1, "The pairing command was not sent for the fresh connection.");
        AssertAction(socket.Sent[0], "pair");
        socket.Publish("""{"meetingUpdate":{"meetingPermissions":{"canPair":true}}}""");
        Thread.Sleep(50);
        Equal(1, socket.Sent.Count);
        client.StopAsync().GetAwaiter().GetResult(); client.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    private static void Wait(Task task, string message) { if (!task.Wait(TimeSpan.FromSeconds(2))) throw new InvalidOperationException(message); }
    private static void WaitUntil(Func<bool> condition, string message)
    {
        var until = DateTime.UtcNow.AddSeconds(2);
        while (!condition() && DateTime.UtcNow < until) Thread.Sleep(10);
        if (!condition()) throw new InvalidOperationException(message);
    }
    private static void Equal<T>(T expected, T actual) where T : notnull { if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new InvalidOperationException($"Expected {expected}; got {actual}."); }
    private static void AssertAction(string command, string action)
    {
        if (!command.Contains($"\"action\":\"{action}\"", StringComparison.Ordinal))
            throw new InvalidOperationException($"Expected Teams action '{action}', received: {command}");
    }

    private sealed class FakeTokenStore : ITeamsPairingTokenStore
    {
        public string? Token { get; set; }
        public int ClearCalls { get; private set; }
        public Exception? ClearError { get; set; }
        public Task<string?> ReadAsync(CancellationToken cancellationToken = default) => Task.FromResult(Token);
        public Task WriteAsync(string token, CancellationToken cancellationToken = default) { Token = token; return Task.CompletedTask; }
        public Task ClearAsync(CancellationToken cancellationToken = default)
        {
            ClearCalls++;
            if (ClearError is { } error) return Task.FromException(error);
            Token = null;
            return Task.CompletedTask;
        }
    }

    private sealed class RecordingMuteSink : IRecorderMicrophoneMuteSink
    {
        public List<bool> Calls { get; } = [];
        public void SetMuted(bool muted) => Calls.Add(muted);
    }

    private sealed class FakeSocket : ITeamsWebSocketConnection
    {
        private readonly Queue<(byte[] Bytes, bool EndOfMessage, WebSocketMessageType MessageType)> messages = [];
        private readonly SemaphoreSlim messageAvailable = new(0);
        public TaskCompletionSource Connected { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource ReceiveEntered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Closed { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public List<string> Sent { get; } = [];
        public Uri? Endpoint { get; private set; }
        public WebSocketState State { get; private set; } = WebSocketState.None;
        public Task ConnectAsync(Uri endpoint, CancellationToken cancellationToken) { Endpoint = endpoint; State = WebSocketState.Open; Connected.TrySetResult(); return Task.CompletedTask; }
        public Task SendAsync(ReadOnlyMemory<byte> message, CancellationToken cancellationToken) { Sent.Add(Encoding.UTF8.GetString(message.Span)); return Task.CompletedTask; }
        public async Task<WebSocketReceiveResult> ReceiveAsync(Memory<byte> buffer, CancellationToken cancellationToken)
        {
            ReceiveEntered.TrySetResult();
            await messageAvailable.WaitAsync(cancellationToken).ConfigureAwait(false);
            (byte[] Bytes, bool EndOfMessage, WebSocketMessageType MessageType) message; lock (messages) message = messages.Dequeue();
            message.Bytes.AsMemory().CopyTo(buffer);
            return new WebSocketReceiveResult(message.Bytes.Length, message.MessageType, message.EndOfMessage);
        }
        public Task CloseAsync(CancellationToken cancellationToken) { State = WebSocketState.Closed; Closed.TrySetResult(); return Task.CompletedTask; }
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
        public void Publish(string message) => Publish(Encoding.UTF8.GetBytes(message), endOfMessage: true);
        public void PublishClose() => Publish([], endOfMessage: true, WebSocketMessageType.Close);
        public void PublishFragments(string message, int fragmentSize)
        {
            var bytes = Encoding.UTF8.GetBytes(message);
            for (var offset = 0; offset < bytes.Length; offset += fragmentSize)
            {
                var length = Math.Min(fragmentSize, bytes.Length - offset);
                Publish(bytes.AsSpan(offset, length).ToArray(), offset + length == bytes.Length);
            }
        }
        private void Publish(byte[] message, bool endOfMessage, WebSocketMessageType messageType = WebSocketMessageType.Text)
        {
            lock (messages) messages.Enqueue((message, endOfMessage, messageType));
            messageAvailable.Release();
        }
    }
}
