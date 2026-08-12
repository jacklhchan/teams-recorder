using System.Buffers.Binary;
using Recorder.Core;
using TeamsRecorder.Windows.Application.Recovery;
using TeamsRecorder.Windows.Application.Storage;

internal static class CrashSafeRecoveryTests
{
    public static void CanonicalPathsJournalAndExclusiveLockAreDurable()
    {
        using var root = new RecoveryTestRoot();
        var storage = NewStorage(root.Path);
        var plan = storage.CreateSessionPlan(RecordingSessionKind.Manual);
        AssertFileName(plan.PartialVideoPath, "recording.partial.mp4");
        AssertFileName(plan.AudioSafetyPartialPath, "recording.audio-safety.partial.mp4");
        AssertFileName(plan.RecoveryJournalPath, "recording-recovery.json");

        var first = RecordingRecoveryJournal.Create(
            1,
            new RecordingRecoveryCheckpoint(128, 10_000_000),
            new RecordingRecoveryCheckpoint(96, 10_000_000),
            new DateTimeOffset(2026, 8, 9, 0, 0, 0, TimeSpan.Zero));
        storage.WriteRecoveryJournalAsync(plan, first).GetAwaiter().GetResult();
        var second = first with { Sequence = 2, AudioVideo = new RecordingRecoveryCheckpoint(256, 20_000_000) };
        storage.WriteRecoveryJournalAsync(plan, second).GetAwaiter().GetResult();
        var read = storage.ReadRecoveryJournal(plan);
        if (read?.Sequence != 2 || read.AudioVideo?.DurableByteOffset != 256 ||
            Directory.EnumerateFiles(plan.FolderPath, "*.tmp").Any())
        {
            throw new InvalidOperationException("The write-through recovery journal did not atomically retain only its latest complete value.");
        }

        using var active = storage.AcquireActiveLock(plan);
        Throws<IOException>(() => storage.AcquireActiveLock(plan));
        var skipped = new SessionRecoveryService(storage).RecoverAsync().GetAwaiter().GetResult().Single();
        if (skipped.Recovered || !skipped.Reason!.Contains("active", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("Startup recovery entered a session while its cross-process active lease was held.");
        }
        active.Dispose();
        using var reacquired = storage.AcquireActiveLock(plan);
    }

    public static void ScannerSelectsOnlyCompleteDurableFragments()
    {
        using var root = new RecoveryTestRoot();
        var firstFragment = Fragment([1, 2, 3]);
        var secondFragment = Fragment([4, 5, 6]);
        var completePrefix = Concat(Initialization(), firstFragment);
        var secondBoundary = completePrefix.Length + secondFragment.Length;
        var tornMdat = Concat(Box("moof", [9]), DeclaredBox("mdat", 32, [8, 7]));
        var path = Path.Combine(root.Path, "torn.mp4");
        File.WriteAllBytes(path, Concat(completePrefix, secondFragment, tornMdat));

        var checkpointed = FragmentedMp4PrefixScanner.Scan(path, secondBoundary);
        if (!checkpointed.HasRecoverablePrefix || checkpointed.CompletePrefixLength != secondBoundary ||
            checkpointed.CompleteFragmentCount != 2)
        {
            throw new InvalidOperationException("The scanner crossed a durable checkpoint or missed a complete fragment.");
        }

        var withTornTail = FragmentedMp4PrefixScanner.Scan(path);
        if (!withTornTail.HasRecoverablePrefix || withTornTail.CompletePrefixLength != secondBoundary ||
            withTornTail.CompleteFragmentCount != 2)
        {
            throw new InvalidOperationException("The scanner included a torn moof/mdat tail.");
        }

        var insideSecondFragment = FragmentedMp4PrefixScanner.Scan(path, completePrefix.Length + 10);
        if (!insideSecondFragment.HasRecoverablePrefix || insideSecondFragment.CompletePrefixLength != completePrefix.Length)
        {
            throw new InvalidOperationException("A checkpoint inside a later fragment was not rolled back to the prior complete boundary.");
        }
    }

    public static void ScannerHandlesExtendedAndOverflowBoxesFailClosed()
    {
        using var root = new RecoveryTestRoot();
        var extended = Concat(
            Box("ftyp", [1], extended: true),
            Box("moov", [2], extended: true),
            Box("moof", [3], extended: true),
            Box("mdat", [4, 5], extended: true));
        var extendedPath = Path.Combine(root.Path, "extended.mp4");
        File.WriteAllBytes(extendedPath, extended);
        var accepted = FragmentedMp4PrefixScanner.Scan(extendedPath);
        if (!accepted.HasRecoverablePrefix || accepted.CompletePrefixLength != extended.Length)
        {
            throw new InvalidOperationException("A valid 64-bit ISO-BMFF box size was rejected.");
        }

        var overflowTail = new byte[16];
        BinaryPrimitives.WriteUInt32BigEndian(overflowTail.AsSpan(0, 4), 1);
        WriteType(overflowTail.AsSpan(4, 4), "mdat");
        BinaryPrimitives.WriteUInt64BigEndian(overflowTail.AsSpan(8, 8), (ulong)long.MaxValue + 1UL);
        var overflowPath = Path.Combine(root.Path, "overflow-tail.mp4");
        File.WriteAllBytes(overflowPath, Concat(extended, overflowTail));
        var bounded = FragmentedMp4PrefixScanner.Scan(overflowPath);
        if (!bounded.HasRecoverablePrefix || bounded.CompletePrefixLength != extended.Length)
        {
            throw new InvalidOperationException("An overflowing 64-bit tail invalidated or extended the prior safe prefix.");
        }

        var overflowOnlyPath = Path.Combine(root.Path, "overflow-only.mp4");
        File.WriteAllBytes(overflowOnlyPath, overflowTail);
        if (FragmentedMp4PrefixScanner.Scan(overflowOnlyPath).HasRecoverablePrefix)
        {
            throw new InvalidOperationException("An overflowing 64-bit box was treated as recoverable media.");
        }
    }

    public static void RecoveryCopiesPrefixValidatesToEndAndIsIdempotent()
    {
        using var root = new RecoveryTestRoot();
        var storage = NewStorage(root.Path);
        var plan = storage.CreateSessionPlan(RecordingSessionKind.Meeting);
        var durable = Concat(Initialization(), Fragment([1, 2]), Fragment([3, 4]));
        var evidence = Concat(durable, Box("moof", [5]), DeclaredBox("mdat", 64, [6]));
        File.WriteAllBytes(plan.PartialVideoPath, evidence);
        storage.WriteRecoveryJournalAsync(
            plan,
            RecordingRecoveryJournal.Create(
                4,
                new RecordingRecoveryCheckpoint(durable.Length, 40_000_000),
                null,
                new DateTimeOffset(2026, 8, 9, 0, 0, 0, TimeSpan.Zero)))
            .GetAwaiter().GetResult();

        var recovery = new SessionRecoveryService(
            storage,
            recoveryMediaValidator: new CompletePrefixValidator(allowVideo: true, allowAudio: false));
        var first = recovery.RecoverAsync().GetAwaiter().GetResult().Single();
        if (!first.Recovered || first.RecoveryState != RecordingRecoveryState.RecoveredAfterInterruption ||
            !File.ReadAllBytes(plan.FinalVideoPath).SequenceEqual(durable) ||
            !File.ReadAllBytes(plan.PartialVideoPath).SequenceEqual(evidence))
        {
            throw new InvalidOperationException("Recovery did not publish only the decoder-validated prefix while retaining the original evidence.");
        }

        var metadata = RecordingInfoJson.Parse(File.ReadAllText(plan.MetadataPath));
        if (metadata.MediaKind != "video" || metadata.RecoveryState != RecordingRecoveryState.RecoveredAfterInterruption)
        {
            throw new InvalidOperationException("Recovered fMP4 metadata does not expose the interrupted recovery state.");
        }

        var second = recovery.RecoverAsync().GetAwaiter().GetResult().Single();
        if (second.Recovered || !File.ReadAllBytes(plan.FinalVideoPath).SequenceEqual(durable))
        {
            throw new InvalidOperationException("A second startup changed or republished an already recovered recording.");
        }
    }

    public static void AudioSafetyFallbackRetainsVideoEvidence()
    {
        using var root = new RecoveryTestRoot();
        var storage = NewStorage(root.Path);
        var plan = storage.CreateSessionPlan(RecordingSessionKind.Manual);
        var videoEvidence = Concat(Initialization(), Fragment([1]));
        var audioEvidence = Concat(Initialization(), Fragment([7, 8, 9]));
        File.WriteAllBytes(plan.PartialVideoPath, videoEvidence);
        File.WriteAllBytes(plan.AudioSafetyPartialPath, audioEvidence);

        var result = new SessionRecoveryService(
                storage,
                recoveryMediaValidator: new CompletePrefixValidator(allowVideo: false, allowAudio: true))
            .RecoverAsync().GetAwaiter().GetResult().Single();
        var metadata = RecordingInfoJson.Parse(File.ReadAllText(plan.MetadataPath));
        if (!result.Recovered || result.RecoveryState != RecordingRecoveryState.VideoLostAudioPreserved ||
            metadata.MediaKind != "audio" || metadata.RecoveryState != RecordingRecoveryState.VideoLostAudioPreserved ||
            !File.ReadAllBytes(plan.FinalVideoPath).SequenceEqual(audioEvidence) ||
            !File.ReadAllBytes(plan.PartialVideoPath).SequenceEqual(videoEvidence) ||
            !File.ReadAllBytes(plan.AudioSafetyPartialPath).SequenceEqual(audioEvidence))
        {
            throw new InvalidOperationException("The independent audio safety writer was not recovered without altering video evidence.");
        }
    }

    public static void InvalidEvidenceNeverOverwritesOrPublishes()
    {
        using var root = new RecoveryTestRoot();
        var storage = NewStorage(root.Path);
        var plan = storage.CreateSessionPlan(RecordingSessionKind.Manual);
        var evidence = Concat(Initialization(), Fragment([1, 2, 3]));
        File.WriteAllBytes(plan.PartialVideoPath, evidence);
        File.WriteAllBytes(plan.FinalVideoPath, [99, 98, 97]);

        var result = new SessionRecoveryService(
                storage,
                recoveryMediaValidator: new CompletePrefixValidator(allowVideo: false, allowAudio: false))
            .RecoverAsync().GetAwaiter().GetResult().Single();
        var metadata = RecordingInfoJson.Parse(File.ReadAllText(plan.MetadataPath));
        if (result.Recovered || result.RecoveryState != RecordingRecoveryState.FailedEvidenceRetained ||
            !File.ReadAllBytes(plan.FinalVideoPath).SequenceEqual(new byte[] { 99, 98, 97 }) ||
            !File.ReadAllBytes(plan.PartialVideoPath).SequenceEqual(evidence) ||
            metadata.RecoveryState != RecordingRecoveryState.FailedEvidenceRetained ||
            storage.ListSessions().Any())
        {
            throw new InvalidOperationException("Invalid recovery evidence was overwritten, published, or not marked for retained-evidence diagnostics.");
        }

        var rejected = storage.CreateSessionPlan(RecordingSessionKind.Test);
        File.WriteAllBytes(rejected.PartialVideoPath, evidence);
        var rejectedResult = new SessionRecoveryService(
                storage,
                recoveryMediaValidator: new CompletePrefixValidator(allowVideo: false, allowAudio: false))
            .RecoverAsync().GetAwaiter().GetResult().Single(item => item.FolderPath == rejected.FolderPath);
        if (rejectedResult.Recovered || File.Exists(rejected.FinalVideoPath) ||
            !File.ReadAllBytes(rejected.PartialVideoPath).SequenceEqual(evidence))
        {
            throw new InvalidOperationException("A decoder-rejected candidate became a final recording.");
        }
    }

    public static void LegacyDoublePartialAndM4aArtifactsRemainRecoverable()
    {
        using var root = new RecoveryTestRoot();
        var storage = new SessionStorageService(
            root.Path,
            videoValidator: new AlwaysVideoValidator(),
            audioValidator: new AlwaysAudioValidator());
        var plan = storage.CreateSessionPlan(RecordingSessionKind.Manual);
        var legacyVideo = Path.Combine(plan.FolderPath, RecordingSessionLayout.LegacyDoublePartialVideoFileName);
        File.WriteAllBytes(legacyVideo, [1, 2, 3, 4]);
        File.WriteAllBytes(plan.PartialAudioPath, [5, 6, 7]);

        var result = new SessionRecoveryService(storage, new AlwaysAudioValidator())
            .RecoverAsync().GetAwaiter().GetResult().Single();
        if (!result.Recovered || !File.Exists(plan.FinalVideoPath) || !File.Exists(plan.FinalAudioPath) ||
            File.Exists(legacyVideo) || File.Exists(plan.PartialAudioPath))
        {
            throw new InvalidOperationException("Legacy double-partial MP4 and partial M4A evidence no longer follow the compatible recovery path.");
        }
    }

    public static void FailedEvidenceIsNotDecodedAgainWithoutNewDurableState()
    {
        using var root = new RecoveryTestRoot();
        var storage = NewStorage(root.Path);
        var plan = storage.CreateSessionPlan(RecordingSessionKind.Manual);
        var evidence = new byte[] { 1, 2, 3, 4, 5 };
        File.WriteAllBytes(plan.PartialAudioPath, evidence);

        var first = new SessionRecoveryService(storage, new RejectingAudioValidator())
            .RecoverAsync().GetAwaiter().GetResult().Single();
        if (first.RecoveryState != RecordingRecoveryState.FailedEvidenceRetained)
        {
            throw new InvalidOperationException("Initial invalid audio evidence was not retained fail-closed.");
        }

        var second = new SessionRecoveryService(storage, new ThrowingAudioValidator())
            .RecoverAsync().GetAwaiter().GetResult().Single();
        if (second.Recovered || second.RecoveryState != RecordingRecoveryState.FailedEvidenceRetained ||
            !File.ReadAllBytes(plan.PartialAudioPath).SequenceEqual(evidence))
        {
            throw new InvalidOperationException("Terminal failed evidence was retried, altered, or published.");
        }
    }

    public static void PublishedSessionWithoutRecoveryEvidenceSkipsFullDecode()
    {
        using var root = new RecoveryTestRoot();
        var storage = new SessionStorageService(
            root.Path,
            videoValidator: new ThrowingVideoValidator(),
            audioValidator: new ThrowingAudioValidator());
        var plan = storage.CreateSessionPlan(RecordingSessionKind.Manual);
        var published = new byte[] { 9, 8, 7, 6 };
        File.WriteAllBytes(plan.FinalVideoPath, published);
        var metadata = RecordingInfoJson.CreateAudioOnly(
            null,
            null,
            RecordingRecoveryState.None,
            RecordingSessionKind.Manual);
        File.WriteAllText(plan.MetadataPath, metadata.Document.ToJsonString());
        storage.WriteRecoveryJournalAsync(
            plan,
            new RecordingRecoveryJournal(
                SchemaVersion: 1,
                Sequence: 1,
                AudioVideo: null,
                AudioSafety: new RecordingRecoveryCheckpoint(4, 10_000_000),
                UpdatedUtc: DateTimeOffset.UtcNow)).GetAwaiter().GetResult();

        var result = new SessionRecoveryService(storage, new ThrowingAudioValidator())
            .RecoverAsync().GetAwaiter().GetResult().Single();
        if (result.Recovered || result.RecoveryState != RecordingRecoveryState.None ||
            !File.ReadAllBytes(plan.FinalVideoPath).SequenceEqual(published))
        {
            throw new InvalidOperationException("A completed published session was decoded again or altered at startup.");
        }
    }

    private static SessionStorageService NewStorage(string root) => new(
        root,
        videoValidator: new CompleteFmp4VideoValidator(),
        audioValidator: new CompleteFmp4AudioValidator());

    private static byte[] Initialization() => Concat(Box("ftyp", [1]), Box("moov", [2]));
    private static byte[] Fragment(byte[] payload) => Concat(Box("moof", [1]), Box("mdat", payload));

    private static byte[] Box(string type, byte[] payload, bool extended = false)
    {
        var headerBytes = extended ? 16 : 8;
        var result = new byte[headerBytes + payload.Length];
        if (extended)
        {
            BinaryPrimitives.WriteUInt32BigEndian(result.AsSpan(0, 4), 1);
            BinaryPrimitives.WriteUInt64BigEndian(result.AsSpan(8, 8), (ulong)result.Length);
        }
        else
        {
            BinaryPrimitives.WriteUInt32BigEndian(result.AsSpan(0, 4), (uint)result.Length);
        }
        WriteType(result.AsSpan(4, 4), type);
        payload.CopyTo(result, headerBytes);
        return result;
    }

    private static byte[] DeclaredBox(string type, uint declaredSize, byte[] availablePayload)
    {
        var result = new byte[8 + availablePayload.Length];
        BinaryPrimitives.WriteUInt32BigEndian(result.AsSpan(0, 4), declaredSize);
        WriteType(result.AsSpan(4, 4), type);
        availablePayload.CopyTo(result, 8);
        return result;
    }

    private static void WriteType(Span<byte> destination, string type)
    {
        if (type.Length != 4) throw new ArgumentException("A BMFF type must be four ASCII characters.", nameof(type));
        for (var index = 0; index < 4; index++) destination[index] = checked((byte)type[index]);
    }

    private static byte[] Concat(params byte[][] values)
    {
        var result = new byte[values.Sum(static value => value.Length)];
        var offset = 0;
        foreach (var value in values)
        {
            value.CopyTo(result, offset);
            offset += value.Length;
        }
        return result;
    }

    private static void AssertFileName(string path, string expected)
    {
        if (!string.Equals(Path.GetFileName(path), expected, StringComparison.Ordinal))
            throw new InvalidOperationException($"Expected canonical work path '{expected}', got '{path}'.");
    }

    private static void Throws<TException>(Action action) where TException : Exception
    {
        try { action(); }
        catch (TException) { return; }
        throw new InvalidOperationException($"Expected {typeof(TException).Name}.");
    }

    private sealed class CompletePrefixValidator(bool allowVideo, bool allowAudio) : IRecoveryMediaValidator
    {
        public RecoveryMediaValidationResult ValidateToEnd(string path, RecoveryMediaKind mediaKind)
        {
            var allowed = mediaKind == RecoveryMediaKind.AudioVideoMp4 ? allowVideo : allowAudio;
            var scan = FragmentedMp4PrefixScanner.Scan(path);
            return allowed && scan.HasRecoverablePrefix && scan.CompletePrefixLength == new FileInfo(path).Length
                ? RecoveryMediaValidationResult.Valid
                : RecoveryMediaValidationResult.Invalid("Injected decode-to-EOF rejection.");
        }
    }

    private sealed class CompleteFmp4VideoValidator : IVideoMediaValidator
    {
        public bool IsValidNonEmptyVideo(string path)
        {
            var scan = FragmentedMp4PrefixScanner.Scan(path);
            return scan.HasRecoverablePrefix && scan.CompletePrefixLength == new FileInfo(path).Length;
        }
    }

    private sealed class CompleteFmp4AudioValidator : IAudioBackupValidator
    {
        public bool IsValidNonEmptyAudio(string path)
        {
            var scan = FragmentedMp4PrefixScanner.Scan(path);
            return scan.HasRecoverablePrefix && scan.CompletePrefixLength == new FileInfo(path).Length;
        }
    }

    private sealed class AlwaysVideoValidator : IVideoMediaValidator
    {
        public bool IsValidNonEmptyVideo(string path) => File.Exists(path) && new FileInfo(path).Length > 0;
    }

    private sealed class AlwaysAudioValidator : IAudioBackupValidator
    {
        public bool IsValidNonEmptyAudio(string path) => File.Exists(path) && new FileInfo(path).Length > 0;
    }

    private sealed class RejectingAudioValidator : IAudioBackupValidator
    {
        public bool IsValidNonEmptyAudio(string path) => false;
    }

    private sealed class ThrowingAudioValidator : IAudioBackupValidator
    {
        public bool IsValidNonEmptyAudio(string path) =>
            throw new InvalidOperationException("Terminal evidence must not be decoded again.");
    }

    private sealed class ThrowingVideoValidator : IVideoMediaValidator
    {
        public bool IsValidNonEmptyVideo(string path) =>
            throw new InvalidOperationException("Published media without recovery evidence must not be decoded again.");
    }

    private sealed class RecoveryTestRoot : IDisposable
    {
        public RecoveryTestRoot()
        {
            Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "teams-recorder-recovery-tests-" + Guid.NewGuid().ToString("N"));
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
