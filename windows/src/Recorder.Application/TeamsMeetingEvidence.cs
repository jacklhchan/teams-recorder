namespace TeamsRecorder.Windows.Application;

/// <summary>
/// Meeting evidence accepted by automatic recording. Only the paired Teams
/// transport may create joined/left evidence; unavailable deliberately means
/// unknown, never a meeting end. The connection generation rejects stale events
/// from a superseded socket without exposing a pairing credential.
/// </summary>
public abstract record TeamsMeetingEvidence(long ConnectionGeneration, long Revision)
{
    public sealed record JoinedConfirmed(long Generation, long EvidenceRevision = 0) : TeamsMeetingEvidence(Generation, EvidenceRevision);
    public sealed record LeftConfirmed(long Generation, long EvidenceRevision = 0) : TeamsMeetingEvidence(Generation, EvidenceRevision);
    public sealed record StateUnavailable(long Generation, long EvidenceRevision = 0) : TeamsMeetingEvidence(Generation, EvidenceRevision);
}
