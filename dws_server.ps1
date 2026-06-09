$env:PATH = [Environment]::GetEnvironmentVariable("PATH", "User") + ";" + [Environment]::GetEnvironmentVariable("PATH", "Machine")
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

$port = 18632
while ($true) {
    try {
        $s = [System.Net.HttpListener]::new()
        $s.Prefixes.Add("http://127.0.0.1:$port/")
        $s.Start()
        break
    } catch {
        $port++
        if ($port -gt 18640) { exit 1 }
    }
}
# 立即写入端口号，让 bat 能读到
$port | Out-File "$scriptDir\.port.txt" -Encoding utf8

$year = (Get-Date).Year
$endDate = "$year-12-31T23:59:59+08:00"
while ($s.IsListening) {
    $c = $s.GetContext()
    $p = $c.Request.Url.AbsolutePath
    if ($p -eq "/sync-calendar") {
        try {
            $raw = & dws calendar event list --start "2026-06-01T00:00:00+08:00" --end $endDate --format json 2>&1
            $json = $raw -join "`n"
            $b = [Text.Encoding]::UTF8.GetBytes($json)
            $c.Response.ContentType = "application/json; charset=utf-8"
            $c.Response.Headers.Add("Access-Control-Allow-Origin", "*")
            $c.Response.ContentLength64 = $b.Length
            $c.Response.OutputStream.Write($b, 0, $b.Length)
        } catch {
            $err = "{""error"":""$($_.Exception.Message -replace '"','\"')""}"
            $b = [Text.Encoding]::UTF8.GetBytes($err)
            $c.Response.ContentType = "application/json; charset=utf-8"
            $c.Response.Headers.Add("Access-Control-Allow-Origin", "*")
            $c.Response.ContentLength64 = $b.Length
            $c.Response.OutputStream.Write($b, 0, $b.Length)
        }
        $c.Response.Close()
    } else {
        $path = $c.Request.Url.AbsolutePath
        if ($path -eq "/") { $path = "/index.html" }
        $filePath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($scriptDir, $path.TrimStart("/")))
        if ([System.IO.File]::Exists($filePath)) {
            $content = [System.IO.File]::ReadAllBytes($filePath)
            $ext = [System.IO.Path]::GetExtension($filePath)
            $mime = @{".html"="text/html; charset=utf-8"; ".css"="text/css"; ".js"="application/javascript"; ".json"="application/json"; ".png"="image/png"; ".jpg"="image/jpeg"; ".svg"="image/svg+xml"; ".ico"="image/x-icon"}
            $ct = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { "application/octet-stream" }
            $c.Response.ContentType = $ct
            $c.Response.ContentLength64 = $content.Length
            $c.Response.OutputStream.Write($content, 0, $content.Length)
        } else {
            $c.Response.StatusCode = 404
        }
        $c.Response.Close()
    }
}
