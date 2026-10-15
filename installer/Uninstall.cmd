@echo off
title UNLOCK DIGITAL - Autodesk Licensing Doctor - Uninstall
setlocal

net session >nul 2>&1
if %errorlevel% NEQ 0 (
    echo Requesting administrator rights...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall.ps1"
pause
endlocal
