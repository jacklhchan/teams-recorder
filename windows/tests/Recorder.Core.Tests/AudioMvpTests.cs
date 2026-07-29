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

    private static void Equal<T>(T expected, T actual) where T : notnull { if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new InvalidOperationException($"Expected {expected}; got {actual}."); }
    private static void Throws<T>(Action action) where T : Exception { try { action(); } catch (T) { return; } throw new InvalidOperationException($"Expected {typeof(T).Name}."); }

    private sealed class MixedBridge : INativeRecorderBridge
    {
        public NativeOperationResult MixedStartResult { get; set; } = NativeOperationResult.Success();
        public NativeMixedRecordingRequest? LastMixedRequest { get; private set; }
        public int MixedStartCalls { get; private set; }
        public int RegularStartCalls { get; private set; }
        public int StopCalls { get; private set; }
        private NativeRecorderState state = NativeRecorderState.Ready;
        public NativeOperationResult Start(NativeRecordingRequest request) { RegularStartCalls++; state = NativeRecorderState.Recording; return NativeOperationResult.Success(); }
        public NativeOperationResult StartMixed(NativeMixedRecordingRequest request) { request.Validate(); LastMixedRequest = request; MixedStartCalls++; if (MixedStartResult.IsSuccess) state = NativeRecorderState.Recording; return MixedStartResult; }
        public NativeOperationResult Stop() { StopCalls++; state = NativeRecorderState.Stopped; return NativeOperationResult.Success(); }
        public NativeRecorderSnapshot GetSnapshot() => new(NativeRecorderResult.Ok, state, NativeCaptureStats.Empty(RecordingCaptureMode.Mixed), null);
        public NativeEndpointEnumerationResult EnumerateEndpoints() => new(NativeOperationResult.Success(), Array.Empty<NativeCaptureEndpoint>());
        public void Dispose() { }
    }

    private sealed class TestDelay : IRecordingDelay
    {
        private readonly TaskCompletionSource completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Entered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Task DelayAsync(TimeSpan duration, CancellationToken cancellationToken) { Entered.TrySetResult(); return completion.Task.WaitAsync(cancellationToken); }
        public void Complete() => completion.TrySetResult();
    }
}
