using System.Text.Json.Serialization;

namespace TeamsRecorder.Windows.Application.AI;

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum AIProviderKind { OpenAICompatible, HktGenAI }

/// <summary>
/// The versioned, non-secret part of an OpenAI-compatible provider setting.
/// API credentials deliberately live in a separate per-user DPAPI store.
/// </summary>
public sealed record OpenAICompatibleProviderProfile
{
    public const int CurrentSchemaVersion = 3;
    public const string HktBaseUrlPrefix = "https://api.uat.bot-builder.pccw.com/v1/groups/";
    public const string DefaultBaseUrl = "https://api.openai.com/v1";
    public const string DefaultAsrModel = "gpt-4o-transcribe";
    public const string DefaultLlmModel = "gpt-5.6-terra";

    [JsonPropertyName("schemaVersion")] public int SchemaVersion { get; init; }
    [JsonPropertyName("providerKind")] public AIProviderKind ProviderKind { get; init; } = AIProviderKind.OpenAICompatible;
    [JsonPropertyName("baseURL")] public string BaseUrl { get; init; } = string.Empty;
    [JsonPropertyName("groupID")] public string? GroupId { get; init; }
    [JsonPropertyName("asrModel")] public string AsrModel { get; init; } = string.Empty;
    [JsonPropertyName("llmModel")] public string LlmModel { get; init; } = string.Empty;
    [JsonPropertyName("language")] public string Language { get; init; } = string.Empty;
    [JsonPropertyName("prompt")] public string Prompt { get; init; } = string.Empty;
    [JsonPropertyName("meetingIntelligencePrompt")] public string MeetingIntelligencePrompt { get; init; } = string.Empty;

    public static OpenAICompatibleProviderProfile Default => Validated(
        DefaultBaseUrl, DefaultAsrModel, DefaultLlmModel, language: string.Empty, prompt: string.Empty);

    public static OpenAICompatibleProviderProfile Validated(
        string baseUrlText, string asrModel, string llmModel, string? language, string? prompt,
        string? meetingIntelligencePrompt = null)
    {
        var normalizedUrl = NormalizeBaseUrl(baseUrlText);
        var normalizedAsr = TrimRequired(asrModel, ProviderProfileValidationError.MissingAsrModel);
        var normalizedLlm = TrimRequired(llmModel, ProviderProfileValidationError.MissingLlmModel);
        return new()
        {
            SchemaVersion = CurrentSchemaVersion,
            ProviderKind = AIProviderKind.OpenAICompatible,
            BaseUrl = normalizedUrl,
            GroupId = null,
            AsrModel = normalizedAsr,
            LlmModel = normalizedLlm,
            Language = language?.Trim() ?? string.Empty,
            Prompt = prompt?.Trim() ?? string.Empty,
            MeetingIntelligencePrompt = ValidateMeetingIntelligencePrompt(meetingIntelligencePrompt)
        };
    }

    public static OpenAICompatibleProviderProfile ValidateStored(OpenAICompatibleProviderProfile value)
    {
        ArgumentNullException.ThrowIfNull(value);
        if (value.SchemaVersion is not (1 or 2 or CurrentSchemaVersion))
            throw new ProviderProfileException(ProviderProfileValidationError.UnsupportedSchemaVersion);
        var meetingPrompt = value.SchemaVersion == 1 ? string.Empty : value.MeetingIntelligencePrompt;
        if (value.SchemaVersion < 3 || value.ProviderKind == AIProviderKind.OpenAICompatible)
            return Validated(value.BaseUrl, value.AsrModel, value.LlmModel, value.Language, value.Prompt, meetingPrompt);
        return HktValidated(value.GroupId ?? string.Empty, value.AsrModel, value.LlmModel,
            value.Language, value.Prompt, meetingPrompt);
    }

