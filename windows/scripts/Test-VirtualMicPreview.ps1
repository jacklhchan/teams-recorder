[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path
$windowsRoot = Join-Path $repoRoot "windows"
$driverScripts = Join-Path $windowsRoot "driver\TeamsRecorderVirtualMic\scripts"
$applicationProject = Join-Path $windowsRoot "src\Recorder.Application\Recorder.Application.csproj"
$testProject = Join-Path $windowsRoot "tests\Recorder.VirtualMicPreview.Tests\Recorder.VirtualMicPreview.Tests.csproj"
$dotnet = (Get-Command dotnet -ErrorAction Stop).Source

try {
    & (Join-Path $driverScripts "Test-DriverPreflight.ps1") | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "WDK preflight command failed unexpectedly." }
    Write-Host "PASS: WDK preflight succeeded on this host."
}
catch {
    $preflightFailure = $_.Exception.Message
    $expectedUnavailableHost =
        $preflightFailure -match "Windows Driver Kit \(WDK\) is required" -or
        $preflightFailure -match "installed WDK is incomplete" -or
        $preflightFailure -match "Visual Studio MSBuild is required"
    if (-not $expectedUnavailableHost) {
        throw
    }
    Write-Host "PASS: host without the complete WDK toolchain fails closed with an explicit preflight error."
}

& $dotnet run --project $testProject --configuration Release --tl:off
if ($LASTEXITCODE -ne 0) { throw "Release virtual-microphone preview acceptance tests failed." }

& $dotnet run --project $testProject --configuration Debug --property:EnableTestSignedVirtualMicPreview=true --tl:off
if ($LASTEXITCODE -ne 0) { throw "Explicit Debug virtual-microphone preview acceptance tests failed." }

$releaseOutput = & $dotnet build $applicationProject --configuration Release --property:EnableTestSignedVirtualMicPreview=true --no-restore --tl:off 2>&1
if ($LASTEXITCODE -eq 0 -or ($releaseOutput -join "`n") -notmatch "permitted only in Debug builds") {
    throw "Release build unexpectedly accepted EnableTestSignedVirtualMicPreview."
}
Write-Host "PASS: Release build rejects the test-signed virtual microphone property."
