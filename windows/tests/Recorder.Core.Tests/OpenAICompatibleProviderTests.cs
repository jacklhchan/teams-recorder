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
        try { OpenAICompatibleProviderProfile.ValidateStored(loopback with { SchemaVersion = OpenAICompatibleProviderProfile.CurrentSchemaVersion + 1 }); throw new InvalidOperationException("Future schema was accepted."); }
        catch (ProviderProfileException error) when (error.Reason == ProviderProfileValidationError.UnsupportedSchemaVersion) { }
    }

    public static void HktProfileDerivesEndpointAndUsesApiKeyHeader()
    {
        var profile = OpenAICompatibleProviderProfile.HktValidated("12345", "asr", "llm", "yue", "names", "focus on decisions");
        Equal("https://api.uat.bot-builder.pccw.com/v1/groups/12345/openai", profile.BaseUrl);
        Equal("12345", profile.GroupId!);
        if (profile.ProviderKind != AIProviderKind.HktGenAI) throw new InvalidOperationException("HKT provider kind was not retained.");
        var header = ProviderRequestAuthentication.Header(profile, "secret")
            ?? throw new InvalidOperationException("HKT authentication header was not created.");
        Equal("X-API-KEY", header.Key); Equal("secret", header.Value);
        try { _ = OpenAICompatibleProviderProfile.HktValidated("group-a", "asr", "llm", "", ""); throw new InvalidOperationException("Invalid HKT group ID was accepted."); }
        catch (ProviderProfileException error) when (error.Reason == ProviderProfileValidationError.InvalidHktGroupId) { }
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

    public static void ProviderProfilesAndKeysRemainIndependent()
    {
        using var root = new TestRoot();
        var profilePath = Path.Combine(root.Path, "profile.json");
        var keys = new FakeKeyStore();
        var repository = new OpenAICompatibleProviderRepository(
            new JsonOpenAICompatibleProviderProfileStore(profilePath),
            keys);
        var generic = OpenAICompatibleProviderProfile.Validated(
            "https://generic.example", "generic-asr", "generic-llm", "yue", "generic prompt", "generic MI");
        var hkt = OpenAICompatibleProviderProfile.HktValidated(
            "42", "hkt-asr", "hkt-llm", "en", "hkt prompt", "hkt MI");

        repository.SaveAsync(generic, "generic-key").GetAwaiter().GetResult();
        repository.SaveAsync(hkt, "hkt-key").GetAwaiter().GetResult();

        Equal("generic-asr", repository.LoadProfileAsync(AIProviderKind.OpenAICompatible).GetAwaiter().GetResult()!.AsrModel);
        Equal("hkt-asr", repository.LoadProfileAsync(AIProviderKind.HktGenAI).GetAwaiter().GetResult()!.AsrModel);
        if (repository.LoadProfileAsync().GetAwaiter().GetResult()!.ProviderKind != AIProviderKind.HktGenAI)
            throw new InvalidOperationException("The last saved provider was not retained as active.");
        Equal("generic-key", repository.SnapshotAsync(generic).GetAwaiter().GetResult().ApiKey!);
        Equal("hkt-key", repository.SnapshotAsync(hkt).GetAwaiter().GetResult().ApiKey!);

        repository.ClearApiKeyAsync(AIProviderKind.HktGenAI).GetAwaiter().GetResult();
        if (repository.HasApiKeyAsync(AIProviderKind.HktGenAI).GetAwaiter().GetResult())
            throw new InvalidOperationException("The HKT key was not removed.");
        if (!repository.HasApiKeyAsync(AIProviderKind.OpenAICompatible).GetAwaiter().GetResult())
            throw new InvalidOperationException("Removing the HKT key also removed the generic key.");
        if (File.ReadAllText(profilePath).Contains("hkt-asr", StringComparison.Ordinal) ||
            !File.Exists(Path.Combine(root.Path, "profile.hkt.json")))
            throw new InvalidOperationException("Provider profiles did not remain in independent files.");
    }

    private static void Reject(string baseUrl, ProviderProfileValidationError expected)
    {
        try { _ = OpenAICompatibleProviderProfile.Validated(baseUrl, "asr", "llm", "", ""); throw new InvalidOperationException($"{baseUrl} was accepted."); }
        catch (ProviderProfileException error) when (error.Reason == expected) { }
    }
    private static void Equal(string expected, string actual) { if (!string.Equals(expected, actual, StringComparison.Ordinal)) throw new InvalidOperationException($"Expected '{expected}', got '{actual}'."); }
    private sealed class FakeKeyStore : IOpenAICompatibleApiKeyStore
    {
        private readonly Dictionary<AIProviderKind, string> keys = [];
        public Task<string?> ReadAsync(CancellationToken cancellationToken = default) =>
            ReadAsync(AIProviderKind.OpenAICompatible, cancellationToken);
        public Task<string?> ReadAsync(AIProviderKind kind, CancellationToken cancellationToken = default) =>
            Task.FromResult(keys.GetValueOrDefault(kind));
        public Task WriteAsync(string apiKey, CancellationToken cancellationToken = default) =>
            WriteAsync(AIProviderKind.OpenAICompatible, apiKey, cancellationToken);
        public Task WriteAsync(AIProviderKind kind, string apiKey, CancellationToken cancellationToken = default)
        {
            keys[kind] = apiKey;
            return Task.CompletedTask;
        }
        public Task ClearAsync(CancellationToken cancellationToken = default) =>
            ClearAsync(AIProviderKind.OpenAICompatible, cancellationToken);
        public Task ClearAsync(AIProviderKind kind, CancellationToken cancellationToken = default)
        {
            keys.Remove(kind);
            return Task.CompletedTask;
        }
    }
    private sealed class TestRoot : IDisposable
    {
        public TestRoot() { Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "teams-recorder-ai-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(Path); }
        public string Path { get; }
        public void Dispose() { try { Directory.Delete(Path, true); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
    }
}
