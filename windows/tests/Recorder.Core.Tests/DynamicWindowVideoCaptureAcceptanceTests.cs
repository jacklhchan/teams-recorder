using Recorder.Core;
using TeamsRecorder.Windows.Application;
using TeamsRecorder.Windows.Application.Recovery;
using TeamsRecorder.Windows.Application.Storage;

// AT-DV: deterministic contract coverage for the managed/native dynamic
// target seam. Native C++ has the equivalent route test plus WGC integration;
// this file verifies the public .NET contract without a desktop/GPU fixture.
internal static class DynamicWindowVideoCaptureAcceptanceTests
{
    public static void MidRecordingTargetChangesArePrivateAndAudioContinues()
    {
        var bridge = new DynamicBridge();
        var start = new NativeSelectedWindowAvRequest(
            NativeSelectedAudioSource.SystemLoopback,
            "C:\\recordings\\audio-safety.partial.mp4",
            "C:\\recordings\\recording.partial.mp4");
        if (start.VideoWidth != 1920 || start.VideoHeight != 1080 ||
            start.VideoFrameRate != 30 || start.VideoBitRate != 5_000_000)
        {
            throw new InvalidOperationException(
                "Selected-window capture must default to a 1080p30 fixed canvas at the bounded 5 Mbps profile.");
        }
        start.Validate();
        Equal(NativeRecorderResult.Ok, bridge.StartSelectedWindowAv(start).Result);
        bridge.EmitAudio();
        Equal(FrameKind.Black, bridge.EmitFrame(Target(0x100, 42, 10), callbackGeneration: 0));

        var first = Target(0x100, 42, 10);
        Equal(NativeRecorderResult.Ok, bridge.SetVideoTarget(first).Result);
        var firstGeneration = bridge.CurrentGeneration;
        Equal(FrameKind.Target, bridge.EmitFrame(first, firstGeneration));

        var replacement = Target(0x200, 43, 20);
        Equal(NativeRecorderResult.Ok, bridge.SetVideoTarget(replacement).Result);
        var replacementGeneration = bridge.CurrentGeneration;
        Equal(FrameKind.Black, bridge.EmitFrame(first, firstGeneration));
        Equal(FrameKind.Target, bridge.EmitFrame(replacement, replacementGeneration));

        Equal(NativeRecorderResult.Ok, bridge.DisableVideoTarget().Result);
        Equal(FrameKind.Black, bridge.EmitFrame(replacement, replacementGeneration));
        Equal(1, bridge.AudioPackets);
    }

    public static void HwndReuseResizeCloseAndStaleCallbacksNeverLeakPriorPixels()
    {
        var bridge = new DynamicBridge();
        _ = bridge.StartSelectedWindowAv(new(
            NativeSelectedAudioSource.SystemLoopback,
            "C:\\recordings\\audio-safety.partial.mp4",
            "C:\\recordings\\recording.partial.mp4"));

        var original = Target(0x1234, 77, 100);
        _ = bridge.SetVideoTarget(original);
        var originalGeneration = bridge.CurrentGeneration;

        // Same PID and HWND with a new process instance is a different exact
        // identity; the old callback is black even before/after replacement.
        var recycled = Target(0x1234, 77, 101);
        _ = bridge.SetVideoTarget(recycled);
        var recycledGeneration = bridge.CurrentGeneration;
        Equal(FrameKind.Black, bridge.EmitFrame(original, originalGeneration));
        Equal(FrameKind.Target, bridge.EmitFrame(recycled, recycledGeneration));

        bridge.BeginResize();
        Equal(FrameKind.Black, bridge.EmitFrame(recycled, recycledGeneration));
        bridge.CommitResize();
        Equal(FrameKind.Target, bridge.EmitFrame(recycled, bridge.CurrentGeneration));

        bridge.TargetClosed();
        Equal(FrameKind.Black, bridge.EmitFrame(recycled, bridge.CurrentGeneration));
        bridge.EmitAudio();
        Equal(1, bridge.AudioPackets);
    }

