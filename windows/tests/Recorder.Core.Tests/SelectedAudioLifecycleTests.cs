using Recorder.Core;
using TeamsRecorder.Windows.Application;

internal static class SelectedAudioLifecycleTests
{
    public static void TestAutoStopPublishesExactlyOnce()
    {
        using var root = new TemporaryRoot();
        var bridge = new SelectedBridge();
        var delay = new ControlledDelay();
        var target = Target();
        using var lifecycle = new RecordingLifecycleService(
            bridge,
            root.Path,
            new CurrentProcessCatalog(target),
            delay);

        var started = lifecycle.StartAsync(new RecordingStartRequest(
            RecordingSessionKind.Test,
            RecordingAudioSource.SelectedProcessLoopback,
            MicrophoneEndpointId: "capture-usb",
            ProcessTarget: target,
            IncludeProcessTree: true,
            TestDuration: TimeSpan.FromSeconds(10))).GetAwaiter().GetResult();

        Equal(RecordingCoordinatorState.Recording, started.Snapshot.State);
        if (!delay.Entered.Task.Wait(TimeSpan.FromSeconds(2)))
            throw new InvalidOperationException("Selected test delay was not scheduled.");
        delay.Complete();
        if (!SpinWait.SpinUntil(() => lifecycle.Snapshot.State == RecordingCoordinatorState.Stopped, TimeSpan.FromSeconds(2)))
            throw new InvalidOperationException("Selected test did not auto-stop.");

        var publication = lifecycle.PublishCompletedAsync().GetAwaiter().GetResult();
        if (!publication.Published || !File.Exists(started.Session.FinalAudioPath))
            throw new InvalidOperationException("Selected test did not publish its completed M4A session.");
        Equal(1, bridge.StopCalls);
        if (lifecycle.PublishCompletedAsync().GetAwaiter().GetResult().Session is not null)
            throw new InvalidOperationException("A selected test session was published more than once.");

        var metadata = RecordingInfoJson.Parse(File.ReadAllText(started.Session.MetadataPath));
        Equal(WindowsCaptureMetadata.SelectedProcessLoopback, metadata.WindowsCapture?.AudioSource);
        Equal("ms-teams.exe", metadata.WindowsCapture?.ProcessName);
    }

    public static void ProcessDisappearanceFailsClosedAndCleansOnlyEmptyFolder()
    {
        using var root = new TemporaryRoot();
        using var lifecycle = new RecordingLifecycleService(
            new SelectedBridge(),
            root.Path,
            new CurrentProcessCatalog(current: null));

        Throws<InvalidOperationException>(() => lifecycle.StartAsync(new RecordingStartRequest(
            RecordingSessionKind.Manual,
            RecordingAudioSource.SelectedProcessLoopback,
            ProcessTarget: Target(),
            IncludeProcessTree: true)).GetAwaiter().GetResult());

        if (Directory.EnumerateFileSystemEntries(root.Path).Any())
            throw new InvalidOperationException("A disappeared process left an empty or fallback session behind.");
    }

    public static void RecoverableSelectedFaultKeepsAccumulatedBackup()
    {
        using var root = new TemporaryRoot();
        var bridge = new SelectedBridge { StopResult = NativeOperationResult.Failure(NativeRecorderResult.CaptureError, "target exited") };
        var target = Target();
        using var lifecycle = new RecordingLifecycleService(bridge, root.Path, new CurrentProcessCatalog(target));
        var started = lifecycle.StartAsync(new RecordingStartRequest(
            RecordingSessionKind.Meeting,
            RecordingAudioSource.SelectedProcessLoopback,
            ProcessTarget: target,
            IncludeProcessTree: true)).GetAwaiter().GetResult();
        Equal(RecordingOwner.TeamsAutomatic, lifecycle.Owner);

        var recovery = lifecycle.FinalizeForRecoveryAsync().GetAwaiter().GetResult();
        if (recovery.Published || !File.Exists(started.Session.BackupAudioPath))
            throw new InvalidOperationException("A selected-process fault discarded accumulated recovery media.");
        Equal(RecordingOwner.None, lifecycle.Owner);
    }

    private static SelectedProcessTarget Target() => new(
        71,
        new DateTimeOffset(2026, 7, 30, 5, 0, 0, TimeSpan.Zero),
        "ms-teams");

    private static void Equal<T>(T expected, T? actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual!))
            throw new InvalidOperationException($"Expected {expected}; got {actual}.");
    }

    private static void Throws<TException>(Action action) where TException : Exception
    {
        try { action(); }
        catch (TException) { return; }
        throw new InvalidOperationException($"Expected {typeof(TException).Name}.");
    }

    private sealed class CurrentProcessCatalog(SelectedProcessTarget? current) : IProcessCatalog
    {
        public IReadOnlyList<ProcessCatalogEntry> GetProcesses() => Array.Empty<ProcessCatalogEntry>();

        public bool IsCurrent(SelectedProcessTarget target) => current is not null &&
            current.ProcessId == target.ProcessId &&
            current.StartedAt == target.StartedAt &&
            string.Equals(current.ProcessName, target.ProcessName, StringComparison.Ordinal);
    }

    private sealed class SelectedBridge : INativeRecorderBridge, INativeSelectedAudioRecorderBridge
    {
        private NativeRecorderState state = NativeRecorderState.Ready;
        public NativeOperationResult StopResult { get; init; } = NativeOperationResult.Success();
        public int StopCalls { get; private set; }

        public NativeOperationResult Start(NativeRecordingRequest request) =>
            NativeOperationResult.Failure(NativeRecorderResult.NotImplemented, "Legacy capture is not part of this test.");

        public NativeOperationResult StartMixed(NativeMixedRecordingRequest request) =>
            NativeOperationResult.Failure(NativeRecorderResult.NotImplemented, "System capture is not part of this test.");

        public NativeOperationResult StartSelectedAudio(NativeSelectedAudioRequest request)
        {
            request.Validate();
            File.WriteAllBytes(request.OutputPath, [1, 2, 3, 4]);
            state = NativeRecorderState.Recording;
            return NativeOperationResult.Success();
        }

        public NativeOperationResult Stop()
        {
            StopCalls++;
            if (StopResult.IsSuccess) state = NativeRecorderState.Stopped;
            return StopResult;
        }

        public NativeRecorderSnapshot GetSnapshot() => new(
            NativeRecorderResult.Ok,
            state,
            NativeCaptureStats.Empty(RecordingCaptureMode.SelectedAppMixed),
            null);

        public NativeEndpointEnumerationResult EnumerateEndpoints() =>
            new(NativeOperationResult.Success(), Array.Empty<NativeCaptureEndpoint>());

        public void Dispose() { }
    }

    private sealed class ControlledDelay : IRecordingDelay
    {
        private readonly TaskCompletionSource completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Entered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Task DelayAsync(TimeSpan duration, CancellationToken cancellationToken)
        {
            Entered.TrySetResult();
            return completion.Task.WaitAsync(cancellationToken);
        }

        public void Complete() => completion.TrySetResult();
    }

    private sealed class TemporaryRoot : IDisposable
    {
        public TemporaryRoot()
        {
            Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "teams-recorder-selected-audio-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Path);
        }

        public string Path { get; }

        public void Dispose()
        {
            if (Directory.Exists(Path)) Directory.Delete(Path, recursive: true);
        }
    }
}
