# 第一次安装 Windows 版（只有这一次要管理员权限）：
#   把配置、面板、规则集装到安装目录（默认 C:\neu-v6-free），放好 sing-box.exe，
#   并把本地助手注册成开机自启的计划任务「neu-v6-free helper」（以 SYSTEM 身份运行，由它启动 sing-box）。
# 以后改了订阅或设置：重新生成后运行 update.ps1，不需要管理员。
# 用法：在这个文件上右键 →「使用 PowerShell 运行」；或在 PowerShell 里：
#   powershell -ExecutionPolicy Bypass -File install.ps1 [-SingBox D:\path\sing-box.exe]
# 不指定 -SingBox 时依次找：旁边的 sing-box.exe（ARM64 电脑先找 sing-box-arm64.exe）→ 已安装的 → 从 GitHub 下载测试过的版本。重新安装不会覆盖「我的规则」。
# 发布包（GitHub Releases 的 zip）里的配置是「起步配置」：面板密钥是占位符，第一次安装时随机生成；
# 已经装过时只升级程序和面板，保留现有配置和面板里的订阅、设置。
param([string]$SingBox = '', [switch]$NoPause)
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot

# 断网检查（和本地助手的看门狗相同）：经 sing-box 的探测用域名，绕过它的探测绑定物理网卡的地址访问 IP
function Responds([string]$url, [string]$bind) {
  $a = @('-skI', '-o', 'NUL', '-m', '6', '--noproxy', '*', '-w', '%{http_code}')
  if ($bind) { $a += @('--interface', $bind) }
  $code = & curl.exe @a $url 2>$null
  return ([bool]$code -and $code -ne '000')
}
function NetState() {
  foreach ($u in 'https://www.taobao.com', 'https://www.baidu.com', 'https://www.qq.com') { if (Responds $u '') { return 'ok' } }
  $cfgs = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object {
    ($_.IPv4DefaultGateway -or $_.IPv6DefaultGateway) -and $_.InterfaceAlias -ne 'neu-v6' -and
    $_.InterfaceAlias -notmatch 'vEthernet|Radmin|Teredo' -and
    $_.NetAdapter.InterfaceDescription -notmatch 'Wintun|TAP-Windows|Tailscale|WireGuard|Clash|Meta|Radmin|Hyper-V|VMware|VirtualBox|ZeroTier' })
  foreach ($ip in @($cfgs | ForEach-Object { $_.IPv6Address.IPAddress } | Where-Object { $_ -like '2*' })) {
    foreach ($u in 'http://[2400:3200::1]/', 'http://[2402:4e00::]/') { if (Responds $u $ip) { return 'broken' } }
  }
  foreach ($ip in @($cfgs | ForEach-Object { $_.IPv4Address.IPAddress } | Where-Object { $_ })) {
    foreach ($u in 'http://220.181.111.1/', 'http://110.242.68.66/') { if (Responds $u $ip) { return 'broken' } }
  }
  return 'offline'
}

