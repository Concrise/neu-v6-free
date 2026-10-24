# 卸载 Windows 版：停掉 sing-box 和本地助手，删除计划任务、配置、面板和 sing-box.exe。
# 用法：右键 →「使用 PowerShell 运行」；加 -Purge 连「我的规则」和流量统计一起删。
param([switch]$Purge, [switch]$NoPause)
$ErrorActionPreference = 'Stop'
$me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  $extra = if ($Purge) { ' -Purge' } else { '' }
  Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"$extra"
  exit 0
}
$dir = $PSScriptRoot
$task = 'neu-v6-free helper'
# 先请本地助手暂停：它和 sing-box 都在 SYSTEM 的会话里，能让 sing-box 正常退出（撤掉 TUN 网卡）并恢复 WeakHostSend
try {
  $c = [IO.File]::ReadAllText((Join-Path $dir 'config.json')) | ConvertFrom-Json
  $port = 9091
  try { $port = [int](([IO.File]::ReadAllText((Join-Path $dir 'panel\groups.json')) | ConvertFrom-Json).traffic_port) } catch { }
  Invoke-RestMethod -Uri "http://127.0.0.1:$port/pause" -Method Post -Body '{}' -ContentType 'application/json' `
    -Headers @{ Authorization = "Bearer $($c.experimental.clash_api.secret)" } -TimeoutSec 30 | Out-Null
} catch { }
if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) {
  Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $task -Confirm:$false
  Write-Host '本地助手已停止并删除'
}
# sing-box 先让它自己退出（撤掉 TUN 网卡），10 秒没退再强杀
foreach ($p in @(Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq (Join-Path $dir 'sing-box.exe') })) {
  if (Test-Path "$dir\helper.ps1") { Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$dir\helper.ps1`" -SendCtrlC $($p.Id)" -WindowStyle Hidden -Wait }
  if (-not $p.WaitForExit(10000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
}
Start-Sleep -Seconds 1
# 本地助手暂时关掉的 WeakHostSend 恢复原值（见 helper.ps1 的 FixWeakHost）
$wh = Join-Path $dir 'weakhost.json'
if (Test-Path $wh) {
  foreach ($p in ([IO.File]::ReadAllText($wh) | ConvertFrom-Json).PSObject.Properties) {
    $guid, $family = $p.Name.Split('|')
    $a = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceGuid -eq $guid })[0]
    if ($a) { Set-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily $family -WeakHostSend $p.Value -ErrorAction SilentlyContinue }
  }
  Write-Host '网卡的 WeakHostSend 已恢复成安装前的设置'
}
foreach ($p in 'config.json', 'config.json.prev', 'config.json.new', 'panel', 'data', 'sing-box.exe', 'helper.ps1', 'update.ps1', 'helper.log', 'sing-box.log', 'sing-box.prev.log', 'sing-box.out.log', 'safe-mode.json', 'server-fallback.json', 'weakhost.json') {
  $t = Join-Path $dir $p
  if (Test-Path $t) { Remove-Item $t -Recurse -Force }
}
Remove-Item (Join-Path $dir 'rules\*.srs') -Force -ErrorAction SilentlyContinue
if ($Purge) {
  Remove-Item (Join-Path $dir 'rules') -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item (Join-Path $dir 'traffic.json') -Force -ErrorAction SilentlyContinue
  Write-Host '已卸载，「我的规则」和流量统计也已删除。'
} else {
  Write-Host "已卸载。「我的规则」（$dir\rules）和流量统计（traffic.json）保留，重新安装后接着用；要一起删除：uninstall.ps1 -Purge"
}
if (-not $NoPause) { Read-Host '按回车关闭' | Out-Null }
