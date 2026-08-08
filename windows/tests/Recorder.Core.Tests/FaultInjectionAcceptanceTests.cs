using Recorder.Core;
using TeamsRecorder.Windows.Application;
using TeamsRecorder.Windows.Application.Recovery;
using TeamsRecorder.Windows.Application.Storage;

/// <summary>
/// Deterministic AT-06 fault cases.  These do not attempt to manufacture a
/// valid encoded media file: the fixture validator represents the decoder
/// verdict so each test isolates fault handling, publication, and recovery
/// behavior from codec availability on the test host.
/// </summary>
internal static class FaultInjectionAcceptanceTests
{
    private static readonly byte[] ValidAudioFixture = [0x41, 0x54, 0x30, 0x36, 0x2D, 0x41, 0x41, 0x43];
    private static readonly byte[] CorruptAudioFixture = [0x00, 0xFF, 0x00, 0xFF];
    private static readonly byte[] CorruptVideoFixture = [0xDE, 0xAD, 0xBE, 0xEF, 0x01];

    public static void Mp4ValidatorRejectsCorruptFixtures()
    {
        using var root = new TestRoot();
        var truncated = Path.Combine(root.Path, "truncated.mp4");
        var structuralForgery = Path.Combine(root.Path, "forged.mp4");
        File.WriteAllBytes(truncated, [0, 0, 0, 24, (byte)'f', (byte)'t', (byte)'y', (byte)'p']);
        WriteBoxes(structuralForgery,
            ("ftyp", [0, 0, 0, 0, 0, 0, 0, 0]),
            ("mdat", [1, 2, 3]),
            ("moov", System.Text.Encoding.ASCII.GetBytes("videavc1mp4a")));

        var validator = new Mp4VideoMediaValidator();
        if (validator.IsValidNonEmptyVideo(truncated) || validator.IsValidNonEmptyVideo(structuralForgery))
        {
            throw new InvalidOperationException(
                "AT-06: the MP4 publication validator accepted truncated or structurally forged media.");
        }
    }

    public static void M4aValidatorRejectsCorruptFixtures()
    {
        using var root = new TestRoot();
        var truncated = Path.Combine(root.Path, "truncated.m4a");
        var structuralForgery = Path.Combine(root.Path, "forged.m4a");
        File.WriteAllBytes(truncated, [0, 0, 0, 24, (byte)'f', (byte)'t', (byte)'y', (byte)'p']);
        // This has the inexpensive container markers, but no AAC track or
        // decodable sample.  It must fail the native decoder gate as well.
        WriteBoxes(structuralForgery,
            ("ftyp", [0, 0, 0, 0, 0, 0, 0, 0]),
            ("moov", System.Text.Encoding.ASCII.GetBytes("sounmp4a")));

        var validator = new M4aAudioBackupValidator();
        if (validator.IsValidNonEmptyAudio(truncated) || validator.IsValidNonEmptyAudio(structuralForgery))
        {
            throw new InvalidOperationException(
                "AT-06: the M4A publication validator accepted truncated or structurally forged media.");
        }
    }

    public static void VideoInitializationFaultPublishesIndependentM4a()
    {
        using var root = new TestRoot();
        var target = Target();
        var bridge = new FaultInjectingWindowAvBridge(VideoFault.VideoInitialization);
        using var lifecycle = CreateLifecycle(bridge, root.Path, target);

        var started = lifecycle.StartAsync(Request(target)).GetAwaiter().GetResult();
        if (started.Snapshot.State != RecordingCoordinatorState.Recording || !bridge.InjectionTriggered)
        {
            throw new InvalidOperationException("AT-06: the synthetic video-initialization fault did not leave audio capture running.");
        }
        AssertIndependentOutputPaths(bridge.LastRequest, started.Session);

        lifecycle.StopAsync().GetAwaiter().GetResult();
        var publication = lifecycle.PublishCompletedAsync().GetAwaiter().GetResult();
        AssertAudioOnlyFallback(
            publication,
            started.Session,
            expectedPartialVideo: false,
            expectedAudio: ValidAudioFixture,
            scenario: "video initialization fault");
    }

