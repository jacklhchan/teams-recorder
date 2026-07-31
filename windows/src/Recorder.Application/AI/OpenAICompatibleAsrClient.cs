using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace TeamsRecorder.Windows.Application.AI;

/// <summary>OpenAI-compatible audio transcription request. The API key is deliberately request-scoped.</summary>
public sealed record OpenAICompatibleAsrRequest(
    Uri BaseUri,
    string Model,
    string Language,
    string Prompt,
    string? ApiKey,
    ReadOnlyMemory<byte> Audio,
    string FileName)
{
    internal void Validate()
    {
        ArgumentNullException.ThrowIfNull(BaseUri);
        if (!BaseUri.IsAbsoluteUri || BaseUri.UserInfo.Length != 0 || BaseUri.Query.Length != 0 || BaseUri.Fragment.Length != 0)
            throw new ArgumentException("The ASR base URL must be an absolute URL without credentials, query, or fragment.", nameof(BaseUri));
        if (!BaseUri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) &&
            !(BaseUri.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase) && IsLoopback(BaseUri.Host)))
            throw new ArgumentException("The ASR base URL must use HTTPS, except for a local loopback provider.", nameof(BaseUri));
        if (string.IsNullOrWhiteSpace(Model)) throw new ArgumentException("An ASR model is required.", nameof(Model));
        if (string.IsNullOrWhiteSpace(FileName)) throw new ArgumentException("An audio file name is required.", nameof(FileName));
        if (Audio.Length > OpenAICompatibleAsrClient.MaximumAudioBytes) throw new OpenAICompatibleAsrException(OpenAICompatibleAsrFailure.AudioChunkTooLarge);
    }

    private static bool IsLoopback(string host) =>
        host.Equals("localhost", StringComparison.OrdinalIgnoreCase) ||
        (System.Net.IPAddress.TryParse(host, out var address) && System.Net.IPAddress.IsLoopback(address));
}

public enum OpenAICompatibleAsrResponseFormat { VerboseJson, Json }
public sealed record OpenAICompatibleAsrResult(string Text, OpenAICompatibleAsrResponseFormat ResponseFormat);
public enum OpenAICompatibleAsrFailure { AudioChunkTooLarge, InvalidResponse, AuthenticationRejected, ResponseTooLarge, UnsafeRedirect, HttpStatus }

public sealed class OpenAICompatibleAsrException : Exception
{
    public OpenAICompatibleAsrException(OpenAICompatibleAsrFailure failure, int? statusCode = null, string? message = null, Exception? innerException = null)
        : base(message ?? Describe(failure, statusCode), innerException) { Failure = failure; StatusCode = statusCode; }
    public OpenAICompatibleAsrFailure Failure { get; }
    public int? StatusCode { get; }
    private static string Describe(OpenAICompatibleAsrFailure failure, int? statusCode) => failure switch
    {
        OpenAICompatibleAsrFailure.AudioChunkTooLarge => "The prepared transcription chunk is too large.",
        OpenAICompatibleAsrFailure.InvalidResponse => "The provider returned an invalid transcription response.",
        OpenAICompatibleAsrFailure.AuthenticationRejected => "The provider rejected the API key.",
        OpenAICompatibleAsrFailure.ResponseTooLarge => "The provider response was too large.",
        OpenAICompatibleAsrFailure.UnsafeRedirect => "The provider attempted an unsafe HTTP redirect.",
        _ => $"The provider returned HTTP {statusCode ?? 0} during transcription."
    };
}

/// <summary>Small transport seam: tests can inspect multipart requests without a network or API key.</summary>
public interface IOpenAICompatibleAsrTransport
{
    Task<OpenAICompatibleAsrHttpResponse> SendAsync(OpenAICompatibleAsrHttpRequest request, CancellationToken cancellationToken);
}

public sealed record OpenAICompatibleAsrHttpRequest(Uri Uri, IReadOnlyDictionary<string, string> Headers, byte[] Body);
public sealed record OpenAICompatibleAsrHttpResponse(HttpStatusCode StatusCode, IReadOnlyDictionary<string, string> Headers, byte[] Body);

/// <summary>
/// HTTP transport with redirects disabled by default. It only follows POST-preserving 307/308 redirects
/// when scheme, host, and effective port remain unchanged, so an Authorization header cannot leak.
/// </summary>
public sealed class OpenAICompatibleAsrHttpTransport : IOpenAICompatibleAsrTransport, IDisposable
{
    private const int MaxRedirects = 3;
    private readonly HttpClient client;
    private readonly bool ownsClient;

