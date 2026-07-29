using Recorder.Core;
using TeamsRecorder.Windows.Application.Storage;
using TeamsRecorder.Windows.Application.Recovery;

// Intentionally not registered in Program.cs: the parent integration owns test registration.
internal static class SessionStorageTests
{
    public static void CapacityBoundariesAreExact()
    {
        using var root = new TestRoot();
        var policy = new RecordingStoragePolicy();
        AssertDecision(RecordingStoragePolicy.WarningBytes, RecordingStorageDecision.Normal);
        AssertDecision(RecordingStoragePolicy.WarningBytes - 1, RecordingStorageDecision.Warn);
        AssertDecision(RecordingStoragePolicy.VideoMinimumBytes - 1, RecordingStorageDecision.AudioOnly);
        AssertDecision(RecordingStoragePolicy.DefaultAudioStopBytes, RecordingStorageDecision.AudioOnly);
        AssertDecision(RecordingStoragePolicy.DefaultAudioStopBytes - 1, RecordingStorageDecision.Stop);

        void AssertDecision(long available, RecordingStorageDecision expected)
        {
            var service = new SessionStorageService(root.Path, capacityProvider: new FixedCapacity(available));
            var status = service.GetCapacityStatus();
            if (status.Decision != expected) throw new InvalidOperationException($"Expected {expected} at {available}; got {status.Decision}.");
            if (status.CanStart != (expected != RecordingStorageDecision.Stop)) throw new InvalidOperationException("Capacity startability did not match its decision.");
        }
    }

