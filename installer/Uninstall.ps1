<#
  Uninstall.ps1 - UNLOCK DIGITAL - Autodesk Licensing Doctor
  Removes shortcuts + uninstall entry and deletes the install folder.
  Run Uninstall.cmd (it elevates) - or use Settings > Apps.
#>
$ErrorActionPreference = 'SilentlyContinue'

$AppName      = 'Autodesk Licensing Doctor'
$InstallDir   = $PSScriptRoot
$UninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\UNLOCK-DIGITAL-AdskDoctor'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Administrator rights are required to uninstall.' -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Removing $AppName ..." -ForegroundColor Cyan

# shortcuts
foreach ($lnk in @(
    (Join-Path ([Environment]::GetFolderPath('CommonPrograms')) "$AppName.lnk"),
    (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) "$AppName.lnk")
)) { Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue }

# registry
Remove-Item -LiteralPath $UninstallKey -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "  [v] shortcuts and registry entry removed" -ForegroundColor Green

# delete folder (detached, so this script can delete itself)
$cmd = 'ping 127.0.0.1 -n 3 > nul & rd /s /q "' + $InstallDir + '"'
Start-Process -FilePath $env:ComSpec -ArgumentList '/c', $cmd -WindowStyle Hidden
Write-Host "  [v] program folder will be deleted shortly" -ForegroundColor Green
Write-Host ""
