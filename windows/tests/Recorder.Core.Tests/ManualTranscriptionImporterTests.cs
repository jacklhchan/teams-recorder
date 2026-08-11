using System.Text.Json.Nodes;
using Recorder.Core;
using TeamsRecorder.Windows.Application.Library;
using TeamsRecorder.Windows.Application.Storage;
using TeamsRecorder.Windows.Application.Transcription;

internal static class ManualTranscriptionImporterTests
{
    public static void ImportedAudioBecomesOwnedPlayableTranscriptionMedia()
    {
        using var workspace = new TemporaryWorkspace();
        var source = Path.Combine(workspace.Path, "Quarterly Review 2026.wav");
        File.WriteAllBytes(source, [0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4]);
        var sessions = Path.Combine(workspace.Path, "sessions");
        var storage = CreateStorage(sessions);
        var library = new RecordingLibraryService(storage);

        var imported = library.ImportAudioForTranscriptionAsync(source).GetAwaiter().GetResult();

        if (!File.Exists(source) || !File.Exists(imported.MediaPath) ||
            !File.ReadAllBytes(source).SequenceEqual(File.ReadAllBytes(imported.MediaPath)))
            throw new InvalidOperationException("Import did not preserve the source and create an owned copy.");
        if (Path.GetFileName(imported.MediaPath) != "recording.wav" || imported.DisplayName != "Quarterly Review 2026")
            throw new InvalidOperationException("Import did not preserve the supported container and source-stem display name.");

        var item = storage.ListSessions().Single();
        if (!item.IsManaged || item.Metadata.Source != "imported" || item.Metadata.Title != "Quarterly Review 2026" ||
            item.Metadata.Document["titleOrigin"]?.GetValue<string>() != "unset" ||
            !string.Equals(item.MediaPath, imported.MediaPath, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Imported audio did not appear as an owned imported library session.");

        var resolved = RecordingSessionAsrMediaResolver.Resolve(imported.Session);
        if (!string.Equals(resolved.Path, imported.MediaPath, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The ASR resolver did not accept the explicit imported audio copy.");
    }

    public static void ImportsAreUniqueAndRequireExplicitImportedMetadata()
    {
        using var workspace = new TemporaryWorkspace();
        var source = Path.Combine(workspace.Path, "Customer Discovery.mp3");
        File.WriteAllBytes(source, [1, 2, 3, 4]);
        var sessions = Path.Combine(workspace.Path, "sessions");
        var storage = CreateStorage(sessions);
        var importer = new ManualTranscriptionImporter();

        var first = importer.ImportAsync(storage, source).GetAwaiter().GetResult();
        var second = importer.ImportAsync(storage, source).GetAwaiter().GetResult();
        if (string.Equals(first.Session.FolderPath, second.Session.FolderPath, StringComparison.OrdinalIgnoreCase) ||
            !File.Exists(first.MediaPath) || !File.Exists(second.MediaPath))
            throw new InvalidOperationException("Imports in the same timestamp reused or overwrote an owned folder.");

        var manual = storage.CreateSessionPlan(RecordingSessionKind.Manual);
        var untrusted = Path.Combine(manual.FolderPath, "recording.wav");
        File.WriteAllBytes(untrusted, [9, 8, 7]);
        var metadata = RecordingInfoJson.CreateAudioOnly(
            new JsonObject { ["source"] = "manual" },
            "Not imported",
            RecordingRecoveryState.None,
            RecordingSessionKind.Manual);
        File.WriteAllText(manual.MetadataPath, metadata.Document.ToJsonString());

        if (storage.ListSessions().Any(item => string.Equals(item.FolderPath, manual.FolderPath, StringComparison.OrdinalIgnoreCase)))
            throw new InvalidOperationException("A manually dropped WAV bypassed the explicit import gate.");
        try
        {
            RecordingSessionAsrMediaResolver.Resolve(manual);
            throw new InvalidOperationException("ASR accepted non-imported arbitrary session media.");
        }
        catch (IOException) { }

        var unsupported = Path.Combine(workspace.Path, "notes.txt");
        File.WriteAllText(unsupported, "not audio");
        try
        {
            importer.ImportAsync(storage, unsupported).GetAwaiter().GetResult();
            throw new InvalidOperationException("An unsupported extension was imported.");
        }
        catch (IOException) { }
    }

    private static SessionStorageService CreateStorage(string path) => new(
        path,
        capacityProvider: new FixedCapacity(),
        clock: new FixedClock());

    private sealed class FixedCapacity : IStorageCapacityProvider
    {
        public long? GetAvailableBytes(string rootPath) => RecordingStoragePolicy.WarningBytes;
    }

    private sealed class FixedClock : IClock
    {
        public DateTimeOffset UtcNow => new(2026, 8, 12, 12, 0, 0, TimeSpan.Zero);
    }

    private sealed class TemporaryWorkspace : IDisposable
    {
        public string Path { get; } = System.IO.Path.Combine(
            System.IO.Path.GetTempPath(),
            "teams-recorder-import-" + Guid.NewGuid().ToString("N"));

        public TemporaryWorkspace() => Directory.CreateDirectory(Path);

        public void Dispose()
        {
            try { Directory.Delete(Path, recursive: true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
