<#
  make-logo-icon.ps1  -  UNLOCK DIGITAL
  Converts a PNG logo into a multi-size .ico (16..256) for Windows
  shortcuts and installers.

  Usage:  .\make-logo-icon.ps1 -Source unlock-logo.png -Dest unlock-logo.ico
#>
[CmdletBinding()]
param(
    [string]$Source = 'unlock-logo.png',
    [string]$Dest   = 'unlock-logo.ico',
    [int[]]$Sizes   = @(16,24,32,48,64,128,256)
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not [System.IO.Path]::IsPathRooted($Source)) { $Source = Join-Path $root $Source }
if (-not [System.IO.Path]::IsPathRooted($Dest))   { $Dest   = Join-Path $root $Dest }

if (-not (Test-Path -LiteralPath $Source)) { throw "Source image not found: $Source" }

Add-Type -AssemblyName System.Drawing

$src = [System.Drawing.Image]::FromFile($Source)
$pngs = New-Object System.Collections.Generic.List[byte[]]

foreach ($s in $Sizes) {
    $bmp = New-Object System.Drawing.Bitmap($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.DrawImage($src, (New-Object System.Drawing.Rectangle(0, 0, $s, $s)))
    $g.Dispose()

    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $pngs.Add($ms.ToArray())
    $ms.Dispose()
}
$src.Dispose()

# ---- assemble .ico (PNG-compressed entries; supported by Windows Vista+) ----
$fs = [System.IO.File]::Create($Dest)
$bw = New-Object System.IO.BinaryWriter($fs)

$bw.Write([UInt16]0)                 # reserved
$bw.Write([UInt16]1)                 # type = icon
$bw.Write([UInt16]$Sizes.Count)      # image count

$offset = 6 + (16 * $Sizes.Count)
for ($i = 0; $i -lt $Sizes.Count; $i++) {
    $s = $Sizes[$i]
    $bw.Write([Byte]($(if ($s -ge 256) { 0 } else { $s })))   # width
    $bw.Write([Byte]($(if ($s -ge 256) { 0 } else { $s })))   # height
    $bw.Write([Byte]0)               # palette
    $bw.Write([Byte]0)               # reserved
    $bw.Write([UInt16]1)             # color planes
    $bw.Write([UInt16]32)            # bits per pixel
    $bw.Write([UInt32]$pngs[$i].Length)
    $bw.Write([UInt32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $bw.Write($p) }

$bw.Flush(); $bw.Close(); $fs.Close()

Write-Host ("Created {0}  ({1} bytes, sizes: {2})" -f (Split-Path $Dest -Leaf), (Get-Item $Dest).Length, ($Sizes -join ',')) -ForegroundColor Green
