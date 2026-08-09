using System.Text.Json;
using TeamsRecorder.Windows.Application.Diagnostics;

internal static class RecorderCrashMarkerTests
{
    public static void MarkerIsAtomicBoundedAndPrivacySafe()
    {
        using var root = new TemporaryRoot();
        var path = Path.Combine(root.Path, "last-crash-marker.json");
        var recordedAt = new DateTimeOffset(2026, 8, 9, 12, 0, 0, TimeSpan.Zero);
        var store = new RecorderCrashMarkerStore(path, () => recordedAt);

        store.WriteBestEffort(
            new RecorderCrashContext(
                new string('r', 100),
                ElapsedSeconds: -5,
                AvailableStorageBytes: -10,
                HasRecoverableFault: true,
                CaptureMode: new string('m', 100)),
            new string('s', 80) + "\r\n",
            typeof(SecretBearingException));

        if (!File.Exists(path) || Directory.EnumerateFiles(root.Path).Count() != 1)
            throw new InvalidOperationException("Crash marker publication left a missing or temporary artifact.");
        var bytes = File.ReadAllBytes(path);
        if (bytes.Length == 0 || bytes.Length > 4 * 1024)
            throw new InvalidOperationException("Crash marker escaped its small diagnostic envelope.");

        using var document = JsonDocument.Parse(bytes);
        var json = document.RootElement;
        Equal(RecorderCrashMarkerStore.CurrentSchemaVersion, json.GetProperty("schemaVersion").GetInt32());
        Equal(recordedAt, json.GetProperty("recordedAtUtc").GetDateTimeOffset());
        Equal(64, json.GetProperty("failureSource").GetString()!.Length);
        Equal(typeof(SecretBearingException).FullName, json.GetProperty("exceptionCategory").GetString());
        var context = json.GetProperty("context");
        Equal(64, context.GetProperty("recordingState").GetString()!.Length);
        Equal(0L, context.GetProperty("elapsedSeconds").GetInt64());
        Equal(0L, context.GetProperty("availableStorageBytes").GetInt64());
        Equal(64, context.GetProperty("captureMode").GetString()!.Length);

        var payload = System.Text.Encoding.UTF8.GetString(bytes);
        foreach (var forbidden in new[] { "super-secret-message", root.Path, "processId", "windowHandle", "credential" })
        {
            if (payload.Contains(forbidden, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException($"Crash marker exposed forbidden runtime data: {forbidden}");
        }
    }

    private static void Equal<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new InvalidOperationException($"Expected {expected}; got {actual}.");
    }

    private sealed class SecretBearingException : Exception
    {
        public SecretBearingException() : base("super-secret-message") { }
    }

    private sealed class TemporaryRoot : IDisposable
    {
        public TemporaryRoot()
        {
            Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "recorder-crash-marker-tests-" + Guid.NewGuid().ToString("N"));
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
