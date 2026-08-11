using Recorder.Core;
using TeamsRecorder.Windows.Application.Recovery;
using TeamsRecorder.Windows.Application.Storage;
using TeamsRecorder.Windows.Application.Transcription;

namespace TeamsRecorder.Windows.Application.Library;

/// <summary>
/// Application-layer façade for the recording library.  It deliberately owns
/// no UI state: callers can refresh a view-model from <see cref="ListSessions"/>
/// and invoke the explicitly named, safe library operations from commands.
/// </summary>
public sealed class RecordingLibraryService
{
    private readonly SessionStorageService storage;
    private readonly SessionRecoveryService recovery;

    public RecordingLibraryService(
        SessionStorageService storage,
        SessionRecoveryService? recovery = null)
    {
        this.storage = storage ?? throw new ArgumentNullException(nameof(storage));
        this.recovery = recovery ?? new SessionRecoveryService(storage);
    }

    public IReadOnlyList<RecordingSessionLibraryItem> ListSessions() => storage.ListSessions();

    /// <summary>Imports a user-selected audio file without modifying the source.</summary>
    public Task<ManualTranscriptionImportResult> ImportAudioForTranscriptionAsync(
        string sourcePath,
        CancellationToken cancellationToken = default) =>
        new ManualTranscriptionImporter().ImportAsync(storage, sourcePath, cancellationToken);

    /// <summary>
    /// Re-enumerates the library and returns a session only when its current
    /// immutable fingerprint still matches the row that initiated an action.
    /// A path alone is intentionally insufficient: a recycled or replaced
    /// folder must never receive an action intended for an older row.
    /// </summary>
    public RecordingSessionLibraryItem? ResolveCanonicalSession(RecordingLibrarySessionIdentity expected)
    {
        ArgumentNullException.ThrowIfNull(expected);
        return storage.ListSessions().SingleOrDefault(expected.Matches);
    }

    /// <summary>
    /// Performs the conservative startup-recovery pass, then reads the library
    /// again so callers receive exactly the media that is now publishable.
    /// </summary>
    public async Task<RecordingLibraryStartupResult> RecoverAtStartupAsync(
        CancellationToken cancellationToken = default)
    {
        var recoveryResults = await RecoverEvidenceAtStartupAsync(cancellationToken).ConfigureAwait(false);
        return new RecordingLibraryStartupResult(recoveryResults, storage.ListSessions());
    }

    /// <summary>
    /// Completes only the safety-critical evidence pass. UI startup can become
    /// recording-ready after this returns and load the decode-validated library
    /// projection separately in the background.
    /// </summary>
    public Task<IReadOnlyList<SessionRecoveryResult>> RecoverEvidenceAtStartupAsync(
        CancellationToken cancellationToken = default) =>
        recovery.RecoverAsync(cancellationToken);

    public Task<RecordingInfo> UpdateMetadataAsync(
        string folderPath,
        string? title,
        IEnumerable<string>? tags,
        bool? isFavorite,
        CancellationToken cancellationToken = default) =>
        storage.UpdateMetadataAsync(folderPath, title, tags, isFavorite, cancellationToken);

    /// <summary>Updates metadata only after a fresh, matching canonical row is found.</summary>
    public Task<RecordingInfo> UpdateMetadataAsync(
        RecordingLibrarySessionIdentity expected,
        string? title,
        IEnumerable<string>? tags,
        bool? isFavorite,
        CancellationToken cancellationToken = default)
    {
        var current = RequireCanonicalManagedSession(expected);
        return storage.UpdateMetadataAsync(current.FolderPath, title, tags, isFavorite, cancellationToken);
    }

    /// <summary>
    /// Sends a completed managed session to the Windows Recycle Bin only after
    /// the UI has recorded an affirmative, per-session user confirmation.
    /// </summary>
    public void RecycleSession(string folderPath, bool userConfirmed)
    {
        if (!userConfirmed)
        {
            throw new InvalidOperationException("Deleting a recording requires explicit user confirmation.");
        }

        storage.RecycleSession(folderPath);
    }

    /// <summary>Recycles only the exact canonical session that was confirmed by the user.</summary>
    public void RecycleSession(RecordingLibrarySessionIdentity expected, bool userConfirmed)
    {
        if (!userConfirmed)
        {
            throw new InvalidOperationException("Deleting a recording requires explicit user confirmation.");
        }

        var current = RequireCanonicalManagedSession(expected);
        storage.RecycleSession(current.FolderPath);
    }

    /// <summary>
    /// Removes a failed-start allocation only when it remains empty. Media,
    /// partial media, recovery evidence and diagnostics are always retained.
    /// </summary>
    public bool CleanupFailedStart(RecordingSessionPlan plan) => storage.CleanupEmptyOwnedSession(plan);

    private RecordingSessionLibraryItem RequireCanonicalManagedSession(RecordingLibrarySessionIdentity expected)
    {
        var current = ResolveCanonicalSession(expected)
            ?? throw new IOException("The selected recording changed or is no longer available. Refresh the library and choose it again.");
        if (!current.IsManaged)
        {
            throw new InvalidOperationException("Legacy recordings are playback-only and cannot be changed or recycled by this app.");
        }

        return current;
    }
}

public sealed record RecordingLibraryStartupResult(
    IReadOnlyList<SessionRecoveryResult> RecoveryResults,
    IReadOnlyList<RecordingSessionLibraryItem> Sessions);