    // The native writer is created when the audio-first A/V session starts,
    // not by the first WGC callback. A delayed first real frame must therefore
    // leave an explicit black prefix while the audio timeline keeps advancing.
    public static void DelayedFirstRealFrameKeepsOneWriterBlackPrefixAndAudio()
    {
        var bridge = new DynamicBridge();
        Equal(NativeRecorderResult.Ok, bridge.StartSelectedWindowAv(new(
            NativeSelectedAudioSource.SystemLoopback,
            "C:\\recordings\\audio-safety.partial.mp4",
            "C:\\recordings\\recording.partial.mp4")).Result);

        for (var i = 0; i < 3; i++)
        {
            bridge.EmitAudio();
            Equal(FrameKind.Black, bridge.EmitFrame(Target(0x100, 42, 10), callbackGeneration: 0));
        }

        var teams = Target(0x100, 42, 10);
        Equal(NativeRecorderResult.Ok, bridge.SetVideoTarget(teams).Result);
        bridge.EmitAudio();
        Equal(FrameKind.Target, bridge.EmitFrame(teams, bridge.CurrentGeneration));

        Equal(1, bridge.WriterInstances);
        Equal(4, bridge.AudioPackets);
        EqualFrames([FrameKind.Black, FrameKind.Black, FrameKind.Black, FrameKind.Target], bridge.Frames);
    }

    // Enabling and disabling capture routes frames within the one A/V writer.
    // It must never recreate the writer, leak old pixels during an off gap, or
    // pause the independent audio timeline.
    public static void OffOnOffOnUsesOneWriterBlackGapsAndContinuousAudio()
    {
        var bridge = new DynamicBridge();
        Equal(NativeRecorderResult.Ok, bridge.StartSelectedWindowAv(new(
            NativeSelectedAudioSource.SystemLoopback,
            "C:\\recordings\\audio-safety.partial.mp4",
            "C:\\recordings\\recording.partial.mp4")).Result);

        var first = Target(0x100, 42, 10);
        var second = Target(0x200, 43, 20);
        bridge.EmitAudio();
        Equal(FrameKind.Black, bridge.EmitFrame(first, callbackGeneration: 0));

        Equal(NativeRecorderResult.Ok, bridge.SetVideoTarget(first).Result);
        bridge.EmitAudio();
        Equal(FrameKind.Target, bridge.EmitFrame(first, bridge.CurrentGeneration));

        Equal(NativeRecorderResult.Ok, bridge.DisableVideoTarget().Result);
        bridge.EmitAudio();
        Equal(FrameKind.Black, bridge.EmitFrame(first, bridge.CurrentGeneration - 1));

        Equal(NativeRecorderResult.Ok, bridge.SetVideoTarget(second).Result);
        bridge.EmitAudio();
        Equal(FrameKind.Target, bridge.EmitFrame(second, bridge.CurrentGeneration));

        Equal(1, bridge.WriterInstances);
        Equal(4, bridge.AudioPackets);
        EqualFrames([FrameKind.Black, FrameKind.Target, FrameKind.Black, FrameKind.Target], bridge.Frames);
    }

    public static void NeverEnabledTargetPublishesAudioOnlySafetyMp4()
    {
        using var root = new TemporaryRoot();
        var storage = new SessionStorageService(root.Path, audioValidator: new AlwaysValidAudio());
        var session = storage.CreateSessionPlan(RecordingSessionKind.Manual);
        // This is the independent fMP4 safety artifact retained by a dynamic
        // session that never committed an exact target. The black-only A/V
        // work file is discarded by native finalization and is deliberately
        // not promoted or labelled as captured video.
        File.WriteAllBytes(session.AudioSafetyPartialPath, [1, 2, 3, 4]);
        storage.PublishCompletedMediaAsync(session).GetAwaiter().GetResult();

        if (!File.Exists(session.FinalVideoPath) || File.Exists(session.PartialVideoPath) ||
            File.Exists(session.AudioSafetyPartialPath))
        {
            throw new InvalidOperationException("A never-enabled target did not publish exactly the audio-safety MP4.");
        }
        var metadata = RecordingInfoJson.Parse(File.ReadAllText(session.MetadataPath));
        Equal("audio", metadata.MediaKind);
    }

