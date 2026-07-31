namespace TeamsRecorder.Windows.Application;

/// <summary>
/// Enforces the privacy-first initial microphone choice. Physical microphone
/// capture requires an explicit user selection and is never inferred from a
/// Windows default-role endpoint.
/// </summary>
public static class MicrophoneDefaultSelectionPolicy
{
    public static string? SelectInitialCaptureEndpointId(
        IEnumerable<NativeCaptureEndpoint> endpoints)
    {
        ArgumentNullException.ThrowIfNull(endpoints);
        return null;
    }
}
