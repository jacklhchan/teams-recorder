using Recorder.Core;
using TeamsRecorder.Windows.Application.Storage;

namespace TeamsRecorder.Windows.Application.Recovery;

public interface IAudioBackupValidator { bool IsValidNonEmptyAudio(string path); }

/// <summary>
/// A conservative, dependency-free preflight for an M4A/ISO-BMFF backup. The
/// native writer remains the authoritative producer; this guard only avoids
/// promoting an empty or obviously unrelated file after interruption.
/// </summary>
public sealed class M4aAudioBackupValidator : IAudioBackupValidator
{
    public bool IsValidNonEmptyAudio(string path)
    {
        try
        {
            if (!File.Exists(path) || new FileInfo(path).Length < 16)
            {
                return false;
            }
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            var hasFtyp = false;
            var hasMoov = false;
            Span<byte> header = stackalloc byte[8];
            while (stream.Position + 8 <= stream.Length)
            {
                if (stream.Read(header) != header.Length) return false;
                var size = ((long)header[0] << 24) | ((long)header[1] << 16) | ((long)header[2] << 8) | header[3];
                if (size == 1 || size < 8 || size > stream.Length - stream.Position + 8) return false;
                var type = System.Text.Encoding.ASCII.GetString(header[4..]);
                hasFtyp |= type == "ftyp";
                hasMoov |= type == "moov";
                stream.Seek(size - 8, SeekOrigin.Current);
            }
            return hasFtyp && hasMoov;
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }
}
public sealed record SessionRecoveryResult(string FolderPath, bool Recovered, string? Reason);

public sealed class SessionRecoveryService
{
    private readonly SessionStorageService storage;
    private readonly IAudioBackupValidator validator;
    public SessionRecoveryService(SessionStorageService storage, IAudioBackupValidator? validator = null) { this.storage = storage; this.validator = validator ?? new M4aAudioBackupValidator(); }

    public async Task<IReadOnlyList<SessionRecoveryResult>> RecoverAsync(CancellationToken cancellationToken = default)
    {
        var results = new List<SessionRecoveryResult>();
        foreach (var (folder, kind) in storage.EnumerateOwnedFolders())
        {
            cancellationToken.ThrowIfCancellationRequested();
            var final = Path.Combine(folder, RecordingSessionLayout.FinalAudioFileName);
            var backup = Path.Combine(folder, RecordingSessionLayout.BackupAudioFileName);
            var partial = Path.Combine(folder, RecordingSessionLayout.PartialAudioFileName);
            if (File.Exists(final))
            {
                if (!storage.IsSafeFile(final)) { results.Add(new(folder, false, "Final media is not a safe regular file.")); continue; }
                if (!storage.IsSafeFile(Path.Combine(folder, RecordingSessionLayout.MetadataFileName)))
                {
                    try { await WriteRecoveryMetadataAsync(folder, kind, cancellationToken).ConfigureAwait(false); }
                    catch (IOException) { results.Add(new(folder, false, "Final media exists but recovery metadata could not be written yet.")); continue; }
                    catch (UnauthorizedAccessException) { results.Add(new(folder, false, "Final media exists but recovery metadata could not be written yet.")); continue; }
                }
                results.Add(new(folder, false, "Final media already exists."));
                continue;
            }
            var recoverable = storage.IsSafeFile(backup) && validator.IsValidNonEmptyAudio(backup)
                ? backup
                : storage.IsSafeFile(partial) && validator.IsValidNonEmptyAudio(partial)
                    ? partial
                    : null;
            if (recoverable is null) { results.Add(new(folder, false, "No valid recoverable backup.")); continue; }
            // Keep the recoverable artifact until metadata has been durably
            // written. A metadata failure is therefore retryable at startup.
            try { await WriteRecoveryMetadataAsync(folder, kind, cancellationToken).ConfigureAwait(false); }
            catch (IOException) { results.Add(new(folder, false, "Recovery metadata could not be written yet.")); continue; }
            catch (UnauthorizedAccessException) { results.Add(new(folder, false, "Recovery metadata could not be written yet.")); continue; }
            try { File.Move(recoverable, final, false); }
            catch (IOException) { results.Add(new(folder, false, "Recovery promotion could not be completed without overwriting media.")); continue; }
            results.Add(new(folder, true, null));
        }
        return results;
    }

    private Task WriteRecoveryMetadataAsync(string folder, RecordingSessionKind kind, CancellationToken cancellationToken)
    {
        var metadataPath = Path.Combine(folder, RecordingSessionLayout.MetadataFileName);
        // Do not feed the parser's synthetic legacy defaults back into a
        // missing document: the session kind is the only trustworthy source
        // for a newly reconstructed metadata record.
        var recovered = File.Exists(metadataPath)
            ? CreateFromExisting(storage.ReadMetadata(metadataPath), kind)
            : RecordingInfoJson.CreateAudioOnly(null, null, RecordingRecoveryState.RecoveredAfterInterruption, kind);
        return storage.WriteMetadataAsync(metadataPath, recovered, cancellationToken);
    }

    private static RecordingInfo CreateFromExisting(RecordingInfo current, RecordingSessionKind kind) =>
        RecordingInfoJson.CreateAudioOnly(
            current.Document,
            current.Title,
            RecordingRecoveryState.RecoveredAfterInterruption,
            kind);
}
