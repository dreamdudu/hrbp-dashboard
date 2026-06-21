# OA todo background sync loop. Launched by start-dashboard.bat (no Windows Task Scheduler).
# Runs OA sync only while the board is open (heartbeat). When the board is closed it stops all
# OA actions and closes the resident OA browser; it resumes automatically when the board reopens.
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

# Board online: the frontend writes data\.heartbeat every 30s while open; no heartbeat for 120s => board closed.
function Test-BoardOnline {
    $hb = Join-Path $scriptDir "data\.heartbeat"
    if (-not (Test-Path $hb)) { return $false }
    $raw = Get-Content $hb -Raw -ErrorAction SilentlyContinue
    if (-not $raw) { return $false }
    $t = [datetime]::MinValue
    if (-not [datetime]::TryParse($raw.Trim(), [ref]$t)) { return $false }
    return (((Get-Date) - $t).TotalSeconds -lt 120)
}

# Close the resident OA Edge (debug port 9333 + this project's edge-profile) started by the board.
function Stop-OaEdge {
    Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*--remote-debugging-port=9333*' -and $_.CommandLine -like '*oa-sync\edge-profile*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# One tick every 60s; re-reads settings (oa_auto_enabled / oa_sync_interval) each cycle.
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

    # Board closed: stop all OA actions and close the OA browser; auto-resume when the board reopens.
    if (-not (Test-BoardOnline)) { Stop-OaEdge; $lastRun = [DateTime]::MinValue; Start-Sleep -Seconds 60; continue }
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
            # Session expired: open a single visible login window for manual re-login.
            try { Start-Process -FilePath "powershell.exe" -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', (Join-Path $scriptDir "oa_open_login.ps1") -WindowStyle Hidden } catch {}
        }
        $lastRun = Get-Date
    }
    Start-Sleep -Seconds 60
}
