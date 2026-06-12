$localBin = Join-Path $env:USERPROFILE ".local\bin"
$env:PATH = $localBin + ";" + [Environment]::GetEnvironmentVariable("PATH", "User") + ";" + [Environment]::GetEnvironmentVariable("PATH", "Machine")
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir
$logPath = Join-Path $scriptDir "dws_server.log"
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

    Start-Process -FilePath $dwsPath -ArgumentList @("auth", "login") -WindowStyle Hidden
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
        $client.ReceiveTimeout = 5000
        $stream = $client.GetStream()
        $reader = [System.IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $false, 8192, $true)
        $requestLine = $reader.ReadLine()

        if ([string]::IsNullOrWhiteSpace($requestLine)) {
            Send-HttpResponse $client 400 "Bad Request" "text/plain; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes("Bad Request"))
            continue
        }

        $contentLength = 0
        while ($true) {
            $line = $reader.ReadLine()
            if ($null -eq $line -or $line -eq "") { break }
            if ($line -match '^Content-Length:\s*(\d+)') {
                $contentLength = [int]$matches[1]
            }
        }

        $parts = $requestLine -split " "
        $method = $parts[0]
        $requestPath = $parts[1]
        $bodyText = ""
        if ($contentLength -gt 0) {
            $buffer = New-Object char[] $contentLength
            $read = $reader.Read($buffer, 0, $contentLength)
            if ($read -gt 0) {
                $bodyText = -join $buffer[0..($read - 1)]
            }
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
