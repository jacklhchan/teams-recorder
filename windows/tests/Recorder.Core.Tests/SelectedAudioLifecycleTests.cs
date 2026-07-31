using Recorder.Core;
using TeamsRecorder.Windows.Application;
using TeamsRecorder.Windows.Application.Recovery;
using TeamsRecorder.Windows.Application.Storage;

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
        if (recovery.Error?.Message.Contains("target exited", StringComparison.Ordinal) != true)
            throw new InvalidOperationException("Fault recovery discarded the native diagnostic that explains the retained evidence.");
        Equal(RecordingOwner.None, lifecycle.Owner);
    }

    public static void FaultFinalizationAllowsRestartAndInvalidatesOldGeneration()
    {
        using var root = new TemporaryRoot();
        var bridge = new SelectedBridge();
        var target = Target();
        using var lifecycle = new RecordingLifecycleService(bridge, root.Path, new CurrentProcessCatalog(target));
        var first = lifecycle.StartAsync(new RecordingStartRequest(
            RecordingSessionKind.Manual,
            RecordingAudioSource.SelectedProcessLoopback,
            ProcessTarget: target,
            IncludeProcessTree: true)).GetAwaiter().GetResult();
        var oldGeneration = first.Snapshot.Generation;

        bridge.SourceFaulted = true;
        Equal(RecordingCoordinatorState.Faulted, lifecycle.RefreshAsync().GetAwaiter().GetResult().State);
        var retained = lifecycle.FinalizeForRecoveryAsync().GetAwaiter().GetResult();
        if (retained.Published || !File.Exists(first.Session.BackupAudioPath))
            throw new InvalidOperationException("Fault finalization did not retain the first session evidence.");
        if (lifecycle.Snapshot.State != RecordingCoordinatorState.Stopped ||
            !lifecycle.Snapshot.HasRecoverableFault ||
            lifecycle.Snapshot.Generation <= oldGeneration)
        {
            throw new InvalidOperationException("Fault cleanup did not invalidate the old generation into a restartable state.");
        }

        var recoveredGeneration = lifecycle.Snapshot.Generation;
        bridge.SourceFaulted = false;
        var second = lifecycle.StartAsync(new RecordingStartRequest(
            RecordingSessionKind.Manual,
            RecordingAudioSource.SystemLoopback)).GetAwaiter().GetResult();
        Equal(RecordingCoordinatorState.Recording, second.Snapshot.State);
        if (second.Snapshot.Generation <= recoveredGeneration || bridge.MixedStartCalls != 1)
            throw new InvalidOperationException("A second recording did not replace the cleaned-up selected session.");
    }

    public static void RelaunchRecoveryRetainsSelectedCaptureProvenance()
    {
        using var root = new TemporaryRoot();
        var bridge = new SelectedBridge { SourceFaulted = true };
        var target = Target();
        RecordingSessionPlan plan;
        using (var lifecycle = new RecordingLifecycleService(bridge, root.Path, new CurrentProcessCatalog(target)))
        {
            var started = lifecycle.StartAsync(new RecordingStartRequest(
                RecordingSessionKind.Meeting,
                RecordingAudioSource.SelectedProcessLoopback,
                ProcessTarget: target,
                IncludeProcessTree: true)).GetAwaiter().GetResult();
            plan = started.Session;
            Equal(RecordingCoordinatorState.Faulted, lifecycle.RefreshAsync().GetAwaiter().GetResult().State);
            var retained = lifecycle.FinalizeForRecoveryAsync().GetAwaiter().GetResult();
            if (retained.Published || !File.Exists(plan.BackupAudioPath))
                throw new InvalidOperationException("The selected session backup was not retained before relaunch recovery.");
        }

        var storage = new TeamsRecorder.Windows.Application.Storage.SessionStorageService(root.Path);
        var recovery = new SessionRecoveryService(storage, new AlwaysValidAudio());
        var result = recovery.RecoverAsync().GetAwaiter().GetResult();
        if (result.Count != 1 || !result[0].Recovered || !File.Exists(plan.FinalAudioPath))
            throw new InvalidOperationException("Startup recovery did not promote the retained selected session.");

        var metadata = RecordingInfoJson.Parse(File.ReadAllText(plan.MetadataPath));
        Equal("teamsAutomatic", metadata.Source);
        Equal(0, metadata.Participants.Count);
        Equal(WindowsCaptureMetadata.SelectedProcessLoopback, metadata.WindowsCapture?.AudioSource);
        Equal("ms-teams.exe", metadata.WindowsCapture?.ProcessName);
        Equal(true, metadata.WindowsCapture?.IncludedProcessTree);
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
        public int MixedStartCalls { get; private set; }
        public bool SourceFaulted { get; set; }

        public NativeOperationResult Start(NativeRecordingRequest request) =>
            NativeOperationResult.Failure(NativeRecorderResult.NotImplemented, "Legacy capture is not part of this test.");

        public NativeOperationResult StartMixed(NativeMixedRecordingRequest request)
        {
            MixedStartCalls++;
            File.WriteAllBytes(request.OutputPath, [1, 2, 3, 4]);
            state = NativeRecorderState.Recording;
            return NativeOperationResult.Success();
        }

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
            state = NativeRecorderState.Stopped;
            return StopResult;
        }

        public NativeRecorderSnapshot GetSnapshot() => SourceFaulted
            ? new(
                NativeRecorderResult.CaptureError,
                NativeRecorderState.Faulted,
                NativeCaptureStats.Empty(RecordingCaptureMode.SelectedAppMixed),
                "target exited")
            : new(
                NativeRecorderResult.Ok,
                state,
                NativeCaptureStats.Empty(RecordingCaptureMode.SelectedAppMixed),
                null);

        public NativeEndpointEnumerationResult EnumerateEndpoints() =>
            new(NativeOperationResult.Success(), Array.Empty<NativeCaptureEndpoint>());

        public void Dispose() { }
    }

    private sealed class AlwaysValidAudio : IAudioBackupValidator
    {
        public bool IsValidNonEmptyAudio(string path) => File.Exists(path) && new FileInfo(path).Length > 0;
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
