using Recorder.Core;
using TeamsRecorder.Windows.Application.Recovery;
using TeamsRecorder.Windows.Application.Storage;

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

    /// <summary>
    /// Performs the conservative startup-recovery pass, then reads the library
    /// again so callers receive exactly the media that is now publishable.
    /// </summary>
    public async Task<RecordingLibraryStartupResult> RecoverAtStartupAsync(
        CancellationToken cancellationToken = default)
    {
        var recoveryResults = await recovery.RecoverAsync(cancellationToken).ConfigureAwait(false);
        return new RecordingLibraryStartupResult(recoveryResults, storage.ListSessions());
    }

    public Task<RecordingInfo> UpdateMetadataAsync(
        string folderPath,
        string? title,
        IEnumerable<string>? tags,
        bool? isFavorite,
        CancellationToken cancellationToken = default) =>
        storage.UpdateMetadataAsync(folderPath, title, tags, isFavorite, cancellationToken);

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

    /// <summary>
    /// Removes a failed-start allocation only when it remains empty. Media,
    /// partial media, recovery evidence and diagnostics are always retained.
    /// </summary>
    public bool CleanupFailedStart(RecordingSessionPlan plan) => storage.CleanupEmptyOwnedSession(plan);
}

public sealed record RecordingLibraryStartupResult(
    IReadOnlyList<SessionRecoveryResult> RecoveryResults,
    IReadOnlyList<RecordingSessionLibraryItem> Sessions);
