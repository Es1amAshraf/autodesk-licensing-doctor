@echo off
REM ============================================================
REM  Autodesk Licensing Doctor - launcher (Phase 2 backup)
REM  Self-elevates, creates a layered backup, prints its path.
REM ============================================================
setlocal
net session >nul 2>&1
if %errorlevel%==0 goto elevated
echo Requesting administrator rights...
powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%ComSpec%' -ArgumentList '/c',\"\"\"%~f0\"\"\""
exit /b
:elevated
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Backup.ps1" %*
echo.
pause
