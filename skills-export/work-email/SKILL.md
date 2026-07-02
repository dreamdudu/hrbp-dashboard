---
name: work-email
description: >-
  Operate the user's work mailbox on Windows by automating the locally installed
  Microsoft Outlook desktop app through COM. Use this skill when the agent needs to
  read recent work emails, search messages by time window / sender / keyword / unread
  state, or compose, reply, or forward mail from the user's signed-in Exchange work
  account. Windows + Outlook desktop (logged into the work Exchange account) required.
license: internal
version: 1.0.0
---

# Work Email (Outlook COM)

Automate the user's **work mailbox** by driving the **locally installed Microsoft Outlook
desktop application** via COM automation. This is how you read and send mail from the
user's real Exchange/Microsoft 365 work account without any API keys, OAuth, or passwords —
it reuses the Outlook profile that is already signed in on the machine.

This skill is distilled from a production HRBP dashboard whose backend reads the user's
Outlook inbox this exact way; the read path here is the battle‑tested code, and send/
reply/forward use the same COM object model.

## When to use
- "Read/收一下我最近的工作邮件" → `scripts/email_read.ps1`
- "有没有 X 发来的 / 关于 Y 的 / 未读邮件" → `scripts/email_read.ps1` with filters
- "给 X 发一封邮件 / 回复这封 / 转发给 Y" → `scripts/email_send.ps1`

## Hard prerequisites (read first)
1. **Runs only on the Windows machine where Outlook desktop is installed and already
   signed into the work (Exchange/M365) account.** COM automates that local profile.
   It will NOT work on a server without Outlook, nor for Outlook Web (OWA) only.
2. PowerShell (Windows PowerShell 5.1 or PowerShell 7). No admin needed.
3. Do not run inside a session where Outlook is blocked by policy. If Outlook is closed,
   COM will launch it silently.
4. All scripts print/accept **UTF‑8**; emails are Chinese/English mixed.

## Capabilities & how to invoke

### 1) Read / search inbox — `scripts/email_read.ps1`
Reads the newest mail first, filters, and prints a JSON array to stdout.

```powershell
# 最近 3 天的收件箱（默认 Inbox，最多 60 封）
pwsh -File scripts/email_read.ps1 -Start "2026-06-28 00:00:00" -End "2026-07-01 23:59:59"

# 只看未读、来自某人、含关键词
pwsh -File scripts/email_read.ps1 -Days 7 -Unread -From "zhang" -Keyword "费用"

# 读“已发送”文件夹
pwsh -File scripts/email_read.ps1 -Days 14 -Folder Sent
```
Output item fields: `entryId, subject, from, fromAddress, to, cc, received, unread,
hasAttachments, attachmentNames, bodyPreview, body`.
Use `entryId` later to reply/forward that exact message.

### 2) Send / reply / forward — `scripts/email_send.ps1`
```powershell
# 新邮件（纯文本）。默认 -Send 直接发送；去掉 -Send 改为 -Display 打开草稿让用户确认
pwsh -File scripts/email_send.ps1 -To "a@corp.com;b@corp.com" -Cc "c@corp.com" `
     -Subject "月度费用确认" -Body "王工好，请审批附件费用。" -Send

# HTML 正文 + 附件
pwsh -File scripts/email_send.ps1 -To "a@corp.com" -Subject "报表" `
     -Body "<p>见附件</p>" -Html -Attachments "C:\r\june.xlsx" -Send

# 回复 / 全部回复 / 转发某封已读到的邮件（用 email_read 得到的 entryId）
pwsh -File scripts/email_send.ps1 -ReplyEntryId "<entryId>" -Body "收到，已审批。" -Send
pwsh -File scripts/email_send.ps1 -ReplyAllEntryId "<entryId>" -Body "同意。" -Send
pwsh -File scripts/email_send.ps1 -ForwardEntryId "<entryId>" -To "d@corp.com" -Body "请跟进" -Send
```

## Agent operating rules (important)
- **Confirm before sending.** For any outbound mail, default to `-Display` (opens a draft
  for the human to review/send) unless the user explicitly said to send. Only use `-Send`
  when the user clearly authorized sending. Sending email is outward‑facing and hard to undo.
- To reply/forward the correct message, first `email_read.ps1` to get its `entryId`, then
  pass that id — never guess.
- Never fabricate email content, recipients, or that a mail was sent. Report the script's
  actual result (it prints JSON `{ok, ...}`).
- Respect the read window; scanning is capped (default 600 items) to stay fast on big mailboxes.

See `references/outlook-com-notes.md` for the object‑model details and gotchas
(Exchange address resolution, item classes, folder ids, security prompts, encoding).
