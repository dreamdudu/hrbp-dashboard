@echo off
chcp 65001 >nul
title HRBP 钉钉日程同步
cd /d "%~dp0"

echo 📅 正在从钉钉同步日程到看板...
echo.

where dws >nul 2>&1
if %errorlevel% neq 0 (
    echo ❌ 未找到 dws 命令
    echo 请先安装：https://github.com/open-dingtalk/dws
    pause
    exit /b 1
)

powershell -ExecutionPolicy Bypass -File "sync_dingtalk.ps1" -NoProfile

if exist "sync_result.js" (
    echo.
    echo ✅ 同步完成！
    echo 正在打开看板...
    start "" "index.html"
) else (
    echo.
    echo ❌ 同步失败
    pause
)

