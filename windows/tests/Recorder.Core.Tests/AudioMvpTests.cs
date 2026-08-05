using Recorder.Core;
using TeamsRecorder.Windows.Application;

internal static class AudioMvpTests
{
    public static void MixedRequestValidatesAudioOnlyContract()
    {
        new NativeMixedRecordingRequest("C:\\recordings\\mixed.M4A", null, null, 64_000).Validate();
        new NativeMixedRecordingRequest("C:\\recordings\\mixed.m4a", "render", "microphone", 320_000).Validate();
        if (new NativeMixedRecordingRequest("C:\\recordings\\mixed.m4a").IncludesMicrophone)
            throw new InvalidOperationException("An omitted microphone must remain optional.");

        Throws<ArgumentException>(() => new NativeMixedRecordingRequest("C:\\recordings\\mixed.wav").Validate());
        Throws<ArgumentException>(() => new NativeMixedRecordingRequest(" ").Validate());
        Throws<ArgumentOutOfRangeException>(() => new NativeMixedRecordingRequest("C:\\recordings\\mixed.m4a", AacBitRate: 63_999).Validate());
        Throws<ArgumentOutOfRangeException>(() => new NativeMixedRecordingRequest("C:\\recordings\\mixed.m4a", AacBitRate: 320_001).Validate());
        Throws<ArgumentException>(() => new NativeMixedRecordingRequest("C:\\recordings\\mixed.m4a", " ").Validate());
        Throws<ArgumentException>(() => new NativeMixedRecordingRequest("C:\\recordings\\mixed.m4a", MicrophoneEndpointId: "\0").Validate());
    }

    public static void MixedCoordinatorStartsStopsAndRetries()
    {
        var bridge = new MixedBridge();
        var coordinator = new RecordingCoordinator(bridge);
        var request = new NativeMixedRecordingRequest("C:\\recordings\\mixed.m4a", "render-1", "mic-1", 192_000);

        var started = coordinator.StartMixedAsync(request).GetAwaiter().GetResult();
        Equal(RecordingCoordinatorState.Recording, started.State);
        Equal(request, bridge.LastMixedRequest!);
        Equal(1, bridge.MixedStartCalls);
        Equal(0, bridge.RegularStartCalls);
        Equal(RecordingCaptureMode.Mixed, started.Stats.Mode);
        Equal(RecordingCoordinatorState.Stopped, coordinator.StopAsync().GetAwaiter().GetResult().State);
        Equal(1, bridge.StopCalls);

        bridge.MixedStartResult = NativeOperationResult.Failure(NativeRecorderResult.CaptureError, "mic unavailable");
        var failed = coordinator.StartMixedAsync(request).GetAwaiter().GetResult();
        Equal(RecordingCoordinatorState.Failed, failed.State);
        Equal("mic unavailable", failed.Error!);
        bridge.MixedStartResult = NativeOperationResult.Success();
        var retried = coordinator.StartMixedAsync(request with { OutputPath = "C:\\recordings\\retry.m4a", MicrophoneEndpointId = null }).GetAwaiter().GetResult();
        Equal(RecordingCoordinatorState.Recording, retried.State);
        Equal(3L, retried.Generation);
    }

    public static void MixedTestRecordingStopsAfterScheduledDelay()
    {
        var bridge = new MixedBridge();
        var delay = new TestDelay();
        var coordinator = new RecordingCoordinator(bridge, delay);
        var started = coordinator.StartMixedTestAsync(new NativeMixedRecordingRequest("C:\\recordings\\test.m4a"), TimeSpan.FromSeconds(1)).GetAwaiter().GetResult();
        Equal(RecordingCoordinatorState.Recording, started.State);
        if (!started.IsTestRecording) throw new InvalidOperationException("Expected a mixed test recording.");
        if (!delay.Entered.Task.Wait(TimeSpan.FromSeconds(2))) throw new InvalidOperationException("The mixed test delay was not scheduled.");
        delay.Complete();
        SpinWait.SpinUntil(() => coordinator.Snapshot.State == RecordingCoordinatorState.Stopped, TimeSpan.FromSeconds(2));
        Equal(RecordingCoordinatorState.Stopped, coordinator.Snapshot.State);
        Equal(1, bridge.MixedStartCalls);
        Equal(1, bridge.StopCalls);
    }

