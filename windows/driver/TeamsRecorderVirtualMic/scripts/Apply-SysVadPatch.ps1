[CmdletBinding()]
param(
    [string]$SourceDirectory
)

$ErrorActionPreference = "Stop"
$driverRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($SourceDirectory)) {
    $SourceDirectory = Join-Path $driverRoot ".cache\Windows-driver-samples"
}

$source = [IO.Path]::GetFullPath($SourceDirectory)
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $driverRoot ".cache")).TrimEnd('\') + '\'
if (-not $source.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "-SourceDirectory must remain below '$allowedRoot'."
}

& (Join-Path $PSScriptRoot "Bootstrap-SysVad.ps1") -Destination $source
$lock = Get-Content -LiteralPath (Join-Path $driverRoot "sysvad-dependency.lock.json") -Raw | ConvertFrom-Json
$git = (Get-Command git.exe -ErrorAction Stop).Source
$head = (& $git -C $source rev-parse HEAD).Trim()
if ($head -ne $lock.commit) { throw "SysVAD HEAD '$head' does not match the dependency lock." }

$sysvad = Join-Path $source "audio\sysvad"
$adapter = Join-Path $sysvad "adapter.cpp"
if ((Get-Content -LiteralPath $adapter -Raw) -match 'TeamsRecorderVirtualMicControlInitialize') {
    Write-Host "The locked SysVAD checkout already contains the Teams Recorder patch."
    return
}

& $git -C $source diff --quiet -- audio/sysvad
if ($LASTEXITCODE -ne 0) {
    throw "The locked SysVAD checkout has unrelated changes. Use a clean cache before applying this patch."
}

function Set-Utf8Text([string]$Path, [string]$Value) {
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
}

function Replace-Regex([string]$Path, [string]$Pattern, [string]$Replacement, [string]$Description) {
    $text = Get-Content -LiteralPath $Path -Raw
    $updated = [regex]::Replace($text, $Pattern, $Replacement)
    if ($updated -eq $text) { throw "Could not apply SysVAD patch: $Description" }
    Set-Utf8Text $Path $updated
}

$endpoints = Join-Path $sysvad "EndpointsCommon"
Copy-Item -LiteralPath (Join-Path $driverRoot "kernel\TeamsRecorderVirtualMicControl.h") -Destination $endpoints
Copy-Item -LiteralPath (Join-Path $driverRoot "kernel\TeamsRecorderVirtualMicControl.cpp") -Destination $endpoints

$stream = Join-Path $endpoints "minwavertstream.cpp"
Replace-Regex $stream '(#include\s+"minwavertstream\.h"\s*)' (('$1') + "`r`n#include `"TeamsRecorderVirtualMicControl.h`"`r`n") "include the producer ring"
Replace-Regex $stream 'm_ToneGenerator\.GenerateSine\(m_pDmaBuffer \+ bufferOffset, runWrite\);' 'TeamsRecorderVirtualMicFillPcm(m_pDmaBuffer + bufferOffset, runWrite);' "replace the sample sine generator"

$endpointProject = Join-Path $endpoints "EndpointsCommon.vcxproj"
Replace-Regex $endpointProject '(?s)(<ClCompile Include="minwavertstream\.cpp"\s*/>)' (('$1') + "`r`n    <ClCompile Include=`"TeamsRecorderVirtualMicControl.cpp`" />") "compile the control device"

Replace-Regex $adapter '(#include\s+"minipairs\.h"\s*)' (('$1') + "`r`n#include `"TeamsRecorderVirtualMicControl.h`"`r`n") "include control lifetime declarations"
Replace-Regex $adapter '(if \(gPCDriverUnloadRoutine != NULL\)\s*\{\s*gPCDriverUnloadRoutine\(DriverObject\);\s*\})' (('$1') + "`r`n`r`n    // PortCls stops WaveRT/DPC consumers before the nonpaged ring is released.`r`n    TeamsRecorderVirtualMicControlCleanup();") "clean up the producer ring after PortCls"
Replace-Regex $adapter '(DriverObject->MajorFunction\[IRP_MJ_PNP\] = PnpHandler;)' (('$1') + "`r`n`r`n    ntStatus = TeamsRecorderVirtualMicControlInitialize(DriverObject);`r`n    IF_FAILED_ACTION_JUMP(`r`n        ntStatus,`r`n        DPF(D_ERROR, (`"Virtual microphone control initialization failed, 0x%x`", ntStatus)),`r`n        Done);") "initialize the producer boundary"
Replace-Regex $adapter '(Done:\s*\r?\n\s*if \(!NT_SUCCESS\(ntStatus\)\)\s*\{)' (('$1') + "`r`n        TeamsRecorderVirtualMicControlCleanup();") "clean up a failed DriverEntry initialization"

