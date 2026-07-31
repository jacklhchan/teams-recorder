using Recorder.Core;
using TeamsRecorder.Windows.Application;
using TeamsRecorder.Windows.Application.Diagnostics;

internal static class LocalDiagnosticLogTests
{
    public static void ExportsBoundedSanitizedCaptureDiagnostics()
    {
        using var root = new TestRoot();
        var log = new LocalDiagnosticLog(Path.Combine(root.Path, "diagnostics"));
        var request = new RecordingStartRequest(
            RecordingSessionKind.Manual,
            RecordingAudioSource.SystemLoopback,
            RenderEndpointId: "opaque-render-endpoint",
            MicrophoneEndpointId: "opaque-microphone-endpoint");

        log.RecordStart(request);
        log.RecordFailure("native-start", message: "token=very-secret C:\\Users\\Jane\\recording.m4a Authorization: Bearer hidden-value");
        var result = log.ExportAsync(Path.Combine(root.Path, "export")).GetAwaiter().GetResult();
        var exported = File.ReadAllText(Path.Combine(root.Path, "export", result.FileName));

        if (result.EntryCount != 2 || !exported.Contains("SystemLoopback") || !exported.Contains("explicit") ||
            exported.Contains("opaque-render-endpoint") || exported.Contains("very-secret") ||
            exported.Contains("hidden-value") || exported.Contains("C:\\Users\\Jane"))
        {
            throw new InvalidOperationException("Diagnostic export either missed capture context or retained sensitive data.");
        }
    }

    public static void BoundsItsInMemoryExport()
    {
        using var root = new TestRoot();
        var log = new LocalDiagnosticLog(Path.Combine(root.Path, "diagnostics"));
        for (var index = 0; index < 205; index++) log.RecordFailure("capture", message: $"failure-{index}");
        var result = log.ExportAsync(Path.Combine(root.Path, "export")).GetAwaiter().GetResult();
        if (result.EntryCount != 200) throw new InvalidOperationException("Diagnostic export was not bounded.");
    }

    private sealed class TestRoot : IDisposable
    {
        public TestRoot()
        {
            Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "teams-recorder-diagnostics-" + Guid.NewGuid().ToString("N"));
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
