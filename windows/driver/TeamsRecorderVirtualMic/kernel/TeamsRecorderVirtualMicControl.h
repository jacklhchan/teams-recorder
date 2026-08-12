#pragma once

#include <ntddk.h>

#define TEAMS_RECORDER_VIRTUAL_MIC_IOCTL_WRITE_PCM \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_WRITE_DATA)

extern "C" NTSTATUS TeamsRecorderVirtualMicControlInitialize(
    _In_ PDRIVER_OBJECT DriverObject);
extern "C" VOID TeamsRecorderVirtualMicControlCleanup();

// DISPATCH_LEVEL-safe consumer used by the WaveRT capture stream. Missing
// producer bytes are always replaced with silence.
extern "C" VOID TeamsRecorderVirtualMicFillPcm(
    _Out_writes_bytes_(ByteCount) PUCHAR Destination,
    _In_ ULONG ByteCount);
