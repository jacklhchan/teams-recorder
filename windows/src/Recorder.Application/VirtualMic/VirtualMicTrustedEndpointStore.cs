using System.Text.Json;
using System.Text.Json.Serialization;

namespace TeamsRecorder.Windows.Application.VirtualMic;

public sealed class VirtualMicTrustedEndpointStore(string? path = null)
{
    public static string DefaultPath { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Teams Recorder",
        "virtual-microphone.json");

    private readonly string path = path ?? DefaultPath;

    public async Task<VirtualMicTrustedEndpointIdentity?> LoadAsync(
        CancellationToken cancellationToken = default)
    {
        if (!File.Exists(path)) return null;
        await using var input = File.OpenRead(path);
        var value = await JsonSerializer.DeserializeAsync<PairingDocument>(
            input, cancellationToken: cancellationToken).ConfigureAwait(false);
        if (value is null || value.SchemaVersion != 1)
            throw new InvalidDataException("The virtual microphone pairing file is invalid.");
        var identity = new VirtualMicTrustedEndpointIdentity(
            value.EndpointId, value.HardwareId, value.FriendlyName);
        if (!identity.IsWellFormed)
            throw new InvalidDataException("The virtual microphone pairing identity is not trusted.");
        return identity;
    }

    public async Task SaveAsync(
        VirtualMicTrustedEndpointIdentity identity,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(identity);
        if (!identity.IsWellFormed)
            throw new ArgumentException("The virtual microphone identity is malformed.", nameof(identity));
        var folder = Path.GetDirectoryName(path) ??
            throw new InvalidOperationException("The virtual microphone pairing path has no parent.");
        Directory.CreateDirectory(folder);
        var temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            await using (var output = File.Create(temporary))
            {
                await JsonSerializer.SerializeAsync(output, new PairingDocument
                {
                    EndpointId = identity.EndpointId,
                    HardwareId = identity.HardwareId,
                    FriendlyName = identity.FriendlyName,
                }, cancellationToken: cancellationToken).ConfigureAwait(false);
            }
            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            try { if (File.Exists(temporary)) File.Delete(temporary); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private sealed record PairingDocument
    {
        [JsonPropertyName("schemaVersion")] public int SchemaVersion { get; init; } = 1;
        [JsonPropertyName("endpointId")] public required string EndpointId { get; init; }
        [JsonPropertyName("hardwareId")] public required string HardwareId { get; init; }
        [JsonPropertyName("friendlyName")] public required string FriendlyName { get; init; }
    }
}
