@echo off
chcp 65001 >nul
title HRBP 看板
cd /d "%~dp0"

echo 正在启动看板服务...
start /min powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "dws_server.ps1"

rem 等待服务启动，最多等 8 秒
set WAIT=0
:CHECK
timeout /t 2 /nobreak >nul
set /a WAIT+=2
if exist ".port.txt" goto STARTED
if %WAIT% lss 8 goto CHECK

:STARTED
set /p PORT=<.port.txt
if "%PORT%"=="" set PORT=18632

echo 正在打开看板 http://127.0.0.1:%PORT%/
start "" "http://127.0.0.1:%PORT%/"
exit
