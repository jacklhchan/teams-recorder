[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
param(
    [Parameter(Mandatory)]
    [string]$CertificatePath,
    [ValidateSet("CurrentUser", "LocalMachine")]
    [string]$Scope = "CurrentUser",
    [Parameter(Mandatory)]
    [switch]$IUnderstandTestCertificateTrust
)

$ErrorActionPreference = "Stop"
$driverRoot = Split-Path -Parent $PSScriptRoot
$testSigningRoot = Join-Path $driverRoot "out\test-signing"
$resolvedRoot = [IO.Path]::GetFullPath($testSigningRoot).TrimEnd('\\') + '\\'
$resolvedCertificate = [IO.Path]::GetFullPath($CertificatePath)
if (-not $resolvedCertificate.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase) -or
    -not (Test-Path -LiteralPath $resolvedCertificate -PathType Leaf)) {
    throw "-CertificatePath must name a generated CER below '$testSigningRoot'."
}

$certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($resolvedCertificate)
if ($certificate.Subject -ne "CN=Teams Recorder Virtual Microphone Test" -or
    $certificate.Issuer -ne $certificate.Subject) {
    throw "The certificate is not the exact self-signed Teams Recorder virtual-mic test certificate."
}

if ($Scope -eq "LocalMachine") {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "-Scope LocalMachine requires an elevated PowerShell session."
    }
}

foreach ($storeName in @("Root", "TrustedPublisher")) {
    $store = "Cert:\$Scope\$storeName"
    if ($PSCmdlet.ShouldProcess($store, "Trust only test certificate $($certificate.Thumbprint)")) {
        Import-Certificate -FilePath $resolvedCertificate -CertStoreLocation $store | Out-Null
    }
}

Write-Host "Imported the exact test certificate into $Scope Root and TrustedPublisher."
Write-Host "This script did not enable TESTSIGNING, change Secure Boot/BitLocker, or install a driver."
