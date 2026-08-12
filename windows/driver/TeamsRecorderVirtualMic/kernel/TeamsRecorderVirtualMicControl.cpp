#include "TeamsRecorderVirtualMicControl.h"
#include <wdmsec.h>

namespace {

constexpr ULONG kPoolTag = 'mVRT';
constexpr ULONG kCapacityBytes = 48'000U * 2U * sizeof(INT16) * 2U;
constexpr ULONG kMaximumPcmBytes = 19'200U;
constexpr ULONG kBlockAlign = 4U;
constexpr ULONG kPacketMagic = 0x4B565254U; // "TRVK" little endian.
constexpr USHORT kPacketVersion = 1U;

struct PcmPacketHeader {
    ULONG Magic;
    USHORT Version;
    USHORT HeaderBytes;
    ULONGLONG Sequence;
};

static_assert(sizeof(PcmPacketHeader) == 16U);

PDEVICE_OBJECT g_ControlDevice = nullptr;
UNICODE_STRING g_SymbolicLink{};
KSPIN_LOCK g_RingLock{};
PUCHAR g_Ring = nullptr;
ULONG g_ReadOffset = 0;
ULONG g_WriteOffset = 0;
ULONG g_UsedBytes = 0;
ULONGLONG g_LastSequence = 0;
volatile LONG g_ProducerOpen = 0;
PDRIVER_DISPATCH g_PreviousCreate = nullptr;
PDRIVER_DISPATCH g_PreviousClose = nullptr;
PDRIVER_DISPATCH g_PreviousDeviceControl = nullptr;

VOID ResetRingLocked() {
    g_ReadOffset = 0;
    g_WriteOffset = 0;
    g_UsedBytes = 0;
    g_LastSequence = 0;
    if (g_Ring != nullptr) RtlZeroMemory(g_Ring, kCapacityBytes);
}

VOID CopyIntoRingLocked(_In_reads_bytes_(count) const UCHAR* source, ULONG count) {
    ULONG remaining = count;
    while (remaining > 0) {
        const ULONG run = min(remaining, kCapacityBytes - g_WriteOffset);
        RtlCopyMemory(g_Ring + g_WriteOffset, source + (count - remaining), run);
        g_WriteOffset = (g_WriteOffset + run) % kCapacityBytes;
        g_UsedBytes += run;
        remaining -= run;
    }
}

VOID CopyFromRingLocked(_Out_writes_bytes_(count) UCHAR* destination, ULONG count) {
    ULONG remaining = count;
    while (remaining > 0) {
        const ULONG run = min(remaining, kCapacityBytes - g_ReadOffset);
        RtlCopyMemory(destination + (count - remaining), g_Ring + g_ReadOffset, run);
        g_ReadOffset = (g_ReadOffset + run) % kCapacityBytes;
        g_UsedBytes -= run;
        remaining -= run;
    }
}

NTSTATUS CompleteIrp(_Inout_ PIRP irp, NTSTATUS status, ULONG_PTR information = 0) {
    irp->IoStatus.Status = status;
    irp->IoStatus.Information = information;
    IoCompleteRequest(irp, IO_NO_INCREMENT);
    return status;
}

NTSTATUS DispatchCreate(_In_ PDEVICE_OBJECT device, _Inout_ PIRP irp) {
    if (device != g_ControlDevice) return g_PreviousCreate(device, irp);
    if (InterlockedCompareExchange(&g_ProducerOpen, 1, 0) != 0)
        return CompleteIrp(irp, STATUS_DEVICE_BUSY);
    KIRQL oldIrql;
    KeAcquireSpinLock(&g_RingLock, &oldIrql);
    ResetRingLocked();
    KeReleaseSpinLock(&g_RingLock, oldIrql);
    return CompleteIrp(irp, STATUS_SUCCESS);
}

NTSTATUS DispatchClose(_In_ PDEVICE_OBJECT device, _Inout_ PIRP irp) {
    if (device != g_ControlDevice) return g_PreviousClose(device, irp);
    KIRQL oldIrql;
    KeAcquireSpinLock(&g_RingLock, &oldIrql);
    ResetRingLocked();
    KeReleaseSpinLock(&g_RingLock, oldIrql);
    InterlockedExchange(&g_ProducerOpen, 0);
    return CompleteIrp(irp, STATUS_SUCCESS);
}

NTSTATUS DispatchDeviceControl(_In_ PDEVICE_OBJECT device, _Inout_ PIRP irp) {
    if (device != g_ControlDevice) return g_PreviousDeviceControl(device, irp);
    const auto stack = IoGetCurrentIrpStackLocation(irp);
    if (stack->Parameters.DeviceIoControl.IoControlCode !=
            TEAMS_RECORDER_VIRTUAL_MIC_IOCTL_WRITE_PCM ||
        KeGetCurrentIrql() != PASSIVE_LEVEL)
        return CompleteIrp(irp, STATUS_INVALID_DEVICE_REQUEST);

    const ULONG inputBytes = stack->Parameters.DeviceIoControl.InputBufferLength;
    if (irp->AssociatedIrp.SystemBuffer == nullptr ||
        inputBytes < sizeof(PcmPacketHeader) + kBlockAlign ||
        inputBytes > sizeof(PcmPacketHeader) + kMaximumPcmBytes)
        return CompleteIrp(irp, STATUS_INVALID_BUFFER_SIZE);

    const auto header = static_cast<const PcmPacketHeader*>(irp->AssociatedIrp.SystemBuffer);
    const ULONG pcmBytes = inputBytes - sizeof(PcmPacketHeader);
    if (header->Magic != kPacketMagic || header->Version != kPacketVersion ||
        header->HeaderBytes != sizeof(PcmPacketHeader) || header->Sequence == 0 ||
        pcmBytes % kBlockAlign != 0)
        return CompleteIrp(irp, STATUS_INVALID_PARAMETER);

    KIRQL oldIrql;
    KeAcquireSpinLock(&g_RingLock, &oldIrql);
    if (header->Sequence != g_LastSequence + 1U) {
        KeReleaseSpinLock(&g_RingLock, oldIrql);
        return CompleteIrp(irp, STATUS_REQUEST_OUT_OF_SEQUENCE);
    }
    if (pcmBytes > kCapacityBytes - g_UsedBytes) {
        ULONG discard = pcmBytes - (kCapacityBytes - g_UsedBytes);
        discard = (discard + kBlockAlign - 1U) / kBlockAlign * kBlockAlign;
        g_ReadOffset = (g_ReadOffset + discard) % kCapacityBytes;
        g_UsedBytes -= discard;
    }
    const auto pcm = reinterpret_cast<const UCHAR*>(header + 1);
    CopyIntoRingLocked(pcm, pcmBytes);
    g_LastSequence = header->Sequence;
    KeReleaseSpinLock(&g_RingLock, oldIrql);
    return CompleteIrp(irp, STATUS_SUCCESS, inputBytes);
}

} // namespace

