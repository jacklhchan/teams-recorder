using Recorder.Core;
using TeamsRecorder.Windows.Application.Library;
using TeamsRecorder.Windows.Application.Recovery;
using TeamsRecorder.Windows.Application.Storage;

internal static class RecordingLibraryServiceTests
{
    public static void StartupRecoveryRefreshesLibraryAndMetadataEditsRoundTrip()
    {
        using var root = new TestRoot();
        var audio = new AlwaysValidAudio();
        var storage = new SessionStorageService(root.Path, audioValidator: audio);
        var plan = storage.CreateSessionPlan(RecordingSessionKind.Manual);
        WriteM4a(Path.Combine(plan.FolderPath, RecordingSessionLayout.PartialAudioFileName));
        var library = new RecordingLibraryService(storage, new SessionRecoveryService(storage, audio));

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
        var storage = new SessionStorageService(root.Path, audioValidator: new AlwaysValidAudio());
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

    public static void RefreshReusesValidationForUnchangedMedia()
    {
        using var root = new TestRoot();
        var validator = new CountingAudioValidator();
        var storage = new SessionStorageService(root.Path, audioValidator: validator);
        var plans = Enumerable.Range(0, 4)
            .Select(_ => storage.CreateSessionPlan(RecordingSessionKind.Manual))
            .ToArray();
        foreach (var plan in plans) File.WriteAllBytes(plan.FinalAudioPath, [1, 2, 3]);

        if (storage.ListSessions().Count != plans.Length || validator.Count != 0)
            throw new InvalidOperationException("Initial library projection decoded historical media during startup.");
        if (storage.ListSessions().Count != plans.Length || validator.Count != 0)
            throw new InvalidOperationException("An unchanged refresh decoded the complete library again.");

        File.AppendAllBytes(plans[0].FinalAudioPath, [4]);
        if (storage.ListSessions().Count != plans.Length || validator.Count != 0)
            throw new InvalidOperationException("A changed library row activated a decoder before a user action.");
    }

    public static void RefreshReusesValidationAcrossApplicationRestarts()
    {
        using var root = new TestRoot();
        var plans = Enumerable.Range(0, 4)
            .Select(_ => new SessionStorageService(root.Path, audioValidator: new AlwaysValidAudio())
                .CreateSessionPlan(RecordingSessionKind.Manual))
            .ToArray();
        foreach (var plan in plans) File.WriteAllBytes(plan.FinalAudioPath, [1, 2, 3]);

        var initialValidator = new CountingAudioValidator();
        var initial = new SessionStorageService(root.Path, audioValidator: initialValidator);
        if (initial.ListSessions().Count != plans.Length || initialValidator.Count != 0)
            throw new InvalidOperationException("The initial application process decoded its historical library.");

        var restartedValidator = new CountingAudioValidator();
        var restarted = new SessionStorageService(root.Path, audioValidator: restartedValidator);
        if (restarted.ListSessions().Count != plans.Length || restartedValidator.Count != 0)
            throw new InvalidOperationException("An unchanged application restart decoded the complete library again.");

        File.AppendAllBytes(plans[0].FinalAudioPath, [4]);
        var changedValidator = new CountingAudioValidator();
        var changed = new SessionStorageService(root.Path, audioValidator: changedValidator);
        if (changed.ListSessions().Count != plans.Length || changedValidator.Count != 0)
            throw new InvalidOperationException("A changed persistent fingerprint activated a decoder before playback.");

        var selected = changed.ListSessions()[1];
        var actionValidator = new CountingAudioValidator();
        var actionLibrary = new RecordingLibraryService(
            new SessionStorageService(root.Path, audioValidator: actionValidator));
        if (actionLibrary.ResolveCanonicalSession(RecordingLibrarySessionIdentity.Create(selected)) is null ||
            actionValidator.Count != 1)
        {
            throw new InvalidOperationException("A playback action trusted the persistent presentation cache instead of revalidating its target.");
        }
    }

    public static void CompletedSessionWithRetainedEvidenceSkipsRepeatedRecoveryDecode()
    {
        using var root = new TestRoot();
        var initialValidator = new CountingVideoValidator();
        var initial = new SessionStorageService(
            root.Path,
            videoValidator: initialValidator,
            audioValidator: new AlwaysValidAudio());
        var plan = initial.CreateSessionPlan(RecordingSessionKind.Meeting);
        File.WriteAllBytes(plan.FinalVideoPath, [1, 2, 3]);
        File.WriteAllBytes(plan.AudioSafetyPartialPath, [4, 5, 6]);
        File.WriteAllText(
            plan.MetadataPath,
            RecordingInfoJson.CreateVideo(
                null,
                null,
                RecordingRecoveryState.None,
                RecordingSessionKind.Meeting).Document.ToJsonString());
        if (initial.ListSessions().Count != 1 || initialValidator.Count != 0)
            throw new InvalidOperationException("A completed video publication was decoded while rebuilding the library projection.");

        var restarted = new SessionStorageService(
            root.Path,
            videoValidator: new ThrowingVideoValidator(),
            audioValidator: new ThrowingAudioValidator());
        var recovery = new SessionRecoveryService(restarted, new ThrowingAudioValidator())
            .RecoverAsync().GetAwaiter().GetResult().Single();
        if (recovery.Recovered ||
            recovery.RecoveryState != RecordingRecoveryState.None ||
            !File.Exists(plan.FinalVideoPath) ||
            !File.Exists(plan.AudioSafetyPartialPath))
        {
            throw new InvalidOperationException(
                "A completed immutable media fingerprint was decoded again or its retained evidence was modified.");
        }
    }

    public static void CanonicalResolutionValidatesOnlyTheSelectedSession()
    {
        using var root = new TestRoot();
        var listingStorage = new SessionStorageService(root.Path, audioValidator: new AlwaysValidAudio());
        var plans = Enumerable.Range(0, 5)
            .Select(_ => listingStorage.CreateSessionPlan(RecordingSessionKind.Manual))
            .ToArray();
        foreach (var plan in plans) File.WriteAllBytes(plan.FinalAudioPath, [1, 2, 3]);
        var selected = listingStorage.ListSessions()[2];
        var identity = RecordingLibrarySessionIdentity.Create(selected);

        var validator = new CountingAudioValidator();
        var resolver = new RecordingLibraryService(new SessionStorageService(root.Path, audioValidator: validator));
        var resolved = resolver.ResolveCanonicalSession(identity);
        if (resolved is null || !identity.Matches(resolved) || validator.Count != 1)
            throw new InvalidOperationException("Playback revalidation scanned more than the selected canonical session.");
    }

    public static void CanonicalVideoResolutionDecodesEachSelectedArtifactOnce()
    {
        using var root = new TestRoot();
        var listingStorage = new SessionStorageService(
            root.Path,
            videoValidator: new AlwaysValidVideo(),
            audioValidator: new AlwaysValidAudio());
        var plan = listingStorage.CreateSessionPlan(RecordingSessionKind.Meeting);
        File.WriteAllBytes(plan.FinalVideoPath, [1, 2, 3]);
        File.WriteAllBytes(plan.FinalAudioPath, [4, 5, 6]);
        File.WriteAllText(
            plan.MetadataPath,
            "{\"schemaVersion\":1,\"mediaKind\":\"video\",\"source\":\"teamsAutomatic\",\"participants\":[],\"screenIntervals\":[]}");
        var identity = RecordingLibrarySessionIdentity.Create(listingStorage.ListSessions().Single());

        var video = new CountingVideoValidator();
        var audio = new CountingAudioValidator();
        var resolver = new RecordingLibraryService(new SessionStorageService(
            root.Path,
            videoValidator: video,
            audioValidator: audio));
        var resolved = resolver.ResolveCanonicalSession(identity);

        if (resolved is null || !identity.Matches(resolved) || video.Count != 1 || audio.Count != 1)
        {
            throw new InvalidOperationException(
                $"A selected video action decoded an artifact more than once: video={video.Count}, audio={audio.Count}.");
        }
    }

    public static void NestedSessionLikeFoldersAreNeverOwned()
    {
        using var root = new TestRoot();
        var nestedParent = Path.Combine(root.Path, "foreign-container");
        var nestedSession = Path.Combine(nestedParent, "manual-20260812-120000000");
        Directory.CreateDirectory(nestedSession);
        File.WriteAllBytes(Path.Combine(nestedSession, RecordingSessionLayout.FinalAudioFileName), [1, 2, 3]);

        var library = new RecordingLibraryService(new SessionStorageService(
            root.Path,
            audioValidator: new AlwaysValidAudio()));
        if (library.ListSessions().Any(item =>
                string.Equals(item.FolderPath, nestedSession, StringComparison.OrdinalIgnoreCase)))
        {
            throw new InvalidOperationException("A nested foreign folder was treated as an owned recording session.");
        }

        Throws<InvalidOperationException>(() =>
            library.UpdateMetadataAsync(nestedSession, "must not change", [], false)
                .GetAwaiter().GetResult());
        Throws<InvalidOperationException>(() =>
            library.RecycleSession(nestedSession, userConfirmed: true));
        if (!Directory.Exists(nestedSession))
            throw new InvalidOperationException("A nested foreign folder was removed by an owned-session action.");
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

    private sealed class AlwaysValidAudio : IAudioBackupValidator
    {
        public bool IsValidNonEmptyAudio(string path) => File.Exists(path) && new FileInfo(path).Length > 0;
    }

    private sealed class AlwaysValidVideo : IVideoMediaValidator
    {
        public bool IsValidNonEmptyVideo(string path) => File.Exists(path) && new FileInfo(path).Length > 0;
    }

    private sealed class CountingVideoValidator : IVideoMediaValidator
    {
        public int Count { get; private set; }

        public bool IsValidNonEmptyVideo(string path)
        {
            Count++;
            return File.Exists(path) && new FileInfo(path).Length > 0;
        }
    }

    private sealed class CountingAudioValidator : IAudioBackupValidator
    {
        public int Count { get; private set; }

        public bool IsValidNonEmptyAudio(string path)
        {
            Count++;
            return File.Exists(path) && new FileInfo(path).Length > 0;
        }
    }

    private sealed class ThrowingAudioValidator : IAudioBackupValidator
    {
        public bool IsValidNonEmptyAudio(string path) =>
            throw new InvalidOperationException("Completed media must not be decoded again after a validated restart fingerprint.");
    }

    private sealed class ThrowingVideoValidator : IVideoMediaValidator
    {
        public bool IsValidNonEmptyVideo(string path) =>
            throw new InvalidOperationException("A canonical completed video must not be decoded again during startup recovery.");
    }
}