$miniPairs = Join-Path $sysvad "TabletAudioSample\minipairs.h"
$endpointBlock = @'
static PENDPOINT_MINIPAIR g_RenderEndpoints[] = { nullptr };
#define g_cRenderEndpoints 0

// The preview exposes exactly one capture-only endpoint.
static PENDPOINT_MINIPAIR g_CaptureEndpoints[] =
{
    &MicInMiniports,
};
#define g_cCaptureEndpoints (SIZEOF_ARRAY(g_CaptureEndpoints))
'@
Replace-Regex $miniPairs '(?s)static\s+PENDPOINT_MINIPAIR\s+g_RenderEndpoints\[\].*?#define g_cCaptureEndpoints\s+\(SIZEOF_ARRAY\(g_CaptureEndpoints\)\)' $endpointBlock "restrict the endpoint set"

$micTable = Join-Path $sysvad "TabletAudioSample\micinwavtable.h"
Replace-Regex $micTable '#define MICIN_DEVICE_MAX_CHANNELS\s+1' '#define MICIN_DEVICE_MAX_CHANNELS           2' "set stereo capture"
Replace-Regex $micTable '#define MICIN_MIN_SAMPLE_RATE\s+8000' '#define MICIN_MIN_SAMPLE_RATE               48000' "set the minimum rate"
$formatBlock = @'
static
KSDATAFORMAT_WAVEFORMATEXTENSIBLE MicInPinSupportedDeviceFormats[] =
{
    {
        {
            sizeof(KSDATAFORMAT_WAVEFORMATEXTENSIBLE), 0, 0, 0,
            STATICGUIDOF(KSDATAFORMAT_TYPE_AUDIO),
            STATICGUIDOF(KSDATAFORMAT_SUBTYPE_PCM),
            STATICGUIDOF(KSDATAFORMAT_SPECIFIER_WAVEFORMATEX)
        },
        {
            {
                WAVE_FORMAT_EXTENSIBLE, 2, 48000, 192000, 4, 16,
                sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)
            },
            16,
            KSAUDIO_SPEAKER_STEREO,
            STATICGUIDOF(KSDATAFORMAT_SUBTYPE_PCM)
        }
    }
};

// Supported modes (only on streaming pins).
'@
Replace-Regex $micTable '(?s)static\s+KSDATAFORMAT_WAVEFORMATEXTENSIBLE MicInPinSupportedDeviceFormats\[\].*?// Supported modes \(only on streaming pins\)\.\s*//' $formatBlock "restrict capture to PCM16 48 kHz stereo"
$modeBlock = @'
static
MODE_AND_DEFAULT_FORMAT MicInPinSupportedDeviceModes[] =
{
    { STATIC_AUDIO_SIGNALPROCESSINGMODE_RAW, &MicInPinSupportedDeviceFormats[0].DataFormat },
    { STATIC_AUDIO_SIGNALPROCESSINGMODE_DEFAULT, &MicInPinSupportedDeviceFormats[0].DataFormat },
};
'@
Replace-Regex $micTable '(?s)static\s+MODE_AND_DEFAULT_FORMAT MicInPinSupportedDeviceModes\[\].*?\};' $modeBlock "restrict signal processing modes"

$driverProject = Join-Path $sysvad "TabletAudioSample\TabletAudioSample.vcxproj"
Replace-Regex $driverProject '<TargetName>TabletAudioSample</TargetName>' '<TargetName>TeamsRecorderVirtualMic</TargetName>' "name the driver binary"
Replace-Regex $driverProject '\$\(DDK_LIB_PATH\)\\portcls\.lib;' '$(DDK_LIB_PATH)\portcls.lib;$(DDK_LIB_PATH)\wdmsec.lib;' "link IoCreateDeviceSecure"

