@echo off
chcp 65001 >nul
title OA 常驻浏览器（登录后保持运行）
echo 正在启动常驻 OA 浏览器（带调试端口 9333）...
start "" "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" --remote-debugging-port=9333 --remote-allow-origins=* --user-data-dir="%~dp0edge-profile" --new-window "https://zmp.iwhalecloud.com/fish-zmp/modules/todoItem/index.jsp"
echo.
echo 1) 在打开的窗口完成飞连一键登录（如已自动登录则忽略）；
echo 2) 登录后请【最小化但不要关闭】该窗口（OA 会话随窗口存在，关掉就会掉登录）；
echo 3) 之后运行 oa-sync.bat 即可静默同步「我的待办」到智能分析。
echo.
pause
