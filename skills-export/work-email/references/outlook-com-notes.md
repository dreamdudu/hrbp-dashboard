# Outlook COM — 对象模型要点与坑（工作邮箱自动化）

这些是从生产代码里踩实的关键点，agent 复用/改写脚本时务必遵守。

## 连接与前提
- 入口：`New-Object -ComObject Outlook.Application` → `$app.GetNamespace("MAPI")`。
- 它自动化的是**本机已登录的 Outlook 桌面配置**（工作 Exchange/M365 账号）。因此：
  - 必须在装有 Outlook 桌面版、且该账号已登录的 Windows 机器上运行；
  - 无 API key / OAuth / 密码；权限即当前 Windows 用户的 Outlook 权限；
  - Outlook 没开时 COM 会静默拉起它。
- 不适用于纯 OWA（网页版）或无 Outlook 的服务器。那种情况要改用 Microsoft Graph API（另一套鉴权，不在本 skill 范围）。

## 文件夹
- `GetDefaultFolder(n)`：`6`=收件箱(Inbox)，`5`=已发送(Sent Mail)，`4`=已发送队列，`3`=已删除，`9`=日历，`10`=联系人。
- 子文件夹：`$folder.Folders.Item("名称")`。

## 遍历与过滤
- `$folder.Items.Sort("[ReceivedTime]", $true)` 按时间倒序（已发送用 `[SentOn]`）。倒序后一旦遇到早于时间窗的邮件即可 `break`，避免全量扫描。
- **务必判断条目类型**：`$item.Class -eq 43`（olMail）才是普通邮件；会议邀请、日志、投递回执等混在 Items 里，不加判断会取到错误字段/报错。
- 大邮箱要设**扫描上限**（示例脚本默认扫 600 封），否则可能很慢。
- 也可用 `$folder.Items.Restrict("[Unread]=true")` 或 `Restrict("[ReceivedTime] >= '...'")` 做服务端过滤，效率更高（DASL/日期格式需按区域设置）。

## 发件人真实地址（最容易错的点）
- `$item.SenderEmailAddress` 对**企业内部发件人**常返回 Exchange DN，形如 `/o=ExchangeLabs/ou=.../cn=...`，不是邮箱。
- 解析成真实 SMTP：`$item.Sender.GetExchangeUser().PrimarySmtpAddress`（先判断以 `/` 开头再解析，外部发件人本就是 SMTP，不用解析）。

## 常用字段
- 读：`Subject / Body / HTMLBody / SenderName / SenderEmailAddress / To / CC / ReceivedTime / SentOn / UnRead / EntryID / Attachments(.FileName)`。
- `EntryID` 是某封邮件的稳定 id；先用 read 拿到，再 `GetItemFromID($id)` 精确回复/转发它，**不要靠主题猜**。

## 发送 / 回复 / 转发
- 新邮件：`$app.CreateItem(0)`（0=olMailItem），设 `To/CC/BCC/Subject/Body`（或 `HTMLBody`），`Attachments.Add(绝对路径)`，最后 `.Send()`。
- 回复：`$item.Reply()` / `.ReplyAll()` / `.Forward()` 返回一个新草稿 MailItem，已带引用原文；把用户正文拼在原文**前面**，转发需另设 `To`。
- 发送前 `Recipients.ResolveAll()` 校验地址是否可解析。
- **安全**：`.Send()` 是对外、不可撤回的动作。默认应 `.Display($true)` 打开草稿让人工确认，只有用户明确授权才 `.Send()`。
- 少数被 AV/组策略管控的环境里，程序化 `.Send()`/读取正文可能弹出 Outlook 的"程序正在访问邮件"安全提示；现代带杀软的环境通常放行。

## 编码
- CJK 邮件很多：脚本里 `[Console]::OutputEncoding = [Text.Encoding]::UTF8`，输出 UTF‑8 JSON，供上游 agent 解析。

## 稳健性
- 每个字段取值都 `try{}catch{}` 兜底（个别邮件属性会抛异常），单封失败不影响整体。
- 正文可能极长，按需截断（示例：预览 160 字，全文上限 8000 字）。
