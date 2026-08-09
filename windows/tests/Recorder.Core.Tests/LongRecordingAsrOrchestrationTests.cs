using System.Runtime.CompilerServices;
using System.Text.Json;
using Recorder.Core;
using TeamsRecorder.Windows.Application.AI;
using TeamsRecorder.Windows.Application.Storage;
using TeamsRecorder.Windows.Application.Transcription;

internal static class LongRecordingAsrOrchestrationTests
{
    public static void CompleteChunksUseRollingContextAndOneImmutableSnapshot()
    {
        using var root = new TestRoot();
        var plan = Plan(root.Path);
        var snapshots = 0;
        var transcriber = new ChunkTranscriber();
        using var coordinator = new RecordingSessionAsrJobCoordinator(
            _ =>
            {
                snapshots++;
                return Task.FromResult(Snapshot());
            },
            transcriber,
            chunkSource: new FixedChunkSource([
                new(0, TimeSpan.FromSeconds(120), [1], "chunk-000.m4a"),
                new(1, TimeSpan.FromSeconds(120), [2], "chunk-001.m4a"),
                new(2, TimeSpan.FromSeconds(60), [3], "chunk-002.m4a"),
            ]));

        var job = coordinator.StartAsync(plan, true).GetAwaiter().GetResult();
        job.Completion.GetAwaiter().GetResult();
        Equal(1, snapshots);
        Equal(3, transcriber.Prompts.Count);
        Equal("base prompt", transcriber.Prompts[0]);
        var secondContext = Context(transcriber.Prompts[1]);
        var thirdContext = Context(transcriber.Prompts[2]);
        Equal(RecordingSessionAsrRollingPrompt.MaximumContextCharacters, secondContext.Length);
        Equal(new string('A', 240), secondContext);
        Equal(new string('B', 240), thirdContext);
        using var manifest = JsonDocument.Parse(File.ReadAllText(Path.Combine(plan.FolderPath, TranscriptionArtifactPublisher.ManifestFileName)));
        Equal(3, manifest.RootElement.GetProperty("chunkCount").GetInt32());
        if (File.ReadAllText(Path.Combine(plan.FolderPath, TranscriptionArtifactPublisher.TranscriptFileName)) !=
            new string('A', 300) + Environment.NewLine + new string('B', 300) + Environment.NewLine + "final")
            throw new InvalidOperationException("Chunk transcripts were not joined in chronological order.");
    }

    public static void InvalidPlannedChunkFailsBeforeAnyUpload()
    {
        using var root = new TestRoot();
        var plan = Plan(root.Path);
        var transcriber = new ChunkTranscriber();
        using var coordinator = new RecordingSessionAsrJobCoordinator(
            _ => Task.FromResult(Snapshot()),
            transcriber,
            chunkSource: new FixedChunkSource([new(0, TimeSpan.FromSeconds(121), [1], "chunk.m4a")]));
        var job = coordinator.StartAsync(plan, true).GetAwaiter().GetResult();
        Throws<IOException>(() => job.Completion.GetAwaiter().GetResult());
        Equal(0, transcriber.Prompts.Count);
        if (File.Exists(Path.Combine(plan.FolderPath, TranscriptionArtifactPublisher.TranscriptFileName)))
            throw new InvalidOperationException("An invalid planned chunk produced a transcript artifact.");
    }

    private static string Context(string prompt)
    {
        const string marker = "Previous transcript context:\n";
        var index = prompt.IndexOf(marker, StringComparison.Ordinal);
        return index < 0 ? string.Empty : prompt[(index + marker.Length)..];
    }

    private static OpenAICompatibleProviderSnapshot Snapshot() => new(
        OpenAICompatibleProviderProfile.Validated("https://api.openai.com/v1", "asr", "llm", "en", "base prompt"),
        "immutable-key");

    private static RecordingSessionPlan Plan(string root)
    {
        var plan = new SessionStorageService(root).CreateSessionPlan(RecordingSessionKind.Manual);
        File.WriteAllBytes(plan.FinalAudioPath, [9]);
        return plan;
    }

    private static void Equal<T>(T expected, T actual) where T : notnull
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

    private sealed class FixedChunkSource(IReadOnlyList<RecordingSessionAsrChunk> chunks) : IRecordingSessionAsrChunkSource
    {
        public async IAsyncEnumerable<RecordingSessionAsrChunk> ReadChunksAsync(RecordingSessionPlan plan, RecordingSessionAsrChunkConstraints constraints, [EnumeratorCancellation] CancellationToken cancellationToken)
        {
            foreach (var chunk in chunks)
            {
                cancellationToken.ThrowIfCancellationRequested();
                await Task.Yield();
                yield return chunk;
            }
        }
    }

    private sealed class ChunkTranscriber : IRecordingSessionAsrChunkTranscriber
    {
        public List<string> Prompts { get; } = [];
        public Task<OpenAICompatibleAsrResult> TranscribeAsync(OpenAICompatibleProviderSnapshot snapshot, ReadOnlyMemory<byte> completedM4a, string fileName, CancellationToken cancellationToken) =>
            TranscribeChunkAsync(snapshot, completedM4a, fileName, snapshot.Profile.Prompt, cancellationToken);
        public Task<OpenAICompatibleAsrResult> TranscribeChunkAsync(OpenAICompatibleProviderSnapshot snapshot, ReadOnlyMemory<byte> completeChunk, string fileName, string rollingPrompt, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Prompts.Add(rollingPrompt);
            var text = Prompts.Count switch { 1 => new string('A', 300), 2 => new string('B', 300), _ => "final" };
            return Task.FromResult(new OpenAICompatibleAsrResult(text, OpenAICompatibleAsrResponseFormat.VerboseJson));
        }
    }

    private sealed class TestRoot : IDisposable
    {
        public TestRoot() { Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "teams-recorder-long-asr-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(Path); }
        public string Path { get; }
        public void Dispose() { try { Directory.Delete(Path, true); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
    }
}
