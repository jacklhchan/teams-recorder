using System.Text.Json.Nodes;
using Recorder.Core;
using TeamsRecorder.Windows.Application.Storage;

namespace TeamsRecorder.Windows.Application.Transcription;

public sealed record ManualTranscriptionImportResult(
    RecordingSessionPlan Session,
    string MediaPath,
    string DisplayName);

/// <summary>
/// Copies an explicitly selected local audio file into a newly allocated,
/// app-owned manual session. The original is never moved or modified.
/// </summary>
public sealed class ManualTranscriptionImporter
{
    public async Task<ManualTranscriptionImportResult> ImportAsync(
        SessionStorageService storage,
        string sourcePath,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(storage);
        if (string.IsNullOrWhiteSpace(sourcePath))
            throw new ArgumentException("An audio file is required.", nameof(sourcePath));

        var source = Path.GetFullPath(sourcePath);
        var extension = Path.GetExtension(source).TrimStart('.').ToLowerInvariant();
        if (!RecordingSessionLayout.IsSupportedImportedAudioExtension(extension))
            throw new IOException("Select an M4A, MP3, WAV, FLAC, AAC, AIFF, AIF, or CAF audio file.");
        if (!File.Exists(source) || !IsSafeRegularFile(source))
            throw new FileNotFoundException("The selected audio file was not found or is not a safe regular file.", source);
        if (new FileInfo(source).Length <= 0)
            throw new IOException("The selected audio file is empty.");

        var displayName = NormalizeDisplayName(Path.GetFileNameWithoutExtension(source));
        var plan = storage.CreateSessionPlan(RecordingSessionKind.Manual);
        var destination = Path.Combine(plan.FolderPath, $"recording.{extension}");
        var copied = false;
        try
        {
            await using (var input = new FileStream(
                source,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                128 * 1024,
                FileOptions.Asynchronous | FileOptions.SequentialScan))
            await using (var output = new FileStream(
                destination,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                128 * 1024,
                FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await input.CopyToAsync(output, 128 * 1024, cancellationToken).ConfigureAwait(false);
                await output.FlushAsync(cancellationToken).ConfigureAwait(false);
                output.Flush(flushToDisk: true);
            }
            copied = true;

            var document = new JsonObject
            {
                ["source"] = "imported",
                ["titleOrigin"] = "unset",
            };
            var metadata = RecordingInfoJson.CreateAudioOnly(
                document,
                displayName,
                RecordingRecoveryState.None,
                RecordingSessionKind.Manual);
            await storage.WriteMetadataAsync(plan.MetadataPath, metadata, cancellationToken).ConfigureAwait(false);
            return new(plan with { FinalAudioPath = destination }, destination, displayName);
        }
        catch
        {
            // This exact folder was allocated above. Remove only files created
            // by this operation, then remove the folder only if it is empty;
            // unknown evidence introduced concurrently is never recursively deleted.
            DeleteBestEffort(plan.MetadataPath);
            if (copied || File.Exists(destination)) DeleteBestEffort(destination);
            try { Directory.Delete(plan.FolderPath, recursive: false); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            throw;
        }
    }

    private static string NormalizeDisplayName(string value)
    {
        var normalized = value.Trim();
        if (normalized.Length == 0) return "Imported recording";
        return normalized.Length <= 200 ? normalized : normalized[..200];
    }

    private static bool IsSafeRegularFile(string path)
    {
        var attributes = File.GetAttributes(path);
        return (attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) == 0;
    }

    private static void DeleteBestEffort(string path)
    {
        try
        {
            if (File.Exists(path) && IsSafeRegularFile(path)) File.Delete(path);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
