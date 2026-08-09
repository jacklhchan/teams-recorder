[CmdletBinding()]
param(
    [string]$Destination
)

$ErrorActionPreference = "Stop"
$driverRoot = Split-Path -Parent $PSScriptRoot
$lockPath = Join-Path $driverRoot "sysvad-dependency.lock.json"
$lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json

if ($lock.commit -notmatch "^[0-9a-f]{40}$" -or
    $lock.repository -ne "https://github.com/microsoft/Windows-driver-samples.git") {
    throw "The SysVAD dependency lock is malformed. Refusing to bootstrap an unpinned driver source."
}

$cacheRoot = Join-Path $driverRoot ".cache"
if ([string]::IsNullOrWhiteSpace($Destination)) {
    $Destination = Join-Path $cacheRoot "Windows-driver-samples"
}

$resolvedDriverRoot = [IO.Path]::GetFullPath($driverRoot).TrimEnd('\\') + '\\'
$resolvedDestination = [IO.Path]::GetFullPath($Destination)
if (-not $resolvedDestination.StartsWith($resolvedDriverRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "-Destination must remain below '$driverRoot'; bootstrap never writes an arbitrary directory."
}

$git = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue
if (-not $git) {
    throw "git.exe is required to bootstrap the pinned Microsoft SysVAD source."
}

if (Test-Path -LiteralPath $resolvedDestination) {
    $existingHead = & $git -C $resolvedDestination rev-parse HEAD 2>$null
    if ($LASTEXITCODE -ne 0 -or $existingHead.Trim() -ne $lock.commit) {
        throw "Destination already exists but is not the locked SysVAD checkout. Refusing to modify or delete it: $resolvedDestination"
    }
}
else {
    $parent = Split-Path -Parent $resolvedDestination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    & $git clone --filter=blob:none --no-checkout $lock.repository $resolvedDestination
    if ($LASTEXITCODE -ne 0) { throw "Cloning the pinned SysVAD source failed." }
    & $git -C $resolvedDestination checkout --detach $lock.commit
    if ($LASTEXITCODE -ne 0) { throw "Checking out the pinned SysVAD commit failed." }
}

& $git -C $resolvedDestination submodule update --init wil
if ($LASTEXITCODE -ne 0) { throw "Initializing the locked SysVAD WIL submodule failed." }

$actualWilCommit = (& $git -C (Join-Path $resolvedDestination "wil") rev-parse HEAD).Trim()
if ($actualWilCommit -ne $lock.wilSubmoduleCommit) {
    throw "WIL resolved to '$actualWilCommit', not locked '$($lock.wilSubmoduleCommit)'."
}

foreach ($relativePath in @(
    "audio\sysvad\sysvad.sln",
    "audio\sysvad\TabletAudioSample\minipairs.h",
    "audio\sysvad\EndpointsCommon\minwavertstream.cpp",
    "audio\sysvad\EndpointsCommon\minwavertstream.h")) {
    if (-not (Test-Path -LiteralPath (Join-Path $resolvedDestination $relativePath) -PathType Leaf)) {
        throw "The pinned source is missing required SysVAD patch target '$relativePath'."
    }
}

Write-Host "Pinned SysVAD source is ready at $resolvedDestination"
Write-Host "Review SysVadPatchContract.md before creating any driver patch."
