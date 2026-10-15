<#
  Build-Release.ps1  -  UNLOCK DIGITAL  -  Autodesk Licensing Doctor
  ------------------------------------------------------------------
  Creates a release for a given version and stores THREE zipped forms:

    1) PROJECT   -> AdskDoctor-v<ver>-Project.zip   (source files)
    2) PORTABLE  -> AdskDoctor-v<ver>-Portable.zip  (run from anywhere, no install)
    3) SETUP     -> AdskDoctor-v<ver>-Setup.zip     (installer package)

  Plus a per-version record (RELEASE-RECORD.txt + manifest.json + SHA256SUMS)
  and an entry appended to RELEASES.md.

  Examples
    .\Build-Release.ps1 -Version 1.2.0
    .\Build-Release.ps1 -Version 1.2.1 -Notes "Fixed ADLS reset" -Recompile
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,

    [string]$Notes = '',

    # Re-encode the GUI script (UTF-8 BOM, required for Arabic) and recompile the exe
    [switch]$Recompile,

    # Open the release folder when done
    [switch]$Open
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }

function Write-Step($m) { Write-Host ("  [*] " + $m) -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host ("  [v] " + $m) -ForegroundColor Green }
function Write-Warn2($m){ Write-Host ("  [!] " + $m) -ForegroundColor Yellow }

function Save-Text {
    param([string]$Path, [string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($true)   # UTF-8 with BOM (Arabic-safe)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function New-BomFile {
    param([string]$Path)
    $c = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($Path, $c, (New-Object System.Text.UTF8Encoding($true)))
}

# ---------------------------------------------------------------------------
# 0) sanity: required files
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "UNLOCK DIGITAL - Autodesk Licensing Doctor" -ForegroundColor White
Write-Host ("Building release v" + $Version) -ForegroundColor White
Write-Host ""

$gui        = Join-Path $root 'AdskDoctor-GUI.ps1'
$exeName    = 'UNLOCK-DIGITAL-AdskDoctor.exe'
$exe        = Join-Path $root $exeName
$icon       = Join-Path $root 'AdskDoctor.ico'
$runtimeScripts = @('AdskDoctor.ps1','Backup.ps1','Clean.ps1','Repair.ps1')
$sourceScripts  = @('AdskDoctor.ps1','Backup.ps1','Clean.ps1','Repair.ps1','AdskDoctor-GUI.ps1','make-icon.ps1','Build-Release.ps1')
$launchers      = @('Run-Diagnostic.cmd','Run-Backup.cmd')
$installerFiles = @('Install.ps1','Install.cmd','Uninstall.ps1','Uninstall.cmd')

$required = @('AdskDoctor-GUI.ps1') + $runtimeScripts + @('AdskDoctor.ico')
$missing  = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root $_)) })
if ($missing.Count) { throw ("Missing required file(s): " + ($missing -join ', ')) }

# ---------------------------------------------------------------------------
# 1) optional: recompile the exe from the (BOM-encoded) GUI source
# ---------------------------------------------------------------------------
if ($Recompile) {
    Write-Step "Re-encoding GUI (UTF-8 BOM) and recompiling exe ..."
    New-BomFile $gui
    $cmd = "Import-Module ps2exe; Invoke-PS2EXE -inputFile '$gui' -outputFile '$exe' -iconFile '$icon' " +
           "-STA -noConsole -requireAdmin -x64 -title 'Autodesk Licensing Doctor' " +
           "-description 'Autodesk licensing cleanup and repair' -company 'UNLOCK DIGITAL' " +
           "-product 'Autodesk Licensing Doctor' -copyright 'Unlock Digital - By Eng. Eslam Ashraf' " +
           "-version '$Version.0'"
    powershell -NoProfile -ExecutionPolicy Bypass -Command $cmd | Out-Null
    if (-not (Test-Path $exe)) { throw "Recompile failed: exe not produced." }
    Write-Ok ("Compiled " + $exeName)
}
if (-not (Test-Path $exe)) { throw "Executable not found: $exe  (run once with -Recompile)" }

