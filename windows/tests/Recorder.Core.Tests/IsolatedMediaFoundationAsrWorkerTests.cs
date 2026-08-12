using System.Diagnostics;
using Recorder.Core;
using TeamsRecorder.Windows.Application.Storage;
using TeamsRecorder.Windows.Application.Transcription;

internal static class IsolatedMediaFoundationAsrWorkerTests
{
    public static void BlockedWorkerOpenTimesOutStopsAndCleansStaging()
    {
        using var root = new TestRoot();
        var worker = new ControlledWorker();
        var factory = new ControlledWorkerFactory(worker);
        var source = Source(factory);
        var elapsed = Stopwatch.StartNew();
        Throws<IOException>(() => ReadAllAsync(source, Plan(root.Path)).GetAwaiter().GetResult());
        elapsed.Stop();
        AssertPrompt(elapsed, "blocked worker open");
        Equal(1, worker.StopCalls);
        AssertStagingDeleted(factory);
    }

    public static void BlockedWorkerReadTimesOutStopsAndCleansStaging()
    {
        using var root = new TestRoot();
        var worker = new ControlledWorker(new AsrWorkerMessage(AsrWorkerMessageKind.Ready));
        var factory = new ControlledWorkerFactory(worker);
        var source = Source(factory);
        var elapsed = Stopwatch.StartNew();
        Throws<IOException>(() => ReadAllAsync(source, Plan(root.Path)).GetAwaiter().GetResult());
        elapsed.Stop();
        AssertPrompt(elapsed, "blocked worker read");
        Equal(1, worker.StopCalls);
        AssertStagingDeleted(factory);
    }

    public static void CancellationDuringBlockedWorkerReadReturnsPromptlyAndCleansStaging()
    {
        using var root = new TestRoot();
        var worker = new ControlledWorker(new AsrWorkerMessage(AsrWorkerMessageKind.Ready));
        var factory = new ControlledWorkerFactory(worker);
        var source = Source(factory);
        using var cancellation = new CancellationTokenSource();
        cancellation.CancelAfter(TimeSpan.FromMilliseconds(20));
        var elapsed = Stopwatch.StartNew();
        Throws<OperationCanceledException>(() => ReadAllAsync(source, Plan(root.Path), cancellation.Token).GetAwaiter().GetResult());
        elapsed.Stop();
        AssertPrompt(elapsed, "blocked worker cancellation");
        Equal(1, worker.StopCalls);
        AssertStagingDeleted(factory);
    }

    public static void BlockedWorkerStopCannotHoldCleanupHostage()
    {
        using var root = new TestRoot();
        var worker = new ControlledWorker { BlockStop = true };
        var factory = new ControlledWorkerFactory(worker);
        var source = Source(factory);
        var elapsed = Stopwatch.StartNew();
        Throws<IOException>(() => ReadAllAsync(source, Plan(root.Path)).GetAwaiter().GetResult());
        elapsed.Stop();
        AssertPrompt(elapsed, "blocked worker stop");
        Equal(1, worker.StopCalls);
        AssertStagingDeleted(factory);
    }

    public static void WorkerChunkIsAcknowledgedOnlyAfterItsConsumerAdvances()
    {
        using var root = new TestRoot();
        var worker = new ControlledWorker(new AsrWorkerMessage(AsrWorkerMessageKind.Ready));
        var factory = new ControlledWorkerFactory(worker);
        var source = Source(factory);
        var plan = Plan(root.Path);
        var enumerator = source.ReadChunksAsync(plan, RecordingSessionAsrChunkConstraints.ProviderDefault).GetAsyncEnumerator();
        try
        {
            worker.BeforeNextRead = () =>
            {
                var request = factory.Request ?? throw new InvalidOperationException("Worker did not receive a start request.");
                var fileName = "transcription-0000.wav";
                File.WriteAllBytes(Path.Combine(request.StagingPath, fileName), PcmWav());
                worker.Enqueue(new(AsrWorkerMessageKind.Chunk, 0, TimeSpan.FromMilliseconds(10), fileName));
                worker.Enqueue(new(AsrWorkerMessageKind.Completed));
            };
            if (!enumerator.MoveNextAsync().AsTask().GetAwaiter().GetResult())
                throw new InvalidOperationException("The isolated worker produced no chunk.");
            Equal(0, worker.Acknowledgements);
            if (!MediaFoundationRecordingSessionAsrChunkSource.IsCompletePcmWav(enumerator.Current.Audio))
                throw new InvalidOperationException("The isolated worker produced a non-WAV chunk.");
            if (enumerator.MoveNextAsync().AsTask().GetAwaiter().GetResult())
                throw new InvalidOperationException("The isolated worker produced an unexpected extra chunk.");
            Equal(1, worker.Acknowledgements);
        }
        finally
        {
            enumerator.DisposeAsync().AsTask().GetAwaiter().GetResult();
        }
        Equal(1, worker.StopCalls);
        AssertStagingDeleted(factory);
    }

