using System.Buffers.Binary;

namespace TeamsRecorder.Windows.Application.VirtualMic;

/// <summary>
/// Strict binary protocol between the recorder application and the test-only
/// user-mode virtual-mic broker. It deliberately has no JSON, paths,
/// credentials, endpoint IDs, or arbitrary metadata fields.
/// </summary>
public static class VirtualMicPcmProtocol
{
    // Little-endian bytes spell "TRVM".
    public const uint Magic = 0x4D565254;
    public const ushort CurrentVersion = 1;
    public const int HeaderBytes = 12;
    public const int CapabilityTokenBytes = 32;
    public const int SampleRate = 48_000;
    public const int Channels = 2;
    public const int BitsPerSample = 16;
    public const int BlockAlign = Channels * (BitsPerSample / 8);
    public const int MaximumFrameDurationMilliseconds = 100;
    public const int MaximumPcmPayloadBytes = SampleRate * BlockAlign * MaximumFrameDurationMilliseconds / 1_000;
    public const int MaximumPayloadBytes = 24 * 1_024;

    public static byte[] CreateHello(ReadOnlySpan<byte> capabilityToken)
    {
        if (capabilityToken.Length != CapabilityTokenBytes)
        {
            throw new ArgumentException($"A virtual microphone capability token must be {CapabilityTokenBytes} bytes.", nameof(capabilityToken));
        }

        return Create(VirtualMicPcmMessageKind.Hello, capabilityToken);
    }

    public static byte[] CreateAcknowledgement() => Create(VirtualMicPcmMessageKind.Acknowledgement, []);

    public static byte[] CreateStop() => Create(VirtualMicPcmMessageKind.Stop, []);

    public static byte[] CreatePcm(ulong sequence, ReadOnlySpan<byte> pcm16LeStereo)
    {
        ValidatePcmBytes(pcm16LeStereo, nameof(pcm16LeStereo));
        var payload = new byte[sizeof(ulong) + pcm16LeStereo.Length];
        BinaryPrimitives.WriteUInt64LittleEndian(payload, sequence);
        pcm16LeStereo.CopyTo(payload.AsSpan(sizeof(ulong)));
        return Create(VirtualMicPcmMessageKind.Pcm, payload);
    }

    public static VirtualMicPcmMessage Deserialize(ReadOnlySpan<byte> frame)
    {
        if (frame.Length < HeaderBytes)
        {
            throw new VirtualMicPcmProtocolException(VirtualMicPcmProtocolError.MalformedFrame);
        }

        var kind = ParseHeader(frame[..HeaderBytes], out var payloadLength);
        if (payloadLength != frame.Length - HeaderBytes)
        {
            throw new VirtualMicPcmProtocolException(VirtualMicPcmProtocolError.MalformedFrame);
        }

        var payload = frame[HeaderBytes..].ToArray();
        ValidatePayload(kind, payload);
        return new VirtualMicPcmMessage(kind, payload);
    }

    public static async Task<VirtualMicPcmMessage> ReadAsync(Stream stream, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(stream);
        var header = new byte[HeaderBytes];
        await ReadExactlyAsync(stream, header, cancellationToken).ConfigureAwait(false);
        var kind = ParseHeader(header, out var payloadLength);
        var payload = new byte[payloadLength];
        await ReadExactlyAsync(stream, payload, cancellationToken).ConfigureAwait(false);
        ValidatePayload(kind, payload);
        return new VirtualMicPcmMessage(kind, payload);
    }

