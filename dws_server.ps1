$localBin = Join-Path $env:USERPROFILE ".local\bin"
$env:PATH = $localBin + ";" + [Environment]::GetEnvironmentVariable("PATH", "User") + ";" + [Environment]::GetEnvironmentVariable("PATH", "Machine")
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir
$logsDir = Join-Path $scriptDir "logs"
if (-not [System.IO.Directory]::Exists($logsDir)) { [void][System.IO.Directory]::CreateDirectory($logsDir) }
$logPath = Join-Path $logsDir "dws_server.log"
$maxLogBytes = 5MB
function Invoke-LogRotation([string] $Path) {
    try {
        if ([System.IO.File]::Exists($Path) -and ((Get-Item -LiteralPath $Path).Length -gt $maxLogBytes)) {
            $dir = [System.IO.Path]::GetDirectoryName($Path)
            $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
            $rotated = Join-Path $dir ($base + "." + (Get-Date).ToString("yyyyMMdd-HHmmss") + ".log")
            Move-Item -LiteralPath $Path -Destination $rotated -Force
        }
    } catch {}
}

# Single-instance mutex: allow only one server process per board directory, preventing port churn from repeated launches
$md5 = [System.Security.Cryptography.MD5]::Create()
$dirBytes = [System.Text.Encoding]::UTF8.GetBytes($scriptDir.ToLowerInvariant())
$dirHash = ([System.BitConverter]::ToString($md5.ComputeHash($dirBytes))).Replace('-', '')
$mutexName = "Global\HRBP_DWS_Server_" + $dirHash
# Use WaitOne(0) to test ownership rather than object existence: only a process that truly holds the lock is the running server,
# so a blocked instance merely holding a handle won't make later instances wrongly think a server is already running
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($false, $mutexName, [ref]$createdNew)
$acquired = $false
try { $acquired = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
if (-not $acquired) {
    # Another instance holds the lock (the actually running server): exit immediately, do not grab another port
    try {
        Invoke-LogRotation $logPath
        Add-Content -Path $logPath -Encoding utf8 -Value "$((Get-Date).ToString("s")) another server instance is already running, exiting pid=$PID"
    } catch {}
    exit 0
}
# This process now owns the lock; keep the reference for the process lifetime
$script:SingletonMutex = $mutex
$dataDir = Join-Path $scriptDir "data"
$backupDir = Join-Path $dataDir "backups"
$statePath = Join-Path $dataDir "dashboard-state.json"
$dwsPath = Join-Path $localBin "dws.exe"
if (-not [System.IO.File]::Exists($dwsPath)) {
    $dwsCommand = Get-Command dws -ErrorAction SilentlyContinue
    if ($dwsCommand) { $dwsPath = $dwsCommand.Source }
}

function Write-ServerLog {
    param([string] $Message)
    try {
        Invoke-LogRotation $logPath
        Add-Content -Path $logPath -Encoding utf8 -Value "$((Get-Date).ToString("s")) $Message"
    } catch {}
}

function Ensure-DataStore {
    if (-not [System.IO.Directory]::Exists($dataDir)) {
        [void][System.IO.Directory]::CreateDirectory($dataDir)
    }
    if (-not [System.IO.Directory]::Exists($backupDir)) {
        [void][System.IO.Directory]::CreateDirectory($backupDir)
    }
}

function New-DefaultStateJson {
    $state = @{
        version = 1
        tasks = @()
        calendar = @()
        settings = @{}
        updatedAt = (Get-Date).ToString("o")
    }
    return ($state | ConvertTo-Json -Depth 20)
}

function Get-StateJson {
    Ensure-DataStore
    if (-not [System.IO.File]::Exists($statePath)) {
        $json = New-DefaultStateJson
        [System.IO.File]::WriteAllText($statePath, $json, [Text.Encoding]::UTF8)
        return $json
    }
    return [System.IO.File]::ReadAllText($statePath, [Text.Encoding]::UTF8)
}

function Save-StateJson {
    param([string] $Json)

    Ensure-DataStore
    [void]($Json | ConvertFrom-Json)
    if ([System.IO.File]::Exists($statePath)) {
        $stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
        Copy-Item -LiteralPath $statePath -Destination (Join-Path $backupDir "dashboard-state-$stamp.json") -Force
    }
    $tmpPath = "$statePath.tmp"
    [System.IO.File]::WriteAllText($tmpPath, $Json, [Text.Encoding]::UTF8)
    Move-Item -LiteralPath $tmpPath -Destination $statePath -Force
}

$mime = @{
    ".html" = "text/html; charset=utf-8"
    ".css"  = "text/css; charset=utf-8"
    ".js"   = "application/javascript; charset=utf-8"
    ".json" = "application/json; charset=utf-8"
    ".png"  = "image/png"
    ".jpg"  = "image/jpeg"
    ".jpeg" = "image/jpeg"
    ".svg"  = "image/svg+xml; charset=utf-8"
    ".ico"  = "image/x-icon"
}

function New-BoardListener {
    $ports = @()
    $ports += 18632..18680
    $ports += 28080..28120

    foreach ($port in $ports) {
        try {
            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
            $listener.Start()
            return @{ Listener = $listener; Port = $port }
        } catch {
            if ($listener) {
                try { $listener.Stop() } catch {}
            }
        }
    }

    throw "No available local port found."
}

function Send-HttpResponse {
    param(
        [System.Net.Sockets.TcpClient] $Client,
        [int] $StatusCode,
        [string] $StatusText,
        [string] $ContentType,
        [byte[]] $Body
    )

    if ($null -eq $Body) { $Body = [byte[]]::new(0) }
    $stream = $Client.GetStream()
    $headers = @(
        "HTTP/1.1 $StatusCode $StatusText",
        "Content-Type: $ContentType",
        "Content-Length: $($Body.Length)",
        "Access-Control-Allow-Origin: *",
        "Cache-Control: no-cache, no-store, must-revalidate",
        "Connection: close",
        "",
        ""
    ) -join "`r`n"

    $headerBytes = [Text.Encoding]::ASCII.GetBytes($headers)
    $stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($Body.Length -gt 0) {
        $stream.Write($Body, 0, $Body.Length)
    }
}

function Get-SafePath {
    param([string] $RequestPath)

    if ([string]::IsNullOrWhiteSpace($RequestPath) -or $RequestPath -eq "/") {
        $RequestPath = "/index.html"
    }

    $cleanPath = [Uri]::UnescapeDataString(($RequestPath -split "\?")[0]).TrimStart("/")
    $fullPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($scriptDir, $cleanPath))
    $rootPath = [System.IO.Path]::GetFullPath($scriptDir)

    if (-not $fullPath.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    return $fullPath
}

function Invoke-DwsCalendarList {
    param([string] $EndDate)

    if (-not [System.IO.File]::Exists($dwsPath)) {
        throw "Cannot find dws.exe. Expected at $localBin\dws.exe."
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $dwsPath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
    $args = @("calendar", "event", "list", "--start", "2026-06-01T00:00:00+08:00", "--end", $EndDate, "--format", "json")
    $startInfo.Arguments = ($args | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join " "

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    $body = if ($stdout.Trim()) { $stdout } else { $stderr }
    return @{ ExitCode = $process.ExitCode; Body = $body }
}

function Invoke-DwsCalendarDelete {
    param([string] $EventId)

    if ([string]::IsNullOrWhiteSpace($EventId)) {
        throw "Missing DingTalk calendar eventId."
    }
    if (-not [System.IO.File]::Exists($dwsPath)) {
        throw "Cannot find dws.exe. Expected at $localBin\dws.exe."
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $dwsPath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
    $args = @("calendar", "event", "delete", "--id", $EventId, "--format", "json", "-y")
    $startInfo.Arguments = ($args | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join " "

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    $body = if ($stdout.Trim()) { $stdout } else { $stderr }
    return @{ ExitCode = $process.ExitCode; Body = $body; Error = $stderr }
}

function Start-DwsLogin {
    if (-not [System.IO.File]::Exists($dwsPath)) {
        throw "Cannot find dws.exe. Expected at $localBin\dws.exe."
    }

    $cmdLine = '"' + $dwsPath + '" auth login --force & echo. & echo ============================================== & echo  If the browser did not open automatically, & echo  copy the URL above into your browser to login. & echo  After login, close this window and refresh the board. & echo ============================================== & pause'
    Start-Process -FilePath "cmd.exe" -ArgumentList "/k", $cmdLine -WindowStyle Normal
}

function Get-SafeFileName {
    param([string] $Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return "file" }
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $sb = $Name
    foreach ($c in $invalid) { $sb = $sb.Replace([string]$c, "_") }
    $sb = $sb.Trim().TrimStart(".")
    if ([string]::IsNullOrWhiteSpace($sb)) { return "file" }
    if ($sb.Length -gt 120) { $sb = $sb.Substring(0, 120) }
    return $sb
}

function Get-TaskAttachmentDir {
    param([string] $TaskId)
    $safeId = Get-SafeFileName $TaskId
    $dir = Join-Path (Join-Path $dataDir "attachments") $safeId
    if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    return @{ Dir = $dir; SafeId = $safeId }
}

function Get-AnalyticsDir {
    param([string] $Cat)
    if ([string]::IsNullOrWhiteSpace($Cat)) { $Cat = "personnel-cost" }
    if ($Cat -notmatch '^[a-z0-9\-]+$' -or @('personnel-cost') -notcontains $Cat) { throw "Invalid analytics category." }
    $dir = Join-Path (Join-Path $dataDir "analytics") $Cat
    $filesDir = Join-Path $dir "files"
    if (-not [System.IO.Directory]::Exists($filesDir)) { [void][System.IO.Directory]::CreateDirectory($filesDir) }
    return @{ Dir = $dir; Files = $filesDir }
}

function Get-TaskArchiveDir {
    $dir = Join-Path $dataDir "task-archive"
    $entries = Join-Path $dir "entries"
    if (-not [System.IO.Directory]::Exists($entries)) { [void][System.IO.Directory]::CreateDirectory($entries) }
    return @{ Dir = $dir; Entries = $entries }
}

function Start-AnalyticsParse {
    param([string] $Cat)
    $node = (Get-Command node -ErrorAction SilentlyContinue).Source
    if (-not $node) { return }
    $script = Join-Path $scriptDir "analytics\parse_personnel_cost.js"
    if ([System.IO.File]::Exists($script)) {
        try { Start-Process -FilePath $node -ArgumentList ('"' + $script + '"') -WindowStyle Hidden } catch {}
    }
}

function Test-DingtalkReachable {
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch {}
    try {
        $req = [System.Net.WebRequest]::Create("https://oapi.dingtalk.com/")
        $req.Method = "GET"
        $req.Timeout = 7000
        $req.ReadWriteTimeout = 7000
        try {
            $resp = $req.GetResponse()
            $resp.Close()
            return $true
        } catch [System.Net.WebException] {
            $st = $_.Exception.Status
            if ($st -eq [System.Net.WebExceptionStatus]::ProtocolError) { return $true }
            if ($st -eq [System.Net.WebExceptionStatus]::Timeout -or
                $st -eq [System.Net.WebExceptionStatus]::ConnectFailure -or
                $st -eq [System.Net.WebExceptionStatus]::NameResolutionFailure -or
                $st -eq [System.Net.WebExceptionStatus]::SecureChannelFailure -or
                $st -eq [System.Net.WebExceptionStatus]::TrustFailure -or
                $st -eq [System.Net.WebExceptionStatus]::SendFailure -or
                $st -eq [System.Net.WebExceptionStatus]::ReceiveFailure) { return $false }
            return $true
        }
    } catch {
        return $false
    }
}

function Invoke-DwsJson {
    param([string[]] $DwsArgs)

    if (-not [System.IO.File]::Exists($dwsPath)) {
        throw "Cannot find dws.exe. Expected at $localBin\dws.exe."
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $dwsPath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
    $startInfo.Arguments = ($DwsArgs | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join " "

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    $body = if ($stdout.Trim()) { $stdout } else { $stderr }
    return @{ ExitCode = $process.ExitCode; Body = $body }
}

$script:dwsSelfInfo = $null
function Get-DwsSelfInfo {
    if ($script:dwsSelfInfo) { return $script:dwsSelfInfo }
    try {
        $res = Invoke-DwsJson @("contact", "user", "get-self", "--format", "json")
        if ($res.ExitCode -eq 0 -and $res.Body) {
            $parsed = $res.Body | ConvertFrom-Json
            $model = $null
            if ($parsed.result -and $parsed.result.Count -gt 0) { $model = $parsed.result[0].orgEmployeeModel }
            if ($model) {
                $script:dwsSelfInfo = @{ name = [string]$model.orgUserName; userId = [string]$model.userId }
                return $script:dwsSelfInfo
            }
        }
    } catch {
        Write-ServerLog "get-self exception: $($_.Exception.Message)"
    }
    return @{ name = ""; userId = "" }
}

function Get-QueryValue {
    param([string] $RequestPath, [string] $Key)

    $m = [regex]::Match($RequestPath, [regex]::Escape($Key) + "=([^&]*)")
    if (-not $m.Success) { return "" }
    return [Uri]::UnescapeDataString($m.Groups[1].Value.Replace("+", " "))
}

function Invoke-DwsMessageSync {
    param([string] $StartTime, [string] $EndTime)

    $convMap = [ordered]@{}
    $cursor = "0"
    $pages = 0
    $hasMore = $false

    while ($pages -lt 8) {
        $res = Invoke-DwsJson @("chat", "message", "list-all", "--start", $StartTime, "--end", $EndTime, "--limit", "50", "--cursor", $cursor, "--format", "json")
        if ($res.ExitCode -ne 0) {
            throw "dws chat message list-all failed (exit=$($res.ExitCode)): $($res.Body)"
        }
        $parsed = $res.Body | ConvertFrom-Json
        $result = if ($parsed.result) { $parsed.result } else { $parsed }
        $list = @()
        if ($result.conversationMessagesList) { $list = @($result.conversationMessagesList) }

        foreach ($conv in $list) {
            $cid = [string]$conv.openConversationId
            if (-not $convMap.Contains($cid)) {
                $convMap[$cid] = @{
                    openConversationId = $cid
                    title = [string]$conv.title
                    singleChat = [bool]$conv.singleChat
                    messages = [System.Collections.ArrayList]::new()
                }
            }
            foreach ($msg in @($conv.messages)) {
                [void]$convMap[$cid].messages.Add(@{
                    content = [string]$msg.content
                    createTime = [string]$msg.createTime
                    sender = [string]$msg.sender
                    senderOpenDingTalkId = [string]$msg.senderOpenDingTalkId
                    openMessageId = [string]$msg.openMessageId
                })
            }
        }

        $pages++
        $hasMore = [bool]$result.hasMore
        $cursor = [string]$result.nextCursor
        if (-not $hasMore -or [string]::IsNullOrWhiteSpace($cursor)) { break }
    }

    $conversations = @()
    foreach ($key in $convMap.Keys) {
        $entry = $convMap[$key]
        $entry.messages = @($entry.messages)
        $conversations += $entry
    }

    return @{
        success = $true
        self = (Get-DwsSelfInfo)
        conversations = $conversations
        pages = $pages
        hasMore = $hasMore
    }
}

function Invoke-OutlookEmailSync {
    param([string] $StartTime, [string] $EndTime, [int] $Max = 60)

    $startDt = [DateTime]::Parse($StartTime)
    $endDt = [DateTime]::Parse($EndTime)

    $outlook = $null
    try {
        $outlook = New-Object -ComObject Outlook.Application
    } catch {
        throw "无法连接 Outlook（请确保 Outlook 已安装并已登录 Exchange 账户）：$($_.Exception.Message)"
    }

    $ns = $outlook.GetNamespace("MAPI")
    $inbox = $ns.GetDefaultFolder(6)  # olFolderInbox
    $items = $inbox.Items
    try { $items.Sort("[ReceivedTime]", $true) } catch {}  # newest first

    $emails = @()
    $count = 0
    $scanned = 0
    foreach ($item in $items) {
        if ($count -ge $Max) { break }
        $scanned++
        if ($scanned -gt 600) { break }

        $cls = 0
        try { $cls = [int]$item.Class } catch {}
        if ($cls -ne 43) { continue }  # olMail only

        $rt = $null
        try { $rt = [DateTime]$item.ReceivedTime } catch { continue }
        if ($rt -lt $startDt) { break }   # sorted desc: everything after is older
        if ($rt -gt $endDt) { continue }

        $subject = ""; $body = ""; $fromName = ""; $fromAddr = ""; $toStr = ""; $ccStr = ""
        try { $subject = [string]$item.Subject } catch {}
        try { $body = [string]$item.Body } catch {}
        try { $fromName = [string]$item.SenderName } catch {}
        try {
            $fromAddr = [string]$item.SenderEmailAddress
            if ($fromAddr -like "/*") {
                try {
                    $eu = $item.Sender.GetExchangeUser()
                    if ($eu -and $eu.PrimarySmtpAddress) { $fromAddr = [string]$eu.PrimarySmtpAddress }
                } catch {}
            }
        } catch {}
        try { $toStr = [string]$item.To } catch {}
        try { $ccStr = [string]$item.CC } catch {}

        if ($body.Length -gt 4000) { $body = $body.Substring(0, 4000) }

        $emails += @{
            subject = $subject
            from = $fromName
            fromAddress = $fromAddr
            to = $toStr
            cc = $ccStr
            received = $rt.ToString("yyyy-MM-dd HH:mm:ss")
            body = $body
        }
        $count++
    }

    return @{ success = $true; emails = @($emails); count = $count; scanned = $scanned }
}

$server = New-BoardListener
$listener = $server.Listener
$port = $server.Port
$port | Out-File "$scriptDir\.port.txt" -Encoding ascii
Write-ServerLog "server started pid=$PID port=$port statePath=$statePath"

$year = (Get-Date).Year
$endDate = "$year-12-31T23:59:59+08:00"

while ($true) {
    $client = $null
    try {
        $client = $listener.AcceptTcpClient()
        $client.ReceiveTimeout = 60000
        $stream = $client.GetStream()
        # 按字节读取请求头(读到 CRLF CRLF 为止)，再按 Content-Length 精确读满请求体后 UTF-8 解码。
        # 旧实现用 StreamReader.Read 单次按字符读取，大请求体(base64 附件)会跨多个 TCP 段被截断，导致 FromBase64String 失败 → HTTP 500。
        $headList = New-Object System.Collections.Generic.List[byte]
        while ($true) {
            $bb = $stream.ReadByte()
            if ($bb -lt 0) { break }
            $headList.Add([byte]$bb)
            $hc = $headList.Count
            if ($hc -ge 4 -and $headList[$hc - 4] -eq 13 -and $headList[$hc - 3] -eq 10 -and $headList[$hc - 2] -eq 13 -and $headList[$hc - 1] -eq 10) { break }
        }
        $headerText = [Text.Encoding]::ASCII.GetString($headList.ToArray())
        $headerLines = $headerText -split "`r`n"
        $requestLine = $headerLines[0]

        if ([string]::IsNullOrWhiteSpace($requestLine)) {
            Send-HttpResponse $client 400 "Bad Request" "text/plain; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes("Bad Request"))
            continue
        }

        $contentLength = 0
        foreach ($line in $headerLines) {
            if ($line -match '^Content-Length:\s*(\d+)') { $contentLength = [int]$matches[1] }
        }

        $parts = $requestLine -split " "
        $method = $parts[0]
        $requestPath = $parts[1]
        $bodyText = ""
        if ($contentLength -gt 0) {
            $bodyBytes = New-Object byte[] $contentLength
            $totalRead = 0
            while ($totalRead -lt $contentLength) {
                $r = $stream.Read($bodyBytes, $totalRead, $contentLength - $totalRead)
                if ($r -le 0) { break }
                $totalRead += $r
            }
            $bodyText = [Text.Encoding]::UTF8.GetString($bodyBytes, 0, $totalRead)
        }

        if ($method -eq "OPTIONS") {
            Send-HttpResponse $client 204 "No Content" "text/plain; charset=utf-8" ([byte[]]::new(0))
            continue
        }

        if ($requestPath -eq "/auth-login") {
            try {
                Start-DwsLogin
                $message = @{ success = $true; message = "auth_started" } | ConvertTo-Json -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            } catch {
                Write-ServerLog "auth-login exception: $($_.Exception.GetType().FullName) $($_.Exception.Message)"
                $message = @{ success = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 500 "Internal Server Error" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            }
            continue
        }

        if ($requestPath -eq "/auth-status") {
            try {
                if (-not (Test-DingtalkReachable)) {
                    $message = @{ success = $true; authenticated = $false; network = $true } | ConvertTo-Json -Compress
                } else {
                    $res = Invoke-DwsJson @("contact", "user", "get-self", "--format", "json")
                    $body = if ($res.Body) { [string]$res.Body } else { "" }
                    $authed = $true
                    if ($body -match 'not_authenticated' -or $res.ExitCode -ne 0) { $authed = $false }
                    $message = @{ success = $true; authenticated = $authed; network = $false } | ConvertTo-Json -Compress
                }
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            } catch {
                Write-ServerLog "auth-status exception: $($_.Exception.Message)"
                $message = @{ success = $false; authenticated = $true; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            }
            continue
        }

        if ($requestPath -eq "/api/state" -and $method -eq "GET") {
            try {
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes((Get-StateJson)))
            } catch {
                Write-ServerLog "state get exception: $($_.Exception.GetType().FullName) $($_.Exception.Message)"
                $message = @{ success = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 500 "Internal Server Error" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            }
            continue
        }

        if ($requestPath -eq "/api/state" -and $method -eq "POST") {
            try {
                $payload = $bodyText | ConvertFrom-Json
                if (-not $payload.payload) { throw "Missing state payload." }
                $stateJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$payload.payload))
                Save-StateJson $stateJson
                $message = @{ success = $true; savedAt = (Get-Date).ToString("o") } | ConvertTo-Json -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            } catch {
                Write-ServerLog "state save exception: $($_.Exception.GetType().FullName) $($_.Exception.Message)"
                $message = @{ success = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 500 "Internal Server Error" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            }
            continue
        }

        if ($requestPath -eq "/delete-calendar-event" -and $method -eq "POST") {
            try {
                $payload = if ([string]::IsNullOrWhiteSpace($bodyText)) { $null } else { $bodyText | ConvertFrom-Json }
                $eventId = ""
                if ($payload -and $payload.eventId) { $eventId = [string]$payload.eventId }
                if ([string]::IsNullOrWhiteSpace($eventId)) { throw "Missing DingTalk calendar eventId." }

                $dwsResult = Invoke-DwsCalendarDelete $eventId
                $body = if ($dwsResult.Body) { [string]$dwsResult.Body } else { "" }
                if ($dwsResult.ExitCode -ne 0 -or $body -match '"error"\s*:') {
                    Write-ServerLog "delete-calendar-event dws exit=$($dwsResult.ExitCode) body=$body"
                    $message = @{ success = $false; error = $body; exitCode = $dwsResult.ExitCode } | ConvertTo-Json -Compress
                    Send-HttpResponse $client 502 "Bad Gateway" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
                } else {
                    $message = @{ success = $true; eventId = $eventId; result = $body } | ConvertTo-Json -Compress
                    Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
                }
            } catch {
                Write-ServerLog "delete-calendar-event exception: $($_.Exception.GetType().FullName) $($_.Exception.Message)"
                $message = @{ success = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 400 "Bad Request" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            }
            continue
        }

        if ($requestPath -eq "/upload-attachment" -and $method -eq "POST") {
            try {
                $payload = $bodyText | ConvertFrom-Json
                $taskId = [string]$payload.taskId
                $name = [string]$payload.name
                $b64 = [string]$payload.dataBase64
                if ([string]::IsNullOrWhiteSpace($taskId) -or [string]::IsNullOrWhiteSpace($name)) { throw "Missing taskId or name." }

                $info = Get-TaskAttachmentDir $taskId
                $safe = Get-SafeFileName $name
                $target = Join-Path $info.Dir $safe
                $baseName = [System.IO.Path]::GetFileNameWithoutExtension($safe)
                $ext = [System.IO.Path]::GetExtension($safe)
                $i = 1
                while ([System.IO.File]::Exists($target)) {
                    $safe = "$baseName($i)$ext"
                    $target = Join-Path $info.Dir $safe
                    $i++
                }
                $bytes = [Convert]::FromBase64String($b64)
                [System.IO.File]::WriteAllBytes($target, $bytes)

                $rel = "data/attachments/" + $info.SafeId + "/" + $safe
                $message = @{ success = $true; path = $rel; name = $safe; size = $bytes.Length } | ConvertTo-Json -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            } catch {
                Write-ServerLog "upload-attachment exception: $($_.Exception.Message)"
                $message = @{ success = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 500 "Internal Server Error" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            }
            continue
        }

        if ($requestPath -like "/open-folder*") {
            try {
                $taskId = Get-QueryValue $requestPath "task"
                if ([string]::IsNullOrWhiteSpace($taskId)) { throw "Missing task parameter." }
                $info = Get-TaskAttachmentDir $taskId
                Start-Process explorer.exe $info.Dir
                $message = @{ success = $true; dir = $info.Dir } | ConvertTo-Json -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            } catch {
                Write-ServerLog "open-folder exception: $($_.Exception.Message)"
                $message = @{ success = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 500 "Internal Server Error" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            }
            continue
        }

        if ($requestPath -like "/contact-lookup*") {
            try {
                $name = Get-QueryValue $requestPath "name"
                if ([string]::IsNullOrWhiteSpace($name)) { throw "Missing name parameter." }

                $user = $null
                $res = Invoke-DwsJson @("contact", "user", "search", "--query", $name, "--format", "json")
                if ($res.ExitCode -eq 0 -and $res.Body) {
                    $parsed = $res.Body | ConvertFrom-Json
                    if ($parsed.result -and @($parsed.result).Count -gt 0) { $user = @($parsed.result)[0] }
                }
                if (-not $user) {
                    $cnPattern = "[" + [char]0x4E00 + "-" + [char]0x9FA5 + "]{2,}"
                    $cn = [regex]::Match($name, $cnPattern)
                    if ($cn.Success -and $cn.Value -ne $name) {
                        $res2 = Invoke-DwsJson @("contact", "user", "search", "--query", $cn.Value, "--format", "json")
                        if ($res2.ExitCode -eq 0 -and $res2.Body) {
                            $parsed2 = $res2.Body | ConvertFrom-Json
                            if ($parsed2.result -and @($parsed2.result).Count -gt 0) { $user = @($parsed2.result)[0] }
                        }
                    }
                }

                $jobNumber = ""
                $dirName = ""
                if ($user -and $user.userId) {
                    $detailRes = Invoke-DwsJson @("contact", "user", "get", "--ids", [string]$user.userId, "--format", "json")
                    if ($detailRes.ExitCode -eq 0 -and $detailRes.Body) {
                        try {
                            $detail = $detailRes.Body | ConvertFrom-Json
                            if ($detail.result -and @($detail.result).Count -gt 0) {
                                $model = @($detail.result)[0].orgEmployeeModel
                                if ($model) {
                                    $jobNumber = [string]$model.jobNumber
                                    $dirName = [string]$model.orgUserName
                                }
                            }
                        } catch {}
                    }
                }

                $payload = if ($user) {
                    $finalName = if ($dirName) { $dirName } else { [string]$user.name }
                    @{ success = $true; user = @{ name = $finalName; userId = [string]$user.userId; jobNumber = $jobNumber; openDingTalkId = [string]$user.openDingTalkId } }
                } else {
                    @{ success = $true; user = $null }
                }
                $json = $payload | ConvertTo-Json -Depth 4 -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($json))
            } catch {
                Write-ServerLog "contact-lookup exception: $($_.Exception.Message)"
                $message = @{ success = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 502 "Bad Gateway" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            }
            continue
        }

        if ($requestPath -eq "/oa-login") {
            try {
                $loginScript = Join-Path $scriptDir "oa_open_login.ps1"
                Start-Process -FilePath "powershell.exe" -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $loginScript -WindowStyle Hidden
                $message = @{ success = $true } | ConvertTo-Json -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            } catch {
                Write-ServerLog "oa-login exception: $($_.Exception.Message)"
                $message = @{ success = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 500 "Internal Server Error" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            }
            continue
        }

        if ($requestPath -eq "/oa-status") {
            try {
                $running = $false; $loggedIn = $false
                try {
                    $resp = Invoke-WebRequest "http://127.0.0.1:9333/json" -UseBasicParsing -TimeoutSec 4
                    $running = $true
                    $tabs = $resp.Content | ConvertFrom-Json
                    $pages = @($tabs | Where-Object { $_.type -eq 'page' })
                    $oa = @($pages | Where-Object { $_.url -like '*zmp.iwhalecloud.com*' })
                    $onLogin = @($pages | Where-Object { $_.url -like '*jinglian*' -or $_.url -like '*/login*' -or $_.url -like '*oauth2*' })
                    if ($oa.Count -gt 0 -and $onLogin.Count -eq 0) { $loggedIn = $true }
                } catch { $running = $false }
                $message = @{ success = $true; running = $running; loggedIn = $loggedIn } | ConvertTo-Json -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            } catch {
                $message = @{ success = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 500 "Internal Server Error" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            }
            continue
        }

        if ($requestPath -eq "/sync-oa") {
            try {
                $node = (Get-Command node -ErrorAction SilentlyContinue).Source
                $oaScript = Join-Path $scriptDir "oa-sync\oa_silent_sync.js"
                if (-not $node) { throw "未找到 node，请确认已安装 Node.js" }
                if (-not [System.IO.File]::Exists($oaScript)) { throw "未找到 oa_silent_sync.js（应位于 ..\oa-sync\）" }
                # 确保常驻 OA 浏览器(调试端口 9333)已启动；未启动则拉起。node 端会重试连接，无需在此阻塞等待
                $portUp = $false
                try { $tc = New-Object System.Net.Sockets.TcpClient; $tc.Connect("127.0.0.1", 9333); $tc.Close(); $portUp = $true } catch { $portUp = $false }
                if (-not $portUp) {
                    $edge = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
                    $edgeProfile = Join-Path $scriptDir "oa-sync\edge-profile"
                    $todoUrl = "https://zmp.iwhalecloud.com/fish-zmp/modules/todoItem/index.jsp"
                    if ([System.IO.File]::Exists($edge)) {
                        try { Start-Process -FilePath $edge -ArgumentList '--remote-debugging-port=9333', '--remote-allow-origins=*', ("--user-data-dir=$edgeProfile"), '--new-window', $todoUrl -WindowStyle Minimized } catch {}
                    }
                }
                Start-Process -FilePath $node -ArgumentList ('"' + $oaScript + '"') -WindowStyle Hidden
                $message = @{ success = $true; started = $true; browserWasUp = $portUp } | ConvertTo-Json -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            } catch {
                Write-ServerLog "sync-oa exception: $($_.Exception.Message)"
                $message = @{ success = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 500 "Internal Server Error" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            }
            continue
        }

        if ($requestPath -like "/analytics-status*") {
            try {
                $info = Get-AnalyticsDir (Get-QueryValue $requestPath "cat")
                $sp = Join-Path $info.Dir "_status.json"
                $body = if ([System.IO.File]::Exists($sp)) { [System.IO.File]::ReadAllText($sp, [Text.Encoding]::UTF8) } else { '{"state":"empty"}' }
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($body))
            } catch {
                $message = @{ success = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 500 "Internal Server Error" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            }
            continue
        }

        if ($requestPath -like "/analytics-data*") {
            try {
                $info = Get-AnalyticsDir (Get-QueryValue $requestPath "cat")
                $ap = Join-Path $info.Dir "_agg.json"
                $body = if ([System.IO.File]::Exists($ap)) { [System.IO.File]::ReadAllText($ap, [Text.Encoding]::UTF8) } else { '{"meta":{"years":[],"rowCount":0},"byYear":{}}' }
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($body))
            } catch {
                $message = @{ success = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 500 "Internal Server Error" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            }
            continue
        }

        if ($requestPath -like "/analytics-files*") {
            try {
                $info = Get-AnalyticsDir (Get-QueryValue $requestPath "cat")
                $arr = @()
                if ([System.IO.Directory]::Exists($info.Files)) {
                    Get-ChildItem -Path $info.Files -Filter *.xlsx -File | Sort-Object Name | ForEach-Object { $arr += @{ name = $_.Name; size = $_.Length; mtime = $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm") } }
                }
                $message = @{ success = $true; files = @($arr) } | ConvertTo-Json -Depth 5 -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            } catch {
                $message = @{ success = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 500 "Internal Server Error" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            }
            continue
        }

        if ($requestPath -like "/analytics-detail*") {
            try {
                $info = Get-AnalyticsDir (Get-QueryValue $requestPath "cat")
                $dp = Join-Path $info.Dir "_detail.jsonl"
                $page = 0; [int]::TryParse((Get-QueryValue $requestPath "page"), [ref]$page) | Out-Null; if ($page -lt 1) { $page = 1 }
                $size = 0; [int]::TryParse((Get-QueryValue $requestPath "size"), [ref]$size) | Out-Null; if ($size -lt 1) { $size = 50 }; if ($size -gt 500) { $size = 500 }
                $year = Get-QueryValue $requestPath "year"
                $feeCat = Get-QueryValue $requestPath "feeCat"
                $q = Get-QueryValue $requestPath "q"
                $rows = New-Object System.Collections.Generic.List[string]
                $total = 0; $startIdx = ($page - 1) * $size
                if ([System.IO.File]::Exists($dp)) {
                    foreach ($line in [System.IO.File]::ReadLines($dp, [Text.Encoding]::UTF8)) {
                        if ([string]::IsNullOrWhiteSpace($line)) { continue }
                        if ($year -and ($line -notmatch ('"y":"' + [regex]::Escape($year) + '"'))) { continue }
                        if ($feeCat -and ($line -notmatch ('"fc":"' + [regex]::Escape($feeCat) + '"'))) { continue }
                        if ($q -and ($line.IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -lt 0)) { continue }
                        if ($total -ge $startIdx -and $rows.Count -lt $size) { $rows.Add($line) }
                        $total++
                    }
                }
                $body = '{"total":' + $total + ',"page":' + $page + ',"size":' + $size + ',"rows":[' + ($rows -join ',') + ']}'
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($body))
            } catch {
                $message = @{ success = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 500 "Internal Server Error" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            }
            continue
        }

        if ($requestPath -like "/analytics-upload*" -and $method -eq "POST") {
            try {
                $info = Get-AnalyticsDir (Get-QueryValue $requestPath "cat")
                $payload = $bodyText | ConvertFrom-Json
                $name = [string]$payload.name
                $b64 = [string]$payload.dataBase64
                if ([string]::IsNullOrWhiteSpace($name)) { throw "Missing name." }
                $safe = Get-SafeFileName $name
                if ($safe -notmatch '\.xlsx$') { throw "仅支持 .xlsx 文件" }
                $target = Join-Path $info.Files $safe
                $bytes = [Convert]::FromBase64String($b64)
                [System.IO.File]::WriteAllBytes($target, $bytes)
                Start-AnalyticsParse (Get-QueryValue $requestPath "cat")
                $message = @{ success = $true; name = $safe; size = $bytes.Length } | ConvertTo-Json -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            } catch {
                Write-ServerLog "analytics-upload exception: $($_.Exception.Message)"
                $message = @{ success = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 500 "Internal Server Error" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            }
            continue
        }

        if ($requestPath -eq "/analytics-delete-file" -and $method -eq "POST") {
            try {
                $payload = $bodyText | ConvertFrom-Json
                $cat = [string]$payload.cat
                $info = Get-AnalyticsDir $cat
                $safe = Get-SafeFileName ([string]$payload.name)
                $target = Join-Path $info.Files $safe
                if ([System.IO.File]::Exists($target)) { [System.IO.File]::Delete($target) }
                Start-AnalyticsParse $cat
                $message = @{ success = $true } | ConvertTo-Json -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            } catch {
                $message = @{ success = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 500 "Internal Server Error" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            }
            continue
        }

        if ($requestPath -like "/analytics-smart*" -and $method -eq "POST") {
            try {
                $payload = $bodyText | ConvertFrom-Json
                $info = Get-AnalyticsDir ([string]$payload.cat)
                $obj = @{ text = [string]$payload.text; at = [string]$payload.at; years = $payload.years; rowCount = $payload.rowCount }
                [System.IO.File]::WriteAllText((Join-Path $info.Dir "_smart.json"), ($obj | ConvertTo-Json -Depth 5 -Compress), (New-Object System.Text.UTF8Encoding($false)))
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes('{"success":true}'))
            } catch {
                $message = @{ success = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 500 "Internal Server Error" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            }
            continue
        }

        if ($requestPath -like "/analytics-smart*") {
            try {
                $info = Get-AnalyticsDir (Get-QueryValue $requestPath "cat")
                $sp = Join-Path $info.Dir "_smart.json"
                $body = if ([System.IO.File]::Exists($sp)) { [System.IO.File]::ReadAllText($sp, [Text.Encoding]::UTF8) } else { '{}' }
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($body))
            } catch {
                $message = @{ success = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 500 "Internal Server Error" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            }
            continue
        }

        if ($requestPath -eq "/task-archive" -and $method -eq "POST") {
            try {
                $payload = $bodyText | ConvertFrom-Json
                $id = Get-SafeFileName ([string]$payload.id)
                if ([string]::IsNullOrWhiteSpace($id)) { throw "Missing archive id." }
                $info = Get-TaskArchiveDir
                $utf8 = New-Object System.Text.UTF8Encoding($false)
                $recJson = $payload.record | ConvertTo-Json -Depth 12 -Compress
                [System.IO.File]::WriteAllText((Join-Path $info.Entries ($id + ".json")), $recJson, $utf8)
                [System.IO.File]::WriteAllText((Join-Path $info.Entries ($id + ".md")), ([string]$payload.markdown), $utf8)
                $idxObj = @{ id = $id; title = [string]$payload.title; expert = [string]$payload.expert; at = [string]$payload.at; source = [string]$payload.source; linkKind = [string]$payload.linkKind; linkId = [string]$payload.linkId }
                $idxLine = $idxObj | ConvertTo-Json -Compress
                $indexPath = Join-Path $info.Dir "_index.jsonl"
                if ([System.IO.File]::Exists($indexPath)) {
                    $kept = New-Object System.Collections.Generic.List[string]
                    foreach ($line in [System.IO.File]::ReadLines($indexPath, [Text.Encoding]::UTF8)) {
                        if (-not [string]::IsNullOrWhiteSpace($line) -and ($line -notmatch ('"id":"' + [regex]::Escape($id) + '"'))) { $kept.Add($line) }
                    }
                    $kept.Add($idxLine)
                    [System.IO.File]::WriteAllText($indexPath, (($kept -join "`n") + "`n"), $utf8)
                } else {
                    [System.IO.File]::WriteAllText($indexPath, ($idxLine + "`n"), $utf8)
                }
                $vault = [string]$payload.obsidianVault
                if (-not [string]::IsNullOrWhiteSpace($vault) -and [System.IO.Directory]::Exists($vault)) {
                    try {
                        $odir = Join-Path $vault "工作存档"
                        if (-not [System.IO.Directory]::Exists($odir)) { [void][System.IO.Directory]::CreateDirectory($odir) }
                        $datePart = [string]$payload.at
                        if ($datePart.Length -ge 10) { $datePart = $datePart.Substring(0, 10) }
                        $ofname = Get-SafeFileName ($datePart + "-" + [string]$payload.title)
                        if ($ofname -notmatch '\.md$') { $ofname = $ofname + ".md" }
                        [System.IO.File]::WriteAllText((Join-Path $odir $ofname), ([string]$payload.markdown), $utf8)
                    } catch { Write-ServerLog "task-archive obsidian write failed: $($_.Exception.Message)" }
                }
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes('{"success":true}'))
            } catch {
                Write-ServerLog "task-archive exception: $($_.Exception.Message)"
                $message = @{ success = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 500 "Internal Server Error" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            }
            continue
        }

        if ($requestPath -like "/task-archive-list*") {
            try {
                $info = Get-TaskArchiveDir
                $indexPath = Join-Path $info.Dir "_index.jsonl"
                $page = 0; [int]::TryParse((Get-QueryValue $requestPath "page"), [ref]$page) | Out-Null; if ($page -lt 1) { $page = 1 }
                $size = 0; [int]::TryParse((Get-QueryValue $requestPath "size"), [ref]$size) | Out-Null; if ($size -lt 1) { $size = 15 }; if ($size -gt 100) { $size = 100 }
                $q = Get-QueryValue $requestPath "q"
                $all = New-Object System.Collections.Generic.List[string]
                if ([System.IO.File]::Exists($indexPath)) {
                    foreach ($line in [System.IO.File]::ReadLines($indexPath, [Text.Encoding]::UTF8)) {
                        if ([string]::IsNullOrWhiteSpace($line)) { continue }
                        if ($q -and ($line.IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -lt 0)) { continue }
                        $all.Add($line)
                    }
                }
                $all.Reverse()
                $total = $all.Count; $startIdx = ($page - 1) * $size
                $rows = New-Object System.Collections.Generic.List[string]
                for ($i = $startIdx; $i -lt [Math]::Min($startIdx + $size, $total); $i++) { $rows.Add($all[$i]) }
                $body = '{"total":' + $total + ',"page":' + $page + ',"size":' + $size + ',"items":[' + ($rows -join ',') + ']}'
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($body))
            } catch {
                $message = @{ success = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 500 "Internal Server Error" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            }
            continue
        }

        if ($requestPath -like "/task-archive-item*") {
            try {
                $info = Get-TaskArchiveDir
                $id = Get-SafeFileName (Get-QueryValue $requestPath "id")
                $fp = Join-Path $info.Entries ($id + ".json")
                $body = if ([System.IO.File]::Exists($fp)) { [System.IO.File]::ReadAllText($fp, [Text.Encoding]::UTF8) } else { '{}' }
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($body))
            } catch {
                $message = @{ success = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 500 "Internal Server Error" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            }
            continue
        }

        if ($requestPath -eq "/task-archive-delete" -and $method -eq "POST") {
            try {
                $payload = $bodyText | ConvertFrom-Json
                $id = Get-SafeFileName ([string]$payload.id)
                $info = Get-TaskArchiveDir
                foreach ($ext in @(".json", ".md")) { $fp = Join-Path $info.Entries ($id + $ext); if ([System.IO.File]::Exists($fp)) { [System.IO.File]::Delete($fp) } }
                $indexPath = Join-Path $info.Dir "_index.jsonl"
                if ([System.IO.File]::Exists($indexPath)) {
                    $kept = New-Object System.Collections.Generic.List[string]
                    foreach ($line in [System.IO.File]::ReadLines($indexPath, [Text.Encoding]::UTF8)) {
                        if (-not [string]::IsNullOrWhiteSpace($line) -and ($line -notmatch ('"id":"' + [regex]::Escape($id) + '"'))) { $kept.Add($line) }
                    }
                    $tail = if ($kept.Count) { "`n" } else { "" }
                    [System.IO.File]::WriteAllText($indexPath, (($kept -join "`n") + $tail), (New-Object System.Text.UTF8Encoding($false)))
                }
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes('{"success":true}'))
            } catch {
                $message = @{ success = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 500 "Internal Server Error" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            }
            continue
        }

        if ($requestPath -eq "/affairs-extract" -and $method -eq "POST") {
            try {
                $payload = $bodyText | ConvertFrom-Json
                $name = Get-SafeFileName ([string]$payload.name)
                $b64 = [string]$payload.dataBase64
                if ([string]::IsNullOrWhiteSpace($name)) { throw "Missing name." }
                $node = (Get-Command node -ErrorAction SilentlyContinue).Source
                if (-not $node) { throw "未找到 node，无法解析附件内容" }
                $script = Join-Path $scriptDir "affairs\extract_text.js"
                if (-not [System.IO.File]::Exists($script)) { throw "extract_text.js 不存在" }
                $tmpDir = Join-Path $dataDir "tmp"
                if (-not [System.IO.Directory]::Exists($tmpDir)) { [void][System.IO.Directory]::CreateDirectory($tmpDir) }
                $tmp = Join-Path $tmpDir ((Get-Random).ToString() + "_" + $name)
                [System.IO.File]::WriteAllBytes($tmp, [Convert]::FromBase64String($b64))
                $si = [System.Diagnostics.ProcessStartInfo]::new()
                $si.FileName = $node; $si.UseShellExecute = $false; $si.RedirectStandardOutput = $true; $si.RedirectStandardError = $true
                $si.StandardOutputEncoding = [Text.Encoding]::UTF8; $si.StandardErrorEncoding = [Text.Encoding]::UTF8
                $si.Arguments = '"' + $script + '" "' + $tmp + '"'
                $pr = [System.Diagnostics.Process]::new(); $pr.StartInfo = $si; [void]$pr.Start()
                $out = $pr.StandardOutput.ReadToEnd(); $errOut = $pr.StandardError.ReadToEnd(); $pr.WaitForExit()
                try { [System.IO.File]::Delete($tmp) } catch {}
                $body = if ($out.Trim()) { $out } else { (@{ ok = $false; error = $errOut; text = "" } | ConvertTo-Json -Compress) }
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($body))
            } catch {
                Write-ServerLog "affairs-extract exception: $($_.Exception.Message)"
                $message = @{ ok = $false; error = $_.Exception.Message; text = "" } | ConvertTo-Json -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            }
            continue
        }

        if ($requestPath -eq "/affairs-action" -and $method -eq "POST") {
            try {
                # 本轮：DingTalk 动作仅预览(dry-run)，不真正执行；将 $affairsLiveExecute 改为 $true 即可开启真实执行。
                $affairsLiveExecute = $false
                $payload = $bodyText | ConvertFrom-Json
                $type = [string]$payload.type
                $p = $payload.params
                function Pv($o, $k) { if ($o -and ($o.PSObject.Properties.Name -contains $k)) { return [string]$o.$k } return "" }
                $args = $null
                switch ($type) {
                    "dingtalk_schedule" {
                        $args = @("calendar", "event", "create", "--title", (Pv $p "title"), "--start", (Pv $p "start"), "--end", (Pv $p "end"))
                        if (Pv $p "desc") { $args += @("--desc", (Pv $p "desc")) }
                        if (Pv $p "location") { $args += @("--location", (Pv $p "location")) }
                        if (Pv $p "attendees") { $args += @("--attendees", (Pv $p "attendees")) }
                    }
                    "dingtalk_msg_single" { $args = @("chat", "message", "send", "--user", (Pv $p "to"), "--title", (Pv $p "title"), "--text", (Pv $p "text")) }
                    "dingtalk_msg_group" { $args = @("chat", "message", "send", "--group", (Pv $p "group"), "--title", (Pv $p "title"), "--text", (Pv $p "text")) }
                    "dingtalk_ding" { $args = @("ding", "message", "send", "--users", (Pv $p "to"), "--content", (Pv $p "content")) }
                    "dingtalk_report" {
                        $rc = Pv $p "content"
                        $contentsArr = @(@{ key = "工作内容"; sort = "0"; content = $rc; contentType = "markdown"; type = "1" })
                        $contentsJson = ConvertTo-Json $contentsArr -Compress
                        $args = @("report", "entry", "submit", "--template-id", (Pv $p "template"), "--contents", $contentsJson)
                    }
                    "dingtalk_group" { $args = @("chat", "group", "create", "--name", (Pv $p "name"), "--users", (Pv $p "users")) }
                    "dingtalk_aitable" { $args = @("aitable", "create", "--name", (Pv $p "name")) }
                    default { $args = $null }
                }
                if (-not $args) { throw "Unsupported action type: $type" }
                if (-not $affairsLiveExecute) { $args += "--dry-run" }
                else { $args += "-y" }
                $args += @("--format", "json")
                $res = Invoke-DwsJson $args
                $cmdDisplay = "dws " + (($args | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join " ")
                $message = @{ success = ($res.ExitCode -eq 0); dryRun = (-not $affairsLiveExecute); output = [string]$res.Body; command = $cmdDisplay; exitCode = $res.ExitCode } | ConvertTo-Json -Depth 5 -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            } catch {
                Write-ServerLog "affairs-action exception: $($_.Exception.Message)"
                $message = @{ success = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 500 "Internal Server Error" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            }
            continue
        }

        if ($requestPath -like "/sync-emails*") {
            try {
                $startTime = Get-QueryValue $requestPath "start"
                $endTime = Get-QueryValue $requestPath "end"
                if ([string]::IsNullOrWhiteSpace($startTime)) { $startTime = (Get-Date).AddDays(-3).ToString("yyyy-MM-dd HH:mm:ss") }
                if ([string]::IsNullOrWhiteSpace($endTime)) { $endTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") }

                $payload = Invoke-OutlookEmailSync $startTime $endTime
                $json = $payload | ConvertTo-Json -Depth 6 -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($json))
            } catch {
                $errText = $_.Exception.Message
                Write-ServerLog "sync-emails exception: $errText"
                $message = @{ success = $false; error = $errText } | ConvertTo-Json -Compress
                Send-HttpResponse $client 502 "Bad Gateway" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            }
            continue
        }

        if ($requestPath -like "/sync-messages*") {
            try {
                $startTime = Get-QueryValue $requestPath "start"
                $endTime = Get-QueryValue $requestPath "end"
                if ([string]::IsNullOrWhiteSpace($startTime)) { $startTime = (Get-Date).ToString("yyyy-MM-dd") + " 00:00:00" }
                if ([string]::IsNullOrWhiteSpace($endTime)) { $endTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") }

                $payload = Invoke-DwsMessageSync $startTime $endTime
                $json = $payload | ConvertTo-Json -Depth 8 -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($json))
            } catch {
                $errText = $_.Exception.Message
                $statusCode = if ($errText -match 'not_authenticated|未登录|auth login') { 401 } else { 502 }
                $statusText = if ($statusCode -eq 401) { "Unauthorized" } else { "Bad Gateway" }
                Write-ServerLog "sync-messages exception: $errText"
                $message = @{ success = $false; error = $errText } | ConvertTo-Json -Compress
                Send-HttpResponse $client $statusCode $statusText "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            }
            continue
        }

        if ($requestPath -eq "/sync-calendar") {
            try {
                $dwsResult = Invoke-DwsCalendarList $endDate
                $json = $dwsResult.Body
                $statusCode = 200
                $statusText = "OK"
                if ($dwsResult.ExitCode -ne 0 -or $json -match '"error"\s*:') {
                    $statusCode = if ($json -match 'not_authenticated|未登录|auth login') { 401 } else { 502 }
                    $statusText = if ($statusCode -eq 401) { "Unauthorized" } else { "Bad Gateway" }
                    Write-ServerLog "sync-calendar dws exit=$($dwsResult.ExitCode) status=$statusCode body=$json"
                }
                Send-HttpResponse $client $statusCode $statusText "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($json))
            } catch {
                Write-ServerLog "sync-calendar exception: $($_.Exception.GetType().FullName) $($_.Exception.Message)"
                $message = @{ error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 500 "Internal Server Error" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($message))
            }
            continue
        }

        $filePath = Get-SafePath $requestPath
        if ($filePath -and [System.IO.File]::Exists($filePath)) {
            $ext = [System.IO.Path]::GetExtension($filePath).ToLowerInvariant()
            $contentType = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { "application/octet-stream" }
            Send-HttpResponse $client 200 "OK" $contentType ([System.IO.File]::ReadAllBytes($filePath))
        } else {
            Send-HttpResponse $client 404 "Not Found" "text/plain; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes("Not Found"))
        }
    } catch {
        if ($client) {
            try {
                Send-HttpResponse $client 500 "Internal Server Error" "text/plain; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($_.Exception.Message))
            } catch {}
        }
    } finally {
        if ($client) { $client.Close() }
    }
}
