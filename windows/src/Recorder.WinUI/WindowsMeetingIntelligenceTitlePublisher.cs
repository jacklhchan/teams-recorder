using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Recorder.Core;
using TeamsRecorder.Windows.Application.Library;
using TeamsRecorder.Windows.Application.Storage;
using TeamsRecorder.Windows.Application.Transcription;

namespace TeamsRecorder.Windows.WinUI;

/// <summary>
/// Applies the first generated contextual title only while the owned metadata
/// title is still empty and byte-identical to the captured revision. Any user
/// title, including a title produced by a previous generation, is preserved.
/// </summary>
internal sealed class WindowsMeetingIntelligenceTitlePublisher(RecordingLibraryService library)
    : IMeetingIntelligenceTitlePublisher
{
    public async Task<MeetingIntelligenceTitleSnapshot> CaptureAsync(
        RecordingSessionPlan plan,
        CancellationToken cancellationToken)
    {
        var (title, revision) = await ReadAsync(plan, cancellationToken).ConfigureAwait(false);
        return new(title,
            string.IsNullOrWhiteSpace(title) ? MeetingIntelligenceTitleOrigin.Unset : MeetingIntelligenceTitleOrigin.Manual,
            revision);
    }

    public async Task<MeetingIntelligenceTitlePublicationOutcome> TryApplyAsync(
        RecordingSessionPlan plan,
        MeetingIntelligenceTitleSnapshot captured,
        string suggestedTitle,
        MeetingIntelligenceTranscriptRevision sourceRevision,
        CancellationToken cancellationToken)
    {
        _ = sourceRevision;
        if (captured.Origin == MeetingIntelligenceTitleOrigin.Manual)
            return MeetingIntelligenceTitlePublicationOutcome.Preserved;
        var (currentTitle, currentRevision) = await ReadAsync(plan, cancellationToken).ConfigureAwait(false);
        if (!string.Equals(currentRevision, captured.RevisionToken, StringComparison.Ordinal) ||
            !string.IsNullOrWhiteSpace(currentTitle))
            return MeetingIntelligenceTitlePublicationOutcome.Conflict;
        try
        {
            await library.UpdateMetadataAsync(plan.FolderPath, suggestedTitle, tags: null, isFavorite: null, cancellationToken)
                .ConfigureAwait(false);
            return MeetingIntelligenceTitlePublicationOutcome.Applied;
        }
        catch (IOException) { return MeetingIntelligenceTitlePublicationOutcome.Failed; }
        catch (UnauthorizedAccessException) { return MeetingIntelligenceTitlePublicationOutcome.Failed; }
    }

    private static async Task<(string? Title, string Revision)> ReadAsync(
        RecordingSessionPlan plan,
        CancellationToken cancellationToken)
    {
        var path = Path.GetFullPath(plan.MetadataPath);
        var folder = Path.GetFullPath(plan.FolderPath) + Path.DirectorySeparatorChar;
        if (!path.StartsWith(folder, StringComparison.OrdinalIgnoreCase))
            throw new IOException("The meeting title metadata path is not owned by the session.");
        var info = new FileInfo(path);
        if (!info.Exists || (info.Attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0 ||
            info.Length > 1024 * 1024)
            throw new IOException("The meeting title metadata is missing or unsafe.");
        var bytes = await File.ReadAllBytesAsync(path, cancellationToken).ConfigureAwait(false);
        using var document = JsonDocument.Parse(bytes);
        var title = document.RootElement.TryGetProperty("title", out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()?.Trim()
            : null;
        var revision = "sha256:" + Convert.ToHexStringLower(SHA256.HashData(bytes));
        return (title, revision);
    }
}
