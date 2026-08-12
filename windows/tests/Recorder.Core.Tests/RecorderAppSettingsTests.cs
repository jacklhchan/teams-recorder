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
            SelectedApplicationExecutable = "custom-recorder-target",
            LocalTeamsHeuristicAutoStartEnabled = true,
            FollowTeamsMuteEnabled = true,
        }).GetAwaiter().GetResult();

        var loaded = store.LoadAsync().GetAwaiter().GetResult()
            ?? throw new InvalidOperationException("Expected saved settings.");
        if (loaded.SchemaVersion != RecorderAppSettings.CurrentSchemaVersion ||
            loaded.OutputFolder != Path.GetFullPath(expectedFolder) ||
            loaded.RenderEndpointId != "render-id" || loaded.MicrophoneEndpointId != "mic-id" ||
            loaded.CaptureSource != RecorderPersistedCaptureSource.SelectedApplication ||
            loaded.SelectedApplicationExecutable != "custom-recorder-target.exe" ||
            loaded.TeamsMuteSyncEnabled || !loaded.TeamsAutomaticRecordingEnabled ||
            !loaded.LocalTeamsHeuristicAutoStartEnabled || !loaded.FollowTeamsMuteEnabled)
            throw new InvalidOperationException("Public app settings did not round trip.");

        var json = File.ReadAllText(path);
        if (json.Contains("apiKey", StringComparison.OrdinalIgnoreCase) || json.Contains("token", StringComparison.OrdinalIgnoreCase) ||
            json.Contains("processId", StringComparison.OrdinalIgnoreCase) || json.Contains("windowTitle", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("App settings must not contain credentials.");
    }

    public static void PreservesNoMicrophoneAndRejectsUnsafeFutureSettings()
    {
        if (new RecorderAppSettings().RecordMicrophone)
            throw new InvalidOperationException("First-run settings must default to no microphone.");

        var noMicrophone = RecorderAppSettings.Validate(new RecorderAppSettings
        {
            RecordMicrophone = false,
            MicrophoneEndpointId = "must-not-survive",
        });
        if (noMicrophone.MicrophoneEndpointId is not null)
            throw new InvalidOperationException("Explicit no-microphone choice was not preserved.");

        var retiredAutomaticFlag = RecorderAppSettings.Validate(new RecorderAppSettings
        {
            TeamsAutomaticRecordingEnabled = true,
        });
        if (retiredAutomaticFlag.TeamsAutomaticRecordingEnabled ||
            retiredAutomaticFlag.LocalTeamsHeuristicAutoStartEnabled)
            throw new InvalidOperationException("The retired Teams API flag must not grant local monitoring consent.");

        using var root = new TestRoot();
        var legacyPath = Path.Combine(root.Path, "legacy-app-settings.json");
        File.WriteAllText(legacyPath, "{\"schemaVersion\":2,\"recordMicrophone\":true,\"teamsMuteSyncEnabled\":true,\"teamsAutomaticRecordingEnabled\":true}");
        var legacy = new JsonRecorderAppSettingsStore(legacyPath).LoadAsync().GetAwaiter().GetResult()
            ?? throw new InvalidOperationException("Expected legacy settings.");
        if (legacy.TeamsMuteSyncEnabled || legacy.TeamsAutomaticRecordingEnabled ||
            legacy.LocalTeamsHeuristicAutoStartEnabled || legacy.FollowTeamsMuteEnabled)
            throw new InvalidOperationException("Legacy settings must require fresh local-monitoring consent.");

        var schemaThree = RecorderAppSettings.Validate(new RecorderAppSettings
        {
            SchemaVersion = 3,
            LocalTeamsHeuristicAutoStartEnabled = true,
            FollowTeamsMuteEnabled = true,
        });
        if (!schemaThree.LocalTeamsHeuristicAutoStartEnabled || schemaThree.FollowTeamsMuteEnabled)
            throw new InvalidOperationException("Schema 3 must preserve auto-recording consent but require fresh mute-follow consent.");

        Throws<RecorderAppSettingsException>(() => RecorderAppSettings.Validate(new RecorderAppSettings { SchemaVersion = 5 }));
        Throws<RecorderAppSettingsException>(() => RecorderAppSettings.Validate(new RecorderAppSettings { RenderEndpointId = "unsafe\u0001id" }));
        Throws<RecorderAppSettingsException>(() => RecorderAppSettings.Validate(new RecorderAppSettings
        {
            CaptureSource = RecorderPersistedCaptureSource.SelectedApplication,
            SelectedApplicationExecutable = @"C:\\Program Files\\target.exe",
        }));
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
