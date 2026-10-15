<#
  Build-Release.ps1  -  UNLOCK DIGITAL  -  Autodesk Licensing Doctor
  ------------------------------------------------------------------
  Creates a release for a given version and stores THREE forms:

    1) PROJECT   -> AdskDoctor-v<ver>-Project.zip        (source files)
    2) PORTABLE  -> AdskDoctor-v<ver>-Portable.zip       (run from anywhere)
    3) SETUP     -> UNLOCK-DIGITAL-AdskDoctor-Setup-<ver>.exe   (real installer,
                    Inno Setup, branded with unlock-logo.ico)

  Plus a per-version record (RELEASE-RECORD.txt + manifest.json + SHA256SUMS)
  and an entry appended to RELEASES.md.

  Examples
    .\Build-Release.ps1 -Version 1.2.4
    .\Build-Release.ps1 -Version 1.2.4 -Notes "Fixed ADLS reset" -Recompile
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,

    [string]$Notes = '',

    # Re-encode the GUI script (UTF-8 BOM, required for Arabic) and recompile the exe
    [switch]$Recompile,

    # Recompile the exe only, then stop (used by CI before code signing)
    [switch]$CompileOnly,

    # Use the legacy ZIP-based installer instead of the Inno Setup .exe
    [switch]$LegacySetupZip,

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
function Get-Sha256([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function New-BomFile { param([string]$Path)
    $c = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($Path, $c, (New-Object System.Text.UTF8Encoding($true)))
}
function New-Zip { param([string]$SourceDir, [string]$DestZip)
    if (Test-Path $DestZip) { Remove-Item $DestZip -Force }
    Compress-Archive -Path (Join-Path $SourceDir '*') -DestinationPath $DestZip -CompressionLevel Optimal -Force
}

Write-Host ""
Write-Host "UNLOCK DIGITAL - Autodesk Licensing Doctor" -ForegroundColor White
Write-Host ("Building release v" + $Version) -ForegroundColor White
Write-Host ""

# ---------------------------------------------------------------------------
# 0) paths + sanity
# ---------------------------------------------------------------------------
$gui        = Join-Path $root 'AdskDoctor-GUI.ps1'
$exeName    = 'UNLOCK-DIGITAL-AdskDoctor.exe'
$exe        = Join-Path $root $exeName
$icon       = Join-Path $root 'AdskDoctor.ico'
$logoPng    = Join-Path $root 'unlock-logo.png'
$logoIco    = Join-Path $root 'unlock-logo.ico'
$licenseF   = Join-Path $root 'LICENSE'
$runtimeScripts = @('AdskDoctor.ps1','Backup.ps1','Clean.ps1','Repair.ps1')
$sourceScripts  = @('AdskDoctor.ps1','Backup.ps1','Clean.ps1','Repair.ps1','AdskDoctor-GUI.ps1','make-icon.ps1','make-logo-icon.ps1','Build-Release.ps1')
$launchers      = @('Run-Diagnostic.cmd','Run-Backup.cmd')
$installerFiles = @('Install.ps1','Install.cmd','Uninstall.ps1','Uninstall.cmd')

$required = @('AdskDoctor-GUI.ps1') + $runtimeScripts + @('AdskDoctor.ico')
$missing  = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root $_)) })
if ($missing.Count) { throw ("Missing required file(s): " + ($missing -join ', ')) }

# brand icon for the installer (generate from the PNG logo when possible)
if (-not (Test-Path -LiteralPath $logoIco) -and (Test-Path -LiteralPath $logoPng)) {
    Write-Step "Generating unlock-logo.ico from unlock-logo.png ..."
    & (Join-Path $root 'make-logo-icon.ps1') -Source $logoPng -Dest $logoIco | Out-Null
}
$hasIco = Test-Path -LiteralPath $logoIco

