using TeamsRecorder.Windows.Application;

internal static class VirtualMicCapabilityTests
{
    private const string TrustedEndpointId = "{trusted-virtual-mic-endpoint}";

    public static void TrustedCaptureEndpointIsAvailable()
    {
        var capability = VirtualMicCapabilityDetector.Detect(
            [Endpoint(TrustedEndpointId, VirtualMicCapabilityDetector.StableFriendlyName)],
            TrustedEndpointId);

        Equal(VirtualMicCapabilityState.Available, capability.State);
        Equal(TrustedEndpointId, capability.EndpointId!);
    }

    public static void MissingTrustedIdentityFailsClosed()
    {
        var capability = VirtualMicCapabilityDetector.Detect([], TrustedEndpointId);

        Equal(VirtualMicCapabilityState.Unavailable, capability.State);
        Equal(null, capability.EndpointId);
        Equal("The configured trusted virtual microphone endpoint ID was not found; integration remains disabled.", capability.Reason);
    }

    public static void MismatchedFriendlyNameForTrustedIdentityFailsClosed()
    {
        var capability = VirtualMicCapabilityDetector.Detect(
            [Endpoint(TrustedEndpointId, "Different device")],
            TrustedEndpointId);

        Equal(VirtualMicCapabilityState.Unavailable, capability.State);
        Equal(null, capability.EndpointId);
        Equal("The configured trusted virtual microphone endpoint has an unexpected friendly name; integration remains disabled.", capability.Reason);
    }

    public static void FriendlyNameSpoofWithoutTrustedIdentityFailsClosed()
    {
        var capability = VirtualMicCapabilityDetector.Detect(
            [Endpoint("{untrusted-endpoint}", VirtualMicCapabilityDetector.StableFriendlyName)],
            TrustedEndpointId);

        Equal(VirtualMicCapabilityState.Unavailable, capability.State);
        Equal(null, capability.EndpointId);
        Equal("A capture endpoint uses the expected virtual microphone name, but its endpoint ID is not trusted (possible friendly-name spoof or stale configuration); integration remains disabled.", capability.Reason);
    }

    private static NativeCaptureEndpoint Endpoint(string endpointId, string friendlyName) =>
        new(CaptureEndpointFlow.Capture, EndpointDefaultRole.None, endpointId, friendlyName);

    private static void Equal<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new InvalidOperationException($"Expected {expected}; got {actual}.");
    }
}
