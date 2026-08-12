using System.Text;
using TeamsRecorder.Windows.Application.AI;

namespace TeamsRecorder.Windows.Application.Transcription;

public sealed record MeetingIntelligenceTranscriptRevision(string Sha256, int ByteCount)
{
    public static MeetingIntelligenceTranscriptRevision FromBytes(ReadOnlySpan<byte> bytes)
    {
        var digest = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(bytes));
        return new("sha256:" + digest, bytes.Length);
    }
}

public sealed record MeetingIntelligenceCanonicalTranscript(
    string Text,
    byte[] Utf8Bytes,
    MeetingIntelligenceTranscriptRevision Revision);

public enum MeetingIntelligencePipelineStage { SummarizingChunks, ReducingSummaries, GeneratingFinal }
public sealed record MeetingIntelligenceProgress(MeetingIntelligencePipelineStage Stage, int Current, int Total);

public enum MeetingIntelligencePipelineFailure
{
    SourceTooLarge,
    InvalidSource,
    RequestTooLarge,
    TooManyChunks,
    PartialTooLarge,
    TooManyRequests,
    MaximumDepthReached,
    DeadlineExceeded,
}

public sealed class MeetingIntelligencePipelineException(MeetingIntelligencePipelineFailure failure, string message)
    : Exception(message)
{
    public MeetingIntelligencePipelineFailure Failure { get; } = failure;
}

/// <summary>
/// Deterministic, bounded long-transcript map/reduce pipeline. It never truncates source or
/// publishes partial work. A worst-case 64-chunk job requires at most 64 + 6 + 1 requests.
/// </summary>
public sealed class MeetingIntelligencePipeline
{
    public const int MaximumSourceBytes = 4 * 1024 * 1024;
    public const int MaximumChunkBytes = 64 * 1024;
    public const int MaximumChunks = 64;
    public const int MaximumPartialSummaryBytes = 4 * 1024;
    public const int MaximumReductionGroupSize = 12;
    public const int MaximumReductionDepth = 4;
    public const int MaximumRequests = 71;
    public static readonly TimeSpan MaximumDuration = TimeSpan.FromMinutes(30);

    private readonly IMeetingIntelligenceRequestClient client;
    private readonly Func<DateTimeOffset> now;

    public MeetingIntelligencePipeline(
        IMeetingIntelligenceRequestClient client,
        Func<DateTimeOffset>? now = null)
    {
        this.client = client ?? throw new ArgumentNullException(nameof(client));
        this.now = now ?? (() => DateTimeOffset.UtcNow);
    }

