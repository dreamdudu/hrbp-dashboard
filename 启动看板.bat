@echo off
chcp 65001 >nul
title HRBP Dashboard
cd /d "%~dp0"

if exist ".port.txt" del ".port.txt" >nul 2>nul

echo Starting dashboard service...
start "" /min "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0dws_server.ps1"

rem Wait up to 12 seconds for the service to write its port file.
set WAIT=0
:CHECK
ping -n 2 127.0.0.1 >nul
set /a WAIT+=1
if not exist ".port.txt" goto RETRY
set /p PORT=<.port.txt
if "%PORT%"=="" goto RETRY
goto STARTED

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
