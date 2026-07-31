using System.Net;
using System.Text;
using TeamsRecorder.Windows.Application.AI;

internal static class OpenAICompatibleProviderConnectionTests
{
    public static void DiscoversModelsAndKeepsAuthenticationRequestScoped()
    {
        HttpRequestMessage? captured = null;
        using var client = new HttpClient(new DelegateHandler(request =>
        {
            captured = request;
            return Json(HttpStatusCode.OK, "{\"data\":[{\"id\":\"gpt-b\"},{\"id\":\"gpt-a\"},{\"id\":\"gpt-a\"}]}" );
        }));
        using var provider = new OpenAICompatibleProviderConnectionClient(client);
        var report = provider.TestConnectionAsync(Profile(), "secret-key").GetAwaiter().GetResult();
        if (!report.SupportsModelDiscovery || !report.Models.SequenceEqual(["gpt-a", "gpt-b"]))
            throw new InvalidOperationException("Provider model discovery did not normalize model IDs.");
        if (captured?.RequestUri?.AbsoluteUri != "https://provider.example/v1/models" ||
            captured.Headers.Authorization?.ToString() != "Bearer secret-key")
            throw new InvalidOperationException("Connection test did not use the OpenAI-compatible endpoint and request-scoped key.");
    }

    public static void AcceptsManualModelProvidersAndRejectsUnsafeFailures()
    {
        using var manualClient = new HttpClient(new DelegateHandler(_ => new HttpResponseMessage(HttpStatusCode.NotFound)));
        using var manual = new OpenAICompatibleProviderConnectionClient(manualClient);
        if (manual.TestConnectionAsync(Profile(), null).GetAwaiter().GetResult().SupportsModelDiscovery)
            throw new InvalidOperationException("A 404 model endpoint must still permit manual model entry.");

        using var rejectedClient = new HttpClient(new DelegateHandler(_ => new HttpResponseMessage(HttpStatusCode.Unauthorized)));
        using var rejected = new OpenAICompatibleProviderConnectionClient(rejectedClient);
        Throws<ProviderConnectionException>(() => rejected.TestConnectionAsync(Profile(), "bad").GetAwaiter().GetResult(), error => error.Failure == ProviderConnectionFailure.AuthenticationRejected);

        using var oversizedClient = new HttpClient(new DelegateHandler(_ => Json(HttpStatusCode.OK, new string('x', OpenAICompatibleProviderConnectionClient.MaximumResponseBytes + 1))));
        using var oversized = new OpenAICompatibleProviderConnectionClient(oversizedClient);
        Throws<ProviderConnectionException>(() => oversized.TestConnectionAsync(Profile(), null).GetAwaiter().GetResult(), error => error.Failure == ProviderConnectionFailure.ResponseTooLarge);
    }

    private static OpenAICompatibleProviderProfile Profile() =>
        OpenAICompatibleProviderProfile.Validated("https://provider.example", "asr", "llm", "", "");

    private static HttpResponseMessage Json(HttpStatusCode status, string content) => new(status)
    {
        Content = new StringContent(content, Encoding.UTF8, "application/json"),
    };

    private static void Throws<T>(Action action, Func<T, bool> acceptable) where T : Exception
    {
        try { action(); }
        catch (T error) when (acceptable(error)) { return; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }

    private sealed class DelegateHandler(Func<HttpRequestMessage, HttpResponseMessage> response) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(response(request));
    }
}
