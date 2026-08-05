using System.Text;
using System.Text.Json;

namespace TeamsRecorder.Windows.Application;

/// <summary>
/// The documented, local-only Teams desktop Third-party App API wire format.
/// This class deliberately has no tenant credentials and never issues a mute toggle.
/// A WebSocket transport can be supplied by the Windows host after its pairing and
/// credential-protection prerequisite has been validated on a real Teams client.
/// </summary>
public static class TeamsThirdPartyApi
{
    public const string Host = "127.0.0.1";
    public const int Port = 8124;
    public const string ProtocolVersion = "2.0.0";

    public static Uri CreateEndpoint(TeamsThirdPartyApiIdentity identity, string? token)
    {
        ArgumentNullException.ThrowIfNull(identity);
        var query = new List<KeyValuePair<string, string>>();
        if (!string.IsNullOrWhiteSpace(token)) query.Add(new("token", token));
        query.AddRange([
            new("protocol-version", ProtocolVersion),
            new("manufacturer", identity.Manufacturer),
            new("device", identity.Device),
            new("app", identity.App),
            new("app-version", identity.AppVersion),
        ]);
        var builder = new UriBuilder("ws", Host, Port)
        {
            Query = string.Join("&", query.Select(static pair =>
                $"{Uri.EscapeDataString(pair.Key)}={Uri.EscapeDataString(pair.Value)}")),
        };
        return builder.Uri;
    }

    public static string CreateCommand(TeamsThirdPartyApiAction action, int requestId) =>
        JsonSerializer.Serialize(new { action = action.ToWireValue(), parameters = new { }, requestId });

    public static TeamsThirdPartyApiEvent Decode(string json)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(json);
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        var requestId = TryGetInt(root, "requestId");
        if (TryGetString(root, "errorMsg") is { Length: > 0 } error) return new TeamsThirdPartyApiEvent.Error(requestId, error);
        if (TryGetString(root, "tokenRefresh") is { Length: > 0 } token) return new TeamsThirdPartyApiEvent.TokenRefresh(token);
        if (root.TryGetProperty("meetingUpdate", out var update) && update.ValueKind == JsonValueKind.Object)
        {
            var permissions = update.TryGetProperty("meetingPermissions", out var rawPermissions) ? rawPermissions : default;
            var canToggle = TryGetBool(permissions, "canToggleMute") ?? false;
            var canPair = TryGetBool(permissions, "canPair") ?? false;
            TeamsMeetingState? state = null;
            var hasMeetingState = update.TryGetProperty("meetingState", out var rawState) && rawState.ValueKind == JsonValueKind.Object;
            bool? inMeeting = null;
            bool? muted = null;
            if (hasMeetingState)
            {
                inMeeting = TryGetBool(rawState, "isInMeeting");
                muted = TryGetBool(rawState, "isMuted");
                if (inMeeting.HasValue && muted.HasValue) state = new(inMeeting.Value, muted.Value, canToggle, canPair);
            }
            return new TeamsThirdPartyApiEvent.MeetingUpdate(new(
                state,
                canToggle,
                canPair,
                HasMeetingState: hasMeetingState,
                HasIsInMeeting: inMeeting.HasValue,
                HasIsMuted: muted.HasValue));
        }
        if (TryGetString(root, "response") is { Length: > 0 } response) return new TeamsThirdPartyApiEvent.Response(requestId, response);
        return new TeamsThirdPartyApiEvent.Ignored();
    }

    private static string? TryGetString(JsonElement value, string property) =>
        value.ValueKind == JsonValueKind.Object && value.TryGetProperty(property, out var item) && item.ValueKind == JsonValueKind.String ? item.GetString() : null;
    private static bool? TryGetBool(JsonElement value, string property) =>
        value.ValueKind == JsonValueKind.Object && value.TryGetProperty(property, out var item) && (item.ValueKind is JsonValueKind.True or JsonValueKind.False) ? item.GetBoolean() : null;
    private static int? TryGetInt(JsonElement value, string property) =>
        value.TryGetProperty(property, out var item) && item.TryGetInt32(out var number) ? number : null;
}

public sealed record TeamsThirdPartyApiIdentity(string Manufacturer, string Device, string App, string AppVersion)
{
    public static TeamsThirdPartyApiIdentity Recorder(string appVersion) => new("Local Meeting Recorder", "Windows Audio Bridge", "Local Meeting Recorder", appVersion);
}

public enum TeamsThirdPartyApiAction { Pair, QueryState }
public static class TeamsThirdPartyApiActionExtensions
{
    public static string ToWireValue(this TeamsThirdPartyApiAction action) => action switch
    {
        TeamsThirdPartyApiAction.Pair => "pair",
        TeamsThirdPartyApiAction.QueryState => "query-state",
        _ => throw new ArgumentOutOfRangeException(nameof(action)),
    };
}

public sealed record TeamsMeetingState(bool IsInMeeting, bool IsMuted, bool CanToggleMute, bool CanPair);
public sealed record TeamsThirdPartyApiMeetingUpdate(
    TeamsMeetingState? State,
    bool CanToggleMute,
    bool CanPair,
    bool HasMeetingState = false,
    bool HasIsInMeeting = false,
    bool HasIsMuted = false);
public abstract record TeamsThirdPartyApiEvent
{
    /// <summary>
    /// A raw meeting payload is authoritative only when the transport confirms that the active
    /// socket was opened with a persisted pairing credential.  Decoder callers use the default
    /// false value; the WebSocket client sets it for authenticated connections before publishing.
    /// </summary>
    public sealed record MeetingUpdate(TeamsThirdPartyApiMeetingUpdate Update, bool IsPairingAuthenticated = false) : TeamsThirdPartyApiEvent;
    public sealed record TokenRefresh(string Token) : TeamsThirdPartyApiEvent;
    public sealed record Response(int? RequestId, string Message) : TeamsThirdPartyApiEvent;
    public sealed record Error(int? RequestId, string Message) : TeamsThirdPartyApiEvent;
    public sealed record Ignored : TeamsThirdPartyApiEvent;
}
