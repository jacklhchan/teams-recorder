using TeamsRecorder.Windows.Application;

internal static class MicrophoneDefaultSelectionPolicyTests
{
    public static void PrefersTheCommunicationsDefaultForInitialMicrophone()
    {
        var choice = MicrophoneDefaultSelectionPolicy.SelectInitialCaptureEndpointId(
        [Endpoint("console", EndpointDefaultRole.Console, "Built-in microphone"),
         Endpoint("multimedia", EndpointDefaultRole.Multimedia, "USB microphone"),
         Endpoint("communications", EndpointDefaultRole.Communications, "Headset microphone")]);
        Equal("communications", choice);
    }

    public static void UsesAnyAvailableCaptureWhenWindowsHasNoDefaultRole()
    {
        var choice = MicrophoneDefaultSelectionPolicy.SelectInitialCaptureEndpointId(
        [Endpoint("zeta", EndpointDefaultRole.None, "Zeta"),
         Endpoint("alpha", EndpointDefaultRole.None, "Alpha")]);
        Equal("alpha", choice);
    }

    public static void NeverSelectsRenderEndpointsAsMicrophones()
    {
        var choice = MicrophoneDefaultSelectionPolicy.SelectInitialCaptureEndpointId(
        [new NativeCaptureEndpoint(CaptureEndpointFlow.Render, EndpointDefaultRole.Communications, "speakers", "Speakers")]);
        if (choice is not null)
            throw new InvalidOperationException("A render endpoint cannot be selected as a microphone.");
    }

    private static NativeCaptureEndpoint Endpoint(string id, EndpointDefaultRole roles, string name) =>
        new(CaptureEndpointFlow.Capture, roles, id, name);

    private static void Equal(string expected, string? actual)
    {
        if (!string.Equals(expected, actual, StringComparison.Ordinal))
            throw new InvalidOperationException($"Expected {expected}; got {actual ?? "<null>"}.");
    }
}