    public static void AllocationAndPublishDoNotOverwrite()
    {
        using var root = new TestRoot();
        var now = new DateTimeOffset(2026, 7, 29, 12, 0, 0, TimeSpan.Zero);
        var service = new SessionStorageService(root.Path, capacityProvider: new FixedCapacity(RecordingStoragePolicy.WarningBytes), clock: new FixedClock(now));
        var first = service.CreateSessionPlan(RecordingSessionKind.Manual);
        File.WriteAllBytes(first.BackupAudioPath, [1, 2, 3]);
        File.WriteAllBytes(first.FinalAudioPath, [9]);
        Throws<IOException>(() => service.PublishCompletedMediaAsync(first).GetAwaiter().GetResult());
        if (File.ReadAllBytes(first.FinalAudioPath).Single() != 9 || !File.Exists(first.BackupAudioPath)) throw new InvalidOperationException("Publishing overwrote existing media.");

        File.Delete(first.FinalAudioPath);
        service.PublishCompletedMediaAsync(first, "Session title").GetAwaiter().GetResult();
        if (!File.Exists(first.FinalAudioPath) || File.Exists(first.BackupAudioPath)) throw new InvalidOperationException("Publishing did not promote only the work file.");
        var second = service.CreateSessionPlan(RecordingSessionKind.Manual);
        if (string.Equals(first.FolderPath, second.FolderPath, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Allocation reused a managed session folder.");
    }

    public static void LibraryIgnoresUnsafeIncompleteAndMalformedEntries()
    {
        using var root = new TestRoot();
        var service = new SessionStorageService(root.Path);
        var valid = Path.Combine(root.Path, "manual-20260729-120000000");
        var backupOnly = Path.Combine(root.Path, "meeting-20260729-120000000");
        var malformed = Path.Combine(root.Path, "meeting-");
        var foreign = Path.Combine(root.Path, "other-20260729-120000000");
        Directory.CreateDirectory(valid);
        Directory.CreateDirectory(backupOnly);
        Directory.CreateDirectory(malformed);
        Directory.CreateDirectory(foreign);
        File.WriteAllBytes(Path.Combine(valid, RecordingSessionLayout.FinalAudioFileName), [4, 5]);
        File.WriteAllBytes(Path.Combine(backupOnly, RecordingSessionLayout.BackupAudioFileName), [6]);
        File.WriteAllText(Path.Combine(valid, RecordingSessionLayout.MetadataFileName), "{ malformed");

        var items = service.ListSessions();
        if (items.Count != 1 || !string.Equals(items[0].FolderPath, valid, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("The library included incomplete, malformed, or foreign entries.");
        if (items[0].Metadata.MediaKind != "audio") throw new InvalidOperationException("Malformed metadata was not safely normalized.");
    }

    public static void RecoveryIsIdempotentAndNeverClobbers()
    {
        using var root = new TestRoot();
        var service = new SessionStorageService(root.Path);
        var recoverable = CreateFolder("manual-20260729-120000000");
        var protectedFinal = CreateFolder("meeting-20260729-120000000");
        var invalid = CreateFolder("test-20260729-120000000");
        File.WriteAllBytes(Path.Combine(recoverable, RecordingSessionLayout.BackupAudioFileName), [1, 2]);
        File.WriteAllBytes(Path.Combine(protectedFinal, RecordingSessionLayout.FinalAudioFileName), [9]);
        File.WriteAllBytes(Path.Combine(protectedFinal, RecordingSessionLayout.BackupAudioFileName), [8]);
        File.WriteAllBytes(Path.Combine(invalid, RecordingSessionLayout.BackupAudioFileName), [7]);
        var recovery = new SessionRecoveryService(service, new SelectiveValidator(invalid));

        var first = recovery.RecoverAsync().GetAwaiter().GetResult();
        if (!first.Single(x => x.FolderPath == recoverable).Recovered) throw new InvalidOperationException("Valid backup was not recovered.");
        if (File.ReadAllBytes(Path.Combine(protectedFinal, RecordingSessionLayout.FinalAudioFileName)).Single() != 9) throw new InvalidOperationException("Recovery clobbered completed media.");
        if (!File.Exists(Path.Combine(protectedFinal, RecordingSessionLayout.BackupAudioFileName))) throw new InvalidOperationException("Recovery altered a protected backup.");
        if (File.Exists(Path.Combine(invalid, RecordingSessionLayout.FinalAudioFileName))) throw new InvalidOperationException("Rejected backup was recovered.");

        var second = recovery.RecoverAsync().GetAwaiter().GetResult();
        if (second.Any(x => x.FolderPath == recoverable && x.Recovered)) throw new InvalidOperationException("Recovery was not idempotent.");

        string CreateFolder(string name) { var path = Path.Combine(root.Path, name); Directory.CreateDirectory(path); return path; }
    }
    public static void CapacityUnavailableBlocksStart()
    {
        var policy = new RecordingStoragePolicy();
        if (policy.Decide((long?)null) != RecordingStorageDecision.Stop)
            throw new InvalidOperationException("Unavailable storage must block recording.");
    }

    public static void MetadataNormalizesMalformedOptionalFields()
    {
        var info = RecordingInfoJson.Parse("{\"title\":3,\"tags\":[\"ok\",7],\"isFavorite\":\"yes\",\"mediaKind\":\"bad\",\"unknown\":true}");
        if (info.Title is not null || info.Tags.Count != 1 || info.Tags[0] != "ok" || info.IsFavorite || info.MediaKind != "audio" || info.Document["unknown"] is null)
            throw new InvalidOperationException("Malformed optional metadata was not normalized safely.");
    }

    public static void FolderNamesAreWhitelisted()
    {
        if (!RecordingSessionLayout.TryGetKind("meeting-20260729-120000000", out var kind) || kind != RecordingSessionKind.Meeting)
            throw new InvalidOperationException("Expected a managed meeting folder.");
        if (RecordingSessionLayout.TryGetKind("other-20260729", out _))
            throw new InvalidOperationException("Unexpected library folder was accepted.");
    }

    public static void AllocatesDeterministicCollisionSuffix()
    {
        var root = Path.Combine(Path.GetTempPath(), "recorder-session-storage-tests", Guid.NewGuid().ToString("N"));
        try
        {
            var timestamp = new DateTimeOffset(2026, 7, 29, 12, 0, 0, TimeSpan.Zero);
            var service = new SessionStorageService(root, capacityProvider: new FixedCapacity(RecordingStoragePolicy.WarningBytes), clock: new FixedClock(timestamp));
            Directory.CreateDirectory(Path.Combine(root, RecordingSessionLayout.FolderName(RecordingSessionKind.Manual, timestamp)));
            var plan = service.CreateSessionPlan(RecordingSessionKind.Manual);
            if (!plan.FolderPath.EndsWith("-1", StringComparison.Ordinal)) throw new InvalidOperationException("Expected the first collision suffix.");
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    private sealed class FixedCapacity(long? available) : IStorageCapacityProvider { public long? GetAvailableBytes(string _) => available; }
    private sealed class FixedClock(DateTimeOffset now) : IClock { public DateTimeOffset UtcNow => now; }
    private sealed class SelectiveValidator(string rejectedPath) : IAudioBackupValidator { public bool IsValidNonEmptyAudio(string path) => !path.StartsWith(rejectedPath, StringComparison.OrdinalIgnoreCase) && File.Exists(path) && new FileInfo(path).Length > 0; }
    private sealed class TestRoot : IDisposable
    {
        public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "recorder-session-storage-tests", Guid.NewGuid().ToString("N"));
        public TestRoot() => Directory.CreateDirectory(Path);
        public void Dispose() { if (Directory.Exists(Path)) Directory.Delete(Path, true); }
    }
    private static void Throws<T>(Action action) where T : Exception { try { action(); } catch (T) { return; } throw new InvalidOperationException($"Expected {typeof(T).Name}."); }
}
