using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using TeamsRecorder.Windows.Application.Control;

// This is deliberately a standalone executable test target until the shared
// Windows test runner is next edited.  It avoids touching that runner while
// still running real named-pipe acceptance checks.
#pragma warning disable CA1416
internal static class RecorderControlPipeTests
{
    public static async Task<int> Main()
    {
        if (!OperatingSystem.IsWindows())
        {
            Console.WriteLine("SKIP: Windows named-pipe control tests require Windows.");
            return 0;
        }

        var tests = new (string Name, Func<Task> Run)[]
        {
            ("current-user DACL allows only the current SID", CurrentUserDaclAllowsOnlyCurrentSidAsync),
            ("unauthorised peer is rejected before dispatch", UnauthorizedPeerIsRejectedAsync),
            ("oversized, unknown-version, and unknown-command requests fail closed", InvalidRequestsFailClosedAsync),
            ("repeated stop is idempotent", RepeatedStopIsIdempotentAsync),
            ("concurrent start has exactly one successful operation", ConcurrentStartHasOneSuccessAsync),
            ("idle-client saturation preserves and recovers the accept loop", IdleClientSaturationRecoversAsync),
            ("control responses contain no sensitive runtime identity", ResponseHasNoSensitiveRuntimeIdentityAsync),
        };

        var failures = 0;
        foreach (var (name, run) in tests)
        {
            try
            {
                await run().ConfigureAwait(false);
                Console.WriteLine($"PASS: {name}");
            }
            catch (Exception exception)
            {
                failures++;
                Console.Error.WriteLine($"FAIL: {name}: {exception.Message}");
            }
        }
        return failures == 0 ? 0 : 1;
    }

    private static Task CurrentUserDaclAllowsOnlyCurrentSidAsync()
    {
        using var identity = WindowsIdentity.GetCurrent();
        var expected = identity.User ?? throw new TestFailureException("Current user SID is unavailable.");
        var security = RecorderControlPipeSecurityPolicy.CreateForCurrentUser(expected);
        var rules = security.GetAccessRules(includeExplicit: true, includeInherited: false, typeof(SecurityIdentifier))
            .OfType<PipeAccessRule>()
            .ToArray();

        Assert(rules.Length == 1, "The control-pipe DACL must contain exactly one explicit allow rule.");
        var rule = rules[0];
        Assert(rule.AccessControlType == AccessControlType.Allow, "The current-user control-pipe rule must be an allow rule.");
        Assert(rule.IdentityReference is SecurityIdentifier actual && actual == expected,
            "The control-pipe DACL must name exactly the current user SID.");
        Assert((rule.PipeAccessRights & PipeAccessRights.ReadWrite) == PipeAccessRights.ReadWrite,
            "The current user must have read/write control-pipe access.");
        return Task.CompletedTask;
    }

    private static async Task UnauthorizedPeerIsRejectedAsync()
    {
        var owner = new FakeLifecycleOwner();
        await using var server = StartServer(owner, new RejectingPeerIdentityVerifier());
        await using var client = await ConnectRawAsync(server.Endpoint).ConfigureAwait(false);
        await WriteRawAsync(client, ValidStatusRequestJson("unauthorised-peer")).ConfigureAwait(false);
        await AssertConnectionClosedAsync(client).ConfigureAwait(false);
        Assert(owner.TotalInvocations == 0, "An unauthorised peer must never reach the lifecycle owner.");
    }

