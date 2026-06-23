@echo off
chcp 65001 >nul
title Restart HRBP Dashboard
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0restart-dashboard.ps1"
