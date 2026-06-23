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

function Get-WebResponseUtf8Content {
    param($Response)
    if ($null -ne $Response -and $null -ne $Response.RawContentStream) {
        try {
            return [Text.Encoding]::UTF8.GetString($Response.RawContentStream.ToArray())
        } catch {}
    }
    return [string]$Response.Content
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

# ===================== 技能看板（本地脚本型 skill） =====================
function Get-SkillsDir {
    $dir = Join-Path $scriptDir "skills"
    if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    return $dir
}

function Resolve-SkillDir {
    param([string] $Id)
    if ([string]::IsNullOrWhiteSpace($Id) -or $Id -notmatch '^[A-Za-z0-9_\-]+$') { throw "Invalid skill id." }
    return (Join-Path (Get-SkillsDir) $Id)
}

function Read-SkillManifest {
    param([string] $Dir)
    $mf = Join-Path $Dir "skill.json"
    if (-not [System.IO.File]::Exists($mf)) { return $null }
    try { return ([System.IO.File]::ReadAllText($mf, [Text.Encoding]::UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json) } catch { return $null }
}

function Write-SkillManifest {
    param([string] $Dir, $Manifest)
    $mf = Join-Path $Dir "skill.json"
    $json = $Manifest | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($mf, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Quote-ProcessArgument {
    param([string] $Value)
    if ($null -eq $Value) { return '""' }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Get-UsablePython {
    $candidates = @()
    foreach ($name in @("python", "py")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { $candidates += $cmd.Source }
    }
    if ($env:USERPROFILE) {
        $candidates += (Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe")
    }
    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (-not $candidate -or -not [System.IO.File]::Exists($candidate)) { continue }
        if ($candidate -match '\\WindowsApps\\python(?:3)?\.exe$') { continue }
        try {
            $si = [System.Diagnostics.ProcessStartInfo]::new()
            $si.FileName = $candidate
            $si.Arguments = "--version"
            $si.UseShellExecute = $false
            $si.RedirectStandardOutput = $true
            $si.RedirectStandardError = $true
            $pr = [System.Diagnostics.Process]::new()
            $pr.StartInfo = $si
            [void]$pr.Start()
            if ($pr.WaitForExit(5000) -and $pr.ExitCode -eq 0) { return $candidate }
            try { $pr.Kill() } catch {}
        } catch {}
    }
    return $null
}

function Ensure-SkillPythonDependencies {
    param([string] $Dir, [string] $PythonExe, $Dependencies)
    $deps = @($Dependencies) | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if (-not $deps.Count) { return "" }
    $runtimeDir = Join-Path $Dir ".runtime\python"
    if (-not [System.IO.Directory]::Exists($runtimeDir)) { [void][System.IO.Directory]::CreateDirectory($runtimeDir) }
    $stampPath = Join-Path $runtimeDir ".dependencies.json"
    $wanted = ($deps | ConvertTo-Json -Compress)
    $current = if ([System.IO.File]::Exists($stampPath)) { [System.IO.File]::ReadAllText($stampPath, [Text.Encoding]::UTF8) } else { "" }
    if ($current -ne $wanted) {
        $si = [System.Diagnostics.ProcessStartInfo]::new()
        $si.FileName = $PythonExe
        $argParts = @("-m", "pip", "install", "--disable-pip-version-check", "--target", $runtimeDir) + $deps
        $si.Arguments = ($argParts | ForEach-Object { Quote-ProcessArgument $_ }) -join " "
        $si.WorkingDirectory = $Dir
        $si.UseShellExecute = $false
        $si.RedirectStandardOutput = $true
        $si.RedirectStandardError = $true
        $si.StandardOutputEncoding = [Text.Encoding]::UTF8
        $si.StandardErrorEncoding = [Text.Encoding]::UTF8
        $pr = [System.Diagnostics.Process]::new()
        $pr.StartInfo = $si
        [void]$pr.Start()
        $outTask = $pr.StandardOutput.ReadToEndAsync()
        $errTask = $pr.StandardError.ReadToEndAsync()
        if (-not $pr.WaitForExit(180000)) { try { $pr.Kill() } catch {}; throw "安装 Python 依赖超时。" }
        if ($pr.ExitCode -ne 0) { throw "安装 Python 依赖失败：$($errTask.Result)$($outTask.Result)" }
        [System.IO.File]::WriteAllText($stampPath, $wanted, (New-Object System.Text.UTF8Encoding($false)))
    }
    return $runtimeDir
}

function Ensure-SkillNodeDependencies {
    param([string] $Dir)
    $pkgPath = Join-Path $Dir "package.json"
    if (-not [System.IO.File]::Exists($pkgPath)) { return }
    try {
        $pkg = [System.IO.File]::ReadAllText($pkgPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $hasDeps = $pkg.dependencies -and $pkg.dependencies.PSObject.Properties.Count
    } catch { $hasDeps = $false }
    if (-not $hasDeps -or [System.IO.Directory]::Exists((Join-Path $Dir "node_modules"))) { return }
    $npm = (Get-Command npm.cmd -ErrorAction SilentlyContinue).Source
    if (-not $npm) { $npm = (Get-Command npm -ErrorAction SilentlyContinue).Source }
    if (-not $npm) { throw "该技能需要 Node 依赖，但未找到 npm。" }
    $si = [System.Diagnostics.ProcessStartInfo]::new()
    $si.FileName = $npm
    $si.Arguments = "install --omit=dev --no-audit --no-fund"
    $si.WorkingDirectory = $Dir
    $si.UseShellExecute = $false
    $si.RedirectStandardOutput = $true
    $si.RedirectStandardError = $true
    $si.StandardOutputEncoding = [Text.Encoding]::UTF8
    $si.StandardErrorEncoding = [Text.Encoding]::UTF8
    $pr = [System.Diagnostics.Process]::new()
    $pr.StartInfo = $si
    [void]$pr.Start()
    $outTask = $pr.StandardOutput.ReadToEndAsync()
    $errTask = $pr.StandardError.ReadToEndAsync()
    if (-not $pr.WaitForExit(180000)) { try { $pr.Kill() } catch {}; throw "安装 Node 依赖超时。" }
    if ($pr.ExitCode -ne 0) { throw "安装 Node 依赖失败：$($errTask.Result)$($outTask.Result)" }
}

# 猜测技能入口：package.json → 常见入口 → scripts 目录 → 首个可执行脚本
function Guess-SkillEntry {
    param([string] $Dir)
    $pkg = Join-Path $Dir "package.json"
    if ([System.IO.File]::Exists($pkg)) {
        try {
            $p = [System.IO.File]::ReadAllText($pkg, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($p.main -and [System.IO.File]::Exists((Join-Path $Dir ([string]$p.main)))) { return [string]$p.main }
            if ($p.bin) {
                if ($p.bin -is [string]) { if ([System.IO.File]::Exists((Join-Path $Dir ([string]$p.bin)))) { return [string]$p.bin } }
                else { foreach ($k in $p.bin.PSObject.Properties.Name) { $v = [string]$p.bin.$k; if ([System.IO.File]::Exists((Join-Path $Dir $v))) { return $v } } }
            }
        } catch {}
    }
    foreach ($cand in @("index.js", "main.js", "skill.js", "cli.js", "index.py", "main.py", "skill.py", "cli.py", "main.ps1", "skill.ps1")) {
        if ([System.IO.File]::Exists((Join-Path $Dir $cand))) { return $cand }
    }
    foreach ($ext in @("*.js", "*.mjs", "*.py", "*.ps1")) {
        $files = [System.IO.Directory]::GetFiles($Dir, $ext, [System.IO.SearchOption]::AllDirectories)
        if ($files.Count -ge 1) { return $files[0].Substring($Dir.Length).TrimStart('\', '/').Replace('\', '/') }
    }
    return ""
}

function Get-SkillInitialContract {
    param([string] $Dir, [string] $Entry)
    $runtime = if ($Entry -match '\.py$') { "python" } elseif ($Entry -match '\.ps1$') { "powershell" } else { "node" }
    $inputMode = "workspace"
    $dependencies = @()
    $defaultArgs = @()
    $globalOptions = @()
    $entryPath = if ($Entry) { Join-Path $Dir $Entry } else { "" }
    $code = ""
    if ($entryPath -and [System.IO.File]::Exists($entryPath)) {
        try { $code = [System.IO.File]::ReadAllText($entryPath, [Text.Encoding]::UTF8) } catch {}
    }
    if ($runtime -eq "python") {
        if ($code -match '\bargparse\b|add_subparsers\s*\(|sys\.argv') { $inputMode = "cli" }
        elseif ($code -match 'sys\.stdin|input\s*\(') { $inputMode = "stdin" }
        $jsonArgPos = $code.IndexOf('add_argument("--json"')
        if ($jsonArgPos -lt 0) { $jsonArgPos = $code.IndexOf("add_argument('--json'") }
        $subparserPos = $code.IndexOf("add_subparsers")
        if ($inputMode -eq "cli" -and $jsonArgPos -ge 0 -and ($subparserPos -lt 0 -or $jsonArgPos -lt $subparserPos)) {
            $defaultArgs += "--json"
            $globalOptions += [ordered]@{ name = "--json"; takesValue = $false }
        }
        $requirements = Join-Path $Dir "requirements.txt"
        if ([System.IO.File]::Exists($requirements)) {
            try {
                $dependencies += [System.IO.File]::ReadAllLines($requirements, [Text.Encoding]::UTF8) |
                    ForEach-Object { ($_ -split '\s+#', 2)[0].Trim() } |
                    Where-Object { $_ -and -not $_.StartsWith("#") -and -not $_.StartsWith("-") }
            } catch {}
        }
        $commonImports = [ordered]@{
            requests = "requests>=2.31"
            yaml = "PyYAML>=6"
            bs4 = "beautifulsoup4>=4.12"
            PIL = "Pillow>=10"
            openpyxl = "openpyxl>=3.1"
            pandas = "pandas>=2"
            httpx = "httpx>=0.27"
        }
        foreach ($module in $commonImports.Keys) {
            if ($code -match "(?m)^\s*(?:from\s+$([regex]::Escape($module))\b|import\s+$([regex]::Escape($module))\b)") {
                $dependencies += $commonImports[$module]
            }
        }
    } elseif ($runtime -eq "node") {
        if ($code -match '\bprocess\.argv\b|\bcommander\b|\byargs\b') { $inputMode = "cli" }
        elseif ($code -match '\bprocess\.stdin\b') { $inputMode = "stdin" }
    } elseif ($code -match '\bparam\s*\(') {
        $inputMode = "cli"
    }
    return @{ runtime = $runtime; inputMode = $inputMode; dependencies = @($dependencies | Select-Object -Unique); defaultArgs = $defaultArgs; globalOptions = $globalOptions }
}

# 采集仓库内说明性文件与文件树，供前端大模型蒸馏 manifest
function Get-SkillRepoInfo {
    param([string] $Dir)
    $files = @()
    try {
        foreach ($f in [System.IO.Directory]::GetFiles($Dir, "*", [System.IO.SearchOption]::AllDirectories)) {
            $rel = $f.Substring($Dir.Length).TrimStart('\', '/').Replace('\', '/')
            if ($rel -like "node_modules/*" -or $rel -like ".git/*") { continue }
            $files += $rel
            if ($files.Count -ge 200) { break }
        }
    } catch {}
    function ReadIf($path, $max) {
        if ([System.IO.File]::Exists($path)) {
            try { $t = [System.IO.File]::ReadAllText($path, [Text.Encoding]::UTF8); if ($t.Length -gt $max) { $t = $t.Substring(0, $max) }; return $t } catch { return "" }
        }
        return ""
    }
    $skillMd = ""
    foreach ($n in @("SKILL.md", "skill.md", "Skill.md")) { $p = Join-Path $Dir $n; if ([System.IO.File]::Exists($p)) { $skillMd = ReadIf $p 8000; break } }
    $readme = ""
    foreach ($n in @("README.md", "readme.md", "Readme.md", "README", "README.txt")) { $p = Join-Path $Dir $n; if ([System.IO.File]::Exists($p)) { $readme = ReadIf $p 8000; break } }
    $pkg = ReadIf (Join-Path $Dir "package.json") 4000
    return @{ files = $files; skillMd = $skillMd; readme = $readme; packageJson = $pkg }
}

function Install-SkillFromGithub {
    param([string] $Repo, [string] $Ref, [string] $SkillSlug, [string] $SkillPath)
    if ($Repo -notmatch '^[A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+$') { throw "仓库格式应为 owner/name。" }
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch {}
    $parts = $Repo -split '/'
    $owner = $parts[0]; $name = $parts[1]
    $idSeed = $owner + "-" + $name + $(if ($SkillSlug) { "-" + $SkillSlug } else { "" })
    $id = (Get-SafeFileName $idSeed) -replace '[^A-Za-z0-9_\-]', '-'
    $refs = @()
    if ($Ref) { $refs += $Ref }
    $refs += @("main", "master")
    $tmpDir = Join-Path $dataDir "tmp"
    if (-not [System.IO.Directory]::Exists($tmpDir)) { [void][System.IO.Directory]::CreateDirectory($tmpDir) }
    $zip = Join-Path $tmpDir ("skillzip-" + (Get-Random) + ".zip")
    $okRef = $null
    foreach ($r in ($refs | Select-Object -Unique)) {
        $url = "https://codeload.github.com/$owner/$name/zip/refs/heads/$r"
        try {
            Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 60
            if ([System.IO.File]::Exists($zip) -and ((Get-Item $zip).Length -gt 0)) { $okRef = $r; break }
        } catch {}
    }
    if (-not $okRef) { throw "下载失败：无法从 GitHub 获取 $Repo（请确认仓库与分支存在，且本机网络可访问 codeload.github.com）。" }
    $exDir = Join-Path $tmpDir ("skillex-" + (Get-Random))
    Expand-Archive -Path $zip -DestinationPath $exDir -Force
    try { [System.IO.File]::Delete($zip) } catch {}
    $top = [System.IO.Directory]::GetDirectories($exDir)
    $repoRoot = if ($top.Count -ge 1) { $top[0] } else { $exDir }
    $srcRoot = $repoRoot
    if ($SkillPath) {
        $cleanSkillPath = ($SkillPath -replace '\\', '/').Trim('/')
        if ($cleanSkillPath -match '(^|/)\.\.(/|$)') { throw "技能目录路径无效。" }
        $candidate = [System.IO.Path]::GetFullPath((Join-Path $repoRoot ($cleanSkillPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
        $repoFull = [System.IO.Path]::GetFullPath($repoRoot)
        if (-not $candidate.StartsWith($repoFull, [StringComparison]::OrdinalIgnoreCase) -or -not [System.IO.Directory]::Exists($candidate)) {
            throw "仓库 $Repo 中未找到技能目录 $cleanSkillPath。"
        }
        $skillMdPath = Join-Path $candidate "SKILL.md"
        if (-not [System.IO.File]::Exists($skillMdPath)) { throw "技能目录 $cleanSkillPath 中没有 SKILL.md。" }
        $srcRoot = $candidate
    } elseif ($SkillSlug) {
        $skillFiles = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter "SKILL.md" -ErrorAction SilentlyContinue)
        $matched = $skillFiles | Where-Object { $_.Directory.Name -ieq $SkillSlug } | Select-Object -First 1
        if (-not $matched) {
            foreach ($sf in $skillFiles) {
                try {
                    $head = [System.IO.File]::ReadAllText($sf.FullName, [Text.Encoding]::UTF8)
                    if ($head -match "(?im)^\s*name\s*:\s*['`"]?$([regex]::Escape($SkillSlug))['`"]?\s*$") { $matched = $sf; break }
                } catch {}
            }
        }
        if (-not $matched) { throw "仓库 $Repo 中未找到技能 $SkillSlug。" }
        $srcRoot = $matched.Directory.FullName
    }
    $dest = Resolve-SkillDir $id
    if ([System.IO.Directory]::Exists($dest)) { Remove-Item -LiteralPath $dest -Recurse -Force }
    Move-Item -LiteralPath $srcRoot -Destination $dest
    try { Remove-Item -LiteralPath $exDir -Recurse -Force } catch {}
    $entry = Guess-SkillEntry $dest
    $contract = Get-SkillInitialContract $dest $entry
    $now = (Get-Date).ToString("o")
    $manifest = [ordered]@{
        id = $id; kind = "skill"; name = $(if ($SkillSlug) { $SkillSlug } else { $name }); icon = "🧩"; description = ""; runtime = $contract.runtime; entry = $entry;
        inputHint = ""; outputHint = ""; inputMode = $contract.inputMode; cliGuide = ""; dependencies = @($contract.dependencies); defaultArgs = @($contract.defaultArgs); globalOptions = @($contract.globalOptions); trusted = $false; version = "";
        source = [ordered]@{ type = "github"; repo = $Repo; ref = $okRef; skill = $SkillSlug; path = $SkillPath; url = "https://github.com/$Repo" };
        installedAt = $now; updatedAt = $now
    }
    Write-SkillManifest $dest $manifest
    $info = Get-SkillRepoInfo $dest
    return @{ id = $id; manifest = $manifest; files = $info.files; skillMd = $info.skillMd; readme = $info.readme; packageJson = $info.packageJson }
}

function Install-SkillFromArchive {
    param(
        [string] $DownloadUrl,
        [string] $SkillId,
        [string] $Name,
        [string] $Provider,
        [string] $DetailUrl,
        [string] $Version,
        [string] $Description
    )
    if ([string]::IsNullOrWhiteSpace($DownloadUrl)) { throw "市场未提供技能下载地址。" }
    $uri = $null
    if (-not [Uri]::TryCreate($DownloadUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne "https") {
        throw "技能下载地址必须是 HTTPS。"
    }
    $id = (Get-SafeFileName $SkillId) -replace '[^A-Za-z0-9_\-]', '-'
    if ([string]::IsNullOrWhiteSpace($id)) { throw "市场技能 ID 无效。" }
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch {}
    $tmpDir = Join-Path $dataDir "tmp"
    if (-not [System.IO.Directory]::Exists($tmpDir)) { [void][System.IO.Directory]::CreateDirectory($tmpDir) }
    $zip = Join-Path $tmpDir ("skillzip-" + (Get-Random) + ".zip")
    $exDir = Join-Path $tmpDir ("skillex-" + (Get-Random))
    try {
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $zip -UseBasicParsing -TimeoutSec 90
        if (-not [System.IO.File]::Exists($zip) -or ((Get-Item $zip).Length -lt 4)) { throw "市场返回了空文件。" }
        $magic = [System.IO.File]::ReadAllBytes($zip)
        if ($magic[0] -ne 0x50 -or $magic[1] -ne 0x4B) { throw "市场下载内容不是 ZIP 技能包。" }
        Expand-Archive -Path $zip -DestinationPath $exDir -Force
        $rootFiles = [System.IO.Directory]::GetFiles($exDir)
        $rootDirs = [System.IO.Directory]::GetDirectories($exDir)
        $srcRoot = if ($rootFiles.Count -eq 0 -and $rootDirs.Count -eq 1) { $rootDirs[0] } else { $exDir }
        $dest = Resolve-SkillDir $id
        if ([System.IO.Directory]::Exists($dest)) { Remove-Item -LiteralPath $dest -Recurse -Force }
        Move-Item -LiteralPath $srcRoot -Destination $dest
        $entry = Guess-SkillEntry $dest
        $contract = Get-SkillInitialContract $dest $entry
        $now = (Get-Date).ToString("o")
        $manifest = [ordered]@{
            id = $id; kind = "skill"; name = $(if ($Name) { $Name } else { $id }); icon = "🧩";
            description = $Description; runtime = $contract.runtime; entry = $entry;
            inputHint = ""; outputHint = ""; inputMode = $contract.inputMode; cliGuide = ""; dependencies = @($contract.dependencies); defaultArgs = @($contract.defaultArgs); globalOptions = @($contract.globalOptions); trusted = $false; version = $Version;
            source = [ordered]@{ type = "market"; provider = $Provider; id = $SkillId; url = $DetailUrl; downloadUrl = $DownloadUrl };
            installedAt = $now; updatedAt = $now
        }
        Write-SkillManifest $dest $manifest
        $info = Get-SkillRepoInfo $dest
        return @{ id = $id; manifest = $manifest; files = $info.files; skillMd = $info.skillMd; readme = $info.readme; packageJson = $info.packageJson }
    } finally {
        try { if ([System.IO.File]::Exists($zip)) { [System.IO.File]::Delete($zip) } } catch {}
        try { if ([System.IO.Directory]::Exists($exDir)) { Remove-Item -LiteralPath $exDir -Recurse -Force } } catch {}
    }
}

# 运行一次性 MCP 客户端(node)，把请求对象经 stdin 传入，返回其 stdout(JSON 字符串)
function Invoke-McpClient {
    param($ReqObj, [int] $TimeoutMs = 75000)
    $node = (Get-Command node -ErrorAction SilentlyContinue).Source
    if (-not $node) { throw "未找到 node，无法连接 MCP" }
    $script = Join-Path $scriptDir "mcp\mcp_client.js"
    if (-not [System.IO.File]::Exists($script)) { throw "mcp_client.js 不存在" }
    $json = $ReqObj | ConvertTo-Json -Depth 12 -Compress
    $si = [System.Diagnostics.ProcessStartInfo]::new()
    $si.FileName = $node; $si.Arguments = '"' + $script + '"'
    $si.UseShellExecute = $false; $si.RedirectStandardInput = $true; $si.RedirectStandardOutput = $true; $si.RedirectStandardError = $true
    $si.StandardOutputEncoding = [Text.Encoding]::UTF8; $si.StandardErrorEncoding = [Text.Encoding]::UTF8
    $pr = [System.Diagnostics.Process]::new(); $pr.StartInfo = $si; [void]$pr.Start()
    $inBytes = [Text.Encoding]::UTF8.GetBytes($json)
    $pr.StandardInput.BaseStream.Write($inBytes, 0, $inBytes.Length); $pr.StandardInput.BaseStream.Flush(); $pr.StandardInput.Close()
    $outTask = $pr.StandardOutput.ReadToEndAsync()
    $errTask = $pr.StandardError.ReadToEndAsync()
    if (-not $pr.WaitForExit($TimeoutMs)) { try { $pr.Kill() } catch {}; throw "MCP 连接超时" }
    $o = $outTask.Result
    if (-not ($o.Trim())) { throw ("MCP 无输出：" + $errTask.Result) }
    return $o
}

# 把 MCP 应用 manifest 转成 mcp_client 的请求基对象(不含 op/tool/arguments)
function New-McpReqBase {
    param($M)
    $transport = if ($M.transport) { [string]$M.transport } else { "stdio" }
    $req = @{ transport = $transport }
    if ($transport -eq "http") {
        $req.url = [string]$M.url
        if ($M.headers) { $req.headers = $M.headers }
    }
    else {
        $req.command = [string]$M.command
        $req.args = @($M.args)
        if ($M.env) { $req.env = $M.env }
    }
    return $req
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

# Single-instance hardening: this process holds the mutex, so it is the only legitimate server.
# Kill any other dws_server.ps1 processes from this same board directory (stragglers left by the
# frontend self-heal / multiple tabs occasionally launching, or instances stuck before the mutex check),
# so the process list never accumulates multiple dws_server.ps1 entries.
try {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and ($_.CommandLine -match '-File\s+"?[^"]*dws_server\.ps1') -and ($_.CommandLine -like ("*" + $scriptDir + "*")) } |
        ForEach-Object {
            try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; Write-ServerLog "cleaned up stray server instance pid=$($_.ProcessId)" } catch {}
        }
} catch {}

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

        if ($requestPath -like "/heartbeat*") {
            try {
                $hb = Join-Path $dataDir ".heartbeat"
                if ((Get-QueryValue $requestPath "off") -eq "1") {
                    if ([System.IO.File]::Exists($hb)) { [System.IO.File]::Delete($hb) }
                } else {
                    [System.IO.File]::WriteAllText($hb, (Get-Date).ToString("o"), (New-Object System.Text.UTF8Encoding($false)))
                }
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes('{"ok":true}'))
            } catch {
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes('{"ok":false}'))
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

        if ($requestPath -like "/skill-list*") {
            try {
                $root = Get-SkillsDir
                $arr = @()
                foreach ($d in [System.IO.Directory]::GetDirectories($root)) { $mm = Read-SkillManifest $d; if ($mm) { $arr += $mm } }
                $body = @{ ok = $true; skills = @($arr) } | ConvertTo-Json -Depth 8
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($body))
            } catch {
                Write-ServerLog "skill-list exception: $($_.Exception.Message)"
                $body = @{ ok = $false; error = $_.Exception.Message; skills = @() } | ConvertTo-Json -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($body))
            }
            continue
        }

        if ($requestPath -eq "/skill-install" -and $method -eq "POST") {
            try {
                $payload = $bodyText | ConvertFrom-Json
                if ($payload.PSObject.Properties.Name -contains 'downloadUrl' -and $payload.downloadUrl) {
                    $res = Install-SkillFromArchive `
                        -DownloadUrl ([string]$payload.downloadUrl) `
                        -SkillId ([string]$payload.id) `
                        -Name ([string]$payload.name) `
                        -Provider ([string]$payload.provider) `
                        -DetailUrl ([string]$payload.url) `
                        -Version ([string]$payload.version) `
                        -Description ([string]$payload.description)
                } else {
                    $repo = [string]$payload.repo
                    $ref = if ($payload.PSObject.Properties.Name -contains 'ref') { [string]$payload.ref } else { "" }
                    $skillSlug = if ($payload.PSObject.Properties.Name -contains 'skillSlug') { [string]$payload.skillSlug } else { "" }
                    $skillPath = if ($payload.PSObject.Properties.Name -contains 'skillPath') { [string]$payload.skillPath } else { "" }
                    $res = Install-SkillFromGithub $repo $ref $skillSlug $skillPath
                }
                $body = @{ ok = $true; id = $res.id; manifest = $res.manifest; files = @($res.files); skillMd = $res.skillMd; readme = $res.readme; packageJson = $res.packageJson } | ConvertTo-Json -Depth 8
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($body))
            } catch {
                Write-ServerLog "skill-install exception: $($_.Exception.Message)"
                $body = @{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($body))
            }
            continue
        }

        if ($requestPath -like "/skill-market-search*") {
            try {
                [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
                $source = Get-QueryValue $requestPath "source"
                $q = Get-QueryValue $requestPath "q"
                $provider = "json"
                if ($source -match '^https?://(?:www\.)?skillsmp\.com(?:/|$)') {
                    $provider = "skillsmp"
                    $items = @()
                    if ($q) {
                        $url = "https://skillsmp.com/api/v1/skills/search?q=" + [Uri]::EscapeDataString($q) + "&page=1&limit=20&sortBy=stars"
                        $remote = Invoke-WebRequest -Uri $url -UseBasicParsing -Headers @{ Accept = "application/json"; "User-Agent" = "HRBP-Dashboard" } -TimeoutSec 30
                        # SkillsMP omits charset=utf-8. PowerShell 5.1 otherwise decodes
                        # its UTF-8 JSON with a legacy code page and corrupts Chinese text.
                        $payload = (Get-WebResponseUtf8Content $remote) | ConvertFrom-Json
                        if (-not $payload.success) { throw "SkillsMP 搜索失败。" }
                        $items = @($payload.data.skills)
                    } else {
                        $remote = Invoke-WebRequest -Uri "https://skillsmp.com/search?sortBy=stars" -UseBasicParsing -Headers @{ "User-Agent" = "HRBP-Dashboard" } -TimeoutSec 30
                        $matches = [regex]::Matches((Get-WebResponseUtf8Content $remote), '<a[^>]+href="(/creators/[^"]+)"[^>]*>([\s\S]*?)</a>')
                        $seen = @{}
                        foreach ($m in $matches) {
                            $detailPath = $m.Groups[1].Value
                            if ($seen.ContainsKey($detailPath)) { continue }
                            $text = [regex]::Replace($m.Groups[2].Value, '<[^>]+>', ' ')
                            $text = [Net.WebUtility]::HtmlDecode(([regex]::Replace($text, '\s+', ' ')).Trim())
                            $parts = $text -split ' '
                            if ($parts.Count -lt 4) { continue }
                            $name = $parts[0]
                            $starsText = $parts[1]
                            $repo = $parts[2]
                            if ($repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { continue }
                            $mult = 1.0; $metric = $starsText
                            if ($metric -match 'k$') { $mult = 1000; $metric = $metric.TrimEnd('k') }
                            elseif ($metric -match 'm$') { $mult = 1000000; $metric = $metric.TrimEnd('m') }
                            $stars = [int64]([double]$metric * $mult)
                            $description = ($parts[3..($parts.Count - 1)] -join ' ') -replace '\s+\d{4}-\d{2}-\d{2}$', ''
                            $detailUrl = "https://skillsmp.com$detailPath"
                            try {
                                $detail = Invoke-WebRequest -Uri $detailUrl -UseBasicParsing -Headers @{ "User-Agent" = "HRBP-Dashboard" } -TimeoutSec 20
                                $githubMatch = [regex]::Match((Get-WebResponseUtf8Content $detail), 'href="(https://github\.com/[^"]+/tree/[^"]+)"')
                                $githubUrl = if ($githubMatch.Success) { [Net.WebUtility]::HtmlDecode($githubMatch.Groups[1].Value) } else { "https://github.com/$repo" }
                            } catch { $githubUrl = "https://github.com/$repo" }
                            $items += [ordered]@{ id = ($detailPath.Trim('/') -replace '/', '-'); name = $name; description = $description; githubUrl = $githubUrl; skillUrl = $detailUrl; stars = $stars }
                            $seen[$detailPath] = $true
                            if ($items.Count -ge 10) { break }
                        }
                    }
                    $data = [ordered]@{ skills = @($items) }
                } elseif ($source -match '^https?://(?:www\.)?skills\.sh(?:/|$)') {
                    $provider = "skillssh"
                    $items = @()
                    if ($q) {
                        $npx = (Get-Command "npx.cmd" -ErrorAction SilentlyContinue).Source
                        if (-not $npx) {
                            $candidate = Join-Path $env:ProgramFiles "nodejs\npx.cmd"
                            if ([System.IO.File]::Exists($candidate)) { $npx = $candidate }
                        }
                        if (-not $npx) { throw "未找到 npx.cmd，无法搜索 skills.sh。" }
                        $si = [System.Diagnostics.ProcessStartInfo]::new()
                        $si.FileName = $npx
                        $si.UseShellExecute = $false
                        $si.RedirectStandardOutput = $true
                        $si.RedirectStandardError = $true
                        $si.StandardOutputEncoding = [Text.Encoding]::UTF8
                        $si.StandardErrorEncoding = [Text.Encoding]::UTF8
                        $si.Arguments = (@("-y", "skills", "find", $q) | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join " "
                        $proc = [System.Diagnostics.Process]::new()
                        $proc.StartInfo = $si
                        [void]$proc.Start()
                        $stdout = $proc.StandardOutput.ReadToEnd()
                        $stderr = $proc.StandardError.ReadToEnd()
                        if (-not $proc.WaitForExit(60000)) { try { $proc.Kill() } catch {}; throw "skills.sh 搜索超时。" }
                        if ($proc.ExitCode -ne 0 -and -not $stdout) { throw $(if ($stderr) { $stderr.Trim() } else { "skills.sh 搜索失败。" }) }
                        $clean = [regex]::Replace($stdout, "$([char]27)\[[0-9;?]*[ -/]*[@-~]", "")
                        $matches = [regex]::Matches($clean, '(?m)^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)@([^\s]+)\s+([0-9.]+[KMB]?) installs\s*$')
                        foreach ($m in $matches) {
                            $repo = $m.Groups[1].Value; $slug = $m.Groups[2].Value; $metric = $m.Groups[3].Value
                            $mult = 1.0
                            if ($metric -match 'K$') { $mult = 1000; $metric = $metric.TrimEnd('K') }
                            elseif ($metric -match 'M$') { $mult = 1000000; $metric = $metric.TrimEnd('M') }
                            elseif ($metric -match 'B$') { $mult = 1000000000; $metric = $metric.TrimEnd('B') }
                            $installs = [int64]([double]$metric * $mult)
                            $items += [ordered]@{ id = "$repo/$slug"; slug = $slug; name = $slug; source = $repo; sourceType = "github"; installs = $installs; installUrl = "https://github.com/$repo"; url = "https://skills.sh/$repo/$slug" }
                        }
                    } else {
                        $remote = Invoke-WebRequest -Uri "https://www.skills.sh/" -UseBasicParsing -Headers @{ "User-Agent" = "HRBP-Dashboard" } -TimeoutSec 30
                        $matches = [regex]::Matches($remote.Content, 'href="/([^"/]+/[^"/]+/[^"/]+)"[^>]*>([\s\S]*?)</a>')
                        $seen = @{}
                        foreach ($m in $matches) {
                            $path = $m.Groups[1].Value
                            if ($seen.ContainsKey($path)) { continue }
                            $text = [regex]::Replace($m.Groups[2].Value, '<[^>]+>', ' ')
                            $text = [Net.WebUtility]::HtmlDecode(([regex]::Replace($text, '\s+', ' ')).Trim())
                            if ($text -notmatch '^\d+\s+') { continue }
                            $parts = $path -split '/'
                            if ($parts.Count -ne 3) { continue }
                            $repo = "$($parts[0])/$($parts[1])"; $slug = $parts[2]
                            $metricMatch = [regex]::Match($text, '([0-9.]+[KMB]?)\s*$')
                            $installs = 0
                            if ($metricMatch.Success) {
                                $metric = $metricMatch.Groups[1].Value; $mult = 1.0
                                if ($metric -match 'K$') { $mult = 1000; $metric = $metric.TrimEnd('K') }
                                elseif ($metric -match 'M$') { $mult = 1000000; $metric = $metric.TrimEnd('M') }
                                elseif ($metric -match 'B$') { $mult = 1000000000; $metric = $metric.TrimEnd('B') }
                                $installs = [int64]([double]$metric * $mult)
                            }
                            $items += [ordered]@{ id = "$repo/$slug"; slug = $slug; name = $slug; source = $repo; sourceType = "github"; installs = $installs; installUrl = "https://github.com/$repo"; url = "https://skills.sh/$repo/$slug" }
                            $seen[$path] = $true
                            if ($items.Count -ge 20) { break }
                        }
                    }
                    $data = [ordered]@{ data = @($items) }
                } elseif ($source -match '^https?://(?:www\.)?skillhub\.(?:cn|tencent\.com)(?:/|$)' -or $source -match '^https?://api\.skillhub\.(?:cn|tencent\.com)(?:/|$)') {
                    $provider = "skillhub"
                    $apiHost = if ($source -match 'skillhub\.tencent\.com') { "https://api.skillhub.tencent.com" } else { "https://api.skillhub.cn" }
                    $url = "$apiHost/api/skills?page=1&pageSize=20&sortBy=score&order=desc"
                    if ($q) { $url += "&keyword=" + [Uri]::EscapeDataString($q) }
                } elseif ($source -notmatch '^https?://') {
                    $provider = "github"
                    $full = $(if ($q) { "$q $source" } else { $source })
                    $url = "https://api.github.com/search/repositories?q=" + [Uri]::EscapeDataString($full) + "&sort=stars&order=desc&per_page=20"
                } else {
                    $url = $source
                    if ($url.Contains("{q}")) { $url = $url.Replace("{q}", [Uri]::EscapeDataString($q)) }
                    elseif ($q) { $url += $(if ($url.Contains("?")) { "&" } else { "?" }) + "q=" + [Uri]::EscapeDataString($q) }
                }
                if ($provider -ne "skillssh" -and $provider -ne "skillsmp") {
                    $headers = @{ Accept = "application/json"; "User-Agent" = "HRBP-Dashboard" }
                    $remote = Invoke-WebRequest -Uri $url -UseBasicParsing -Headers $headers -TimeoutSec 30
                    $contentType = [string]$remote.Headers["Content-Type"]
                    if ($contentType -notmatch 'json') { throw "市场返回的不是 JSON（$contentType），请配置原生 API 地址而不是网页地址。" }
                    $data = $remote.Content | ConvertFrom-Json
                }
                $body = @{ ok = $true; provider = $provider; source = $source; data = $data } | ConvertTo-Json -Depth 15
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($body))
            } catch {
                Write-ServerLog "skill-market-search exception: $($_.Exception.Message)"
                $body = @{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($body))
            }
            continue
        }

        if ($requestPath -eq "/skill-update" -and $method -eq "POST") {
            try {
                $payload = $bodyText | ConvertFrom-Json
                $dir = Resolve-SkillDir ([string]$payload.id)
                $m = Read-SkillManifest $dir
                if (-not $m) { throw "技能不存在。" }
                foreach ($k in @('name', 'icon', 'description', 'runtime', 'entry', 'inputHint', 'outputHint', 'version', 'inputMode', 'cliGuide')) {
                    if ($payload.PSObject.Properties.Name -contains $k) {
                        if ($m.PSObject.Properties.Name -contains $k) { $m.$k = [string]$payload.$k }
                        else { $m | Add-Member -NotePropertyName $k -NotePropertyValue ([string]$payload.$k) -Force }
                    }
                }
                if ($payload.PSObject.Properties.Name -contains 'dependencies') {
                    $depsValue = @($payload.dependencies) | ForEach-Object { [string]$_ } | Where-Object { $_ }
                    if ($m.PSObject.Properties.Name -contains 'dependencies') { $m.dependencies = $depsValue }
                    else { $m | Add-Member -NotePropertyName 'dependencies' -NotePropertyValue $depsValue -Force }
                }
                if ($payload.PSObject.Properties.Name -contains 'globalOptions') {
                    $globalValue = @($payload.globalOptions)
                    if ($m.PSObject.Properties.Name -contains 'globalOptions') { $m.globalOptions = $globalValue }
                    else { $m | Add-Member -NotePropertyName 'globalOptions' -NotePropertyValue $globalValue -Force }
                }
                if ($payload.PSObject.Properties.Name -contains 'defaultArgs') {
                    $defaultValue = @($payload.defaultArgs) | ForEach-Object { [string]$_ } | Where-Object { $_ }
                    if ($m.PSObject.Properties.Name -contains 'defaultArgs') { $m.defaultArgs = $defaultValue }
                    else { $m | Add-Member -NotePropertyName 'defaultArgs' -NotePropertyValue $defaultValue -Force }
                }
                if ($payload.PSObject.Properties.Name -contains 'trusted') {
                    if ($m.PSObject.Properties.Name -contains 'trusted') { $m.trusted = [bool]$payload.trusted }
                    else { $m | Add-Member -NotePropertyName 'trusted' -NotePropertyValue ([bool]$payload.trusted) -Force }
                }
                if ($m.PSObject.Properties.Name -contains 'updatedAt') { $m.updatedAt = (Get-Date).ToString("o") } else { $m | Add-Member -NotePropertyName 'updatedAt' -NotePropertyValue ((Get-Date).ToString("o")) -Force }
                Write-SkillManifest $dir $m
                $body = @{ ok = $true; manifest = $m } | ConvertTo-Json -Depth 8
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($body))
            } catch {
                Write-ServerLog "skill-update exception: $($_.Exception.Message)"
                $body = @{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($body))
            }
            continue
        }

        if ($requestPath -eq "/skill-delete" -and $method -eq "POST") {
            try {
                $payload = $bodyText | ConvertFrom-Json
                $dir = Resolve-SkillDir ([string]$payload.id)
                if ([System.IO.Directory]::Exists($dir)) { Remove-Item -LiteralPath $dir -Recurse -Force }
                $body = @{ ok = $true } | ConvertTo-Json -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($body))
            } catch {
                Write-ServerLog "skill-delete exception: $($_.Exception.Message)"
                $body = @{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($body))
            }
            continue
        }

        if ($requestPath -like "/skill-inspect*") {
            try {
                $dir = Resolve-SkillDir (Get-QueryValue $requestPath "id")
                $m = Read-SkillManifest $dir
                if (-not $m) { throw "技能不存在。" }
                $entryCode = ""
                if ($m.entry) {
                    $entryPath = Join-Path $dir ([string]$m.entry)
                    if ([System.IO.File]::Exists($entryPath)) {
                        try { $entryCode = [System.IO.File]::ReadAllText($entryPath, [Text.Encoding]::UTF8); if ($entryCode.Length -gt 12000) { $entryCode = $entryCode.Substring(0, 12000) + "`n…（已截断）" } } catch {}
                    }
                }
                $deps = @()
                if ($m.PSObject.Properties.Name -contains 'dependencies') { $deps += @($m.dependencies) }
                $pkg = Join-Path $dir "package.json"
                if ([System.IO.File]::Exists($pkg)) {
                    try { $p = [System.IO.File]::ReadAllText($pkg, [Text.Encoding]::UTF8) | ConvertFrom-Json; if ($p.dependencies) { foreach ($k in $p.dependencies.PSObject.Properties.Name) { $deps += ($k + "@" + [string]$p.dependencies.$k) } } } catch {}
                }
                $info = Get-SkillRepoInfo $dir
                $body = @{ ok = $true; manifest = $m; entry = [string]$m.entry; entryCode = $entryCode; deps = @($deps | Select-Object -Unique); files = @($info.files); skillMd = $info.skillMd; readme = $info.readme } | ConvertTo-Json -Depth 8
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($body))
            } catch {
                Write-ServerLog "skill-inspect exception: $($_.Exception.Message)"
                $body = @{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($body))
            }
            continue
        }

        if ($requestPath -eq "/skill-run" -and $method -eq "POST") {
            try {
                $payload = $bodyText | ConvertFrom-Json
                $dir = Resolve-SkillDir ([string]$payload.id)
                $m = Read-SkillManifest $dir
                if (-not $m) { throw "技能不存在。" }
                $confirmed = ($payload.PSObject.Properties.Name -contains 'confirmed') -and [bool]$payload.confirmed
                if ((-not ([bool]$m.trusted)) -and (-not $confirmed)) { throw "该技能尚未确认信任，请先确认后再运行。" }
                $runtime = if ($m.runtime) { [string]$m.runtime } else { "node" }
                $entry = [string]$m.entry
                if (-not $entry) { throw "未配置入口文件 entry。" }
                $entryPath = Join-Path $dir $entry
                if (-not [System.IO.File]::Exists($entryPath)) { throw "入口文件不存在：$entry" }
                $tmpRoot = Join-Path $dataDir "tmp"
                if (-not [System.IO.Directory]::Exists($tmpRoot)) { [void][System.IO.Directory]::CreateDirectory($tmpRoot) }
                $work = Join-Path $tmpRoot ("skillrun-" + (Get-Random))
                [void][System.IO.Directory]::CreateDirectory($work)
                if ($payload.files) {
                    foreach ($f in @($payload.files)) {
                        try { [System.IO.File]::WriteAllBytes((Join-Path $work (Get-SafeFileName ([string]$f.name))), [Convert]::FromBase64String([string]$f.dataBase64)) } catch {}
                    }
                }
                $inputText = [string]$payload.input
                try { [System.IO.File]::WriteAllText((Join-Path $work "input.txt"), $inputText, (New-Object System.Text.UTF8Encoding($false))) } catch {}
                $exe = $null; $argLine = $null; $runtimePath = ""
                $inputMode = if ($m.PSObject.Properties.Name -contains 'inputMode' -and $m.inputMode) { [string]$m.inputMode } else { "workspace" }
                $runArgs = @()
                if ($payload.PSObject.Properties.Name -contains 'args' -and $payload.args) { $runArgs = @($payload.args) | ForEach-Object { [string]$_ } }
                if ($inputMode -eq "cli" -and $m.PSObject.Properties.Name -contains 'defaultArgs') {
                    foreach ($defaultArg in @($m.defaultArgs)) {
                        $defaultText = [string]$defaultArg
                        if ($defaultText -and $runArgs -notcontains $defaultText) { $runArgs += $defaultText }
                    }
                }
                if ($inputMode -eq "cli" -and $m.PSObject.Properties.Name -contains 'globalOptions' -and $runArgs.Count) {
                    $globalSpecs = @($m.globalOptions)
                    $prefixArgs = @()
                    $keptArgs = @()
                    for ($ri = 0; $ri -lt $runArgs.Count; $ri++) {
                        $arg = $runArgs[$ri]
                        $spec = $globalSpecs | Where-Object { [string]$_.name -eq $arg } | Select-Object -First 1
                        if ($spec) {
                            $prefixArgs += $arg
                            if ([bool]$spec.takesValue -and ($ri + 1) -lt $runArgs.Count) { $ri++; $prefixArgs += $runArgs[$ri] }
                        } else {
                            $keptArgs += $arg
                        }
                    }
                    $runArgs = $prefixArgs + $keptArgs
                }
                switch ($runtime) {
                    "python" {
                        $exe = Get-UsablePython
                        if ($exe) { $runtimePath = Ensure-SkillPythonDependencies $dir $exe $m.dependencies }
                    }
                    "powershell" { $exe = "powershell.exe" }
                    default {
                        $exe = (Get-Command node -ErrorAction SilentlyContinue).Source
                        if ($exe) { Ensure-SkillNodeDependencies $dir }
                    }
                }
                if (-not $exe) { throw "未找到运行时：$runtime" }
                $parts = @()
                if ($runtime -eq "powershell") { $parts += @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File") }
                $parts += $entryPath
                if ($inputMode -eq "cli") {
                    if (-not $runArgs.Count) { throw "该技能需要 CLI 参数，但未生成可执行参数。" }
                    $parts += $runArgs
                } elseif ($inputMode -eq "workspace") {
                    $parts += $work
                }
                $argLine = ($parts | ForEach-Object { Quote-ProcessArgument $_ }) -join " "
                $si = [System.Diagnostics.ProcessStartInfo]::new()
                $si.FileName = $exe; $si.Arguments = $argLine; $si.WorkingDirectory = $dir
                $si.UseShellExecute = $false; $si.RedirectStandardInput = $true; $si.RedirectStandardOutput = $true; $si.RedirectStandardError = $true
                $si.StandardOutputEncoding = [Text.Encoding]::UTF8; $si.StandardErrorEncoding = [Text.Encoding]::UTF8
                if ($runtimePath) {
                    $oldPythonPath = [Environment]::GetEnvironmentVariable("PYTHONPATH")
                    $si.EnvironmentVariables["PYTHONPATH"] = if ($oldPythonPath) { $runtimePath + [IO.Path]::PathSeparator + $oldPythonPath } else { $runtimePath }
                    $si.EnvironmentVariables["PYTHONUTF8"] = "1"
                }
                $pr = [System.Diagnostics.Process]::new(); $pr.StartInfo = $si; [void]$pr.Start()
                try { $inBytes = [Text.Encoding]::UTF8.GetBytes($inputText); $pr.StandardInput.BaseStream.Write($inBytes, 0, $inBytes.Length); $pr.StandardInput.BaseStream.Flush(); $pr.StandardInput.Close() } catch {}
                $outTask = $pr.StandardOutput.ReadToEndAsync()
                $errTask = $pr.StandardError.ReadToEndAsync()
                $exited = $pr.WaitForExit(120000)
                if (-not $exited) { try { $pr.Kill() } catch {}; try { Remove-Item -LiteralPath $work -Recurse -Force } catch {}; throw "技能运行超时（120 秒）。" }
                $out = $outTask.Result; $errOut = $errTask.Result
                try { Remove-Item -LiteralPath $work -Recurse -Force } catch {}
                $body = @{ ok = ($pr.ExitCode -eq 0); exitCode = $pr.ExitCode; output = $out; error = $errOut } | ConvertTo-Json -Depth 6 -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($body))
            } catch {
                Write-ServerLog "skill-run exception: $($_.Exception.Message)"
                $body = @{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($body))
            }
            continue
        }

        if ($requestPath -eq "/mcp-save" -and $method -eq "POST") {
            try {
                $p = $bodyText | ConvertFrom-Json
                $id = if ($p.PSObject.Properties.Name -contains 'id') { [string]$p.id } else { "" }
                if (-not $id) {
                    $baseName = if ($p.name) { [string]$p.name } else { "mcp" }
                    $clean = (((Get-SafeFileName $baseName) -replace '[^A-Za-z0-9_\-]', '-') -replace '-+', '-').Trim('-')
                    if (-not $clean) { $clean = [Guid]::NewGuid().ToString('N').Substring(0, 8) }
                    $id = "mcp-" + $clean
                    $try = $id; $i = 2
                    while ([System.IO.Directory]::Exists((Join-Path (Get-SkillsDir) $try))) { $try = $id + "-" + $i; $i++ }
                    $id = $try
                }
                $dir = Resolve-SkillDir $id
                if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
                $existing = Read-SkillManifest $dir
                $now = (Get-Date).ToString("o")
                function Pg($o, $k, $d) { if ($o -and ($o.PSObject.Properties.Name -contains $k) -and $null -ne $o.$k) { return $o.$k } return $d }
                # 缺省值回退到已存在的 manifest，避免部分更新(如仅 trusted)清空其它字段
                $instAt = if ($existing -and $existing.installedAt) { $existing.installedAt } else { $now }
                if ($existing) {
                    $dName = $existing.name; $dIcon = $existing.icon; $dDesc = $existing.description; $dTransport = $existing.transport
                    $dCommand = $existing.command; $dArgs = $existing.args; $dEnv = $existing.env; $dUrl = $existing.url; $dHeaders = $existing.headers
                    $dTrust = [bool]$existing.trusted; $dSource = $existing.source
                } else {
                    $dName = $id; $dIcon = '🔌'; $dDesc = ''; $dTransport = 'stdio'
                    $dCommand = ''; $dArgs = @(); $dEnv = @{}; $dUrl = ''; $dHeaders = @{}
                    $dTrust = $false; $dSource = @{ type = 'manual' }
                }
                $m = [ordered]@{
                    id          = $id; kind = "mcp"
                    name        = [string](Pg $p 'name' $dName)
                    icon        = [string](Pg $p 'icon' $dIcon)
                    description = [string](Pg $p 'description' $dDesc)
                    transport   = [string](Pg $p 'transport' $dTransport)
                    command     = [string](Pg $p 'command' $dCommand)
                    args        = @(Pg $p 'args' $dArgs)
                    env         = (Pg $p 'env' $dEnv)
                    url         = [string](Pg $p 'url' $dUrl)
                    headers     = (Pg $p 'headers' $dHeaders)
                    trusted     = [bool](Pg $p 'trusted' $dTrust)
                    source      = (Pg $p 'source' $dSource)
                    installedAt = $instAt; updatedAt = $now
                }
                Write-SkillManifest $dir $m
                $body = @{ ok = $true; manifest = $m } | ConvertTo-Json -Depth 10
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($body))
            } catch {
                Write-ServerLog "mcp-save exception: $($_.Exception.Message)"
                $body = @{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($body))
            }
            continue
        }

        if ($requestPath -eq "/mcp-list-tools" -and $method -eq "POST") {
            try {
                $p = $bodyText | ConvertFrom-Json
                $dir = Resolve-SkillDir ([string]$p.id)
                $m = Read-SkillManifest $dir
                if (-not $m) { throw "应用不存在。" }
                $req = New-McpReqBase $m
                $req.op = "list"
                $out = Invoke-McpClient $req
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($out))
            } catch {
                Write-ServerLog "mcp-list-tools exception: $($_.Exception.Message)"
                $body = @{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($body))
            }
            continue
        }

        if ($requestPath -eq "/mcp-call" -and $method -eq "POST") {
            try {
                $p = $bodyText | ConvertFrom-Json
                $dir = Resolve-SkillDir ([string]$p.id)
                $m = Read-SkillManifest $dir
                if (-not $m) { throw "应用不存在。" }
                $confirmed = ($p.PSObject.Properties.Name -contains 'confirmed') -and [bool]$p.confirmed
                if ((-not ([bool]$m.trusted)) -and (-not $confirmed)) { throw "该 MCP 应用尚未确认信任，请先确认后再运行。" }
                $req = New-McpReqBase $m
                $req.op = "call"
                $req.tool = [string]$p.tool
                if ($p.PSObject.Properties.Name -contains 'arguments') { $req.arguments = $p.arguments } else { $req.arguments = @{} }
                $out = Invoke-McpClient $req
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($out))
            } catch {
                Write-ServerLog "mcp-call exception: $($_.Exception.Message)"
                $body = @{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($body))
            }
            continue
        }

        if ($requestPath -like "/mcp-market-search*") {
            try {
                [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
                $q = Get-QueryValue $requestPath "q"
                $base = Get-QueryValue $requestPath "base"
                if (-not $base) { $base = "https://registry.modelcontextprotocol.io/v0/servers" }
                $url = $base + "?limit=50"
                if ($q) { $url = $url + "&search=" + [Uri]::EscapeDataString($q) }
                $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20
                $data = $resp.Content | ConvertFrom-Json
                $servers = @($data.servers)
                if (-not $servers.Count -and $data.PSObject.Properties.Name -contains 'data') { $servers = @($data.data) }
                $items = @()
                foreach ($entry in $servers) {
                    $s = if ($entry.PSObject.Properties.Name -contains 'server') { $entry.server } else { $entry }
                    $nm = [string]$s.name
                    $desc = [string]$s.description
                    $ver = if ($s.version) { [string]$s.version } else { "" }
                    $transport = "stdio"; $command = ""; $argsArr = @(); $remoteUrl = ""
                    $pkgs = @($s.packages)
                    $remotes = @($s.remotes)
                    if ($remotes.Count -ge 1 -and $remotes[0].url) {
                        $transport = "http"; $remoteUrl = [string]$remotes[0].url
                    }
                    elseif ($pkgs.Count -ge 1) {
                        $pk = $pkgs[0]
                        $rt = if ($pk.registry_type) { [string]$pk.registry_type } else { [string]$pk.registry_name }
                        $ident = if ($pk.identifier) { [string]$pk.identifier } else { [string]$pk.name }
                        if ($rt -match 'npm') { $command = "npx"; $argsArr = @("-y", $ident) }
                        elseif ($rt -match 'pypi|pip') { $command = "uvx"; $argsArr = @($ident) }
                        elseif ($rt -match 'oci|docker') { $command = "docker"; $argsArr = @("run", "-i", "--rm", $ident) }
                        else { $command = $ident }
                    }
                    if (-not $q -or ($nm -match [regex]::Escape($q)) -or ($desc -match [regex]::Escape($q))) {
                        $items += @{ name = $nm; description = $desc; version = $ver; transport = $transport; command = $command; args = $argsArr; url = $remoteUrl; source = "registry" }
                    }
                }
                $body = @{ ok = $true; items = @($items) } | ConvertTo-Json -Depth 8
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($body))
            } catch {
                Write-ServerLog "mcp-market-search exception: $($_.Exception.Message)"
                $body = @{ ok = $false; error = $_.Exception.Message; items = @() } | ConvertTo-Json -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($body))
            }
            continue
        }

        # MCPWorld 导航站搜索代理：mcpworld.com 非标准 Registry，列表接口为 /api/mcp-market/servers（搜索词参数 wd），条目多为 GitHub 仓库（serverUrl），映射为通用条目供前端按仓库安装
        if ($requestPath -like "/mcpworld-search*") {
            try {
                [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
                $q = Get-QueryValue $requestPath "q"
                $url = "https://www.mcpworld.com/api/mcp-market/servers?type=total_score_all&pn=1&pl=30"
                if ($q) { $url = $url + "&wd=" + [Uri]::EscapeDataString($q) }
                $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20 -UserAgent "Mozilla/5.0"
                $data = $resp.Content | ConvertFrom-Json
                $servers = @()
                $mcpList = @($data.data.mcpList)
                if ($mcpList.Count -ge 1) { $servers = @($mcpList[0].servers) }
                $items = @()
                foreach ($s in $servers) {
                    $nm = [string]$s.serverName
                    $desc = [string]$s.description
                    $surl = [string]$s.serverUrl
                    $stars = if ($s.star) { [int]$s.star } else { 0 }
                    $repo = ""
                    if ($surl -match 'github\.com/([^/\s]+)/([^/\s#?]+)') { $repo = $matches[1] + "/" + ($matches[2] -replace '\.git$', '') }
                    $items += @{ name = $nm; description = $desc; url = $surl; stars = $stars; repo = $repo; source = "mcpworld" }
                }
                $body = @{ ok = $true; items = @($items) } | ConvertTo-Json -Depth 8
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($body))
            } catch {
                Write-ServerLog "mcpworld-search exception: $($_.Exception.Message)"
                $body = @{ ok = $false; error = $_.Exception.Message; items = @() } | ConvertTo-Json -Compress
                Send-HttpResponse $client 200 "OK" "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($body))
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
