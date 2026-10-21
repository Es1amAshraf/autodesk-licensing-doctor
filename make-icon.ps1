<#
    make-icon.ps1 - builds the AdskDoctor Windows icon from the approved artwork.

    The master artwork is design\brand\adskdoctor-icon.svg, rendered once to
    adskdoctor-logo.png (512 x 512, transparent corners). This script only
    downscales that master and packs a multi-resolution .ico, so every size
    keeps the exact approved shield / wrench / check mark.

    Usage:
        .\make-icon.ps1
        .\make-icon.ps1 -Source adskdoctor-logo.png -OutIco AdskDoctor.ico
#>
[CmdletBinding()]
param(
    [string]$Source,
    [string]$OutIco,
    [string]$OutPng
)

if (-not $Source) { $Source = Join-Path $PSScriptRoot 'adskdoctor-logo.png' }
if (-not $OutIco) { $OutIco = Join-Path $PSScriptRoot 'AdskDoctor.ico' }
if (-not $OutPng) { $OutPng = Join-Path $PSScriptRoot 'icon-preview.png' }

Add-Type -AssemblyName System.Drawing

if (-not (Test-Path -LiteralPath $Source)) {
    throw "Master logo not found: $Source"
}

$src = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $Source).Path)
if ($src.Width -lt 256 -or $src.Height -lt 256) {
    $src.Dispose()
    throw "Master logo must be at least 256 x 256 (got $($src.Width) x $($src.Height))."
}

# High-quality downscale with a transparent-aware edge mode. A plain
# HighQualityBicubic resize leaves a dark halo around transparent corners.
function Resize-Icon {
    param([System.Drawing.Image]$Image, [int]$Size)
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CompositingMode    = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $g.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $attr = New-Object System.Drawing.Imaging.ImageAttributes
    $attr.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
    $rect = New-Object System.Drawing.Rectangle(0, 0, $Size, $Size)
    $g.DrawImage($Image, $rect, 0, 0, $Image.Width, $Image.Height,
                 [System.Drawing.GraphicsUnit]::Pixel, $attr)
    $attr.Dispose()
    $g.Dispose()
    return $bmp
}

function Save-Ico {
    param([System.Drawing.Bitmap[]]$Bitmaps, [string]$Path)
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$Bitmaps.Count)
    $pngs = @()
    foreach ($b in $Bitmaps) {
        $pms = New-Object System.IO.MemoryStream
        $b.Save($pms, [System.Drawing.Imaging.ImageFormat]::Png)
        $pngs += ,$pms.ToArray()
        $pms.Dispose()
    }
    $offset = 6 + 16 * $Bitmaps.Count
    for ($i = 0; $i -lt $Bitmaps.Count; $i++) {
        $w = $Bitmaps[$i].Width; $png = $pngs[$i]
        $bw.Write([byte]$(if ($w -ge 256) { 0 } else { $w }))
        $bw.Write([byte]$(if ($w -ge 256) { 0 } else { $w }))
        $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([UInt16]1); $bw.Write([UInt16]32)
        $bw.Write([UInt32]$png.Length); $bw.Write([UInt32]$offset)
        $offset += $png.Length
    }
    foreach ($png in $pngs) { $bw.Write($png) }
    $bw.Flush()
    [System.IO.File]::WriteAllBytes($Path, $ms.ToArray())
    $bw.Dispose(); $ms.Dispose()
}

$sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
$bitmaps = @($sizes | ForEach-Object { Resize-Icon -Image $src -Size $_ })
Save-Ico -Bitmaps $bitmaps -Path $OutIco

$preview = Resize-Icon -Image $src -Size 256
$preview.Save($OutPng, [System.Drawing.Imaging.ImageFormat]::Png)
$preview.Dispose()

foreach ($b in $bitmaps) { $b.Dispose() }
$src.Dispose()

Write-Host ("ICO written : {0}" -f $OutIco)
Write-Host ("PNG written : {0}" -f $OutPng)