# 请本地助手暂停：它和 sing-box 都在 SYSTEM 的会话里，能让 sing-box 正常退出（撤掉 TUN 网卡）并恢复 WeakHostSend。
# 本脚本在用户会话里，连不上 sing-box 的控制台，自己只能强杀（强杀后紧接着再启动常常打不开 TUN）
function PauseHelper([string]$cfgFile, [string]$groupsFile) {
  try {
    $c = [IO.File]::ReadAllText($cfgFile) | ConvertFrom-Json
    $p = 9091
    try { $p = [int](([IO.File]::ReadAllText($groupsFile) | ConvertFrom-Json).traffic_port) } catch { }
    Invoke-RestMethod -Uri "http://127.0.0.1:$p/pause" -Method Post -Body '{}' -ContentType 'application/json' `
      -Headers @{ Authorization = "Bearer $($c.experimental.clash_api.secret)" } -TimeoutSec 30 | Out-Null
  } catch { }
}

# 停掉还在运行的 sing-box：先试着让它自己退出，10 秒没退再强杀（同 helper.ps1 的 StopProcess）
function StopSingBox([string]$exe) {
  foreach ($p in @(Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })) {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$src\helper.ps1`" -SendCtrlC $($p.Id)" -WindowStyle Hidden -Wait
    if (-not $p.WaitForExit(10000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
  }
}

# 恢复本地助手暂时关掉的 WeakHostSend（见 helper.ps1 的 FixWeakHost）
function RestoreWeakHost([string]$file) {
  if (-not (Test-Path $file)) { return }
  foreach ($p in ([IO.File]::ReadAllText($file) | ConvertFrom-Json).PSObject.Properties) {
    $guid, $family = $p.Name.Split('|')
    $a = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceGuid -eq $guid })[0]
    if ($a) { Set-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily $family -WeakHostSend $p.Value -ErrorAction SilentlyContinue }
  }
  Remove-Item $file -Force
}

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
  # 起步配置（发布包）：已经装过就保留现有配置；第一次装就生成随机的面板密钥（写进安装目录时替换）
  $starter = ([IO.File]::ReadAllText($cfgPath, $utf8)).Contains('__NEU_SECRET__')
  $keep = $starter -and (Test-Path (Join-Path $dir 'config.json'))
  $secret = $null
  if ($keep) { Write-Host '已经装过：保留现有的配置和面板里的订阅、设置，只升级程序和面板。' }
  elseif ($starter) {
    $b = New-Object byte[] 16
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    $secret = -join ($b | ForEach-Object { $_.ToString('x2') })
  }

  # 已经装过：先停掉自己的助手和 sing-box（助手稍后会带着 sing-box 一起重启）
  $task = 'neu-v6-free helper'
  if (Test-Path (Join-Path $dir 'config.json')) { PauseHelper (Join-Path $dir 'config.json') (Join-Path $dir 'panel\groups.json') }
  if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue }
  StopSingBox (Join-Path $dir 'sing-box.exe')
  RestoreWeakHost (Join-Path $dir 'weakhost.json')
  # 开着的 App（窗口 + 托盘图标）先关掉，才能换它的文件；装完再打开
  Get-Process neu-v6-free -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$dir\app\*" } | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 1
  # 别的代理软件占着端口时 sing-box 起不来
  $ports = @(@($cfg.inbounds) | Where-Object { $_.listen_port } | ForEach-Object { [int]$_.listen_port }) + [int]($cfg.experimental.clash_api.external_controller -split ':')[-1]
  $busy = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $ports -contains $_.LocalPort } |
    ForEach-Object { $p = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue; "$($_.LocalPort)（$($p.ProcessName)）" })
  if ($busy.Count) { throw "端口被占用：$($busy -join '、')。先退出 v2rayN、Clash 等其他代理软件（包括它们的 TUN 模式），再运行一次" }

  New-Item -ItemType Directory -Force -Path $dir, $panelDir, $rulesDir, (Join-Path $dir 'data') | Out-Null
  Remove-Item (Join-Path $dir 'safe-mode.json') -Force -ErrorAction SilentlyContinue  # 重新安装 = 重新启用
  $cfgDest = Join-Path $dir 'config.json'
  if ($keep) { $cfgPath = $cfgDest }
  elseif ($starter) {
    [IO.File]::WriteAllText($cfgDest, ([IO.File]::ReadAllText($cfgPath, $utf8)).Replace('__NEU_SECRET__', $secret), $utf8)
    $cfgPath = $cfgDest
  }
  # 别的代理软件退出后常留下系统代理：指向的端口已经没有程序在听，浏览器就「没网」。这种失效的系统代理直接关掉
  $inet = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
  $ie = Get-ItemProperty $inet
  if ($ie.ProxyEnable -eq 1 -and $ie.ProxyServer) {
    $pp = [int](([string]$ie.ProxyServer -split '[:;=]')[-1])
    if (-not (Get-NetTCPConnection -State Listen -LocalPort $pp -ErrorAction SilentlyContinue)) {
      Set-ItemProperty $inet -Name ProxyEnable -Value 0
      Write-Host "系统代理 $($ie.ProxyServer) 已经没有程序在用（多半是退出的代理软件留下的），已关闭。" -ForegroundColor Yellow
    } else {
      Write-Host "注意：系统代理设成了 $($ie.ProxyServer)，那个程序还在运行。本工具用 TUN 接管全部流量，不需要系统代理。" -ForegroundColor Yellow
    }
  }
  # 代理环境变量不替你改，只提醒：它指向的软件关掉后，用这个变量的程序（命令行工具、Claude Code 等）会连不上
  foreach ($n in 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY') {
    foreach ($scope in 'User', 'Machine') {
      $v = [Environment]::GetEnvironmentVariable($n, $scope)
      if ($v) { Write-Host "注意：环境变量 $n（$scope）= $($v -replace '//[^/@]+@', '//***@')。如果它指向的代理软件已经关掉，请删掉这个变量，否则用它的程序会连不上。" -ForegroundColor Yellow }
    }
  }

  # sing-box.exe：安装程序（setup.exe）里自带 x64 和 ARM64 两个版本，按本机选
  $sbDest = Join-Path $dir 'sing-box.exe'
  $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' } else { 'amd64' }
  $bundled = if ($arch -eq 'arm64' -and (Test-Path (Join-Path $src 'sing-box-arm64.exe'))) { Join-Path $src 'sing-box-arm64.exe' } else { Join-Path $src 'sing-box.exe' }
  if (-not $SingBox -and (Test-Path $bundled)) { $SingBox = $bundled }
  if ($SingBox) { Copy-Item $SingBox $sbDest -Force; Write-Host "sing-box：用 $(Split-Path $SingBox -Leaf)" }
  elseif (Test-Path $sbDest) { Write-Host 'sing-box：沿用已安装的' }
  else {
    # 固定用测试过的版本（和 cli.js 的 SINGBOX_VERSION 一致）：新的大版本常常改配置格式
    $sbVer = '1.13.21'
    Write-Host "正在从 GitHub 下载 sing-box $sbVer……"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $tmp = Join-Path $env:TEMP "neu-v6-sing-box-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
      Invoke-WebRequest -Uri "https://github.com/SagerNet/sing-box/releases/download/v$sbVer/sing-box-$sbVer-windows-$arch.zip" -OutFile "$tmp\sb.zip" -UseBasicParsing
      Expand-Archive "$tmp\sb.zip" $tmp
      Copy-Item (Get-ChildItem $tmp -Recurse -Filter 'sing-box.exe' | Select-Object -First 1).FullName $sbDest -Force
    } catch { throw "下载 sing-box 失败（$($_.Exception.Message)）：请用安装程序 setup.exe 安装（自带 sing-box），或手动下载后用 -SingBox 指定" }
    finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host "sing-box：已下载 $sbVer"
  }

  # 配置、面板、规则集、助手与脚本
  $same = (& $full $src) -eq $dir
  if (-not $same) {
    # 含 panel\lib（面板生成配置用）。保留现有配置时不换 groups.json：它和配置是一对
    $meta = Join-Path $panelDir 'groups.json'
    $keepMeta = if ($keep -and (Test-Path $meta)) { [IO.File]::ReadAllBytes($meta) } else { $null }
    Copy-Item (Join-Path $src 'panel\*') $panelDir -Recurse -Force
    if ($keepMeta) { [IO.File]::WriteAllBytes($meta, $keepMeta) }
    # 面板里「订阅与节点」「设置」的数据（含密钥，只给管理员和 SYSTEM）：命令行生成的覆盖；发布包只在没有时放一份空的
    $pf = Join-Path $src 'profile.json'; $pfDest = Join-Path $dir 'profile.json'
    if ((Test-Path $pf) -and (-not $starter -or -not (Test-Path $pfDest))) {
      Copy-Item $pf $pfDest -Force
      & icacls $pfDest /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null
    } elseif ($secret -and (Test-Path $pfDest)) {
      # 卸载时保留了订阅和设置、这次是重新安装：配置是新的起步配置，提醒在面板里点「应用」
      $t = [IO.File]::ReadAllText($pfDest, $utf8)
      if ($t -notmatch '"pending"\s*:\s*true') { [IO.File]::WriteAllText($pfDest, ($t -replace '^\s*\{', '{"pending":true,'), $utf8) }
    }
    # VERSION：本地助手检查更新用
    foreach ($f in 'helper.ps1', 'update.ps1', 'uninstall.ps1', 'uninstall.bat', 'VERSION') { if (Test-Path (Join-Path $src $f)) { Copy-Item (Join-Path $src $f) $dir -Force } }
    # App：窗口里是面板，托盘里有状态图标（GitHub Actions 编译，见 windows/app）
    if (Test-Path (Join-Path $src 'app\neu-v6-free.exe')) {
      Remove-Item (Join-Path $dir 'app') -Recurse -Force -ErrorAction SilentlyContinue
      Copy-Item (Join-Path $src 'app') $dir -Recurse -Force
    }
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
  if (-not $same -and $cfgPath -ne $cfgDest) { Copy-Item $cfgPath $cfgDest -Force }
  # 安装目录：普通用户只能读和运行（App 在 app 里）。1.1.0 及以前没设，目录继承了 C:\ 的「已验证的用户：修改」，
  # 普通账户就能改以 SYSTEM 运行的 helper.ps1、sing-box.exe。先收紧目录，再让里面的文件都改回继承它
  & icacls $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
  & icacls "$dir\*" /reset /T /C /Q | Out-Null
  # 有节点密码和面板密钥的文件只给管理员和 SYSTEM（App 读的 panel-secret 由本地助手再允许登录的用户读）
  foreach ($f in 'config.json', 'config.json.prev', 'config.json.new', 'profile.json', 'panel-secret') {
    $t = Join-Path $dir $f
    if (Test-Path $t) { & icacls $t /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null }
  }

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
  # 等 TUN 网卡真的起来（只看进程在不在不够：打开 TUN 卡住时进程还在，网络照常直连，自检会误以为通过）
  $h = $null
  for ($i = 0; $i -lt 64 -and -not ($h -and $h.tun); $i++) {
    Start-Sleep -Milliseconds 700
    try { $h = Invoke-RestMethod -Uri "http://127.0.0.1:$port/health" -TimeoutSec 2 } catch { }
  }
  # 断网保护：装完确认经 sing-box 能上网；不通就撤回，电脑回到原来的网络。
  # 「绕过它」的探测不一定可靠（例如 WeakHostSend 打开时绑定物理网卡的包照样进 TUN），所以不通时一律先撤回，再测一次判断原因
  $st = 'broken'
  if ($h -and $h.tun) {
    for ($i = 0; $i -lt 6; $i++) { Start-Sleep -Seconds 4; $st = NetState; if ($st -eq 'ok') { break } }
  }
  if ($st -ne 'ok') {
    PauseHelper $cfgPath (Join-Path $panelDir 'groups.json')
    Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
    Disable-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue | Out-Null
    StopSingBox $sbDest
    RestoreWeakHost (Join-Path $dir 'weakhost.json')
    $without = $false
    for ($i = 0; $i -lt 3 -and -not $without; $i++) { Start-Sleep -Seconds 3; $without = (NetState) -eq 'ok' }
    Remove-Item (Join-Path $dir 'safe-mode.json') -Force -ErrorAction SilentlyContinue  # 上面的暂停留下的；下次安装重新开始
    if (-not ($h -and $h.tun)) { Write-Host 'sing-box 没起来（或者 TUN 网卡没打开），已自动撤回：开机不再启动，网络恢复原样。' -ForegroundColor Red }
    elseif ($without) {
      Write-Host '装上后经 sing-box 上不了网，停掉它就能上：已自动撤回（sing-box 已停止、开机不再启动），网络恢复原样。' -ForegroundColor Red
      Write-Host '常见原因：不在校园网（没有 IPv6，模式二连不上服务器），或别的代理软件还开着 TUN。'
    } else {
      Write-Host '现在网络本身不通（停掉 sing-box 也上不了网），没法自检，已先撤回。联网以后再运行一次 install.bat。' -ForegroundColor Yellow
    }
    Write-Host '最后的日志：'
    Get-Content (Join-Path $dir 'sing-box.log') -Tail 20 -Encoding UTF8 -ErrorAction SilentlyContinue
    Get-Content (Join-Path $dir 'helper.log') -Tail 10 -Encoding UTF8 -ErrorAction SilentlyContinue
    Done 1
  }
  Write-Host '安装完成：自检通过，经 sing-box 能正常上网；开机自动启动。' -ForegroundColor Green
  # 再等本地助手查一次免流服务器（模式二）：连不上时它会自动改走「不用服务器」
  for ($i = 0; $i -lt 15; $i++) {
    try { $h = Invoke-RestMethod -Uri "http://127.0.0.1:$port/health" -TimeoutSec 3 } catch { }
    if ($h.server_checked) { break }
    Start-Sleep -Seconds 3
  }
  if ($h.server_fallback) { Write-Host "注意：当前网络连不上免流服务器，已自动改走「不用服务器」（经服务器的流量改为直连，IPv4 计费）。回到能连上服务器的网络后会自动切回。" -ForegroundColor Yellow }
  Write-Host '万一以后上不了网：本地助手会自动暂停 sing-box；也可以打开 http://127.0.0.1:9091/ 手动暂停或重新启用。' 
  Write-Host ''
  Write-Host '面板：http://127.0.0.1:9090/ui' -ForegroundColor Cyan
  $app = Join-Path $dir 'app\neu-v6-free.exe'
  if (Test-Path $app) {
    # 开始菜单和桌面的入口（所有用户）；以前的版本在开始菜单放的是打开网页的 .url
    $sh = New-Object -ComObject WScript.Shell
    foreach ($l in (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\校园网 v6 免流.lnk'), (Join-Path $env:PUBLIC 'Desktop\校园网 v6 免流.lnk')) {
      $k = $sh.CreateShortcut($l); $k.TargetPath = $app; $k.WorkingDirectory = Split-Path $app; $k.Description = '校园网 v6 免流：面板和运行状态'; $k.Save()
    }
    Remove-Item (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\校园网 v6 免流.url') -Force -ErrorAction SilentlyContinue
    # App 自己读密钥（本地助手写的 panel-secret）登录面板。经 explorer 打开，App 不会以管理员身份运行
    if ($secret) { Write-Host "面板密钥：$secret（App 会自动登录；用浏览器打开面板时要用）" -ForegroundColor Cyan }
    Start-Process explorer.exe $app -ErrorAction SilentlyContinue
    Write-Host '以后从开始菜单、桌面的「校园网 v6 免流」或右下角托盘的 v6 图标打开；关掉窗口、退出 App 都不影响免流。'
  } elseif ($secret) {
    # 第一次装：密钥放在网址的 # 后面（不会发给任何服务器），面板读到后自动登录。经 explorer 打开，浏览器不会以管理员身份运行
    Write-Host "面板密钥：$secret（已经帮你在浏览器里登录；换浏览器时要用）" -ForegroundColor Cyan
    Start-Process explorer.exe "http://127.0.0.1:9090/ui/#secret=$secret" -ErrorAction SilentlyContinue
  }
  Write-Host '以后订阅、节点、设置都在面板里改（「订阅与节点」「设置」），不用再运行脚本。'
  Write-Host "卸载：$dir\uninstall.ps1"
  Done 0
} catch {
  Write-Host "安装失败：$($_.Exception.Message)" -ForegroundColor Red
  Done 1
}
