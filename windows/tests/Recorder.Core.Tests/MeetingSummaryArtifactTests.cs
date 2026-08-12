using TeamsRecorder.Windows.Application.AI;
using TeamsRecorder.Windows.Application.Storage;
using TeamsRecorder.Windows.Application.Transcription;
using Recorder.Core;

internal static class MeetingSummaryArtifactTests
{
    public static void CoordinatorReadsOnlyOwnedTranscriptAndPublishesBoundedArtifacts()
    {
        using var root = new TestRoot();
        var storage = new SessionStorageService(root.Path);
        var plan = storage.CreateSessionPlan(RecordingSessionKind.Manual);
        new TranscriptionArtifactPublisher().PublishAsync(plan, "raw", "owned transcript", new TranscriptionPublicationManifest("asr", "en", 1, [])).GetAwaiter().GetResult();
        var calls = 0;
        var publisher = new MeetingSummaryArtifactPublisher(maximumBackupsPerArtifact: 1);
        var coordinator = new MeetingSummaryCoordinator((snapshot, request, _) =>
        {
            calls++;
            if (!request.UserConsentGranted || request.Transcript != "owned transcript") throw new InvalidOperationException("Coordinator sent an unexpected transcript.");
            return Task.FromResult(new MeetingSummary("Summary " + calls, ["Follow up"], ["Approved"]));
        }, publisher);
        var snapshot = new OpenAICompatibleProviderSnapshot(OpenAICompatibleProviderProfile.Default, "private-key");
        coordinator.SummarizeAndPublishAsync(plan, snapshot, true).GetAwaiter().GetResult();
        coordinator.SummarizeAndPublishAsync(plan, snapshot, true).GetAwaiter().GetResult();
        if (calls != 2 || !File.ReadAllText(Path.Combine(plan.FolderPath, MeetingSummaryArtifactPublisher.SummaryMarkdownFileName)).Contains("Summary 2") ||
            Directory.EnumerateFiles(plan.FolderPath, MeetingSummaryArtifactPublisher.SummaryJsonFileName + ".previous-*").Count() > 1 ||
            publisher.LoadState(plan)?.Phase != MeetingSummaryPhase.Completed)
            throw new InvalidOperationException("Summary artifacts were not safely published with bounded backups.");
        var json = File.ReadAllText(Path.Combine(plan.FolderPath, MeetingSummaryArtifactPublisher.SummaryJsonFileName));
        var state = File.ReadAllText(Path.Combine(plan.FolderPath, MeetingSummaryArtifactPublisher.StateFileName));
        if (json.Contains("private-key") || state.Contains("private-key") || state.Contains("BaseUrl"))
            throw new InvalidOperationException("Summary artifacts exposed provider credentials or URL details.");
    }

    public static void CoordinatorRequiresConsentAndRefusesForeignSessions()
    {
        using var root = new TestRoot();
        var storage = new SessionStorageService(root.Path);
        var plan = storage.CreateSessionPlan(RecordingSessionKind.Manual);
        var called = false;
        var coordinator = new MeetingSummaryCoordinator((_, _, _) => { called = true; return Task.FromResult(new MeetingSummary("x", [], [])); });
        var snapshot = new OpenAICompatibleProviderSnapshot(OpenAICompatibleProviderProfile.Default, null);
        try
        {
            coordinator.SummarizeAndPublishAsync(plan, snapshot, false).GetAwaiter().GetResult();
            throw new InvalidOperationException("Missing consent was accepted.");
        }
        catch (MeetingSummaryException error) when (error.Kind == MeetingSummaryErrorKind.ConsentRequired) { }
        if (called) throw new InvalidOperationException("Summary provider was called without consent.");
        try
        {
            new MeetingSummaryArtifactPublisher().SaveStateAsync(plan with { FolderPath = root.Path }, new(MeetingSummaryPhase.Queued, "token=private C:\\Users\\Jane", DateTimeOffset.UtcNow)).GetAwaiter().GetResult();
            throw new InvalidOperationException("Foreign folder was accepted for summary artifacts.");
        }
        catch (IOException) { }
    }

    public static void CoordinatorKeepsSafeFailureState()
    {
        using var root = new TestRoot();
        var plan = new SessionStorageService(root.Path).CreateSessionPlan(RecordingSessionKind.Manual);
        new TranscriptionArtifactPublisher().PublishAsync(plan, "raw", "text", new TranscriptionPublicationManifest("asr", "en", 1, [])).GetAwaiter().GetResult();
        var publisher = new MeetingSummaryArtifactPublisher();
        var coordinator = new MeetingSummaryCoordinator((_, _, _) => throw new MeetingSummaryException(MeetingSummaryErrorKind.ProviderUnavailable, "Authorization: Bearer private C:\\Users\\Jane"), publisher);
        try { coordinator.SummarizeAndPublishAsync(plan, new(OpenAICompatibleProviderProfile.Default, "secret"), true).GetAwaiter().GetResult(); }
        catch (MeetingSummaryException) { }
        var state = publisher.LoadState(plan);
        if (state?.Phase != MeetingSummaryPhase.Failed || state.Message.Contains("private", StringComparison.OrdinalIgnoreCase) || state.Message.Contains("Users", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Summary failure state was not safely retained.");
    }

    private sealed class TestRoot : IDisposable
    {
        public TestRoot()
        {
            Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "teams-recorder-summary-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Path);
        }
        public string Path { get; }
        public void Dispose() { try { Directory.Delete(Path, true); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
    }
}
