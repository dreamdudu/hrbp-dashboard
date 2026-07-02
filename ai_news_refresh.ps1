# 后台一次性刷新 AI 每日资讯缓存（供 dws_server.ps1 非阻塞调用）。
# 以 DWS_LIBONLY 模式 dot-source 主服务脚本，仅复用其抓取/翻译函数，不启动监听、不抢单实例锁。
$ErrorActionPreference = "SilentlyContinue"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:DWS_LIBONLY = '1'
try {
    . (Join-Path $here "dws_server.ps1")
    # 真正抓取 + 写缓存（Get-AiNewsPayload 内部会写 ai-news-cache.json，并按需翻译写 zh 存储）
    [void](Get-AiNewsPayload -ForceRefresh $true)
} catch {
    try { Add-Content -Path (Join-Path $here "logs\dws_server.log") -Encoding utf8 -Value ("$((Get-Date).ToString('s')) ai-news bg refresh failed: " + $_.Exception.Message) } catch {}
} finally {
    try { Remove-Item -Path (Join-Path $here "data\ai-news-refresh.lock") -Force -ErrorAction SilentlyContinue } catch {}
}
