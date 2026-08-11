using System.Net.Http.Headers;

namespace TeamsRecorder.Windows.Application.AI;

/// <summary>Applies the credential scheme required by the frozen provider profile.</summary>
public static class ProviderRequestAuthentication
{
    public static void Apply(HttpRequestMessage request, OpenAICompatibleProviderSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(snapshot);
        request.Headers.Authorization = null;
        request.Headers.Remove("X-API-KEY");
        var key = snapshot.ApiKey?.Trim();
        if (string.IsNullOrWhiteSpace(key)) return;
        if (snapshot.Profile.ProviderKind == AIProviderKind.HktGenAI)
            request.Headers.TryAddWithoutValidation("X-API-KEY", key);
        else
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
    }

    public static KeyValuePair<string, string>? Header(OpenAICompatibleProviderProfile profile, string? apiKey)
    {
        var key = apiKey?.Trim();
        if (string.IsNullOrWhiteSpace(key)) return null;
        return profile.ProviderKind == AIProviderKind.HktGenAI
            ? new("X-API-KEY", key)
            : new("Authorization", "Bearer " + key);
    }
}
