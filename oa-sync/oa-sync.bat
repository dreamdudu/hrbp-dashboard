@echo off
chcp 65001 >nul
cd /d "%~dp0"
node "%~dp0oa_silent_sync.js"
set EC=%ERRORLEVEL%
if "%EC%"=="3" (
  echo.
  echo [提示] OA 登录已过期，请先运行 oa-login.bat 重新登录，再执行本同步。
)
exit /b %EC%
