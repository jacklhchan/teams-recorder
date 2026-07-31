using TeamsRecorder.Windows.Application.Settings;

internal static class RecorderAppSettingsTests
{
    public static void RoundTripsPublicChoicesWithoutSecrets()
    {
        using var root = new TestRoot();
        var path = Path.Combine(root.Path, "app-settings.json");
        var store = new JsonRecorderAppSettingsStore(path);
        var expectedFolder = Path.Combine(root.Path, "Sessions");
        store.SaveAsync(new RecorderAppSettings
        {
            OutputFolder = expectedFolder,
            RenderEndpointId = "render-id",
            RecordMicrophone = true,
            MicrophoneEndpointId = "mic-id",
            CaptureSource = RecorderPersistedCaptureSource.SelectedApplication,
            TeamsMuteSyncEnabled = true,
            TeamsAutomaticRecordingEnabled = true,
        }).GetAwaiter().GetResult();

        var loaded = store.LoadAsync().GetAwaiter().GetResult()
            ?? throw new InvalidOperationException("Expected saved settings.");
        if (loaded.SchemaVersion != RecorderAppSettings.CurrentSchemaVersion ||
            loaded.OutputFolder != Path.GetFullPath(expectedFolder) ||
            loaded.RenderEndpointId != "render-id" || loaded.MicrophoneEndpointId != "mic-id" ||
            loaded.CaptureSource != RecorderPersistedCaptureSource.SelectedApplication ||
            !loaded.TeamsMuteSyncEnabled || !loaded.TeamsAutomaticRecordingEnabled)
            throw new InvalidOperationException("Public app settings did not round trip.");

        var json = File.ReadAllText(path);
        if (json.Contains("apiKey", StringComparison.OrdinalIgnoreCase) || json.Contains("token", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("App settings must not contain credentials.");
    }

    public static void PreservesNoMicrophoneAndRejectsUnsafeFutureSettings()
    {
        var noMicrophone = RecorderAppSettings.Validate(new RecorderAppSettings
        {
            RecordMicrophone = false,
            MicrophoneEndpointId = "must-not-survive",
        });
        if (noMicrophone.MicrophoneEndpointId is not null)
            throw new InvalidOperationException("Explicit no-microphone choice was not preserved.");

        var automaticWithoutTeams = RecorderAppSettings.Validate(new RecorderAppSettings
        {
            TeamsMuteSyncEnabled = false,
            TeamsAutomaticRecordingEnabled = true,
        });
        if (automaticWithoutTeams.TeamsAutomaticRecordingEnabled)
            throw new InvalidOperationException("Automatic recording must require the Teams opt-in.");

        using var root = new TestRoot();
        var legacyPath = Path.Combine(root.Path, "legacy-app-settings.json");
        File.WriteAllText(legacyPath, "{\"schemaVersion\":1,\"recordMicrophone\":true}");
        var legacy = new JsonRecorderAppSettingsStore(legacyPath).LoadAsync().GetAwaiter().GetResult()
            ?? throw new InvalidOperationException("Expected legacy settings.");
        if (legacy.TeamsMuteSyncEnabled || legacy.TeamsAutomaticRecordingEnabled)
            throw new InvalidOperationException("Legacy settings must default Teams opt-ins to disabled.");

        Throws<RecorderAppSettingsException>(() => RecorderAppSettings.Validate(new RecorderAppSettings { SchemaVersion = 2 }));
        Throws<RecorderAppSettingsException>(() => RecorderAppSettings.Validate(new RecorderAppSettings { RenderEndpointId = "unsafe\u0001id" }));
    }

    private static void Throws<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }

    private sealed class TestRoot : IDisposable
    {
        public TestRoot()
        {
            Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "teams-recorder-settings-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Path);
        }

        public string Path { get; }

        public void Dispose()
        {
            try { Directory.Delete(Path, recursive: true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
