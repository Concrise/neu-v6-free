# 更新已安装的 Windows 版（不需要管理员）：把旁边新生成的配置交给本地助手，
# 助手检查通过后替换配置、面板、规则集并重启 sing-box；「我的规则」不受影响。
# 用法：在这个文件上右键 →「使用 PowerShell 运行」；或 powershell -ExecutionPolicy Bypass -File update.ps1
# 改了订阅或设置才需要；在面板里切换分组、加「我的规则」都是立即生效的。
param([switch]$NoPause)
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding $false
$code = 0
try {
  $cfg = [IO.File]::ReadAllText((Join-Path $src 'config.json'), $utf8) | ConvertFrom-Json
  $secret = [string]$cfg.experimental.clash_api.secret
  $port = 9091
  try { $port = [int](([IO.File]::ReadAllText((Join-Path $src 'panel\groups.json'), $utf8) | ConvertFrom-Json).traffic_port) } catch { }
  $body = ConvertTo-Json -InputObject @{ src = $src } -Compress
  $apply = {
    try {
      Invoke-RestMethod -Uri "http://127.0.0.1:$port/apply" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body)) `
        -ContentType 'application/json; charset=utf-8' -Headers @{ Authorization = "Bearer $secret" } -TimeoutSec 180
    } catch [System.Net.WebException] {
      $resp = $_.Exception.Response
      if (-not $resp) { throw "连不上本地助手（127.0.0.1:$port）：还没安装就先运行 install.ps1；装过的话看 C:\neu-v6-free\helper.log" }
      $msg = (New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)).ReadToEnd()
      try { $msg = ($msg | ConvertFrom-Json).error } catch { }
      throw $msg
    }
  }
  $r = & $apply
  if ($r.helper_updated) {
    # 助手刚升级：旧版助手不认识新增的文件（如面板的 panel\lib），等新版起来再交一遍
    Write-Host '本地助手已升级，等它重启后再装一遍新增的文件……'
    for ($i = 0; $i -lt 40; $i++) {
      Start-Sleep -Seconds 1
      try { if ((Invoke-RestMethod -Uri "http://127.0.0.1:$port/health" -TimeoutSec 2).client) { break } } catch { }
    }
    $r = & $apply
  }
  Write-Host '已更新并重启 sing-box。' -ForegroundColor Green
  if ($r.server_fallback) { Write-Host '注意：当前网络连不上免流服务器，已自动改走「不用服务器」；能连上后会自动切回。' -ForegroundColor Yellow }
} catch {
  Write-Host "更新失败：$($_.Exception.Message)" -ForegroundColor Red
  $code = 1
}
if (-not $NoPause) { Read-Host '按回车关闭' | Out-Null }
exit $code
