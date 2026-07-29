using System.Text.Json;
using System.Text.Json.Nodes;
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
    private readonly string rootPath;
    private readonly RecordingStoragePolicy policy;
    private readonly IStorageCapacityProvider capacityProvider;
    private readonly IClock clock;
    private readonly ISessionPathCollisionProvider collisions;

    public SessionStorageService(string rootPath, RecordingStoragePolicy? policy = null, IStorageCapacityProvider? capacityProvider = null, IClock? clock = null, ISessionPathCollisionProvider? collisions = null)
    {
        if (string.IsNullOrWhiteSpace(rootPath)) throw new ArgumentException("A storage root is required.", nameof(rootPath));
        this.rootPath = Path.GetFullPath(rootPath);
        this.policy = policy ?? new RecordingStoragePolicy();
        this.capacityProvider = capacityProvider ?? new SystemStorageCapacityProvider();
        this.clock = clock ?? new SystemClock();
        this.collisions = collisions ?? new FileSystemCollisionProvider();
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
            if (collisions.DirectoryExists(folder)) continue;
            try
            {
                Directory.CreateDirectory(folder);
                // Directory.CreateDirectory is not an exclusive create operation.  Claim a short-lived
                // marker so two writers that observed the same absent folder cannot both receive it.
                var claim = Path.Combine(folder, ".session-allocation-claim");
                using (File.Open(claim, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { }
                File.Delete(claim);
                return Plan(kind, folder, capacity);
            }
            catch (IOException) { }
        }
        throw new IOException("Unable to allocate a unique recording session folder.");
    }

    public async Task PublishCompletedMediaAsync(RecordingSessionPlan plan, string? title = null, CancellationToken cancellationToken = default)
    {
        EnsurePlan(plan);
        if (!File.Exists(plan.BackupAudioPath)) throw new FileNotFoundException("The recording work file does not exist.", plan.BackupAudioPath);
        if (new FileInfo(plan.BackupAudioPath).Length <= 0) throw new IOException("The recording work file is empty.");
        if (File.Exists(plan.FinalAudioPath)) throw new IOException("A final recording already exists for this session.");
        File.Move(plan.BackupAudioPath, plan.FinalAudioPath, false);
        var info = RecordingInfo.AudioOnly(title);
        await WriteMetadataAsync(plan.MetadataPath, info, cancellationToken).ConfigureAwait(false);
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
        var temporary = metadataPath + ".tmp";
        await File.WriteAllTextAsync(temporary, info.Document.ToJsonString(JsonOptions), cancellationToken).ConfigureAwait(false);
        File.Move(temporary, metadataPath, true);
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

    private bool IsDescendant(string path) { var full = Path.GetFullPath(path); return full.StartsWith(rootPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase); }
    private static bool PathEquals(string left, string right) => string.Equals(Path.GetFullPath(left), Path.GetFullPath(right), StringComparison.OrdinalIgnoreCase);
    private static bool IsReparsePoint(string path) { try { return File.Exists(path) || Directory.Exists(path) ? (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0 : false; } catch (IOException) { return true; } catch (UnauthorizedAccessException) { return true; } }
}
