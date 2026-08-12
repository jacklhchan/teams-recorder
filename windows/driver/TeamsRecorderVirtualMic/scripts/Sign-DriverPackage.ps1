[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$CertificatePfxPath,
    [Parameter(Mandatory)]
    [SecureString]$PfxPassword,
    [string]$PackageDirectory
)

$ErrorActionPreference = "Stop"
$driverRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($PackageDirectory)) {
    $PackageDirectory = Join-Path $driverRoot "out\package"
}

function Resolve-ChildPath {
    param([string]$Path, [string]$Root, [string]$ParameterName)
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\\') + '\\'
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not $resolvedPath.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$ParameterName must remain below '$Root'."
    }
    return $resolvedPath
}

$resolvedPackage = Resolve-ChildPath $PackageDirectory (Join-Path $driverRoot "out\package") "-PackageDirectory"
$resolvedPfx = Resolve-ChildPath $CertificatePfxPath (Join-Path $driverRoot "out\test-signing") "-CertificatePfxPath"
if (-not (Test-Path -LiteralPath $resolvedPackage -PathType Container)) { throw "Driver package directory does not exist: $resolvedPackage" }
if (-not (Test-Path -LiteralPath $resolvedPfx -PathType Leaf)) { throw "Test PFX does not exist: $resolvedPfx" }

$pfxData = Get-PfxData -FilePath $resolvedPfx -Password $PfxPassword
$testCertificate = @($pfxData.EndEntityCertificates | Where-Object {
    $_.Subject -eq "CN=Teams Recorder Virtual Microphone Test" -and $_.Issuer -eq $_.Subject -and $_.HasPrivateKey
}) | Select-Object -First 1
if ($null -eq $testCertificate) {
    throw "The PFX is not the exact Teams Recorder virtual-microphone test certificate with a private key."
}

$preflight = & (Join-Path $PSScriptRoot "Test-DriverPreflight.ps1")
$inf = Join-Path $resolvedPackage "TeamsRecorderVirtualMic.inf"
$catalog = Join-Path $resolvedPackage "TeamsRecorderVirtualMic.cat"
$expectedHardwareId = "ROOT\TeamsRecorderVirtualMic"
if (-not (Test-Path -LiteralPath $inf -PathType Leaf)) { throw "Expected INF is missing: $inf" }
$infText = Get-Content -LiteralPath $inf -Raw
if ($infText -notmatch [regex]::Escape($expectedHardwareId) -or
    $infText -notmatch "CatalogFile=TeamsRecorderVirtualMic.cat") {
    throw "The package INF does not match the exact virtual-microphone identity contract."
}

$drivers = @(Get-ChildItem -LiteralPath $resolvedPackage -Filter "*.sys" -File)
if ($drivers.Count -ne 1 -or $drivers[0].Name -ne "TeamsRecorderVirtualMic.sys") {
    throw "The package must contain exactly one driver binary named TeamsRecorderVirtualMic.sys."
}

& $preflight.Inf2CatPath "/driver:$resolvedPackage" "/os:10_X64"
if ($LASTEXITCODE -ne 0) { throw "inf2cat failed for the constrained preview package." }
if (-not (Test-Path -LiteralPath $catalog -PathType Leaf)) { throw "inf2cat did not create the expected catalog: $catalog" }

$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($PfxPassword)
try {
    $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    foreach ($file in @($drivers[0].FullName, $catalog)) {
        & $preflight.SignToolPath sign /v /fd SHA256 /f $resolvedPfx /p $plainPassword $file
        if ($LASTEXITCODE -ne 0) { throw "signtool failed for $file" }
        & $preflight.SignToolPath verify /v /pa $file
        if ($LASTEXITCODE -ne 0) { throw "Signature verification failed for $file" }
    }
}
finally {
    if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    $plainPassword = $null
}

Write-Host "Test-signed, verified constrained driver package: $resolvedPackage"
