@echo off
setlocal
title TermWrap
rem TermWrap launcher: auto-elevates via UAC, then opens the menu.
rem Keep this file ASCII-only (batch files are parsed in the OEM codepage).

net session >nul 2>&1
if not %errorlevel%==0 (
    echo Requesting administrator privileges...
    echo Please click Yes on the UAC prompt.
    powershell -NoProfile -Command "Start-Process -FilePath '%~dp0termwrap.ps1' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0termwrap.ps1" %*
if errorlevel 1 pause
