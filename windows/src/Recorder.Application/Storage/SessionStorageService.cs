using System.Text.Json;
using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.VisualBasic.FileIO;
using Recorder.Core;
using TeamsRecorder.Windows.Application.Recovery;

namespace TeamsRecorder.Windows.Application.Storage;

public interface IStorageCapacityProvider { long? GetAvailableBytes(string rootPath); }
public interface IClock { DateTimeOffset UtcNow { get; } }
public interface ISessionPathCollisionProvider { bool DirectoryExists(string path); }

/// <summary>
/// A conservative publication/recovery guard for a finalized MP4.  It is not
/// a replacement for native decode verification; it only prevents an empty,
/// audio-only, or obviously incomplete work file from being renamed into the
/// library's final video name.
/// </summary>
public interface IVideoMediaValidator { bool IsValidNonEmptyVideo(string path); }

public sealed class SystemStorageCapacityProvider : IStorageCapacityProvider
{
    public long? GetAvailableBytes(string rootPath)
    {
        try { return new DriveInfo(Path.GetPathRoot(Path.GetFullPath(rootPath))!).AvailableFreeSpace; }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }
}

public sealed class SystemClock : IClock { public DateTimeOffset UtcNow => DateTimeOffset.UtcNow; }
public sealed class FileSystemCollisionProvider : ISessionPathCollisionProvider { public bool DirectoryExists(string path) => Directory.Exists(path); }

public sealed class Mp4VideoMediaValidator : IVideoMediaValidator
{
    private const int MaximumMoovBytes = 32 * 1024 * 1024;

    public bool IsValidNonEmptyVideo(string path)
    {
        try
        {
            if (!File.Exists(path) || new FileInfo(path).Length < 24)
            {
                return false;
            }

            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            var hasFtyp = false;
            var hasMdat = false;
            var hasVideoHandler = false;
            var hasVideoCodec = false;
            while (stream.Position < stream.Length)
            {
                if (!TryReadBoxHeader(stream, out var type, out var size, out var headerBytes) ||
                    size < headerBytes || size > stream.Length - stream.Position + headerBytes)
                {
                    return false;
                }

                var payloadBytes = size - headerBytes;
                switch (type)
                {
                    case "ftyp":
                        hasFtyp = true;
                        stream.Seek(payloadBytes, SeekOrigin.Current);
                        break;
                    case "mdat":
                        hasMdat |= payloadBytes > 0;
                        stream.Seek(payloadBytes, SeekOrigin.Current);
                        break;
                    case "moov" when payloadBytes <= MaximumMoovBytes:
                    {
                        var payload = new byte[checked((int)payloadBytes)];
                        stream.ReadExactly(payload);
                        hasVideoHandler |= ContainsAscii(payload, "vide");
                        hasVideoCodec |= ContainsAscii(payload, "avc1") || ContainsAscii(payload, "avc3") ||
                            ContainsAscii(payload, "hvc1") || ContainsAscii(payload, "hev1") ||
                            ContainsAscii(payload, "vp09") || ContainsAscii(payload, "av01");
                        break;
                    }
                    case "moov":
                        // A huge movie atom is not a reason to publish an
                        // unverified recording during startup recovery.
                        return false;
                    default:
                        stream.Seek(payloadBytes, SeekOrigin.Current);
                        break;
                }
            }

            // The bounded box scan rejects obvious corruption before native
            // activation. Publication still requires native H.264 + AAC
            // decoder output below; atom names alone are never proof that a
            // recording is playable.
            return hasFtyp && hasMdat && hasVideoHandler && hasVideoCodec &&
                NativeMediaDecoder.TryDecodeH264AacMp4(path);
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
        catch (ArgumentException) { return false; }
        catch (OverflowException) { return false; }
    }

    private static bool TryReadBoxHeader(Stream stream, out string type, out long size, out int headerBytes)
    {
        type = string.Empty;
        size = 0;
        headerBytes = 0;
        Span<byte> header = stackalloc byte[8];
        if (stream.Read(header) != header.Length) return false;
        var smallSize = ((long)header[0] << 24) | ((long)header[1] << 16) | ((long)header[2] << 8) | header[3];
        type = System.Text.Encoding.ASCII.GetString(header[4..]);
        headerBytes = 8;
        if (smallSize == 0) return false;
        if (smallSize != 1)
        {
            size = smallSize;
            return true;
        }

        Span<byte> extended = stackalloc byte[8];
        if (stream.Read(extended) != extended.Length) return false;
        headerBytes = 16;
        if ((extended[0] & 0x80) != 0) return false;
        size = ((long)extended[0] << 56) | ((long)extended[1] << 48) |
               ((long)extended[2] << 40) | ((long)extended[3] << 32) |
               ((long)extended[4] << 24) | ((long)extended[5] << 16) |
               ((long)extended[6] << 8) | extended[7];
        return true;
    }

    private static bool ContainsAscii(ReadOnlySpan<byte> bytes, string text) =>
        bytes.IndexOf(System.Text.Encoding.ASCII.GetBytes(text)) >= 0;
}

internal static partial class NativeMediaDecoder
{
    private const string LibraryName = "Recorder.NativeBridge";

