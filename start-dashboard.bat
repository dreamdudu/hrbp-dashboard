@echo off
chcp 65001 >nul
title HRBP Dashboard
cd /d "%~dp0"

rem Start the 鲸+ OA todo background sync loop (single-instance; reads enable/interval from dashboard state; no Windows Task Scheduler)
start "" /min "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0oa_sync_loop.ps1"

rem Fast path: if a server is already running and reachable, just open it
if not exist ".port.txt" goto LAUNCH
set /p PORT=<.port.txt
if "%PORT%"=="" goto LAUNCH
curl -s -o nul -m 2 "http://127.0.0.1:%PORT%/" && goto STARTED

:LAUNCH
echo Starting dashboard service...
start "" /min "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0dws_server.ps1"

rem Wait until the service is up (port file present and server reachable)
set WAIT=0
:CHECK
ping -n 2 127.0.0.1 >nul
set /a WAIT+=1
if not exist ".port.txt" goto RETRY
set /p PORT=<.port.txt
if "%PORT%"=="" goto RETRY
curl -s -o nul -m 2 "http://127.0.0.1:%PORT%/" && goto STARTED

:RETRY
if %WAIT% lss 12 goto CHECK
echo Service failed to start. Opening index.html directly.
if /i "%~1"=="--no-open" exit /b 1
start "" "%~dp0index.html"
exit /b 1

:STARTED
echo Opening dashboard http://127.0.0.1:%PORT%/
if /i "%~1"=="--no-open" exit /b 0
start "" "http://127.0.0.1:%PORT%/"
exit /b 0
