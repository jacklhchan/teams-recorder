using System.Net;
using System.Text.Json;

namespace TeamsRecorder.Windows.Application.AI;

/// <summary>
/// Performs the same lightweight provider check as the macOS app: GET /v1/models.
/// A provider that does not implement model discovery can still be used by entering
/// its model names manually; authentication failures and unsafe profiles fail closed.
/// </summary>
public sealed class OpenAICompatibleProviderConnectionClient : IDisposable
{
    public const int MaximumResponseBytes = 1024 * 1024;
    public const int MaximumDiscoveredModels = 1000;
    private readonly HttpClient client;
    private readonly bool ownsClient;

    public OpenAICompatibleProviderConnectionClient(HttpClient? client = null)
    {
        if (client is null)
        {
            this.client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false })
            {
                Timeout = TimeSpan.FromSeconds(15),
            };
            ownsClient = true;
        }
        else
        {
            this.client = client;
        }
    }

    public async Task<ProviderConnectionReport> TestConnectionAsync(
        OpenAICompatibleProviderProfile profile,
        string? apiKey,
        CancellationToken cancellationToken = default)
    {
        var validated = OpenAICompatibleProviderProfile.ValidateStored(profile);
        var endpoint = new Uri(validated.BaseUrl.TrimEnd('/') + "/models", UriKind.Absolute);
        using var request = new HttpRequestMessage(HttpMethod.Get, endpoint);
        request.Headers.Accept.ParseAdd("application/json");
        if (!string.IsNullOrWhiteSpace(apiKey))
        {
            request.Headers.Authorization = new("Bearer", apiKey);
        }

        try
        {
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
            if (response.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.MethodNotAllowed)
            {
                return ProviderConnectionReport.WithoutModelDiscovery;
            }
            if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            {
                throw new ProviderConnectionException(ProviderConnectionFailure.AuthenticationRejected);
            }
            if (!response.IsSuccessStatusCode)
            {
                throw new ProviderConnectionException(ProviderConnectionFailure.HttpStatus, (int)response.StatusCode);
            }

            var payload = await ReadBoundedAsync(response.Content, cancellationToken).ConfigureAwait(false);
            try
            {
                using var document = JsonDocument.Parse(payload);
                if (!document.RootElement.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Array)
                {
                    return ProviderConnectionReport.WithoutModelDiscovery;
                }
                if (data.GetArrayLength() > MaximumDiscoveredModels)
                {
                    throw new ProviderConnectionException(ProviderConnectionFailure.TooManyModels);
                }
                var models = data.EnumerateArray()
                    .Where(item => item.ValueKind == JsonValueKind.Object && item.TryGetProperty("id", out var id) && id.ValueKind == JsonValueKind.String)
                    .Select(item => item.GetProperty("id").GetString()?.Trim())
                    .Where(id => !string.IsNullOrWhiteSpace(id))
                    .Cast<string>()
                    .Distinct(StringComparer.Ordinal)
                    .OrderBy(id => id, StringComparer.Ordinal)
                    .ToArray();
                return new ProviderConnectionReport(true, models);
            }
            catch (JsonException)
            {
                return ProviderConnectionReport.WithoutModelDiscovery;
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (ProviderConnectionException)
        {
            throw;
        }
        catch (HttpRequestException error)
        {
            throw new ProviderConnectionException(ProviderConnectionFailure.Unavailable, innerException: error);
        }
        catch (TaskCanceledException error)
        {
            throw new ProviderConnectionException(ProviderConnectionFailure.Unavailable, innerException: error);
        }
    }

    private static async Task<byte[]> ReadBoundedAsync(HttpContent content, CancellationToken cancellationToken)
    {
        if (content.Headers.ContentLength is > MaximumResponseBytes)
        {
            throw new ProviderConnectionException(ProviderConnectionFailure.ResponseTooLarge);
        }
        await using var input = await content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        using var output = new MemoryStream();
        var buffer = new byte[81920];
        int read;
        while ((read = await input.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) > 0)
        {
            if (output.Length + read > MaximumResponseBytes)
            {
                throw new ProviderConnectionException(ProviderConnectionFailure.ResponseTooLarge);
            }
            output.Write(buffer, 0, read);
        }
        return output.ToArray();
    }

    public void Dispose()
    {
        if (ownsClient)
        {
            client.Dispose();
        }
    }
}

public sealed record ProviderConnectionReport(bool SupportsModelDiscovery, IReadOnlyList<string> Models)
{
    public static ProviderConnectionReport WithoutModelDiscovery { get; } = new(false, Array.Empty<string>());
}

public enum ProviderConnectionFailure { AuthenticationRejected, HttpStatus, ResponseTooLarge, TooManyModels, Unavailable }

/// <summary>Safe-to-display error; it intentionally excludes the provider URL and API key.</summary>
public sealed class ProviderConnectionException(
    ProviderConnectionFailure failure,
    int? statusCode = null,
    Exception? innerException = null)
    : Exception(Describe(failure, statusCode), innerException)
{
    public ProviderConnectionFailure Failure { get; } = failure;
    public int? StatusCode { get; } = statusCode;

    private static string Describe(ProviderConnectionFailure failure, int? statusCode) => failure switch
    {
        ProviderConnectionFailure.AuthenticationRejected => "The provider rejected the API key.",
        ProviderConnectionFailure.ResponseTooLarge => "The provider returned an oversized response.",
        ProviderConnectionFailure.TooManyModels => "The provider returned too many models.",
        ProviderConnectionFailure.Unavailable => "The provider could not be reached.",
        _ => $"The provider returned HTTP {statusCode ?? 0}.",
    };
}