    public static void DisappearingInitialTargetPublishesAudioOnlySafetyMp4()
    {
        using var root = new TemporaryRoot();
        var requested = Target(0x5678, 91, 321);
        var bridge = new LifecycleAudioSafetyBridge();
        using var lifecycle = new RecordingLifecycleService(
            bridge,
            root.Path,
            videoTargets: new EmptyVideoTargetCatalog(),
            verifiedVideoCapturePipeline: true,
            audioValidator: new AlwaysValidAudio());

        var started = lifecycle.StartAsync(new RecordingStartRequest(
            RecordingSessionKind.Manual,
            RecordingAudioSource.SystemLoopback,
            VideoTarget: requested)).GetAwaiter().GetResult();
        Equal(RecordingCoordinatorState.Recording, started.Snapshot.State);
        if (bridge.LastRequest?.WindowTarget is not null)
            throw new InvalidOperationException("A target that disappeared before start was still passed to native capture.");

        lifecycle.StopAsync().GetAwaiter().GetResult();
        var publication = lifecycle.PublishCompletedAsync().GetAwaiter().GetResult();
        if (!publication.Published || !File.Exists(started.Session.FinalVideoPath) ||
            File.Exists(started.Session.PartialVideoPath))
        {
            throw new InvalidOperationException("A disappeared initial target did not publish the audio-safety MP4.");
        }
        var metadata = RecordingInfoJson.Parse(File.ReadAllText(started.Session.MetadataPath));
        Equal("audio", metadata.MediaKind);
        Equal(RecordingRecoveryState.None, metadata.RecoveryState);
    }

    // A WGC target can be committed yet deliver no accepted frame before stop
    // (for example the Teams meeting window was replaced). The native A/V
    // work file then contains privacy-black continuity only. It must remain
    // evidence, while the independent audio-safe MP4 is the sole library
    // item rather than falsely claiming captured video.
    public static void EnabledButBlackOnlyTargetPublishesAudioSafetyMp4()
    {
        using var root = new TemporaryRoot();
        var requested = Target(0x6789, 92, 322);
        var bridge = new LifecycleAudioSafetyBridge();
        using var lifecycle = new RecordingLifecycleService(
            bridge,
            root.Path,
            videoTargets: new SingleVideoTargetCatalog(requested),
            verifiedVideoCapturePipeline: true,
            audioValidator: new AlwaysValidAudio());

        var started = lifecycle.StartAsync(new RecordingStartRequest(
            RecordingSessionKind.Manual,
            RecordingAudioSource.SystemLoopback,
            VideoTarget: requested)).GetAwaiter().GetResult();
        Equal(RecordingCoordinatorState.Recording, started.Snapshot.State);
        if (bridge.LastRequest?.WindowTarget is null)
            throw new InvalidOperationException("The admitted target was not passed to native capture.");

        lifecycle.StopAsync().GetAwaiter().GetResult();
        var publication = lifecycle.PublishCompletedAsync().GetAwaiter().GetResult();
        if (!publication.Published || !File.Exists(started.Session.FinalVideoPath) ||
            !File.Exists(started.Session.PartialVideoPath) ||
            File.Exists(started.Session.AudioSafetyPartialPath))
        {
            throw new InvalidOperationException("Black-only video did not preserve evidence and publish the audio-safe recording.");
        }

        var metadata = RecordingInfoJson.Parse(File.ReadAllText(started.Session.MetadataPath));
        Equal("audio", metadata.MediaKind);
        Equal(RecordingRecoveryState.VideoLostAudioPreserved, metadata.RecoveryState);

        // A later startup sees the retained partial as evidence, but must not
        // promote it over the completed audio-safe MP4. This simulated decoder
        // accepts only the known final audio artifact.
        var recoveryStorage = new SessionStorageService(root.Path, audioValidator: new AlwaysValidAudio());
        var recovery = new SessionRecoveryService(
            recoveryStorage,
            recoveryMediaValidator: new AudioOnlyRecoveryValidator());
        var recoveryResult = recovery.RecoverAsync().GetAwaiter().GetResult().Single();
        if (recoveryResult.Recovered || recoveryResult.RecoveryState != RecordingRecoveryState.VideoLostAudioPreserved)
            throw new InvalidOperationException("Startup recovery promoted black-only partial video over the audio-safe recording.");
        metadata = RecordingInfoJson.Parse(File.ReadAllText(started.Session.MetadataPath));
        Equal("audio", metadata.MediaKind);
    }

