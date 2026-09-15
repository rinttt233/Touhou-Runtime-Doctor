@echo off
rem ===========================================================================
rem  Touhou Runtime Doctor - detect only (read-only, safe to run anytime)
rem  Pure ASCII on purpose; Chinese output comes from the PowerShell engine.
rem ===========================================================================
setlocal
chcp 936 >nul 2>nul
title Touhou Runtime Doctor - Detect Only

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run.ps1" -Mode Detect %*
set RC=%errorlevel%

if not "%RC%"=="0" (
    echo.
    echo   [INFO] Exit code: %RC%
    echo.
    pause
)
exit /b %RC%
