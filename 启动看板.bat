@echo off
chcp 65001 >nul
title HRBP 看板
cd /d "%~dp0"

echo 正在启动同步服务...
start /min powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "dws_server.ps1"

timeout /t 2 /nobreak >nul

echo 正在打开看板...
start "" "index.html"
exit
