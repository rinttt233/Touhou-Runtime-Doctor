@echo off
rem ===========================================================================
rem  Touhou Runtime Doctor - device / system information collector
rem
rem  Read-only: gathers full hardware and system information and writes
rem  four report formats (txt / brief txt / html / json).
rem  It changes nothing and starts no game.
rem
rem  Runs elevated when possible so that full details (monitor EDID, some
rem  disk health fields) are available.
rem
rem  Pure ASCII on purpose; Chinese output comes from the PowerShell engine.
rem ===========================================================================
setlocal
chcp 936 >nul 2>nul
title Touhou Runtime Doctor - Device Info

rem HKU\S-1-5-19 is only readable by administrators.
reg query "HKU\S-1-5-19" >nul 2>&1
if errorlevel 1 (
    echo.
    echo   Requesting administrator privileges for complete device details ...
    echo   ^(You may also run without elevation; a few fields will be blank.^)
    echo.
    set "TRD_SELF=%~f0"
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:TRD_SELF -Verb RunAs"
    if errorlevel 1 (
        echo   [WARN] Elevation declined. Continuing with normal rights.
        echo.
        goto :collect
    ) else (
        exit /b 0
    )
)

:collect
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run.ps1" -Mode SysInfo %*
set RC=%errorlevel%

if not "%RC%"=="0" (
    echo.
    echo   [INFO] Exit code: %RC%
    echo.
    pause
)
exit /b %RC%
