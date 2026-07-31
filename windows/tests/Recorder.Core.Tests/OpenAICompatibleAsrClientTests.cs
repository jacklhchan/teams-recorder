using System.Net;
using System.Text;
using TeamsRecorder.Windows.Application.AI;

internal static class OpenAICompatibleAsrClientTests
{
    public static void UsesOpenAiMultipartContractAndBearerKey()
    {
        var transport = new FakeTransport(Success(" hello world "));
        var result = Client(transport).TranscribeAsync(Request()).GetAwaiter().GetResult();
        Equal("hello world", result.Text); Equal(OpenAICompatibleAsrResponseFormat.VerboseJson, result.ResponseFormat);
        var sent = transport.Requests.Single();
        Equal("https://example.test/v1/audio/transcriptions", sent.Uri.AbsoluteUri);
        Equal("Bearer test-key", sent.Headers["Authorization"]);
        var body = Encoding.UTF8.GetString(sent.Body);
        Contains(body, "name=\"model\""); Contains(body, "whisper-1"); Contains(body, "name=\"language\""); Contains(body, "zh");
        Contains(body, "name=\"prompt\""); Contains(body, "meeting terms"); Contains(body, "name=\"response_format\""); Contains(body, "verbose_json");
        Contains(body, "filename=\"call.m4a\"");
    }

    public static void FallsBackToJsonOnlyForUnsupportedVerboseJson()
    {
        var transport = new FakeTransport(Status(422), Success("fallback"));
        var result = Client(transport).TranscribeAsync(Request()).GetAwaiter().GetResult();
        Equal(OpenAICompatibleAsrResponseFormat.Json, result.ResponseFormat); Equal(2, transport.Requests.Count);
        Contains(Encoding.UTF8.GetString(transport.Requests[1].Body), "\r\njson\r\n");
    }

    public static void RetriesTransientResponsesWithRetryAfter()
    {
        var delays = new List<TimeSpan>();
        var transport = new FakeTransport(Status(429, new Dictionary<string, string> { ["Retry-After"] = "3" }), Success("after retry"));
        var client = new OpenAICompatibleAsrClient(transport, delay: (value, _) => { delays.Add(value); return Task.CompletedTask; });
        Equal("after retry", client.TranscribeAsync(Request()).GetAwaiter().GetResult().Text);
        Equal(TimeSpan.FromSeconds(3), delays.Single()); Equal(2, transport.Requests.Count);
    }

    public static void BoundsAudioAndResponseAndHonorsCancellation()
    {
        var oversized = Request() with { Audio = new byte[OpenAICompatibleAsrClient.MaximumAudioBytes + 1] };
        Throws<OpenAICompatibleAsrException>(() => Client(new FakeTransport()).TranscribeAsync(oversized).GetAwaiter().GetResult(), error => error.Failure == OpenAICompatibleAsrFailure.AudioChunkTooLarge);
        Throws<OpenAICompatibleAsrException>(() => Client(new FakeTransport(new OpenAICompatibleAsrHttpResponse(HttpStatusCode.OK, EmptyHeaders, new byte[OpenAICompatibleAsrClient.MaximumResponseBytes + 1]))).TranscribeAsync(Request()).GetAwaiter().GetResult(), error => error.Failure == OpenAICompatibleAsrFailure.ResponseTooLarge);
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        Throws<OperationCanceledException>(() => Client(new FakeTransport()).TranscribeAsync(Request(), cancelled.Token).GetAwaiter().GetResult(), _ => true);
    }

    public static void DoesNotRetryAuthenticationOrAcceptInvalidPayload()
    {
        var unauthorized = new FakeTransport(Status(401));
        Throws<OpenAICompatibleAsrException>(() => Client(unauthorized).TranscribeAsync(Request()).GetAwaiter().GetResult(), error => error.Failure == OpenAICompatibleAsrFailure.AuthenticationRejected);
        Equal(1, unauthorized.Requests.Count);
        Throws<OpenAICompatibleAsrException>(() => Client(new FakeTransport(new OpenAICompatibleAsrHttpResponse(HttpStatusCode.OK, EmptyHeaders, Encoding.UTF8.GetBytes("{}")))).TranscribeAsync(Request()).GetAwaiter().GetResult(), error => error.Failure == OpenAICompatibleAsrFailure.InvalidResponse);
    }

    public static void UsesTheSharedProviderSnapshotWithoutPersistingItsKey()
    {
        var transport = new FakeTransport(Success("snapshot"));
        var profile = OpenAICompatibleProviderProfile.Validated("https://provider.example", "asr-model", "llm-model", "yue", "names");
        var snapshot = new OpenAICompatibleProviderSnapshot(profile, "memory-only-key");
        Equal("snapshot", Client(transport).TranscribeAsync(snapshot, new byte[] { 5 }, "meeting.m4a").GetAwaiter().GetResult().Text);
        var request = transport.Requests.Single();
        Equal("https://provider.example/v1/audio/transcriptions", request.Uri.AbsoluteUri);
        Equal("Bearer memory-only-key", request.Headers["Authorization"]);
    }

    private static readonly IReadOnlyDictionary<string, string> EmptyHeaders = new Dictionary<string, string>();
    private static OpenAICompatibleAsrClient Client(FakeTransport transport) => new(transport, delay: (_, _) => Task.CompletedTask);
    private static OpenAICompatibleAsrRequest Request() => new(new Uri("https://example.test/v1"), "whisper-1", "zh", "meeting terms", "test-key", new byte[] { 1, 2, 3 }, "call.m4a");
    private static OpenAICompatibleAsrHttpResponse Success(string text) => new(HttpStatusCode.OK, EmptyHeaders, Encoding.UTF8.GetBytes($"{{\"text\":\"{text}\"}}"));
    private static OpenAICompatibleAsrHttpResponse Status(int code, IReadOnlyDictionary<string, string>? headers = null) => new((HttpStatusCode)code, headers ?? EmptyHeaders, Array.Empty<byte>());
    private static void Equal<T>(T expected, T actual) where T : notnull { if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new InvalidOperationException($"Expected {expected}; got {actual}."); }
    private static void Contains(string value, string expected) { if (!value.Contains(expected, StringComparison.Ordinal)) throw new InvalidOperationException($"Expected '{expected}' in value."); }
    private static void Throws<T>(Action action, Func<T, bool> expected) where T : Exception { try { action(); } catch (T error) when (expected(error)) { return; } throw new InvalidOperationException($"Expected {typeof(T).Name}."); }

    private sealed class FakeTransport : IOpenAICompatibleAsrTransport
    {
        private readonly Queue<object> results;
        public FakeTransport(params object[] values) => results = new Queue<object>(values);
        public List<OpenAICompatibleAsrHttpRequest> Requests { get; } = [];
        public Task<OpenAICompatibleAsrHttpResponse> SendAsync(OpenAICompatibleAsrHttpRequest request, CancellationToken cancellationToken)
        {
            Requests.Add(request); cancellationToken.ThrowIfCancellationRequested();
            if (results.Count == 0) throw new InvalidOperationException("No fake response was queued.");
            var result = results.Dequeue(); if (result is Exception error) return Task.FromException<OpenAICompatibleAsrHttpResponse>(error);
            return Task.FromResult((OpenAICompatibleAsrHttpResponse)result);
        }
    }
}