    public OpenAICompatibleAsrHttpTransport(HttpClient? client = null)
    {
        if (client is not null) { this.client = client; return; }
        this.client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }, disposeHandler: true);
        ownsClient = true;
    }

    public async Task<OpenAICompatibleAsrHttpResponse> SendAsync(OpenAICompatibleAsrHttpRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        var current = request.Uri;
        for (var redirect = 0; ; redirect++)
        {
            using var message = CreateMessage(current, request);
            using var response = await client.SendAsync(message, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
            if (response.StatusCode is HttpStatusCode.TemporaryRedirect or HttpStatusCode.PermanentRedirect)
            {
                var location = response.Headers.Location;
                var destination = location is null ? null : (location.IsAbsoluteUri ? location : new Uri(current, location));
                if (destination is null || redirect >= MaxRedirects || !IsSameAuthority(current, destination))
                    throw new OpenAICompatibleAsrException(OpenAICompatibleAsrFailure.UnsafeRedirect);
                current = destination;
                continue;
            }
            return new OpenAICompatibleAsrHttpResponse(response.StatusCode, ReadHeaders(response), await ReadBoundedAsync(response, cancellationToken).ConfigureAwait(false));
        }
    }

    public void Dispose() { if (ownsClient) client.Dispose(); }

    private static HttpRequestMessage CreateMessage(Uri uri, OpenAICompatibleAsrHttpRequest request)
    {
        var message = new HttpRequestMessage(HttpMethod.Post, uri) { Content = new ByteArrayContent(request.Body) };
        foreach (var (name, value) in request.Headers)
        {
            if (!message.Headers.TryAddWithoutValidation(name, value)) message.Content.Headers.TryAddWithoutValidation(name, value);
        }
        return message;
    }

    private static async Task<byte[]> ReadBoundedAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        if (response.Content.Headers.ContentLength is long length && length > OpenAICompatibleAsrClient.MaximumResponseBytes)
            throw new OpenAICompatibleAsrException(OpenAICompatibleAsrFailure.ResponseTooLarge);
        await using var input = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        using var output = new MemoryStream(); var buffer = new byte[16 * 1024];
        int read;
        while ((read = await input.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) != 0)
        {
            if (output.Length + read > OpenAICompatibleAsrClient.MaximumResponseBytes)
                throw new OpenAICompatibleAsrException(OpenAICompatibleAsrFailure.ResponseTooLarge);
            output.Write(buffer, 0, read);
        }
        return output.ToArray();
    }

    private static IReadOnlyDictionary<string, string> ReadHeaders(HttpResponseMessage response) => response.Headers.Concat(response.Content.Headers)
        .ToDictionary(header => header.Key, header => string.Join(",", header.Value), StringComparer.OrdinalIgnoreCase);
    private static bool IsSameAuthority(Uri source, Uri destination) =>
        string.Equals(source.Scheme, destination.Scheme, StringComparison.OrdinalIgnoreCase) &&
        string.Equals(source.Host, destination.Host, StringComparison.OrdinalIgnoreCase) && EffectivePort(source) == EffectivePort(destination);
    private static int EffectivePort(Uri uri) => uri.IsDefaultPort ? (uri.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase) ? 443 : 80) : uri.Port;
}

public sealed class OpenAICompatibleAsrClient
{
    public const int MaximumAudioBytes = 32 * 1024 * 1024;
    public const int MaximumResponseBytes = 2 * 1024 * 1024;
    private readonly IOpenAICompatibleAsrTransport transport;
    private readonly int maximumAttempts;
    private readonly Func<TimeSpan, CancellationToken, Task> delay;

    public OpenAICompatibleAsrClient(IOpenAICompatibleAsrTransport transport, int maximumAttempts = 3, Func<TimeSpan, CancellationToken, Task>? delay = null)
    {
        this.transport = transport ?? throw new ArgumentNullException(nameof(transport));
        if (maximumAttempts < 1) throw new ArgumentOutOfRangeException(nameof(maximumAttempts));
        this.maximumAttempts = maximumAttempts;
        this.delay = delay ?? Task.Delay;
    }

    public async Task<OpenAICompatibleAsrResult> TranscribeAsync(OpenAICompatibleAsrRequest request, CancellationToken cancellationToken = default)
    {
        request.Validate();
        try { return await SendAsync(request, OpenAICompatibleAsrResponseFormat.VerboseJson, cancellationToken).ConfigureAwait(false); }
        catch (OpenAICompatibleAsrException error) when (error.Failure == OpenAICompatibleAsrFailure.HttpStatus && error.StatusCode is 400 or 422)
        { return await SendAsync(request, OpenAICompatibleAsrResponseFormat.Json, cancellationToken).ConfigureAwait(false); }
    }

    /// <summary>Adapter for the shared, non-secret provider profile. The key remains in the snapshot only.</summary>
    public Task<OpenAICompatibleAsrResult> TranscribeAsync(
        OpenAICompatibleProviderSnapshot snapshot,
        ReadOnlyMemory<byte> audio,
        string fileName,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        var profile = OpenAICompatibleProviderProfile.ValidateStored(snapshot.Profile);
        return TranscribeAsync(new OpenAICompatibleAsrRequest(
            new Uri(profile.BaseUrl, UriKind.Absolute), profile.AsrModel, profile.Language,
            profile.Prompt, snapshot.ApiKey, audio, fileName), cancellationToken);
    }

