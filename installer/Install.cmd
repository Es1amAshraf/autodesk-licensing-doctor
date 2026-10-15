@echo off
title UNLOCK DIGITAL - Autodesk Licensing Doctor - Setup
setlocal

REM --- self-elevate if needed ---
net session >nul 2>&1
if %errorlevel% NEQ 0 (
    echo Requesting administrator rights...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1"
set RC=%errorlevel%

echo.
if "%RC%"=="0" (echo Installation finished.) else (echo Installation failed ^(code %RC%^).)
echo.
pause
endlocal
