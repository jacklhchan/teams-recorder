namespace TeamsRecorder.Windows.Application;

/// <summary>
/// Chooses the initial optional microphone without changing a choice the user
/// has already made. Communications is preferred because it is the Windows
/// role normally used by meeting clients such as Teams.
/// </summary>
public static class MicrophoneDefaultSelectionPolicy
{
    public static string? SelectInitialCaptureEndpointId(
        IEnumerable<NativeCaptureEndpoint> endpoints)
    {
        ArgumentNullException.ThrowIfNull(endpoints);
        return endpoints
            .Where(endpoint => endpoint.Flow == CaptureEndpointFlow.Capture)
            .OrderBy(GetDefaultRoleRank)
            .ThenBy(endpoint => endpoint.FriendlyName, StringComparer.CurrentCultureIgnoreCase)
            .Select(endpoint => endpoint.EndpointId)
            .FirstOrDefault();
    }

    private static int GetDefaultRoleRank(NativeCaptureEndpoint endpoint) =>
        endpoint.DefaultRoles.HasFlag(EndpointDefaultRole.Communications) ? 0 :
        endpoint.DefaultRoles.HasFlag(EndpointDefaultRole.Multimedia) ? 1 :
        endpoint.DefaultRoles.HasFlag(EndpointDefaultRole.Console) ? 2 : 3;
}
