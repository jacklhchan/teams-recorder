using System.Text.Json;
using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.VisualBasic.FileIO;
using Recorder.Core;

namespace TeamsRecorder.Windows.Application.Storage;

public interface IStorageCapacityProvider { long? GetAvailableBytes(string rootPath); }
public interface IClock { DateTimeOffset UtcNow { get; } }
public interface ISessionPathCollisionProvider { bool DirectoryExists(string path); }

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

public sealed record RecordingSessionPlan(RecordingSessionKind Kind, string FolderPath, string FinalAudioPath, string BackupAudioPath, string MetadataPath, StorageCapacityStatus Capacity);
public sealed record RecordingSessionLibraryItem(RecordingSessionKind Kind, string FolderPath, string AudioPath, long AudioBytes, RecordingInfo Metadata, bool HasRecoverableBackup);

/// <summary>Owns only the app's session-library filesystem layout; capture code can use the returned paths directly.</summary>
public sealed class SessionStorageService
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };
    private static readonly ConcurrentDictionary<string, SemaphoreSlim> MetadataWriteGates = new(StringComparer.OrdinalIgnoreCase);
    private readonly string rootPath;
    private readonly RecordingStoragePolicy policy;
    private readonly IStorageCapacityProvider capacityProvider;
    private readonly IClock clock;

    public SessionStorageService(string rootPath, RecordingStoragePolicy? policy = null, IStorageCapacityProvider? capacityProvider = null, IClock? clock = null, ISessionPathCollisionProvider? collisions = null)
    {
        if (string.IsNullOrWhiteSpace(rootPath)) throw new ArgumentException("A storage root is required.", nameof(rootPath));
        this.rootPath = Path.GetFullPath(rootPath);
        this.policy = policy ?? new RecordingStoragePolicy();
        this.capacityProvider = capacityProvider ?? new SystemStorageCapacityProvider();
        this.clock = clock ?? new SystemClock();
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
        if (new FileInfo(plan.BackupAudioPath).Length <= 0) throw new IOException("The recording work file is empty.");
        if (File.Exists(plan.FinalAudioPath)) throw new IOException("A final recording already exists for this session.");
        // Publish the metadata first. If it cannot be atomically written, the
        // backup remains in place for startup recovery instead of creating a
        // final media file that recovery would previously skip forever.
        var info = RecordingInfoJson.WithWindowsCapture(
            RecordingInfoJson.CreateAudioOnly(null, title, RecordingRecoveryState.None, plan.Kind),
            windowsCapture);
        await WriteMetadataAsync(plan.MetadataPath, info, cancellationToken).ConfigureAwait(false);
        File.Move(plan.BackupAudioPath, plan.FinalAudioPath, false);
    }

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
        var finalAudio = Path.Combine(folderPath, RecordingSessionLayout.FinalAudioFileName);
        if (!IsSafeFile(finalAudio))
        {
            throw new IOException("The selected session does not contain a safe completed recording.");
        }

        var metadataPath = Path.Combine(folderPath, RecordingSessionLayout.MetadataFileName);
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

            var normalized = RecordingInfoJson.Normalize(document, null, null);
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
        var finalAudio = Path.Combine(folderPath, RecordingSessionLayout.FinalAudioFileName);
        if (!IsSafeFile(finalAudio))
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
                var final = Path.Combine(folder, RecordingSessionLayout.FinalAudioFileName);
                if (!IsSafeFile(final)) continue;
                var metadata = ReadMetadata(Path.Combine(folder, RecordingSessionLayout.MetadataFileName));
                var backup = Path.Combine(folder, RecordingSessionLayout.BackupAudioFileName);
                result.Add(new(kind, folder, final, new FileInfo(final).Length, metadata, IsSafeFile(backup) && new FileInfo(backup).Length > 0));
            }
        }
        catch (IOException) { return Array.Empty<RecordingSessionLibraryItem>(); }
        catch (UnauthorizedAccessException) { return Array.Empty<RecordingSessionLibraryItem>(); }
        return result.OrderByDescending(x => x.FolderPath, StringComparer.Ordinal).ToArray();
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
        if (!PathEquals(plan.FinalAudioPath, expectedFinal) ||
            !PathEquals(plan.BackupAudioPath, expectedBackup) ||
            !PathEquals(plan.MetadataPath, expectedMetadata))
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
