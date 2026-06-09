$env:PATH = [Environment]::GetEnvironmentVariable("PATH", "User") + ";" + [Environment]::GetEnvironmentVariable("PATH", "Machine")
$s = [System.Net.HttpListener]::new()
$s.Prefixes.Add("http://127.0.0.1:18632/")
$s.Start()
$year = (Get-Date).Year
$endDate = "$year-12-31T23:59:59+08:00"
while ($s.IsListening) {
    $c = $s.GetContext()
    if ($c.Request.Url.AbsolutePath -eq "/sync-calendar") {
        try {
            $raw = & dws calendar event list --start "2026-06-01T00:00:00+08:00" --end $endDate --format json 2>&1
            $json = $raw -join "`n"
            $b = [Text.Encoding]::UTF8.GetBytes($json)
            $c.Response.ContentType = "application/json; charset=utf-8"
            $c.Response.Headers.Add("Access-Control-Allow-Origin", "*")
            $c.Response.ContentLength64 = $b.Length
            $c.Response.OutputStream.Write($b, 0, $b.Length)
        } catch {
            $c.Response.StatusCode = 500
        }
        $c.Response.Close()
    } else {
        $c.Response.StatusCode = 404
        $c.Response.Close()
    }
}