# ---------------------------------------------------------------------------
# 2) staging
# ---------------------------------------------------------------------------
$releaseDir = Join-Path $root ("releases\v" + $Version)
if (Test-Path $releaseDir) { Remove-Item $releaseDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null

$stage = Join-Path $env:TEMP ("adsk_release_" + [guid]::NewGuid().ToString('N'))
$sProj = Join-Path $stage 'project'
$sPort = Join-Path $stage 'portable'
$sSetup = Join-Path $stage 'setup'
$sPayload = Join-Path $sSetup 'payload'
New-Item -ItemType Directory -Force -Path $sProj,$sPort,$sSetup,$sPayload | Out-Null

Write-Step "Staging files ..."

# shared: brand logo (png preferred, else existing)
$logoPng = Join-Path $root 'unlock-logo.png'

# --- 2a) PROJECT -----------------------------------------------------------
foreach ($f in $sourceScripts) {
    $src = Join-Path $root $f
    if (Test-Path $src) { Copy-Item $src $sProj -Force }
}
foreach ($f in $launchers) {
    $src = Join-Path $root $f
    if (Test-Path $src) { Copy-Item $src $sProj -Force }
}
Copy-Item $icon $sProj -Force
if (Test-Path (Join-Path $root 'README.md')) { Copy-Item (Join-Path $root 'README.md') $sProj -Force }
if (Test-Path $logoPng) { Copy-Item $logoPng $sProj -Force }
$instDirSrc = Join-Path $root 'installer'
if (Test-Path $instDirSrc) {
    $d = Join-Path $sProj 'installer'
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    Copy-Item (Join-Path $instDirSrc '*') $d -Force
}

# --- 2b) PORTABLE ----------------------------------------------------------
Copy-Item $exe $sPort -Force
foreach ($f in $runtimeScripts) { Copy-Item (Join-Path $root $f) $sPort -Force }
Copy-Item $icon $sPort -Force
if (Test-Path $logoPng) { Copy-Item $logoPng $sPort -Force }
foreach ($f in $launchers) {
    $src = Join-Path $root $f
    if (Test-Path $src) { Copy-Item $src $sPort -Force }
}
if (Test-Path (Join-Path $root 'README.md')) { Copy-Item (Join-Path $root 'README.md') $sPort -Force }

$portableReadme = @"
UNLOCK DIGITAL - Autodesk Licensing Doctor  (PORTABLE v$Version)
=================================================================
No installation required. Just run:  $exeName
(Right-click -> "Run as administrator", or accept the UAC prompt.)

Keep ALL files in this folder together - the app calls the .ps1 scripts
that sit next to the .exe.
"@
Save-Text (Join-Path $sPort 'PORTABLE-READ-ME.txt') $portableReadme

# --- 2c) SETUP -------------------------------------------------------------
# payload = the portable runtime
Copy-Item $exe $sPayload -Force
foreach ($f in $runtimeScripts) { Copy-Item (Join-Path $root $f) $sPayload -Force }
Copy-Item $icon $sPayload -Force
if (Test-Path $logoPng) { Copy-Item $logoPng $sPayload -Force }
foreach ($f in $launchers) {
    $src = Join-Path $root $f
    if (Test-Path $src) { Copy-Item $src $sPayload -Force }
}

# installer scripts (from installer\ folder); fall back to embedded copies
foreach ($f in $installerFiles) {
    $src = Join-Path $instDirSrc $f
    if (Test-Path $src) { Copy-Item $src $sSetup -Force }
    else { throw "Installer file missing: $src" }
}

$setupReadme = @"
UNLOCK DIGITAL - Autodesk Licensing Doctor  (SETUP v$Version)
==============================================================
1. Extract this ZIP anywhere.
2. Right-click  Install.cmd  ->  Run as administrator
   (or just double-click and accept the UAC prompt)
3. Launch it from the Desktop / Start Menu shortcut:
     "Autodesk Licensing Doctor"

Installs to:  %ProgramFiles%\UNLOCK DIGITAL\AdskDoctor
Removes with: Settings > Apps  (or Uninstall.cmd)
"@
Save-Text (Join-Path $sSetup 'SETUP-READ-ME.txt') $setupReadme

# ---------------------------------------------------------------------------
# 3) zip the three forms
# ---------------------------------------------------------------------------
function New-Zip {
    param([string]$SourceDir, [string]$DestZip)
    if (Test-Path $DestZip) { Remove-Item $DestZip -Force }
    Compress-Archive -Path (Join-Path $SourceDir '*') -DestinationPath $DestZip -CompressionLevel Optimal -Force
}

$zipProject  = Join-Path $releaseDir ("AdskDoctor-v$Version-Project.zip")
$zipPortable = Join-Path $releaseDir ("AdskDoctor-v$Version-Portable.zip")
$zipSetup    = Join-Path $releaseDir ("AdskDoctor-v$Version-Setup.zip")

Write-Step "Creating ZIPs ..."
New-Zip $sProj  $zipProject
New-Zip $sPort  $zipPortable
New-Zip $sSetup $zipSetup
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# 4) record (hashes + manifest + changelog)
# ---------------------------------------------------------------------------
$zips = @($zipProject, $zipPortable, $zipSetup)
$hashLines = @()
foreach ($z in $zips) {
    $hashLines += ("{0}  {1}" -f (Get-Sha256 $z), (Split-Path $z -Leaf))
}
Save-Text (Join-Path $releaseDir 'SHA256SUMS.txt') (($hashLines -join "`r`n") + "`r`n")

$built = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$ver   = (Get-Item $exe).VersionInfo
$record = @"
=========================================================
 UNLOCK DIGITAL - Autodesk Licensing Doctor
 RELEASE RECORD
=========================================================
 Version        : $Version
 Built (local)  : $built
 Company        : UNLOCK DIGITAL
 Copyright      : Unlock Digital - By Eng. Eslam Ashraf
 exe FileVersion: $($ver.FileVersion)
 exe Size       : $([math]::Round((Get-Item $exe).Length/1KB,1)) KB

 Notes:
 $Notes

 Files:
$(($zips | ForEach-Object { "   - " + (Split-Path $_ -Leaf) + "  (" + [math]::Round((Get-Item $_).Length/1KB,1) + " KB)" }) -join "`r`n")

 SHA-256:
$(($hashLines | ForEach-Object { "   " + $_ }) -join "`r`n")
=========================================================
"@
Save-Text (Join-Path $releaseDir 'RELEASE-RECORD.txt') $record

$manifest = [ordered]@{
    product   = 'UNLOCK DIGITAL - Autodesk Licensing Doctor'
    version   = $Version
    built     = $built
    company   = 'UNLOCK DIGITAL'
    copyright = 'Unlock Digital - By Eng. Eslam Ashraf'
    notes     = $Notes
    artifacts = @(
        foreach ($z in $zips) {
            [ordered]@{
                name   = (Split-Path $z -Leaf)
                sizeMB = [math]::Round((Get-Item $z).Length/1MB, 2)
                sha256 = (Get-Sha256 $z)
            }
        }
    )
}
Save-Text (Join-Path $releaseDir 'manifest.json') ($manifest | ConvertTo-Json -Depth 5)

# master changelog
$log = Join-Path $root 'RELEASES.md'
$header = "# UNLOCK DIGITAL - Autodesk Licensing Doctor - Releases`r`n`r`n"
$entry  = "## v$Version  ($built)`r`n`r`n$Notes`r`n`r`n"
foreach ($z in $zips) {
    $entry += "- ``$(Split-Path $z -Leaf)``  -  $([math]::Round((Get-Item $z).Length/1MB,2)) MB  -  SHA256 ``$(Get-Sha256 $z)```r`n"
}
$entry += "`r`n"
if (Test-Path $log) {
    Add-Content -LiteralPath $log -Value $entry -Encoding UTF8
} else {
    Save-Text $log ($header + $entry)
}

Write-Host ""
Write-Ok "Release v$Version ready:"
foreach ($z in $zips) {
    Write-Host ("      " + (Split-Path $z -Leaf) + "   " + ([math]::Round((Get-Item $z).Length/1MB,2)) + " MB") -ForegroundColor Gray
}
Write-Host ("    Record: " + $releaseDir) -ForegroundColor Gray
Write-Host ""

if ($Open) { Start-Process $releaseDir }