    public static void Mp4WriterFaultPublishesM4aAndRetainsVideoEvidence()
    {
        using var root = new TestRoot();
        var target = Target();
        var bridge = new FaultInjectingWindowAvBridge(VideoFault.Mp4Writer);
        using var lifecycle = CreateLifecycle(bridge, root.Path, target);

        var started = lifecycle.StartAsync(Request(target)).GetAwaiter().GetResult();
        if (started.Snapshot.State != RecordingCoordinatorState.Recording || !bridge.InjectionTriggered)
        {
            throw new InvalidOperationException("AT-06: the synthetic MP4 writer fault did not leave the independent M4A capture running.");
        }
        AssertIndependentOutputPaths(bridge.LastRequest, started.Session);

        lifecycle.StopAsync().GetAwaiter().GetResult();
        var publication = lifecycle.PublishCompletedAsync().GetAwaiter().GetResult();
        AssertAudioOnlyFallback(
            publication,
            started.Session,
            expectedPartialVideo: true,
            expectedAudio: ValidAudioFixture,
            scenario: "MP4 writer fault");
        if (!File.ReadAllBytes(started.Session.PartialVideoPath).SequenceEqual(CorruptVideoFixture))
        {
            throw new InvalidOperationException("AT-06: corrupt MP4 evidence was altered instead of retained for recovery inspection.");
        }
    }

    public static void FatalVideoStartFaultRetainsM4aForStartupRecovery()
    {
        using var root = new TestRoot();
        var target = Target();
        var bridge = new FaultInjectingWindowAvBridge(VideoFault.FatalVideoStart);
        using var lifecycle = CreateLifecycle(bridge, root.Path, target);

        var start = lifecycle.StartAsync(Request(target)).GetAwaiter().GetResult();
        if (start.Snapshot.State != RecordingCoordinatorState.Failed || !bridge.InjectionTriggered ||
            !File.Exists(start.Session.BackupAudioPath))
        {
            throw new InvalidOperationException("AT-06: a fatal A/V initialization return discarded the only M4A recovery artifact.");
        }
        if (!File.ReadAllBytes(start.Session.BackupAudioPath).SequenceEqual(ValidAudioFixture) ||
            File.Exists(start.Session.FinalAudioPath) || File.Exists(start.Session.FinalVideoPath))
        {
            throw new InvalidOperationException("AT-06: fatal A/V initialization did not retain the M4A solely as recovery evidence.");
        }

        var validator = new FixtureAudioValidator();
        var storage = new SessionStorageService(root.Path, audioValidator: validator);
        var recovered = new SessionRecoveryService(storage, validator).RecoverAsync().GetAwaiter().GetResult()
            .Single(result => string.Equals(result.FolderPath, start.Session.FolderPath, StringComparison.OrdinalIgnoreCase));
        if (!recovered.Recovered || !File.Exists(start.Session.FinalAudioPath) ||
            File.Exists(start.Session.BackupAudioPath))
        {
            throw new InvalidOperationException("AT-06: startup recovery could not promote the M4A retained after a fatal video start fault.");
        }
    }

