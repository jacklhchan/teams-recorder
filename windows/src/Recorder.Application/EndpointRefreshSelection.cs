namespace TeamsRecorder.Windows.Application;

/// <summary>
/// Preserves an explicit endpoint choice across a fresh native enumeration.
/// A vanished endpoint remains selected but unavailable, rather than silently
/// changing the recording source to a default device.
/// </summary>
public readonly record struct EndpointRefreshSelection(
    string? EndpointId,
    bool IsAvailable)
{
    public static EndpointRefreshSelection Retain(
        string? selectedEndpointId,
        IEnumerable<NativeCaptureEndpoint> endpoints)
    {
        ArgumentNullException.ThrowIfNull(endpoints);

        // A null ID is the intentional "system default" or "no microphone"
        // choice. It must not be replaced by the first enumerated endpoint.
        if (selectedEndpointId is null)
        {
            return new(null, IsAvailable: true);
        }

        return new(
            selectedEndpointId,
            endpoints.Any(endpoint => string.Equals(
                endpoint.EndpointId,
                selectedEndpointId,
                StringComparison.Ordinal)));
    }
}
