@echo off
REM ============================================================
REM  Autodesk Licensing Doctor - launcher (Phase 1 diagnostic)
REM  Self-elevates to Administrator, writes an HTML report next
REM  to this file, and opens it.
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
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0AdskDoctor.ps1" -Html -Export "%~dp0report.html"
echo.
echo Opening report...
start "" "%~dp0report.html"
echo.
pause