    public static void StorageRecoveryPromotesOnlyValidM4aAfterVideoFailure()
    {
        using var root = new TestRoot();
        var audioValidator = new FixtureAudioValidator();
        var storage = new SessionStorageService(
            root.Path,
            videoValidator: new RejectingVideoValidator(),
            audioValidator: audioValidator);

        var recoverable = storage.CreateSessionPlan(RecordingSessionKind.Manual);
        File.WriteAllBytes(recoverable.PartialVideoPath, CorruptVideoFixture);
        File.WriteAllBytes(recoverable.BackupAudioPath, ValidAudioFixture);

        var badAudio = storage.CreateSessionPlan(RecordingSessionKind.Manual);
        File.WriteAllBytes(badAudio.PartialVideoPath, CorruptVideoFixture);
        File.WriteAllBytes(badAudio.BackupAudioPath, CorruptAudioFixture);

        var recovery = new SessionRecoveryService(storage, audioValidator).RecoverAsync().GetAwaiter().GetResult();
        var recoveredVideoFault = recovery.Single(result => result.FolderPath == recoverable.FolderPath);
        var rejectedAudioFault = recovery.Single(result => result.FolderPath == badAudio.FolderPath);

        if (!recoveredVideoFault.Recovered || !File.Exists(recoverable.FinalAudioPath) ||
            File.Exists(recoverable.FinalVideoPath) || !File.Exists(recoverable.PartialVideoPath) ||
            File.Exists(recoverable.BackupAudioPath))
        {
            throw new InvalidOperationException("AT-06: recovery did not publish the valid M4A fallback while retaining corrupt video evidence.");
        }
        var metadata = RecordingInfoJson.Parse(File.ReadAllText(recoverable.MetadataPath));
        if (metadata.MediaKind != "audio" || metadata.RecoveryState != RecordingRecoveryState.VideoLostAudioPreserved ||
            !File.ReadAllBytes(recoverable.FinalAudioPath).SequenceEqual(ValidAudioFixture))
        {
            throw new InvalidOperationException("AT-06: recovered audio fallback lost its video-failure state or changed its media bytes.");
        }

        if (rejectedAudioFault.Recovered || File.Exists(badAudio.FinalAudioPath) ||
            !File.Exists(badAudio.BackupAudioPath) || !File.Exists(badAudio.PartialVideoPath))
        {
            throw new InvalidOperationException("AT-06: recovery promoted an invalid M4A or deleted its fault evidence.");
        }
    }

    private static RecordingLifecycleService CreateLifecycle(
        FaultInjectingWindowAvBridge bridge,
        string root,
        VideoCaptureTarget target) =>
        new(
            bridge,
            root,
            videoTargets: new FixedVideoTargetCatalog(target),
            verifiedVideoCapturePipeline: true,
            audioValidator: new FixtureAudioValidator());

    private static RecordingStartRequest Request(VideoCaptureTarget target) =>
        new(RecordingSessionKind.Manual, RecordingAudioSource.SystemLoopback, VideoTarget: target);

    private static VideoCaptureTarget Target() =>
        new(71, (nint)0x1234, 1337, "ms-teams.exe", "AT-06 fixture");