# locate ISCC (Inno Setup)
$iscc = $null
foreach ($p in @(
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles      'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:LOCALAPPDATA      'Programs\Inno Setup 6\ISCC.exe'))) {
    if (Test-Path -LiteralPath $p) { $iscc = $p; break }
}

# ---------------------------------------------------------------------------
# 1) optional: recompile the app exe
# ---------------------------------------------------------------------------
if ($Recompile) {
    Write-Step "Re-encoding GUI (UTF-8 BOM) and recompiling exe ..."
    New-BomFile $gui
    # ps2exe cannot overwrite a running exe; detect it up front instead of
    # silently shipping the previous build.
    $running = @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($exeName)) -ErrorAction SilentlyContinue)
    if ($running.Count) {
        throw ("Close " + $exeName + " first (it is running, pid " +
               (($running | ForEach-Object { $_.Id }) -join ', ') + ").")
    }
    $before = $null
    if (Test-Path -LiteralPath $exe) { $before = (Get-Item -LiteralPath $exe).LastWriteTimeUtc }

    # The exe is compiled with Windows PowerShell 5.1 on purpose: a 5.1-based
    # ps2exe build runs on a stock Windows 10/11, while a PowerShell 7 build would
    # require PowerShell 7 on the client machine. Check up front that the module
    # is importable there - otherwise the failure only shows up as the bare
    # "exe not produced" message, which says nothing about the reason.
    $probe = powershell -NoProfile -ExecutionPolicy Bypass -Command "if (Get-Module -ListAvailable ps2exe) { 'ok' } else { 'missing' }" 2>&1
    if (([string]($probe -join ' ')) -notmatch 'ok') {
        throw ('ps2exe is not installed for Windows PowerShell 5.1. Install it with: ' +
               'powershell -NoProfile -Command "Install-Module ps2exe -Scope CurrentUser -Force"')
    }

    $cmd = "Import-Module ps2exe; Invoke-PS2EXE -inputFile '$gui' -outputFile '$exe' -iconFile '$icon' " +
           "-STA -noConsole -requireAdmin -x64 -title 'Autodesk Licensing Doctor' " +
           "-description 'Autodesk licensing cleanup and repair' -company 'UNLOCK DIGITAL' " +
           "-product 'Autodesk Licensing Doctor' -copyright 'Unlock Digital - By Eng. Eslam Ashraf' " +
           "-version '$Version.0'"
    $compileOut = powershell -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1
    # print everything (including errors) so a failed compile is diagnosable
    $compileOut | ForEach-Object { Write-Host ("      " + ([string]$_).TrimEnd()) -ForegroundColor DarkGray }

    $fi = Get-Item -LiteralPath $exe -ErrorAction SilentlyContinue
    if (-not $fi) { throw "Recompile failed: exe not produced." }
    if ($before -and $fi.LastWriteTimeUtc -le $before) {
        throw ("Recompile failed: " + $exeName + " was not updated (still the previous build).")
    }
    if ($fi.VersionInfo.FileVersion -ne "$Version.0") {
        Write-Warn2 ("File version is " + $fi.VersionInfo.FileVersion + ", expected $Version.0")
    }
    Write-Ok ("Compiled " + $exeName + "  (" + [math]::Round($fi.Length / 1KB, 1) + " KB, v" + $fi.VersionInfo.FileVersion + ")")
}
if ($CompileOnly) {
    Write-Ok ("Compile-only: " + $exeName + " is ready (nothing else was built).")
    return
}
if (-not (Test-Path $exe)) { throw "Executable not found: $exe  (run once with -Recompile)" }

