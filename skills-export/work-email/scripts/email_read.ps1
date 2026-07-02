<#
.SYNOPSIS
  读取 / 搜索本机 Outlook 桌面版（已登录 Exchange 工作账号）的邮件，输出 JSON 数组到 stdout。
.NOTES
  仅在装有 Outlook 且已登录工作账号的 Windows 机器上有效（COM 自动化本地 Outlook 配置）。
.EXAMPLE
  pwsh -File email_read.ps1 -Start "2026-06-28 00:00:00" -End "2026-07-01 23:59:59"
  pwsh -File email_read.ps1 -Days 7 -Unread -From "zhang" -Keyword "费用"
  pwsh -File email_read.ps1 -Days 14 -Folder Sent
#>
[CmdletBinding()]
param(
    [string] $Start,                       # 起始时间 "yyyy-MM-dd HH:mm:ss"；不填则用 -Days 回溯
    [string] $End,                         # 结束时间；默认现在
    [int]    $Days = 3,                     # 未给 -Start 时，回溯的天数
    [int]    $Max = 60,                     # 最多返回多少封
    [ValidateSet("Inbox", "Sent")]
    [string] $Folder = "Inbox",            # 读哪个文件夹
    [string] $Keyword = "",                # 主题/正文包含的关键词（可空）
    [string] $From = "",                   # 发件人姓名/地址包含（可空）
    [switch] $Unread,                      # 仅未读
    [int]    $MaxScan = 600,               # 最多扫描多少封（防止超大邮箱卡顿）
    [switch] $Compact                      # 输出压缩 JSON（默认缩进）
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($End)) { $endDt = Get-Date } else { $endDt = [DateTime]::Parse($End) }
if ([string]::IsNullOrWhiteSpace($Start)) { $startDt = $endDt.AddDays(-[math]::Abs($Days)) } else { $startDt = [DateTime]::Parse($Start) }

try {
    $outlook = New-Object -ComObject Outlook.Application
} catch {
    @{ ok = $false; error = "无法连接 Outlook（请确认已安装 Outlook 桌面版并登录工作账号）：$($_.Exception.Message)"; emails = @() } |
        ConvertTo-Json -Compress
    exit 1
}

$ns = $outlook.GetNamespace("MAPI")
# 6 = olFolderInbox, 5 = olFolderSentMail
$folderId = if ($Folder -eq "Sent") { 5 } else { 6 }
$box = $ns.GetDefaultFolder($folderId)
$items = $box.Items
$sortField = if ($Folder -eq "Sent") { "[SentOn]" } else { "[ReceivedTime]" }
try { $items.Sort($sortField, $true) } catch {}   # 最新在前

$kw = $Keyword.ToLower()
$fromKw = $From.ToLower()
$emails = @()
$count = 0
$scanned = 0

foreach ($item in $items) {
    if ($count -ge $Max) { break }
    $scanned++
    if ($scanned -gt $MaxScan) { break }

    # 只处理普通邮件（olMail = 43），跳过会议/日志/通知等条目
    $cls = 0; try { $cls = [int]$item.Class } catch {}
    if ($cls -ne 43) { continue }

    # 按时间窗过滤（已按时间倒序：早于起始即可停止）
    $when = $null
    try { $when = if ($Folder -eq "Sent") { [DateTime]$item.SentOn } else { [DateTime]$item.ReceivedTime } } catch { continue }
    if ($when -lt $startDt) { break }
    if ($when -gt $endDt) { continue }

    if ($Unread) { try { if (-not $item.UnRead) { continue } } catch {} }

    $subject = ""; $body = ""; $fromName = ""; $fromAddr = ""; $toStr = ""; $ccStr = ""; $unreadFlag = $false; $entryId = ""
    try { $subject = [string]$item.Subject } catch {}
    try { $body = [string]$item.Body } catch {}
    try { $fromName = [string]$item.SenderName } catch {}
    try {
        # Exchange 内部地址可能是 /o=.../cn=... 的 DN，解析成真实 SMTP
        $fromAddr = [string]$item.SenderEmailAddress
        if ($fromAddr -like "/*") {
            try { $eu = $item.Sender.GetExchangeUser(); if ($eu -and $eu.PrimarySmtpAddress) { $fromAddr = [string]$eu.PrimarySmtpAddress } } catch {}
        }
    } catch {}
    try { $toStr = [string]$item.To } catch {}
    try { $ccStr = [string]$item.CC } catch {}
    try { $unreadFlag = [bool]$item.UnRead } catch {}
    try { $entryId = [string]$item.EntryID } catch {}

    # 关键词 / 发件人过滤
    if ($kw -and -not (($subject.ToLower().Contains($kw)) -or ($body.ToLower().Contains($kw)))) { continue }
    if ($fromKw -and -not ((("$fromName $fromAddr").ToLower()).Contains($fromKw))) { continue }

    $attNames = @()
    try { foreach ($a in $item.Attachments) { $attNames += [string]$a.FileName } } catch {}

    $preview = ($body -replace "\s+", " ").Trim()
    if ($preview.Length -gt 160) { $preview = $preview.Substring(0, 160) + "…" }
    if ($body.Length -gt 8000) { $body = $body.Substring(0, 8000) }

    $emails += [ordered]@{
        entryId         = $entryId
        subject         = $subject
        from            = $fromName
        fromAddress     = $fromAddr
        to              = $toStr
        cc              = $ccStr
        received        = $when.ToString("yyyy-MM-dd HH:mm:ss")
        unread          = $unreadFlag
        hasAttachments  = ($attNames.Count -gt 0)
        attachmentNames = $attNames
        bodyPreview     = $preview
        body            = $body
    }
    $count++
}

$result = [ordered]@{ ok = $true; folder = $Folder; count = $count; scanned = $scanned; window = @{ start = $startDt.ToString("s"); end = $endDt.ToString("s") }; emails = $emails }
if ($Compact) { $result | ConvertTo-Json -Depth 6 -Compress } else { $result | ConvertTo-Json -Depth 6 }
