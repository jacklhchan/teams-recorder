using System.Buffers.Binary;
using TeamsRecorder.Windows.Application;
using TeamsRecorder.Windows.Application.VirtualMic;

// Standalone by design: this acceptance target avoids modifying the shared
// Recorder.Core.Tests Program while still exercising the preview contract.
internal static class VirtualMicPreviewAcceptanceTests
{
    private const string EndpointId = "{teams-recorder-virtual-mic-test-endpoint}";

    public static async Task<int> Main()
    {
        var tests = new (string Name, Func<Task> Run)[]
        {
            ("identity spoof is rejected", IdentitySpoofIsRejectedAsync),
            ("absent endpoint fails closed", AbsentEndpointFailsClosedAsync),
            ("PCM protocol is bounded and strict", PcmProtocolIsBoundedAndStrictAsync),
            ("release build cannot enable test driver", ReleaseBuildCannotEnableTestDriverAsync),
            ("test build broker handshakes and routes bounded PCM", TestBuildBrokerRoundTripAsync),
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

    private static Task IdentitySpoofIsRejectedAsync()
    {
        var identity = TrustedIdentity();
        Assert(identity.IsWellFormed, "The test identity should match the INF identity contract.");
        var spoofed = VirtualMicCapabilityDetector.Detect(
            [Endpoint("{untrusted-spoof}", VirtualMicPreviewIdentity.FriendlyName)],
            identity.EndpointId);
        Assert(!spoofed.IsAvailable && spoofed.EndpointId is null,
            "A friendly-name spoof without the paired endpoint ID must remain disabled.");

        var wrongHardware = identity with { HardwareId = "ROOT\\UntrustedVirtualMic" };
        Assert(!wrongHardware.IsWellFormed,
            "A pairing with any hardware ID other than the constrained INF identity must be rejected.");
        return Task.CompletedTask;
    }

    private static Task AbsentEndpointFailsClosedAsync()
    {
        var absent = VirtualMicCapabilityDetector.Detect([], TrustedIdentity().EndpointId);
        Assert(!absent.IsAvailable && absent.EndpointId is null,
            "An absent paired endpoint must never route to a same-named or default microphone.");
        return Task.CompletedTask;
    }

    private static Task PcmProtocolIsBoundedAndStrictAsync()
    {
        var pcm = new byte[VirtualMicPcmProtocol.MaximumPcmPayloadBytes];
        var encoded = VirtualMicPcmProtocol.CreatePcm(42, pcm);
        var decoded = VirtualMicPcmProtocol.ParsePcm(VirtualMicPcmProtocol.Deserialize(encoded));
        Assert(decoded.Sequence == 42 && decoded.Pcm16LeStereo.Length == pcm.Length,
            "A maximum 100 ms PCM frame must round trip exactly.");

        Throws<ArgumentOutOfRangeException>(() =>
            VirtualMicPcmProtocol.CreatePcm(43, new byte[VirtualMicPcmProtocol.MaximumPcmPayloadBytes + VirtualMicPcmProtocol.BlockAlign]));

        var oversizedHeader = VirtualMicPcmProtocol.CreateAcknowledgement();
        BinaryPrimitives.WriteUInt32LittleEndian(
            oversizedHeader.AsSpan(sizeof(uint) + sizeof(ushort) + sizeof(ushort)),
            checked((uint)VirtualMicPcmProtocol.MaximumPayloadBytes + 1));
        ThrowsProtocol(VirtualMicPcmProtocolError.OversizedFrame, () => VirtualMicPcmProtocol.Deserialize(oversizedHeader));

        var malformedPcm = VirtualMicPcmProtocol.CreatePcm(44, new byte[VirtualMicPcmProtocol.BlockAlign]);
        BinaryPrimitives.WriteUInt32LittleEndian(
            malformedPcm.AsSpan(sizeof(uint) + sizeof(ushort) + sizeof(ushort)),
            checked((uint)(sizeof(ulong) + VirtualMicPcmProtocol.BlockAlign + 1)));
        ThrowsProtocol(VirtualMicPcmProtocolError.MalformedFrame, () => VirtualMicPcmProtocol.Deserialize(malformedPcm));
        return Task.CompletedTask;
    }

    private static Task ReleaseBuildCannotEnableTestDriverAsync()
    {
        if (VirtualMicPreviewBuildPolicy.IsTestSignedPreviewCompiled)
        {
            // The companion script runs this executable once in Release and
            // once in explicit Debug-preview mode. This assertion belongs only
            // to the former; the latter exercises the broker below.
            return Task.CompletedTask;
        }

        var capability = VirtualMicPreviewHandshake.Evaluate(TrustedIdentity(), [Endpoint(EndpointId, VirtualMicPreviewIdentity.FriendlyName)]);
        Assert(capability.State == VirtualMicPreviewCapabilityState.Disabled && !capability.IsAvailable,
            "Release must fail closed even if a matching test endpoint is enumerated.");
        return Task.CompletedTask;
    }

    private static async Task TestBuildBrokerRoundTripAsync()
    {
        if (!VirtualMicPreviewBuildPolicy.IsTestSignedPreviewCompiled)
        {
            Console.WriteLine("SKIP: broker is correctly compiled out of this Release test run.");
            return;
        }

        var identity = TrustedIdentity();
        var capability = VirtualMicPreviewHandshake.Evaluate(identity, [Endpoint(EndpointId, VirtualMicPreviewIdentity.FriendlyName)]);
        Assert(capability.IsAvailable, "The explicit Debug test-preview build should accept the exact paired endpoint.");
        var sink = new RecordingSink();
        var session = VirtualMicPcmBrokerSession.Create(identity);
        await using var broker = new VirtualMicPcmBroker(capability, session, sink);
        broker.Start();
        await using var connection = await VirtualMicPreviewHandshake.ConnectBrokerAsync(
            capability,
            session,
            TimeSpan.FromSeconds(3)).ConfigureAwait(false);
        await connection.WritePcmAsync(new byte[VirtualMicPcmProtocol.BlockAlign * 480]).ConfigureAwait(false);
        var frame = await sink.FirstFrame.WaitAsync(TimeSpan.FromSeconds(3)).ConfigureAwait(false);
        Assert(frame.Sequence == 1 && frame.Pcm16LeStereo.Length == VirtualMicPcmProtocol.BlockAlign * 480,
            "The broker must deliver one bounded frame after a valid current-user handshake.");
    }

    private static VirtualMicTrustedEndpointIdentity TrustedIdentity() => new(
        EndpointId,
        VirtualMicPreviewIdentity.HardwareId,
        VirtualMicPreviewIdentity.FriendlyName);

    private static NativeCaptureEndpoint Endpoint(string id, string name) =>
        new(CaptureEndpointFlow.Capture, EndpointDefaultRole.None, id, name);

    private static void Throws<TException>(Action action) where TException : Exception
    {
        try
        {
            action();
        }
        catch (TException)
        {
            return;
        }

        throw new InvalidOperationException($"Expected {typeof(TException).Name}.");
    }

    private static void ThrowsProtocol(VirtualMicPcmProtocolError expected, Action action)
    {
        try
        {
            action();
        }
        catch (VirtualMicPcmProtocolException exception) when (exception.Error == expected)
        {
            return;
        }

        throw new InvalidOperationException($"Expected protocol error {expected}.");
    }

    private static void Assert(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }

    private sealed class RecordingSink : IVirtualMicPcmSink
    {
        private readonly TaskCompletionSource<VirtualMicPcmFrame> firstFrame = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public Task<VirtualMicPcmFrame> FirstFrame => firstFrame.Task;

        public Task WriteAsync(VirtualMicPcmFrame frame, CancellationToken cancellationToken)
        {
            firstFrame.TrySetResult(frame);
            return Task.CompletedTask;
        }
    }
}
