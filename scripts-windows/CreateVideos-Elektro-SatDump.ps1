<#
.SYNOPSIS
    Creates Elektro-L3 SatDump LRIT timelapse videos from SatDump V2 Live Output.

.DESCRIPTION
    Recursively searches the Live Output folder, including every dated SatDump
    reception session, for the six MSU-GS PNG products. The timestamp is read
    from the dated folder immediately containing each PNG
    (yyyy-MM-dd_HH-mm-ss).

    Requires FFmpeg (ffmpeg.exe) with the libx264 encoder.

.EXAMPLE
    .\CreateVideos-Elektro-SatDump.ps1 -Source "D:\SatDump\Live Output"

.EXAMPLE
    .\CreateVideos-Elektro-SatDump.ps1 -Source "D:\SatDump\Live Output" `
        -Output "D:\Vitality-GOES\html\videos" -DaysBack 3 -FrameRate 5
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$Source,

    <#[string]$Output = (Join-Path $PSScriptRoot 'Elektro-Videos'),#>
	[string]$Output = $PSScriptRoot,

    [ValidateRange(1, 3650)]
    [int]$DaysBack = 7,

    [ValidateRange(1, 60)]
    [int]$FrameRate = 5,

    # Optional full path to ffmpeg.exe. If omitted, FFmpeg must be on PATH.
    [string]$FFmpeg = 'ffmpeg.exe'
)

$ErrorActionPreference = 'Stop'

$products = @(
    [pscustomobject]@{
        Name = 'Thermal-IR'
        File = 'msu_gs_10.8um_Thermal_IR_(Uncalibrated).png'
    },
    [pscustomobject]@{
        Name = 'AVHRR-221-False-Colour'
        File = 'msu_gs_AVHRR_221_False_Color.png'
    },
    [pscustomobject]@{
        Name = 'False-Colour-IR-Underlay'
        File = 'msu_gs_False_Color_+_IR_Underlay.png'
    },
    [pscustomobject]@{
        Name = 'MCIR'
        File = 'msu_gs_MCIR.png'
    },
    [pscustomobject]@{
        Name = 'MSU-GS-321-False-Colour'
        File = 'msu_gs_MSU-GS_321_False_Color.png'
    },
    [pscustomobject]@{
        Name = 'Natural-Colour'
        File = 'msu_gs_Natural_Color.png'
    }
)

# Resolve FFmpeg before doing any work.
$ffmpegCommand = Get-Command $FFmpeg -ErrorAction SilentlyContinue
if (-not $ffmpegCommand) {
    throw "FFmpeg was not found. Install FFmpeg and add ffmpeg.exe to PATH, or pass -FFmpeg with its full path."
}
$ffmpegPath = $ffmpegCommand.Source
if (-not $ffmpegPath) { $ffmpegPath = $ffmpegCommand.Definition }

$sourcePath = (Resolve-Path -LiteralPath $Source).Path
New-Item -ItemType Directory -Path $Output -Force | Out-Null
$outputPath = (Resolve-Path -LiteralPath $Output).Path

$cutoff = (Get-Date).AddDays(-$DaysBack)
Write-Host "Source:      $sourcePath"
Write-Host "Output:      $outputPath"
Write-Host "Date range:  $cutoff onwards"
Write-Host "Frame rate:  $FrameRate fps"
Write-Host ''

# Find images only within the Elektro-L3 IMAGES branch. The recursive search
# naturally includes every reception folder created by SatDump restarts.
$allPngs = Get-ChildItem -LiteralPath $sourcePath -Filter '*.png' -File -Recurse |
    Where-Object {
        $_.FullName -match '[\\/]IMAGES[\\/]ELEKTRO-L3[\\/]'
    }

foreach ($product in $products) {
    Write-Host "Processing $($product.Name) ..."

    $frames = foreach ($file in $allPngs) {
        if ($file.Name -ieq $product.File) {
            # SatDump V2's immediate parent directory is yyyy-MM-dd_HH-mm-ss.
            $timestamp = [datetime]::MinValue
            $parsed = [datetime]::TryParseExact(
                $file.Directory.Name,
                'yyyy-MM-dd_HH-mm-ss',
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeLocal,
                [ref]$timestamp
            )

            if (-not $parsed) {
                Write-Warning "Skipping image with an unexpected parent-folder timestamp: $($file.FullName)"
                continue
            }

            if ($timestamp -ge $cutoff) {
                [pscustomobject]@{
                    Timestamp = $timestamp
                    File      = $file
                }
            }
        }
    }

    $frames = @($frames | Sort-Object Timestamp, @{ Expression = { $_.File.FullName } })

    if ($frames.Count -eq 0) {
        Write-Warning "No matching images found for $($product.Name) in the last $DaysBack days."
        continue
    }

    # If more than one reception session contains the same product timestamp,
    # keep the first chronological entry only once.
    $frames = @($frames | Group-Object Timestamp | ForEach-Object {
        $_.Group | Select-Object -First 1
    } | Sort-Object Timestamp)

    $safeName = $product.Name -replace '[^A-Za-z0-9_-]', '_'
    $videoPath = Join-Path $outputPath ("Elektro-L3_{0}_{1}.mp4" -f $safeName, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $tempPath = Join-Path $env:TEMP ("ElektroSatDump_" + [guid]::NewGuid().ToString('N'))

    New-Item -ItemType Directory -Path $tempPath -Force | Out-Null

    try {
        # Use numbered copies so FFmpeg receives frames in the timestamp order.
        for ($i = 0; $i -lt $frames.Count; $i++) {
            $frameName = 'frame_{0:D6}.png' -f ($i + 1)
            Copy-Item -LiteralPath $frames[$i].File.FullName -Destination (Join-Path $tempPath $frameName)
        }

        $inputPattern = Join-Path $tempPath 'frame_%06d.png'
        $filter = 'scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p'

        $ffmpegArgs = @(
            '-hide_banner',
            '-y',
            '-framerate', "$FrameRate",
            '-i', $inputPattern,
            '-vf', $filter,
            '-c:v', 'libx264',
            '-preset', 'medium',
            '-crf', '18',
            '-pix_fmt', 'yuv420p',
            '-movflags', '+faststart',
            $videoPath
        )

        & $ffmpegPath @ffmpegArgs
        if ($LASTEXITCODE -ne 0) {
            throw "FFmpeg failed for $($product.Name) with exit code $LASTEXITCODE."
        }

        Write-Host ("Created: {0} ({1} frames, {2} to {3})" -f
            $videoPath, $frames.Count,
            $frames[0].Timestamp.ToString('yyyy-MM-dd HH:mm:ss'),
            $frames[-1].Timestamp.ToString('yyyy-MM-dd HH:mm:ss')) -ForegroundColor Green
    }
    finally {
        Remove-Item -LiteralPath $tempPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ''
}

Write-Host 'Finished processing Elektro-L3 images.' -ForegroundColor Green
