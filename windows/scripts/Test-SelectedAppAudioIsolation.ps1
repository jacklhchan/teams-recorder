[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $TargetToneProgram,

    [string[]] $TargetToneArguments = @(),

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $TargetToneLabel,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $DistractorToneProgram,

    [string[]] $DistractorToneArguments = @(),

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $DistractorToneLabel,

    [ValidateRange(1, 300)]
    [int] $OverlapSeconds = 10,

    [ValidateRange(1, 120)]
    [int] $PostTargetExitObservationSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Start-ToneEmitter {
    param(
        [Parameter(Mandatory)]
        [string] $Program,

        [string[]] $Arguments = @(),

        [Parameter(Mandatory)]
        [string] $Role
    )

    if (-not (Test-Path -LiteralPath $Program -PathType Leaf)) {
        throw "$Role tone emitter was not found. Supply a valid executable path."
    }

    # Do not log Program or Arguments: they can contain sensitive paths or command-line data.
    return Start-Process -FilePath $Program -ArgumentList $Arguments -PassThru
}

function Stop-StartedEmitter {
    param([System.Diagnostics.Process] $Process)

    if ($null -eq $Process) {
        return
    }

    try {
        if (-not $Process.HasExited) {
            Stop-Process -Id $Process.Id -ErrorAction SilentlyContinue
            $Process.WaitForExit()
        }
    }
    catch {
        # Cleanup is best effort: do not obscure the original manual-test error.
    }
}

$target = $null
$distractor = $null

try {
    Write-Host 'Selected App manual isolation exercise — PR Draft only.'
    Write-Host 'This script starts caller-supplied tone emitters but does not inspect the product or judge isolation.'
    Write-Host 'Do not treat process launch or exit codes as a pass result.'
    Write-Host ''
    Write-Host "Known target tone label: $TargetToneLabel"
    Write-Host "Known distractor tone label: $DistractorToneLabel"

    $target = Start-ToneEmitter -Program $TargetToneProgram -Arguments $TargetToneArguments -Role 'Target'
    Write-Host "Target tone emitter started (PID $($target.Id))."
    Write-Host 'In the product, refresh the process picker, select this target, and begin Selected App recording.'
    $null = Read-Host 'Press Enter only after target selection and recording have started'

    $distractor = Start-ToneEmitter -Program $DistractorToneProgram -Arguments $DistractorToneArguments -Role 'Distractor'
    Write-Host 'Distractor tone emitter started. Verify both tones overlap, then inspect only the selected-app recording and meter.'
    Write-Host ''
    Write-Host 'Required manual evidence (record only in the approved evidence system):'
    Write-Host '  1. UTC time, Windows/product build, endpoint and sample rate.'
    Write-Host '  2. Anonymous target/distractor roles, overlap duration, UI selection, meter/health, and recording observation.'
    Write-Host '  3. End the target emitter while the distractor remains active; capture the unavailable/stopped UI and recording behaviour.'
    Write-Host '  4. Record HRESULT, dropped buffers, disconnects, or exceptions if present.'
    Write-Host 'Do not persist credentials, executable paths, command lines, or audio content in evidence.'
    Write-Host ''
    Write-Host 'Manual gate: target-only signal during overlap AND no silent system-audio fallback after target exit.'
    Write-Host "Keep both tones running for $OverlapSeconds seconds while inspecting the target-only recording."
    Start-Sleep -Seconds $OverlapSeconds

    if (-not $target.HasExited) {
        Stop-Process -Id $target.Id -ErrorAction Stop
        $target.WaitForExit()
    }

    Write-Host "Target process terminated. Keep the distractor running for $PostTargetExitObservationSeconds seconds."
    Write-Host 'Verify the product shows unavailable/stopped, preserves recovery evidence, and does not switch to system loopback.'
    Start-Sleep -Seconds $PostTargetExitObservationSeconds
    Write-Host 'RESULT: No isolation verdict was produced. The operator must record Pass, Fail, or Inconclusive manually.'
}
finally {
    # These are the only processes created by this invocation. Their paths,
    # arguments, credentials, recordings, and evidence are never written.
    Stop-StartedEmitter -Process $target
    Stop-StartedEmitter -Process $distractor
}