    private static void AssertIndependentOutputPaths(
        NativeSelectedWindowAvRequest? request,
        RecordingSessionPlan session)
    {
        if (request is null ||
            !string.Equals(request.AudioRecoveryPath, session.BackupAudioPath, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(request.VideoOutputPath, session.PartialVideoPath, StringComparison.OrdinalIgnoreCase) ||
            string.Equals(request.AudioRecoveryPath, request.VideoOutputPath, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("AT-06: selected-window A/V did not receive independent owned M4A and MP4 output paths.");
        }
    }

    private static void AssertAudioOnlyFallback(
        RecordingSessionPublicationResult publication,
        RecordingSessionPlan session,
        bool expectedPartialVideo,
        byte[] expectedAudio,
        string scenario)
    {
        if (!publication.Published || !File.Exists(session.FinalAudioPath) ||
            File.Exists(session.BackupAudioPath) || File.Exists(session.FinalVideoPath) ||
            File.Exists(session.PartialVideoPath) != expectedPartialVideo ||
            !File.ReadAllBytes(session.FinalAudioPath).SequenceEqual(expectedAudio))
        {
            throw new InvalidOperationException($"AT-06: {scenario} did not preserve the independent M4A fallback and expected evidence.");
        }
        var metadata = RecordingInfoJson.Parse(File.ReadAllText(session.MetadataPath));
        if (metadata.MediaKind != "audio" || metadata.RecoveryState != RecordingRecoveryState.VideoLostAudioPreserved)
        {
            throw new InvalidOperationException($"AT-06: {scenario} did not publish audio-only recovery metadata.");
        }
    }

    private static void WriteBoxes(string path, params (string Type, byte[] Payload)[] boxes)
    {
        using var stream = File.Create(path);
        foreach (var (type, payload) in boxes)
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

    private enum VideoFault
    {
        VideoInitialization,
        Mp4Writer,
        FatalVideoStart,
    }

    private sealed class FixtureAudioValidator : IAudioBackupValidator
    {
        public bool IsValidNonEmptyAudio(string path)
        {
            try { return File.Exists(path) && File.ReadAllBytes(path).SequenceEqual(ValidAudioFixture); }
            catch (IOException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
        }
    }

    private sealed class RejectingVideoValidator : IVideoMediaValidator
    {
        public bool IsValidNonEmptyVideo(string path) => false;
    }

    private sealed class FaultInjectingWindowAvBridge(VideoFault fault) : INativeRecorderBridge, INativeSelectedWindowAvRecorderBridge
    {
        private NativeRecorderState state = NativeRecorderState.Ready;

        public NativeSelectedWindowAvRequest? LastRequest { get; private set; }
        public bool InjectionTriggered { get; private set; }

        public NativeOperationResult Start(NativeRecordingRequest request) =>
            NativeOperationResult.Failure(NativeRecorderResult.NotImplemented, "The AT-06 fixture only supports selected-window A/V.");

        public NativeOperationResult StartMixed(NativeMixedRecordingRequest request) =>
            NativeOperationResult.Failure(NativeRecorderResult.NotImplemented, "The AT-06 fixture only supports selected-window A/V.");

        public NativeOperationResult StartSelectedWindowAv(NativeSelectedWindowAvRequest request)
        {
            request.Validate();
            LastRequest = request;
            File.WriteAllBytes(request.AudioRecoveryPath, ValidAudioFixture);
            InjectionTriggered = true;

            switch (fault)
            {
                case VideoFault.VideoInitialization:
                    // Models WGC/GPU/video-writer setup rejecting after the
                    // independent audio writer has begun. Native capture must
                    // remain recording so normal finalization can publish M4A.
                    state = NativeRecorderState.Recording;
                    return NativeOperationResult.Success();
                case VideoFault.Mp4Writer:
                    File.WriteAllBytes(request.VideoOutputPath, CorruptVideoFixture);
                    state = NativeRecorderState.Recording;
                    return NativeOperationResult.Success();
                case VideoFault.FatalVideoStart:
                    state = NativeRecorderState.Faulted;
                    return NativeOperationResult.Failure(NativeRecorderResult.CaptureError, "synthetic fatal video initialization fault");
                default:
                    throw new ArgumentOutOfRangeException();
            }
        }

        public NativeOperationResult Stop()
        {
            state = NativeRecorderState.Stopped;
            return NativeOperationResult.Success();
        }

        public NativeRecorderSnapshot GetSnapshot() => new(
            NativeRecorderResult.Ok,
            state,
            NativeCaptureStats.Empty(RecordingCaptureMode.SelectedWindowAv),
            null);

        public NativeEndpointEnumerationResult EnumerateEndpoints() =>
            new(NativeOperationResult.Success(), Array.Empty<NativeCaptureEndpoint>());

        public void Dispose() { }
    }

    private sealed class FixedVideoTargetCatalog(VideoCaptureTarget target) : IVideoCaptureTargetCatalog
    {
        public IReadOnlyList<VideoCaptureTarget> ListTargets() => [target];
    }

    private sealed class TestRoot : IDisposable
    {
        public string Path { get; } = System.IO.Path.Combine(
            System.IO.Path.GetTempPath(),
            "teams-recorder-at06-fault-tests",
            Guid.NewGuid().ToString("N"));

        public TestRoot() => Directory.CreateDirectory(Path);

        public void Dispose()
        {
            if (Directory.Exists(Path)) Directory.Delete(Path, recursive: true);
        }
    }
}