    public static void SelectedAudioTestCancelsWithoutFallbackOrDoubleStop()
    {
        var bridge = new MixedBridge();
        var delay = new TestDelay();
        var coordinator = new RecordingCoordinator(bridge, delay);
        var request = new NativeSelectedAudioRequest(
            NativeSelectedAudioSource.ProcessTreeLoopback,
            "C:\\recordings\\selected-test.m4a",
            MicrophoneEndpointId: "capture-usb",
            TargetProcessId: 71,
            IncludedProcessTree: true,
            ExpectedProcessCreationTime100Nanoseconds: 1);

        var started = coordinator.StartSelectedAudioTestAsync(request, TimeSpan.FromSeconds(10)).GetAwaiter().GetResult();
        Equal(RecordingCoordinatorState.Recording, started.State);
        if (!started.IsTestRecording) throw new InvalidOperationException("Expected a selected-audio test recording.");
        if (!delay.Entered.Task.Wait(TimeSpan.FromSeconds(2))) throw new InvalidOperationException("The selected-audio test delay was not scheduled.");

        Equal(RecordingCoordinatorState.Stopped, coordinator.StopAsync().GetAwaiter().GetResult().State);
        delay.Complete();
        Thread.Sleep(50);
        Equal(1, bridge.SelectedStartCalls);
        Equal(0, bridge.MixedStartCalls);
        Equal(1, bridge.StopCalls);
    }

    public static void SelectedAudioRequestRejectsFallbackShapedOptions()
    {
        new NativeSelectedAudioRequest(
            NativeSelectedAudioSource.SystemLoopback,
            "C:\\recordings\\system.m4a",
            MicrophoneEndpointId: "capture-usb").Validate();
        new NativeSelectedAudioRequest(
            NativeSelectedAudioSource.ProcessTreeLoopback,
            "C:\\recordings\\process.m4a",
            TargetProcessId: 71,
            IncludedProcessTree: true,
            ExpectedProcessCreationTime100Nanoseconds: 1).Validate();

        Throws<ArgumentException>(() => new NativeSelectedAudioRequest(
            NativeSelectedAudioSource.ProcessTreeLoopback,
            "C:\\recordings\\process.m4a",
            RenderEndpointId: "render-default",
            TargetProcessId: 71,
            IncludedProcessTree: true,
            ExpectedProcessCreationTime100Nanoseconds: 1).Validate());
        Throws<ArgumentException>(() => new NativeSelectedAudioRequest(
            NativeSelectedAudioSource.SystemLoopback,
            "C:\\recordings\\system.m4a",
            TargetProcessId: 71).Validate());
        Throws<ArgumentException>(() => new NativeSelectedAudioRequest(
            NativeSelectedAudioSource.ProcessTreeLoopback,
            "C:\\recordings\\process.m4a",
            TargetProcessId: 71,
            IncludedProcessTree: true).Validate());
    }

    public static void RecoverableFaultRetainsEvidenceAndAllowsRestart()
    {
        using var root = new TemporaryRoot();
        var bridge = new MixedBridge { WriteOutputOnStart = true };
        using var lifecycle = new RecordingLifecycleService(bridge, root.Path);
        var first = lifecycle.StartMixedAsync(
            RecordingSessionKind.Manual,
            renderEndpointId: null,
            microphoneEndpointId: null).GetAwaiter().GetResult();
        var oldGeneration = first.Snapshot.Generation;

        bridge.SourceFaulted = true;
        var faulted = lifecycle.RefreshAsync().GetAwaiter().GetResult();
        Equal(RecordingCoordinatorState.Faulted, faulted.State);
        Equal(true, faulted.HasRecoverableFault);

        var recovery = lifecycle.FinalizeForRecoveryAsync().GetAwaiter().GetResult();
        if (recovery.Published || !File.Exists(first.Session.BackupAudioPath) ||
            File.Exists(first.Session.FinalAudioPath))
        {
            throw new InvalidOperationException(
                "A recoverable capture fault was incorrectly published as a clean recording.");
        }
        if (recovery.Error?.Message.Contains("device invalidated", StringComparison.Ordinal) != true)
        {
            throw new InvalidOperationException("Fault recovery discarded the native diagnostic.");
        }
        if (lifecycle.Snapshot.State != RecordingCoordinatorState.Stopped ||
            !lifecycle.Snapshot.HasRecoverableFault ||
            lifecycle.Snapshot.Generation <= oldGeneration)
        {
            throw new InvalidOperationException(
                "Fault recovery did not produce a restartable generation while retaining its fault marker.");
        }

        var recoveredGeneration = lifecycle.Snapshot.Generation;
        bridge.SourceFaulted = false;
        var restarted = lifecycle.StartMixedAsync(
            RecordingSessionKind.Manual,
            renderEndpointId: null,
            microphoneEndpointId: null).GetAwaiter().GetResult();
        Equal(RecordingCoordinatorState.Recording, restarted.Snapshot.State);
        Equal(false, restarted.Snapshot.HasRecoverableFault);
        if (restarted.Snapshot.Generation <= recoveredGeneration)
        {
            throw new InvalidOperationException("A restarted recording reused a recovered generation.");
        }
        lifecycle.StopAsync().GetAwaiter().GetResult();
    }

