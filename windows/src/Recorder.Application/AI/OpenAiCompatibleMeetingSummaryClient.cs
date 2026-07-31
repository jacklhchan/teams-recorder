using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace TeamsRecorder.Windows.Application.AI;

public sealed record MeetingSummaryRequest(string Transcript, bool UserConsentGranted);

public sealed record MeetingSummary(string Summary, IReadOnlyList<string> ActionItems, IReadOnlyList<string> Decisions);

public enum MeetingSummaryErrorKind { ConsentRequired, InvalidProfile, TranscriptTooLarge, ProviderUnavailable, InvalidResponse, ResponseTooLarge }

public sealed class MeetingSummaryException(MeetingSummaryErrorKind kind, string message, Exception? inner = null)
    : Exception(message, inner)
{
    public MeetingSummaryErrorKind Kind { get; } = kind;
}

/// <summary>Posts an explicitly-consented transcript to an OpenAI-compatible chat endpoint.</summary>
public sealed class OpenAiCompatibleMeetingSummaryClient : IDisposable
{
    public const int MaximumTranscriptBytes = 256 * 1024;
    public const int MaximumResponseBytes = 1024 * 1024;
    private const int MaximumAttempts = 3;
    private readonly HttpClient client;
    private readonly bool ownsClient;
    private readonly Func<TimeSpan, CancellationToken, Task> delay;

