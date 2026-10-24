# 第一次安装 Windows 版（只有这一次要管理员权限）：
#   把配置、面板、规则集装到安装目录（默认 C:\neu-v6-free），放好 sing-box.exe，
#   并把本地助手注册成开机自启的计划任务「neu-v6-free helper」（以 SYSTEM 身份运行，由它启动 sing-box）。
# 以后改了订阅或设置：重新生成后运行 update.ps1，不需要管理员。
# 用法：在这个文件上右键 →「使用 PowerShell 运行」；或在 PowerShell 里：
#   powershell -ExecutionPolicy Bypass -File install.ps1 [-SingBox D:\path\sing-box.exe]
# 不指定 -SingBox 时依次找：旁边的 sing-box.exe → 已安装的 → 从 GitHub 下载官方最新版。重新安装不会覆盖「我的规则」。
param([string]$SingBox = '', [switch]$NoPause)
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot

function Done($code) {
  if (-not $NoPause) { Read-Host '按回车关闭' | Out-Null }
  exit $code
}

# 计划任务要以 SYSTEM 身份运行：需要管理员
$me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host '需要管理员权限（只有第一次安装需要），正在请求……'
  $extra = if ($SingBox) { " -SingBox `"$SingBox`"" } else { '' }
  Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"$extra"
  exit 0
}

try {
  $utf8 = New-Object System.Text.UTF8Encoding $false
  $cfgPath = Join-Path $src 'config.json'
  if (-not (Test-Path $cfgPath)) { throw '旁边没有 config.json：先生成 Windows 配置（node cli.js -p windows，或网页生成器下载的 zip）' }
  $cfg = [IO.File]::ReadAllText($cfgPath, $utf8) | ConvertFrom-Json
  $full = { param($p) [IO.Path]::GetFullPath(([string]$p).Replace('/', '\')).TrimEnd('\') }

  # 安装目录 = 配置里面板目录的上一级（生成时的 windows_panel_dir，默认 C:/neu-v6-free/panel）
  $panelDir = & $full $cfg.experimental.clash_api.external_ui
  $dir = Split-Path $panelDir
  $rulesDir = Join-Path $dir 'rules'
  foreach ($rs in @($cfg.route.rule_set)) {
    if ($rs -and $rs.path -and (Split-Path (& $full $rs.path)) -ne $rulesDir) {
      throw "配置里的规则目录（$(Split-Path $rs.path)）和 $rulesDir 不一致：生成时 windows_rules_dir 要设成安装目录下的 rules"
    }
  }
  Write-Host "安装到 $dir"

  # 已经装过：先停掉自己的助手和 sing-box（助手稍后会带着 sing-box 一起重启）
  $task = 'neu-v6-free helper'
  if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue }
  Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq (Join-Path $dir 'sing-box.exe') } | Stop-Process -Force
  Start-Sleep -Seconds 1
  # 别的代理软件占着端口时 sing-box 起不来
  $ports = @(@($cfg.inbounds) | Where-Object { $_.listen_port } | ForEach-Object { [int]$_.listen_port }) + [int]($cfg.experimental.clash_api.external_controller -split ':')[-1]
  $busy = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $ports -contains $_.LocalPort } |
    ForEach-Object { $p = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue; "$($_.LocalPort)（$($p.ProcessName)）" })
  if ($busy.Count) { throw "端口被占用：$($busy -join '、')。先退出 v2rayN、Clash 等其他代理软件（包括它们的 TUN 模式），再运行一次" }

  New-Item -ItemType Directory -Force -Path $dir, $panelDir, $rulesDir, (Join-Path $dir 'data') | Out-Null
  # sing-box.exe
  $sbDest = Join-Path $dir 'sing-box.exe'
  if (-not $SingBox -and (Test-Path (Join-Path $src 'sing-box.exe'))) { $SingBox = Join-Path $src 'sing-box.exe' }
  if ($SingBox) { Copy-Item $SingBox $sbDest -Force; Write-Host "sing-box：用 $SingBox" }
  elseif (Test-Path $sbDest) { Write-Host 'sing-box：沿用已安装的' }
  else {
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
    Write-Host '正在从 GitHub 下载 sing-box 官方版……'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/SagerNet/sing-box/releases/latest' -UseBasicParsing
    $asset = @($rel.assets | Where-Object { $_.name -like "sing-box-*-windows-$arch.zip" })[0]
    if (-not $asset) { throw "没找到 windows-$arch 的 sing-box，请手动下载后用 -SingBox 指定" }
    $tmp = Join-Path $env:TEMP "neu-v6-sing-box-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
      Invoke-WebRequest -Uri $asset.browser_download_url -OutFile "$tmp\sb.zip" -UseBasicParsing
      Expand-Archive "$tmp\sb.zip" $tmp
      Copy-Item (Get-ChildItem $tmp -Recurse -Filter 'sing-box.exe' | Select-Object -First 1).FullName $sbDest -Force
    } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host "sing-box：已下载 $($rel.tag_name)"
  }

  # 配置、面板、规则集、助手与脚本
  $same = (& $full $src) -eq $dir
  if (-not $same) {
    Copy-Item (Join-Path $src 'panel\*') $panelDir -Force
    foreach ($f in 'helper.ps1', 'update.ps1', 'uninstall.ps1') { Copy-Item (Join-Path $src $f) $dir -Force }
    if (Test-Path (Join-Path $src 'rules')) {
      if (Test-Path (Join-Path $src 'rules\*.srs')) { Copy-Item (Join-Path $src 'rules\*.srs') $rulesDir -Force }
      foreach ($f in Get-ChildItem (Join-Path $src 'rules') -Filter 'user-*.json') {  # 「我的规则」只补缺的
        $t = Join-Path $rulesDir $f.Name
        if (-not (Test-Path $t)) { Copy-Item $f.FullName $t }
      }
    }
  }
  foreach ($rs in @($cfg.route.rule_set)) {
    if ($rs -and $rs.type -eq 'local' -and -not (Test-Path (& $full $rs.path))) {
      if (([string]$rs.tag).StartsWith('user-')) { [IO.File]::WriteAllText((& $full $rs.path), '{"version":2,"rules":[]}', $utf8) }
      else { throw "缺少规则集 $($rs.path)：用命令行生成（node cli.js -p windows 会下载规则集），或用网页生成器重新下载 zip" }
    }
  }
  $out = & $sbDest check --disable-color -c $cfgPath 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) { throw "sing-box 检查配置没通过：$($out.Trim())" }
  $cfgDest = Join-Path $dir 'config.json'
  if (-not $same) { Copy-Item $cfgPath $cfgDest -Force }
  # config.json 里有节点密码和面板密钥：只给管理员、SYSTEM 和当前用户读
  & icacls $cfgDest /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' "$($env:USERDOMAIN)\$($env:USERNAME):R" | Out-Null

  # 本地助手：开机以 SYSTEM 运行，退出后一分钟自动重启；由它启动并看着 sing-box
  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $arg = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dir\helper.ps1`" -Dir `"$dir`""
  $action = New-ScheduledTaskAction -Execute $ps -Argument $arg
  $trigger = New-ScheduledTaskTrigger -AtStartup
  $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
  Start-ScheduledTask -TaskName $task

  $port = 9091
  try { $port = [int](([IO.File]::ReadAllText((Join-Path $panelDir 'groups.json'), $utf8) | ConvertFrom-Json).traffic_port) } catch { }
  $h = $null
  for ($i = 0; $i -lt 20 -and -not ($h -and $h.singbox); $i++) {
    Start-Sleep -Milliseconds 700
    try { $h = Invoke-RestMethod -Uri "http://127.0.0.1:$port/health" -TimeoutSec 2 } catch { }
  }
  if ($h -and $h.singbox) { Write-Host '安装完成：sing-box 和本地助手都在运行，开机自动启动。' -ForegroundColor Green }
  elseif ($h) { Write-Host "本地助手在运行，但 sing-box 没起来：看 $dir\sing-box.log" -ForegroundColor Yellow }
  else { Write-Host "本地助手没有响应：看 $dir\helper.log" -ForegroundColor Yellow }
  Write-Host ''
  Write-Host '面板：http://127.0.0.1:9090/ui （密钥是生成配置时的 clash_api_secret）' -ForegroundColor Cyan
  Write-Host '以后改了订阅或设置：重新生成，然后运行新生成目录里的 update.ps1（不需要管理员）。'
  Write-Host "卸载：$dir\uninstall.ps1"
  Done 0
} catch {
  Write-Host "安装失败：$($_.Exception.Message)" -ForegroundColor Red
  Done 1
}