    public static void WindowVideoLifecyclePublishesFinalNativeIntervalAndFailsClosed()
    {
        using var root = new TemporaryRoot();
        var successBridge = new MixedBridge { WriteOutputOnStart = true, WriteVideoOutputOnStart = true };
        using (var lifecycle = new RecordingLifecycleService(successBridge, root.Path))
        {
            var started = lifecycle.StartMixedAsync(RecordingSessionKind.Manual, null, null).GetAwaiter().GetResult();
            var videoStart = lifecycle.StartWindowVideo(new NativeWindowVideoRecordingRequest(
                1, Path.Combine(started.Session.FolderPath, RecordingSessionLayout.FinalVideoFileName)));
            if (!videoStart.IsSuccess) throw new InvalidOperationException("The fake video companion did not start.");
            lifecycle.StopAsync().GetAwaiter().GetResult();
            var published = lifecycle.PublishCompletedAsync().GetAwaiter().GetResult();
            var info = RecordingInfoJson.Parse(File.ReadAllText(started.Session.MetadataPath));
            var interval = info.Document["screenIntervals"] as System.Text.Json.Nodes.JsonArray;
            if (!published.Published || successBridge.StopCalls != 1 || successBridge.StopWindowVideoCalls != 0 ||
                info.MediaKind != "video" || interval is not { Count: 1 } ||
                interval[0]?["startSeconds"]?.GetValue<double>() != 1.25 ||
                interval[0]?["endSeconds"]?.GetValue<double>() != 4.5)
                throw new InvalidOperationException("Lifecycle did not publish the final native MP4 interval through unified stop.");
        }

        var failedBridge = new MixedBridge { WriteOutputOnStart = true, WriteVideoOutputOnStart = true, FinalVideoStatsAreValid = false };
        using (var lifecycle = new RecordingLifecycleService(failedBridge, root.Path))
        {
            var started = lifecycle.StartMixedAsync(RecordingSessionKind.Manual, null, null).GetAwaiter().GetResult();
            lifecycle.StartWindowVideo(new NativeWindowVideoRecordingRequest(
                1, Path.Combine(started.Session.FolderPath, RecordingSessionLayout.FinalVideoFileName)));
            lifecycle.StopAsync().GetAwaiter().GetResult();
            var published = lifecycle.PublishCompletedAsync().GetAwaiter().GetResult();
            var info = RecordingInfoJson.Parse(File.ReadAllText(started.Session.MetadataPath));
            if (!published.Published || failedBridge.StopWindowVideoCalls != 0 ||
                info.MediaKind != "audio" || info.RecoveryState != RecordingRecoveryState.VideoLostAudioPreserved)
                throw new InvalidOperationException("Invalid final video stats did not retain audio with the video-loss recovery marker.");
        }
    }

    private static void Equal<T>(T expected, T actual) where T : notnull { if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new InvalidOperationException($"Expected {expected}; got {actual}."); }
    private static void Throws<T>(Action action) where T : Exception { try { action(); } catch (T) { return; } throw new InvalidOperationException($"Expected {typeof(T).Name}."); }