    public static OpenAICompatibleProviderProfile HktValidated(
        string groupId,
        string asrModel,
        string llmModel,
        string? language,
        string? prompt,
        string? meetingIntelligencePrompt = null)
    {
        var normalizedGroupId = groupId.Trim();
        if (normalizedGroupId.Length is < 1 or > 32 || normalizedGroupId.Any(character => character is < '0' or > '9'))
            throw new ProviderProfileException(ProviderProfileValidationError.InvalidHktGroupId);
        return new()
        {
            SchemaVersion = CurrentSchemaVersion,
            ProviderKind = AIProviderKind.HktGenAI,
            BaseUrl = HktBaseUrlPrefix + normalizedGroupId + "/openai",
            GroupId = normalizedGroupId,
            AsrModel = TrimRequired(asrModel, ProviderProfileValidationError.MissingAsrModel),
            LlmModel = TrimRequired(llmModel, ProviderProfileValidationError.MissingLlmModel),
            Language = language?.Trim() ?? string.Empty,
            Prompt = prompt?.Trim() ?? string.Empty,
            MeetingIntelligencePrompt = ValidateMeetingIntelligencePrompt(meetingIntelligencePrompt),
        };
    }

    private static string ValidateMeetingIntelligencePrompt(string? value)
    {
        var prompt = value?.Trim() ?? string.Empty;
        if (prompt.Length > 16_384 || prompt.Any(character => character == '\0'))
            throw new ProviderProfileException(ProviderProfileValidationError.InvalidMeetingIntelligencePrompt);
        return prompt;
    }

    private static string TrimRequired(string? value, ProviderProfileValidationError error)
    {
        var trimmed = value?.Trim();
        if (string.IsNullOrWhiteSpace(trimmed)) throw new ProviderProfileException(error);
        return trimmed;
    }

    private static string NormalizeBaseUrl(string? value)
    {
        if (!Uri.TryCreate(value?.Trim(), UriKind.Absolute, out var uri) || string.IsNullOrWhiteSpace(uri.Host))
            throw new ProviderProfileException(ProviderProfileValidationError.InvalidBaseUrl);
        if (!string.IsNullOrEmpty(uri.UserInfo) || !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment))
            throw new ProviderProfileException(ProviderProfileValidationError.UnsupportedUrlComponents);
        if (!uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) &&
            !(uri.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase) && IsLoopback(uri.Host)))
            throw new ProviderProfileException(ProviderProfileValidationError.InsecureRemoteUrl);

        var path = uri.AbsolutePath.TrimEnd('/');
        if (string.IsNullOrEmpty(path)) path = "/v1";
        else if (!path.EndsWith("/v1", StringComparison.OrdinalIgnoreCase)) path += "/v1";
        var builder = new UriBuilder(uri) { Scheme = uri.Scheme.ToLowerInvariant(), Host = uri.Host.ToLowerInvariant(), Path = path, Query = string.Empty, Fragment = string.Empty };
        return builder.Uri.AbsoluteUri.TrimEnd('/');
    }

    private static bool IsLoopback(string host) =>
        host.Equals("localhost", StringComparison.OrdinalIgnoreCase) || host == "::1" ||
        (System.Net.IPAddress.TryParse(host, out var address) && System.Net.IPAddress.IsLoopback(address));
}

public enum ProviderProfileValidationError
{
    InvalidBaseUrl,
    UnsupportedUrlComponents,
    InsecureRemoteUrl,
    MissingAsrModel,
    MissingLlmModel,
    InvalidMeetingIntelligencePrompt,
    InvalidHktGroupId,
    UnsupportedSchemaVersion
}

/// <summary>Safe-to-display validation failure; it intentionally contains no submitted URL or credential.</summary>
public sealed class ProviderProfileException(ProviderProfileValidationError reason) : InvalidOperationException(BuildMessage(reason))
{
    public ProviderProfileValidationError Reason { get; } = reason;
    private static string BuildMessage(ProviderProfileValidationError reason) => reason switch
    {
        ProviderProfileValidationError.InvalidBaseUrl => "Enter a valid API base URL.",
        ProviderProfileValidationError.UnsupportedUrlComponents => "The API URL cannot contain credentials, a query, or a fragment.",
        ProviderProfileValidationError.InsecureRemoteUrl => "Remote providers must use HTTPS.",
        ProviderProfileValidationError.MissingAsrModel => "Enter an ASR model identifier.",
        ProviderProfileValidationError.MissingLlmModel => "Enter an LLM model identifier.",
        ProviderProfileValidationError.InvalidMeetingIntelligencePrompt => "The meeting intelligence prompt is too large or invalid.",
        ProviderProfileValidationError.InvalidHktGroupId => "Enter an HKT group ID containing 1 to 32 digits.",
        _ => "This provider profile version is not supported."
    };
}