# ---------------------------------------------------------------------------
# 2) staging
# ---------------------------------------------------------------------------
$releaseDir = Join-Path $root ("releases\v" + $Version)
if (Test-Path $releaseDir) { Remove-Item $releaseDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null

$stage    = Join-Path $env:TEMP ("adsk_release_" + [guid]::NewGuid().ToString('N'))
$sProj    = Join-Path $stage 'project'
$sPort    = Join-Path $stage 'portable'
$sSetup   = Join-Path $stage 'setup'
$sPayload = Join-Path $sSetup 'payload'
New-Item -ItemType Directory -Force -Path $sProj,$sPort,$sSetup,$sPayload | Out-Null

Write-Step "Staging files ..."

# --- 2a) PROJECT -----------------------------------------------------------
foreach ($f in $sourceScripts + $launchers) {
    $src = Join-Path $root $f
    if (Test-Path $src) { Copy-Item $src $sProj -Force }
}
Copy-Item $icon $sProj -Force
if ($hasIco) { Copy-Item $logoIco $sProj -Force }
if (Test-Path $logoPng) { Copy-Item $logoPng $sProj -Force }
foreach ($f in @('README.md','LICENSE','RELEASES.md','.gitignore','.gitattributes')) {
    $src = Join-Path $root $f
    if (Test-Path $src) { Copy-Item $src $sProj -Force }
}
$instDirSrc = Join-Path $root 'installer'
if (Test-Path $instDirSrc) {
    $d = Join-Path $sProj 'installer'
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    Copy-Item (Join-Path $instDirSrc '*') $d -Force
}

# --- shared runtime payload (used by portable + installer) ------------------
$runtimePayload = @($exe) + ($runtimeScripts | ForEach-Object { Join-Path $root $_ }) + @($icon)
if ($hasIco) { $runtimePayload += $logoIco }
if (Test-Path $logoPng) { $runtimePayload += $logoPng }
$runtimePayload += ($launchers | ForEach-Object { Join-Path $root $_ } | Where-Object { Test-Path $_ })

# --- 2b) PORTABLE ----------------------------------------------------------
Copy-Item $runtimePayload $sPort -Force
if (Test-Path (Join-Path $root 'README.md')) { Copy-Item (Join-Path $root 'README.md') $sPort -Force }
if (Test-Path $licenseF) { Copy-Item $licenseF $sPort -Force }
$portableReadme = @"
UNLOCK DIGITAL - Autodesk Licensing Doctor  (PORTABLE v$Version)
=================================================================
No installation required. Just run:  $exeName
(accept the UAC prompt - the tool needs administrator rights.)

Keep ALL files in this folder together - the app calls the .ps1 scripts
that sit next to the .exe.

Copyright (c) 2026 UNLOCK DIGITAL - By Eng. Eslam Ashraf   (MIT)
"@
Save-Text (Join-Path $sPort 'PORTABLE-READ-ME.txt') $portableReadme

# --- 2c) INSTALLER ---------------------------------------------------------
Copy-Item $runtimePayload $sPayload -Force
if (Test-Path (Join-Path $root 'README.md')) { Copy-Item (Join-Path $root 'README.md') $sPayload -Force }

$setupExe = Join-Path $releaseDir ("UNLOCK-DIGITAL-AdskDoctor-Setup-$Version.exe")
$usedInno = $false

if ($iscc -and -not $LegacySetupZip) {
    Write-Step "Compiling installer with Inno Setup ..."
    $iss = Join-Path $instDirSrc 'AdskDoctor.iss'
    $args = @(
        "/DVersion=$Version",
        "/DPayloadDir=$sPayload",
        "/DOutputDir=$releaseDir",
        "/DIconFile=$logoIco",
        "/DLicenseFile=$licenseF",
        $iss
    )
    & $iscc @args | Out-Null
    if (Test-Path -LiteralPath $setupExe) {
        $usedInno = $true
        Write-Ok "Setup.exe created"
    } else {
        Write-Warn2 "Inno Setup did not produce the expected exe - falling back to Setup.zip"
    }
}
if (-not $usedInno) {
    foreach ($f in $installerFiles) {
        $src = Join-Path $instDirSrc $f
        if (Test-Path $src) { Copy-Item $src $sSetup -Force }
    }
    $setupReadme = @"
UNLOCK DIGITAL - Autodesk Licensing Doctor  (SETUP v$Version)
==============================================================
1. Extract this ZIP anywhere.
2. Right-click  Install.cmd  ->  Run as administrator.
3. Launch from the Desktop / Start Menu shortcut "Autodesk Licensing Doctor".
Installs to: %ProgramFiles%\UNLOCK DIGITAL\AdskDoctor
"@
    Save-Text (Join-Path $sSetup 'SETUP-READ-ME.txt') $setupReadme
}

# ---------------------------------------------------------------------------
# 3) build the artifacts
# ---------------------------------------------------------------------------
Write-Step "Creating artifacts ..."

$zipProject  = Join-Path $releaseDir ("AdskDoctor-v$Version-Project.zip")
$zipPortable = Join-Path $releaseDir ("AdskDoctor-v$Version-Portable.zip")
New-Zip $sProj $zipProject
New-Zip $sPort $zipPortable

$artifacts = @($zipProject, $zipPortable)
if ($usedInno) {
    $artifacts += $setupExe
} else {
    $zipSetup = Join-Path $releaseDir ("AdskDoctor-v$Version-Setup.zip")
    New-Zip $sSetup $zipSetup
    $artifacts += $zipSetup
}
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# 4) record (hashes + manifest + changelog)
# ---------------------------------------------------------------------------
$hashLines = @()
foreach ($a in $artifacts) { $hashLines += ("{0}  {1}" -f (Get-Sha256 $a), (Split-Path $a -Leaf)) }
Save-Text (Join-Path $releaseDir 'SHA256SUMS.txt') (($hashLines -join "`r`n") + "`r`n")

$built = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$ver   = (Get-Item $exe).VersionInfo
$kind  = { param($p) if ($p -like '*.exe') { 'installer (.exe)' } elseif ($p -like '*Project*') { 'source' } else { 'portable' } }

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
 Installer      : $(if ($usedInno) { 'Inno Setup .exe' } else { 'legacy Setup.zip' })

 Notes:
 $Notes

 Files:
$(($artifacts | ForEach-Object { "   - " + (Split-Path $_ -Leaf) + "  (" + [math]::Round((Get-Item $_).Length/1KB,1) + " KB)" }) -join "`r`n")

 SHA-256:
$(($hashLines | ForEach-Object { "   " + $_ }) -join "`r`n")
=========================================================
"@
Save-Text (Join-Path $releaseDir 'RELEASE-RECORD.txt') $record

$manifest = [ordered]@{
    product     = 'UNLOCK DIGITAL - Autodesk Licensing Doctor'
    version     = $Version
    built       = $built
    company     = 'UNLOCK DIGITAL'
    copyright   = 'Unlock Digital - By Eng. Eslam Ashraf'
    installer   = $(if ($usedInno) { 'inno-setup-exe' } else { 'legacy-zip' })
    notes       = $Notes
    artifacts   = @(
        foreach ($a in $artifacts) {
            [ordered]@{
                name   = (Split-Path $a -Leaf)
                kind   = (& $kind $a)
                sizeMB = [math]::Round((Get-Item $a).Length/1MB, 2)
                sha256 = (Get-Sha256 $a)
            }
        }
    )
}
Save-Text (Join-Path $releaseDir 'manifest.json') ($manifest | ConvertTo-Json -Depth 5)

$log    = Join-Path $root 'RELEASES.md'
$header = "# UNLOCK DIGITAL - Autodesk Licensing Doctor - Releases`r`n`r`n"
$entry  = "## v$Version  ($built)`r`n`r`n$Notes`r`n`r`n"
foreach ($a in $artifacts) {
    $entry += "- ``$(Split-Path $a -Leaf)``  -  $([math]::Round((Get-Item $a).Length/1MB,2)) MB  -  SHA256 ``$(Get-Sha256 $a)```r`n"
}
$entry += "`r`n"

# Rebuild the log instead of appending: this version's entry goes on top and any
# previous entry for the SAME version is dropped, so re-building a release does
# not pile up duplicates.
$older = @()
if (Test-Path $log) {
    $txt = [System.IO.File]::ReadAllText($log)
    $i = $txt.IndexOf('## v')
    if ($i -ge 0) { $txt = $txt.Substring($i) }
    $older = @([regex]::Split($txt, '(?m)(?=^## v)') |
        Where-Object { $_.Trim().Length -gt 0 } |
        Where-Object { $_ -notmatch ('^## v' + [regex]::Escape($Version) + '\b') })
}
Save-Text $log ($header + $entry + ($older -join ''))

Write-Host ""
Write-Ok "Release v$Version ready:"
foreach ($a in $artifacts) {
    Write-Host ("      " + (Split-Path $a -Leaf) + "   " + ([math]::Round((Get-Item $a).Length/1MB,2)) + " MB") -ForegroundColor Gray
}
Write-Host ("    Record: " + $releaseDir) -ForegroundColor Gray
Write-Host ""

if ($Open) { Start-Process $releaseDir }
