using Recorder.Core;
using TeamsRecorder.Windows.Application.Storage;

namespace TeamsRecorder.Windows.Application.Recovery;

public interface IAudioBackupValidator { bool IsValidNonEmptyAudio(string path); }

/// <summary>
/// A fail-closed M4A publication guard. It first rejects malformed ISO-BMFF
/// input cheaply, then requires the shipped native Media Foundation decoder to
/// produce a non-empty AAC sample. Atom names or non-empty bytes alone are
/// never sufficient to promote an audio recovery artifact.
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
            return hasFtyp && hasMoov && NativeMediaDecoder.TryDecodeAacM4a(path);
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
            results.Add(await RecoverFolderAsync(folder, kind, cancellationToken).ConfigureAwait(false));
        }
        return results;
    }

    private async Task<SessionRecoveryResult> RecoverFolderAsync(
        string folder,
        RecordingSessionKind kind,
        CancellationToken cancellationToken)
    {
        var finalAudio = Path.Combine(folder, RecordingSessionLayout.FinalAudioFileName);
        var backupAudio = Path.Combine(folder, RecordingSessionLayout.BackupAudioFileName);
        var partialAudio = Path.Combine(folder, RecordingSessionLayout.PartialAudioFileName);
        var finalVideo = Path.Combine(folder, RecordingSessionLayout.FinalVideoFileName);
        var partialVideo = Path.Combine(folder, RecordingSessionLayout.PartialVideoFileName);
        var metadataPath = Path.Combine(folder, RecordingSessionLayout.MetadataFileName);
        var metadataExists = storage.IsSafeFile(metadataPath);
        var current = metadataExists
            ? storage.ReadMetadata(metadataPath)
            : RecordingInfoJson.CreateAudioOnly(null, null, RecordingRecoveryState.None, kind);
        var hasFinalAudio = storage.IsSafeCompletedAudio(finalAudio);
        var hasFinalVideo = storage.IsSafeCompletedVideo(finalVideo);
        var hasPartialVideo = storage.IsSafeCompletedVideo(partialVideo);
        var hasVideoEvidence = current.MediaKind == "video" || File.Exists(finalVideo) || File.Exists(partialVideo);

        if (hasFinalVideo)
        {
            if (!hasFinalAudio)
            {
                var audio = await PromoteAudioFallbackAsync(
                    folder,
                    kind,
                    current,
                    backupAudio,
                    partialAudio,
                    RecordingRecoveryState.VideoLostAudioPreserved,
                    cancellationToken).ConfigureAwait(false);
                if (!audio.Succeeded)
                {
                    return new SessionRecoveryResult(folder, false,
                        "Final MP4 was retained but no valid M4A fallback could be published: " + audio.Reason);
                }
                hasFinalAudio = true;
            }

            if (metadataExists && current.MediaKind == "video" && current.RecoveryState == RecordingRecoveryState.None)
            {
                var sanitized = RecordingInfoJson.CreateVideo(
                    current.Document,
                    current.Title,
                    RecordingRecoveryState.None,
                    kind);
                if (string.Equals(
                        sanitized.Document.ToJsonString(),
                        current.Document.ToJsonString(),
                        StringComparison.Ordinal))
                {
                    return new SessionRecoveryResult(folder, false, "Final video and M4A fallback already exist.");
                }

                try
                {
                    await storage.WriteMetadataAsync(metadataPath, sanitized, cancellationToken).ConfigureAwait(false);
                    return new SessionRecoveryResult(folder, false, "Final video metadata was sanitized.");
                }
                catch (IOException) { return new SessionRecoveryResult(folder, false, "Final MP4 exists but video metadata could not be sanitized yet."); }
                catch (UnauthorizedAccessException) { return new SessionRecoveryResult(folder, false, "Final MP4 exists but video metadata could not be sanitized yet."); }
            }

            try
            {
                await WriteRecoveryMetadataAsync(
                    folder,
                    kind,
                    current,
                    isVideo: true,
                    RecordingRecoveryState.RecoveredAfterInterruption,
                    cancellationToken).ConfigureAwait(false);
                return new SessionRecoveryResult(folder, true, null);
            }
            catch (IOException) { return new SessionRecoveryResult(folder, false, "Final MP4 exists but recovery metadata could not be written yet."); }
            catch (UnauthorizedAccessException) { return new SessionRecoveryResult(folder, false, "Final MP4 exists but recovery metadata could not be written yet."); }
        }

        if (hasPartialVideo && !File.Exists(finalVideo))
        {
            if (!hasFinalAudio)
            {
                var audio = await PromoteAudioFallbackAsync(
                    folder,
                    kind,
                    current,
                    backupAudio,
                    partialAudio,
                    RecordingRecoveryState.VideoLostAudioPreserved,
                    cancellationToken).ConfigureAwait(false);
                if (!audio.Succeeded)
                {
                    return new SessionRecoveryResult(folder, false,
                        "Validated partial MP4 was retained but no valid M4A fallback could be published: " + audio.Reason);
                }
                hasFinalAudio = true;
            }

            try
            {
                File.Move(partialVideo, finalVideo, false);
            }
            catch (IOException)
            {
                await TryWriteAudioFallbackMetadataAsync(folder, kind, current, cancellationToken).ConfigureAwait(false);
                return new SessionRecoveryResult(folder, false, "Validated partial MP4 could not be promoted without overwriting media.");
            }
            catch (UnauthorizedAccessException)
            {
                await TryWriteAudioFallbackMetadataAsync(folder, kind, current, cancellationToken).ConfigureAwait(false);
                return new SessionRecoveryResult(folder, false, "Validated partial MP4 could not be promoted without overwriting media.");
            }

            try
            {
                await WriteRecoveryMetadataAsync(
                    folder,
                    kind,
                    current,
                    isVideo: true,
                    RecordingRecoveryState.RecoveredAfterInterruption,
                    cancellationToken).ConfigureAwait(false);
                return new SessionRecoveryResult(folder, true, null);
            }
            catch (IOException) { return new SessionRecoveryResult(folder, false, "Finalized MP4 was retained but recovery metadata could not be written yet."); }
            catch (UnauthorizedAccessException) { return new SessionRecoveryResult(folder, false, "Finalized MP4 was retained but recovery metadata could not be written yet."); }
        }

        return await RecoverAudioOnlyAsync(
            folder,
            kind,
            current,
            metadataExists,
            finalAudio,
            backupAudio,
            partialAudio,
            hasVideoEvidence,
            cancellationToken).ConfigureAwait(false);
    }

    private async Task<SessionRecoveryResult> RecoverAudioOnlyAsync(
        string folder,
        RecordingSessionKind kind,
        RecordingInfo current,
        bool metadataExists,
        string finalAudio,
        string backupAudio,
        string partialAudio,
        bool videoWasExpected,
        CancellationToken cancellationToken)
    {
        var recoveryState = videoWasExpected
            ? RecordingRecoveryState.VideoLostAudioPreserved
            : RecordingRecoveryState.RecoveredAfterInterruption;
        if (storage.IsSafeCompletedAudio(finalAudio))
        {
            if (metadataExists && current.MediaKind == "audio" &&
                (!videoWasExpected || current.RecoveryState == RecordingRecoveryState.VideoLostAudioPreserved))
            {
                return new SessionRecoveryResult(folder, false, "Final media already exists.");
            }

            try
            {
                await WriteRecoveryMetadataAsync(folder, kind, current, isVideo: false, recoveryState, cancellationToken).ConfigureAwait(false);
                return new SessionRecoveryResult(folder, false, "Final media already exists; metadata was repaired.");
            }
            catch (IOException) { return new SessionRecoveryResult(folder, false, "Final media exists but recovery metadata could not be written yet."); }
            catch (UnauthorizedAccessException) { return new SessionRecoveryResult(folder, false, "Final media exists but recovery metadata could not be written yet."); }
        }

        var audio = await PromoteAudioFallbackAsync(
            folder,
            kind,
            current,
            backupAudio,
            partialAudio,
            recoveryState,
            cancellationToken).ConfigureAwait(false);
        return audio.Succeeded
            ? new SessionRecoveryResult(folder, true, null)
            : new SessionRecoveryResult(folder, false, audio.Reason);
    }

    private async Task<AudioPromotionResult> PromoteAudioFallbackAsync(
        string folder,
        RecordingSessionKind kind,
        RecordingInfo current,
        string backupAudio,
        string partialAudio,
        RecordingRecoveryState recoveryState,
        CancellationToken cancellationToken)
    {
        var recoverable = storage.IsSafeFile(backupAudio) && validator.IsValidNonEmptyAudio(backupAudio)
            ? backupAudio
            : storage.IsSafeFile(partialAudio) && validator.IsValidNonEmptyAudio(partialAudio)
                ? partialAudio
                : null;
        if (recoverable is null)
        {
            return new AudioPromotionResult(false, "No valid recoverable M4A backup.");
        }

        // Keep the recoverable artifact until metadata has been durably
        // written.  A metadata failure is therefore retryable at startup.
        try
        {
            await WriteRecoveryMetadataAsync(folder, kind, current, isVideo: false, recoveryState, cancellationToken).ConfigureAwait(false);
        }
        catch (IOException) { return new AudioPromotionResult(false, "Recovery metadata could not be written yet."); }
        catch (UnauthorizedAccessException) { return new AudioPromotionResult(false, "Recovery metadata could not be written yet."); }

        try
        {
            File.Move(recoverable, Path.Combine(folder, RecordingSessionLayout.FinalAudioFileName), false);
            return new AudioPromotionResult(true, null);
        }
        catch (IOException) { return new AudioPromotionResult(false, "Recovery promotion could not be completed without overwriting media."); }
        catch (UnauthorizedAccessException) { return new AudioPromotionResult(false, "Recovery promotion could not be completed without overwriting media."); }
    }

    private async Task TryWriteAudioFallbackMetadataAsync(
        string folder,
        RecordingSessionKind kind,
        RecordingInfo current,
        CancellationToken cancellationToken)
    {
        try
        {
            await WriteRecoveryMetadataAsync(
                folder,
                kind,
                current,
                isVideo: false,
                RecordingRecoveryState.VideoLostAudioPreserved,
                cancellationToken).ConfigureAwait(false);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private Task WriteRecoveryMetadataAsync(
        string folder,
        RecordingSessionKind kind,
        RecordingInfo current,
        bool isVideo,
        RecordingRecoveryState recoveryState,
        CancellationToken cancellationToken)
    {
        var metadataPath = Path.Combine(folder, RecordingSessionLayout.MetadataFileName);
        var recovered = isVideo
            ? RecordingInfoJson.CreateVideo(current.Document, current.Title, recoveryState, kind)
            : RecordingInfoJson.CreateAudioOnly(current.Document, current.Title, recoveryState, kind);
        return storage.WriteMetadataAsync(metadataPath, recovered, cancellationToken);
    }

    private sealed record AudioPromotionResult(bool Succeeded, string? Reason);
}