    public static bool TryDecodeH264AacMp4(string path)
    {
        try { return ValidateH264AacMp4(path) == NativeMp4ValidationResult.Ok; }
        catch (DllNotFoundException) { return false; }
        catch (EntryPointNotFoundException) { return false; }
        catch (BadImageFormatException) { return false; }
    }

    public static bool TryDecodeAacM4a(string path)
    {
        try { return ValidateAacM4a(path) == NativeMp4ValidationResult.Ok; }
        catch (DllNotFoundException) { return false; }
        catch (EntryPointNotFoundException) { return false; }
        catch (BadImageFormatException) { return false; }
    }

    [LibraryImport(LibraryName, EntryPoint = "recorder_native_validate_h264_aac_mp4", StringMarshalling = StringMarshalling.Utf8)]
    private static partial NativeMp4ValidationResult ValidateH264AacMp4(string path);

    [LibraryImport(LibraryName, EntryPoint = "recorder_native_validate_aac_m4a", StringMarshalling = StringMarshalling.Utf8)]
    private static partial NativeMp4ValidationResult ValidateAacM4a(string path);

    private enum NativeMp4ValidationResult : uint { Ok = 0 }
}

public sealed record RecordingSessionPlan(RecordingSessionKind Kind, string FolderPath, string FinalAudioPath, string BackupAudioPath, string MetadataPath, StorageCapacityStatus Capacity)
{
    public string PartialAudioPath => Path.Combine(FolderPath, RecordingSessionLayout.PartialAudioFileName);
    public string FinalVideoPath => Path.Combine(FolderPath, RecordingSessionLayout.FinalVideoFileName);
    public string PartialVideoPath => Path.Combine(FolderPath, RecordingSessionLayout.PartialVideoFileName);
}

/// <summary>
/// A video publication can deliberately degrade to audio when the MP4 cannot
/// be safely published.  The caller can present that state without guessing
/// from file existence, while the separately finalized M4A remains playable.
/// </summary>
public sealed record RecordingVideoPublicationResult(
    bool VideoPublished,
    bool AudioPreserved,
    RecordingRecoveryState RecoveryState,
    string? Reason);
/// <summary>
/// A discoverable recording. <see cref="IsManaged"/> is false for pre-session-layout
/// M4A files found directly in the selected root; they are deliberately playback-only
/// so a library refresh never grants metadata-edit or recycle authority over them.
/// </summary>
public sealed record RecordingSessionLibraryItem(
    RecordingSessionKind Kind,
    string FolderPath,
    string AudioPath,
    long AudioBytes,
    RecordingInfo Metadata,
    bool HasRecoverableBackup,
    bool IsManaged = true)
{
    // Keep the original positional members source-compatible for existing UI
    // callers, while making the media-neutral meaning explicit for MP4 items.
    public string MediaPath => AudioPath;
    public long MediaBytes => AudioBytes;
}

/// <summary>Owns only the app's session-library filesystem layout; capture code can use the returned paths directly.</summary>
public sealed class SessionStorageService
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };
    private static readonly ConcurrentDictionary<string, SemaphoreSlim> MetadataWriteGates = new(StringComparer.OrdinalIgnoreCase);
    private readonly string rootPath;
    private readonly RecordingStoragePolicy policy;
    private readonly IStorageCapacityProvider capacityProvider;
    private readonly IClock clock;
    private readonly IVideoMediaValidator videoValidator;
    private readonly IAudioBackupValidator audioValidator;

    public SessionStorageService(
        string rootPath,
        RecordingStoragePolicy? policy = null,
        IStorageCapacityProvider? capacityProvider = null,
        IClock? clock = null,
        ISessionPathCollisionProvider? collisions = null,
        IVideoMediaValidator? videoValidator = null,
        IAudioBackupValidator? audioValidator = null)
    {
        if (string.IsNullOrWhiteSpace(rootPath)) throw new ArgumentException("A storage root is required.", nameof(rootPath));
        this.rootPath = Path.GetFullPath(rootPath);
        this.policy = policy ?? new RecordingStoragePolicy();
        this.capacityProvider = capacityProvider ?? new SystemStorageCapacityProvider();
        this.clock = clock ?? new SystemClock();
        this.videoValidator = videoValidator ?? new Mp4VideoMediaValidator();
        this.audioValidator = audioValidator ?? new M4aAudioBackupValidator();
        // Retain the optional collision provider for source compatibility. Directory creation below is
        // the authoritative, cross-process collision check.
        _ = collisions;
    }

    public StorageCapacityStatus GetCapacityStatus()
    {
        if (Directory.Exists(rootPath) && IsReparsePoint(rootPath))
        {
            return new StorageCapacityStatus(null, RecordingStorageDecision.Stop);
        }

        var available = capacityProvider.GetAvailableBytes(rootPath);
        return new StorageCapacityStatus(available, policy.Decide(available));
    }

    public RecordingSessionPlan CreateSessionPlan(RecordingSessionKind kind)
    {
        var capacity = GetCapacityStatus();
        if (!capacity.CanStart) throw new IOException("Recording cannot start because storage is unavailable or has less than 256 MiB free.");
        Directory.CreateDirectory(rootPath);
        EnsureSafeStorageRoot();
        for (var attempt = 0; attempt < 10_000; attempt++)
        {
            var folder = Path.Combine(rootPath, RecordingSessionLayout.FolderName(kind, clock.UtcNow, attempt));
            try
            {
                if (!TryCreateDirectoryAtomically(folder)) continue;
                if (IsReparsePoint(folder))
                {
                    throw new IOException("The allocated recording folder cannot be a symbolic link or reparse point.");
                }
                return Plan(kind, folder, capacity);
            }
            catch (IOException) { }
        }
        throw new IOException("Unable to allocate a unique recording session folder.");
    }

    public async Task PublishCompletedMediaAsync(RecordingSessionPlan plan, string? title = null, CancellationToken cancellationToken = default)
    {
        await PublishCompletedMediaAsync(plan, title, windowsCapture: null, cancellationToken: cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// Writes the bounded session intent before native ingress starts. This is
    /// deliberately durable so startup recovery can retain selected-app
    /// provenance after a source exits or capture faults.
    /// </summary>
    public Task WriteProvisionalMetadataAsync(
        RecordingSessionPlan plan,
        WindowsCaptureMetadata? windowsCapture,
        CancellationToken cancellationToken = default)
    {
        EnsurePlan(plan);
        var info = RecordingInfoJson.WithWindowsCapture(
            RecordingInfoJson.CreateAudioOnly(null, null, RecordingRecoveryState.None, plan.Kind),
            windowsCapture);
        return WriteMetadataAsync(plan.MetadataPath, info, cancellationToken);
    }

    /// <summary>
    /// Finalizes a recording and stores only the privacy-bounded Windows
    /// capture description. The native request's PID and output path are
    /// intentionally not accepted here and therefore cannot reach metadata.
    /// </summary>
    public async Task PublishCompletedMediaAsync(
        RecordingSessionPlan plan,
        string? title,
        WindowsCaptureMetadata? windowsCapture,
        CancellationToken cancellationToken = default)
    {
        EnsurePlan(plan);
        if (!File.Exists(plan.BackupAudioPath)) throw new FileNotFoundException("The recording work file does not exist.", plan.BackupAudioPath);
        if (!audioValidator.IsValidNonEmptyAudio(plan.BackupAudioPath)) throw new IOException("The recording work file is not a decodable AAC/M4A recording.");
        if (File.Exists(plan.FinalAudioPath)) throw new IOException("A final recording already exists for this session.");
        // Publish the metadata first. If it cannot be atomically written, the
        // backup remains in place for startup recovery instead of creating a
        // final media file that recovery would previously skip forever.
        var existing = IsSafeFile(plan.MetadataPath)
            ? ReadMetadata(plan.MetadataPath)
            : RecordingInfoJson.CreateAudioOnly(null, null, RecordingRecoveryState.None, plan.Kind);
        var info = RecordingInfoJson.WithWindowsCapture(
            RecordingInfoJson.CreateAudioOnly(existing.Document, title, RecordingRecoveryState.None, plan.Kind),
            windowsCapture ?? existing.WindowsCapture);
        await WriteMetadataAsync(plan.MetadataPath, info, cancellationToken).ConfigureAwait(false);
        File.Move(plan.BackupAudioPath, plan.FinalAudioPath, false);
    }

    /// <summary>
    /// Publishes a completed MP4 as the primary media only after a separate
    /// M4A fallback is final.  The API deliberately accepts no HWND, PID,
    /// window title, process creation time, or screen image; those values are
    /// transient capture inputs and cannot enter durable metadata here.
    /// </summary>
    public async Task<RecordingVideoPublicationResult> PublishCompletedVideoAsync(
        RecordingSessionPlan plan,
        string? title = null,
        WindowsCaptureMetadata? windowsCapture = null,
        CancellationToken cancellationToken = default)
    {
        EnsurePlan(plan);
        var existing = ReadExistingOrNewMetadata(plan);

        // Finalize the independent M4A first.  If this step fails, neither the
        // MP4 nor its work file is touched, so startup recovery still has the
        // original backup evidence.
        await EnsureAudioFallbackAsync(
            plan,
            existing,
            title,
            windowsCapture,
            RecordingRecoveryState.None,
            cancellationToken).ConfigureAwait(false);

        if (IsSafeCompletedVideo(plan.FinalVideoPath))
        {
            try
            {
                await WriteVideoMetadataAsync(
                    plan,
                    existing,
                    title,
                    windowsCapture,
                    RecordingRecoveryState.None,
                    cancellationToken).ConfigureAwait(false);
                return new RecordingVideoPublicationResult(true, true, RecordingRecoveryState.None, null);
            }
            catch (IOException error)
            {
                return new RecordingVideoPublicationResult(false, true, RecordingRecoveryState.RecoveredAfterInterruption,
                    $"MP4 was finalized but video metadata could not be published yet: {error.Message}");
            }
            catch (UnauthorizedAccessException error)
            {
                return new RecordingVideoPublicationResult(false, true, RecordingRecoveryState.RecoveredAfterInterruption,
                    $"MP4 was finalized but video metadata could not be published yet: {error.Message}");
            }
        }

        // Never overwrite a final-looking but invalid/reparse MP4.  It remains
        // evidence, while the already-final M4A becomes the only library item.
        if (File.Exists(plan.FinalVideoPath) || !IsSafeCompletedVideo(plan.PartialVideoPath))
        {
            return await PublishVideoFailureAudioFallbackCoreAsync(
                plan,
                existing,
                title,
                windowsCapture,
                "The MP4 work file was absent, invalid, or could not be safely published.",
                cancellationToken).ConfigureAwait(false);
        }

        try
        {
            File.Move(plan.PartialVideoPath, plan.FinalVideoPath, false);
        }
        catch (IOException error)
        {
            return await PublishVideoFailureAudioFallbackCoreAsync(
                plan,
                existing,
                title,
                windowsCapture,
                $"The MP4 work file could not be promoted without overwriting media: {error.Message}",
                cancellationToken).ConfigureAwait(false);
        }
        catch (UnauthorizedAccessException error)
        {
            return await PublishVideoFailureAudioFallbackCoreAsync(
                plan,
                existing,
                title,
                windowsCapture,
                $"The MP4 work file could not be promoted without overwriting media: {error.Message}",
                cancellationToken).ConfigureAwait(false);
        }

        try
        {
            await WriteVideoMetadataAsync(
                plan,
                existing,
                title,
                windowsCapture,
                RecordingRecoveryState.None,
                cancellationToken).ConfigureAwait(false);
            return new RecordingVideoPublicationResult(true, true, RecordingRecoveryState.None, null);
        }
        catch (IOException error)
        {
            // Both final media files remain intact.  Recovery will repair the
            // metadata before exposing the MP4 as a library primary item.
            return new RecordingVideoPublicationResult(false, true, RecordingRecoveryState.RecoveredAfterInterruption,
                $"Final media was retained, but video metadata could not be published yet: {error.Message}");
        }
        catch (UnauthorizedAccessException error)
        {
            return new RecordingVideoPublicationResult(false, true, RecordingRecoveryState.RecoveredAfterInterruption,
                $"Final media was retained, but video metadata could not be published yet: {error.Message}");
        }
    }

    /// <summary>
    /// Completes the safe audio path after a capture, GPU, encoder, mux, or
    /// video-publication failure.  Any partial MP4 is intentionally retained
    /// as recovery evidence and can never become library media through this
    /// operation.
    /// </summary>
    public async Task<RecordingVideoPublicationResult> PublishVideoFailureAudioFallbackAsync(
        RecordingSessionPlan plan,
        string? title = null,
        WindowsCaptureMetadata? windowsCapture = null,
        CancellationToken cancellationToken = default)
    {
        EnsurePlan(plan);
        return await PublishVideoFailureAudioFallbackCoreAsync(
            plan,
            ReadExistingOrNewMetadata(plan),
            title,
            windowsCapture,
            "Video was unavailable; the separately finalized M4A was preserved.",
            cancellationToken).ConfigureAwait(false);
    }

    private async Task<RecordingVideoPublicationResult> PublishVideoFailureAudioFallbackCoreAsync(
        RecordingSessionPlan plan,
        RecordingInfo existing,
        string? title,
        WindowsCaptureMetadata? windowsCapture,
        string reason,
        CancellationToken cancellationToken)
    {
        await EnsureAudioFallbackAsync(
            plan,
            existing,
            title,
            windowsCapture,
            RecordingRecoveryState.VideoLostAudioPreserved,
            cancellationToken).ConfigureAwait(false);
        return new RecordingVideoPublicationResult(
            VideoPublished: false,
            AudioPreserved: true,
            RecoveryState: RecordingRecoveryState.VideoLostAudioPreserved,
            Reason: reason);
    }

    private async Task EnsureAudioFallbackAsync(
        RecordingSessionPlan plan,
        RecordingInfo existing,
        string? title,
        WindowsCaptureMetadata? windowsCapture,
        RecordingRecoveryState recoveryState,
        CancellationToken cancellationToken)
    {
        if (File.Exists(plan.FinalAudioPath))
        {
            if (!IsSafeCompletedAudio(plan.FinalAudioPath))
            {
                throw new IOException("The existing final M4A is not a safe non-empty regular file.");
            }

            await WriteAudioMetadataAsync(
                plan,
                existing,
                title,
                windowsCapture,
                recoveryState,
                cancellationToken).ConfigureAwait(false);
            return;
        }

        if (!IsSafeCompletedAudio(plan.BackupAudioPath))
        {
            throw new FileNotFoundException("A non-empty M4A backup is required before video can be published.", plan.BackupAudioPath);
        }

        // Metadata is made durable before the rename.  If its write fails, the
        // backup remains exactly where native capture left it and startup can
        // retry; no final media file is created with no recoverable metadata.
        await WriteAudioMetadataAsync(
            plan,
            existing,
            title,
            windowsCapture,
            recoveryState,
            cancellationToken).ConfigureAwait(false);
        File.Move(plan.BackupAudioPath, plan.FinalAudioPath, false);
    }

    private Task WriteAudioMetadataAsync(
        RecordingSessionPlan plan,
        RecordingInfo existing,
        string? title,
        WindowsCaptureMetadata? windowsCapture,
        RecordingRecoveryState recoveryState,
        CancellationToken cancellationToken)
    {
        var audio = RecordingInfoJson.CreateAudioOnly(
            existing.Document,
            title,
            recoveryState,
            plan.Kind);
        return WriteMetadataAsync(
            plan.MetadataPath,
            RecordingInfoJson.WithWindowsCapture(audio, windowsCapture ?? existing.WindowsCapture),
            cancellationToken);
    }

    private Task WriteVideoMetadataAsync(
        RecordingSessionPlan plan,
        RecordingInfo existing,
        string? title,
        WindowsCaptureMetadata? windowsCapture,
        RecordingRecoveryState recoveryState,
        CancellationToken cancellationToken)
    {
        var video = RecordingInfoJson.CreateVideo(
            existing.Document,
            title,
            recoveryState,
            plan.Kind);
        return WriteMetadataAsync(
            plan.MetadataPath,
            RecordingInfoJson.WithWindowsCapture(video, windowsCapture ?? existing.WindowsCapture),
            cancellationToken);
    }

    private RecordingInfo ReadExistingOrNewMetadata(RecordingSessionPlan plan) =>
        IsSafeFile(plan.MetadataPath)
            ? ReadMetadata(plan.MetadataPath)
            : RecordingInfoJson.CreateAudioOnly(null, null, RecordingRecoveryState.None, plan.Kind);

    /// <summary>
    /// Removes only an empty folder allocated by this storage service after a
    /// capture start failed. Any file or child directory is evidence (media,
    /// partial media, recovery data, or diagnostics), so it is deliberately
    /// retained for recovery rather than inferred safe to delete.
    /// </summary>
    public bool CleanupEmptyOwnedSession(RecordingSessionPlan plan)
    {
        EnsurePlan(plan);
        if (!Directory.Exists(plan.FolderPath) || IsReparsePoint(plan.FolderPath)) return false;
        try
        {
            if (Directory.EnumerateFileSystemEntries(plan.FolderPath).Any()) return false;
            Directory.Delete(plan.FolderPath, recursive: false);
            return true;
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }

    /// <summary>
    /// A failed start may remove only its own known provisional metadata and
    /// then only an otherwise empty owned folder. Media, partial media,
    /// diagnostics, and unknown files are always retained as evidence.
    /// </summary>
    public bool CleanupFailedProvisionalStart(RecordingSessionPlan plan)
    {
        EnsurePlan(plan);
        if (!Directory.Exists(plan.FolderPath) || IsReparsePoint(plan.FolderPath)) return false;

        try
        {
            var entries = Directory.EnumerateFileSystemEntries(plan.FolderPath).ToArray();
            if (entries.Length == 1 && PathEquals(entries[0], plan.MetadataPath) && IsSafeFile(plan.MetadataPath))
            {
                File.Delete(plan.MetadataPath);
            }
            else if (entries.Length != 0)
            {
                return false;
            }
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }

        return CleanupEmptyOwnedSession(plan);
    }

    /// <summary>
    /// Updates user-editable session metadata without changing the media file or
    /// discarding unknown fields written by another compatible client.
    /// </summary>
    public async Task<RecordingInfo> UpdateMetadataAsync(
        string folderPath,
        string? title,
        IEnumerable<string>? tags,
        bool? isFavorite,
        CancellationToken cancellationToken = default)
    {
        EnsureOwnedFolder(folderPath);
        var metadataPath = Path.Combine(folderPath, RecordingSessionLayout.MetadataFileName);
        if (!TryGetPublishedMediaPath(folderPath, ReadMetadata(metadataPath), out _))
        {
            throw new IOException("The selected session does not contain a safe completed recording.");
        }

        var writeGate = MetadataWriteGates.GetOrAdd(metadataPath, static _ => new SemaphoreSlim(1, 1));
        await writeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            // The read-modify-write operation must be serialized in-process so two UI saves do
            // not silently discard one another's compatible/unknown metadata fields.
            var current = ReadMetadata(metadataPath);
            var document = current.Document.DeepClone() as JsonObject ?? new JsonObject();
            var normalizedTitle = NormalizeTitle(title);
            if (normalizedTitle is null)
            {
                document.Remove("title");
            }
            else
            {
                document["title"] = normalizedTitle;
            }

            if (tags is not null)
            {
                document["tags"] = new JsonArray(NormalizeTags(tags).Select(static tag => JsonValue.Create(tag)).ToArray());
            }

            if (isFavorite is { } favorite)
            {
                document["isFavorite"] = favorite;
            }

            var normalized = current.MediaKind == "video"
                ? RecordingInfoJson.CreateVideo(document, null, current.RecoveryState, GetOwnedKind(folderPath))
                : RecordingInfoJson.Normalize(document, null, null);
            await WriteMetadataAsync(metadataPath, normalized, cancellationToken).ConfigureAwait(false);
            return normalized;
        }
        finally
        {
            writeGate.Release();
        }
    }

    /// <summary>
    /// Moves a completed, managed session folder to the Windows Recycle Bin.
    /// Callers must obtain explicit user confirmation before invoking this
    /// destructive operation. Reparse points and folders without a completed
    /// managed recording are rejected before the shell is called.
    /// </summary>
    public void RecycleSession(string folderPath)
    {
        EnsureOwnedFolder(folderPath);
        var metadataPath = Path.Combine(folderPath, RecordingSessionLayout.MetadataFileName);
        if (!TryGetPublishedMediaPath(folderPath, ReadMetadata(metadataPath), out _))
        {
            throw new IOException("The selected session does not contain a safe completed recording.");
        }

        FileSystem.DeleteDirectory(
            folderPath,
            UIOption.OnlyErrorDialogs,
            RecycleOption.SendToRecycleBin,
            UICancelOption.ThrowException);
    }

    public IReadOnlyList<RecordingSessionLibraryItem> ListSessions()
    {
        if (!Directory.Exists(rootPath) || IsReparsePoint(rootPath)) return Array.Empty<RecordingSessionLibraryItem>();
        var result = new List<RecordingSessionLibraryItem>();
        try
        {
            foreach (var folder in Directory.EnumerateDirectories(rootPath))
            {
                if (!TryOwnedFolder(folder, out var kind) || IsReparsePoint(folder)) continue;
                var metadata = ReadMetadata(Path.Combine(folder, RecordingSessionLayout.MetadataFileName));
                if (metadata.MediaKind == "video")
                {
                    // Do not surface legacy/imported target identity in the
                    // Windows library even before a user makes an edit.
                    metadata = RecordingInfoJson.CreateVideo(
                        metadata.Document,
                        metadata.Title,
                        metadata.RecoveryState,
                        kind);
                    // A stale/invalid MP4 must not make its associated M4A
                    // look like a playable video recording.  Recovery will
                    // persist this same downgrade, but the library fails
                    // closed even if it is queried before recovery runs.
                    var finalAudio = Path.Combine(folder, RecordingSessionLayout.FinalAudioFileName);
                    var finalVideo = Path.Combine(folder, RecordingSessionLayout.FinalVideoFileName);
                    if ((!IsSafeCompletedVideo(finalVideo) || !IsSafeCompletedAudio(finalAudio)) &&
                        IsSafeCompletedAudio(finalAudio))
                    {
                        metadata = RecordingInfoJson.CreateAudioOnly(
                            metadata.Document,
                            metadata.Title,
                            RecordingRecoveryState.VideoLostAudioPreserved,
                            kind);
                    }
                }
                // A video record is discoverable only when its publisher has
                // written both explicit video metadata and the final MP4. A
                // partial MP4 is always recovery evidence, never library media.
                if (!TryGetPublishedMediaPath(folder, metadata, out var final)) continue;
                var backup = Path.Combine(folder, RecordingSessionLayout.BackupAudioFileName);
                result.Add(new(kind, folder, final, new FileInfo(final).Length, metadata, IsSafeFile(backup) && new FileInfo(backup).Length > 0));
            }

            // Early Windows builds wrote M4A files directly beneath the chosen
            // output folder, before each recording had a managed session folder.
            // Keep those recordings visible and playable after upgrade, but do
            // not treat them as managed folders: metadata edits and recycle are
            // intentionally restricted to the current owned-session layout.
            foreach (var audio in Directory.EnumerateFiles(rootPath, "*.m4a", System.IO.SearchOption.TopDirectoryOnly))
            {
                if (!IsSafeFile(audio)) continue;
                result.Add(new(
                    RecordingSessionKind.Manual,
                    rootPath,
                    audio,
                    new FileInfo(audio).Length,
                    RecordingInfo.AudioOnly(Path.GetFileNameWithoutExtension(audio)),
                    HasRecoverableBackup: false,
                    IsManaged: false));
            }
        }
        catch (IOException) { return Array.Empty<RecordingSessionLibraryItem>(); }
        catch (UnauthorizedAccessException) { return Array.Empty<RecordingSessionLibraryItem>(); }
        return result.OrderByDescending(x => File.GetLastWriteTimeUtc(x.AudioPath))
            .ThenByDescending(x => x.AudioPath, StringComparer.Ordinal)
            .ToArray();
    }

    internal RecordingInfo ReadMetadata(string metadataPath)
    {
        try { return RecordingInfoJson.Parse(File.ReadAllText(metadataPath)); }
        catch (IOException) { return RecordingInfoJson.Parse(null); }
        catch (UnauthorizedAccessException) { return RecordingInfoJson.Parse(null); }
    }

    internal async Task WriteMetadataAsync(string metadataPath, RecordingInfo info, CancellationToken cancellationToken)
    {
        if (!IsDescendant(metadataPath) || IsReparsePoint(metadataPath))
        {
            throw new IOException("The metadata file cannot be a symbolic link or reparse point.");
        }

        var temporary = metadataPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        var moved = false;
        try
        {
            await using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, useAsync: true))
            await using (var writer = new StreamWriter(stream))
            {
                await writer.WriteAsync(info.Document.ToJsonString(JsonOptions).AsMemory(), cancellationToken).ConfigureAwait(false);
            }

            // The temporary file is in the destination directory, so Windows replaces the destination
            // with a same-volume rename rather than exposing a partially-written metadata file.
            await ReplaceMetadataAtomicallyAsync(temporary, metadataPath, cancellationToken).ConfigureAwait(false);
            moved = true;
        }
        finally
        {
            if (!moved)
            {
                try { File.Delete(temporary); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        }
    }

    internal IEnumerable<(string Folder, RecordingSessionKind Kind)> EnumerateOwnedFolders()
    {
        if (!Directory.Exists(rootPath) || IsReparsePoint(rootPath))
        {
            return Array.Empty<(string Folder, RecordingSessionKind Kind)>();
        }

        var result = new List<(string Folder, RecordingSessionKind Kind)>();
        try
        {
            foreach (var folder in Directory.EnumerateDirectories(rootPath))
            {
                if (TryOwnedFolder(folder, out var kind) && !IsReparsePoint(folder))
                {
                    result.Add((folder, kind));
                }
            }
        }
        catch (IOException) { return Array.Empty<(string Folder, RecordingSessionKind Kind)>(); }
        catch (UnauthorizedAccessException) { return Array.Empty<(string Folder, RecordingSessionKind Kind)>(); }
        return result;
    }

    internal bool IsSafeFile(string path) => IsDescendant(path) && File.Exists(path) && !IsReparsePoint(path);

    /// <summary>Shared by publication and startup recovery; a final MP4 must pass the bounded structural guard.</summary>
    internal bool IsSafeCompletedVideo(string path) => IsSafeNonEmptyFile(path) && videoValidator.IsValidNonEmptyVideo(path);

    /// <summary>A final M4A must have a decodable AAC sample, not merely bytes or BMFF atom names.</summary>
    internal bool IsSafeCompletedAudio(string path)
    {
        return IsSafeNonEmptyFile(path) && audioValidator.IsValidNonEmptyAudio(path);
    }

    internal bool IsSafeNonEmptyFile(string path)
    {
        try { return IsSafeFile(path) && new FileInfo(path).Length > 0; }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }

    private bool TryGetPublishedMediaPath(string folder, RecordingInfo metadata, out string mediaPath)
    {
        var finalVideo = Path.Combine(folder, RecordingSessionLayout.FinalVideoFileName);
        var finalAudio = Path.Combine(folder, RecordingSessionLayout.FinalAudioFileName);
        if (metadata.MediaKind == "video" && IsSafeCompletedVideo(finalVideo) && IsSafeCompletedAudio(finalAudio))
        {
            mediaPath = finalVideo;
            return true;
        }

        if (IsSafeCompletedAudio(finalAudio))
        {
            mediaPath = finalAudio;
            return true;
        }

        mediaPath = string.Empty;
        return false;
    }

    private static string? NormalizeTitle(string? title)
    {
        var value = title?.Trim();
        if (string.IsNullOrEmpty(value)) return null;
        if (value.Length > 200) throw new ArgumentException("A session title cannot exceed 200 characters.", nameof(title));
        return value;
    }

    private static IReadOnlyList<string> NormalizeTags(IEnumerable<string> tags)
    {
        var normalized = new List<string>();
        foreach (var tag in tags)
        {
            var value = tag?.Trim();
            if (string.IsNullOrEmpty(value)) continue;
            if (value.Length > 64) throw new ArgumentException("A session tag cannot exceed 64 characters.", nameof(tags));
            if (normalized.Contains(value, StringComparer.OrdinalIgnoreCase)) continue;
            normalized.Add(value);
            if (normalized.Count > 20) throw new ArgumentException("A session cannot have more than 20 tags.", nameof(tags));
        }

        return normalized;
    }

    private RecordingSessionPlan Plan(RecordingSessionKind kind, string folder, StorageCapacityStatus capacity) => new(kind, folder, Path.Combine(folder, RecordingSessionLayout.FinalAudioFileName), Path.Combine(folder, RecordingSessionLayout.BackupAudioFileName), Path.Combine(folder, RecordingSessionLayout.MetadataFileName), capacity);

    private RecordingSessionKind GetOwnedKind(string folder)
    {
        if (!TryOwnedFolder(folder, out var kind))
        {
            throw new InvalidOperationException("The session folder is not a managed direct child of the storage root.");
        }
        return kind;
    }

    private bool TryOwnedFolder(string folder, out RecordingSessionKind kind)
    {
        kind = default;
        return IsDescendant(folder) &&
            RecordingSessionLayout.TryGetKind(Path.GetFileName(folder), out kind);
    }
    private void EnsurePlan(RecordingSessionPlan plan)
    {
        EnsureOwnedFolder(plan.FolderPath);
        var expectedFinal = Path.Combine(plan.FolderPath, RecordingSessionLayout.FinalAudioFileName);
        var expectedBackup = Path.Combine(plan.FolderPath, RecordingSessionLayout.BackupAudioFileName);
        var expectedMetadata = Path.Combine(plan.FolderPath, RecordingSessionLayout.MetadataFileName);
        var expectedFinalVideo = Path.Combine(plan.FolderPath, RecordingSessionLayout.FinalVideoFileName);
        var expectedPartialVideo = Path.Combine(plan.FolderPath, RecordingSessionLayout.PartialVideoFileName);
        if (!PathEquals(plan.FinalAudioPath, expectedFinal) ||
            !PathEquals(plan.BackupAudioPath, expectedBackup) ||
            !PathEquals(plan.MetadataPath, expectedMetadata) ||
            !PathEquals(plan.FinalVideoPath, expectedFinalVideo) ||
            !PathEquals(plan.PartialVideoPath, expectedPartialVideo))
        {
            throw new InvalidOperationException("The recording session plan contains an unexpected path.");
        }
    }

    private void EnsureOwnedFolder(string folder)
    {
        EnsureSafeStorageRoot();
        if (!TryOwnedFolder(folder, out _) || IsReparsePoint(folder))
        {
            throw new InvalidOperationException("The session folder is not a managed direct child of the storage root.");
        }
    }

    private void EnsureSafeStorageRoot()
    {
        if (IsReparsePoint(rootPath))
        {
            throw new IOException("The selected recording folder cannot be a symbolic link or reparse point.");
        }
    }

    private static bool TryCreateDirectoryAtomically(string path)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Atomic recording-session allocation is implemented for Windows only.");
        }

        if (CreateDirectory(path, IntPtr.Zero)) return true;
        var error = Marshal.GetLastWin32Error();
        if (error is 80 or 183) return false; // ERROR_FILE_EXISTS / ERROR_ALREADY_EXISTS
        throw new IOException($"Unable to create recording session folder '{path}'.", new Win32Exception(error));
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateDirectory(string lpPathName, IntPtr lpSecurityAttributes);

    private static async Task ReplaceMetadataAtomicallyAsync(string temporary, string metadataPath, CancellationToken cancellationToken)
    {
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                File.Move(temporary, metadataPath, true);
                return;
            }
            catch (IOException error) when (attempt < 20 && IsTransientReplacementConflict(error))
            {
                await Task.Delay(TimeSpan.FromMilliseconds(5), cancellationToken).ConfigureAwait(false);
            }
            catch (UnauthorizedAccessException error) when (attempt < 20 && IsTransientReplacementConflict(error))
            {
                await Task.Delay(TimeSpan.FromMilliseconds(5), cancellationToken).ConfigureAwait(false);
            }
        }
    }

    private static bool IsTransientReplacementConflict(Exception error)
    {
        var win32Error = error.HResult & 0xffff;
        return win32Error is 5 or 32 or 33; // ERROR_ACCESS_DENIED / SHARING_VIOLATION / LOCK_VIOLATION
    }

    private bool IsDescendant(string path) { var full = Path.GetFullPath(path); return full.StartsWith(rootPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase); }
    private static bool PathEquals(string left, string right) => string.Equals(Path.GetFullPath(left), Path.GetFullPath(right), StringComparison.OrdinalIgnoreCase);
    private static bool IsReparsePoint(string path) { try { return File.Exists(path) || Directory.Exists(path) ? (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0 : false; } catch (IOException) { return true; } catch (UnauthorizedAccessException) { return true; } }
}
