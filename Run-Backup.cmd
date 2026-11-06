@echo off
REM ============================================================
REM  Autodesk Licensing Doctor - launcher (Phase 2 backup)
REM  Self-elevates, creates a layered backup, prints its path.
REM ============================================================
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"
fltmc >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator rights...
    set "LAUNCH_TARGET=%~f0"
    "%PS%" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:LAUNCH_TARGET -Verb RunAs"
    exit /b
)
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Backup.ps1" %*
echo.
pause
