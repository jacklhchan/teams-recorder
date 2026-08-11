[CmdletBinding()]
param(
    [ValidateSet("Debug")]
    [string]$Configuration = "Debug",
    [ValidateSet("x64")]
    [string]$Platform = "x64"
)

$ErrorActionPreference = "Stop"
$driverRoot = Split-Path -Parent $PSScriptRoot
$preflight = & (Join-Path $PSScriptRoot "Test-DriverPreflight.ps1")
& (Join-Path $PSScriptRoot "Apply-SysVadPatch.ps1")

$source = Join-Path $driverRoot ".cache\Windows-driver-samples\audio\sysvad"
$project = Join-Path $source "TabletAudioSample\TabletAudioSample.vcxproj"
& $preflight.MsBuildPath $project /m /t:Build "/p:Configuration=$Configuration" "/p:Platform=$Platform"
if ($LASTEXITCODE -ne 0) { throw "The constrained SysVAD driver build failed." }

$driver = @(Get-ChildItem -LiteralPath $source -Recurse -Filter "TeamsRecorderVirtualMic.sys" -File |
    Where-Object { $_.FullName -match "\\$Platform\\$Configuration\\" } |
    Sort-Object LastWriteTimeUtc -Descending)[0]
$inf = @(Get-ChildItem -LiteralPath $source -Recurse -Filter "ComponentizedAudioSample.inf" -File |
    Where-Object { $_.FullName -match "\\$Platform\\$Configuration\\" } |
    Sort-Object LastWriteTimeUtc -Descending)[0]
if ($null -eq $driver -or $null -eq $inf) {
    throw "MSBuild completed without the expected constrained SYS/INF outputs."
}

$package = Join-Path $driverRoot "out\package"
New-Item -ItemType Directory -Path $package -Force | Out-Null
Copy-Item -LiteralPath $driver.FullName -Destination (Join-Path $package "TeamsRecorderVirtualMic.sys") -Force
Copy-Item -LiteralPath $inf.FullName -Destination (Join-Path $package "TeamsRecorderVirtualMic.inf") -Force

$infText = Get-Content -LiteralPath (Join-Path $package "TeamsRecorderVirtualMic.inf") -Raw
foreach ($required in @("ROOT\TeamsRecorderVirtualMic", "TeamsRecorderVirtualMic.sys", "CatalogFile = TeamsRecorderVirtualMic.cat")) {
    if ($infText -notmatch [regex]::Escape($required)) { throw "Built INF is missing '$required'." }
}
Write-Host "Unsigned Debug preview package is ready at $package"
Write-Host "Run Sign-DriverPackage.ps1 with the dedicated test PFX before installing it on a disposable test machine."
