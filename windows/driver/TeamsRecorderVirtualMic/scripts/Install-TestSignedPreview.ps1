[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
param(
    [Parameter(Mandatory)]
    [string]$PackageDirectory,
    [string]$DevConPath,
    [Parameter(Mandatory)]
    [switch]$IUnderstandThisIsForADisposableTestMachine
)

$ErrorActionPreference = "Stop"
$driverRoot = Split-Path -Parent $PSScriptRoot
$resolvedPackageRoot = [IO.Path]::GetFullPath((Join-Path $driverRoot "out\package")).TrimEnd('\\') + '\\'
$resolvedPackage = [IO.Path]::GetFullPath($PackageDirectory)
if (-not $resolvedPackage.StartsWith($resolvedPackageRoot, [StringComparison]::OrdinalIgnoreCase) -or
    -not (Test-Path -LiteralPath $resolvedPackage -PathType Container)) {
    throw "-PackageDirectory must be an existing package below '$($resolvedPackageRoot.TrimEnd('\\'))'."
}

$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Installing a root-enumerated test driver requires an elevated PowerShell session."
}

$preflight = & (Join-Path $PSScriptRoot "Test-DriverPreflight.ps1")
if ([string]::IsNullOrWhiteSpace($DevConPath)) { $DevConPath = $preflight.DevConPath }
$resolvedDevCon = [IO.Path]::GetFullPath($DevConPath)
if (-not (Test-Path -LiteralPath $resolvedDevCon -PathType Leaf)) { throw "devcon.exe was not found: $resolvedDevCon" }

$bcdEdit = Join-Path $env:SystemRoot "System32\bcdedit.exe"
if (-not (Test-Path -LiteralPath $bcdEdit -PathType Leaf)) { throw "bcdedit.exe was not found; refusing to assume test-signing status." }
$bootConfiguration = & $bcdEdit /enum "{current}"
if ($LASTEXITCODE -ne 0 -or ($bootConfiguration -join "`n") -notmatch "(?im)^\s*testsigning\s+Yes\s*$") {
    throw "TESTSIGNING is not visibly enabled for the current boot entry. Enable it manually only on a disposable test machine, reboot, then rerun; this script will not change boot configuration."
}

$inf = Join-Path $resolvedPackage "TeamsRecorderVirtualMic.inf"
$catalog = Join-Path $resolvedPackage "TeamsRecorderVirtualMic.cat"
$driver = Join-Path $resolvedPackage "TeamsRecorderVirtualMic.sys"
foreach ($required in @($inf, $catalog, $driver)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Signed package is missing required file: $required" }
}
if ((Get-Content -LiteralPath $inf -Raw) -notmatch [regex]::Escape("ROOT\TeamsRecorderVirtualMic")) {
    throw "The selected INF does not contain the exact expected hardware ID."
}
& $preflight.SignToolPath verify /v /pa $catalog
if ($LASTEXITCODE -ne 0) { throw "The package catalog is not verifiably signed." }
& $preflight.SignToolPath verify /v /pa $driver
if ($LASTEXITCODE -ne 0) { throw "The driver binary is not verifiably signed." }

if ($PSCmdlet.ShouldProcess("ROOT\TeamsRecorderVirtualMic", "Install exact test-signed virtual microphone device")) {
    & $resolvedDevCon install $inf "ROOT\TeamsRecorderVirtualMic"
    if ($LASTEXITCODE -ne 0) { throw "devcon failed to install the exact test virtual microphone device." }
}

Write-Host "bcdedit was queried only; this script never changes TESTSIGNING, Secure Boot, or BitLocker."
Write-Host "No certificate was imported by this script; use Install-TestCertificate.ps1 explicitly if required."
