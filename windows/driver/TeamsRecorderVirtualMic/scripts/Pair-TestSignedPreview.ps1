[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateLength(1, 1024)]
    [string]$EndpointId
)

$ErrorActionPreference = "Stop"
if ($EndpointId.IndexOf([char]0) -ge 0 -or [string]::IsNullOrWhiteSpace($EndpointId)) {
    throw "-EndpointId must be the exact non-empty Core Audio capture endpoint ID allocated by Windows."
}

$pairingRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Teams Recorder'
$pairingPath = Join-Path $pairingRoot 'virtual-microphone.json'
$temporary = "$pairingPath.tmp-$([Guid]::NewGuid().ToString('N'))"
$document = [ordered]@{
    schemaVersion = 1
    endpointId = $EndpointId
    hardwareId = 'ROOT\TeamsRecorderVirtualMic'
    friendlyName = 'Teams Recorder Virtual Microphone'
}

try {
    New-Item -ItemType Directory -Path $pairingRoot -Force | Out-Null
    $document | ConvertTo-Json -Compress | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM -NoNewline
    Move-Item -LiteralPath $temporary -Destination $pairingPath -Force
}
finally {
    if (Test-Path -LiteralPath $temporary) {
        Remove-Item -LiteralPath $temporary -Force
    }
}

Write-Host "Paired the exact virtual microphone endpoint for the current Windows user."
Write-Host "Pairing file: $pairingPath"
