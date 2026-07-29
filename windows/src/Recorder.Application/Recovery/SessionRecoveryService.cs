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
            if (!File.Exists(path) || new FileInfo(path).Length < 12)
            {
                return false;
            }

            Span<byte> header = stackalloc byte[12];
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            return stream.Read(header) == header.Length &&
                header[4] == (byte)'f' && header[5] == (byte)'t' &&
                header[6] == (byte)'y' && header[7] == (byte)'p';
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
        foreach (var (folder, _) in storage.EnumerateOwnedFolders())
        {
            cancellationToken.ThrowIfCancellationRequested();
            var final = Path.Combine(folder, RecordingSessionLayout.FinalAudioFileName);
            var backup = Path.Combine(folder, RecordingSessionLayout.BackupAudioFileName);
            if (File.Exists(final)) { results.Add(new(folder, false, "Final media already exists.")); continue; }
            if (!storage.IsSafeFile(backup) || !validator.IsValidNonEmptyAudio(backup)) { results.Add(new(folder, false, "No valid recoverable backup.")); continue; }
            try { File.Move(backup, final, false); }
            catch (IOException) { results.Add(new(folder, false, "Recovery promotion could not be completed without overwriting media.")); continue; }
            var current = storage.ReadMetadata(Path.Combine(folder, RecordingSessionLayout.MetadataFileName));
            var recovered = RecordingInfoJson.CreateAudioOnly(
                current.Document,
                current.Title,
                RecordingRecoveryState.RecoveredAfterInterruption);
            await storage.WriteMetadataAsync(Path.Combine(folder, RecordingSessionLayout.MetadataFileName), recovered, cancellationToken).ConfigureAwait(false);
            results.Add(new(folder, true, null));
        }
        return results;
    }
}
