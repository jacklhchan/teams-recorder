using Recorder.Core;
using TeamsRecorder.Windows.Application;
using TeamsRecorder.Windows.Application.Recovery;
using TeamsRecorder.Windows.Application.Storage;

internal static class RecoveryJournalLifecycleTests
{
    public static void LifecycleHoldsLockAndPersistsOnlyNativeDurableCheckpoints()
    {
        using var root = new TemporaryRoot();
        var bridge = new CheckpointBridge();
        using var lifecycle = new RecordingLifecycleService(
            bridge,
            root.Path,
            audioValidator: new NonEmptyAudioValidator());

        var started = lifecycle.StartMixedAsync(
            RecordingSessionKind.Manual,
            renderEndpointId: null,
            microphoneEndpointId: null).GetAwaiter().GetResult();

        var competingStorage = new SessionStorageService(root.Path, audioValidator: new NonEmptyAudioValidator());
        Throws<IOException>(() => competingStorage.AcquireActiveLock(started.Session));
        if (File.Exists(started.Session.RecoveryJournalPath))
            throw new InvalidOperationException("A journal was written before a native durable checkpoint existed.");

        bridge.Stats = NativeCaptureStats.Empty(RecordingCaptureMode.Mixed) with
        {
            AudioDurableCheckpoint = new NativeDurableCheckpoint(3, 4_096, 20_000_000),
        };
        _ = lifecycle.RefreshAsync().GetAwaiter().GetResult();

        if (!SpinWait.SpinUntil(
                () => File.Exists(started.Session.RecoveryJournalPath),
                TimeSpan.FromSeconds(2)))
        {
            throw new InvalidOperationException("The native checkpoint was not durably handed to managed recovery.");
        }

        var journal = competingStorage.ReadRecoveryJournal(started.Session)
            ?? throw new InvalidOperationException("The recovery journal was unreadable.");
        if (!journal.IsValid() || journal.AudioVideo is not null ||
            journal.AudioSafety is not { DurableByteOffset: 4_096, PresentationTime100Nanoseconds: 20_000_000 })
        {
            throw new InvalidOperationException("The journal changed or inferred the native durability boundary.");
        }

        _ = lifecycle.StopAsync().GetAwaiter().GetResult();
        _ = lifecycle.PublishCompletedAsync().GetAwaiter().GetResult();
        using var acquiredAfterPublication = competingStorage.AcquireActiveLock(started.Session);
    }

    private static void Throws<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }

    private sealed class NonEmptyAudioValidator : IAudioBackupValidator
    {
        public bool IsValidNonEmptyAudio(string path) =>
            File.Exists(path) && new FileInfo(path).Length > 0;
    }

    private sealed class CheckpointBridge : INativeRecorderBridge
    {
        private NativeRecorderState state = NativeRecorderState.Ready;
        public NativeCaptureStats Stats { get; set; } = NativeCaptureStats.Empty(RecordingCaptureMode.Mixed);

        public NativeOperationResult Start(NativeRecordingRequest request) =>
            NativeOperationResult.Failure(NativeRecorderResult.NotImplemented, "Not used.");

        public NativeOperationResult StartMixed(NativeMixedRecordingRequest request)
        {
            request.Validate();
            File.WriteAllBytes(request.OutputPath, [1, 2, 3, 4]);
            state = NativeRecorderState.Recording;
            return NativeOperationResult.Success();
        }

        public NativeOperationResult Stop()
        {
            state = NativeRecorderState.Stopped;
            return NativeOperationResult.Success();
        }

        public NativeRecorderSnapshot GetSnapshot() =>
            new(NativeRecorderResult.Ok, state, Stats, null);

        public NativeEndpointEnumerationResult EnumerateEndpoints() =>
            new(NativeOperationResult.Success(), Array.Empty<NativeCaptureEndpoint>());

        public void Dispose() { }
    }

    private sealed class TemporaryRoot : IDisposable
    {
        public TemporaryRoot()
        {
            Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "recorder-journal-lifecycle-" + Guid.NewGuid().ToString("N"));
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
