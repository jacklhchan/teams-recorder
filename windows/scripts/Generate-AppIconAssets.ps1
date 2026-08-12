[CmdletBinding()]
param(
    [string]$Source,
    [string]$Destination
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

if ([string]::IsNullOrWhiteSpace($Source)) {
    $Source = Join-Path $PSScriptRoot "..\..\Assets\Generated\app-icon-source.png"
}

if ([string]::IsNullOrWhiteSpace($Destination)) {
    $Destination = Join-Path $PSScriptRoot "..\src\Recorder.WinUI\Assets"
}

function Save-SquarePng {
    param(
        [Parameter(Mandatory)] [System.Drawing.Image]$Image,
        [Parameter(Mandatory)] [int]$Size,
        [Parameter(Mandatory)] [string]$Path
    )

    $bitmap = [System.Drawing.Bitmap]::new($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([System.Drawing.Color]::Transparent)
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $graphics.DrawImage($Image, 0, 0, $Size, $Size)
        }
        finally {
            $graphics.Dispose()
        }

        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $bitmap.Dispose()
    }
}

function Save-WidePng {
    param(
        [Parameter(Mandatory)] [System.Drawing.Image]$Image,
        [Parameter(Mandatory)] [int]$Width,
        [Parameter(Mandatory)] [int]$Height,
        [Parameter(Mandatory)] [string]$Path
    )

    $bitmap = [System.Drawing.Bitmap]::new($Width, $Height, [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([System.Drawing.Color]::Transparent)
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $size = [Math]::Min($Width, $Height)
            $graphics.DrawImage($Image, [int](($Width - $size) / 2), [int](($Height - $size) / 2), $size, $size)
        }
        finally {
            $graphics.Dispose()
        }

        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $bitmap.Dispose()
    }
}

function New-IcoFromPngs {
    param(
        [Parameter(Mandatory)] [string[]]$PngPaths,
        [Parameter(Mandatory)] [string]$Path
    )

    $entries = foreach ($pngPath in $PngPaths) {
        $bytes = [System.IO.File]::ReadAllBytes($pngPath)
        $image = [System.Drawing.Image]::FromFile($pngPath)
        try {
            [PSCustomObject]@{ Width = $image.Width; Height = $image.Height; Bytes = $bytes }
        }
        finally {
            $image.Dispose()
        }
    }

    $stream = [System.IO.File]::Create($Path)
    $writer = [System.IO.BinaryWriter]::new($stream)
    try {
        $writer.Write([UInt16]0)
        $writer.Write([UInt16]1)
        $writer.Write([UInt16]$entries.Count)
        $offset = 6 + (16 * $entries.Count)
        foreach ($entry in $entries) {
            $writer.Write([byte]$(if ($entry.Width -ge 256) { 0 } else { $entry.Width }))
            $writer.Write([byte]$(if ($entry.Height -ge 256) { 0 } else { $entry.Height }))
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([UInt16]1)
            $writer.Write([UInt16]32)
            $writer.Write([UInt32]$entry.Bytes.Length)
            $writer.Write([UInt32]$offset)
            $offset += $entry.Bytes.Length
        }
        foreach ($entry in $entries) {
            $writer.Write($entry.Bytes)
        }
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

$sourcePath = [System.IO.Path]::GetFullPath($Source)
$destinationPath = [System.IO.Path]::GetFullPath($Destination)
if (-not (Test-Path -LiteralPath $sourcePath)) {
    throw "The macOS icon source was not found: $sourcePath"
}

[System.IO.Directory]::CreateDirectory($destinationPath) | Out-Null
$sourceImage = [System.Drawing.Image]::FromFile($sourcePath)
try {
    Save-SquarePng $sourceImage 300 (Join-Path $destinationPath 'Square150x150Logo.scale-200.png')
    Save-SquarePng $sourceImage 88 (Join-Path $destinationPath 'Square44x44Logo.scale-200.png')
    Save-SquarePng $sourceImage 48 (Join-Path $destinationPath 'Square44x44Logo.targetsize-24_altform-unplated.png')
    Save-SquarePng $sourceImage 48 (Join-Path $destinationPath 'Square44x44Logo.targetsize-48_altform-lightunplated.png')
    Save-SquarePng $sourceImage 48 (Join-Path $destinationPath 'LockScreenLogo.scale-200.png')
    Save-SquarePng $sourceImage 50 (Join-Path $destinationPath 'StoreLogo.png')
    Save-WidePng $sourceImage 620 300 (Join-Path $destinationPath 'Wide310x150Logo.scale-200.png')
    Save-WidePng $sourceImage 1240 600 (Join-Path $destinationPath 'SplashScreen.scale-200.png')

    $iconPngs = @(
        (Join-Path $env:TEMP 'TeamsRecorderIcon-16.png'),
        (Join-Path $env:TEMP 'TeamsRecorderIcon-32.png'),
        (Join-Path $env:TEMP 'TeamsRecorderIcon-48.png'),
        (Join-Path $env:TEMP 'TeamsRecorderIcon-256.png')
    )
    try {
        Save-SquarePng $sourceImage 16 $iconPngs[0]
        Save-SquarePng $sourceImage 32 $iconPngs[1]
        Save-SquarePng $sourceImage 48 $iconPngs[2]
        Save-SquarePng $sourceImage 256 $iconPngs[3]
        New-IcoFromPngs $iconPngs (Join-Path $destinationPath 'AppIcon.ico')
    }
    finally {
        Remove-Item -LiteralPath $iconPngs -Force -ErrorAction SilentlyContinue
    }
}
finally {
    $sourceImage.Dispose()
}

Write-Host "Generated Windows app icon assets from $sourcePath"
