using System.Runtime.CompilerServices;
using Recorder.Core;
using TeamsRecorder.Windows.Application.Storage;
using TeamsRecorder.Windows.Application.Transcription;

internal static class MediaFoundationRecordingSessionAsrChunkSourceTests
{
    public static void ManagedMp4ProducesChronologicalCompleteBoundedChunks()
    {
        using var root = new TestRoot();
        var plan = ManagedMp4Plan(root.Path);
        var factory = new FixedReaderFactory(new PcmAudioFormat(8_000, 1, 16), [
            Bytes(20_000, 1), Bytes(20_000, 2), Bytes(20_000, 3), Bytes(20_000, 4),
        ]);
        var source = new MediaFoundationRecordingSessionAsrChunkSource(factory);
        var constraints = new RecordingSessionAsrChunkConstraints(TimeSpan.FromSeconds(2), MediaFoundationRecordingSessionAsrChunkSource.WavHeaderBytes + 32_000);
        var chunks = ReadAllAsync(source, plan, constraints).GetAwaiter().GetResult();

        Equal(Path.Combine(plan.FolderPath, RecordingSessionLayout.FinalVideoFileName), factory.OpenedPath);
        Equal(3, chunks.Count);
        Equal(TimeSpan.FromSeconds(2), chunks[0].Duration);
        Equal(TimeSpan.FromSeconds(2), chunks[1].Duration);
        Equal(TimeSpan.FromSeconds(1), chunks[2].Duration);
        for (var index = 0; index < chunks.Count; index++)
        {
            Equal(index, chunks[index].Sequence);
            if (chunks[index].Audio.Length > constraints.MaximumBytes || chunks[index].Duration > constraints.MaximumDuration ||
                !MediaFoundationRecordingSessionAsrChunkSource.IsCompletePcmWav(chunks[index].Audio) ||
                !chunks[index].FileName.EndsWith(".wav", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("The managed MP4 exporter yielded an invalid bounded complete WAV chunk.");
        }
        AssertNoStagingDirectories(plan.FolderPath);
    }

    public static void EnforcesPerChunkDurationAndByteCapsBeforeYielding()
    {
        using var root = new TestRoot();
        var plan = ManagedMp4Plan(root.Path);
        var factory = new FixedReaderFactory(new PcmAudioFormat(8_000, 1, 16), [Bytes(500, 9)]);
        var source = new MediaFoundationRecordingSessionAsrChunkSource(factory);
        var constraints = new RecordingSessionAsrChunkConstraints(TimeSpan.FromMilliseconds(50), 96);
        var chunks = ReadAllAsync(source, plan, constraints).GetAwaiter().GetResult();

        if (chunks.Count < 2 || chunks.Any(chunk => chunk.Audio.Length > 96 || chunk.Duration > TimeSpan.FromMilliseconds(50)))
            throw new InvalidOperationException("An ASR chunk exceeded the requested duration or byte cap.");
        AssertNoStagingDirectories(plan.FolderPath);
    }

    public static void CancellationDeletesBoundedStagingFiles()
    {
        using var root = new TestRoot();
        var plan = ManagedMp4Plan(root.Path);
        var factory = new FixedReaderFactory(new PcmAudioFormat(8_000, 1, 16), [Bytes(400, 1), Bytes(400, 2)]);
        var source = new MediaFoundationRecordingSessionAsrChunkSource(factory);
        var constraints = new RecordingSessionAsrChunkConstraints(TimeSpan.FromSeconds(2), MediaFoundationRecordingSessionAsrChunkSource.WavHeaderBytes + 400);
        using var cancellation = new CancellationTokenSource();
        var enumerator = source.ReadChunksAsync(plan, constraints, cancellation.Token).GetAsyncEnumerator();
        try
        {
            if (!enumerator.MoveNextAsync().AsTask().GetAwaiter().GetResult())
                throw new InvalidOperationException("The fake source did not provide its first bounded chunk.");
            cancellation.Cancel();
            Throws<OperationCanceledException>(() => enumerator.MoveNextAsync().AsTask().GetAwaiter().GetResult());
        }
        finally
        {
            enumerator.DisposeAsync().AsTask().GetAwaiter().GetResult();
        }
        AssertNoStagingDirectories(plan.FolderPath);
    }

    public static void CorruptManagedMp4FailsClosedAndCleansStaging()
    {
        using var root = new TestRoot();
        var plan = ManagedMp4Plan(root.Path);
        File.WriteAllBytes(Path.Combine(plan.FolderPath, RecordingSessionLayout.FinalVideoFileName), Bytes(256, 7));
        var source = new MediaFoundationRecordingSessionAsrChunkSource();
        var failure = ThrowsAndReturn<IOException>(() => ReadAllAsync(source, plan, RecordingSessionAsrChunkConstraints.ProviderDefault).GetAwaiter().GetResult());
        AssertNoStagingDirectories(plan.FolderPath, failure.Message);
    }

    private static async Task<List<RecordingSessionAsrChunk>> ReadAllAsync(
        MediaFoundationRecordingSessionAsrChunkSource source,
        RecordingSessionPlan plan,
        RecordingSessionAsrChunkConstraints constraints)
    {
        var chunks = new List<RecordingSessionAsrChunk>();
        await foreach (var chunk in source.ReadChunksAsync(plan, constraints)) chunks.Add(chunk);
        return chunks;
    }

    private static RecordingSessionPlan ManagedMp4Plan(string root)
    {
        var plan = new SessionStorageService(root).CreateSessionPlan(RecordingSessionKind.Manual);
        File.WriteAllBytes(Path.Combine(plan.FolderPath, RecordingSessionLayout.FinalVideoFileName), [1]);
        return plan;
    }

    private static byte[] Bytes(int count, byte value)
    {
        var result = new byte[count];
        Array.Fill(result, value);
        return result;
    }

    private static void AssertNoStagingDirectories(string folder, string? context = null)
    {
        var remaining = Directory.EnumerateDirectories(folder, MediaFoundationRecordingSessionAsrChunkSource.StagingDirectoryPrefix + "*", SearchOption.TopDirectoryOnly).ToArray();
        if (remaining.Length > 0)
            throw new InvalidOperationException("ASR chunk staging was not cleaned up: " + string.Join(", ", remaining.Select(path => Path.GetFileName(path) + "[" + File.GetAttributes(path) + "]")) + (context is null ? string.Empty : "; source failure: " + context));
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

    private static T ThrowsAndReturn<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T error) { return error; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }

    private sealed class FixedReaderFactory(PcmAudioFormat format, IReadOnlyList<byte[]> samples) : IRecordingSessionPcmReaderFactory
    {
        public string? OpenedPath { get; private set; }
        public IRecordingSessionPcmReader Open(string mediaPath)
        {
            OpenedPath = mediaPath;
            return new FixedReader(format, samples);
        }
    }

    private sealed class FixedReader(PcmAudioFormat format, IReadOnlyList<byte[]> samples) : IRecordingSessionPcmReader
    {
        private int index;
        public PcmAudioFormat Format { get; } = format;
        public ReadOnlyMemory<byte>? Read(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (index >= samples.Count) return null;
            return new ReadOnlyMemory<byte>(samples[index++]);
        }
        public void Dispose() { }
    }

    private sealed class TestRoot : IDisposable
    {
        public TestRoot()
        {
            Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "teams-recorder-mf-asr-" + Guid.NewGuid().ToString("N"));
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
