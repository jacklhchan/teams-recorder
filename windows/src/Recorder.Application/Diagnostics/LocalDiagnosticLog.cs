using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Recorder.Core;

namespace TeamsRecorder.Windows.Application.Diagnostics;

/// <summary>
/// A deliberately small, local-only diagnostic trail.  It records enough
/// context to diagnose capture failures without recording audio, endpoint IDs,
/// file-system locations, pairing credentials, or process command lines.
/// </summary>
public interface IRecordingDiagnostics
{
    void RecordStart(RecordingStartRequest request);
    void RecordFailure(string stage, Exception? error = null, string? message = null);
    void RecordSnapshot(RecordingCoordinatorSnapshot snapshot);
    Task<DiagnosticExportResult> ExportAsync(string destinationDirectory, CancellationToken cancellationToken = default);
}

public sealed record DiagnosticExportResult(string FileName, int EntryCount);

public sealed record CaptureDiagnosticContext(
    string SessionKind,
    string AudioSource,
    string RenderEndpointChoice,
    string MicrophoneEndpointChoice,
    bool IncludesSelectedProcessTree)
{
    public static CaptureDiagnosticContext From(RecordingStartRequest request) => new(
        request.Kind.ToString(),
        request.AudioSource.ToString(),
        request.RenderEndpointId is null ? "windowsDefault" : "explicit",
        request.MicrophoneEndpointId is null ? "none" : "explicit",
        request.IncludeProcessTree);
}

public sealed record LocalDiagnosticEntry(
    DateTimeOffset TimestampUtc,
    string EventName,
    string Severity,
    CaptureDiagnosticContext? Capture,
    string? Stage,
    string? Error);

public sealed class LocalDiagnosticLog : IRecordingDiagnostics
{
    private const int MaximumEntries = 200;
    private const int MaximumMessageLength = 768;
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = false };
    private readonly object gate = new();
    private readonly List<LocalDiagnosticEntry> entries = [];
    private readonly string logPath;

    public LocalDiagnosticLog(string directory)
    {
        if (string.IsNullOrWhiteSpace(directory)) throw new ArgumentException("A diagnostic directory is required.", nameof(directory));
        logPath = Path.Combine(directory, "capture-diagnostics.jsonl");
    }

    public static LocalDiagnosticLog CreateDefault() => new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Teams Recorder",
        "Diagnostics"));

    public void RecordStart(RecordingStartRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        Record(new(DateTimeOffset.UtcNow, "captureStart", "information", CaptureDiagnosticContext.From(request), null, null));
    }

    public void RecordFailure(string stage, Exception? error = null, string? message = null)
    {
        Record(new(DateTimeOffset.UtcNow, "captureFailure", "error", null,
            DiagnosticSanitizer.Stage(stage),
            DiagnosticSanitizer.Message(message ?? error?.Message)));
    }

    public void RecordSnapshot(RecordingCoordinatorSnapshot snapshot)
    {
        if (string.IsNullOrWhiteSpace(snapshot.Error)) return;
        Record(new(DateTimeOffset.UtcNow, "captureState", "error", null,
            snapshot.State.ToString(), DiagnosticSanitizer.Message(snapshot.Error)));
    }

    public async Task<DiagnosticExportResult> ExportAsync(string destinationDirectory, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(destinationDirectory)) throw new ArgumentException("A destination directory is required.", nameof(destinationDirectory));
        var snapshot = Snapshot();
        Directory.CreateDirectory(destinationDirectory);
        var fileName = $"teams-recorder-diagnostics-{DateTimeOffset.UtcNow:yyyyMMdd-HHmmss}.json";
        var destination = Path.Combine(destinationDirectory, fileName);
        var json = JsonSerializer.Serialize(snapshot, JsonOptions);
        await File.WriteAllTextAsync(destination, json, Encoding.UTF8, cancellationToken).ConfigureAwait(false);
        return new(fileName, snapshot.Count);
    }

    private void Record(LocalDiagnosticEntry entry)
    {
        try
        {
            lock (gate)
            {
                entries.Add(entry);
                if (entries.Count > MaximumEntries) entries.RemoveRange(0, entries.Count - MaximumEntries);
                var directory = Path.GetDirectoryName(logPath)!;
                Directory.CreateDirectory(directory);
                File.AppendAllText(logPath, JsonSerializer.Serialize(entry, JsonOptions) + Environment.NewLine, Encoding.UTF8);
            }
        }
        catch (IOException) { /* diagnostics must never break recording */ }
        catch (UnauthorizedAccessException) { /* diagnostics must never break recording */ }
    }

    private IReadOnlyList<LocalDiagnosticEntry> Snapshot()
    {
        lock (gate) return entries.ToArray();
    }

    internal static class DiagnosticSanitizer
    {
        private static readonly Regex Secret = new("(?ix)\\b(?:access[_-]?token|refresh[_-]?token|token|authorization)\\b\\s*[:=]\\s*(?:bearer\\s+)?[^\\s,;\\\"']+|\\bbearer\\s+[a-z0-9._~+\\-/=]+", RegexOptions.Compiled);
        private static readonly Regex QuerySecret = new(@"(?i)([?&](?:access[_-]?token|refresh[_-]?token|token)=[^&\s]+)", RegexOptions.Compiled);
        private static readonly Regex WindowsPath = new(@"(?i)(?:[a-z]:\\|\\\\)[^\r\n\t ]+", RegexOptions.Compiled);

        public static string Stage(string? value) => string.IsNullOrWhiteSpace(value) ? "unknown" : value.Trim()[..Math.Min(64, value.Trim().Length)];
        public static string? Message(string? value)
        {
            if (string.IsNullOrWhiteSpace(value)) return null;
            var sanitized = Secret.Replace(value, "[redacted-secret]");
            sanitized = QuerySecret.Replace(sanitized, "[redacted-secret]");
            sanitized = WindowsPath.Replace(sanitized, "[redacted-path]");
            sanitized = sanitized.Replace('\0', ' ').Replace('\r', ' ').Replace('\n', ' ').Trim();
            return sanitized[..Math.Min(MaximumMessageLength, sanitized.Length)];
        }
    }
}
