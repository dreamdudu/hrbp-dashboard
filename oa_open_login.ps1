# Open a single clean OA 飞连 login window (debug port 9333). Kills any existing edge-profile Edge and
# clears session-restore so exactly one tab opens. Used by dws_server /oa-login and oa_sync_loop (on expiry).
$ErrorActionPreference = "SilentlyContinue"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$prof = Join-Path $scriptDir "oa-sync\edge-profile"
$edge = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
if (-not (Test-Path $edge)) { $edge = "msedge.exe" }
$url = "https://zmp.iwhalecloud.com/fish-zmp/modules/todoItem/index.jsp"

# 关闭所有使用该专用配置的 Edge 实例（避免累积多标签/多窗口）
Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -like "*$prof*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch {} }
Start-Sleep -Seconds 2

# 清除会话恢复，确保只打开一个登录标签（不恢复旧的看板/登录页）
$def = Join-Path $prof "Default"
foreach ($f in @("Current Session", "Current Tabs", "Last Session", "Last Tabs")) {
    Remove-Item -LiteralPath (Join-Path $def $f) -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath (Join-Path $def "Sessions") -Recurse -Force -ErrorAction SilentlyContinue

# 启动一个干净的可见窗口（带调试端口），单标签指向 OA（未登录会跳飞连登录页）
Start-Process -FilePath $edge -ArgumentList '--remote-debugging-port=9333', '--remote-allow-origins=*', ("--user-data-dir=$prof"), '--no-first-run', '--no-default-browser-check', '--hide-crash-restore-bubble', '--new-window', $url
