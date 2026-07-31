using System.Text.Json;
using TeamsRecorder.Windows.Application.AI;

internal static class OpenAICompatibleProviderTests
{
    public static void DefaultsMatchOpenAiAndNormalizeVersionedBaseUrl()
    {
        var profile = OpenAICompatibleProviderProfile.Default;
        Equal("https://api.openai.com/v1", profile.BaseUrl);
        Equal("gpt-4o-transcribe", profile.AsrModel);
        Equal("gpt-5.6-terra", profile.LlmModel);
        var custom = OpenAICompatibleProviderProfile.Validated(" https://example.test/openai/ ", " asr ", " llm ", " yue ", " meeting ");
        Equal("https://example.test/openai/v1", custom.BaseUrl); Equal("asr", custom.AsrModel); Equal("llm", custom.LlmModel); Equal("yue", custom.Language); Equal("meeting", custom.Prompt);
    }

    public static void ProfileRejectsInsecureOrSensitiveUrlsAndFutureSchema()
    {
        Reject("http://example.test", ProviderProfileValidationError.InsecureRemoteUrl);
        Reject("https://key@example.test", ProviderProfileValidationError.UnsupportedUrlComponents);
        Reject("https://example.test/v1?token=secret", ProviderProfileValidationError.UnsupportedUrlComponents);
        Reject("https://example.test/v1#fragment", ProviderProfileValidationError.UnsupportedUrlComponents);
        var loopback = OpenAICompatibleProviderProfile.Validated("http://127.0.0.1:8080", "asr", "llm", "", "");
        Equal("http://127.0.0.1:8080/v1", loopback.BaseUrl);
        try { OpenAICompatibleProviderProfile.ValidateStored(loopback with { SchemaVersion = 2 }); throw new InvalidOperationException("Future schema was accepted."); }
        catch (ProviderProfileException error) when (error.Reason == ProviderProfileValidationError.UnsupportedSchemaVersion) { }
    }

    public static void RepositoryKeepsKeyOutOfProfileJsonAndSnapshotsItSeparately()
    {
        using var root = new TestRoot();
        var profilePath = Path.Combine(root.Path, "profile.json");
        var keys = new FakeKeyStore();
        var repository = new OpenAICompatibleProviderRepository(new JsonOpenAICompatibleProviderProfileStore(profilePath), keys);
        var profile = OpenAICompatibleProviderProfile.Validated("https://provider.example", "asr-model", "llm-model", "yue", "context");
        repository.SaveAsync(profile, "secret-api-key").GetAwaiter().GetResult();
        var saved = File.ReadAllText(profilePath);
        if (saved.Contains("secret-api-key", StringComparison.Ordinal) || saved.Contains("apiKey", StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Profile JSON stored the API key.");
        var snapshot = repository.SnapshotAsync().GetAwaiter().GetResult();
        Equal("secret-api-key", snapshot.ApiKey!); Equal("https://provider.example/v1", snapshot.Profile.BaseUrl);
    }

    private static void Reject(string baseUrl, ProviderProfileValidationError expected)
    {
        try { _ = OpenAICompatibleProviderProfile.Validated(baseUrl, "asr", "llm", "", ""); throw new InvalidOperationException($"{baseUrl} was accepted."); }
        catch (ProviderProfileException error) when (error.Reason == expected) { }
    }
    private static void Equal(string expected, string actual) { if (!string.Equals(expected, actual, StringComparison.Ordinal)) throw new InvalidOperationException($"Expected '{expected}', got '{actual}'."); }
    private sealed class FakeKeyStore : IOpenAICompatibleApiKeyStore
    {
        private string? key;
        public Task<string?> ReadAsync(CancellationToken cancellationToken = default) => Task.FromResult(key);
        public Task WriteAsync(string apiKey, CancellationToken cancellationToken = default) { key = apiKey; return Task.CompletedTask; }
        public Task ClearAsync(CancellationToken cancellationToken = default) { key = null; return Task.CompletedTask; }
    }
    private sealed class TestRoot : IDisposable
    {
        public TestRoot() { Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "teams-recorder-ai-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(Path); }
        public string Path { get; }
        public void Dispose() { try { Directory.Delete(Path, true); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
    }
}
