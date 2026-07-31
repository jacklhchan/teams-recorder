using System.Text.Json;
using System.Text.Json.Serialization;

namespace TeamsRecorder.Windows.Application.Settings;

/// <summary>
/// Non-secret, per-user choices restored when the WinUI app starts again.
/// Device identifiers are retained only to restore an explicit choice; a missing
/// device remains visibly unavailable and is never replaced with another device.
/// </summary>
public sealed record RecorderAppSettings
{
    public const int CurrentSchemaVersion = 1;

    [JsonPropertyName("schemaVersion")] public int SchemaVersion { get; init; } = CurrentSchemaVersion;
    [JsonPropertyName("outputFolder")] public string? OutputFolder { get; init; }
    [JsonPropertyName("renderEndpointId")] public string? RenderEndpointId { get; init; }
    [JsonPropertyName("recordMicrophone")] public bool RecordMicrophone { get; init; } = true;
    [JsonPropertyName("microphoneEndpointId")] public string? MicrophoneEndpointId { get; init; }
    [JsonPropertyName("captureSource")] public RecorderPersistedCaptureSource CaptureSource { get; init; } = RecorderPersistedCaptureSource.SystemLoopback;
    // These are local opt-ins only. Pairing material remains in the separate DPAPI store.
    [JsonPropertyName("teamsMuteSyncEnabled")] public bool TeamsMuteSyncEnabled { get; init; }
    [JsonPropertyName("teamsAutomaticRecordingEnabled")] public bool TeamsAutomaticRecordingEnabled { get; init; }

    public static RecorderAppSettings Validate(RecorderAppSettings value)
    {
        ArgumentNullException.ThrowIfNull(value);
        if (value.SchemaVersion != CurrentSchemaVersion)
            throw new RecorderAppSettingsException("The saved app settings version is not supported.");
        if (!Enum.IsDefined(value.CaptureSource))
            throw new RecorderAppSettingsException("The saved capture source is not supported.");

        return value with
        {
            SchemaVersion = CurrentSchemaVersion,
            OutputFolder = NormalizeFolder(value.OutputFolder),
            RenderEndpointId = NormalizeIdentifier(value.RenderEndpointId),
            MicrophoneEndpointId = value.RecordMicrophone ? NormalizeIdentifier(value.MicrophoneEndpointId) : null,
            // Automatic recording has no meaning without its separately opted-in Teams connection.
            TeamsAutomaticRecordingEnabled = value.TeamsMuteSyncEnabled && value.TeamsAutomaticRecordingEnabled,
        };
    }

    private static string? NormalizeFolder(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        try { return Path.GetFullPath(value.Trim()); }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException)
        {
            throw new RecorderAppSettingsException("The saved recording folder is invalid.");
        }
    }

    private static string? NormalizeIdentifier(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        var normalized = value.Trim();
        if (normalized.Length > 512 || normalized.Any(char.IsControl))
            throw new RecorderAppSettingsException("The saved device identifier is invalid.");
        return normalized;
    }
}

public enum RecorderPersistedCaptureSource { SystemLoopback, SelectedApplication }

public interface IRecorderAppSettingsStore
{
    Task<RecorderAppSettings?> LoadAsync(CancellationToken cancellationToken = default);
    Task SaveAsync(RecorderAppSettings settings, CancellationToken cancellationToken = default);
}

/// <summary>Atomic JSON store for public app choices. It intentionally has no API key or Teams pairing material.</summary>
public sealed class JsonRecorderAppSettingsStore(string? path = null) : IRecorderAppSettingsStore
{
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = false };
    private readonly string path = path ?? Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Teams Recorder",
        "app-settings.json");

    public async Task<RecorderAppSettings?> LoadAsync(CancellationToken cancellationToken = default)
    {
        if (!File.Exists(path)) return null;
        try
        {
            await using var input = File.OpenRead(path);
            var settings = await JsonSerializer.DeserializeAsync<RecorderAppSettings>(input, Json, cancellationToken).ConfigureAwait(false);
            return settings is null
                ? throw new RecorderAppSettingsException("The saved app settings are invalid.")
                : RecorderAppSettings.Validate(settings);
        }
        catch (RecorderAppSettingsException) { throw; }
        catch (JsonException) { throw new RecorderAppSettingsException("The saved app settings are invalid."); }
        catch (IOException) { throw new RecorderAppSettingsException("The saved app settings could not be read."); }
        catch (UnauthorizedAccessException) { throw new RecorderAppSettingsException("The saved app settings could not be read."); }
    }

    public async Task SaveAsync(RecorderAppSettings settings, CancellationToken cancellationToken = default)
    {
        var valid = RecorderAppSettings.Validate(settings);
        var folder = Path.GetDirectoryName(path) ?? throw new RecorderAppSettingsException("The app settings could not be saved.");
        var temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            Directory.CreateDirectory(folder);
            await using (var output = File.Create(temporary))
                await JsonSerializer.SerializeAsync(output, valid, Json, cancellationToken).ConfigureAwait(false);
            File.Move(temporary, path, overwrite: true);
        }
        catch (RecorderAppSettingsException) { throw; }
        catch (IOException) { throw new RecorderAppSettingsException("The app settings could not be saved."); }
        catch (UnauthorizedAccessException) { throw new RecorderAppSettingsException("The app settings could not be saved."); }
        finally
        {
            try { if (File.Exists(temporary)) File.Delete(temporary); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}

public sealed class RecorderAppSettingsException(string message) : InvalidOperationException(message);
