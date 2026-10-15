<#
    make-icon.ps1 - generates the UNLOCK DIGITAL brand icon (AdskDoctor.ico)
    A stylised "open padlock" in the brand colours (black + red).
    Also writes a preview PNG so it can be reviewed.
#>
[CmdletBinding()]
param(
    [string]$OutIco,
    [string]$OutPng
)

if (-not $OutIco) { $OutIco = Join-Path $PSScriptRoot 'AdskDoctor.ico' }
if (-not $OutPng) { $OutPng = Join-Path $PSScriptRoot 'icon-preview.png' }

Add-Type -AssemblyName System.Drawing

$Red   = [System.Drawing.Color]::FromArgb(228, 30, 46)
$Black = [System.Drawing.Color]::FromArgb(17, 18, 20)

function Add-RoundedRect {
    param($Path, [single]$x, [single]$y, [single]$w, [single]$h, [single]$r)
    $d = $r * 2
    $Path.AddArc($x,        $y,        $d, $d, 180, 90)
    $Path.AddArc($x + $w - $d, $y,      $d, $d, 270, 90)
    $Path.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $Path.AddArc($x,        $y + $h - $d, $d, $d, 90, 90)
    $Path.CloseFigure()
}

function New-LockBitmap {
    param([int]$size)
    $S   = [single]$size
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    # ---- shackle (open on the right) ----
    $pen = New-Object System.Drawing.Pen($Red, ($S * 0.12))
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
    $sw = $S * 0.46; $sh = $S * 0.42
    $sx = ($S - $sw) / 2; $sy = $S * 0.06
    # arc: left-middle -> over the top -> upper-right (the gap on the right = open)
    $g.DrawArc($pen, $sx, $sy, $sw, $sh, 180, 165)
    # left leg down onto the body
    $g.DrawLine($pen, $sx, ($sy + $sh * 0.5), $sx, ($sy + $sh * 0.92))
    $pen.Dispose()

    # ---- body ----
    $bw = $S * 0.60; $bh = $S * 0.46
    $bx = ($S - $bw) / 2; $by = $S * 0.44
    $body = New-Object System.Drawing.Drawing2D.GraphicsPath
    Add-RoundedRect $body $bx $by $bw $bh ($S * 0.10)
    $g.FillPath((New-Object System.Drawing.SolidBrush($Black)), $body)
    $g.DrawPath((New-Object System.Drawing.Pen($Red, ($S * 0.03))), $body)

    # ---- keyhole ----
    $kcx = $S * 0.5; $kcy = $by + $bh * 0.40
    $kd  = $S * 0.16
    $g.FillEllipse((New-Object System.Drawing.SolidBrush($Red)), ($kcx - $kd/2), ($kcy - $kd/2), $kd, $kd)
    $stem = New-Object System.Drawing.Drawing2D.GraphicsPath
    Add-RoundedRect $stem ($kcx - $S*0.035) ($kcy) ($S*0.07) ($bh*0.42) ($S*0.02)
    $g.FillPath((New-Object System.Drawing.SolidBrush($Red)), $stem)

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
    $bw.Close(); $ms.Close()
}

$sizes = @(16, 32, 48, 64, 128, 256)
$bms = @($sizes | ForEach-Object { New-LockBitmap -size $_ })
Save-Ico -Bitmaps $bms -Path $OutIco
$big = New-LockBitmap -size 256
$big.Save($OutPng, [System.Drawing.Imaging.ImageFormat]::Png)
foreach ($b in $bms) { $b.Dispose() }
$big.Dispose()

Write-Host ("ICO written : {0}" -f $OutIco)
Write-Host ("PNG written : {0}" -f $OutPng)
