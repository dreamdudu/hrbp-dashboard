# 一键重启看板后端：结束正在运行的 dws_server.ps1，再用新代码启动一个，并打开浏览器。
$ErrorActionPreference = "SilentlyContinue"
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $dir

Write-Host "[1/3] 结束正在运行的看板服务..."
# 仅匹配以 -File ...dws_server.ps1 方式启动的进程（不会误伤本脚本或其它 powershell）
$killed = 0
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and ($_.CommandLine -match '-File\s+"?[^"]*dws_server\.ps1') } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host ("      已结束 PID " + $_.ProcessId); $killed++ }
if ($killed -eq 0) { Write-Host "      （未发现运行中的实例）" }
Start-Sleep -Milliseconds 800   # 等待互斥锁随进程退出释放

Write-Host "[2/3] 启动新的看板服务（隐藏窗口）..."
Start-Process wscript -ArgumentList ('"' + (Join-Path $dir 'dws_server.vbs') + '"') | Out-Null

Write-Host "[3/3] 等待服务就绪..."
$port = ""
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 700
    $port = (Get-Content (Join-Path $dir ".port.txt") -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($port) { $port = $port.Trim() }
    if ($port) {
        try { $r = Invoke-WebRequest "http://127.0.0.1:$port/" -UseBasicParsing -TimeoutSec 2; if ($r.StatusCode -eq 200) { break } } catch {}
    }
}
if ($port) {
    Write-Host ("完成 ✔  http://127.0.0.1:$port/")
    Start-Process ("http://127.0.0.1:" + $port + "/")
} else {
    Write-Host "启动超时，请查看 logs\dws_server.log"
    Start-Sleep -Seconds 3
}