$inx = Join-Path $sysvad "TabletAudioSample\ComponentizedAudioSample.inx"
Replace-Regex $inx 'CatalogFile\s*=\s*sysvad\.cat' 'CatalogFile = TeamsRecorderVirtualMic.cat' "name the catalog"
Replace-Regex $inx '(?im)^keywordDetectorContosoAdapter\.dll=222\s*\r?\n' '' "remove the keyword adapter disk entry"
Replace-Regex $inx '(?im)^keyworddetectorcontosoadapter\.dll=SignatureAttributes\.PETrust\s*\r?\n' '' "remove the keyword adapter signature entry"
Replace-Regex $inx 'tabletaudiosample\.sys' 'TeamsRecorderVirtualMic.sys' "name the packaged driver"
Replace-Regex $inx 'Root\\sysvad_ComponentizedAudioSample' 'ROOT\TeamsRecorderVirtualMic' "set the exact hardware ID"
Replace-Regex $inx 'CopyFiles=SYSVAD_SA\.CopyList,KEYWORDDETECTORCONTOSOADAPTER\.CopyList' 'CopyFiles=SYSVAD_SA.CopyList' "package only the driver"
Replace-Regex $inx 'AddReg=SYSVAD_SA\.AddReg,KEYWORDDETECTORCONTOSOADAPTER\.AddReg' 'AddReg=SYSVAD_SA.AddReg' "remove the keyword adapter registration"
$interfaces = @'
[SYSVAD_SA.NT.Interfaces]
AddInterface=%KSCATEGORY_AUDIO%,    %KSNAME_WaveMicIn%, SYSVAD.I.WaveMicIn
AddInterface=%KSCATEGORY_REALTIME%, %KSNAME_WaveMicIn%, SYSVAD.I.WaveMicIn
AddInterface=%KSCATEGORY_CAPTURE%,  %KSNAME_WaveMicIn%, SYSVAD.I.WaveMicIn
AddInterface=%KSCATEGORY_AUDIO%,    %KSNAME_TopologyMicIn%, SYSVAD.I.TopologyMicIn
AddInterface=%KSCATEGORY_TOPOLOGY%, %KSNAME_TopologyMicIn%, SYSVAD.I.TopologyMicIn

[SYSVAD_SA.NT.Services]
'@
Replace-Regex $inx '(?s)\[SYSVAD_SA\.NT\.Interfaces\].*?\[SYSVAD_SA\.NT\.Services\]' $interfaces "publish only microphone interfaces"
Replace-Regex $inx 'AddService=sysvad_componentizedaudiosample,0x00000002,sysvad_ComponentizedAudioSample_Service_Inst' 'AddService=TeamsRecorderVirtualMic,0x00000002,TeamsRecorderVirtualMic_Service_Inst' "set the service name"
Replace-Regex $inx '\[sysvad_ComponentizedAudioSample_Service_Inst\]' '[TeamsRecorderVirtualMic_Service_Inst]' "rename the service section"
Replace-Regex $inx 'SYSVAD_SA\.DeviceDesc="[^"]+"' 'SYSVAD_SA.DeviceDesc="Teams Recorder Virtual Microphone"' "set the device name"
Replace-Regex $inx 'SYSVAD\.WaveMicIn\.szPname="[^"]+"' 'SYSVAD.WaveMicIn.szPname="Teams Recorder Virtual Microphone"' "set the wave name"
Replace-Regex $inx 'SYSVAD\.TopologyMicIn\.szPname="[^"]+"' 'SYSVAD.TopologyMicIn.szPname="Teams Recorder Virtual Microphone Topology"' "set the topology name"
Replace-Regex $inx 'MicInCustomName=\s*"[^"]+"' 'MicInCustomName="Teams Recorder Virtual Microphone"' "set the Core Audio friendly name"

Write-Host "Applied the Teams Recorder virtual-microphone patch to locked SysVAD source: $source"
Write-Host "Review 'git -C $source diff -- audio/sysvad' before building."
