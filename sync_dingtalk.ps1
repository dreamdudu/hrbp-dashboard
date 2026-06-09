# 同步钉钉日程脚本
# 依赖：dws 命令行工具（https://github.com/open-dingtalk/dws）

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$resultFile = Join-Path $scriptDir "sync_result.js"

$dwsCmd = Get-Command "dws" -ErrorAction SilentlyContinue
if (-not $dwsCmd) {
    Write-Host "❌ 未找到 dws 命令，请先安装：https://github.com/open-dingtalk/dws" -ForegroundColor Red
    pause
    exit 1
}

Write-Host "📅 正在从钉钉同步日程..." -ForegroundColor Cyan

$today = Get-Date
$endOfYear = Get-Date -Year $today.Year -Month 12 -Day 31

$startStr = $today.ToString("yyyy-MM-ddTHH:mm:ss+08:00")
$endStr = $endOfYear.ToString("yyyy-MM-ddTHH:mm:ss+08:00")

Write-Host "   时间范围：$($today.ToString('yyyy-MM-dd')) 至 $($endOfYear.ToString('yyyy-MM-dd'))" -ForegroundColor Gray

try {
    $jsonOutput = & $dwsCmd.Source calendar event list --start $startStr --end $endStr --format json 2>$null
    $parsed = $jsonOutput | ConvertFrom-Json
    
    $events = @()
    $rawList = @()
    if ($parsed.result -and $parsed.result.events) {
        $rawList = $parsed.result.events
    } elseif ($parsed -is [System.Collections.IList]) {
        $rawList = $parsed
    } elseif ($parsed.events) {
        $rawList = $parsed.events
    }
    
    $skippedCancelled = 0
    $skippedNoTitle = 0
    
    foreach ($evt in $rawList) {
        if ($evt.status -eq "cancelled") {
            $skippedCancelled++
            continue
        }
        
        $title = if ($evt.title) { $evt.title } elseif ($evt.summary) { $evt.summary } else { "" }
        
        if (-not $title) {
            $skippedNoTitle++
            continue
        }
        
        $startRaw = $evt.start
        $endRaw = $evt.end
        
        $startDt = if ($startRaw.dateTime) { $startRaw.dateTime } elseif ($startRaw.date) { $startRaw.date } else { "" }
        $endDt = if ($endRaw.dateTime) { $endRaw.dateTime } elseif ($endRaw.date) { $endRaw.date } else { "" }
        
        $eventDate = ""
        $startTime = ""
        $endTime = ""
        
        if ($startDt -match "T") {
            try {
                $dt = [DateTime]::Parse($startDt)
                $eventDate = $dt.ToString("yyyy-MM-dd")
                $startTime = $dt.ToString("HH:mm")
            } catch {
                $eventDate = $startDt.Substring(0, [Math]::Min(10, $startDt.Length))
            }
        } elseif ($startDt) {
            $eventDate = $startDt.Substring(0, [Math]::Min(10, $startDt.Length))
        }
        
        if ($endDt -match "T") {
            try {
                $et = [DateTime]::Parse($endDt)
                $endTime = $et.ToString("HH:mm")
            } catch {}
        }
        
        $notes = if ($evt.description) { $evt.description -split "`n" | Select-Object -First 1 } else { "" }
        
        $events += @{
            title = $title
            date = $eventDate
            start = $startTime
            end = $endTime
            notes = $notes
        }
    }
    
    # 确保输出为数组（PowerShell 单条记录会输出对象而非数组）
    $jsContent = "window.__dingtalkSyncResult = " + (ConvertTo-Json -InputObject $events -Depth 3 -Compress) + ";"
    $jsContent | Out-File -FilePath $resultFile -Encoding utf8
    
    Write-Host "✅ 同步完成！共获取 $($events.Count) 条日程" -ForegroundColor Green
    if ($skippedCancelled -gt 0) { Write-Host "   已跳过 $skippedCancelled 条已取消日程" -ForegroundColor Gray }
    if ($skippedNoTitle -gt 0) { Write-Host "   已跳过 $skippedNoTitle 条无标题日程" -ForegroundColor Gray }
    Write-Host "   请在浏览器中刷新页面，然后点击"同步钉钉日程"按钮" -ForegroundColor Gray
} catch {
    Write-Host "❌ 同步失败：$_" -ForegroundColor Red
    $jsContent = "window.__dingtalkSyncResult = [];"
    $jsContent | Out-File -FilePath $resultFile -Encoding utf8
}

pause
