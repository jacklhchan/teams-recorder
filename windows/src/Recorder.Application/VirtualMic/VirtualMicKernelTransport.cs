using System.Buffers.Binary;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace TeamsRecorder.Windows.Application.VirtualMic;

public interface IVirtualMicKernelTransport : IDisposable
{
    void Write(ulong sequence, ReadOnlySpan<byte> pcm16LeStereo);
}

/// <summary>
/// The broker's sole kernel boundary. The fixed control device accepts only a
/// bounded METHOD_BUFFERED packet; the recorder process never opens it.
/// </summary>
public sealed partial class VirtualMicKernelTransport : IVirtualMicKernelTransport
{
    public const string DevicePath = @"\\.\TeamsRecorderVirtualMicControl";
    public const uint WritePcmIoControlCode = 0x0022A000;
    private const uint GenericWrite = 0x40000000;
    private const uint ShareRead = 0x00000001;
    private const uint ShareWrite = 0x00000002;
    private const uint OpenExisting = 3;
    private const uint PacketMagic = 0x4B565254; // "TRVK" little endian.
    private const ushort PacketVersion = 1;
    private const int HeaderBytes = 16;
    private readonly SafeFileHandle handle;

    public VirtualMicKernelTransport()
    {
        if (!OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException("The virtual microphone kernel transport requires Windows.");
        handle = CreateFile(DevicePath, GenericWrite, ShareRead | ShareWrite,
            IntPtr.Zero, OpenExisting, 0, IntPtr.Zero);
        if (handle.IsInvalid)
            throw new Win32Exception(Marshal.GetLastPInvokeError(),
                "Opening the Teams Recorder virtual microphone control device failed.");
    }

    public void Write(ulong sequence, ReadOnlySpan<byte> pcm16LeStereo)
    {
        if (sequence == 0 || pcm16LeStereo.IsEmpty ||
            pcm16LeStereo.Length > VirtualMicPcmProtocol.MaximumPcmPayloadBytes ||
            pcm16LeStereo.Length % VirtualMicPcmProtocol.BlockAlign != 0)
            throw new ArgumentOutOfRangeException(nameof(pcm16LeStereo));

        var packet = new byte[HeaderBytes + pcm16LeStereo.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(packet, PacketMagic);
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(4), PacketVersion);
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(6), HeaderBytes);
        BinaryPrimitives.WriteUInt64LittleEndian(packet.AsSpan(8), sequence);
        pcm16LeStereo.CopyTo(packet.AsSpan(HeaderBytes));
        if (!DeviceIoControl(handle, WritePcmIoControlCode, packet,
                checked((uint)packet.Length), IntPtr.Zero, 0, out _, IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastPInvokeError(),
                "The virtual microphone driver rejected a PCM frame.");
    }

    public void Dispose() => handle.Dispose();

    [LibraryImport("kernel32.dll", EntryPoint = "CreateFileW", SetLastError = true,
        StringMarshalling = StringMarshalling.Utf16)]
    private static partial SafeFileHandle CreateFile(
        string fileName, uint desiredAccess, uint shareMode, IntPtr securityAttributes,
        uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DeviceIoControl(
        SafeFileHandle device, uint ioControlCode, byte[] inputBuffer,
        uint inputBufferSize, IntPtr outputBuffer, uint outputBufferSize,
        out uint bytesReturned, IntPtr overlapped);
}

public sealed class VirtualMicKernelPcmSink(IVirtualMicKernelTransport transport) :
    IVirtualMicPcmSink, IDisposable
{
    private readonly IVirtualMicKernelTransport transport = transport ??
        throw new ArgumentNullException(nameof(transport));

    public Task WriteAsync(VirtualMicPcmFrame frame, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        transport.Write(frame.Sequence, frame.Pcm16LeStereo.Span);
        return Task.CompletedTask;
    }

    public void Dispose() => transport.Dispose();
}
