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
public sealed record SessionRecoveryResult(
    string FolderPath,
    bool Recovered,
    string? Reason,
    RecordingRecoveryState RecoveryState = RecordingRecoveryState.None);

public sealed class SessionRecoveryService
{
    private readonly SessionStorageService storage;
    private readonly IAudioBackupValidator validator;
    private readonly IRecoveryMediaValidator recoveryMediaValidator;

    public SessionRecoveryService(
        SessionStorageService storage,
        IAudioBackupValidator? validator = null,
        IRecoveryMediaValidator? recoveryMediaValidator = null)
    {
        this.storage = storage;
        this.validator = validator ?? new M4aAudioBackupValidator();
        this.recoveryMediaValidator = recoveryMediaValidator ?? new StorageRecoveryMediaValidator(storage);
    }

    public async Task<IReadOnlyList<SessionRecoveryResult>> RecoverAsync(CancellationToken cancellationToken = default)
    {
        var results = new List<SessionRecoveryResult>();
        foreach (var (folder, kind) in storage.EnumerateOwnedFolders())
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (CanSkipCompletedPublishedFolder(folder, kind))
            {
                results.Add(new SessionRecoveryResult(folder, false, "Completed session already published."));
                continue;
            }
            results.Add(await RecoverFolderAsync(folder, kind, cancellationToken).ConfigureAwait(false));
        }
        return results;
    }

    private bool CanSkipCompletedPublishedFolder(string folder, RecordingSessionKind kind)
    {
        try
        {
            var metadataPath = Path.Combine(folder, RecordingSessionLayout.MetadataFileName);
            if (!storage.IsSafeFile(metadataPath)) return false;
            var current = storage.ReadMetadata(metadataPath);
            if (current.RecoveryState != RecordingRecoveryState.None) return false;

            var hasRecoveryMediaEvidence =
                File.Exists(Path.Combine(folder, RecordingSessionLayout.BackupAudioFileName)) ||
                File.Exists(Path.Combine(folder, RecordingSessionLayout.PartialAudioFileName)) ||
                File.Exists(Path.Combine(folder, RecordingSessionLayout.PartialVideoFileName)) ||
                File.Exists(Path.Combine(folder, RecordingSessionLayout.LegacyDoublePartialVideoFileName)) ||
                File.Exists(Path.Combine(folder, RecordingSessionLayout.AudioSafetyPartialFileName));

            var canonical = current.MediaKind == "video"
                ? RecordingInfoJson.CreateVideo(current.Document, current.Title, RecordingRecoveryState.None, kind)
                : RecordingInfoJson.CreateAudioOnly(current.Document, current.Title, RecordingRecoveryState.None, kind);
            if (!System.Text.Json.Nodes.JsonNode.DeepEquals(canonical.Document, current.Document)) return false;

            var finalVideo = Path.Combine(folder, RecordingSessionLayout.FinalVideoFileName);
            var declaredFinal = current.MediaKind == "video" || File.Exists(finalVideo)
                ? finalVideo
                : Path.Combine(folder, RecordingSessionLayout.FinalAudioFileName);
            if (!storage.IsSafeNonEmptyFile(declaredFinal)) return false;
            if (!hasRecoveryMediaEvidence) return true;

            // A successful prior library pass already decoded this exact final
            // file fingerprint. Leftover safety evidence remains untouched, but
            // must not force the same completed media through recovery on every
            // subsequent launch. A changed file invalidates the fingerprint and
            // falls back to the full conservative recovery path.
            return storage.IsKnownValidCompletedMedia(declaredFinal, current.MediaKind);
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
        catch (ArgumentException) { return false; }
    }

    private async Task<SessionRecoveryResult> RecoverFolderAsync(
        string folder,
        RecordingSessionKind kind,
        CancellationToken cancellationToken)
    {
        if (!storage.TryAcquireSessionLock(folder, out var sessionLock))
        {
            return new SessionRecoveryResult(folder, false, "The recording session is active or its exclusive lock is unavailable.");
        }

        using (sessionLock)
        {
            return await RecoverUnlockedFolderAsync(folder, kind, cancellationToken).ConfigureAwait(false);
        }
    }

    private async Task<SessionRecoveryResult> RecoverUnlockedFolderAsync(
        string folder,
        RecordingSessionKind kind,
        CancellationToken cancellationToken)
    {
        var finalAudio = Path.Combine(folder, RecordingSessionLayout.FinalAudioFileName);
        var backupAudio = Path.Combine(folder, RecordingSessionLayout.BackupAudioFileName);
        var partialAudio = Path.Combine(folder, RecordingSessionLayout.PartialAudioFileName);
        var finalVideo = Path.Combine(folder, RecordingSessionLayout.FinalVideoFileName);
        var partialVideo = Path.Combine(folder, RecordingSessionLayout.PartialVideoFileName);
        var legacyDoublePartialVideo = Path.Combine(folder, RecordingSessionLayout.LegacyDoublePartialVideoFileName);
        var audioSafety = Path.Combine(folder, RecordingSessionLayout.AudioSafetyPartialFileName);
        var journal = storage.ReadRecoveryJournal(Path.Combine(folder, RecordingSessionLayout.RecoveryJournalFileName));
        var metadataPath = Path.Combine(folder, RecordingSessionLayout.MetadataFileName);
        var metadataExists = storage.IsSafeFile(metadataPath);
        var current = metadataExists
            ? storage.ReadMetadata(metadataPath)
            : RecordingInfoJson.CreateAudioOnly(null, null, RecordingRecoveryState.None, kind);

        var hasRecoveryMediaEvidence = File.Exists(backupAudio) || File.Exists(partialAudio) ||
            File.Exists(partialVideo) || File.Exists(legacyDoublePartialVideo) || File.Exists(audioSafety);
        var declaredFinalPath = current.MediaKind == "video"
            ? finalVideo
            : File.Exists(finalVideo)
                ? finalVideo
                : finalAudio;
        var canonicalPublishedMetadata = current.MediaKind == "video"
            ? RecordingInfoJson.CreateVideo(current.Document, current.Title, RecordingRecoveryState.None, kind)
            : RecordingInfoJson.CreateAudioOnly(current.Document, current.Title, RecordingRecoveryState.None, kind);
        var publishedMetadataIsCanonical = System.Text.Json.Nodes.JsonNode.DeepEquals(
            canonicalPublishedMetadata.Document,
            current.Document);
        if (metadataExists && current.RecoveryState == RecordingRecoveryState.None &&
            !hasRecoveryMediaEvidence && storage.IsSafeNonEmptyFile(declaredFinalPath))
        {
            // Atomic publication already validated the completed media before
            // committing this metadata. Startup recovery must not decode every
            // multi-minute library item to EOF again when no recovery evidence
            // exists; doing so blocks recorder readiness for the library's
            // cumulative duration.
            if (!publishedMetadataIsCanonical)
            {
                try
                {
                    await storage.WriteMetadataAsync(
                        metadataPath,
                        canonicalPublishedMetadata,
                        cancellationToken).ConfigureAwait(false);
                    return new SessionRecoveryResult(folder, false, "Completed session metadata was sanitized.");
                }
                catch (IOException)
                {
                    return new SessionRecoveryResult(folder, false, "Completed session metadata could not be sanitized yet.");
                }
                catch (UnauthorizedAccessException)
                {
                    return new SessionRecoveryResult(folder, false, "Completed session metadata could not be sanitized yet.");
                }
            }

            return new SessionRecoveryResult(folder, false, "Completed session already published.");
        }

        var hasFinalAudio = storage.IsSafeCompletedAudio(finalAudio);
        var hasFinalVideo = storage.IsSafeCompletedVideo(finalVideo);
        var completedLegacyVideo = storage.IsSafeCompletedVideo(partialVideo)
            ? partialVideo
            : storage.IsSafeCompletedVideo(legacyDoublePartialVideo)
                ? legacyDoublePartialVideo
                : null;
        var hasPartialVideo = completedLegacyVideo is not null;
        var hasFragmentedVideoEvidence = File.Exists(partialVideo) || File.Exists(legacyDoublePartialVideo) ||
            journal?.AudioVideo is not null;
        var hasVideoEvidence = current.MediaKind == "video" || File.Exists(finalVideo) || hasFragmentedVideoEvidence;

        // FailedEvidenceRetained is a terminal, fail-closed result for the
        // exact evidence already present. Re-running a synchronous decoder on
        // the same malformed partial at every startup can indefinitely block
        // recorder readiness. Preserve it byte-for-byte and retry only if a
        // new journal or a completed media artifact appears later.
        if (metadataExists && current.RecoveryState == RecordingRecoveryState.FailedEvidenceRetained &&
            !hasFinalAudio && !hasFinalVideo && journal is null)
        {
            return FailedEvidence(folder, "Previously rejected recovery evidence remains retained for diagnostics.");
        }

        // A second process must be able to finish a publication interrupted
        // after the no-overwrite rename but before metadata commit.
        if (!hasFinalVideo && current.MediaKind == "audio" && storage.IsSafeNonEmptyFile(finalVideo) &&
            recoveryMediaValidator.ValidateToEnd(finalVideo, RecoveryMediaKind.AudioOnlyMp4).IsValid)
        {
            var state = hasFragmentedVideoEvidence
                ? RecordingRecoveryState.VideoLostAudioPreserved
                : RecordingRecoveryState.RecoveredAfterInterruption;
            if (metadataExists && current.RecoveryState == state)
            {
                return new SessionRecoveryResult(folder, false, "Recovered audio MP4 already exists.", state);
            }
            try
            {
                await WriteRecoveryMetadataAsync(folder, kind, current, isVideo: false, state, cancellationToken)
                    .ConfigureAwait(false);
                return new SessionRecoveryResult(folder, true, null, state);
            }
            catch (IOException) { return FailedEvidence(folder, "Recovered audio MP4 metadata could not be written yet."); }
            catch (UnauthorizedAccessException) { return FailedEvidence(folder, "Recovered audio MP4 metadata could not be written yet."); }
        }

        // A normal completed fMP4 may not have a legacy M4A beside it. The
        // durable fMP4/journal contract supersedes that old publication rule.
        if (hasFinalVideo && hasFragmentedVideoEvidence && !hasFinalAudio)
        {
            if (metadataExists && current.MediaKind == "video" &&
                current.RecoveryState is RecordingRecoveryState.None or RecordingRecoveryState.RecoveredAfterInterruption)
            {
                var sanitized = RecordingInfoJson.CreateVideo(
                    current.Document,
                    current.Title,
                    current.RecoveryState,
                    kind);
                if (string.Equals(
                    sanitized.Document.ToJsonString(),
                    current.Document.ToJsonString(),
                    StringComparison.Ordinal))
                {
                    return new SessionRecoveryResult(
                        folder,
                        false,
                        "Final fragmented MP4 already exists.",
                        current.RecoveryState);
                }
                try
                {
                    await storage.WriteMetadataAsync(metadataPath, sanitized, cancellationToken).ConfigureAwait(false);
                    return new SessionRecoveryResult(
                        folder,
                        false,
                        "Final fragmented MP4 metadata was sanitized.",
                        current.RecoveryState);
                }
                catch (IOException) { return FailedEvidence(folder, "Final fragmented MP4 metadata could not be sanitized yet."); }
                catch (UnauthorizedAccessException) { return FailedEvidence(folder, "Final fragmented MP4 metadata could not be sanitized yet."); }
            }
            try
            {
                var state = current.MediaKind == "video" && current.RecoveryState == RecordingRecoveryState.None
                    ? RecordingRecoveryState.None
                    : RecordingRecoveryState.RecoveredAfterInterruption;
                await WriteRecoveryMetadataAsync(folder, kind, current, isVideo: true, state, cancellationToken)
                    .ConfigureAwait(false);
                return new SessionRecoveryResult(folder, state != RecordingRecoveryState.None, null, state);
            }
            catch (IOException) { return FailedEvidence(folder, "Final fragmented MP4 metadata could not be written yet."); }
            catch (UnauthorizedAccessException) { return FailedEvidence(folder, "Final fragmented MP4 metadata could not be written yet."); }
        }

        if (!File.Exists(finalVideo))
        {
            var videoAttempt = await TryPromoteFragmentedPrefixAsync(
                folder,
                [
                    new FragmentedSource(partialVideo, journal?.AudioVideo?.DurableByteOffset),
                    new FragmentedSource(legacyDoublePartialVideo, null),
                ],
                finalVideo,
                RecoveryMediaKind.AudioVideoMp4,
                "recording.recovery-video.candidate.mp4",
                cancellationToken).ConfigureAwait(false);
            if (videoAttempt.Promoted)
            {
                try
                {
                    await WriteRecoveryMetadataAsync(
                        folder,
                        kind,
                        current,
                        isVideo: true,
                        RecordingRecoveryState.RecoveredAfterInterruption,
                        cancellationToken).ConfigureAwait(false);
                    return new SessionRecoveryResult(
                        folder,
                        true,
                        null,
                        RecordingRecoveryState.RecoveredAfterInterruption);
                }
                catch (IOException) { return FailedEvidence(folder, "Recovered video metadata could not be written yet."); }
                catch (UnauthorizedAccessException) { return FailedEvidence(folder, "Recovered video metadata could not be written yet."); }
            }

            var audioAttempt = await TryPromoteFragmentedPrefixAsync(
                folder,
                [new FragmentedSource(audioSafety, journal?.AudioSafety?.DurableByteOffset)],
                finalVideo,
                RecoveryMediaKind.AudioOnlyMp4,
                "recording.recovery-audio.candidate.mp4",
                cancellationToken).ConfigureAwait(false);
            if (audioAttempt.Promoted)
            {
                var state = hasVideoEvidence
                    ? RecordingRecoveryState.VideoLostAudioPreserved
                    : RecordingRecoveryState.RecoveredAfterInterruption;
                try
                {
                    await WriteRecoveryMetadataAsync(folder, kind, current, isVideo: false, state, cancellationToken)
                        .ConfigureAwait(false);
                    return new SessionRecoveryResult(folder, true, null, state);
                }
                catch (IOException) { return FailedEvidence(folder, "Recovered audio metadata could not be written yet."); }
                catch (UnauthorizedAccessException) { return FailedEvidence(folder, "Recovered audio metadata could not be written yet."); }
            }
        }

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
                    await TryWriteFailedEvidenceMetadataAsync(folder, kind, current, cancellationToken).ConfigureAwait(false);
                    return FailedEvidence(
                        folder,
                        "Validated partial MP4 was retained but no valid M4A fallback could be published: " + audio.Reason);
                }
                hasFinalAudio = true;
            }

            try
            {
                File.Move(completedLegacyVideo!, finalVideo, false);
            }
            catch (IOException)
            {
                await TryWriteAudioFallbackMetadataAsync(folder, kind, current, cancellationToken).ConfigureAwait(false);
                return new SessionRecoveryResult(
                    folder,
                    false,
                    "Validated partial MP4 could not be promoted without overwriting media.",
                    RecordingRecoveryState.VideoLostAudioPreserved);
            }
            catch (UnauthorizedAccessException)
            {
                await TryWriteAudioFallbackMetadataAsync(folder, kind, current, cancellationToken).ConfigureAwait(false);
                return new SessionRecoveryResult(
                    folder,
                    false,
                    "Validated partial MP4 could not be promoted without overwriting media.",
                    RecordingRecoveryState.VideoLostAudioPreserved);
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

        var legacyResult = await RecoverAudioOnlyAsync(
            folder,
            kind,
            current,
            metadataExists,
            finalAudio,
            backupAudio,
            partialAudio,
            hasVideoEvidence,
            cancellationToken).ConfigureAwait(false);
        if (legacyResult.Recovered || storage.IsSafeCompletedAudio(finalAudio) ||
            storage.IsSafeCompletedVideo(finalVideo))
        {
            return legacyResult;
        }

        var hasRetainedEvidence = File.Exists(finalVideo) || File.Exists(partialVideo) ||
            File.Exists(legacyDoublePartialVideo) || File.Exists(audioSafety) ||
            File.Exists(backupAudio) || File.Exists(partialAudio) || journal is not null;
        if (!hasRetainedEvidence) return legacyResult;

        await TryWriteFailedEvidenceMetadataAsync(folder, kind, current, cancellationToken).ConfigureAwait(false);
        return FailedEvidence(folder, legacyResult.Reason ?? "No recoverable media passed full validation.");
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
                return new SessionRecoveryResult(folder, false, "Final media already exists; metadata was repaired.", recoveryState);
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
            ? new SessionRecoveryResult(folder, true, null, recoveryState)
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

    private async Task<FragmentedPromotionAttempt> TryPromoteFragmentedPrefixAsync(
        string folder,
        IReadOnlyList<FragmentedSource> sources,
        string finalPath,
        RecoveryMediaKind mediaKind,
        string candidateFileName,
        CancellationToken cancellationToken)
    {
        var hadEvidence = false;
        string? lastReason = null;
        foreach (var source in sources)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!storage.IsSafeFile(source.Path)) continue;
            hadEvidence = true;

            var scan = FragmentedMp4PrefixScanner.Scan(source.Path, source.DurableByteLimit);
            if (!scan.HasRecoverablePrefix)
            {
                lastReason = scan.Reason;
                continue;
            }

            var candidate = Path.Combine(folder, candidateFileName);
            try
            {
                if (File.Exists(candidate))
                {
                    if (!storage.IsSafeFile(candidate))
                    {
                        lastReason = "The recovery staging path is not a safe regular file.";
                        continue;
                    }

                    var existingValidation = recoveryMediaValidator.ValidateToEnd(candidate, mediaKind);
                    if (!existingValidation.IsValid)
                    {
                        // This is a derived copy, never the only evidence. The
                        // source remains byte-for-byte intact for the retry.
                        File.Delete(candidate);
                    }
                }

                if (!File.Exists(candidate))
                {
                    await CopyPrefixWithWriteThroughAsync(
                        source.Path,
                        candidate,
                        scan.CompletePrefixLength,
                        cancellationToken).ConfigureAwait(false);
                }

                var validation = recoveryMediaValidator.ValidateToEnd(candidate, mediaKind);
                if (!validation.IsValid)
                {
                    lastReason = validation.Reason;
                    continue;
                }

                File.Move(candidate, finalPath, overwrite: false);
                return new FragmentedPromotionAttempt(true, true, null);
            }
            catch (IOException error)
            {
                lastReason = error.Message;
            }
            catch (UnauthorizedAccessException error)
            {
                lastReason = error.Message;
            }
        }

        return new FragmentedPromotionAttempt(false, hadEvidence, lastReason);
    }

    private static async Task CopyPrefixWithWriteThroughAsync(
        string sourcePath,
        string candidatePath,
        long byteCount,
        CancellationToken cancellationToken)
    {
        if (byteCount <= 0) throw new IOException("A recovery prefix must be non-empty.");
        await using var source = new FileStream(
            sourcePath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            1024 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        if (byteCount > source.Length) throw new IOException("The selected recovery prefix exceeds its evidence file.");

        await using var destination = new FileStream(
            candidatePath,
            FileMode.CreateNew,
            FileAccess.Write,
            FileShare.None,
            1024 * 1024,
            FileOptions.Asynchronous | FileOptions.WriteThrough);
        var buffer = new byte[1024 * 1024];
        var remaining = byteCount;
        while (remaining > 0)
        {
            var read = await source.ReadAsync(
                buffer.AsMemory(0, (int)Math.Min(buffer.Length, remaining)),
                cancellationToken).ConfigureAwait(false);
            if (read == 0) throw new EndOfStreamException("The recovery evidence ended before its complete fragment boundary.");
            await destination.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
            remaining -= read;
        }
        await destination.FlushAsync(cancellationToken).ConfigureAwait(false);
        destination.Flush(flushToDisk: true);
    }

    private async Task TryWriteFailedEvidenceMetadataAsync(
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
                isVideo: current.MediaKind == "video",
                RecordingRecoveryState.FailedEvidenceRetained,
                cancellationToken).ConfigureAwait(false);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static SessionRecoveryResult FailedEvidence(string folder, string reason) =>
        new(folder, false, reason, RecordingRecoveryState.FailedEvidenceRetained);

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
    private sealed record FragmentedSource(string Path, long? DurableByteLimit);
    private sealed record FragmentedPromotionAttempt(bool Promoted, bool HadEvidence, string? Reason);
}