    public async Task<MeetingIntelligenceGeneratedContent> GenerateAsync(
        MeetingIntelligenceCanonicalTranscript transcript,
        OpenAICompatibleProviderSnapshot snapshot,
        IProgress<MeetingIntelligenceProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(transcript);
        ArgumentNullException.ThrowIfNull(snapshot);
        var deadline = now() + MaximumDuration;
        CheckBoundary(deadline, cancellationToken);
        if (transcript.Utf8Bytes.Length > MaximumSourceBytes)
            throw new MeetingIntelligencePipelineException(MeetingIntelligencePipelineFailure.SourceTooLarge, "The canonical transcript exceeds 4 MiB.");
        if (transcript.Utf8Bytes.Length == 0 || !string.Equals(transcript.Text, StrictUtf8(transcript.Utf8Bytes), StringComparison.Ordinal))
            throw new MeetingIntelligencePipelineException(MeetingIntelligencePipelineFailure.InvalidSource, "The canonical transcript is empty or invalid UTF-8.");

        var chunks = Split(transcript.Utf8Bytes, snapshot);
        if (chunks.Count > MaximumChunks)
            throw new MeetingIntelligencePipelineException(MeetingIntelligencePipelineFailure.TooManyChunks, "The transcript requires more than 64 chunks.");

        var requestCount = 0;
        if (chunks.Count == 1)
        {
            PrepareRequest(ref requestCount, deadline, cancellationToken, progress,
                new(MeetingIntelligencePipelineStage.GeneratingFinal, 1, 1));
            var direct = await client.RequestFinalResultAsync(chunks[0], snapshot, cancellationToken).ConfigureAwait(false);
            CheckBoundary(deadline, cancellationToken);
            return ValidateFinal(direct);
        }

        var summaries = new List<string>(chunks.Count);
        for (var index = 0; index < chunks.Count; index++)
        {
            PrepareRequest(ref requestCount, deadline, cancellationToken, progress,
                new(MeetingIntelligencePipelineStage.SummarizingChunks, index + 1, chunks.Count));
            var summary = await client.RequestPartialSummaryAsync(chunks[index], snapshot, cancellationToken).ConfigureAwait(false);
            CheckBoundary(deadline, cancellationToken);
            summaries.Add(ValidatePartial(summary));
        }

        var depth = 0;
        while (RequiresReduction(summaries, snapshot))
        {
            if (depth >= MaximumReductionDepth)
                throw new MeetingIntelligencePipelineException(MeetingIntelligencePipelineFailure.MaximumDepthReached, "The summary reduction exceeded four levels.");
            var groups = ReductionGroups(summaries, snapshot);
            var reduced = new List<string>(groups.Count);
            for (var index = 0; index < groups.Count; index++)
            {
                PrepareRequest(ref requestCount, deadline, cancellationToken, progress,
                    new(MeetingIntelligencePipelineStage.ReducingSummaries, index + 1, groups.Count));
                var summary = await client.RequestPartialSummaryAsync(string.Join('\n', groups[index]), snapshot, cancellationToken).ConfigureAwait(false);
                CheckBoundary(deadline, cancellationToken);
                reduced.Add(ValidatePartial(summary));
            }
            summaries = reduced;
            depth++;
        }

        var finalInput = string.Join('\n', summaries);
        if (!client.FitsRequest(finalInput, snapshot, final: true))
            throw new MeetingIntelligencePipelineException(MeetingIntelligencePipelineFailure.RequestTooLarge, "The reduced summary cannot fit in the final request.");
        PrepareRequest(ref requestCount, deadline, cancellationToken, progress,
            new(MeetingIntelligencePipelineStage.GeneratingFinal, 1, 1));
        var result = await client.RequestFinalResultAsync(finalInput, snapshot, cancellationToken).ConfigureAwait(false);
        CheckBoundary(deadline, cancellationToken);
        return ValidateFinal(result);
    }

    private IReadOnlyList<string> Split(byte[] bytes, OpenAICompatibleProviderSnapshot snapshot)
    {
        var chunks = new List<string>();
        var offset = 0;
        var isSingleChunk = bytes.Length <= MaximumChunkBytes;
        while (offset < bytes.Length)
        {
            if (chunks.Count >= MaximumChunks)
                throw new MeetingIntelligencePipelineException(MeetingIntelligencePipelineFailure.TooManyChunks, "The transcript requires more than 64 chunks.");
            var upper = Math.Min(offset + MaximumChunkBytes, bytes.Length);
            var remainingSlots = MaximumChunks - chunks.Count - 1;
            var lower = Math.Max(offset + 1, bytes.Length - (remainingSlots * MaximumChunkBytes));
            var preferred = PreferredBoundary(bytes, offset, Math.Min(lower, upper), upper);
            var end = FittingBoundary(bytes, offset, Math.Min(lower, upper), preferred, snapshot, final: isSingleChunk);
            if (end <= offset)
                throw new MeetingIntelligencePipelineException(MeetingIntelligencePipelineFailure.RequestTooLarge, "A transcript chunk cannot fit in the request envelope.");
            var value = StrictUtf8(bytes.AsSpan(offset, end - offset));
            if (value is null)
                throw new MeetingIntelligencePipelineException(MeetingIntelligencePipelineFailure.InvalidSource, "The transcript contains invalid UTF-8.");
            chunks.Add(value);
            offset = end;
        }
        return chunks;
    }

    private int FittingBoundary(byte[] bytes, int start, int lower, int upper, OpenAICompatibleProviderSnapshot snapshot, bool final)
    {
        var boundaries = new List<int> { start };
        for (var index = start + 1; index <= upper; index++)
        {
            if (index == bytes.Length || !IsContinuation(bytes[index])) boundaries.Add(index);
        }
        var low = boundaries.FindIndex(value => value >= lower);
        if (low < 1) low = 1;
        var high = boundaries.Count - 1;
        var best = -1;
        while (low <= high)
        {
            var middle = low + ((high - low) / 2);
            var candidate = boundaries[middle];
            var value = StrictUtf8(bytes.AsSpan(start, candidate - start));
            if (value is not null && client.FitsRequest(value, snapshot, final))
            {
                best = candidate;
                low = middle + 1;
            }
            else high = middle - 1;
        }
        if (best < 0)
            throw new MeetingIntelligencePipelineException(MeetingIntelligencePipelineFailure.RequestTooLarge, "A transcript scalar cannot fit in the request envelope.");
        return best;
    }