extern "C" NTSTATUS TeamsRecorderVirtualMicControlInitialize(
    _In_ PDRIVER_OBJECT driverObject) {
    if (driverObject == nullptr || g_ControlDevice != nullptr) return STATUS_INVALID_PARAMETER;
    KeInitializeSpinLock(&g_RingLock);
    g_Ring = static_cast<PUCHAR>(ExAllocatePool2(
        POOL_FLAG_NON_PAGED, kCapacityBytes, kPoolTag));
    if (g_Ring == nullptr) return STATUS_INSUFFICIENT_RESOURCES;
    RtlZeroMemory(g_Ring, kCapacityBytes);

    UNICODE_STRING deviceName;
    RtlInitUnicodeString(&deviceName, L"\\Device\\TeamsRecorderVirtualMicControl");
    RtlInitUnicodeString(&g_SymbolicLink, L"\\DosDevices\\TeamsRecorderVirtualMicControl");
    UNICODE_STRING sddl;
    RtlInitUnicodeString(&sddl,
        L"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;IU)");
    static const GUID controlClass =
        {0xd7233c79, 0xe5a1, 0x4e25, {0x9d, 0x88, 0x55, 0x64, 0x51, 0x0e, 0x8d, 0x77}};
    NTSTATUS status = IoCreateDeviceSecure(
        driverObject, 0, &deviceName, FILE_DEVICE_UNKNOWN,
        FILE_DEVICE_SECURE_OPEN, FALSE,
        &sddl, &controlClass, &g_ControlDevice);
    if (!NT_SUCCESS(status)) {
        ExFreePoolWithTag(g_Ring, kPoolTag);
        g_Ring = nullptr;
        return status;
    }
    status = IoCreateSymbolicLink(&g_SymbolicLink, &deviceName);
    if (!NT_SUCCESS(status)) {
        IoDeleteDevice(g_ControlDevice);
        g_ControlDevice = nullptr;
        ExFreePoolWithTag(g_Ring, kPoolTag);
        g_Ring = nullptr;
        return status;
    }

    g_PreviousCreate = driverObject->MajorFunction[IRP_MJ_CREATE];
    g_PreviousClose = driverObject->MajorFunction[IRP_MJ_CLOSE];
    g_PreviousDeviceControl = driverObject->MajorFunction[IRP_MJ_DEVICE_CONTROL];
    driverObject->MajorFunction[IRP_MJ_CREATE] = DispatchCreate;
    driverObject->MajorFunction[IRP_MJ_CLOSE] = DispatchClose;
    driverObject->MajorFunction[IRP_MJ_DEVICE_CONTROL] = DispatchDeviceControl;
    g_ControlDevice->Flags &= ~DO_DEVICE_INITIALIZING;
    return STATUS_SUCCESS;
}

extern "C" VOID TeamsRecorderVirtualMicControlCleanup() {
    if (g_ControlDevice != nullptr) {
        IoDeleteSymbolicLink(&g_SymbolicLink);
        IoDeleteDevice(g_ControlDevice);
        g_ControlDevice = nullptr;
    }
    if (g_Ring != nullptr) {
        ExFreePoolWithTag(g_Ring, kPoolTag);
        g_Ring = nullptr;
    }
}

extern "C" VOID TeamsRecorderVirtualMicFillPcm(
    _Out_writes_bytes_(byteCount) PUCHAR destination,
    _In_ ULONG byteCount) {
    if (destination == nullptr || byteCount == 0) return;
    RtlZeroMemory(destination, byteCount);
    if (g_Ring == nullptr) return;
    KIRQL oldIrql;
    KeAcquireSpinLock(&g_RingLock, &oldIrql);
    const ULONG available = min(byteCount, g_UsedBytes);
    if (available > 0) CopyFromRingLocked(destination, available);
    KeReleaseSpinLock(&g_RingLock, oldIrql);
}
