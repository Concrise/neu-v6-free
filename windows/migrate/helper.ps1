# 1.1.x → Go 版本地助手的过渡脚本。只放在发布的 windows.zip 里，名字叫 helper.ps1：
# 1.1.x 的助手在面板里一键更新时只认带 helper.ps1 的安装包，会把它当成新版助手换上，由计划任务「neu-v6-free helper」以 SYSTEM 重新运行。
# 它启动后：从本项目的正式发布下载 Windows 安装包、按 SHA256SUMS 校验、解压，再运行 neu-v6-free.exe install。
# 安装程序会结束这个计划任务（也就是本脚本），所以用 WMI 单独起进程（不属于计划任务，不会被一起结束）。
# 安装程序保留配置、订阅、设置、我的规则和流量统计，改成 Windows 服务、自检，不通就暂停 sing-box；装完在登录用户的桌面上打开 App。
# 这期间 sing-box 一直在运行（旧版助手重启时不停它），网络不受影响。下载失败就隔一分钟再试。
param([string]$Dir = $PSScriptRoot, [int]$Port = 0)
$ErrorActionPreference = 'Stop'
$Repo = 'Concrise/neu-v6-free'
$Api = "https://api.github.com/repos/$Repo/releases/latest"
$Prefix = "https://github.com/$Repo/releases/download/"
$utf8 = New-Object Text.UTF8Encoding $false
$LogFile = Join-Path $Dir 'helper.log'
function Log($msg) { [IO.File]::AppendAllText($LogFile, "$((Get-Date).ToString('s')) [升级到 Go 版] $msg`r`n", $utf8) }
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Download([string]$url) {
  $wc = New-Object Net.WebClient
  $wc.Headers['User-Agent'] = 'neu-v6-free'
  try { return $wc.DownloadData($url) } finally { $wc.Dispose() }
}

function Installing() {
  @(Get-CimInstance Win32_Process -Filter "Name='neu-v6-free.exe'" | Where-Object { $_.CommandLine -like '* install *' }).Count -gt 0
}

function Migrate() {
  $rel = $utf8.GetString((Download $Api)) | ConvertFrom-Json
  $assets = @{}
  foreach ($a in @($rel.assets)) { if ($a) { $assets[[string]$a.name] = [string]$a.browser_download_url } }
  $name = @($assets.Keys | Where-Object { $_ -like '*-windows.zip' })[0]
  if (-not $name -or -not $assets['SHA256SUMS']) { throw '最新发布里没有 Windows 安装包或 SHA256SUMS' }
  foreach ($u in @($assets[$name], $assets['SHA256SUMS'])) { if (-not $u.StartsWith($Prefix)) { throw "下载地址不是本项目的发布：$u" } }
  $zip = Download $assets[$name]
  $sums = $utf8.GetString((Download $assets['SHA256SUMS']))
  $want = @($sums -split "`n" | Where-Object { $_.Trim().EndsWith("  $name") } | ForEach-Object { ($_.Trim() -split '\s+')[0] })[0]
  $got = -join ([Security.Cryptography.SHA256]::Create().ComputeHash($zip) | ForEach-Object { $_.ToString('x2') })
  if (-not $want -or $got -ne $want.ToLower()) { throw '安装包校验不通过（SHA256 不符）' }
  $stage = Join-Path $Dir ('.migrate-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  $zf = Join-Path $stage 'pkg.zip'
  [IO.File]::WriteAllBytes($zf, $zip)
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [IO.Compression.ZipFile]::ExtractToDirectory($zf, $stage)  # 有 ..\ 之类越出目录的路径会直接报错
  $pkg = @(Get-ChildItem $stage -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'VERSION') })[0]
  if (-not $pkg -or -not (Test-Path (Join-Path $pkg.FullName 'neu-v6-free.exe'))) { throw '安装包里没有 neu-v6-free.exe' }
  $exe = Join-Path $pkg.FullName 'neu-v6-free.exe'
  $out = Join-Path $Dir 'migrate.log'
  $installArgs = "install --from `"$($pkg.FullName)`" --name $(Split-Path $Dir -Leaf) --no-pause"
  if ($Port -gt 0) { $installArgs += " --port $Port" }
  $cmd = "cmd.exe /d /c `"`"$exe`" $installArgs > `"$out`" 2>&1`""
  $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd; CurrentDirectory = $pkg.FullName }
  if ($r.ReturnValue -ne 0) { throw "启动安装程序失败（Win32_Process.Create 返回 $($r.ReturnValue)）" }
  Log "已校验 $name，开始安装（输出在 $out）"
}

if (Installing) { Log '安装程序已经在运行' }
else {
  while ($true) {
    try { Migrate; break } catch { Log "没成功：$($_.Exception.Message)；一分钟后再试"; Start-Sleep 60 }
  }
}
# 安装程序会结束本计划任务；在那之前保持运行
while ($true) { Start-Sleep 60 }
