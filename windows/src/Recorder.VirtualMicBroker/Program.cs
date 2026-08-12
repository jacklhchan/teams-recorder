using TeamsRecorder.Windows.Application.VirtualMic;

namespace TeamsRecorder.Windows.VirtualMicBroker;

internal static class Program
{
    public static async Task<int> Main()
    {
        try
        {
            if (!VirtualMicPreviewBuildPolicy.IsTestSignedPreviewCompiled)
                return 10;

            var bootstrap = await Console.In.ReadLineAsync().ConfigureAwait(false);
            var session = VirtualMicBrokerLaunchEnvelope.Parse(bootstrap ?? string.Empty).ToSession();
            var capability = new VirtualMicPreviewCapability(
                VirtualMicPreviewCapabilityState.Available,
                session.Identity.EndpointId,
                "Exact endpoint identity was supplied over the private bootstrap channel.");

            using var sink = new VirtualMicKernelPcmSink(new VirtualMicKernelTransport());
            await using var broker = new VirtualMicPcmBroker(capability, session, sink);
            broker.Start();
            while (broker.IsRunning)
                await Task.Delay(100).ConfigureAwait(false);
            return 0;
        }
        catch
        {
            // Endpoint IDs, tokens and audio are intentionally never logged.
            return 1;
        }
    }
}
