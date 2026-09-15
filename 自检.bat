@echo off
rem ===========================================================================
rem  Touhou Runtime Doctor - environment self test
rem
rem  Answers one question: "can this tool actually run on THIS machine?"
rem  It touches no game files and changes no system settings.
rem
rem  Useful before anything else on an unfamiliar or old system
rem  (notably 32-bit Windows 7, which only ships PowerShell 2.0).
rem
rem  Pure ASCII on purpose; Chinese output comes from the PowerShell engine.
rem ===========================================================================
setlocal
chcp 936 >nul 2>nul
title Touhou Runtime Doctor - Self Test

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run.ps1" -Mode SelfTest %*
set RC=%errorlevel%

if not "%RC%"=="0" (
    echo.
    echo   [INFO] Exit code: %RC%
    echo   [INFO] 4 = PowerShell too old, 5 = a critical capability is unavailable
    echo.
)
pause
exit /b %RC%
