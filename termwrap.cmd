@echo off
title TermWrap
rem TermWrap launcher: auto-elevates via UAC, then starts the menu.
rem 双击本文件即可：自动请求管理员权限 -> 打开交互菜单。

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo 正在请求管理员权限，请在 UAC 弹窗中点击"是"...
    powershell -NoProfile -Command "Start-Process -FilePath '%~dp0termwrap.cmd' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0termwrap.ps1" %*
if errorlevel 1 pause
