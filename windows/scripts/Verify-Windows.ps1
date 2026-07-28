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
$cmake = Resolve-Tool "cmake" (Join-Path $env:ProgramFiles "CMake\bin\cmake.exe")
$ctest = Resolve-Tool "ctest" (Join-Path $env:ProgramFiles "CMake\bin\ctest.exe")

Push-Location $windowsRoot
try {
    Invoke-Checked $dotnet "build" ".\TeamsRecorder.Windows.sln" "--configuration" "Release"
    Invoke-Checked $dotnet "run" "--project" ".\tests\Recorder.Core.Tests\Recorder.Core.Tests.csproj" "--configuration" "Release" "--no-build"
} finally {
    Pop-Location
}

& (Join-Path $PSScriptRoot "Test-Contracts.ps1")

# Some automation hosts inject both Path and PATH. MSBuild treats those as
# duplicate case-insensitive environment keys when it starts cl.exe.
$normalizedPath = $env:Path
[Environment]::SetEnvironmentVariable("PATH", $null, [EnvironmentVariableTarget]::Process)
[Environment]::SetEnvironmentVariable("Path", $normalizedPath, [EnvironmentVariableTarget]::Process)

Push-Location $nativeRoot
try {
    Invoke-Checked $cmake "--preset" "windows-x64"
    Invoke-Checked $cmake "--build" "--preset" "windows-x64-debug"
    Invoke-Checked $ctest "--preset" "windows-x64-debug"
} finally {
    Pop-Location
}

Write-Host "Windows migration verification passed."
