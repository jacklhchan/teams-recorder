[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',
    [ValidateRange(60, 3600)]
    [int]$At03Seconds = 300,
    [ValidateRange(1, 10)]
    [int]$At05Runs = 3,
    [ValidateRange(60, 3600)]
    [int]$At05Seconds = 600,
    [string]$OutputDirectory,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$nativeRoot = Join-Path $repoRoot 'windows\native'
$defaultEvidence = Join-Path $repoRoot 'windows\out\acceptance'
$resolvedOutput = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $defaultEvidence } else { $OutputDirectory }
New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null

if (-not $SkipBuild) {
    $preset = if ($Configuration -eq 'Release') { 'windows-x64-release' } else { 'windows-x64-debug' }
    Push-Location $nativeRoot
    try {
        & cmake --build --preset $preset --target Recorder.AvMarkerAcceptance.Tests
        if ($LASTEXITCODE -ne 0) { throw 'Could not build Recorder.AvMarkerAcceptance.Tests.' }
    } finally { Pop-Location }
}

$test = Join-Path $repoRoot "windows\out\native\$Configuration\Recorder.AvMarkerAcceptance.Tests.exe"
if (-not (Test-Path -LiteralPath $test -PathType Leaf)) {
    throw "A/V marker acceptance executable was not found: $test"
}

$runs = @($At03Seconds) + @(1..$At05Runs | ForEach-Object { $At05Seconds })
$records = @()
foreach ($duration in $runs) {
    $started = [DateTimeOffset]::UtcNow
    $lines = & $test --duration-seconds $duration 2>&1
    $exitCode = $LASTEXITCODE
    $records += [ordered]@{
        durationSeconds = $duration
        startedUtc = $started.ToString('o')
        completedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        exitCode = $exitCode
        output = @($lines | ForEach-Object { $_.ToString() })
    }
    if ($exitCode -ne 0) {
        throw "A/V marker acceptance failed for $duration seconds: $($lines -join [Environment]::NewLine)"
    }
}

$commit = (& git -C $repoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Could not read the current Git commit.' }
$worktreeStatus = @(& git -C $repoRoot status --porcelain)
if ($LASTEXITCODE -ne 0) { throw 'Could not read the current Git worktree state.' }
$worktreeDiff = (& git -C $repoRoot diff --binary | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'Could not read the current Git worktree diff.' }
$sha256 = New-Object System.Security.Cryptography.SHA256Managed
try {
    $diffBytes = [System.Text.Encoding]::UTF8.GetBytes($worktreeDiff)
    $worktreeDiffSha256 = ([System.BitConverter]::ToString($sha256.ComputeHash($diffBytes))).Replace('-', '')
} finally { $sha256.Dispose() }
$binarySha256 = (Get-FileHash -LiteralPath $test -Algorithm SHA256).Hash
$evidence = [ordered]@{
    schemaVersion = 1
    kind = 'deterministic-av-marker-acceptance'
    commit = $commit
    worktreeDirty = $worktreeStatus.Count -ne 0
    worktreeDiffSha256 = $worktreeDiffSha256
    executableSha256 = $binarySha256
    generatedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    configuration = $Configuration
    at03Seconds = $At03Seconds
    at05Runs = $At05Runs
    at05Seconds = $At05Seconds
    result = 'PASS'
    notes = 'Synthetic mux/decoder evidence only; it does not replace live Teams or WGC privacy acceptance.'
    runs = $records
}
$stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$path = Join-Path $resolvedOutput "deterministic-av-marker-$stamp.json"
$evidence | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
Write-Output "PASS deterministic A/V evidence: $path"
