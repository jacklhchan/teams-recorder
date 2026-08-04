[CmdletBinding()]
param(
    [string]$Version = "1.0.0"
)

$ErrorActionPreference = "Stop"

if ($Version -notmatch "^\d+\.\d+\.\d+([-.][0-9A-Za-z.-]+)?$") {
    throw "-Version must begin with a three-part version such as 1.0.0."
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path
$windowsRoot = Join-Path $repoRoot "windows"
$project = Join-Path $windowsRoot "src\Recorder.WinUI\Recorder.WinUI.csproj"
$cliProject = Join-Path $windowsRoot "src\Recorder.Cli\Recorder.Cli.csproj"
$nativeBridge = Join-Path $windowsRoot "out\native\Release\Recorder.NativeBridge.dll"
$installerScript = Join-Path $windowsRoot "installer\TeamsRecorder.iss"
$publishDirectory = Join-Path $windowsRoot "out\publish\setup-win-x64"
$outputDirectory = Join-Path $windowsRoot "out\installer"

if (-not (Test-Path -LiteralPath $nativeBridge -PathType Leaf)) {
    throw "Release Recorder.NativeBridge.dll is missing. Run windows/scripts/Verify-Windows.ps1 first."
}

# The Release bridge uses the MSVC dynamic runtime. Keep this a per-user
# installer by deploying the required redistributable DLLs app-local instead
# of asking the target computer to run a machine-wide VC++ installer.
$runtimeDirectory = Join-Path $env:SystemRoot "System32"
$nativeRuntimeFiles = @("msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll")

$isccCandidates = @(
    (Get-Command ISCC.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
    (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe"),
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }
$iscc = $isccCandidates | Select-Object -First 1
if (-not $iscc) {
    throw "Inno Setup 6 (ISCC.exe) was not found. Install it with: winget install --id JRSoftware.InnoSetup -e"
}

$dotnet = (Get-Command dotnet -ErrorAction Stop).Source
New-Item -ItemType Directory -Path $publishDirectory, $outputDirectory -Force | Out-Null

& $dotnet publish $project `
    --configuration Release `
    --runtime win-x64 `
    --self-contained true `
    --no-restore `
    --property:Platform=x64 `
    --property:WindowsPackageType=None `
    --property:PublishSingleFile=false `
    --property:PublishTrimmed=false `
    --output $publishDirectory `
    --tl:off
if ($LASTEXITCODE -ne 0) {
    throw "Self-contained WinUI publish failed with exit code $LASTEXITCODE."
}

if (-not (Test-Path -LiteralPath (Join-Path $publishDirectory "Recorder.WinUI.exe") -PathType Leaf)) {
    throw "Self-contained publish did not produce Recorder.WinUI.exe."
}
if (-not (Test-Path -LiteralPath (Join-Path $publishDirectory "Recorder.NativeBridge.dll") -PathType Leaf)) {
    throw "Self-contained publish did not include Recorder.NativeBridge.dll."
}

& $dotnet publish $cliProject `
    --configuration Release `
    --runtime win-x64 `
    --self-contained true `
    --no-restore `
    --property:PublishSingleFile=true `
    --property:PublishTrimmed=false `
    --output $publishDirectory `
    --tl:off
if ($LASTEXITCODE -ne 0) {
    throw "Self-contained recorder CLI publish failed with exit code $LASTEXITCODE."
}
if (-not (Test-Path -LiteralPath (Join-Path $publishDirectory "teams-recorder.exe") -PathType Leaf)) {
    throw "CLI publish did not produce teams-recorder.exe."
}
foreach ($runtimeFile in $nativeRuntimeFiles) {
    $runtimeSource = Join-Path $runtimeDirectory $runtimeFile
    if (-not (Test-Path -LiteralPath $runtimeSource -PathType Leaf)) {
        throw "Required VC++ runtime was not found: $runtimeSource"
    }
    Copy-Item -LiteralPath $runtimeSource -Destination (Join-Path $publishDirectory $runtimeFile) -Force
}

& $iscc "/DSourceDir=$publishDirectory" "/DOutputDir=$outputDirectory" "/DAppVersion=$Version" $installerScript
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup compilation failed with exit code $LASTEXITCODE."
}

$setup = Join-Path $outputDirectory "TeamsRecorderSetup-$Version-win-x64.exe"
if (-not (Test-Path -LiteralPath $setup -PathType Leaf)) {
    throw "Inno Setup completed but the expected setup executable was not produced: $setup"
}

Write-Host "Created self-contained setup: $setup"
Write-Host "This unsigned developer build preserves recordings under %LocalAppData%\Teams Recorder\Sessions when it is uninstalled."
