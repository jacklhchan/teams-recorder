[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path
$windowsRoot = Join-Path $repoRoot "windows"
$project = Join-Path $windowsRoot "src\Recorder.WinUI\Recorder.WinUI.csproj"
$nativeBridge = Join-Path $windowsRoot "out\native\Release\Recorder.NativeBridge.dll"
$packageRoot = Join-Path $windowsRoot "out\packages"

if (-not (Test-Path -LiteralPath $nativeBridge -PathType Leaf)) {
    throw "Release native bridge is missing. Run windows/scripts/Verify-Windows.ps1 first."
}

$dotnet = (Get-Command dotnet -ErrorAction Stop).Source
New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null

& $dotnet build $project `
    --configuration Release `
    --property:Platform=x64 `
    --property:RuntimeIdentifier=win-x64 `
    --property:WindowsPackageType=MSIX `
    "-p:AppxPackageDir=$packageRoot\" `
    --property:UapAppxPackageBuildMode=SideloadOnly `
    --property:AppxBundle=Never `
    --property:AppxPackageSigningEnabled=false `
    --property:GenerateAppxPackageOnBuild=true `
    --no-restore `
    --tl:off

if ($LASTEXITCODE -ne 0) {
    throw "MSIX packaging failed with exit code $LASTEXITCODE."
}

Write-Host "Created an unsigned MSIX under $packageRoot. It has not been installed."
