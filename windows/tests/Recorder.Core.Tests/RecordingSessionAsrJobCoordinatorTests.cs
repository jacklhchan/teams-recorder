using Recorder.Core;
using TeamsRecorder.Windows.Application.AI;
using TeamsRecorder.Windows.Application.Storage;
using TeamsRecorder.Windows.Application.Transcription;

internal static class RecordingSessionAsrJobCoordinatorTests
{
    public static void TranscribesOnlyAnExplicitCompletedSessionAndPublishesArtifacts()
    {
        using var root = new TestRoot();
        var plan = CompletedPlan(root.Path, [1, 2, 3]);
        var transcriber = new FakeTranscriber(new OpenAICompatibleAsrResult("會議逐字稿", OpenAICompatibleAsrResponseFormat.VerboseJson));
        using var coordinator = Coordinator(transcriber);

        Throws<InvalidOperationException>(() => coordinator.StartAsync(plan, explicitlyOptedIn: false).GetAwaiter().GetResult());
        if (transcriber.Calls != 0 || File.Exists(Path.Combine(plan.FolderPath, TranscriptionArtifactPublisher.StateFileName)))
            throw new InvalidOperationException("ASR was started without explicit opt-in.");

        var job = coordinator.StartAsync(plan, explicitlyOptedIn: true).GetAwaiter().GetResult();
        job.Completion.GetAwaiter().GetResult();
        var state = new TranscriptionArtifactPublisher().LoadState(plan);
        if (transcriber.Calls != 1 || !System.Linq.Enumerable.SequenceEqual(transcriber.Audio, new byte[] { 1, 2, 3 }) || state?.Phase != TranscriptionPhase.Completed ||
            File.ReadAllText(Path.Combine(plan.FolderPath, TranscriptionArtifactPublisher.TranscriptFileName)) != "會議逐字稿")
            throw new InvalidOperationException("Completed M4A transcription was not safely published.");
    }

    public static void RejectsPartialForeignAndOversizedMediaWithoutUploading()
    {
        using var root = new TestRoot();
        var fake = new FakeTranscriber(new OpenAICompatibleAsrResult("unused", OpenAICompatibleAsrResponseFormat.Json));
        using var coordinator = Coordinator(fake);
        var plan = CompletedPlan(root.Path, [1]);
        var foreign = plan with
        {
            FolderPath = root.Path,
            FinalAudioPath = Path.Combine(root.Path, RecordingSessionLayout.FinalAudioFileName)
        };
        File.WriteAllBytes(foreign.FinalAudioPath, [1]);
        Throws<IOException>(() => coordinator.StartAsync(foreign, true).GetAwaiter().GetResult());
        File.Move(plan.FinalAudioPath, plan.BackupAudioPath);
        Throws<IOException>(() => coordinator.StartAsync(plan, true).GetAwaiter().GetResult());

        File.WriteAllBytes(plan.FinalAudioPath, new byte[OpenAICompatibleAsrClient.MaximumAudioBytes + 1]);
        Throws<OpenAICompatibleAsrException>(() => coordinator.StartAsync(plan, true).GetAwaiter().GetResult(), error => error.Failure == OpenAICompatibleAsrFailure.AudioChunkTooLarge);
        if (fake.Calls != 0) throw new InvalidOperationException("Invalid media must never be uploaded.");
    }

    public static void EnforcesOneJobAndRecordsCancellationOrProviderFailure()
    {
        using var root = new TestRoot();
        var plan = CompletedPlan(root.Path, [9]);
        var delayed = new WaitingTranscriber();
        using var coordinator = Coordinator(delayed);
        var job = coordinator.StartAsync(plan, true).GetAwaiter().GetResult();
        delayed.Started.Task.GetAwaiter().GetResult();
        if (new TranscriptionArtifactPublisher().LoadState(plan)?.Phase != TranscriptionPhase.Transcribing)
            throw new InvalidOperationException("An active job must expose a durable transcribing state.");
        Throws<InvalidOperationException>(() => coordinator.StartAsync(plan, true).GetAwaiter().GetResult());
        job.Cancel();
        Throws<OperationCanceledException>(() => job.Completion.GetAwaiter().GetResult());
        if (new TranscriptionArtifactPublisher().LoadState(plan)?.Phase != TranscriptionPhase.Cancelled)
            throw new InvalidOperationException("Cancelled jobs must retain a terminal cancelled state.");

        var failing = new FakeTranscriber(new IOException("provider unavailable"));
        using var failingCoordinator = Coordinator(failing);
        var failed = failingCoordinator.StartAsync(plan, true).GetAwaiter().GetResult();
        Throws<IOException>(() => failed.Completion.GetAwaiter().GetResult());
        var failedState = new TranscriptionArtifactPublisher().LoadState(plan);
        if (failedState?.Phase != TranscriptionPhase.Failed || File.Exists(Path.Combine(plan.FolderPath, TranscriptionArtifactPublisher.TranscriptFileName)))
            throw new InvalidOperationException("Provider faults must be durable without publishing a transcript.");
    }

    private static RecordingSessionAsrJobCoordinator Coordinator(IRecordingSessionAsrTranscriber transcriber) =>
        new(_ => Task.FromResult(new OpenAICompatibleProviderSnapshot(
            OpenAICompatibleProviderProfile.Validated("https://api.openai.com/v1", "gpt-4o-transcribe", "gpt-4o-mini", "zh", ""), "not-persisted")), transcriber);

    private static RecordingSessionPlan CompletedPlan(string root, byte[] audio)
    {
        var plan = new SessionStorageService(root).CreateSessionPlan(RecordingSessionKind.Manual);
        File.WriteAllBytes(plan.FinalAudioPath, audio);
        return plan;
    }

    private static void Throws<T>(Action action, Func<T, bool>? acceptable = null) where T : Exception
    {
        try { action(); }
        catch (T error) when (acceptable is null || acceptable(error)) { return; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }

    private sealed class FakeTranscriber : IRecordingSessionAsrTranscriber
    {
        private readonly object result;
        public FakeTranscriber(object result) => this.result = result;
        public int Calls { get; private set; }
        public byte[] Audio { get; private set; } = [];
        public Task<OpenAICompatibleAsrResult> TranscribeAsync(OpenAICompatibleProviderSnapshot _, ReadOnlyMemory<byte> completedM4a, string __, CancellationToken ___)
        {
            Calls++; Audio = completedM4a.ToArray();
            return result is Exception error ? Task.FromException<OpenAICompatibleAsrResult>(error) : Task.FromResult((OpenAICompatibleAsrResult)result);
        }
    }

    private sealed class WaitingTranscriber : IRecordingSessionAsrTranscriber
    {
        public TaskCompletionSource<bool> Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public async Task<OpenAICompatibleAsrResult> TranscribeAsync(OpenAICompatibleProviderSnapshot _, ReadOnlyMemory<byte> __, string ___, CancellationToken cancellationToken)
        {
            Started.TrySetResult(true);
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken).ConfigureAwait(false);
            throw new InvalidOperationException("unreachable");
        }
    }

    private sealed class TestRoot : IDisposable
    {
        public TestRoot() { Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "teams-recorder-asr-job-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(Path); }
        public string Path { get; }
        public void Dispose() { try { Directory.Delete(Path, true); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
    }
}
