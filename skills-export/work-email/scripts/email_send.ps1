<#
.SYNOPSIS
  用本机 Outlook 桌面版（已登录工作账号）发送新邮件，或回复/全部回复/转发某封邮件。
.NOTES
  默认 -Display（打开草稿供人工确认），需显式 -Send 才真正发送。发送是对外动作、不可撤回，务必先与用户确认。
.EXAMPLE
  # 新邮件（纯文本），打开草稿让用户确认
  pwsh -File email_send.ps1 -To "a@corp.com;b@corp.com" -Subject "费用确认" -Body "请审批。" -Display
  # 直接发送 + HTML + 附件
  pwsh -File email_send.ps1 -To "a@corp.com" -Subject "报表" -Body "<p>见附件</p>" -Html -Attachments "C:\r\june.xlsx" -Send
  # 回复某封（entryId 来自 email_read.ps1）
  pwsh -File email_send.ps1 -ReplyEntryId "0000..." -Body "收到，已审批。" -Send
  pwsh -File email_send.ps1 -ForwardEntryId "0000..." -To "d@corp.com" -Body "请跟进。" -Send
#>
[CmdletBinding()]
param(
    [string]   $To = "",                 # 收件人，分号分隔
    [string]   $Cc = "",
    [string]   $Bcc = "",
    [string]   $Subject = "",
    [string]   $Body = "",
    [switch]   $Html,                    # 正文按 HTML 处理
    [string[]] $Attachments = @(),       # 附件绝对路径
    [string]   $ReplyEntryId = "",       # 回复发件人
    [string]   $ReplyAllEntryId = "",    # 全部回复
    [string]   $ForwardEntryId = "",     # 转发（需配 -To）
    [switch]   $Send,                    # 真正发送
    [switch]   $Display                  # 打开草稿供确认（默认行为）
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

function Out-Result($ok, $extra) {
    $o = [ordered]@{ ok = $ok }
    if ($extra) { foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] } }
    $o | ConvertTo-Json -Compress
}

try {
    $outlook = New-Object -ComObject Outlook.Application
} catch {
    Out-Result $false @{ error = "无法连接 Outlook（请确认已安装 Outlook 桌面版并登录工作账号）：$($_.Exception.Message)" }
    exit 1
}
$ns = $outlook.GetNamespace("MAPI")

try {
    $mail = $null
    $mode = "new"
    if ($ReplyEntryId)      { $mail = $ns.GetItemFromID($ReplyEntryId).Reply();    $mode = "reply" }
    elseif ($ReplyAllEntryId){ $mail = $ns.GetItemFromID($ReplyAllEntryId).ReplyAll(); $mode = "replyAll" }
    elseif ($ForwardEntryId) { $mail = $ns.GetItemFromID($ForwardEntryId).Forward(); $mode = "forward" }
    else                     { $mail = $outlook.CreateItem(0) }   # 0 = olMailItem

    # 收件人
    if ($To)  { $mail.To  = $To }
    if ($Cc)  { $mail.CC  = $Cc }
    if ($Bcc) { $mail.BCC = $Bcc }
    if ($Subject -and $mode -eq "new") { $mail.Subject = $Subject }
    elseif ($Subject) { $mail.Subject = $Subject }   # 回复/转发也允许覆盖主题

    # 正文：回复/转发时把用户正文放在原文前面，保留引用原文
    if ($Body) {
        if ($Html) {
            $existing = ""
            try { $existing = [string]$mail.HTMLBody } catch {}
            $mail.HTMLBody = ($Body + $existing)
        } else {
            $existing = ""
            try { $existing = [string]$mail.Body } catch {}
            $mail.Body = ($Body + "`r`n`r`n" + $existing)
        }
    }

    foreach ($p in $Attachments) {
        if ($p -and (Test-Path -LiteralPath $p)) { [void]$mail.Attachments.Add((Resolve-Path -LiteralPath $p).Path) }
    }

    # 收件人解析校验（避免发到无法解析的地址）
    try { [void]$mail.Recipients.ResolveAll() } catch {}

    if ($Send) {
        $mail.Send()
        Out-Result $true @{ action = "sent"; mode = $mode; to = $To; subject = [string]$mail.Subject }
    } else {
        # 默认：打开草稿供人工确认（更安全）
        $mail.Display($true)
        Out-Result $true @{ action = "draft_displayed"; mode = $mode; to = $To; subject = [string]$mail.Subject; note = "已打开草稿，请人工确认后发送；如需程序直接发送请加 -Send" }
    }
} catch {
    Out-Result $false @{ error = $_.Exception.Message }
    exit 1
}
