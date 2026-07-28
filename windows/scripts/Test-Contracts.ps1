[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$contractsRoot = Join-Path $PSScriptRoot "..\contracts"
$jsonFiles = Get-ChildItem -LiteralPath $contractsRoot -Filter "*.json" -Recurse

if ($jsonFiles.Count -lt 6) {
    throw "Expected at least six contract, schema, and fixture JSON files."
}

foreach ($file in $jsonFiles) {
    $null = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
}

$legacyMetadataPath = Join-Path $contractsRoot "fixtures\recording-info.macos-legacy.json"
$legacyMetadata = Get-Content -LiteralPath $legacyMetadataPath -Raw | ConvertFrom-Json
if ($null -ne $legacyMetadata.schemaVersion) {
    throw "The legacy fixture must not contain schemaVersion."
}
if ($legacyMetadata.mediaKind -ne "video" -or $legacyMetadata.screenIntervals.Count -ne 1) {
    throw "The legacy video metadata fixture is incomplete."
}

$windowsMetadataPath = Join-Path $contractsRoot "fixtures\recording-info.windows-v1.json"
$windowsMetadata = Get-Content -LiteralPath $windowsMetadataPath -Raw | ConvertFrom-Json
if ($windowsMetadata.schemaVersion -ne 1 -or $windowsMetadata.mediaKind -ne "audio") {
    throw "The Windows v1 metadata fixture does not match the v1 contract."
}

$meetingEpochPath = Join-Path $contractsRoot "fixtures\teams-meeting-epoch.json"
$meetingEpoch = Get-Content -LiteralPath $meetingEpochPath -Raw | ConvertFrom-Json
if ($meetingEpoch.expected.stopCommandCount -ne 0) {
    throw "The rejoin fixture must not expect an automatic stop."
}

Write-Host "Validated $($jsonFiles.Count) JSON contract and fixture files."
