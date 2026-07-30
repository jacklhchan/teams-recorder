[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path
$windowsRoot = Join-Path $repoRoot "windows"
$nativeRoot = Join-Path $windowsRoot "native"

function Invoke-Checked {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [Parameter(ValueFromRemainingArguments)]
        [string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "'$FilePath $($Arguments -join ' ')' failed with exit code $LASTEXITCODE."
    }
}

function Resolve-Tool {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$FallbackPath
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }
    if (Test-Path -LiteralPath $FallbackPath -PathType Leaf) {
        return $FallbackPath
    }
    throw "Required tool '$Name' was not found. See windows/README.md for prerequisites."
}

$dotnet = Resolve-Tool "dotnet" (Join-Path $env:ProgramFiles "dotnet\dotnet.exe")
$visualStudioCmake = Join-Path $env:ProgramFiles "Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
$cmake = Resolve-Tool "cmake" $visualStudioCmake
$ctest = Resolve-Tool "ctest" (Join-Path (Split-Path -Parent $cmake) "ctest.exe")

# Some automation hosts inject both Path and PATH. MSBuild treats those as
# duplicate case-insensitive environment keys when it starts cl.exe.
$normalizedPath = $env:Path
[Environment]::SetEnvironmentVariable("PATH", $null, [EnvironmentVariableTarget]::Process)
[Environment]::SetEnvironmentVariable("Path", $normalizedPath, [EnvironmentVariableTarget]::Process)

Push-Location $nativeRoot
try {
    Invoke-Checked $cmake "--preset" "windows-x64"
    Invoke-Checked $cmake "--build" "--preset" "windows-x64-debug"
    Invoke-Checked $cmake "--build" "--preset" "windows-x64-release"
    Invoke-Checked $ctest "--preset" "windows-x64-debug"
    Invoke-Checked $ctest "--preset" "windows-x64-release"
} finally {
    Pop-Location
}

Push-Location $windowsRoot
try {
    Invoke-Checked $dotnet "build" ".\TeamsRecorder.Windows.sln" "--configuration" "Release" "--tl:off"
    Invoke-Checked $dotnet "build" ".\src\Recorder.WinUI\Recorder.WinUI.csproj" "--configuration" "Release" "--property:Platform=x64" "--property:RuntimeIdentifier=win-x64" "--no-restore" "--tl:off"
    Invoke-Checked $dotnet "run" "--project" ".\tests\Recorder.Core.Tests\Recorder.Core.Tests.csproj" "--configuration" "Release" "--no-build"
    $publishDirectory = Join-Path $windowsRoot "out\publish\win-x64"
    Invoke-Checked $dotnet "publish" ".\src\Recorder.WinUI\Recorder.WinUI.csproj" "--configuration" "Release" "--property:Platform=x64" "--property:RuntimeIdentifier=win-x64" "--property:WindowsPackageType=None" "--no-restore" "--output" $publishDirectory "--tl:off"
    foreach ($publishedFile in @("Recorder.WinUI.exe", "Recorder.NativeBridge.dll")) {
        if (-not (Test-Path -LiteralPath (Join-Path $publishDirectory $publishedFile) -PathType Leaf)) {
            throw "Unpackaged publish did not produce $publishedFile."
        }
    }
} finally {
    Pop-Location
}

& (Join-Path $PSScriptRoot "Test-Contracts.ps1")

Write-Host "Windows migration verification passed."
