[CmdletBinding()]
param()
$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path
$scriptPath = Join-Path $PSScriptRoot "Package-Windows.ps1"
$manifestPath = Join-Path $repoRoot "windows\src\Recorder.WinUI\Package.appxmanifest"
$parseErrors = $null; $tokens = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "Package-Windows.ps1 has PowerShell parse errors: $($parseErrors.Message -join '; ')" }
[xml]$manifest = Get-Content -LiteralPath $manifestPath -Raw
$description = $manifest.Package.Applications.Application.VisualElements.Description
# The question mark is a literal stale-text marker, not a regex quantifier.
if ([string]::IsNullOrWhiteSpace($description) -or $description -match 'WAV|\?') { throw "Package.appxmanifest has a stale or malformed media description." }
$scriptText = Get-Content -LiteralPath $scriptPath -Raw
foreach ($requiredText in @("CertificateThumbprint", "CertificatePfxPath", "AppInstallerUri", "AppxPackageSigningEnabled=false", "No certificate was imported or trusted")) { if (-not $scriptText.Contains($requiredText)) { throw "Package-Windows.ps1 is missing required packaging guard: $requiredText" } }
foreach ($requiredText in @('GetEnvironmentVariable("PackageCertificatePassword", "Process")', 'SetEnvironmentVariable("PackageCertificatePassword", $pfxPasswordPlain, "Process")', 'SetEnvironmentVariable("PackageCertificatePassword", $null, "Process")')) { if (-not $scriptText.Contains($requiredText)) { throw "Package-Windows.ps1 is missing required PFX password environment handling: $requiredText" } }
if ($scriptText -match 'PackageCertificatePassword=') { throw "Package-Windows.ps1 must not pass the PFX password on the dotnet/MSBuild command line." }
if ($scriptText -match '(?im)Write-(Host|Output|Verbose|Information|Debug|Warning|Error).*\$pfxPasswordPlain') { throw "Package-Windows.ps1 must not write the PFX password to output." }
$setPasswordIndex = $scriptText.IndexOf('SetEnvironmentVariable("PackageCertificatePassword", $pfxPasswordPlain, "Process")')
$buildIndex = $scriptText.IndexOf('& $dotnet build', $setPasswordIndex)
$restorePasswordIndex = $scriptText.IndexOf('SetEnvironmentVariable("PackageCertificatePassword", $previousPfxPasswordEnvironmentValue, "Process")', $buildIndex)
if ($setPasswordIndex -lt 0 -or $buildIndex -lt $setPasswordIndex -or $restorePasswordIndex -lt $buildIndex) { throw "Package-Windows.ps1 must scope the PFX password environment variable to the dotnet build invocation." }
Write-Host "Package script and manifest validation passed."