    private static int PreferredBoundary(byte[] bytes, int start, int lower, int upper)
    {
        if (upper == bytes.Length) return upper;
        while (upper > start && IsContinuation(bytes[upper])) upper--;
        var preferredLower = Math.Max(lower, Math.Max(start + 1, upper - (16 * 1024)));
        for (var index = upper - 1; index >= preferredLower; index--)
        {
            if (bytes[index] == (byte)'\n') return index + 1;
            if (index + 1 < upper && bytes[index + 1] == (byte)' ' && bytes[index] is (byte)'.' or (byte)'!' or (byte)'?') return index + 2;
        }
        return upper;
    }

    private bool RequiresReduction(IReadOnlyList<string> summaries, OpenAICompatibleProviderSnapshot snapshot)
    {
        if (summaries.Count > MaximumReductionGroupSize) return true;
        var joined = string.Join('\n', summaries);
        return Encoding.UTF8.GetByteCount(joined) > MaximumChunkBytes || !client.FitsRequest(joined, snapshot, final: true);
    }

    private IReadOnlyList<IReadOnlyList<string>> ReductionGroups(IReadOnlyList<string> summaries, OpenAICompatibleProviderSnapshot snapshot)
    {
        var groups = new List<IReadOnlyList<string>>();
        var current = new List<string>();
        foreach (var summary in summaries)
        {
            var candidate = current.Append(summary).ToArray();
            if (candidate.Length <= MaximumReductionGroupSize &&
                Encoding.UTF8.GetByteCount(string.Join('\n', candidate)) <= MaximumChunkBytes &&
                client.FitsRequest(string.Join('\n', candidate), snapshot, final: false))
            {
                current.Add(summary);
                continue;
            }
            if (current.Count == 0 || !client.FitsRequest(summary, snapshot, final: false))
                throw new MeetingIntelligencePipelineException(MeetingIntelligencePipelineFailure.RequestTooLarge, "A partial summary cannot fit in a reduction request.");
            groups.Add(current.ToArray());
            current.Clear();
            current.Add(summary);
        }
        if (current.Count > 0) groups.Add(current.ToArray());
        return groups;
    }

    private static string ValidatePartial(string value)
    {
        try { return MeetingIntelligenceOutputValidator.ValidateSummary(value, MaximumPartialSummaryBytes); }
        catch (MeetingIntelligenceClientException error)
        {
            throw new MeetingIntelligencePipelineException(MeetingIntelligencePipelineFailure.PartialTooLarge, error.Message);
        }
    }

    private static MeetingIntelligenceGeneratedContent ValidateFinal(MeetingIntelligenceGeneratedContent value) => new(
        MeetingIntelligenceOutputValidator.ValidateTitle(value.SuggestedTitle),
        MeetingIntelligenceOutputValidator.ValidateSummary(value.Summary));

    private void PrepareRequest(
        ref int requestCount,
        DateTimeOffset deadline,
        CancellationToken cancellationToken,
        IProgress<MeetingIntelligenceProgress>? progress,
        MeetingIntelligenceProgress value)
    {
        CheckBoundary(deadline, cancellationToken);
        if (requestCount >= MaximumRequests)
            throw new MeetingIntelligencePipelineException(MeetingIntelligencePipelineFailure.TooManyRequests, "The job exceeded 71 provider requests.");
        requestCount++;
        progress?.Report(value);
        CheckBoundary(deadline, cancellationToken);
    }

    private void CheckBoundary(DateTimeOffset deadline, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (now() >= deadline)
            throw new MeetingIntelligencePipelineException(MeetingIntelligencePipelineFailure.DeadlineExceeded, "Meeting intelligence exceeded 30 minutes.");
    }

    private static bool IsContinuation(byte value) => (value & 0b1100_0000) == 0b1000_0000;

    private static string? StrictUtf8(ReadOnlySpan<byte> bytes)
    {
        try { return new UTF8Encoding(false, true).GetString(bytes); }
        catch (DecoderFallbackException) { return null; }
    }
}