    private sealed class MixedBridge : INativeRecorderBridge, INativeSelectedAudioRecorderBridge, INativeWindowVideoRecorderBridge
    {
        public NativeOperationResult MixedStartResult { get; set; } = NativeOperationResult.Success();
        public NativeMixedRecordingRequest? LastMixedRequest { get; private set; }
        public NativeSelectedAudioRequest? LastSelectedRequest { get; private set; }
        public int MixedStartCalls { get; private set; }
        public int SelectedStartCalls { get; private set; }
        public int RegularStartCalls { get; private set; }
        public int StopCalls { get; private set; }
        public int StopWindowVideoCalls { get; private set; }
        public bool SourceFaulted { get; set; }
        public bool WriteOutputOnStart { get; init; }
        public bool WriteVideoOutputOnStart { get; init; }
        public bool FinalVideoStatsAreValid { get; init; } = true;
        private bool videoRunning;
        private NativeRecorderState state = NativeRecorderState.Ready;
        public NativeOperationResult Start(NativeRecordingRequest request) { RegularStartCalls++; state = NativeRecorderState.Recording; return NativeOperationResult.Success(); }
        public NativeOperationResult StartMixed(NativeMixedRecordingRequest request)
        {
            request.Validate();
            LastMixedRequest = request;
            MixedStartCalls++;
            if (MixedStartResult.IsSuccess)
            {
                if (WriteOutputOnStart) File.WriteAllBytes(request.OutputPath, [1, 2, 3, 4]);
                state = NativeRecorderState.Recording;
            }
            return MixedStartResult;
        }
        public NativeOperationResult StartSelectedAudio(NativeSelectedAudioRequest request) { request.Validate(); LastSelectedRequest = request; SelectedStartCalls++; state = NativeRecorderState.Recording; return NativeOperationResult.Success(); }
        public NativeOperationResult Stop() { StopCalls++; state = NativeRecorderState.Stopped; videoRunning = false; return NativeOperationResult.Success(); }
        public NativeOperationResult StartWindowVideo(NativeWindowVideoRecordingRequest request)
        {
            request.Validate();
            if (WriteVideoOutputOnStart) File.WriteAllBytes(request.OutputPath, [9, 8, 7]);
            videoRunning = true;
            return NativeOperationResult.Success();
        }
        public NativeOperationResult StopWindowVideo() { StopWindowVideoCalls++; videoRunning = false; return NativeOperationResult.Success(); }
        public NativeWindowVideoSnapshot GetWindowVideoSnapshot()
        {
            var operation = FinalVideoStatsAreValid ? NativeOperationResult.Success() :
                NativeOperationResult.Failure(NativeRecorderResult.CaptureError, "final MP4 flush failed");
            return new NativeWindowVideoSnapshot(operation, videoRunning, 2, 2, 0, 0,
                12_500_000, FinalVideoStatsAreValid ? 45_000_000UL : 0UL);
        }
        public NativeRecorderSnapshot GetSnapshot() => SourceFaulted
            ? new(
                NativeRecorderResult.CaptureError,
                NativeRecorderState.Faulted,
                NativeCaptureStats.Empty(RecordingCaptureMode.Mixed),
                "device invalidated")
            : new(
                NativeRecorderResult.Ok,
                state,
                NativeCaptureStats.Empty(RecordingCaptureMode.Mixed),
                null);
        public NativeEndpointEnumerationResult EnumerateEndpoints() => new(NativeOperationResult.Success(), Array.Empty<NativeCaptureEndpoint>());
        public void Dispose() { }
    }

    private sealed class TemporaryRoot : IDisposable
    {
        public string Path { get; } = System.IO.Path.Combine(
            System.IO.Path.GetTempPath(),
            "recorder-audio-mvp-tests",
            Guid.NewGuid().ToString("N"));

        public void Dispose()
        {
            if (Directory.Exists(Path)) Directory.Delete(Path, recursive: true);
        }
    }

    private sealed class TestDelay : IRecordingDelay
    {
        private readonly TaskCompletionSource completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Entered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Task DelayAsync(TimeSpan duration, CancellationToken cancellationToken) { Entered.TrySetResult(); return completion.Task.WaitAsync(cancellationToken); }
        public void Complete() => completion.TrySetResult();
    }
}
