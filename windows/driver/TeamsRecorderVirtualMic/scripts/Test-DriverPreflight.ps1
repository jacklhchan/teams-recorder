[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function Find-FirstFile {
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Candidates = @(),
        [Parameter(Mandatory)][string]$Name
    )

    foreach ($candidate in $Candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

$programFilesX86 = ${env:ProgramFiles(x86)}
if ([string]::IsNullOrWhiteSpace($programFilesX86)) {
    throw "ProgramFiles(x86) is unavailable; cannot locate the Windows Driver Kit (WDK)."
}

$kitRoot = Join-Path $programFilesX86 "Windows Kits\10"
$wdkTargets = Find-FirstFile -Candidates @(
    (Join-Path $kitRoot "build\WindowsDriver.common.targets"),
    (Join-Path $kitRoot "build\10.0.26100.0\WindowsDriver.common.targets")
) -Name "WindowsDriver.common.targets"

if (-not $wdkTargets) {
    throw @"
Windows Driver Kit (WDK) is required to build the Teams Recorder Virtual Microphone preview.
Windows SDK files alone are insufficient: WindowsDriver.common.targets was not found below '$kitRoot'.
Install a WDK version that matches the installed Windows SDK and Visual Studio C++ build tools, then rerun this preflight.
"@
}

$signTool = Find-FirstFile -Candidates @(
    (Get-Command signtool.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
    (Join-Path $kitRoot "bin\10.0.26100.0\x64\signtool.exe"),
    (Join-Path $kitRoot "bin\x64\signtool.exe")
) -Name "signtool.exe"
$inf2Cat = Find-FirstFile -Candidates @(
    (Get-Command inf2cat.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
    (Join-Path $kitRoot "bin\10.0.26100.0\x64\inf2cat.exe"),
    (Join-Path $kitRoot "bin\x64\inf2cat.exe")
) -Name "inf2cat.exe"
$devCon = Find-FirstFile -Candidates @(
    (Get-Command devcon.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
    (Join-Path $kitRoot "Tools\x64\devcon.exe"),
    (Join-Path $kitRoot "Tools\10.0.26100.0\x64\devcon.exe")
) -Name "devcon.exe"

if (-not $signTool -or -not $inf2Cat -or -not $devCon) {
    $missing = @()
    if (-not $signTool) { $missing += "signtool.exe" }
    if (-not $inf2Cat) { $missing += "inf2cat.exe" }
    if (-not $devCon) { $missing += "devcon.exe" }
    throw "The installed WDK is incomplete for this preview. Missing: $($missing -join ', ')."
}

$msBuild = Get-Command msbuild.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue
if (-not $msBuild) {
    throw "Visual Studio MSBuild is required to build the pinned SysVAD solution. Install Visual Studio C++ build tools and rerun this preflight."
}

[PSCustomObject]@{
    WdkTargetsPath = $wdkTargets
    SignToolPath = $signTool
    Inf2CatPath = $inf2Cat
    DevConPath = $devCon
    MsBuildPath = $msBuild
}
