[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
param(
    [Parameter(Mandatory)]
    [string]$DevConPath,
    [string]$PublishedName,
    [Parameter(Mandatory)]
    [switch]$IUnderstandThisRemovesOnlyThePreviewDriver
)

$ErrorActionPreference = "Stop"
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Removing a root-enumerated test driver requires an elevated PowerShell session."
}

$resolvedDevCon = [IO.Path]::GetFullPath($DevConPath)
if (-not (Test-Path -LiteralPath $resolvedDevCon -PathType Leaf)) { throw "devcon.exe was not found: $resolvedDevCon" }

if ($PSCmdlet.ShouldProcess("ROOT\TeamsRecorderVirtualMic", "Remove exact test virtual microphone device")) {
    & $resolvedDevCon remove "ROOT\TeamsRecorderVirtualMic"
    if ($LASTEXITCODE -ne 0) { throw "devcon failed to remove the exact test virtual microphone device." }
}

if (-not [string]::IsNullOrWhiteSpace($PublishedName)) {
    if ($PublishedName -notmatch "^oem[0-9]+\.inf$") {
        throw "-PublishedName must be an exact PnP published INF name such as oem42.inf."
    }
    if ($PSCmdlet.ShouldProcess($PublishedName, "Remove exact staged test driver package")) {
        & pnputil.exe /delete-driver $PublishedName /uninstall
        if ($LASTEXITCODE -ne 0) { throw "pnputil failed to remove $PublishedName." }
    }
}
else {
    Write-Warning "The device was removed, but its staged package remains. Supply -PublishedName oemNN.inf to remove only that exact package."
}

Write-Host "No certificate store entries, TESTSIGNING settings, Secure Boot, or BitLocker settings were changed."
