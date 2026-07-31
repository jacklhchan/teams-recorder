using System.Text.Json;
using TeamsRecorder.Windows.Application.Storage;
using TeamsRecorder.Windows.Application.Transcription;
using Recorder.Core;

internal static class TranscriptionArtifactTests
{
    public static void PublishesAtomicallyWithBoundedPreviousArtifacts()
    {
        using var root = new TestRoot();
        var storage = new SessionStorageService(root.Path);
        var plan = storage.CreateSessionPlan(RecordingSessionKind.Manual);
        var publisher = new TranscriptionArtifactPublisher(maximumBackupsPerArtifact: 2);
        for (var i = 0; i < 4; i++)
        {
            publisher.PublishAsync(plan, "raw-" + i, "final-" + i,
                new TranscriptionPublicationManifest("gpt-4o-transcribe", "zh", 1, ["verbose_json"]),
                ["completed", "Authorization: Bearer private-token C:\\Users\\Jane\\recording.m4a"],
                new DateTimeOffset(2026, 7, 31, 0, 0, i, TimeSpan.Zero)).GetAwaiter().GetResult();
        }
        if (File.ReadAllText(Path.Combine(plan.FolderPath, TranscriptionArtifactPublisher.TranscriptFileName)) != "final-3")
            throw new InvalidOperationException("Final transcript was not atomically published.");
        foreach (var name in new[] { TranscriptionArtifactPublisher.TranscriptFileName, TranscriptionArtifactPublisher.RawTranscriptFileName, TranscriptionArtifactPublisher.ManifestFileName, TranscriptionArtifactPublisher.LogFileName })
        {
            if (Directory.EnumerateFiles(plan.FolderPath, name + ".previous-*").Count() > 2)
                throw new InvalidOperationException("Previous transcription artifacts were not bounded.");
        }
        var manifest = File.ReadAllText(Path.Combine(plan.FolderPath, TranscriptionArtifactPublisher.ManifestFileName));
        var log = File.ReadAllText(Path.Combine(plan.FolderPath, TranscriptionArtifactPublisher.LogFileName));
        if (manifest.Contains("apiKey", StringComparison.OrdinalIgnoreCase) || log.Contains("private-token") || log.Contains("C:\\Users\\Jane"))
            throw new InvalidOperationException("Transcription diagnostics exposed secret or audio path data.");
        using var document = JsonDocument.Parse(manifest);
        if (document.RootElement.GetProperty("model").GetString() != "gpt-4o-transcribe")
            throw new InvalidOperationException("Transcription manifest did not round trip.");
    }

    public static void StartupRecoveryMarksOnlyInProgressStateInterrupted()
    {
        using var root = new TestRoot();
        var storage = new SessionStorageService(root.Path);
        var active = storage.CreateSessionPlan(RecordingSessionKind.Meeting);
        var complete = storage.CreateSessionPlan(RecordingSessionKind.Manual);
        var publisher = new TranscriptionArtifactPublisher();
        publisher.SaveStateAsync(active, new TranscriptionState(TranscriptionPhase.Transcribing, "Working token=private-value C:\\Users\\Jane\\recording.m4a", DateTimeOffset.UtcNow)).GetAwaiter().GetResult();
        publisher.SaveStateAsync(complete, new TranscriptionState(TranscriptionPhase.Completed, "Done", DateTimeOffset.UtcNow, DateTimeOffset.UtcNow)).GetAwaiter().GetResult();
        var recovered = new TranscriptionRecoveryService(publisher).MarkInterruptedAsync([active, complete]).GetAwaiter().GetResult();
        var activeState = publisher.LoadState(active);
        if (recovered.Count != 1 || activeState?.Phase != TranscriptionPhase.Interrupted || activeState.Message.Contains("private-value") || activeState.Message.Contains("C:\\Users\\Jane") || publisher.LoadState(complete)?.Phase != TranscriptionPhase.Completed)
            throw new InvalidOperationException("Startup recovery did not preserve terminal transcription state.");
    }

    public static void RefusesForeignOrReparseArtifactLocation()
    {
        using var root = new TestRoot();
        var storage = new SessionStorageService(root.Path);
        var plan = storage.CreateSessionPlan(RecordingSessionKind.Manual);
        var foreign = plan with { FolderPath = root.Path };
        try
        {
            new TranscriptionArtifactPublisher().SaveStateAsync(foreign, new TranscriptionState(TranscriptionPhase.Queued, "Queued", DateTimeOffset.UtcNow)).GetAwaiter().GetResult();
            throw new InvalidOperationException("Foreign folder was accepted.");
        }
        catch (IOException) { }
    }

    private sealed class TestRoot : IDisposable
    {
        public TestRoot()
        {
            Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "teams-recorder-transcription-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Path);
        }
        public string Path { get; }
        public void Dispose() { try { Directory.Delete(Path, true); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
    }
}
