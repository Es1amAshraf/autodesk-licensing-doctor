@echo off
rem Always elevated. Run-GUI.vbs is preferred (hidden console + UAC); this
rem cmd is the fallback for machines where .vbs files are blocked.
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"
rem fltmc needs elevation and does not depend on the Server service, unlike
rem "net session". A disabled Server service must not cause an elevation loop.
fltmc >nul 2>&1
if errorlevel 1 (
    set "LAUNCH_TARGET=%~f0"
    "%PS%" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:LAUNCH_TARGET -Verb RunAs"
    exit /b
)
start "" "%PS%" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0AdskDoctor-GUI.ps1"