    public static void CapturedWindowFramePublishesVideo()
    {
        using var root = new TemporaryRoot();
        var requested = Target(0x789A, 93, 323);
        var bridge = new LifecycleAudioSafetyBridge(capturedWindowFrames: 1);
        using var lifecycle = new RecordingLifecycleService(
            bridge,
            root.Path,
            videoTargets: new SingleVideoTargetCatalog(requested),
            verifiedVideoCapturePipeline: true,
            audioValidator: new AlwaysValidAudio(),
            videoValidator: new AlwaysValidVideo());

        var started = lifecycle.StartAsync(new RecordingStartRequest(
            RecordingSessionKind.Manual,
            RecordingAudioSource.SystemLoopback,
            VideoTarget: requested)).GetAwaiter().GetResult();
        lifecycle.StopAsync().GetAwaiter().GetResult();
        var publication = lifecycle.PublishCompletedAsync().GetAwaiter().GetResult();
        if (!publication.Published || !File.Exists(started.Session.FinalVideoPath) ||
            File.Exists(started.Session.PartialVideoPath) ||
            !File.Exists(started.Session.AudioSafetyPartialPath))
        {
            throw new InvalidOperationException("A captured exact-window frame did not publish the A/V MP4.");
        }

        var metadata = RecordingInfoJson.Parse(File.ReadAllText(started.Session.MetadataPath));
        Equal("video", metadata.MediaKind);
    }

    private static VideoCaptureTarget Target(nint hwnd, int pid, long created) =>
        new(pid, hwnd, created, "ms-teams.exe", "Transient target");

