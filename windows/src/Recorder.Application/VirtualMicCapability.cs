namespace TeamsRecorder.Windows.Application;

public enum VirtualMicCapabilityState { Unavailable, Available }

public sealed record VirtualMicCapability(VirtualMicCapabilityState State, string? EndpointId, string Reason)
{
    public bool IsAvailable => State == VirtualMicCapabilityState.Available;
}

/// <summary>
/// Gates app integration on an installed capture endpoint with the configured, trusted endpoint
/// ID and the expected friendly name. A friendly name is display metadata, not proof of identity;
/// it is checked only as a second, fail-closed guard. Driver installation and signing are external.
/// </summary>
public static class VirtualMicCapabilityDetector
{
    public const string StableFriendlyName = "Teams Recorder Virtual Microphone";

    public static VirtualMicCapability Detect(IReadOnlyList<NativeCaptureEndpoint> endpoints, string? expectedEndpointId)
    {
        if (string.IsNullOrWhiteSpace(expectedEndpointId))
            return new(VirtualMicCapabilityState.Unavailable, null, "No trusted virtual microphone endpoint ID is configured.");

        if (endpoints is null)
            return new(VirtualMicCapabilityState.Unavailable, null, "Virtual microphone endpoint enumeration is unavailable; integration remains disabled.");

        // Do not trim or otherwise normalize endpoint IDs: the configured ID is the trust anchor.
        var idMatches = endpoints
            .Where(endpoint => string.Equals(endpoint.EndpointId, expectedEndpointId, StringComparison.Ordinal))
            .ToArray();
        if (idMatches.Length == 0)
        {
            var nameMatch = endpoints.Any(endpoint =>
                endpoint.Flow == CaptureEndpointFlow.Capture &&
                string.Equals(endpoint.FriendlyName, StableFriendlyName, StringComparison.Ordinal));
            return nameMatch
                ? new(VirtualMicCapabilityState.Unavailable, null, "A capture endpoint uses the expected virtual microphone name, but its endpoint ID is not trusted (possible friendly-name spoof or stale configuration); integration remains disabled.")
                : new(VirtualMicCapabilityState.Unavailable, null, "The configured trusted virtual microphone endpoint ID was not found; integration remains disabled.");
        }

        if (idMatches.Length != 1)
            return new(VirtualMicCapabilityState.Unavailable, null, "The configured trusted virtual microphone endpoint ID is ambiguous; integration remains disabled.");

        var endpoint = idMatches[0];
        if (endpoint.Flow != CaptureEndpointFlow.Capture)
            return new(VirtualMicCapabilityState.Unavailable, null, "The configured trusted virtual microphone endpoint is not a capture endpoint; integration remains disabled.");

        if (!string.Equals(endpoint.FriendlyName, StableFriendlyName, StringComparison.Ordinal))
            return new(VirtualMicCapabilityState.Unavailable, null, "The configured trusted virtual microphone endpoint has an unexpected friendly name; integration remains disabled.");

        return new(VirtualMicCapabilityState.Available, endpoint.EndpointId, "Trusted virtual microphone endpoint is available.");
    }
}
