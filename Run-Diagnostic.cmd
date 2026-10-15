@echo off
REM ============================================================
REM  Autodesk Licensing Doctor - launcher (Phase 1 diagnostic)
REM  Self-elevates to Administrator, writes an HTML report next
REM  to this file, and opens it.
REM ============================================================
setlocal
net session >nul 2>&1
if %errorlevel%==0 goto elevated
echo Requesting administrator rights...
powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%ComSpec%' -ArgumentList '/c',\"\"\"%~f0\"\"\""
exit /b
:elevated
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0AdskDoctor.ps1" -Html -Export "%~dp0report.html"
echo.
echo Opening report...
start "" "%~dp0report.html"
echo.
pause