    private async Task<OpenAICompatibleAsrResult> SendAsync(OpenAICompatibleAsrRequest request, OpenAICompatibleAsrResponseFormat format, CancellationToken cancellationToken)
    {
        var message = BuildRequest(request, format);
        for (var attempt = 0; ; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            OpenAICompatibleAsrHttpResponse response;
            try { response = await transport.SendAsync(message, cancellationToken).ConfigureAwait(false); }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
            catch (Exception error) when (IsTransient(error) && attempt + 1 < maximumAttempts)
            { await delay(Backoff(attempt), cancellationToken).ConfigureAwait(false); continue; }
            if ((int)response.StatusCode is >= 200 and < 300)
            {
                if (response.Body.Length > MaximumResponseBytes) throw new OpenAICompatibleAsrException(OpenAICompatibleAsrFailure.ResponseTooLarge);
                var text = ParseText(response.Body);
                if (string.IsNullOrWhiteSpace(text)) throw new OpenAICompatibleAsrException(OpenAICompatibleAsrFailure.InvalidResponse);
                return new OpenAICompatibleAsrResult(text.Trim(), format);
            }
            var status = (int)response.StatusCode;
            if ((status == 401 || status == 403)) throw new OpenAICompatibleAsrException(OpenAICompatibleAsrFailure.AuthenticationRejected, status);
            if (IsTransient(status) && attempt + 1 < maximumAttempts)
            { await delay(RetryAfter(response.Headers) ?? Backoff(attempt), cancellationToken).ConfigureAwait(false); continue; }
            throw new OpenAICompatibleAsrException(OpenAICompatibleAsrFailure.HttpStatus, status);
        }
    }

    private static OpenAICompatibleAsrHttpRequest BuildRequest(OpenAICompatibleAsrRequest request, OpenAICompatibleAsrResponseFormat format)
    {
        var boundary = "TeamsRecorder-" + Guid.NewGuid().ToString("N");
        using var body = new MemoryStream();
        AddField(body, boundary, "model", request.Model.Trim()); AddField(body, boundary, "language", request.Language.Trim());
        AddField(body, boundary, "prompt", request.Prompt.Trim()); AddField(body, boundary, "response_format", format == OpenAICompatibleAsrResponseFormat.VerboseJson ? "verbose_json" : "json");
        var name = request.FileName.Replace("\"", "_").Replace("\r", "_").Replace("\n", "_");
        Write(body, $"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{name}\"\r\nContent-Type: {MimeType(name)}\r\n\r\n");
        body.Write(request.Audio.Span); Write(body, $"\r\n--{boundary}--\r\n");
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) { ["Content-Type"] = $"multipart/form-data; boundary={boundary}", ["Accept"] = "application/json" };
        if (!string.IsNullOrWhiteSpace(request.ApiKey)) headers["Authorization"] = "Bearer " + request.ApiKey;
        return new OpenAICompatibleAsrHttpRequest(new Uri(request.BaseUri.AbsoluteUri.TrimEnd('/') + "/audio/transcriptions"), headers, body.ToArray());
    }
    private static void AddField(Stream body, string boundary, string name, string value) => Write(body, $"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n");
    private static void Write(Stream stream, string value) { var bytes = Encoding.UTF8.GetBytes(value); stream.Write(bytes); }
    private static string MimeType(string name) => Path.GetExtension(name).ToLowerInvariant() switch { ".m4a" or ".mp4" => "audio/mp4", ".mp3" => "audio/mpeg", ".wav" => "audio/wav", ".flac" => "audio/flac", _ => "application/octet-stream" };
    private static string? ParseText(byte[] body) { try { using var document = JsonDocument.Parse(body); return document.RootElement.TryGetProperty("text", out var text) && text.ValueKind == JsonValueKind.String ? text.GetString() : null; } catch (JsonException) { return null; } }
    private static bool IsTransient(int status) => status == 408 || status == 429 || status is >= 500 and <= 599;
    private static bool IsTransient(Exception error) => error is HttpRequestException || error is TimeoutException || error is TaskCanceledException;
    private static TimeSpan Backoff(int attempt) => TimeSpan.FromSeconds(Math.Min(8, Math.Pow(2, attempt)));
    private static TimeSpan? RetryAfter(IReadOnlyDictionary<string, string> headers)
    {
        if (!headers.TryGetValue("Retry-After", out var value)) return null;
        if (int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out var seconds) && seconds >= 0) return TimeSpan.FromSeconds(Math.Min(60, seconds));
        if (DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var date)) return TimeSpan.FromSeconds(Math.Clamp((date - DateTimeOffset.UtcNow).TotalSeconds, 0, 60));
        return null;
    }
}
