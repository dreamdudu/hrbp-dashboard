@echo off
chcp 65001 >nul
title HRBP 看板
cd /d "%~dp0"

echo 正在启动看板服务...
start /min powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "dws_server.ps1"

timeout /t 2 /nobreak >nul

echo 正在打开看板...
start "" "http://127.0.0.1:18632/"
exit
