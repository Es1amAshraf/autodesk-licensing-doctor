<#
  Install.ps1 - UNLOCK DIGITAL - Autodesk Licensing Doctor
  Installs the tool to %ProgramFiles%\UNLOCK DIGITAL\AdskDoctor
  and registers an uninstall entry (appears in Settings > Apps).

  Normally you do NOT run this directly - run Install.cmd (it elevates).
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:ProgramFiles 'UNLOCK DIGITAL\AdskDoctor')
)

$ErrorActionPreference = 'Stop'

$AppName      = 'Autodesk Licensing Doctor'
$Publisher    = 'UNLOCK DIGITAL'
$ExeName      = 'UNLOCK-DIGITAL-AdskDoctor.exe'
$UninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\UNLOCK-DIGITAL-AdskDoctor'

# --- administrator check ---------------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Administrator rights are required to install.' -ForegroundColor Red
    exit 1
}

$here    = $PSScriptRoot
$payload = Join-Path $here 'payload'
if (-not (Test-Path -LiteralPath $payload)) { throw "payload folder not found next to Install.ps1" }

$exeSrc = Join-Path $payload $ExeName
if (-not (Test-Path -LiteralPath $exeSrc)) { throw "$ExeName not found in payload" }
$ver = (Get-Item $exeSrc).VersionInfo.FileVersion

Write-Host ""
Write-Host "UNLOCK DIGITAL - $AppName" -ForegroundColor White
Write-Host "Installing version $ver ..." -ForegroundColor Cyan
Write-Host ""

# --- copy program files ----------------------------------------------------
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item (Join-Path $payload '*') $InstallDir -Recurse -Force

# keep the uninstaller inside the install dir
foreach ($f in 'Uninstall.ps1','Uninstall.cmd') {
    $s = Join-Path $here $f
    if (Test-Path -LiteralPath $s) { Copy-Item $s $InstallDir -Force }
}
Write-Host "  [v] files copied to $InstallDir" -ForegroundColor Green

# --- shortcuts -------------------------------------------------------------
$exeDst = Join-Path $InstallDir $ExeName
$ws = New-Object -ComObject WScript.Shell
$shortcuts = @(
    (Join-Path ([Environment]::GetFolderPath('CommonPrograms')) "$AppName.lnk"),
    (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) "$AppName.lnk")
)
foreach ($lnkPath in $shortcuts) {
    try {
        $lnk = $ws.CreateShortcut($lnkPath)
        $lnk.TargetPath       = $exeDst
        $lnk.WorkingDirectory = $InstallDir
        $lnk.IconLocation     = "$InstallDir\AdskDoctor.ico"
        $lnk.Description      = "$Publisher - $AppName"
        $lnk.Save()
        Write-Host "  [v] shortcut: $lnkPath" -ForegroundColor Green
    } catch {
        Write-Host "  [!] shortcut failed: $lnkPath" -ForegroundColor Yellow
    }
}

# --- uninstall entry -------------------------------------------------------
New-Item $UninstallKey -Force | Out-Null
$uninstCmd = Join-Path $InstallDir 'Uninstall.cmd'
Set-ItemProperty $UninstallKey -Name DisplayName     -Value "$AppName"
Set-ItemProperty $UninstallKey -Name DisplayVersion  -Value $ver
Set-ItemProperty $UninstallKey -Name Publisher       -Value $Publisher
Set-ItemProperty $UninstallKey -Name DisplayIcon     -Value $exeDst
Set-ItemProperty $UninstallKey -Name InstallLocation -Value $InstallDir
Set-ItemProperty $UninstallKey -Name UninstallString -Value ("`"$uninstCmd`"")
Set-ItemProperty $UninstallKey -Name NoModify        -Value 1 -Type DWord
Set-ItemProperty $UninstallKey -Name NoRepair        -Value 1 -Type DWord
$sizeKb = [math]::Round(((Get-ChildItem $InstallDir -Recurse -File | Measure-Object Length -Sum).Sum) / 1KB)
Set-ItemProperty $UninstallKey -Name EstimatedSize   -Value ([int]$sizeKb) -Type DWord
Write-Host "  [v] uninstall entry registered" -ForegroundColor Green

Write-Host ""
Write-Host "Done. Launch from the Desktop / Start Menu shortcut:" -ForegroundColor White
Write-Host "   $AppName" -ForegroundColor Gray
Write-Host ""
