# 鲸+ OA todo background sync loop. Launched by start-dashboard.bat (no Windows Task Scheduler).
# Reads settings (oa_auto_enabled / oa_sync_interval minutes) from the dashboard state each cycle,
# ensures the resident OA Edge (debug port 9333) is up, then runs the external oa-sync\oa_silent_sync.js.
$ErrorActionPreference = "SilentlyContinue"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$statePath = Join-Path $scriptDir "data\dashboard-state.json"
$oaDir = Join-Path $scriptDir "oa-sync"
$oaScript = Join-Path $oaDir "oa_silent_sync.js"
$edgeProfile = Join-Path $oaDir "edge-profile"
$edge = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
$todoUrl = "https://zmp.iwhalecloud.com/fish-zmp/modules/todoItem/index.jsp"

# Single-instance guard per board directory
$md5 = [System.Security.Cryptography.MD5]::Create()
$hash = ([BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($scriptDir.ToLowerInvariant())))).Replace('-', '')
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($false, "Global\HRBP_OA_Sync_Loop_$hash", [ref]$createdNew)
try { if (-not $mutex.WaitOne(0)) { exit 0 } } catch [System.Threading.AbandonedMutexException] {}
$script:LoopMutex = $mutex

$node = (Get-Command node -ErrorAction SilentlyContinue).Source

function Test-PortUp([int]$p) {
    try { $c = New-Object System.Net.Sockets.TcpClient; $c.Connect("127.0.0.1", $p); $c.Close(); return $true } catch { return $false }
}

# 每 60 秒一个 tick：每次都重读设置(开关/周期)，所以在设置里改动后约 1 分钟内即生效
$lastRun = [DateTime]::MinValue
while ($true) {
    $enabled = $true; $interval = 60
    try {
        if ([System.IO.File]::Exists($statePath)) {
            $st = ([System.IO.File]::ReadAllText($statePath, [Text.Encoding]::UTF8)).TrimStart([char]0xFEFF) | ConvertFrom-Json
            if ($st.settings) {
                if ($null -ne $st.settings.oa_auto_enabled) { $enabled = [bool]$st.settings.oa_auto_enabled }
                if ($st.settings.oa_sync_interval) { $interval = [int]$st.settings.oa_sync_interval }
            }
        }
    } catch {}
    if ($interval -lt 5) { $interval = 5 }
    if ($interval -gt 1440) { $interval = 1440 }

    $due = ($lastRun -eq [DateTime]::MinValue) -or (((Get-Date) - $lastRun).TotalSeconds -ge ($interval * 60))
    if ($enabled -and $due -and $node -and [System.IO.File]::Exists($oaScript)) {
        if (-not (Test-PortUp 9333)) {
            try {
                Start-Process -FilePath $edge -ArgumentList '--remote-debugging-port=9333', '--remote-allow-origins=*', ("--user-data-dir=$edgeProfile"), '--new-window', $todoUrl -WindowStyle Minimized
            } catch {}
            $w = 0; while (-not (Test-PortUp 9333) -and $w -lt 30) { Start-Sleep -Seconds 2; $w += 2 }
            if (Test-PortUp 9333) { Start-Sleep -Seconds 6 }
        }
        try { & $node $oaScript | Out-Null } catch {}
        if ($LASTEXITCODE -eq 3) {
            # 会话过期：用干净启动脚本弹出单个可见登录窗口，提示用户手动登录
            try { Start-Process -FilePath "powershell.exe" -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', (Join-Path $scriptDir "oa_open_login.ps1") -WindowStyle Hidden } catch {}
        }
        $lastRun = Get-Date
    }
    Start-Sleep -Seconds 60
}