    public static async Task WriteAsync(Stream stream, ReadOnlyMemory<byte> frame, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(stream);
        // Parse before writing so locally generated malformed traffic never
        // becomes an input to the broker.
        _ = Deserialize(frame.Span);
        await stream.WriteAsync(frame, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    public static VirtualMicPcmFrame ParsePcm(VirtualMicPcmMessage message)
    {
        ArgumentNullException.ThrowIfNull(message);
        if (message.Kind != VirtualMicPcmMessageKind.Pcm)
        {
            throw new VirtualMicPcmProtocolException(VirtualMicPcmProtocolError.UnexpectedMessage);
        }

        ValidatePayload(message.Kind, message.Payload.Span);
        var sequence = BinaryPrimitives.ReadUInt64LittleEndian(message.Payload.Span);
        return new VirtualMicPcmFrame(sequence, message.Payload[sizeof(ulong)..].ToArray());
    }

    private static byte[] Create(VirtualMicPcmMessageKind kind, ReadOnlySpan<byte> payload)
    {
        ValidatePayload(kind, payload);
        var frame = new byte[HeaderBytes + payload.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(frame, Magic);
        BinaryPrimitives.WriteUInt16LittleEndian(frame.AsSpan(sizeof(uint)), CurrentVersion);
        BinaryPrimitives.WriteUInt16LittleEndian(frame.AsSpan(sizeof(uint) + sizeof(ushort)), (ushort)kind);
        BinaryPrimitives.WriteUInt32LittleEndian(frame.AsSpan(sizeof(uint) + sizeof(ushort) + sizeof(ushort)), checked((uint)payload.Length));
        payload.CopyTo(frame.AsSpan(HeaderBytes));
        return frame;
    }

    private static VirtualMicPcmMessageKind ParseHeader(ReadOnlySpan<byte> header, out int payloadLength)
    {
        if (BinaryPrimitives.ReadUInt32LittleEndian(header) != Magic)
        {
            throw new VirtualMicPcmProtocolException(VirtualMicPcmProtocolError.MalformedFrame);
        }

        if (BinaryPrimitives.ReadUInt16LittleEndian(header[sizeof(uint)..]) != CurrentVersion)
        {
            throw new VirtualMicPcmProtocolException(VirtualMicPcmProtocolError.UnsupportedVersion);
        }

        var kindValue = BinaryPrimitives.ReadUInt16LittleEndian(header[(sizeof(uint) + sizeof(ushort))..]);
        if (!Enum.IsDefined((VirtualMicPcmMessageKind)kindValue))
        {
            throw new VirtualMicPcmProtocolException(VirtualMicPcmProtocolError.UnexpectedMessage);
        }

        var declaredPayload = BinaryPrimitives.ReadUInt32LittleEndian(header[(sizeof(uint) + sizeof(ushort) + sizeof(ushort))..]);
        if (declaredPayload > MaximumPayloadBytes)
        {
            throw new VirtualMicPcmProtocolException(VirtualMicPcmProtocolError.OversizedFrame);
        }

        payloadLength = checked((int)declaredPayload);
        return (VirtualMicPcmMessageKind)kindValue;
    }

    private static void ValidatePayload(VirtualMicPcmMessageKind kind, ReadOnlySpan<byte> payload)
    {
        if (payload.Length > MaximumPayloadBytes)
        {
            throw new VirtualMicPcmProtocolException(VirtualMicPcmProtocolError.OversizedFrame);
        }

        switch (kind)
        {
            case VirtualMicPcmMessageKind.Hello when payload.Length == CapabilityTokenBytes:
            case VirtualMicPcmMessageKind.Acknowledgement when payload.IsEmpty:
            case VirtualMicPcmMessageKind.Stop when payload.IsEmpty:
                return;
            case VirtualMicPcmMessageKind.Pcm:
                if (payload.Length < sizeof(ulong) + BlockAlign || payload.Length > sizeof(ulong) + MaximumPcmPayloadBytes)
                {
                    throw new VirtualMicPcmProtocolException(VirtualMicPcmProtocolError.MalformedFrame);
                }

                if ((payload.Length - sizeof(ulong)) % BlockAlign != 0)
                {
                    throw new VirtualMicPcmProtocolException(VirtualMicPcmProtocolError.MalformedFrame);
                }
                return;
            default:
                throw new VirtualMicPcmProtocolException(VirtualMicPcmProtocolError.MalformedFrame);
        }
    }

    private static void ValidatePcmBytes(ReadOnlySpan<byte> pcm16LeStereo, string parameterName)
    {
        if (pcm16LeStereo.Length < BlockAlign || pcm16LeStereo.Length > MaximumPcmPayloadBytes ||
            pcm16LeStereo.Length % BlockAlign != 0)
        {
            throw new ArgumentOutOfRangeException(
                parameterName,
                $"PCM must contain 1-{MaximumFrameDurationMilliseconds} ms of {SampleRate} Hz stereo 16-bit samples.");
        }
    }

    private static async Task ReadExactlyAsync(Stream stream, Memory<byte> destination, CancellationToken cancellationToken)
    {
        var read = 0;
        while (read < destination.Length)
        {
            var count = await stream.ReadAsync(destination[read..], cancellationToken).ConfigureAwait(false);
            if (count == 0)
            {
                throw new IOException("The virtual microphone pipe closed before a complete frame arrived.");
            }

            read += count;
        }
    }
}

public enum VirtualMicPcmMessageKind : ushort
{
    Hello = 1,
    Acknowledgement = 2,
    Pcm = 3,
    Stop = 4,
}

public sealed class VirtualMicPcmMessage
{
    internal VirtualMicPcmMessage(VirtualMicPcmMessageKind kind, ReadOnlyMemory<byte> payload)
    {
        Kind = kind;
        Payload = payload;
    }

    public VirtualMicPcmMessageKind Kind { get; }
    public ReadOnlyMemory<byte> Payload { get; }
}

public sealed record VirtualMicPcmFrame(ulong Sequence, ReadOnlyMemory<byte> Pcm16LeStereo);

public enum VirtualMicPcmProtocolError
{
    MalformedFrame,
    OversizedFrame,
    UnsupportedVersion,
    UnexpectedMessage,
}

public sealed class VirtualMicPcmProtocolException : Exception
{
    public VirtualMicPcmProtocolException(VirtualMicPcmProtocolError error)
        : base("Virtual microphone PCM protocol rejected the frame.")
    {
        Error = error;
    }

    public VirtualMicPcmProtocolError Error { get; }
}
