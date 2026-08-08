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
        var service = new SessionStorageService(root.Path, capacityProvider: new FixedCapacity(RecordingStoragePolicy.WarningBytes), clock: new FixedClock(now), audioValidator: new AlwaysValidValidator());
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
        var service = new SessionStorageService(root.Path, audioValidator: new AlwaysValidValidator());
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

    public static void LibraryIncludesOnlyPublishedVideoMedia()
    {
        using var root = new TestRoot();
        var service = VideoTestService(root.Path);
        var published = service.CreateSessionPlan(RecordingSessionKind.Manual);
        WriteMp4File(published.FinalVideoPath);
        File.WriteAllBytes(published.FinalAudioPath, [1, 2, 3]);
        File.WriteAllText(published.MetadataPath, "{\"mediaKind\":\"video\",\"screenIntervals\":[{\"start\":0,\"end\":1}]}");

        var partial = service.CreateSessionPlan(RecordingSessionKind.Manual);
        File.WriteAllBytes(Path.Combine(partial.FolderPath, RecordingSessionLayout.PartialVideoFileName), [4, 5, 6]);
        File.WriteAllText(partial.MetadataPath, "{\"mediaKind\":\"video\"}");

        var items = service.ListSessions();
        if (items.Count != 1 || items[0].AudioPath != Path.Combine(published.FolderPath, RecordingSessionLayout.FinalVideoFileName) ||
            items[0].Metadata.MediaKind != "video")
        {
            throw new InvalidOperationException("Only a published video recording may appear in the library.");
        }
    }

    public static void VideoPublicationPromotesMp4AndRetainsM4aFallback()
    {
        using var root = new TestRoot();
        var service = VideoTestService(root.Path);
        var plan = service.CreateSessionPlan(RecordingSessionKind.Meeting);
        WriteMp4File(plan.PartialVideoPath);
        File.WriteAllBytes(plan.BackupAudioPath, [1, 2, 3]);

        var result = service.PublishCompletedVideoAsync(
                plan,
                "Shared content",
                WindowsCaptureMetadata.ForSelectedProcessLoopback("ms-teams.exe"))
            .GetAwaiter().GetResult();

        if (!result.VideoPublished || !result.AudioPreserved || result.RecoveryState != RecordingRecoveryState.None ||
            !File.Exists(plan.FinalVideoPath) || !File.Exists(plan.FinalAudioPath) ||
            File.Exists(plan.PartialVideoPath) || File.Exists(plan.BackupAudioPath))
        {
            throw new InvalidOperationException("Completed video publication did not promote both final media files safely.");
        }

        var metadataText = File.ReadAllText(plan.MetadataPath);
        var metadata = RecordingInfoJson.Parse(metadataText);
        if (metadata.MediaKind != "video" || metadata.RecoveryState != RecordingRecoveryState.None ||
            metadata.Source != "teamsAutomatic" || metadata.WindowsCapture?.ProcessName != "ms-teams.exe" ||
            metadataText.Contains("capturedTeamsWindow", StringComparison.Ordinal) ||
            metadataText.Contains("windowHandle", StringComparison.Ordinal) ||
            metadataText.Contains("processId", StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Published video metadata retained a runtime window identity or lost bounded audio provenance.");
        }

        var updated = service.UpdateMetadataAsync(plan.FolderPath, "Renamed shared content", ["demo"], true)
            .GetAwaiter().GetResult();
        if (updated.MediaKind != "video" || updated.Title != "Renamed shared content" ||
            !File.Exists(plan.FinalVideoPath) || !File.Exists(plan.FinalAudioPath))
        {
            throw new InvalidOperationException("A published video session could not retain its primary/fallback media during metadata editing.");
        }

        var item = service.ListSessions().Single();
        if (item.AudioPath != plan.FinalVideoPath || item.Metadata.MediaKind != "video" ||
            item.Metadata.Title != "Renamed shared content")
        {
            throw new InvalidOperationException("The published MP4 was not the library primary media.");
        }
    }

    public static void VideoPublicationFallsBackToM4aAndNeverPublishesAnInvalidPartialMp4()
    {
        using var root = new TestRoot();
        var service = VideoTestService(root.Path);
        var plan = service.CreateSessionPlan(RecordingSessionKind.Manual);
        File.WriteAllBytes(plan.PartialVideoPath, [9, 9, 9]);
        File.WriteAllBytes(plan.BackupAudioPath, [1, 2, 3]);

        var result = service.PublishCompletedVideoAsync(plan).GetAwaiter().GetResult();
        if (result.VideoPublished || !result.AudioPreserved ||
            result.RecoveryState != RecordingRecoveryState.VideoLostAudioPreserved ||
            File.Exists(plan.FinalVideoPath) || !File.Exists(plan.FinalAudioPath) ||
            !File.Exists(plan.PartialVideoPath) || File.Exists(plan.BackupAudioPath))
        {
            throw new InvalidOperationException($"A failed video publication did not preserve the M4A fallback safely: video={result.VideoPublished}, audio={result.AudioPreserved}, state={result.RecoveryState}, finalVideo={File.Exists(plan.FinalVideoPath)}, finalAudio={File.Exists(plan.FinalAudioPath)}, partialVideo={File.Exists(plan.PartialVideoPath)}, backupAudio={File.Exists(plan.BackupAudioPath)}.");
        }

        var item = service.ListSessions().Single();
        if (item.AudioPath != plan.FinalAudioPath || item.Metadata.MediaKind != "audio" ||
            item.Metadata.RecoveryState != RecordingRecoveryState.VideoLostAudioPreserved)
        {
            throw new InvalidOperationException("An invalid partial MP4 appeared in the library instead of the preserved audio.");
        }
    }

    public static void DefaultMp4ValidatorRejectsStructuralForgery()
    {
        using var root = new TestRoot();
        var path = Path.Combine(root.Path, "forged.mp4");
        WriteMp4File(path);
        if (new Mp4VideoMediaValidator().IsValidNonEmptyVideo(path))
            throw new InvalidOperationException("Box-name-only MP4 was accepted without native decode proof.");
    }

    public static void RecoveryPromotesOnlyValidatedMp4WithAnM4aFallback()
    {
        using var root = new TestRoot();
        var service = VideoTestService(root.Path);
        var recovered = service.CreateSessionPlan(RecordingSessionKind.Manual);
        WriteMp4File(recovered.PartialVideoPath);
        File.WriteAllBytes(recovered.BackupAudioPath, [1, 2, 3]);

        var noAudio = service.CreateSessionPlan(RecordingSessionKind.Manual);
        WriteMp4File(noAudio.PartialVideoPath);

        var invalidVideo = service.CreateSessionPlan(RecordingSessionKind.Manual);
        File.WriteAllBytes(invalidVideo.PartialVideoPath, [8, 8, 8]);
        File.WriteAllBytes(invalidVideo.BackupAudioPath, [4, 5, 6]);

        var results = new SessionRecoveryService(service, new AlwaysValidValidator()).RecoverAsync().GetAwaiter().GetResult();
        if (!results.Single(x => x.FolderPath == recovered.FolderPath).Recovered ||
            !File.Exists(recovered.FinalVideoPath) || !File.Exists(recovered.FinalAudioPath) ||
            File.Exists(recovered.PartialVideoPath) || File.Exists(recovered.BackupAudioPath))
        {
            throw new InvalidOperationException("Recovery did not publish a validated MP4 with its final M4A fallback.");
        }

        var recoveredMetadata = RecordingInfoJson.Parse(File.ReadAllText(recovered.MetadataPath));
        if (recoveredMetadata.MediaKind != "video" ||
            recoveredMetadata.RecoveryState != RecordingRecoveryState.RecoveredAfterInterruption)
        {
            throw new InvalidOperationException("Recovered video metadata was not marked as an interrupted recording without window identity.");
        }

        if (File.Exists(noAudio.FinalVideoPath) || service.ListSessions().Any(x => x.FolderPath == noAudio.FolderPath))
        {
            throw new InvalidOperationException("Recovery published video without a separately preserved M4A fallback.");
        }

        var invalidResult = results.Single(x => x.FolderPath == invalidVideo.FolderPath);
        var invalidMetadata = RecordingInfoJson.Parse(File.ReadAllText(invalidVideo.MetadataPath));
        if (!invalidResult.Recovered || File.Exists(invalidVideo.FinalVideoPath) ||
            !File.Exists(invalidVideo.FinalAudioPath) || !File.Exists(invalidVideo.PartialVideoPath) ||
            invalidMetadata.MediaKind != "audio" ||
            invalidMetadata.RecoveryState != RecordingRecoveryState.VideoLostAudioPreserved)
        {
            throw new InvalidOperationException($"Recovery did not retain invalid MP4 evidence while preserving playable audio: recovered={invalidResult.Recovered}, finalVideo={File.Exists(invalidVideo.FinalVideoPath)}, finalAudio={File.Exists(invalidVideo.FinalAudioPath)}, partialVideo={File.Exists(invalidVideo.PartialVideoPath)}, kind={invalidMetadata.MediaKind}, state={invalidMetadata.RecoveryState}.");
        }
    }

    public static void RecoverySanitizesExistingVideoMetadataWithoutChangingMedia()
    {
        using var root = new TestRoot();
        var service = VideoTestService(root.Path);
        var plan = service.CreateSessionPlan(RecordingSessionKind.Meeting);
        WriteMp4File(plan.FinalVideoPath);
        File.WriteAllBytes(plan.FinalAudioPath, [1, 2, 3]);
        File.WriteAllText(plan.MetadataPath, """
            {
              "mediaKind":"video",
              "recoveryState":"none",
              "capturedTeamsWindow":{"processID":71,"windowID":42,"title":"Private meeting"},
              "videoCapture":{"windowHandle":"0x2A","processId":71}
            }
            """);

        var result = new SessionRecoveryService(service).RecoverAsync().GetAwaiter().GetResult().Single();
        var metadataText = File.ReadAllText(plan.MetadataPath);
        var metadata = RecordingInfoJson.Parse(metadataText);
        if (result.Recovered || metadata.MediaKind != "video" ||
            !File.Exists(plan.FinalVideoPath) || !File.Exists(plan.FinalAudioPath) ||
            metadataText.Contains("Private meeting", StringComparison.Ordinal) ||
            metadataText.Contains("windowHandle", StringComparison.Ordinal) ||
            metadataText.Contains("processID", StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Recovery did not sanitize final video metadata without touching completed media.");
        }
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

    public static void MetadataEditsPreserveMediaAndUnknownFields()
    {
        using var root = new TestRoot();
        var service = new SessionStorageService(root.Path, audioValidator: new AlwaysValidValidator());
        var folder = Path.Combine(root.Path, "manual-20260729-120000000");
        Directory.CreateDirectory(folder);
        var audioPath = Path.Combine(folder, RecordingSessionLayout.FinalAudioFileName);
        File.WriteAllBytes(audioPath, [4, 5, 6]);
        File.WriteAllText(
            Path.Combine(folder, RecordingSessionLayout.MetadataFileName),
            "{\"unknown\":{\"keep\":true},\"mediaKind\":\"audio\",\"tags\":[\"old\"]}");

        var updated = service.UpdateMetadataAsync(
            folder,
            "  Important meeting  ",
            ["Sales", "sales", "  "],
            true).GetAwaiter().GetResult();

        if (updated.Title != "Important meeting" || !updated.IsFavorite || updated.Tags.Count != 1 || updated.Tags[0] != "Sales")
            throw new InvalidOperationException("Session metadata edit was not normalized.");
        if (updated.Document["unknown"] is null || !File.Exists(audioPath) || File.ReadAllBytes(audioPath).Length != 3)
            throw new InvalidOperationException("Session metadata edit altered media or discarded an unknown field.");

        var listed = service.ListSessions().Single();
        if (listed.Metadata.Title != "Important meeting" || !listed.Metadata.IsFavorite || listed.Metadata.Tags.Single() != "Sales")
            throw new InvalidOperationException("The library did not reload edited metadata.");

        Throws<InvalidOperationException>(() => service.UpdateMetadataAsync(Path.Combine(root.Path, "outside"), "x", [], false).GetAwaiter().GetResult());
        ConcurrentMetadataWritesDoNotShareTemporaryFiles();
    }

    private static void ConcurrentMetadataWritesDoNotShareTemporaryFiles()
    {
        using var root = new TestRoot();
        var service = new SessionStorageService(root.Path, audioValidator: new AlwaysValidValidator());
        var folder = Path.Combine(root.Path, "manual-20260729-120000000");
        Directory.CreateDirectory(folder);
        File.WriteAllBytes(Path.Combine(folder, RecordingSessionLayout.FinalAudioFileName), [1]);
        var metadataPath = Path.Combine(folder, RecordingSessionLayout.MetadataFileName);

        var writes = Enumerable.Range(0, 32)
            .Select(i => service.UpdateMetadataAsync(folder, $"Writer {i}", null, null, CancellationToken.None));
        Task.WhenAll(writes).GetAwaiter().GetResult();

        var stored = RecordingInfoJson.Parse(File.ReadAllText(metadataPath));
        if (stored.Title is null || !stored.Title.StartsWith("Writer ", StringComparison.Ordinal))
            throw new InvalidOperationException("Concurrent metadata writes left malformed metadata.");
        if (Directory.EnumerateFiles(folder, "*.tmp").Any())
            throw new InvalidOperationException("Concurrent metadata writes left temporary files behind.");
    }

    public static void RecycleRejectsForeignAndIncompleteFolders()
    {
        using var root = new TestRoot();
        var service = new SessionStorageService(root.Path);
        var foreign = Path.Combine(root.Path, "foreign-20260729-120000000");
        var incomplete = Path.Combine(root.Path, "manual-20260729-120000000");
        Directory.CreateDirectory(foreign);
        Directory.CreateDirectory(incomplete);

        Throws<InvalidOperationException>(() => service.RecycleSession(foreign));
        Throws<IOException>(() => service.RecycleSession(incomplete));
        if (!Directory.Exists(incomplete)) throw new InvalidOperationException("Rejected recycle changed the incomplete folder.");
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

            using var workersReady = new CountdownEvent(32);
            using var startWorkers = new ManualResetEventSlim(false);
            var concurrent = Enumerable.Range(0, 32)
                .Select(_ => Task.Factory.StartNew(
                    () =>
                    {
                        workersReady.Signal();
                        startWorkers.Wait();
                        // Use independent service instances so this exercises the filesystem claim,
                        // rather than relying on any process-local synchronization.
                        return new SessionStorageService(
                            root,
                            capacityProvider: new FixedCapacity(RecordingStoragePolicy.WarningBytes),
                            clock: new FixedClock(timestamp))
                            .CreateSessionPlan(RecordingSessionKind.Manual);
                    },
                    CancellationToken.None,
                    TaskCreationOptions.LongRunning,
                    TaskScheduler.Default))
                .ToArray();
            if (!workersReady.Wait(TimeSpan.FromSeconds(10)))
                throw new InvalidOperationException("Concurrent allocation workers did not become ready.");
            startWorkers.Set();
            var plans = Task.WhenAll(concurrent).GetAwaiter().GetResult();
            if (plans.Select(x => x.FolderPath).Distinct(StringComparer.OrdinalIgnoreCase).Count() != plans.Length)
                throw new InvalidOperationException("Concurrent allocation returned the same session folder more than once.");
            var allocatedNames = plans.Select(x => Path.GetFileName(x.FolderPath)).ToHashSet(StringComparer.Ordinal);
            var expectedNames = Enumerable.Range(2, plans.Length)
                .Select(attempt => RecordingSessionLayout.FolderName(RecordingSessionKind.Manual, timestamp, attempt));
            if (!allocatedNames.SetEquals(expectedNames))
                throw new InvalidOperationException("Concurrent allocation did not preserve deterministic collision suffixes.");
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    public static void NewSessionsWriteCanonicalSourceAndParticipants()
    {
        using var root = new TestRoot();
        var service = new SessionStorageService(root.Path, audioValidator: new AlwaysValidValidator());
        var manual = service.CreateSessionPlan(RecordingSessionKind.Manual);
        var test = service.CreateSessionPlan(RecordingSessionKind.Test);
        var teams = service.CreateSessionPlan(RecordingSessionKind.Meeting);
        Publish(manual);
        Publish(test);
        Publish(teams);

        AssertContract(manual.MetadataPath, "manual");
        AssertContract(test.MetadataPath, "manual");
        AssertContract(teams.MetadataPath, "teamsAutomatic");

        void Publish(RecordingSessionPlan plan)
        {
            File.WriteAllBytes(plan.BackupAudioPath, [1, 2, 3]);
            service.PublishCompletedMediaAsync(plan).GetAwaiter().GetResult();
        }

        static void AssertContract(string metadataPath, string expectedSource)
        {
            var document = System.Text.Json.JsonDocument.Parse(File.ReadAllText(metadataPath)).RootElement;
            if (document.GetProperty("schemaVersion").GetInt32() != 1 ||
                document.GetProperty("source").GetString() != expectedSource ||
                document.GetProperty("participants").ValueKind != System.Text.Json.JsonValueKind.Array ||
                document.GetProperty("participants").GetArrayLength() != 0)
            {
                throw new InvalidOperationException("New Windows session metadata did not satisfy the canonical recording-session fields.");
            }
        }
    }

    public static void FutureSchemaVersionSurvivesRoundTrip()
    {
        using var root = new TestRoot();
        var service = new SessionStorageService(root.Path, audioValidator: new AlwaysValidValidator());
        var folder = Path.Combine(root.Path, "manual-20260729-120000000");
        Directory.CreateDirectory(folder);
        File.WriteAllBytes(Path.Combine(folder, RecordingSessionLayout.FinalAudioFileName), [1]);
        var metadataPath = Path.Combine(folder, RecordingSessionLayout.MetadataFileName);
        File.WriteAllText(metadataPath, "{\"schemaVersion\":2,\"source\":\"futureSource\",\"participants\":[{\"id\":\"p1\"}],\"future\":true}");

        service.UpdateMetadataAsync(folder, "Kept", null, null).GetAwaiter().GetResult();
        var document = System.Text.Json.JsonDocument.Parse(File.ReadAllText(metadataPath)).RootElement;
        if (document.GetProperty("schemaVersion").GetInt32() != 2 ||
            document.GetProperty("source").GetString() != "futureSource" ||
            document.GetProperty("participants").GetArrayLength() != 1 ||
            !document.GetProperty("future").GetBoolean())
        {
            throw new InvalidOperationException("An unsupported future metadata document was silently rewritten as v1.");
        }
    }

    public static void RootContractFixtureRoundTrips()
    {
        var fixture = Path.Combine(AppContext.BaseDirectory, "contracts", "fixtures", "recording-info-v1.json");
        var info = RecordingInfoJson.Parse(File.ReadAllText(fixture));
        var roundTripped = System.Text.Json.JsonDocument.Parse(info.Document.ToJsonString()).RootElement;
        if (info.SchemaVersion != 1 || info.Source != "teamsAutomatic" || info.Participants.Count != 2 ||
            roundTripped.GetProperty("meetingType").GetString() != "Technical Workshop" ||
            roundTripped.GetProperty("windowsCapture").GetProperty("endpointId").GetString() != "default")
        {
            throw new InvalidOperationException("The root recording-session fixture did not survive the Windows metadata round trip.");
        }
    }

    public static void FailedStartCleanupOnlyRemovesEmptyOwnedFolder()
    {
        using var root = new TestRoot();
        var service = new SessionStorageService(root.Path);
        var empty = service.CreateSessionPlan(RecordingSessionKind.Manual);
        if (!service.CleanupEmptyOwnedSession(empty) || Directory.Exists(empty.FolderPath))
            throw new InvalidOperationException("An empty owned failed-start folder was not cleaned up.");

        var evidence = service.CreateSessionPlan(RecordingSessionKind.Manual);
        File.WriteAllBytes(evidence.BackupAudioPath, [1]);
        if (service.CleanupEmptyOwnedSession(evidence) || !File.Exists(evidence.BackupAudioPath))
            throw new InvalidOperationException("Failed-start cleanup removed recoverable media evidence.");

        var diagnostic = service.CreateSessionPlan(RecordingSessionKind.Manual);
        File.WriteAllText(Path.Combine(diagnostic.FolderPath, "recovery-note.json"), "{}");
        if (service.CleanupEmptyOwnedSession(diagnostic) || !File.Exists(Path.Combine(diagnostic.FolderPath, "recovery-note.json")))
            throw new InvalidOperationException("Failed-start cleanup removed recovery evidence.");
    }

    public static void RecoveryPromotesCompletePartialM4aOnly()
    {
        using var root = new TestRoot();
        var service = new SessionStorageService(root.Path, audioValidator: new AlwaysValidValidator());
        var complete = Path.Combine(root.Path, "manual-20260729-120000000");
        var incomplete = Path.Combine(root.Path, "test-20260729-120000000");
        Directory.CreateDirectory(complete);
        Directory.CreateDirectory(incomplete);
        WriteBoxFile(Path.Combine(complete, RecordingSessionLayout.PartialAudioFileName), ("ftyp", 12), ("moov", 8));
        WriteBoxFile(Path.Combine(incomplete, RecordingSessionLayout.PartialAudioFileName), ("ftyp", 12));

        var result = new SessionRecoveryService(service, new CompleteFixtureAudioValidator()).RecoverAsync().GetAwaiter().GetResult();
        if (!result.Single(item => item.FolderPath == complete).Recovered ||
            !File.Exists(Path.Combine(complete, RecordingSessionLayout.FinalAudioFileName)))
        {
            throw new InvalidOperationException("A complete partial M4A was not restored at startup.");
        }
        if (result.Single(item => item.FolderPath == incomplete).Recovered ||
            !File.Exists(Path.Combine(incomplete, RecordingSessionLayout.PartialAudioFileName)))
        {
            throw new InvalidOperationException("An incomplete partial artifact was promoted or deleted.");
        }

        static void WriteBoxFile(string path, params (string Type, int Size)[] boxes)
        {
            using var stream = File.Create(path);
            foreach (var (type, size) in boxes)
            {
                stream.WriteByte((byte)(size >> 24));
                stream.WriteByte((byte)(size >> 16));
                stream.WriteByte((byte)(size >> 8));
                stream.WriteByte((byte)size);
                stream.Write(System.Text.Encoding.ASCII.GetBytes(type));
                for (var index = 8; index < size; index++) stream.WriteByte(0);
            }
        }
    }

    public static void MetadataFailuresRetainRetryableMedia()
    {
        using var root = new TestRoot();
        var service = new SessionStorageService(root.Path, audioValidator: new AlwaysValidValidator());
        var publish = service.CreateSessionPlan(RecordingSessionKind.Manual);
        File.WriteAllBytes(publish.BackupAudioPath, [1, 2, 3]);
        Directory.CreateDirectory(publish.MetadataPath);
        try
        {
            service.PublishCompletedMediaAsync(publish).GetAwaiter().GetResult();
            throw new InvalidOperationException("Publishing unexpectedly replaced a metadata directory.");
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        if (!File.Exists(publish.BackupAudioPath) || File.Exists(publish.FinalAudioPath))
            throw new InvalidOperationException("Metadata publication failure consumed the only recoverable media copy.");
        Directory.Delete(publish.MetadataPath);
        var publishRecovery = new SessionRecoveryService(service, new AlwaysValidValidator());
        if (!publishRecovery.RecoverAsync().GetAwaiter().GetResult().Single(item => item.FolderPath == publish.FolderPath).Recovered ||
            !File.Exists(publish.FinalAudioPath) || !File.Exists(publish.MetadataPath))
            throw new InvalidOperationException("A backup retained after failed publish was not recoverable on retry.");

        var partial = service.CreateSessionPlan(RecordingSessionKind.Manual);
        WriteBoxFile(Path.Combine(partial.FolderPath, RecordingSessionLayout.PartialAudioFileName), ("ftyp", 12), ("moov", 8));
        Directory.CreateDirectory(partial.MetadataPath);
        var firstAttempt = new SessionRecoveryService(service, new AlwaysValidValidator()).RecoverAsync().GetAwaiter().GetResult();
        if (firstAttempt.Single(item => item.FolderPath == partial.FolderPath).Recovered ||
            !File.Exists(Path.Combine(partial.FolderPath, RecordingSessionLayout.PartialAudioFileName)) || File.Exists(partial.FinalAudioPath))
            throw new InvalidOperationException("Recovery metadata failure did not retain partial evidence for retry.");
        Directory.Delete(partial.MetadataPath);
        var retry = new SessionRecoveryService(service, new AlwaysValidValidator()).RecoverAsync().GetAwaiter().GetResult();
        if (!retry.Single(item => item.FolderPath == partial.FolderPath).Recovered || !File.Exists(partial.FinalAudioPath))
            throw new InvalidOperationException("Partial media was not recoverable after metadata storage became available.");

        // Also repair a final file left by a pre-fix build that moved media
        // before its metadata write failed, so it is not skipped forever.
        var orphanFinal = service.CreateSessionPlan(RecordingSessionKind.Meeting);
        File.WriteAllBytes(orphanFinal.FinalAudioPath, [9, 8, 7]);
        new SessionRecoveryService(service, new AlwaysValidValidator()).RecoverAsync().GetAwaiter().GetResult();
        if (!File.Exists(orphanFinal.MetadataPath) ||
            RecordingInfoJson.Parse(File.ReadAllText(orphanFinal.MetadataPath)).Source != "teamsAutomatic")
        {
            throw new InvalidOperationException("Startup recovery did not repair metadata for an existing final recording.");
        }

        static void WriteBoxFile(string path, params (string Type, int Size)[] boxes)
        {
            using var stream = File.Create(path);
            foreach (var (type, size) in boxes)
            {
                stream.WriteByte((byte)(size >> 24));
                stream.WriteByte((byte)(size >> 16));
                stream.WriteByte((byte)(size >> 8));
                stream.WriteByte((byte)size);
                stream.Write(System.Text.Encoding.ASCII.GetBytes(type));
                for (var index = 8; index < size; index++) stream.WriteByte(0);
            }
        }
    }

    private sealed class FixedCapacity(long? available) : IStorageCapacityProvider { public long? GetAvailableBytes(string _) => available; }
    private sealed class FixedClock(DateTimeOffset now) : IClock { public DateTimeOffset UtcNow => now; }
    private sealed class AlwaysValidValidator : IAudioBackupValidator { public bool IsValidNonEmptyAudio(string path) => File.Exists(path) && new FileInfo(path).Length > 0; }
    private sealed class CompleteFixtureAudioValidator : IAudioBackupValidator { public bool IsValidNonEmptyAudio(string path) => File.Exists(path) && new FileInfo(path).Length >= 20; }
    private sealed class AlwaysValidVideoValidator : IVideoMediaValidator { public bool IsValidNonEmptyVideo(string path) => File.Exists(path) && new FileInfo(path).Length >= 24; }
    private sealed class SelectiveValidator(string rejectedPath) : IAudioBackupValidator { public bool IsValidNonEmptyAudio(string path) => !path.StartsWith(rejectedPath, StringComparison.OrdinalIgnoreCase) && File.Exists(path) && new FileInfo(path).Length > 0; }
    private sealed class TestRoot : IDisposable
    {
        public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "recorder-session-storage-tests", Guid.NewGuid().ToString("N"));
        public TestRoot() => Directory.CreateDirectory(Path);
        public void Dispose() { if (Directory.Exists(Path)) Directory.Delete(Path, true); }
    }
    private static SessionStorageService VideoTestService(string rootPath) =>
        new(rootPath, videoValidator: new AlwaysValidVideoValidator(), audioValidator: new AlwaysValidValidator());
    private static void WriteMp4File(string path)
    {
        // Deliberately tiny but structurally complete enough for the managed
        // publication/recovery guard: ftyp + mdat + a moov payload declaring
        // an AVC video track. Native tests remain responsible for decode proof.
        using var stream = File.Create(path);
        WriteBox("ftyp", [0, 0, 0, 0, 0, 0, 0, 0]);
        WriteBox("mdat", [0]);
        WriteBox("moov", System.Text.Encoding.ASCII.GetBytes("videavc1"));

        void WriteBox(string type, byte[] payload)
        {
            var size = checked(payload.Length + 8);
            stream.WriteByte((byte)(size >> 24));
            stream.WriteByte((byte)(size >> 16));
            stream.WriteByte((byte)(size >> 8));
            stream.WriteByte((byte)size);
            stream.Write(System.Text.Encoding.ASCII.GetBytes(type));
            stream.Write(payload);
        }
    }
    private static void Throws<T>(Action action) where T : Exception { try { action(); } catch (T) { return; } throw new InvalidOperationException($"Expected {typeof(T).Name}."); }
}