    private static async Task InvalidRequestsFailClosedAsync()
    {
        var owner = new FakeLifecycleOwner();
        await using var server = StartServer(owner);
        var client = new RecorderControlPipeClient(server.Endpoint);
        var unsupportedVersion = await client.SendAsync(
            new RecorderControlRequest(99, "unsupported-version", RecorderControlCommand.Status),
            TimeSpan.FromSeconds(2)).ConfigureAwait(false);
        Assert(!unsupportedVersion.Ok && unsupportedVersion.Error?.Code == "unsupported_protocol",
            "Unknown protocol versions must receive a closed unsupported-protocol response.");

        await using (var unknownCommandPipe = await ConnectRawAsync(server.Endpoint).ConfigureAwait(false))
        {
            await WriteRawAsync(
                unknownCommandPipe,
                "{\"protocolVersion\":1,\"requestID\":\"unknown-command\",\"command\":\"erase-all\",\"argument\":null}\n")
                .ConfigureAwait(false);
            var rawResponse = await ReadRawAsync(unknownCommandPipe).ConfigureAwait(false);
            Assert(rawResponse is not null, "Unknown command should be rejected with a bounded failure response.");
            var response = RecorderControlProtocol.DeserializeResponse(Encoding.UTF8.GetBytes(rawResponse!));
            Assert(!response.Ok && response.Error?.Code == "malformed_request",
                "Unknown command must fail closed before lifecycle dispatch.");
        }

        await using (var oversizedPipe = await ConnectRawAsync(server.Endpoint).ConfigureAwait(false))
        {
            var oversized = new string('x', RecorderControlProtocol.MaximumFrameBytes);
            try
            {
                await WriteRawAsync(oversizedPipe, oversized).ConfigureAwait(false);
            }
            catch (IOException)
            {
                // A close while writing is a valid fail-closed oversized response.
            }
            await AssertConnectionClosedAsync(oversizedPipe).ConfigureAwait(false);
        }

        Assert(owner.TotalInvocations == 0, "Invalid frames must not invoke lifecycle operations.");
    }

    private static async Task RepeatedStopIsIdempotentAsync()
    {
        var owner = new FakeLifecycleOwner(recording: true);
        await using var server = StartServer(owner);
        var client = new RecorderControlPipeClient(server.Endpoint);
        var first = await client.SendAsync(RecorderControlCommand.Stop, timeout: TimeSpan.FromSeconds(2)).ConfigureAwait(false);
        var second = await client.SendAsync(RecorderControlCommand.Stop, timeout: TimeSpan.FromSeconds(2)).ConfigureAwait(false);

        Assert(first.Ok && second.Ok, "Repeated stop requests must both be safe success responses.");
        Assert(owner.StopOperationInvocations == 1, "Repeated stop must invoke the lifecycle stop exactly once.");
        Assert(second.Status?.RecordingState == RecorderControlRecordingState.Idle,
            "The idempotent stop response must project the idle state.");
    }

    private static async Task ConcurrentStartHasOneSuccessAsync()
    {
        var owner = new FakeLifecycleOwner(blockFirstStart: true);
        await using var server = StartServer(owner, timeout: TimeSpan.FromSeconds(4));
        var client = new RecorderControlPipeClient(server.Endpoint);

        var first = client.SendAsync(RecorderControlCommand.Start, timeout: TimeSpan.FromSeconds(4));
        await owner.FirstStartEntered.WaitAsync(TimeSpan.FromSeconds(2)).ConfigureAwait(false);
        var second = client.SendAsync(RecorderControlCommand.Start, timeout: TimeSpan.FromSeconds(4));
        await Task.Delay(80).ConfigureAwait(false);
        owner.ReleaseFirstStart();

        var responses = await Task.WhenAll(first, second).ConfigureAwait(false);
        Assert(responses.Count(response => response.Ok) == 1,
            "Only one concurrent start request may succeed; the competing request must be busy.");
        Assert(responses.Any(response => !response.Ok && response.Error?.Code == "busy"),
            "The competing concurrent start must fail closed as busy.");
        Assert(owner.StartOperationInvocations == 1, "Only one lifecycle start operation may be invoked.");
    }

    private static async Task ResponseHasNoSensitiveRuntimeIdentityAsync()
    {
        var owner = new FakeLifecycleOwner();
        await using var server = StartServer(owner);
        var response = await new RecorderControlPipeClient(server.Endpoint)
            .SendAsync(RecorderControlCommand.Status, timeout: TimeSpan.FromSeconds(2)).ConfigureAwait(false);
        Assert(response.Ok && response.Status is not null, "A normal status request should succeed.");
        var json = RecorderControlProtocol.SerializeStatusJson(response.Status!).ToLowerInvariant();

        foreach (var forbidden in new[] { "path", "pid", "hwnd", "credential", "token", "folder", "deviceid" })
        {
            Assert(!json.Contains(forbidden, StringComparison.Ordinal),
                $"Control response must not contain the sensitive field or value marker '{forbidden}'.");
        }
    }

