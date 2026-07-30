[CmdletBinding()]
param(
    [string]$CertificateThumbprint,
    [string]$CertificatePfxPath,
    [SecureString]$CertificatePfxPassword,
    [uri]$AppInstallerUri
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path
$windowsRoot = Join-Path $repoRoot "windows"
$project = Join-Path $windowsRoot "src\Recorder.WinUI\Recorder.WinUI.csproj"
$nativeBridge = Join-Path $windowsRoot "out\native\Release\Recorder.NativeBridge.dll"
$packageRoot = Join-Path $windowsRoot "out\packages"
$manifestPath = Join-Path $windowsRoot "src\Recorder.WinUI\Package.appxmanifest"

if ($CertificateThumbprint -and $CertificatePfxPath) { throw "Specify either -CertificateThumbprint or -CertificatePfxPath, not both." }
if ($CertificatePfxPassword -and -not $CertificatePfxPath) { throw "-CertificatePfxPassword requires -CertificatePfxPath." }
if ($AppInstallerUri -and -not ($CertificateThumbprint -or $CertificatePfxPath)) { throw "An App Installer feed is only generated for a signed package." }
if ($AppInstallerUri -and $AppInstallerUri.Scheme -ne "https") { throw "-AppInstallerUri must use HTTPS." }
if (-not (Test-Path -LiteralPath $nativeBridge -PathType Leaf)) { throw "Release native bridge is missing. Run windows/scripts/Verify-Windows.ps1 first." }

$dotnet = (Get-Command dotnet -ErrorAction Stop).Source
New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
[xml]$manifest = Get-Content -LiteralPath $manifestPath -Raw
$namespaceManager = New-Object System.Xml.XmlNamespaceManager($manifest.NameTable)
$namespaceManager.AddNamespace("f", "http://schemas.microsoft.com/appx/manifest/foundation/windows10")
$identity = $manifest.SelectSingleNode("/f:Package/f:Identity", $namespaceManager)
if ($null -eq $identity) { throw "Package manifest has no Identity element." }

$signingArguments = @("--property:AppxPackageSigningEnabled=false")
$signingMode = "unsigned developer-only"
$pfxPasswordPlain = $null
$previousPfxPasswordEnvironmentValue = $null
$hadPfxPasswordEnvironmentValue = $false
try {
    if ($CertificateThumbprint) {
        $normalizedThumbprint = ($CertificateThumbprint -replace "[[:space:]]", "").ToUpperInvariant()
        if ($normalizedThumbprint -notmatch "^[0-9A-F]{40}$") { throw "-CertificateThumbprint must be a 40-character SHA-1 certificate thumbprint." }
        $certificate = @(Get-ChildItem -Path "Cert:\CurrentUser\My", "Cert:\LocalMachine\My" -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $normalizedThumbprint }) | Select-Object -First 1
        if ($null -eq $certificate) { throw "The specified signing certificate was not found in CurrentUser\\My or LocalMachine\\My." }
        if (-not $certificate.HasPrivateKey) { throw "The specified signing certificate does not have an accessible private key." }
        if ($certificate.Subject -ne $identity.Publisher) { throw "Certificate subject '$($certificate.Subject)' must exactly match manifest Publisher '$($identity.Publisher)'." }
        if ($certificate.NotAfter -lt (Get-Date)) { throw "The specified signing certificate is expired." }
        $signingArguments = @("--property:AppxPackageSigningEnabled=true", "--property:PackageCertificateThumbprint=$normalizedThumbprint")
        $signingMode = "signed with certificate thumbprint $normalizedThumbprint"
    }
    elseif ($CertificatePfxPath) {
        $resolvedPfxPath = (Resolve-Path -LiteralPath $CertificatePfxPath -ErrorAction Stop).Path
        if ([System.IO.Path]::GetExtension($resolvedPfxPath) -notin ".pfx", ".p12") { throw "-CertificatePfxPath must name a .pfx or .p12 file." }
        if ($null -eq $CertificatePfxPassword) { throw "-CertificatePfxPassword is required with -CertificatePfxPath; pass (Read-Host -AsSecureString)." }
        $pfxData = Get-PfxData -FilePath $resolvedPfxPath -Password $CertificatePfxPassword
        $pfxCertificate = @($pfxData.EndEntityCertificates | Where-Object { $_.Subject -eq $identity.Publisher -and $_.HasPrivateKey }) | Select-Object -First 1
        if ($null -eq $pfxCertificate) { throw "The PFX must contain a signing certificate with a private key whose subject exactly matches '$($identity.Publisher)'." }
        if ($pfxCertificate.NotAfter -lt (Get-Date)) { throw "The PFX signing certificate is expired." }
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($CertificatePfxPassword)
        try { $pfxPasswordPlain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        $signingArguments = @("--property:AppxPackageSigningEnabled=true", "--property:PackageCertificateKeyFile=$resolvedPfxPath")
        $signingMode = "signed with supplied PFX"
    }

    if ($null -ne $pfxPasswordPlain) {
        $previousPfxPasswordEnvironmentValue = [Environment]::GetEnvironmentVariable("PackageCertificatePassword", "Process")
        $hadPfxPasswordEnvironmentValue = $null -ne $previousPfxPasswordEnvironmentValue
        try {
            [Environment]::SetEnvironmentVariable("PackageCertificatePassword", $pfxPasswordPlain, "Process")
            & $dotnet build $project --configuration Release --property:Platform=x64 --property:RuntimeIdentifier=win-x64 --property:WindowsPackageType=MSIX "-p:AppxPackageDir=$packageRoot\" --property:UapAppxPackageBuildMode=SideloadOnly --property:AppxBundle=Never --property:GenerateAppxPackageOnBuild=true --no-restore --tl:off @signingArguments
            if ($LASTEXITCODE -ne 0) { throw "MSIX packaging failed with exit code $LASTEXITCODE." }
        }
        finally {
            if ($hadPfxPasswordEnvironmentValue) {
                [Environment]::SetEnvironmentVariable("PackageCertificatePassword", $previousPfxPasswordEnvironmentValue, "Process")
            }
            else {
                [Environment]::SetEnvironmentVariable("PackageCertificatePassword", $null, "Process")
            }
            $pfxPasswordPlain = $null
        }
    }
    else {
        & $dotnet build $project --configuration Release --property:Platform=x64 --property:RuntimeIdentifier=win-x64 --property:WindowsPackageType=MSIX "-p:AppxPackageDir=$packageRoot\" --property:UapAppxPackageBuildMode=SideloadOnly --property:AppxBundle=Never --property:GenerateAppxPackageOnBuild=true --no-restore --tl:off @signingArguments
        if ($LASTEXITCODE -ne 0) { throw "MSIX packaging failed with exit code $LASTEXITCODE." }
    }
    $package = Get-ChildItem -LiteralPath $packageRoot -Filter "Recorder.WinUI_*.msix" -File -Recurse | Where-Object { $_.DirectoryName -notmatch "[\\/]Dependencies([\\/]|$)" } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if ($null -eq $package) { throw "MSIX packaging completed but the main package was not found under $packageRoot." }
    if ($AppInstallerUri) {
        $appInstallerPath = Join-Path $package.DirectoryName "Recorder.WinUI.appinstaller"
        $packageUri = [uri]::new($AppInstallerUri, [uri]::EscapeDataString($package.Name))
        $escapedPackageUri = [System.Security.SecurityElement]::Escape($packageUri.AbsoluteUri)
        $escapedAppInstallerUri = [System.Security.SecurityElement]::Escape($AppInstallerUri.AbsoluteUri)
        @"
<?xml version="1.0" encoding="utf-8"?>
<AppInstaller Uri="$escapedAppInstallerUri" Version="$($identity.Version)" xmlns="http://schemas.microsoft.com/appx/appinstaller/2018">
  <MainPackage Name="$($identity.Name)" Publisher="$($identity.Publisher)" Version="$($identity.Version)" ProcessorArchitecture="x64" Uri="$escapedPackageUri" />
  <UpdateSettings><OnLaunch HoursBetweenUpdateChecks="24" /></UpdateSettings>
</AppInstaller>
"@ | Set-Content -LiteralPath $appInstallerPath -Encoding utf8NoBOM
        Write-Host "Created App Installer feed: $appInstallerPath"
        Write-Host "Publish that file and $($package.Name) together at the declared HTTPS location before sharing it."
    }
    Write-Host "Created $signingMode MSIX: $($package.FullName)"
    Write-Host "No certificate was imported or trusted, and no package was installed."
}
finally {
    $pfxPasswordPlain = $null
}
