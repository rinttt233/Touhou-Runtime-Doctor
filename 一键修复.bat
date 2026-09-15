@echo off
rem ===========================================================================
rem  Touhou Runtime Doctor - one-click repair
rem
rem  This batch file is intentionally PURE ASCII so it can never be corrupted
rem  by code page issues. All Chinese output is produced by the PowerShell
rem  engine, which writes through the Unicode console API.
rem
rem  Flow: check admin -> self-elevate if needed -> hand off to Run.ps1
rem ===========================================================================
setlocal
chcp 936 >nul 2>nul
title Touhou Runtime Doctor

rem HKU\S-1-5-19 (LocalService) is only readable by administrators.
rem This is a more reliable elevation probe than "net session", which fails
rem when the Server service is disabled.
reg query "HKU\S-1-5-19" >nul 2>&1
if errorlevel 1 (
    echo.
    echo   Requesting administrator privileges ...
    echo   ^(Runtime installation and registry fixes need elevation.^)
    echo.
    set "TRD_SELF=%~f0"
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:TRD_SELF -Verb RunAs"
    if errorlevel 1 (
        echo   [WARN] Elevation was declined or failed.
        echo          Continuing WITHOUT administrator rights.
        echo          Fixes that install runtimes will be skipped.
        echo.
        pause
    ) else (
        exit /b 0
    )
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run.ps1" %*
set RC=%errorlevel%

if not "%RC%"=="0" (
    echo.
    echo   [INFO] Exit code: %RC%
    echo.
    pause
)
exit /b %RC%
