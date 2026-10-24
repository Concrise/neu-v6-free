# 卸载 Windows 版：停掉 sing-box 和本地助手，删除计划任务、配置、面板和 sing-box.exe。
# 用法：右键 →「使用 PowerShell 运行」；加 -Purge 连「我的规则」一起删。
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
if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) {
  Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $task -Confirm:$false
  Write-Host '本地助手已停止并删除'
}
Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq (Join-Path $dir 'sing-box.exe') } | Stop-Process -Force
Start-Sleep -Seconds 1
foreach ($p in 'config.json', 'panel', 'data', 'sing-box.exe', 'helper.ps1', 'update.ps1', 'helper.log', 'sing-box.log', 'sing-box.out.log') {
  $t = Join-Path $dir $p
  if (Test-Path $t) { Remove-Item $t -Recurse -Force }
}
Remove-Item (Join-Path $dir 'rules\*.srs') -Force -ErrorAction SilentlyContinue
if ($Purge) {
  Remove-Item (Join-Path $dir 'rules') -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host '已卸载，「我的规则」也已删除。'
} else {
  Write-Host "已卸载。「我的规则」保留在 $dir\rules，重新安装后接着用；要一起删除：uninstall.ps1 -Purge"
}
if (-not $NoPause) { Read-Host '按回车关闭' | Out-Null }
