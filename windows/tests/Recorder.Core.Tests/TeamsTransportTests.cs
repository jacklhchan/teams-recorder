using System.Net.WebSockets;
using System.Text;
using TeamsRecorder.Windows.Application;

internal static class TeamsTransportTests
{
    public static void ClientQueriesStateAfterConnectAndTokenRefreshThenSendsPairing()
    {
        var socket = new FakeSocket(); var store = new FakeTokenStore();
        var client = new TeamsThirdPartyApiClient(TeamsThirdPartyApiIdentity.Recorder("test"), store, () => socket, TimeSpan.FromHours(1));
        var events = 0; client.EventReceived += (_, _) => Interlocked.Increment(ref events);
        client.StartAsync().GetAwaiter().GetResult();
        Wait(socket.Connected.Task, "The fake socket did not connect.");
        Wait(socket.ReceiveEntered.Task, "The fake socket did not begin receiving.");
        WaitUntil(() => socket.Sent.Count == 1, "The initial state query was not sent.");
        AssertAction(socket.Sent[0], "query-state");
        socket.Publish("""{"tokenRefresh":"stored-only-in-fake"}""");
        WaitUntil(() => store.Token == "stored-only-in-fake", "The refreshed token was not saved.");
        WaitUntil(() => socket.Sent.Count == 2, "The state query after token refresh was not sent.");
        AssertAction(socket.Sent[1], "query-state");
        socket.Publish("""{"meetingUpdate":{"meetingState":{"isInMeeting":true,"isMuted":false},"meetingPermissions":{"canToggleMute":true}}}""");
        WaitUntil(() => Volatile.Read(ref events) == 1, "The WebSocket event was not delivered.");
        Equal("stored-only-in-fake", store.Token!);
        client.RequestPairingAsync().GetAwaiter().GetResult();
        WaitUntil(() => socket.Sent.Count == 3, "The pairing command was not sent.");
        AssertAction(socket.Sent[2], "pair");
        client.StopAsync().GetAwaiter().GetResult(); client.DisposeAsync().AsTask().GetAwaiter().GetResult();
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
        rejectedSocket.Publish("""{"errorMsg":"Invalid token"}""");

        WaitUntil(() => store.ClearCalls == 1, "The invalid pairing token was not cleared.");
        Wait(replacementSocket.Connected.Task, "The client did not reconnect after clearing the invalid token.");
        if (replacementSocket.Endpoint?.Query.Contains("token=", StringComparison.Ordinal) == true)
            throw new InvalidOperationException("The replacement connection reused an invalid pairing token.");
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
        public Task<string?> ReadAsync(CancellationToken cancellationToken = default) => Task.FromResult(Token);
        public Task WriteAsync(string token, CancellationToken cancellationToken = default) { Token = token; return Task.CompletedTask; }
        public Task ClearAsync(CancellationToken cancellationToken = default) { Token = null; ClearCalls++; return Task.CompletedTask; }
    }

    private sealed class FakeSocket : ITeamsWebSocketConnection
    {
        private readonly Queue<(byte[] Bytes, bool EndOfMessage)> messages = [];
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
            (byte[] Bytes, bool EndOfMessage) message; lock (messages) message = messages.Dequeue();
            message.Bytes.AsMemory().CopyTo(buffer);
            return new WebSocketReceiveResult(message.Bytes.Length, WebSocketMessageType.Text, message.EndOfMessage);
        }
        public Task CloseAsync(CancellationToken cancellationToken) { State = WebSocketState.Closed; Closed.TrySetResult(); return Task.CompletedTask; }
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
        public void Publish(string message) => Publish(Encoding.UTF8.GetBytes(message), endOfMessage: true);
        public void PublishFragments(string message, int fragmentSize)
        {
            var bytes = Encoding.UTF8.GetBytes(message);
            for (var offset = 0; offset < bytes.Length; offset += fragmentSize)
            {
                var length = Math.Min(fragmentSize, bytes.Length - offset);
                Publish(bytes.AsSpan(offset, length).ToArray(), offset + length == bytes.Length);
            }
        }
        private void Publish(byte[] message, bool endOfMessage) { lock (messages) messages.Enqueue((message, endOfMessage)); messageAvailable.Release(); }
    }
}
