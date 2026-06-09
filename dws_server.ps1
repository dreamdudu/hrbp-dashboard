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

function Start-DwsLogin {
    if (-not [System.IO.File]::Exists($dwsPath)) {
        throw "Cannot find dws.exe. Expected at $localBin\dws.exe."
    }

    Start-Process -FilePath $dwsPath -ArgumentList @("auth", "login") -WindowStyle Hidden
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
