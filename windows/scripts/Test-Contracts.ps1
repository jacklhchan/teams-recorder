[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path
$canonicalContractsRoot = Join-Path $repoRoot "contracts"
$schemaPath = Join-Path $canonicalContractsRoot "recording-session.schema.json"
$windowsFixturePath = Join-Path $repoRoot "windows\contracts\fixtures\recording-info.windows-v1.json"
$validatorProject = Join-Path $PSScriptRoot "ContractSchemaValidator\ContractSchemaValidator.csproj"
$fixturesDirectory = Join-Path $canonicalContractsRoot "fixtures"

foreach ($requiredPath in @($schemaPath, $windowsFixturePath, $validatorProject)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required recording-session contract input is missing: $requiredPath"
    }
}
if (-not (Test-Path -LiteralPath $fixturesDirectory -PathType Container)) {
    throw "Required recording-session fixtures directory is missing: $fixturesDirectory"
}

function Read-JsonObject {
    param([Parameter(Mandatory)][string]$Path)

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

$canonicalFixtures = @(Get-ChildItem -LiteralPath $fixturesDirectory -Filter "*.json" -File | Sort-Object Name)
if ($canonicalFixtures.Count -eq 0) {
    throw "The canonical recording-session contract must include at least one fixture."
}

$canonicalFixturePath = Join-Path $fixturesDirectory "recording-info-v1.json"
if (-not (Test-Path -LiteralPath $canonicalFixturePath -PathType Leaf)) {
    throw "The cross-platform recording-info-v1 fixture is missing."
}

$canonicalFixture = Read-JsonObject $canonicalFixturePath
if ($canonicalFixture.source -ne "teamsAutomatic" -or $canonicalFixture.participants.Count -lt 1) {
    throw "The cross-platform canonical fixture must describe a Teams automatic recording with participants."
}

$windowsFixture = Read-JsonObject $windowsFixturePath
if ($windowsFixture.source -ne "manual" -or $null -eq $windowsFixture.participants -or $windowsFixture.participants.Count -ne 0) {
    throw "The Windows fixture must describe a manual recording with an empty participants array."
}

$fixturePaths = @($canonicalFixtures.FullName) + @($windowsFixturePath)
& dotnet run --project $validatorProject --configuration Release -- $schemaPath @fixturePaths
if ($LASTEXITCODE -ne 0) {
    throw "Draft 2020-12 recording-session schema validation failed."
}

Write-Host "Validated canonical Draft 2020-12 recording-session schema against $($fixturePaths.Count) cross-platform and Windows fixtures."