    private static async Task IdleClientSaturationRecoversAsync()
    {
        var owner = new FakeLifecycleOwner();
        await using var server = StartServer(owner, timeout: TimeSpan.FromSeconds(4));
        var idleClients = new List<NamedPipeClientStream>();
        try
        {
            // Eight connected instances previously caused the ninth server
            // instance creation to fail and silently killed the accept loop.
            for (var index = 0; index < 8; index++)
            {
                idleClients.Add(await ConnectRawAsync(server.Endpoint).ConfigureAwait(false));
            }

            Assert(server.IsRunning, "Saturating the current-user client capacity must not fault the listener.");
        }
        finally
        {
            foreach (var idle in idleClients)
            {
                await idle.DisposeAsync().ConfigureAwait(false);
            }
        }

        var response = await new RecorderControlPipeClient(server.Endpoint)
            .SendAsync(RecorderControlCommand.Status, timeout: TimeSpan.FromSeconds(3)).ConfigureAwait(false);
        Assert(server.IsRunning && response.Ok && response.Status?.AppRunning == true,
            "The accept loop did not recover after saturated idle clients disconnected.");
    }

    private static TestServer StartServer(
        FakeLifecycleOwner owner,
        IRecorderControlPeerIdentityVerifier? peerIdentityVerifier = null,
        TimeSpan? timeout = null)
    {
        var endpoint = new RecorderControlEndpoint($"TeamsRecorder.Control.Tests.{Guid.NewGuid():N}");
        var server = new RecorderControlPipeServer(endpoint, owner, timeout ?? TimeSpan.FromSeconds(2), peerIdentityVerifier);
        server.Start();
        return new TestServer(endpoint, server);
    }