    private static void Equal<T>(T expected, T actual) where T : notnull
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new InvalidOperationException($"Expected {expected}; got {actual}.");
    }

    private static void EqualFrames(IReadOnlyList<FrameKind> expected, IReadOnlyList<FrameKind> actual)
    {
        if (!expected.SequenceEqual(actual))
            throw new InvalidOperationException($"Expected [{string.Join(',', expected)}]; got [{string.Join(',', actual)}].");
    }

    private enum FrameKind { Black, Target }

    private sealed class DynamicBridge : INativeRecorderBridge,
        INativeSelectedWindowAvRecorderBridge,
        INativeDynamicWindowVideoRecorderBridge
    {
        private NativeRecorderState state = NativeRecorderState.Ready;
        private long generation;
        private VideoCaptureTarget? target;
        private bool resizeTransition;
        private readonly List<FrameKind> frames = [];

        public int AudioPackets { get; private set; }
        public int WriterInstances { get; private set; }
        public long CurrentGeneration => generation;
        public IReadOnlyList<FrameKind> Frames => frames;

        public NativeOperationResult Start(NativeRecordingRequest request) =>
            NativeOperationResult.Failure(NativeRecorderResult.NotImplemented, "Not used.");

        public NativeOperationResult StartMixed(NativeMixedRecordingRequest request) =>
            NativeOperationResult.Failure(NativeRecorderResult.NotImplemented, "Not used.");

        public NativeOperationResult StartSelectedWindowAv(NativeSelectedWindowAvRequest request)
        {
            request.Validate();
            state = NativeRecorderState.Recording;
            target = request.WindowTarget;
            WriterInstances++;
            generation++;
            return NativeOperationResult.Success();
        }

        public NativeOperationResult SetVideoTarget(VideoCaptureTarget requested)
        {
            if (state != NativeRecorderState.Recording || !requested.IsUsable)
                return NativeOperationResult.Failure(NativeRecorderResult.InvalidState, "No A/V recording is active.");
            // Transition is fenced before the new exact identity commits.
            target = null;
            resizeTransition = true;
            generation++;
            target = requested;
            resizeTransition = false;
            return NativeOperationResult.Success();
        }

        public NativeOperationResult DisableVideoTarget()
        {
            if (state != NativeRecorderState.Recording)
                return NativeOperationResult.Failure(NativeRecorderResult.InvalidState, "No A/V recording is active.");
            target = null;
            resizeTransition = false;
            generation++;
            return NativeOperationResult.Success();
        }

        public void BeginResize()
        {
            resizeTransition = true;
            generation++;
        }

        public void CommitResize() => resizeTransition = false;

        public void TargetClosed()
        {
            target = null;
            resizeTransition = false;
            generation++;
        }

        public void EmitAudio() => AudioPackets++;

        public FrameKind EmitFrame(VideoCaptureTarget callbackTarget, long callbackGeneration)
        {
            var frame = state == NativeRecorderState.Recording && !resizeTransition &&
                target is { } active && callbackGeneration == generation &&
                active.ProcessId == callbackTarget.ProcessId &&
                active.WindowHandle == callbackTarget.WindowHandle &&
                active.ProcessCreationTimeFileTimeUtc == callbackTarget.ProcessCreationTimeFileTimeUtc
                    ? FrameKind.Target : FrameKind.Black;
            frames.Add(frame);
            return frame;
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

    private sealed class AlwaysValidAudio : IAudioBackupValidator
    {
        public bool IsValidNonEmptyAudio(string path) => File.Exists(path) && new FileInfo(path).Length > 0;
    }

    private sealed class AlwaysValidVideo : IVideoMediaValidator
    {
        public bool IsValidNonEmptyVideo(string path) => File.Exists(path) && new FileInfo(path).Length > 0;
    }

    private sealed class AudioOnlyRecoveryValidator : IRecoveryMediaValidator
    {
        public RecoveryMediaValidationResult ValidateToEnd(string path, RecoveryMediaKind mediaKind) =>
            mediaKind == RecoveryMediaKind.AudioOnlyMp4 && File.Exists(path)
                ? RecoveryMediaValidationResult.Valid
                : RecoveryMediaValidationResult.Invalid("Only the final audio-safe MP4 is accepted in this test.");
    }

    private sealed class EmptyVideoTargetCatalog : IVideoCaptureTargetCatalog
    {
        public IReadOnlyList<VideoCaptureTarget> ListTargets() => [];
    }

    private sealed class SingleVideoTargetCatalog(VideoCaptureTarget target) : IVideoCaptureTargetCatalog
    {
        public IReadOnlyList<VideoCaptureTarget> ListTargets() => [target];
    }

    private sealed class LifecycleAudioSafetyBridge(ulong capturedWindowFrames = 0) : INativeRecorderBridge,
        INativeSelectedWindowAvRecorderBridge
    {
        private NativeRecorderState state = NativeRecorderState.Ready;

        public NativeSelectedWindowAvRequest? LastRequest { get; private set; }

        public NativeOperationResult Start(NativeRecordingRequest request) =>
            NativeOperationResult.Failure(NativeRecorderResult.NotImplemented, "Not used.");

        public NativeOperationResult StartMixed(NativeMixedRecordingRequest request) =>
            NativeOperationResult.Failure(NativeRecorderResult.NotImplemented, "Not used.");

        public NativeOperationResult StartSelectedWindowAv(NativeSelectedWindowAvRequest request)
        {
            request.Validate();
            LastRequest = request;
            File.WriteAllBytes(request.AudioRecoveryPath, [1, 2, 3, 4]);
            if (request.WindowTarget is not null)
                File.WriteAllBytes(request.VideoOutputPath, [5, 6, 7, 8]);
            state = NativeRecorderState.Recording;
            return NativeOperationResult.Success();
        }

        public NativeOperationResult Stop()
        {
            state = NativeRecorderState.Stopped;
            return NativeOperationResult.Success();
        }

        public NativeRecorderSnapshot GetSnapshot() => new(
            NativeRecorderResult.Ok,
            state,
            NativeCaptureStats.Empty(RecordingCaptureMode.SelectedWindowAv) with
            {
                CapturedWindowFrames = capturedWindowFrames,
            },
            null);

        public NativeEndpointEnumerationResult EnumerateEndpoints() =>
            new(NativeOperationResult.Success(), Array.Empty<NativeCaptureEndpoint>());

        public void Dispose() { }
    }

    private sealed class TemporaryRoot : IDisposable
    {
        public string Path { get; } = System.IO.Path.Combine(
            System.IO.Path.GetTempPath(), "teams-recorder-dynamic-video-", Guid.NewGuid().ToString("N"));

        public TemporaryRoot() => Directory.CreateDirectory(Path);

        public void Dispose()
        {
            try { Directory.Delete(Path, recursive: true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
