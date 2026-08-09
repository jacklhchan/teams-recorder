using System.Buffers.Binary;
using Recorder.Core;
using TeamsRecorder.Windows.Application.Storage;

namespace TeamsRecorder.Windows.Application.Recovery;

public enum RecoveryMediaKind
{
    AudioVideoMp4,
    AudioOnlyMp4,
}

public sealed record RecoveryMediaValidationResult(bool IsValid, string? Reason = null)
{
    public static RecoveryMediaValidationResult Valid { get; } = new(true);
    public static RecoveryMediaValidationResult Invalid(string reason) => new(false, reason);
}

/// <summary>
/// Recovery publication requires a decoder to consume the candidate through
/// end-of-stream. Producing one sample is deliberately not this contract.
/// </summary>
public interface IRecoveryMediaValidator
{
    RecoveryMediaValidationResult ValidateToEnd(string path, RecoveryMediaKind mediaKind);
}

public sealed record FragmentedMp4PrefixScanResult(
    bool HasRecoverablePrefix,
    long CompletePrefixLength,
    int CompleteFragmentCount,
    string? Reason);

/// <summary>
/// Allocation-free top-level ISO-BMFF scanner used only to find a conservative
/// fMP4 cut point. It never treats structure as playback proof; the resulting
/// copy must still pass <see cref="IRecoveryMediaValidator"/>.
/// </summary>
public static class FragmentedMp4PrefixScanner
{
    private const int MaximumTopLevelBoxes = 1_000_000;
    private const uint Ftyp = 0x66747970;
    private const uint Moov = 0x6d6f6f76;
    private const uint Moof = 0x6d6f6f66;
    private const uint Mdat = 0x6d646174;
    private const uint Free = 0x66726565;
    private const uint Skip = 0x736b6970;
    private const uint Sidx = 0x73696478;
    private const uint Emsg = 0x656d7367;
    private const uint Prft = 0x70726674;
    private const uint Uuid = 0x75756964;
    private const uint Styp = 0x73747970;

    public static FragmentedMp4PrefixScanResult Scan(string path, long? durableByteLimit = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            var limit = durableByteLimit is { } durable
                ? Math.Min(Math.Max(durable, 0), stream.Length)
                : stream.Length;
            if (limit < 8)
            {
                return Failed("The durable region is too short to contain an ISO-BMFF box.");
            }

            var offset = 0L;
            var lastCompletePrefix = 0L;
            var fragmentCount = 0;
            var boxCount = 0;
            var hasFtyp = false;
            var hasMoov = false;
            var awaitingMdat = false;

            Span<byte> header = stackalloc byte[16];
            while (offset < limit && boxCount++ < MaximumTopLevelBoxes)
            {
                var remaining = limit - offset;
                if (remaining < 8)
                {
                    break;
                }

                stream.Position = offset;
                if (stream.Read(header[..8]) != 8)
                {
                    break;
                }

                var compactSize = BinaryPrimitives.ReadUInt32BigEndian(header[..4]);
                var type = BinaryPrimitives.ReadUInt32BigEndian(header.Slice(4, 4));
                long boxSize;
                var headerBytes = 8;
                if (compactSize == 0)
                {
                    // A size-to-EOF box cannot prove that a crash-truncated
                    // payload reached its declared boundary.
                    break;
                }
                if (compactSize == 1)
                {
                    if (remaining < 16 || stream.Read(header.Slice(8, 8)) != 8)
                    {
                        break;
                    }
                    var extendedSize = BinaryPrimitives.ReadUInt64BigEndian(header.Slice(8, 8));
                    if (extendedSize > long.MaxValue)
                    {
                        break;
                    }
                    boxSize = (long)extendedSize;
                    headerBytes = 16;
                }
                else
                {
                    boxSize = compactSize;
                }

                if (boxSize < headerBytes || boxSize > remaining)
                {
                    break;
                }

                var end = offset + boxSize; // boxSize <= remaining prevents overflow.
                if (type == Ftyp && !awaitingMdat && fragmentCount == 0)
                {
                    hasFtyp = true;
                }
                else if (type == Moov && !awaitingMdat && fragmentCount == 0)
                {
                    hasMoov = true;
                }
                else if (type == Moof)
                {
                    if (!hasFtyp || !hasMoov || awaitingMdat)
                    {
                        break;
                    }
                    awaitingMdat = true;
                }
                else if (type == Mdat && awaitingMdat)
                {
                    if (boxSize == headerBytes)
                    {
                        break;
                    }
                    awaitingMdat = false;
                    lastCompletePrefix = end;
                    fragmentCount++;
                }
                else if (awaitingMdat && !CanAppearBetweenMoofAndMdat(type))
                {
                    break;
                }

                offset = end;
            }

            if (lastCompletePrefix == 0)
            {
                return Failed("No complete ftyp/moov/moof/mdat prefix exists inside the durable region.");
            }

            var reason = offset == limit
                ? null
                : "A torn, oversized, or unsupported tail was excluded from recovery.";
            return new FragmentedMp4PrefixScanResult(true, lastCompletePrefix, fragmentCount, reason);
        }
        catch (IOException error)
        {
            return Failed(error.Message);
        }
        catch (UnauthorizedAccessException error)
        {
            return Failed(error.Message);
        }
        catch (ArgumentException error)
        {
            return Failed(error.Message);
        }
    }

    private static bool CanAppearBetweenMoofAndMdat(uint type) =>
        type is Free or Skip or Sidx or Emsg or Prft or Uuid or Styp;

    private static FragmentedMp4PrefixScanResult Failed(string reason) =>
        new(false, 0, 0, reason);
}

internal sealed class StorageRecoveryMediaValidator(SessionStorageService storage) : IRecoveryMediaValidator
{
    public RecoveryMediaValidationResult ValidateToEnd(string path, RecoveryMediaKind mediaKind)
    {
        var valid = mediaKind == RecoveryMediaKind.AudioVideoMp4
            ? storage.IsSafeCompletedVideo(path)
            : storage.IsSafeCompletedAudio(path);
        return valid
            ? RecoveryMediaValidationResult.Valid
            : RecoveryMediaValidationResult.Invalid("The decoder did not consume a non-empty candidate through end-of-stream.");
    }
}
