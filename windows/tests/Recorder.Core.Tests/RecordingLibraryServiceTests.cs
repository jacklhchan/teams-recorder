using Recorder.Core;
using TeamsRecorder.Windows.Application.Library;
using TeamsRecorder.Windows.Application.Recovery;
using TeamsRecorder.Windows.Application.Storage;

internal static class RecordingLibraryServiceTests
{
    public static void StartupRecoveryRefreshesLibraryAndMetadataEditsRoundTrip()
    {
        using var root = new TestRoot();
        var storage = new SessionStorageService(root.Path);
        var plan = storage.CreateSessionPlan(RecordingSessionKind.Manual);
        WriteM4a(Path.Combine(plan.FolderPath, RecordingSessionLayout.PartialAudioFileName));
        var library = new RecordingLibraryService(storage);

        var startup = library.RecoverAtStartupAsync().GetAwaiter().GetResult();
        if (!startup.RecoveryResults.Single(item => item.FolderPath == plan.FolderPath).Recovered ||
            startup.Sessions.Count != 1 || !File.Exists(plan.FinalAudioPath))
        {
            throw new InvalidOperationException("Startup recovery did not refresh the discoverable recording library.");
        }

        var updated = library.UpdateMetadataAsync(plan.FolderPath, "  Recovered call  ", ["Support"], true)
            .GetAwaiter().GetResult();
        if (updated.Title != "Recovered call" || !updated.IsFavorite || updated.Tags.Single() != "Support" ||
            library.ListSessions().Single().Metadata.Title != "Recovered call")
        {
            throw new InvalidOperationException("Library metadata edits did not round trip through storage.");
        }
    }

    public static void RecycleRequiresConfirmationAndFailedStartCleanupPreservesEvidence()
    {
        using var root = new TestRoot();
        var storage = new SessionStorageService(root.Path);
        var library = new RecordingLibraryService(storage);
        var plan = storage.CreateSessionPlan(RecordingSessionKind.Manual);

        if (!library.CleanupFailedStart(plan) || Directory.Exists(plan.FolderPath))
        {
            throw new InvalidOperationException("The library did not clean an empty failed-start allocation.");
        }

        var evidence = storage.CreateSessionPlan(RecordingSessionKind.Manual);
        File.WriteAllBytes(evidence.BackupAudioPath, [1, 2, 3]);
        if (library.CleanupFailedStart(evidence) || !File.Exists(evidence.BackupAudioPath))
        {
            throw new InvalidOperationException("The library removed failed-start recovery evidence.");
        }

        var completed = storage.CreateSessionPlan(RecordingSessionKind.Manual);
        File.WriteAllBytes(completed.BackupAudioPath, [1, 2, 3]);
        storage.PublishCompletedMediaAsync(completed).GetAwaiter().GetResult();
        Throws<InvalidOperationException>(() => library.RecycleSession(completed.FolderPath, userConfirmed: false));
        if (!Directory.Exists(completed.FolderPath))
        {
            throw new InvalidOperationException("An unconfirmed recycle request removed a session.");
        }
    }

    public static void LegacyRootM4aFilesRemainDiscoverableAndPlaybackOnly()
    {
        using var root = new TestRoot();
        var legacyAudio = Path.Combine(root.Path, "teams-test-call-20260729-1733.m4a");
        WriteM4a(legacyAudio);

        var library = new RecordingLibraryService(new SessionStorageService(root.Path));
        var item = library.ListSessions().Single();
        if (item.IsManaged || item.AudioPath != legacyAudio || item.Metadata.Title != "teams-test-call-20260729-1733")
        {
            throw new InvalidOperationException("A legacy root M4A was not exposed as a playback-only library item.");
        }
    }

    private static void WriteM4a(string path)
    {
        using var stream = File.Create(path);
        WriteBox("ftyp", 12);
        WriteBox("moov", 8);
        void WriteBox(string type, int size)
        {
            stream.WriteByte((byte)(size >> 24));
            stream.WriteByte((byte)(size >> 16));
            stream.WriteByte((byte)(size >> 8));
            stream.WriteByte((byte)size);
            stream.Write(System.Text.Encoding.ASCII.GetBytes(type));
            for (var index = 8; index < size; index++) stream.WriteByte(0);
        }
    }

    private static void Throws<TException>(Action action) where TException : Exception
    {
        try { action(); }
        catch (TException) { return; }
        throw new InvalidOperationException($"Expected {typeof(TException).Name}.");
    }

    private sealed class TestRoot : IDisposable
    {
        public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "recorder-library-tests", Guid.NewGuid().ToString("N"));
        public TestRoot() => Directory.CreateDirectory(Path);
        public void Dispose() { if (Directory.Exists(Path)) Directory.Delete(Path, true); }
    }
}
