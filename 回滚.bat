@echo off
rem ===========================================================================
rem  Touhou Runtime Doctor - rollback the most recent repair session
rem  Pure ASCII on purpose; Chinese output comes from the PowerShell engine.
rem ===========================================================================
setlocal
chcp 936 >nul 2>nul
title Touhou Runtime Doctor - Rollback

reg query "HKU\S-1-5-19" >nul 2>&1
if errorlevel 1 (
    echo.
    echo   Requesting administrator privileges ...
    echo.
    set "TRD_SELF=%~f0"
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:TRD_SELF -Verb RunAs"
    exit /b 0
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run.ps1" -Mode Rollback %*
echo.
pause
exit /b %errorlevel%
