using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace TeamsRecorder.Windows.Application.Diagnostics;

/// <summary>
/// Privacy-bounded state captured when the UI process terminates unexpectedly.
/// It intentionally excludes paths, endpoint IDs, PIDs, HWNDs, window titles,
/// transcript/media contents, provider settings, and credentials.
/// </summary>
public sealed record RecorderCrashContext(
    string RecordingState,
    long? ElapsedSeconds,
    long? AvailableStorageBytes,
    bool HasRecoverableFault,
    string CaptureMode);

public sealed record RecorderCrashMarker(
    int SchemaVersion,
    DateTimeOffset RecordedAtUtc,
    string AppVersion,
    string OperatingSystem,
    string FailureSource,
    string? ExceptionCategory,
    RecorderCrashContext Context,
    long PrivateMemoryBytes,
    int HandleCount,
    long ManagedMemoryBytes);

public interface IRecorderCrashMarkerStore
{
    void WriteBestEffort(RecorderCrashContext context, string failureSource, Type? exceptionType = null);
}

public sealed class RecorderCrashMarkerStore : IRecorderCrashMarkerStore
{
    public const int CurrentSchemaVersion = 1;
    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    private readonly string path;
    private readonly Func<DateTimeOffset> clock;

    public RecorderCrashMarkerStore(string? path = null, Func<DateTimeOffset>? clock = null)
    {
        this.path = path ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Teams Recorder",
            "Diagnostics",
            "last-crash-marker.json");
        this.clock = clock ?? (() => DateTimeOffset.UtcNow);
    }

    public void WriteBestEffort(RecorderCrashContext context, string failureSource, Type? exceptionType = null)
    {
        try
        {
            ArgumentNullException.ThrowIfNull(context);
            using var process = Process.GetCurrentProcess();
            var marker = new RecorderCrashMarker(
                CurrentSchemaVersion,
                clock().ToUniversalTime(),
                Bounded(typeof(RecorderCrashMarkerStore).Assembly.GetName().Version?.ToString(), 64),
                Bounded(Environment.OSVersion.VersionString, 128),
                Bounded(failureSource, 64),
                exceptionType is null ? null : Bounded(exceptionType.FullName, 160),
                Sanitize(context),
                Math.Max(0, process.PrivateMemorySize64),
                Math.Max(0, process.HandleCount),
                Math.Max(0, GC.GetTotalMemory(forceFullCollection: false)));

            var folder = Path.GetDirectoryName(path)
                ?? throw new IOException("Crash marker path has no parent directory.");
            Directory.CreateDirectory(folder);
            var temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
            try
            {
                var payload = JsonSerializer.SerializeToUtf8Bytes(marker, Json);
                using (var output = new FileStream(
                    temporary,
                    FileMode.CreateNew,
                    FileAccess.Write,
                    FileShare.None,
                    4096,
                    FileOptions.WriteThrough))
                {
                    output.Write(payload);
                    output.Flush(flushToDisk: true);
                }
                File.Move(temporary, path, overwrite: true);
            }
            finally
            {
                try { if (File.Exists(temporary)) File.Delete(temporary); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        }
        catch
        {
            // A crash marker is diagnostic-only. It must never replace the OS
            // crash path, block termination, or attempt media finalization.
        }
    }

    private static RecorderCrashContext Sanitize(RecorderCrashContext context) => new(
        Bounded(context.RecordingState, 64),
        context.ElapsedSeconds is { } elapsed ? Math.Max(0, elapsed) : null,
        context.AvailableStorageBytes is { } available ? Math.Max(0, available) : null,
        context.HasRecoverableFault,
        Bounded(context.CaptureMode, 64));

    private static string Bounded(string? value, int maximumLength)
    {
        var safe = new string((value ?? string.Empty)
            .Where(character => !char.IsControl(character))
            .Take(maximumLength)
            .ToArray());
        return safe;
    }
}
