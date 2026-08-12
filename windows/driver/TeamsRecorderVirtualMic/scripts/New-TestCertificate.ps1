[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [SecureString]$PfxPassword,
    [string]$OutputDirectory,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$driverRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $driverRoot "out\test-signing"
}

$resolvedDriverRoot = [IO.Path]::GetFullPath($driverRoot).TrimEnd('\\') + '\\'
$resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $resolvedOutput.StartsWith($resolvedDriverRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "-OutputDirectory must remain below '$driverRoot'; certificate material is never written to an arbitrary directory."
}

$pfxPath = Join-Path $resolvedOutput "TeamsRecorderVirtualMic-Test.pfx"
$cerPath = Join-Path $resolvedOutput "TeamsRecorderVirtualMic-Test.cer"
if ((Test-Path -LiteralPath $pfxPath -or Test-Path -LiteralPath $cerPath) -and -not $Force) {
    throw "Test certificate output already exists. Use -Force only if replacing this exact ignored test-signing output."
}

New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null
$certificate = $null
try {
    $certificate = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject "CN=Teams Recorder Virtual Microphone Test" `
        -FriendlyName "Teams Recorder Virtual Microphone Test Signing" `
        -KeyAlgorithm RSA `
        -KeyLength 3072 `
        -KeyExportPolicy Exportable `
        -HashAlgorithm SHA256 `
        -NotAfter (Get-Date).AddDays(30) `
        -CertStoreLocation "Cert:\CurrentUser\My"

    Export-PfxCertificate -Cert $certificate -FilePath $pfxPath -Password $PfxPassword -Force:$Force | Out-Null
    Export-Certificate -Cert $certificate -FilePath $cerPath -Force:$Force | Out-Null
}
catch {
    if ($certificate) {
        Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($certificate.Thumbprint)" -Force -ErrorAction SilentlyContinue
    }
    throw
}

[PSCustomObject]@{
    CertificatePath = $cerPath
    PfxPath = $pfxPath
    Thumbprint = $certificate.Thumbprint
    Subject = $certificate.Subject
    ExpiresUtc = $certificate.NotAfter.ToUniversalTime().ToString("O")
    Note = "The certificate remains only in CurrentUser\\My. This script did not add a trusted root or enable test-signing."
}
