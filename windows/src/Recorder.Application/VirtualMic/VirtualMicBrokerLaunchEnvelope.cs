using System.Text.Json;
using System.Text.Json.Serialization;

namespace TeamsRecorder.Windows.Application.VirtualMic;

/// <summary>
/// One-shot child-process bootstrap. It is written only to redirected stdin;
/// neither the capability token nor endpoint ID appears in argv or logs.
/// </summary>
public sealed record VirtualMicBrokerLaunchEnvelope
{
    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    [JsonPropertyName("schemaVersion")] public int SchemaVersion { get; init; } = 1;
    [JsonPropertyName("pipeName")] public required string PipeName { get; init; }
    [JsonPropertyName("endpointId")] public required string EndpointId { get; init; }
    [JsonPropertyName("hardwareId")] public required string HardwareId { get; init; }
    [JsonPropertyName("friendlyName")] public required string FriendlyName { get; init; }
    [JsonPropertyName("capabilityToken")] public required string CapabilityToken { get; init; }

    public static VirtualMicBrokerLaunchEnvelope Create(VirtualMicPcmBrokerSession session)
    {
        ArgumentNullException.ThrowIfNull(session);
        return new()
        {
            PipeName = session.PipeName,
            EndpointId = session.Identity.EndpointId,
            HardwareId = session.Identity.HardwareId,
            FriendlyName = session.Identity.FriendlyName,
            CapabilityToken = Convert.ToBase64String(session.ExportCapabilityToken()),
        };
    }

    public VirtualMicPcmBrokerSession ToSession()
    {
        if (SchemaVersion != 1)
            throw new InvalidDataException("The virtual microphone broker bootstrap version is unsupported.");
        byte[] token;
        try { token = Convert.FromBase64String(CapabilityToken); }
        catch (FormatException error) { throw new InvalidDataException("The broker capability token is malformed.", error); }
        return VirtualMicPcmBrokerSession.Import(
            PipeName,
            new VirtualMicTrustedEndpointIdentity(EndpointId, HardwareId, FriendlyName),
            token);
    }

    public string Serialize() => JsonSerializer.Serialize(this, Json);

    public static VirtualMicBrokerLaunchEnvelope Parse(string value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > 8_192)
            throw new InvalidDataException("The virtual microphone broker bootstrap is missing or oversized.");
        try
        {
            return JsonSerializer.Deserialize<VirtualMicBrokerLaunchEnvelope>(value, Json)
                ?? throw new InvalidDataException("The virtual microphone broker bootstrap is empty.");
        }
        catch (JsonException error)
        {
            throw new InvalidDataException("The virtual microphone broker bootstrap is malformed.", error);
        }
    }
}