    public OpenAiCompatibleMeetingSummaryClient(HttpClient? client = null, Func<TimeSpan, CancellationToken, Task>? delay = null)
    {
        if (client is null)
        {
            this.client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false });
            ownsClient = true;
        }
        else this.client = client;
        this.delay = delay ?? Task.Delay;
    }

    public async Task<MeetingSummary> SummarizeAsync(OpenAICompatibleProviderSnapshot snapshot, MeetingSummaryRequest request, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        ArgumentNullException.ThrowIfNull(request);
        if (!request.UserConsentGranted) throw new MeetingSummaryException(MeetingSummaryErrorKind.ConsentRequired, "Explicit user consent is required before a transcript is sent to an AI provider.");
        var endpoint = ValidateAndBuildEndpoint(snapshot.Profile);
        var transcript = TranscriptRedactor.Redact(request.Transcript ?? string.Empty);
        if (Encoding.UTF8.GetByteCount(transcript) > MaximumTranscriptBytes)
            throw new MeetingSummaryException(MeetingSummaryErrorKind.TranscriptTooLarge, "The transcript exceeds the 256 KiB AI summary limit.");

        var payload = JsonSerializer.Serialize(new
        {
            model = snapshot.Profile.LlmModel.Trim(),
            temperature = 0.2,
            response_format = new { type = "json_object" },
            messages = new object[]
            {
                new { role = "system", content = "Summarize a meeting. Return only a JSON object with string summary and string arrays actionItems and decisions. Be concise; do not invent facts." },
                new { role = "user", content = transcript }
            }
        });

        for (var attempt = 0; attempt < MaximumAttempts; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            using var httpRequest = new HttpRequestMessage(HttpMethod.Post, endpoint)
            {
                Content = new StringContent(payload, Encoding.UTF8, "application/json")
            };
            httpRequest.Headers.Accept.ParseAdd("application/json");
            if (!string.IsNullOrWhiteSpace(snapshot.ApiKey)) httpRequest.Headers.Authorization = new("Bearer", snapshot.ApiKey);
            try
            {
                using var response = await client.SendAsync(httpRequest, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
                if (IsTransient(response.StatusCode) && attempt + 1 < MaximumAttempts)
                {
                    await delay(TimeSpan.FromSeconds(1 << attempt), cancellationToken).ConfigureAwait(false);
                    continue;
                }
                if (!response.IsSuccessStatusCode) throw new MeetingSummaryException(MeetingSummaryErrorKind.ProviderUnavailable, $"The AI provider returned HTTP {(int)response.StatusCode}.");
                var body = await ReadBoundedAsync(response.Content, cancellationToken).ConfigureAwait(false);
                return Parse(body);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
            catch (MeetingSummaryException) { throw; }
            catch (HttpRequestException) when (attempt + 1 < MaximumAttempts)
            {
                await delay(TimeSpan.FromSeconds(1 << attempt), cancellationToken).ConfigureAwait(false);
            }
            catch (HttpRequestException error)
            {
                throw new MeetingSummaryException(MeetingSummaryErrorKind.ProviderUnavailable, "The AI provider could not be reached.", error);
            }
        }
        throw new MeetingSummaryException(MeetingSummaryErrorKind.ProviderUnavailable, "The AI provider could not be reached.");
    }

    public void Dispose() { if (ownsClient) client.Dispose(); }

    private static Uri ValidateAndBuildEndpoint(OpenAICompatibleProviderProfile profile)
    {
        if (!Uri.TryCreate(profile.BaseUrl, UriKind.Absolute, out var uri) || string.IsNullOrWhiteSpace(profile.LlmModel) ||
            !string.IsNullOrEmpty(uri.UserInfo) || !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment) ||
            !(uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) || (uri.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase) && IsLoopback(uri.Host))))
            throw new MeetingSummaryException(MeetingSummaryErrorKind.InvalidProfile, "The AI provider profile must use HTTPS (or local loopback HTTP) without credentials, query, or fragment.");
        var basePath = uri.AbsolutePath.TrimEnd('/');
        if (!basePath.EndsWith("/v1", StringComparison.OrdinalIgnoreCase)) basePath += "/v1";
        var builder = new UriBuilder(uri) { Path = basePath + "/chat/completions", Query = "", Fragment = "" };
        return builder.Uri;
    }

    private static bool IsLoopback(string host) => host.Equals("localhost", StringComparison.OrdinalIgnoreCase) || host.Equals("::1", StringComparison.OrdinalIgnoreCase) || host.StartsWith("127.", StringComparison.Ordinal);
    private static bool IsTransient(HttpStatusCode status) => status == HttpStatusCode.RequestTimeout || (int)status == 429 || (int)status >= 500;

    private static async Task<byte[]> ReadBoundedAsync(HttpContent content, CancellationToken cancellationToken)
    {
        if (content.Headers.ContentLength is > MaximumResponseBytes) throw new MeetingSummaryException(MeetingSummaryErrorKind.ResponseTooLarge, "The AI provider response exceeds the 1 MiB limit.");
        await using var stream = await content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        using var output = new MemoryStream();
        var buffer = new byte[81920];
        int read;
        while ((read = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) > 0)
        {
            if (output.Length + read > MaximumResponseBytes) throw new MeetingSummaryException(MeetingSummaryErrorKind.ResponseTooLarge, "The AI provider response exceeds the 1 MiB limit.");
            output.Write(buffer, 0, read);
        }
        return output.ToArray();
    }

    private static MeetingSummary Parse(byte[] response)
    {
        try
        {
            using var document = JsonDocument.Parse(response);
            var content = document.RootElement.GetProperty("choices")[0].GetProperty("message").GetProperty("content").GetString();
            using var summary = JsonDocument.Parse(content ?? string.Empty);
            var root = summary.RootElement;
            var text = root.GetProperty("summary").GetString()?.Trim();
            if (string.IsNullOrWhiteSpace(text)) throw new JsonException();
            return new MeetingSummary(text, ReadStrings(root, "actionItems"), ReadStrings(root, "decisions"));
        }
        catch (JsonException error) { throw new MeetingSummaryException(MeetingSummaryErrorKind.InvalidResponse, "The AI provider returned an invalid meeting-summary response.", error); }
        catch (KeyNotFoundException error) { throw new MeetingSummaryException(MeetingSummaryErrorKind.InvalidResponse, "The AI provider returned an invalid meeting-summary response.", error); }
        catch (InvalidOperationException error) { throw new MeetingSummaryException(MeetingSummaryErrorKind.InvalidResponse, "The AI provider returned an invalid meeting-summary response.", error); }
    }

    private static IReadOnlyList<string> ReadStrings(JsonElement root, string property) =>
        root.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.Array
            ? value.EnumerateArray().Where(item => item.ValueKind == JsonValueKind.String).Select(item => item.GetString()!.Trim()).Where(item => item.Length > 0).ToArray()
            : Array.Empty<string>();
}

internal static partial class TranscriptRedactor
{
    [GeneratedRegex(@"(?i)(bearer\s+|api[_-]?key\s*[=:]\s*)[^\s\"",;]+")]
    private static partial Regex Secret();
    [GeneratedRegex(@"(?i)[a-z]:\\Users\\[^\\\s]+")]
    private static partial Regex UserPath();
    public static string Redact(string value) => UserPath().Replace(Secret().Replace(value, "$1[redacted]"), "[user-path]");
}