    private static async Task<NamedPipeClientStream> ConnectRawAsync(RecorderControlEndpoint endpoint)
    {
        var client = new NamedPipeClientStream(
            ".",
            endpoint.PipeName,
            PipeDirection.InOut,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        await client.ConnectAsync(timeout.Token).ConfigureAwait(false);
        return client;
    }

    private static Task WriteRawAsync(NamedPipeClientStream pipe, string value) =>
        pipe.WriteAsync(Encoding.UTF8.GetBytes(value)).AsTask();

    private static async Task<string?> ReadRawAsync(NamedPipeClientStream pipe)
    {
        var buffer = new byte[RecorderControlProtocol.MaximumFrameBytes];
        var length = 0;
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        while (length < buffer.Length)
        {
            var count = await pipe.ReadAsync(buffer.AsMemory(length), timeout.Token).ConfigureAwait(false);
            if (count == 0)
            {
                return null;
            }
            var end = length + count;
            for (var index = length; index < end; index++)
            {
                if (buffer[index] == (byte)'\n')
                {
                    return Encoding.UTF8.GetString(buffer, 0, index);
                }
            }
            length = end;
        }
        throw new TestFailureException("The server returned an oversized frame.");
    }

    private static async Task AssertConnectionClosedAsync(NamedPipeClientStream pipe)
    {
        try
        {
            var response = await ReadRawAsync(pipe).ConfigureAwait(false);
            Assert(response is null, "A rejected peer/frame must not receive a success response.");
        }
        catch (IOException)
        {
            // A closed pipe is the expected fail-closed result.
        }
        catch (OperationCanceledException)
        {
            throw new TestFailureException("The rejected control pipe remained open past its bounded timeout.");
        }
    }

    private static string ValidStatusRequestJson(string requestId) =>
        $"{{\"protocolVersion\":1,\"requestID\":\"{requestId}\",\"command\":\"status\",\"argument\":null}}\n";

    private static void Assert(bool condition, string message)
    {
        if (!condition)
        {
            throw new TestFailureException(message);
        }
    }

    private sealed class TestServer : IAsyncDisposable
    {
        public TestServer(RecorderControlEndpoint endpoint, RecorderControlPipeServer server)
        {
            Endpoint = endpoint;
            Server = server;
        }

        public RecorderControlEndpoint Endpoint { get; }
        private RecorderControlPipeServer Server { get; }
        public bool IsRunning => Server.IsRunning;

        public async ValueTask DisposeAsync()
        {
            await Server.DisposeAsync().ConfigureAwait(false);
        }
    }

    private sealed class RejectingPeerIdentityVerifier : IRecorderControlPeerIdentityVerifier
    {
        public bool IsAuthorized(NamedPipeServerStream pipe, SecurityIdentifier expectedCurrentUserSid) => false;
    }

    private sealed class FakeLifecycleOwner : IRecorderControlLifecycleOwner
    {
        private readonly object gate = new();
        private readonly bool blockFirstStart;
        private bool recording;
        private bool microphoneMuted;
        private bool automaticMode;
        private int startOperationInvocations;
        private int stopOperationInvocations;
        private int totalInvocations;
        private readonly TaskCompletionSource firstStartEntered = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource firstStartRelease = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public FakeLifecycleOwner(bool recording = false, bool blockFirstStart = false)
        {
            this.recording = recording;
            this.blockFirstStart = blockFirstStart;
        }

        public int StartOperationInvocations => Volatile.Read(ref startOperationInvocations);
        public int StopOperationInvocations => Volatile.Read(ref stopOperationInvocations);
        public int TotalInvocations => Volatile.Read(ref totalInvocations);
        public Task FirstStartEntered => firstStartEntered.Task;

        public void ReleaseFirstStart() => firstStartRelease.TrySetResult();

        public Task<RecorderControlStatus> GetStatusAsync(CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref totalInvocations);
            lock (gate)
            {
                return Task.FromResult(new RecorderControlStatus(
                    AppRunning: true,
                    AppVersion: "1.2.3",
                    RecordingState: recording ? RecorderControlRecordingState.Recording : RecorderControlRecordingState.Idle,
                    LifecycleOperation: RecorderControlLifecycleOperation.None,
                    ElapsedSeconds: recording ? 12 : null,
                    MicrophoneMuted: microphoneMuted,
                    AutoModeEnabled: automaticMode));
            }
        }

        public async Task<RecorderControlActionResult> StartAsync(CancellationToken cancellationToken)
        {
            lock (gate)
            {
                if (recording)
                {
                    return RecorderControlActionResult.NoOp();
                }
                Interlocked.Increment(ref totalInvocations);
                Interlocked.Increment(ref startOperationInvocations);
            }

            if (blockFirstStart)
            {
                firstStartEntered.TrySetResult();
                await firstStartRelease.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
            }

            lock (gate)
            {
                recording = true;
            }
            return RecorderControlActionResult.Accepted();
        }

        public Task<RecorderControlActionResult> StopAsync(CancellationToken cancellationToken)
        {
            lock (gate)
            {
                if (!recording)
                {
                    return Task.FromResult(RecorderControlActionResult.NoOp());
                }
                recording = false;
                Interlocked.Increment(ref totalInvocations);
                Interlocked.Increment(ref stopOperationInvocations);
                return Task.FromResult(RecorderControlActionResult.Accepted());
            }
        }

        public Task<RecorderControlActionResult> SetAutomaticModeAsync(bool enabled, CancellationToken cancellationToken)
        {
            lock (gate)
            {
                automaticMode = enabled;
                Interlocked.Increment(ref totalInvocations);
                return Task.FromResult(RecorderControlActionResult.Accepted());
            }
        }

        public Task<RecorderControlActionResult> SetMicrophoneMutedAsync(bool muted, CancellationToken cancellationToken)
        {
            lock (gate)
            {
                microphoneMuted = muted;
                Interlocked.Increment(ref totalInvocations);
                return Task.FromResult(RecorderControlActionResult.Accepted());
            }
        }
    }

    private sealed class TestFailureException(string message) : Exception(message);
}
#pragma warning restore CA1416
