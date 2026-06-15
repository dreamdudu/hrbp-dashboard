@echo off
chcp 65001 >nul
title HRBP DingTalk Calendar Sync
cd /d "%~dp0"

echo Syncing calendar from DingTalk...
echo.

where dws >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] dws command not found
    echo Please install it first: https://github.com/open-dingtalk/dws
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "sync_dingtalk.ps1"

if exist "sync_result.js" (
    echo.
    echo [OK] Sync complete. Opening dashboard...
    start "" "index.html"
) else (
    echo.
    echo [ERROR] Sync failed
    pause
)
