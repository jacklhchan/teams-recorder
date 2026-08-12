using System.Net;
using System.Text;
using TeamsRecorder.Windows.Application.AI;

internal static class OpenAiCompatibleMeetingSummaryClientTests
{
    public static void SendsOpenAiCompatibleJsonOnlyAfterConsent()
    {
        var handler = new CapturingHandler("""{"choices":[{"message":{"content":"{\"summary\":\"Decided ship date\",\"actionItems\":[\"Send plan\"],\"decisions\":[\"Ship Friday\"]}"}}]}""");
        using var client = new OpenAiCompatibleMeetingSummaryClient(new HttpClient(handler));
        var profile = Snapshot("https://ai.example.test/v1", "gpt-test", "secret");
        var summary = client.SummarizeAsync(profile, new MeetingSummaryRequest("Bearer abc C:\\Users\\Jane\\notes", true)).GetAwaiter().GetResult();
        if (handler.Request is null || handler.Request.RequestUri?.AbsolutePath != "/v1/chat/completions" || handler.Request.Headers.Authorization?.Scheme != "Bearer" ||
            !handler.Body.Contains("gpt-test") || !handler.Body.Contains("[redacted]") || handler.Body.Contains("abc") || handler.Body.Contains("C:\\Users\\Jane") ||
            summary.ActionItems.Single() != "Send plan" || summary.Decisions.Single() != "Ship Friday") throw new InvalidOperationException("The OpenAI-compatible summary request was not safely constructed.");
    }

    public static void RejectsConsentOversizeAndUnsafeProfileBeforeNetwork()
    {
        var handler = new CapturingHandler("{}");
        using var client = new OpenAiCompatibleMeetingSummaryClient(new HttpClient(handler));
        var profile = Snapshot("https://ai.example.test", "model", null);
        Expect(MeetingSummaryErrorKind.ConsentRequired, () => client.SummarizeAsync(profile, new MeetingSummaryRequest("text", false)).GetAwaiter().GetResult());
        Expect(MeetingSummaryErrorKind.TranscriptTooLarge, () => client.SummarizeAsync(profile, new MeetingSummaryRequest(new string('a', OpenAiCompatibleMeetingSummaryClient.MaximumTranscriptBytes + 1), true)).GetAwaiter().GetResult());
        Expect(MeetingSummaryErrorKind.InvalidProfile, () => client.SummarizeAsync(new OpenAICompatibleProviderSnapshot(new OpenAICompatibleProviderProfile { BaseUrl = "http://ai.example.test", LlmModel = "model" }, null), new MeetingSummaryRequest("text", true)).GetAwaiter().GetResult());
        if (handler.CallCount != 0) throw new InvalidOperationException("A rejected request must not reach the network.");
    }

    public static void RetriesTransientFailureAndBoundsResponse()
    {
        var handler = new SequenceHandler(HttpStatusCode.ServiceUnavailable, HttpStatusCode.OK);
        using var client = new OpenAiCompatibleMeetingSummaryClient(new HttpClient(handler), (_, _) => Task.CompletedTask);
        var profile = Snapshot("https://ai.example.test", "model", null);
        var result = client.SummarizeAsync(profile, new MeetingSummaryRequest("text", true)).GetAwaiter().GetResult();
        if (handler.CallCount != 2 || result.Summary != "ok") throw new InvalidOperationException("A transient provider failure was not retried.");
        var tooLarge = new CapturingHandler(new string('x', OpenAiCompatibleMeetingSummaryClient.MaximumResponseBytes + 1));
        using var oversizedClient = new OpenAiCompatibleMeetingSummaryClient(new HttpClient(tooLarge));
        Expect(MeetingSummaryErrorKind.ResponseTooLarge, () => oversizedClient.SummarizeAsync(profile, new MeetingSummaryRequest("text", true)).GetAwaiter().GetResult());
    }

    private static void Expect(MeetingSummaryErrorKind expected, Action action)
    {
        try { action(); throw new InvalidOperationException("Expected an error."); }
        catch (AggregateException error) when (error.InnerException is MeetingSummaryException summary && summary.Kind == expected) { }
        catch (MeetingSummaryException error) when (error.Kind == expected) { }
    }

    private static OpenAICompatibleProviderSnapshot Snapshot(string baseUrl, string model, string? apiKey) =>
        new(OpenAICompatibleProviderProfile.Validated(baseUrl, "asr-test", model, language: null, prompt: null), apiKey);

    private sealed class CapturingHandler(string response) : HttpMessageHandler
    {
        public HttpRequestMessage? Request { get; private set; }
        public string Body { get; private set; } = string.Empty;
        public int CallCount { get; private set; }
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            CallCount++; Request = request; Body = request.Content is null ? string.Empty : await request.Content.ReadAsStringAsync(cancellationToken);
            return new(HttpStatusCode.OK) { Content = new StringContent(response, Encoding.UTF8, "application/json") };
        }
    }

    private sealed class SequenceHandler(params HttpStatusCode[] statuses) : HttpMessageHandler
    {
        public int CallCount { get; private set; }
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var status = statuses[Math.Min(CallCount++, statuses.Length - 1)];
            var body = status == HttpStatusCode.OK ? """{"choices":[{"message":{"content":"{\"summary\":\"ok\",\"actionItems\":[],\"decisions\":[]}"}}]}""" : "{}";
            return Task.FromResult(new HttpResponseMessage(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") });
        }
    }
}