    private static IsolatedMediaFoundationAsrChunkSource Source(IAsrWorkerProcessFactory factory) =>
        new(factory, TimeSpan.FromMilliseconds(60), TimeSpan.FromMilliseconds(60));

    private static async Task<List<RecordingSessionAsrChunk>> ReadAllAsync(
        IRecordingSessionAsrChunkSource source,
        RecordingSessionPlan plan,
        CancellationToken cancellationToken = default)
    {
        var chunks = new List<RecordingSessionAsrChunk>();
        await foreach (var chunk in source.ReadChunksAsync(plan, RecordingSessionAsrChunkConstraints.ProviderDefault, cancellationToken)) chunks.Add(chunk);
        return chunks;
    }

    private static RecordingSessionPlan Plan(string root)
    {
        var plan = new SessionStorageService(root).CreateSessionPlan(RecordingSessionKind.Manual);
        File.WriteAllBytes(Path.Combine(plan.FolderPath, RecordingSessionLayout.FinalVideoFileName), [1]);
        return plan;
    }

    private static void AssertPrompt(Stopwatch elapsed, string operation)
    {
        if (elapsed.Elapsed > TimeSpan.FromSeconds(1))
            throw new InvalidOperationException($"{operation} ignored the bounded cancellation deadline: {elapsed.Elapsed}.");
    }

    private static void AssertStagingDeleted(ControlledWorkerFactory factory)
    {
        var request = factory.Request ?? throw new InvalidOperationException("Worker factory did not receive a request.");
        if (Directory.Exists(request.StagingPath))
            throw new InvalidOperationException("The blocked worker staging directory was retained after the parent returned.");
    }

    private static void Equal<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new InvalidOperationException($"Expected {expected}; got {actual}.");
    }

    private static void Throws<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }

    private static byte[] PcmWav()
    {
        var bytes = new byte[44 + 160];
        "RIFF"u8.CopyTo(bytes);
        BitConverter.TryWriteBytes(bytes.AsSpan(4, 4), 196u);
        "WAVEfmt "u8.CopyTo(bytes.AsSpan(8));
        BitConverter.TryWriteBytes(bytes.AsSpan(16, 4), 16u);
        BitConverter.TryWriteBytes(bytes.AsSpan(20, 2), (ushort)1);
        BitConverter.TryWriteBytes(bytes.AsSpan(22, 2), (ushort)1);
        BitConverter.TryWriteBytes(bytes.AsSpan(24, 4), 8_000u);
        BitConverter.TryWriteBytes(bytes.AsSpan(28, 4), 16_000u);
        BitConverter.TryWriteBytes(bytes.AsSpan(32, 2), (ushort)2);
        BitConverter.TryWriteBytes(bytes.AsSpan(34, 2), (ushort)16);
        "data"u8.CopyTo(bytes.AsSpan(36));
        BitConverter.TryWriteBytes(bytes.AsSpan(40, 4), 160u);
        return bytes;
    }

    private sealed class ControlledWorkerFactory(ControlledWorker worker) : IAsrWorkerProcessFactory
    {
        public AsrWorkerStartRequest? Request { get; private set; }
        public IAsrWorkerProcess Start(AsrWorkerStartRequest request)
        {
            Request = request;
            return worker;
        }
    }

    private sealed class ControlledWorker(params AsrWorkerMessage[] initial) : IAsrWorkerProcess
    {
        private readonly Queue<AsrWorkerMessage> messages = new(initial);
        private bool beforeNextReadInvoked;
        public int StopCalls { get; private set; }
        public int Acknowledgements { get; private set; }
        public bool BlockStop { get; init; }
        public Action? BeforeNextRead { get; set; }

        public Task<AsrWorkerMessage> ReadAsync(CancellationToken _)
        {
            if (!beforeNextReadInvoked && BeforeNextRead is not null)
            {
                beforeNextReadInvoked = true;
                BeforeNextRead();
            }
            if (messages.Count > 0) return Task.FromResult(messages.Dequeue());
            return new TaskCompletionSource<AsrWorkerMessage>(TaskCreationOptions.RunContinuationsAsynchronously).Task;
        }

        public Task AcknowledgeAsync(CancellationToken _)
        {
            Acknowledgements++;
            return Task.CompletedTask;
        }

        public Task StopAsync()
        {
            StopCalls++;
            if (BlockStop)
                return new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously).Task;
            return Task.CompletedTask;
        }

        public void Enqueue(AsrWorkerMessage message) => messages.Enqueue(message);
    }

    private sealed class TestRoot : IDisposable
    {
        public TestRoot()
        {
            Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "teams-recorder-isolated-asr-" + Guid.NewGuid().ToString("N"));
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
