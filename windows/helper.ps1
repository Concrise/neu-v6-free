# 本地助手（Windows）：开机以 SYSTEM 身份运行（install.ps1 注册的计划任务「neu-v6-free helper」），负责这几件事：
#   1. 运行 sing-box：启动安装目录里的 sing-box.exe，退出了就重新拉起。
#   2. 我的规则（/rules）：面板里加的规则写进 rules\user-<目标>.json，sing-box 发现文件变了会自动重新加载。
#      全部规则另存一份在 rules\user-rules.json（面板显示顺序、备注都在这里）。
#   3. 更新配置（/apply）：update.ps1 把新生成的配置交给它，检查通过后替换并重启 sing-box。
#      助手本来就有管理员权限，所以只有第一次安装要点「是」，之后更新都不用。
#   4. 断网保护：只要「经 sing-box 上不了网、绕过它却能上」，就停掉 sing-box（安全模式），电脑回到普通网络。
#      更新后不通自动换回旧配置；运行中每 30 秒检查一次，连续 3 次不通就暂停；sing-box 反复崩溃也会暂停。
#      状态页 http://127.0.0.1:<端口>/ 可以看原因、重新启用；面板里也能手动暂停。
#      服务器单独看：当前网络连不上免流服务器而网络本身是通的，就把「免流服务器」自动切到「不用服务器」，
#      每两分钟试一次，连上了自动切回。
#   5. 物理网卡的 WeakHostSend：sing-box 运行期间关掉（见 FixWeakHost），停止时恢复。
#   6. 流量统计（/traffic）：和 mac/helper.py 相同的记账方式，存在 traffic.json（见「流量统计」一节）。
#   7. 客户端（/profile、/fetch、/apply）：订阅、节点、设置在面板里管，设置存在 profile.json；面板生成的配置交给 /apply 安装。
#   8. 自动更新（/update、/update/check、/update/install）：每天查一次 GitHub 上的新版本，面板里点「更新」后下载、校验、换上新程序。
# 只监听 127.0.0.1；/rules、/profile、/fetch、/apply、/update 都要带和 Clash API 相同的密钥，网页发来的请求只认面板页面。
# 手动运行（调试用，管理员 PowerShell）：powershell -ExecutionPolicy Bypass -File helper.ps1 [-Dir C:\neu-v6-free] [-Port 9091]
param(
  [string]$Dir = $PSScriptRoot,
  [int]$Port = 0,
  [int]$SendCtrlC = 0  # 内部用：让这个进程号的 sing-box 正常退出
)
$ErrorActionPreference = 'Stop'

# 给 sing-box 发 Ctrl+Break：它会自己撤掉 TUN 网卡和路由再退出（实测 1 秒左右）。sing-box 有自己的（隐藏）控制台，
# 要先连到它的控制台上；它是以忽略 Ctrl+C 的方式启动的，所以只能发 Ctrl+Break。本进程也会收到并随之结束，
# 所以单独起一个进程做这件事，助手自己不受影响。只能在同一个会话里用：用户会话里的脚本连不上 SYSTEM 的 sing-box 的控制台
if ($SendCtrlC) {
  Add-Type -Namespace NeuV6 -Name Con -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern bool FreeConsole();
[DllImport("kernel32.dll")] public static extern bool AttachConsole(uint pid);
[DllImport("kernel32.dll")] public static extern bool SetConsoleCtrlHandler(System.IntPtr handler, bool add);
[DllImport("kernel32.dll")] public static extern bool GenerateConsoleCtrlEvent(uint ctrlEvent, uint groupId);
'@
  [void][NeuV6.Con]::FreeConsole()
  if (-not [NeuV6.Con]::AttachConsole($SendCtrlC)) { exit 2 }
  [void][NeuV6.Con]::SetConsoleCtrlHandler([IntPtr]::Zero, $true)
  if (-not [NeuV6.Con]::GenerateConsoleCtrlEvent(1, 0)) { exit 3 }
  Start-Sleep -Milliseconds 300
  exit 0
}
$utf8 = New-Object System.Text.UTF8Encoding $false
$RuleTypes = @('domain_suffix', 'domain', 'domain_keyword', 'ip_cidr', 'process_name')
$Dir = [System.IO.Path]::GetFullPath($Dir).TrimEnd('\', '/')
$Config = Join-Path $Dir 'config.json'
$SingBox = Join-Path $Dir 'sing-box.exe'
$DataDir = Join-Path $Dir 'data'
$LogFile = Join-Path $Dir 'helper.log'
$script:proc = $null
$script:lastStart = [DateTime]::MinValue

function LoadConfig() {
  $script:cfg = [System.IO.File]::ReadAllText($Config, $utf8) | ConvertFrom-Json
  $clash = $script:cfg.experimental.clash_api
  $script:Api = 'http://' + $clash.external_controller
  $script:Secret = [string]$clash.secret
  $script:Origins = @($script:Api, $script:Api.Replace('127.0.0.1', 'localhost'))
  # TUN 网卡名（lib/build.js 里 windows 固定为 neu-v6）；没有 TUN 入站时为空
  $tun = @(@($script:cfg.inbounds) | Where-Object { $_ -and $_.type -eq 'tun' })[0]
  $script:TunName = if ($tun) { if ($tun.interface_name) { [string]$tun.interface_name } else { 'neu-v6' } } else { $null }
  # 目标 id → 规则文件、出口名（规则集 user-<id> 和引用它的路由规则）
  $t = [ordered]@{}
  foreach ($rs in @($script:cfg.route.rule_set)) {
    if ($rs -and $rs.type -eq 'local' -and ([string]$rs.tag).StartsWith('user-')) {
      $t[$rs.tag.Substring(5)] = @{ path = [string]$rs.path; name = $null }
    }
  }
  foreach ($r in @($script:cfg.route.rules)) {
    if (-not $r -or -not $r.rule_set) { continue }
    $sets = @($r.rule_set)
    if ($sets.Count -eq 1 -and ([string]$sets[0]).StartsWith('user-')) {
      $id = ([string]$sets[0]).Substring(5)
      if ($t.Contains($id)) {
        if ($r.outbound) { $t[$id].name = $r.outbound } elseif ($r.action -eq 'reject') { $t[$id].name = '拒绝' }
      }
    }
  }
  $script:Targets = $t
  $script:RulesDir = if ($t.Count) { Split-Path ($t[0].path) } else { Join-Path $Dir 'rules' }
  $script:RulesFile = Join-Path $script:RulesDir 'user-rules.json'
  if ($script:Traffic) { $script:Traffic.version++ }  # 流量统计线程重新读出口
}

LoadConfig
if ($Port -eq 0) {
  $Port = 9091
  try {
    $meta = [System.IO.File]::ReadAllText((Join-Path $Dir 'panel\groups.json'), $utf8) | ConvertFrom-Json
    if ($meta.traffic_port) { $Port = [int]$meta.traffic_port }
  } catch { }
}

function Log($msg) {
  try { [System.IO.File]::AppendAllText($LogFile, "$((Get-Date).ToString('s')) $msg`r`n", $utf8) } catch { }
}

function Bad($msg) { throw (New-Object System.ArgumentException $msg) }

# 把面板里粘贴的东西整理成 sing-box 能用的值；不合法就报错（消息直接显示给用户）
function Normalize([string]$kind, $value) {
  $v = ([string]$value).Trim()
  if ($RuleTypes -notcontains $kind) { Bad "不支持的类型：$kind" }
  if (-not $v) { Bad '内容是空的' }
  if ($kind -eq 'ip_cidr') {
    $parts = $v.Split('/')
    $addr = $null
    # IPv4 要写全四段：.NET 会把 1.2.3 当成 1.2.0.3
    if ($parts[0] -notmatch ':' -and $parts[0] -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { Bad "不是 IP 或网段：$v" }
    if ($parts.Count -gt 2 -or -not [System.Net.IPAddress]::TryParse($parts[0], [ref]$addr)) { Bad "不是 IP 或网段：$v" }
    $max = if ($addr.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) { 128 } else { 32 }
    $prefix = $max
    if ($parts.Count -eq 2 -and -not [int]::TryParse($parts[1], [ref]$prefix)) { Bad "不是 IP 或网段：$v" }
    if ($prefix -lt 0 -or $prefix -gt $max) { Bad "网段长度不对：$v" }
    return "$($addr.ToString())/$prefix"
  }
  if ($kind -eq 'process_name') {
    if ($v -match '[\\/]' -or $v.Length -gt 128) { Bad '进程名只写名字，不要带路径，例如 chrome.exe' }
    return $v
  }
  $v = $v.ToLowerInvariant()
  $v = $v -replace '^[a-z][a-z0-9+.-]*://', ''   # 粘贴了整个网址：去掉协议、路径、端口
  $v = ($v -split '[/?#]', 2)[0]
  $v = ($v -replace ':\d+$', '').TrimStart('*', '.').TrimEnd('.')
  if ($kind -ne 'domain_keyword') {
    try { $v = (New-Object System.Globalization.IdnMapping).GetAscii($v) } catch { Bad "不是域名：$v" }  # 中文域名转成 xn-- 形式
  }
  if ($kind -eq 'domain_keyword') {
    if ($v -cnotmatch '^[a-z0-9._-]+$') { Bad "关键词只能有字母、数字和 . _ -：$v" }
    return $v
  }
  if ($v -cnotmatch '^[a-z0-9-]+(\.[a-z0-9-]+)*$') { Bad "不是域名：$v" }
  return $v
}

function NewRule($kind, $value, $target, $note, $added) {
  [ordered]@{ type = $kind; value = $value; target = $target; note = ([string]$note).Substring(0, [Math]::Min(200, ([string]$note).Length)); added = $added }
}

function Now() { (Get-Date).ToString('s') }

function LoadRules() {
  $list = New-Object System.Collections.ArrayList
  if (Test-Path $script:RulesFile) {
    try {
      $d = [System.IO.File]::ReadAllText($script:RulesFile, $utf8) | ConvertFrom-Json
      foreach ($r in @($d.rules)) { if ($r) { [void]$list.Add((NewRule $r.type $r.value $r.target $r.note $r.added)) } }
      return ,$list
    } catch { Log "读取 $script:RulesFile 失败：$_" }
  }
  # 第一次运行：把规则文件里已有的内容（手动写的）收进来
  foreach ($id in $script:Targets.Keys) {
    $p = $script:Targets[$id].path
    if (-not (Test-Path $p)) { continue }
    try {
      $d = [System.IO.File]::ReadAllText($p, $utf8) | ConvertFrom-Json
      foreach ($r in @($d.rules)) {
        if (-not $r) { continue }
        foreach ($k in $RuleTypes) { foreach ($v in @($r.$k)) { if ($v) { [void]$list.Add((NewRule $k $v $id '' $null)) } } }
      }
    } catch { }
  }
  return ,$list
}

# 先写临时文件再替换：sing-box 不会读到写了一半的文件
function WriteText($path, $text) {
  $tmp = "$path.tmp"
  [System.IO.File]::WriteAllText($tmp, $text, $utf8)
  Move-Item -LiteralPath $tmp -Destination $path -Force
}

# 全部规则 → user-rules.json + 每个目标一个 sing-box 规则集；内容没变的文件不动，免得白白重新加载
function ApplyRules($rules) {
  if (-not $script:Targets.Count) { return }
  WriteText $script:RulesFile (ConvertTo-Json -InputObject ([ordered]@{ version = 1; rules = @($rules) }) -Depth 6)
  foreach ($id in $script:Targets.Keys) {
    $dest = [ordered]@{}
    $procs = @()
    foreach ($r in $rules) {
      if ($r.target -ne $id) { continue }
      if ($r.type -eq 'process_name') { $procs += $r.value }
      else { if (-not $dest.Contains($r.type)) { $dest[$r.type] = @() }; $dest[$r.type] += $r.value }
    }
    # 同一条规则里的域名与 IP 是「或」，进程名和它们是「且」，所以进程名单独一条
    $list = @()
    if ($dest.Count) { $list += , $dest }
    if ($procs.Count) { $list += , ([ordered]@{ process_name = $procs }) }
    $text = ConvertTo-Json -InputObject ([ordered]@{ version = 2; rules = $list }) -Depth 6 -Compress
    $p = $script:Targets[$id].path
    if ((Test-Path $p) -and ([System.IO.File]::ReadAllText($p, $utf8) -eq $text)) { continue }
    WriteText $p $text
  }
}

function View($rules) {
  $ts = @(foreach ($k in $script:Targets.Keys) { [ordered]@{ id = $k; name = $script:Targets[$k].name } })
  $rs = @(foreach ($r in $rules) { $x = [ordered]@{}; foreach ($k in $r.Keys) { $x[$k] = $r[$k] }; $x.orphan = -not $script:Targets.Contains($r.target); $x })
  [ordered]@{ targets = $ts; rules = $rs; dir = $script:RulesDir }
}

function Change([string]$op, $body) {
  $rules = LoadRules
  if ($op -eq 'add') {
    $value = Normalize $body.type $body.value
    if (-not $script:Targets.Contains([string]$body.target)) { Bad "没有这个目标：$($body.target)" }
    # 同一个值只能有一个去处：先删掉旧的
    $keep = New-Object System.Collections.ArrayList
    foreach ($r in $rules) { if (-not ($r.type -eq $body.type -and $r.value -eq $value)) { [void]$keep.Add($r) } }
    [void]$keep.Add((NewRule $body.type $value ([string]$body.target) $body.note (Now)))
    $rules = $keep
  } elseif ($op -eq 'delete') {
    $keep = New-Object System.Collections.ArrayList
    foreach ($r in $rules) { if (-not ($r.type -eq $body.type -and $r.value -eq $body.value)) { [void]$keep.Add($r) } }
    $rules = $keep
  } elseif ($op -eq 'replace') {
    $keep = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($r in @($body.rules)) {
      $i++
      if (-not $r) { continue }
      try { $value = Normalize $r.type $r.value } catch [System.ArgumentException] { Bad "第 $i 条：$($_.Exception.Message)" }
      if (-not $script:Targets.Contains([string]$r.target)) { Bad "第 $i 条：没有这个目标：$($r.target)" }
      $dup = @($keep | Where-Object { $_.type -eq $r.type -and $_.value -eq $value })
      foreach ($d in $dup) { $keep.Remove($d) }
      $added = if ($r.added) { $r.added } else { Now }
      [void]$keep.Add((NewRule $r.type $value ([string]$r.target) $r.note $added))
    }
    $rules = $keep
  }
  ApplyRules $rules
  View $rules
}

# ---------- 断网保护 ----------
# 经 sing-box 的探测：域名（走 TUN、sing-box 的 DNS 与分流）；绕过 sing-box 的探测：绑定物理网卡的地址访问 IP（不经 DNS）
$TunProbes = @('https://www.taobao.com', 'https://www.baidu.com', 'https://www.qq.com')
$DirectProbes6 = @('http://[2400:3200::1]/', 'http://[2402:4e00::]/')
$DirectProbes4 = @('http://220.181.111.1/', 'http://110.242.68.66/')
$SafeFile = Join-Path $Dir 'safe-mode.json'
$IsWin = $env:OS -eq 'Windows_NT'

# ---------- 权限 ----------
# 安装目录普通用户只能读和运行（install.ps1 设的，新建的文件默认继承）；有密钥的文件
# （config.json 及其备份、profile.json）要单独收紧成只给管理员和 SYSTEM
function Protect([string]$path) {
  if ($IsWin -and (Test-Path $path)) { & icacls $path /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null }
}
# App（app\neu-v6-free.exe）读 panel-secret 自动登录面板、在托盘菜单里暂停 / 重新启用。它以普通权限运行，
# 读不了只给管理员组的文件，所以除了管理员和 SYSTEM，再允许登录到这台电脑桌面的用户读（每分钟看一次换没换人）
$SecretFile = Join-Path $Dir 'panel-secret'
$script:secretUsers = @{}
$script:nextGrant = Get-Date
function PublishSecret() {
  if (-not $IsWin) { return }
  if (-not $script:Secret) { Remove-Item $SecretFile -Force -ErrorAction SilentlyContinue; return }
  if (-not (Test-Path $SecretFile)) {
    [IO.File]::WriteAllText($SecretFile, '', $utf8)  # 先建空文件收紧权限，再写内容
    Protect $SecretFile
    $script:secretUsers = @{}
  }
  [IO.File]::WriteAllText($SecretFile, $script:Secret + "`n", $utf8)  # 覆盖已有文件不改它的权限
  GrantSecret
}
function GrantSecret() {
  $script:nextGrant = (Get-Date).AddMinutes(1)
  if (-not $IsWin -or -not (Test-Path $SecretFile)) { return }
  try { $u = [string](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName } catch { return }
  if (-not $u -or $script:secretUsers[$u]) { return }
  & icacls $SecretFile /grant "${u}:R" | Out-Null
  if ($LASTEXITCODE -eq 0) { $script:secretUsers[$u] = $true; Log "允许 $u 读面板密钥（App 自动登录用）" }
}
$Curl = if ($IsWin) { 'curl.exe' } else { 'curl' }  # 非 Windows 只用于开发测试
$NullDev = if ($IsWin) { 'NUL' } else { '/dev/null' }
$script:safe = $null
$script:fails = 0
$script:offline = 0
$script:lastStopTest = [DateTime]::MinValue
$script:lastWatch = Get-Date
$script:restarts = New-Object System.Collections.ArrayList

function Responds([string]$url, [string]$bind) {
  $a = @('-skI', '-o', $NullDev, '-m', '6', '--noproxy', '*', '-w', '%{http_code}')
  if ($bind) { $a += @('--interface', $bind) }
  $code = & $Curl @a $url 2>$null
  return ([bool]$code -and $code -ne '000')
}

# 物理网卡的地址（排除 sing-box 的 neu-v6 网卡和其他虚拟网卡）
function PhysicalAddrs() {
  $r = @{ v4 = @(); v6 = @() }
  if (-not $IsWin) { return $r }
  $cfgs = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object {
    ($_.IPv4DefaultGateway -or $_.IPv6DefaultGateway) -and $_.InterfaceAlias -ne 'neu-v6' -and
    $_.InterfaceAlias -notmatch 'vEthernet|Radmin|Teredo' -and
    $_.NetAdapter.InterfaceDescription -notmatch 'Wintun|TAP-Windows|Tailscale|WireGuard|Clash|Meta|Radmin|Hyper-V|VMware|VirtualBox|ZeroTier' })
  $r.v4 = @($cfgs | ForEach-Object { $_.IPv4Address.IPAddress } | Where-Object { $_ })
  $r.v6 = @($cfgs | ForEach-Object { $_.IPv6Address.IPAddress } | Where-Object { $_ -like '2*' })
  return $r
}

# ok：经 sing-box 能上网；broken：经 sing-box 不通、绕过它能通（sing-box 的问题）；offline：网络本身不通
function DirectOk() {
  $p = PhysicalAddrs
  foreach ($ip in $p.v6) { foreach ($u in $DirectProbes6) { if (Responds $u $ip) { return $true } } }
  foreach ($ip in $p.v4) { foreach ($u in $DirectProbes4) { if (Responds $u $ip) { return $true } } }
  return $false
}

function NetState() {
  foreach ($u in $TunProbes) { if (Responds $u '') { return 'ok' } }
  if (DirectOk) { return 'broken' }
  return 'offline'
}

# sing-box 的 TUN 网卡起来了没有。打开 TUN 卡住时（例如上一次被强杀）sing-box 进程还在，网络照常直连，
# 只看「能不能上网」会误以为它在正常工作
function TunUp() {
  if (-not $IsWin -or -not $script:TunName) { return $true }
  return [bool](Get-NetAdapter -Name $script:TunName -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
}

# sing-box 刚启动时给它一点时间；期间 TUN 起来并且能上网就返回 ok。到时间 TUN 还没起来算 broken（sing-box 没在工作）
function WaitNet([int]$seconds = 25) {
  $end = (Get-Date).AddSeconds($seconds)
  $st = 'broken'
  while ((Get-Date) -lt $end) {
    Start-Sleep -Seconds 4
    if (-not (TunUp)) { continue }
    $st = NetState
    if ($st -eq 'ok') { return $st }
  }
  return $st
}

# 「绕过 sing-box」的探测并不总是真的绕过（例如 WeakHostSend 打开时，绑定物理网卡地址的包照样进 TUN），
# 所以「经 sing-box 不通、绕过也不通」时，停掉 sing-box 再试一次才算数：停掉就通 = 是 sing-box 的问题（返回 $true，sing-box 保持停止）；
# 停掉也不通 = 网络本身不通，重新启动 sing-box
function OkWithoutSingBox() {
  $script:lastStopTest = Get-Date
  StopSingBox
  for ($i = 0; $i -lt 3; $i++) {
    Start-Sleep -Seconds 3
    foreach ($u in $TunProbes) { if (Responds $u '') { Log '停掉 sing-box 后能上网：是 sing-box 的问题'; return $true } }
  }
  StartSingBox
  return $false
}

# 启动（更新、重新启用）后的判断：ok / broken（sing-box 的问题）/ offline（网络本身不通，sing-box 在运行）
function CheckAfterStart() {
  $st = WaitNet
  if ($st -ne 'offline') { return $st }
  if (OkWithoutSingBox) { return 'broken' }
  return 'offline'
}

# ---------- 物理网卡的 WeakHostSend ----------
# 网卡打开了「弱主机发送」时，绑定在它上面的连接也按整张路由表走：TUN 的默认路由优先级最高，
# sing-box 自己连服务器、查 DNS 的包就绕回自己的 TUN，全部超时，整台电脑断网（实测：IPv6 打开、IPv4 关着时，只有 IPv6 全断）。
# Windows 默认是关的，有的软件会把它打开。sing-box 运行期间把物理网卡的这一项关掉，暂停、安全模式、卸载时恢复原值。
# 改过哪些记在 weakhost.json：助手重启、电脑重启后也能恢复
$WeakHostFile = Join-Path $Dir 'weakhost.json'

function FixWeakHost() {
  if (-not $IsWin) { return }
  try {
    $saved = [ordered]@{}
    if (Test-Path $WeakHostFile) {
      foreach ($p in ([System.IO.File]::ReadAllText($WeakHostFile, $utf8) | ConvertFrom-Json).PSObject.Properties) { $saved[$p.Name] = $p.Value }
    }
    $changed = $false
    foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)) {
      foreach ($i in @(Get-NetIPInterface -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue | Where-Object { $_.WeakHostSend -eq 'Enabled' })) {
        Set-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily $i.AddressFamily -WeakHostSend Disabled
        $saved["$($a.InterfaceGuid)|$($i.AddressFamily)"] = 'Enabled'
        $changed = $true
        Log "网卡「$($a.Name)」的 $($i.AddressFamily) 打开了 WeakHostSend（会让 sing-box 自己的连接绕回 TUN），已暂时关掉，停止时恢复"
      }
    }
    if ($changed) { WriteText $WeakHostFile (ConvertTo-Json -InputObject $saved -Compress) }
  } catch { Log "检查 WeakHostSend 失败：$_" }
}

function RestoreWeakHost() {
  if (-not (Test-Path $WeakHostFile)) { return }
  try {
    foreach ($p in ([System.IO.File]::ReadAllText($WeakHostFile, $utf8) | ConvertFrom-Json).PSObject.Properties) {
      $guid, $family = $p.Name.Split('|')
      $a = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceGuid -eq $guid })[0]
      if ($a) { Set-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily $family -WeakHostSend $p.Value -ErrorAction SilentlyContinue }
    }
    Remove-Item $WeakHostFile -Force
    Log '已把物理网卡的 WeakHostSend 恢复成原来的设置'
  } catch { Log "恢复 WeakHostSend 失败：$_" }
}

function LoadSafeMode() {
  if (-not (Test-Path $SafeFile)) { return $null }
  try { return ([System.IO.File]::ReadAllText($SafeFile, $utf8) | ConvertFrom-Json) } catch { return [pscustomobject]@{ since = ''; reason = '未知' } }
}

# 停掉 sing-box（TUN 随之撤销，电脑回到普通网络），记下原因；重启电脑后也保持，直到手动重新启用或更新配置
function EnterSafeMode([string]$reason) {
  StopSingBox
  RestoreWeakHost
  $script:safe = [pscustomobject]@{ since = (Get-Date).ToString('s'); reason = $reason }
  WriteText $SafeFile (ConvertTo-Json -InputObject $script:safe -Compress)
  Log "进入安全模式：$reason"
}

function LeaveSafeMode() {
  if (Test-Path $SafeFile) { Remove-Item $SafeFile -Force }
  $script:safe = $null
  $script:restarts.Clear()
  StartSingBox
}

# 重新启用：启动 sing-box 并确认能上网，不行就退回安全模式
function Resume() {
  LeaveSafeMode
  if ((CheckAfterStart) -eq 'broken') {
    EnterSafeMode '重新启用后经 sing-box 仍然上不了网'
    Bad '重新启用后经 sing-box 仍然上不了网，已再次暂停。看 sing-box.log；离开校园网时先在面板里选「不用服务器」'
  }
  Log '已重新启用'
  ServerCheck $true; $script:firstCheck = $false
  [ordered]@{ ok = $true; server_fallback = (LoadFallback) }
}


# ---------- 服务器连不上时自动改走「不用服务器」 ----------
$EntryName = '免流服务器'           # 与 lib/groups.js 一致
$EntryOff = '不用服务器（离校时选）'
$FallbackFile = Join-Path $Dir 'server-fallback.json'
$script:guard = @{ fails = 0; oks = 0; lastRetry = [DateTime]::MinValue; checked = $false }

# 调 sing-box 的 Clash API。按 UTF-8 解码：PowerShell 5.1 的 Invoke-RestMethod 会把中文分组名解成乱码
function Clash([string]$method, [string]$path, $body) {
  $p = @{ Uri = $script:Api + $path; Method = $method; Headers = @{ Authorization = "Bearer $($script:Secret)" }; TimeoutSec = 12; UseBasicParsing = $true }
  if ($null -ne $body) { $p.Body = $utf8.GetBytes((ConvertTo-Json -InputObject $body -Compress)); $p.ContentType = 'application/json; charset=utf-8' }
  $r = Invoke-WebRequest @p
  $text = $utf8.GetString($r.RawContentStream.ToArray())
  if ($text) { return ($text | ConvertFrom-Json) }
}
function Esc([string]$s) { [Uri]::EscapeDataString($s) }
function EntryNow() { try { return (Clash 'GET' "/proxies/$(Esc $EntryName)" $null).now } catch { return $null } }
function ReachableVia([string]$name) {
  try { $r = Clash 'GET' "/proxies/$(Esc $name)/delay?timeout=6000&url=$(Esc 'https://www.gstatic.com/generate_204')" $null; return [bool]$r.delay } catch { return $false }
}
function LoadFallback() {
  if (-not (Test-Path $FallbackFile)) { return $null }
  try { return ([System.IO.File]::ReadAllText($FallbackFile, $utf8) | ConvertFrom-Json) } catch { return $null }
}
function SetEntry([string]$name) { [void](Clash 'PUT' "/proxies/$(Esc $EntryName)" @{ name = $name }) }

# 模式二才有「免流服务器」。quick：刚启动 / 更新 / 重新启用后立刻判断（连续 2 次连不上就切），平时要连续 3 次
function ServerCheck([bool]$quick) {
  $script:guard.checked = $true
  if (-not (@($script:cfg.outbounds) | Where-Object { $_.tag -eq $EntryName })) { return }
  $now = EntryNow
  if (-not $now) { return }
  $fb = LoadFallback
  if ($fb) {
    if ($now -ne $EntryOff) { Remove-Item $FallbackFile -Force; Log '「免流服务器」已被手动改选，不再自动切换'; return }
    if (((Get-Date) - $script:guard.lastRetry).TotalSeconds -lt 120) { return }
    $script:guard.lastRetry = Get-Date
    if (ReachableVia $fb.previous) {
      $script:guard.oks++
      if ($script:guard.oks -ge 2) { SetEntry $fb.previous; Remove-Item $FallbackFile -Force; $script:guard.oks = 0; Log "免流服务器又能连上了，已切回「$($fb.previous)」" }
    } else { $script:guard.oks = 0 }
    return
  }
  if ($now -eq $EntryOff) { $script:guard.fails = 0; return }
  $tries = if ($quick) { 2 } else { 1 }
  for ($i = 0; $i -lt $tries; $i++) {
    if (ReachableVia $EntryName) { $script:guard.fails = 0; return }
    if ($i + 1 -lt $tries) { Start-Sleep -Seconds 4 }
  }
  if (-not (DirectOk)) { $script:guard.fails = 0; return }  # 网络本身不通，不是服务器的问题
  $script:guard.fails++
  Log "连不上免流服务器「$now」（第 $($script:guard.fails) 次）"
  if ($quick -or $script:guard.fails -ge 3) {
    $script:guard.fails = 0
    SetEntry $EntryOff
    $reason = '当前网络连不上免流服务器（离开了校园网、换了网络，或服务器挂了）'
    WriteText $FallbackFile (ConvertTo-Json -InputObject ([ordered]@{ previous = $now; since = (Get-Date).ToString('s'); reason = $reason }) -Compress)
    Log "免流服务器连不上，已自动改走「$EntryOff」（原来是「$now」）"
  }
}

# ---------- 流量统计（/traffic）----------
# 与 mac/helper.py 相同：每秒读一次 Clash API 的 /connections，按每条连接的实际出口记账：
#   v6 校园网 IPv6 直连（免费）；server 经免流服务器（免费，按服务器分开）；v4 校园网 IPv4 直连（计费）；lan 局域网 / 校园网内；other 看不出来的直连
# 连接在两次采样之间关闭时丢掉的尾巴，用 sing-box 的总流量补齐，按本次各类占比分摊。每 30 秒存一次 traffic.json，格式与 mac 相同。
# 放在单独的线程里：主线程做断网检查时会卡住几十秒，放在一起会漏记
$TrafficFile = Join-Path $Dir 'traffic.json'
$script:Traffic = [hashtable]::Synchronized(@{ json = $null; config = $Config; file = $TrafficFile; version = 0; stop = $false })
$TrafficCollector = {
  param($sh)
  Add-Type -AssemblyName System.Web.Extensions
  $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
  $js.MaxJsonLength = [int]::MaxValue
  $utf8 = New-Object System.Text.UTF8Encoding $false
  $groupTypes = @('selector', 'urltest')
  $m = @{}

  function Empty() { @{ v6 = 0; server = @{}; v4 = 0; lan = 0; other = 0 } }
  function AddTo($b, [string]$k, $n) {
    if ($k.StartsWith('server|')) { $s = $k.Substring(7); $b['server'][$s] = $b['server'][$s] + $n } else { $b[$k] = $b[$k] + $n }
  }
  function LoadOut() {
    $c = $js.DeserializeObject([IO.File]::ReadAllText($sh.config, $utf8))
    $clash = $c['experimental']['clash_api']
    $m.api = 'http://' + $clash['external_controller']
    $m.secret = [string]$clash['secret']
    $m.out = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
    foreach ($o in $c['outbounds']) { $m.out[[string]$o['tag']] = $o }
    $m.members = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
    $e = $m.out['免流服务器']  # 与 lib/groups.js 一致
    if ($e) {
      foreach ($t in $e['outbounds']) { $o = $m.out[[string]$t]; if ($o -and $groupTypes -notcontains $o['type'] -and $o['type'] -ne 'direct') { $m.members[[string]$t] = $true } }
    }
  }
  function Api([string]$path) {
    $r = [System.Net.HttpWebRequest]::Create($m.api + $path)
    $r.Proxy = $null; $r.Timeout = 5000; $r.ReadWriteTimeout = 5000
    $r.Headers['Authorization'] = "Bearer $($m.secret)"
    $resp = $r.GetResponse()
    try { return $js.DeserializeObject((New-Object System.IO.StreamReader($resp.GetResponseStream(), $utf8)).ReadToEnd()) } finally { $resp.Close() }
  }
  # 出口 tag → @('server', 服务器名) / @('v6') / @('v4') / @('direct', 解析策略) / @('other')
  function Resolve([string]$tag, $now, [int]$depth) {
    $o = $m.out[$tag]
    if (-not $o -or $depth -gt 8) { return , @('other') }
    $t = $o['type']
    if ($groupTypes -contains $t) {
      $sel = $now[$tag]
      if (-not $sel) { $sel = $o['default'] }
      if (-not $sel -and $o['outbounds']) { $sel = $o['outbounds'][0] }
      return , (Resolve ([string]$sel) $now ($depth + 1))
    }
    if ($t -eq 'direct') { $st = ''; if ($o['domain_resolver']) { $st = [string]$o['domain_resolver']['strategy'] }; return , @('direct', $st) }
    if ($m.members.ContainsKey($tag)) { return , @('server', ($tag -replace ' [^ ]*$', '')) }  # 入口名「<服务器名> <协议>」→ 服务器名
    if ($o['detour']) { $r = Resolve ([string]$o['detour']) $now ($depth + 1); if ($r[0] -eq 'server') { return , $r } }
    $ip = $null
    if ([System.Net.IPAddress]::TryParse([string]$o['server'], [ref]$ip) -and $ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) { return , @('v6') }
    return , @('v4')
  }
  function IsLan([System.Net.IPAddress]$ip) {
    if ([System.Net.IPAddress]::IsLoopback($ip) -or $ip.IsIPv6LinkLocal -or $ip.IsIPv6Multicast -or $ip.IsIPv6SiteLocal) { return $true }
    $b = $ip.GetAddressBytes()
    if ($b.Length -eq 4) {
      return ($b[0] -eq 10 -or $b[0] -eq 0 -or $b[0] -eq 127 -or ($b[0] -eq 172 -and ($b[1] -band 0xF0) -eq 16) -or ($b[0] -eq 192 -and $b[1] -eq 168) -or
        ($b[0] -eq 169 -and $b[1] -eq 254) -or ($b[0] -eq 198 -and ($b[1] -band 0xFE) -eq 18) -or $b[0] -ge 224)
    }
    return (($b[0] -band 0xFE) -eq 0xFC -or ($b[0] -eq 0x20 -and $b[1] -eq 0x01 -and $b[2] -eq 0x0D -and $b[3] -eq 0xB8))
  }
  function Classify($c, $now) {
    $chains = @($c['chains'])
    $r = if ($chains.Count -and $chains[0]) { Resolve ([string]$chains[0]) $now 0 } else { , @('other') }
    if ($r[0] -eq 'server') { return "server|$($r[1])" }
    if ($r[0] -ne 'direct') { return [string]$r[0] }
    if ($r[1] -eq 'ipv6_only' -or $r[1] -eq 'prefer_ipv6') { return 'v6' }
    if ($r[1] -eq 'ipv4_only') { return 'v4' }
    $md = $c['metadata']
    $h = ([string]$md['host']).ToLowerInvariant()
    if ($h -eq 'neu.edu.cn' -or $h.EndsWith('.neu.edu.cn')) { return 'lan' }
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse([string]$md['destinationIP'], [ref]$ip)) { return 'other' }
    if (IsLan $ip) { return 'lan' }
    if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) { return 'v6' }
    return 'v4'
  }

  $state = $null
  try { $state = $js.DeserializeObject([IO.File]::ReadAllText($sh.file, $utf8)) } catch { }
  if (-not ($state -is [System.Collections.IDictionary])) { $state = @{} }
  if (-not $state['since']) { $state['since'] = (Get-Date).ToString('s') }
  foreach ($k in 'months', 'days') { if (-not ($state[$k] -is [System.Collections.IDictionary])) { $state[$k] = @{} } }
  function Save() {
    $tmp = "$($sh.file).tmp"
    [IO.File]::WriteAllText($tmp, $js.Serialize($state), $utf8)
    Move-Item -LiteralPath $tmp -Destination $sh.file -Force
  }

  $last = $null; $lastTotal = $null; $lastT = $null; $now = @{}; $mix = @{}
  $tick = 0; $ver = -1; $lastSave = Get-Date
  $live = @{ rate = (Empty); updated = $null; ok = $false }
  while (-not $sh.stop) {
    $t0 = Get-Date
    try {
      if ($ver -ne $sh.version) { $ver = $sh.version; LoadOut; $last = $null; $lastTotal = $null }  # /apply 装了新配置
      if ($tick % 5 -eq 0) {
        $now = @{}
        $p = (Api '/proxies')['proxies']
        foreach ($k in $p.Keys) { if ($p[$k]['now']) { $now[$k] = [string]$p[$k]['now'] } }
      }
      $d = Api '/connections'
      $total = [long]$d['downloadTotal'] + [long]$d['uploadTotal']
      $cur = @{}; $deltas = @{}
      foreach ($c in @($d['connections'])) {
        if (-not $c) { continue }
        $n = [long]$c['upload'] + [long]$c['download']
        $cur[[string]$c['id']] = $n
        if ($null -eq $last) { continue }  # 刚启动：已有连接只取基线，不重复记
        $delta = $n - [long]$last[[string]$c['id']]
        if ($delta -lt 0) { $delta = $n }
        if ($delta) { $k = Classify $c $now; $deltas[$k] = [long]$deltas[$k] + $delta }
      }
      if ($null -ne $lastTotal -and $total -ge $lastTotal) {
        $sum = [long]0; foreach ($v in $deltas.Values) { $sum += $v }
        $rest = ($total - $lastTotal) - $sum
        $base = if ($deltas.Count) { $deltas } else { $mix }
        if ($rest -gt 0 -and $base.Count) {
          $s = [long]0; foreach ($v in $base.Values) { $s += $v }
          foreach ($k in @($base.Keys)) { $deltas[$k] = [long]$deltas[$k] + [long][Math]::Floor($rest * $base[$k] / $s) }
        }
      }
      if ($deltas.Count) { $mix = $deltas.Clone() }
      $dt = 1.0
      if ($lastT) { $dt = [Math]::Max(((Get-Date) - $lastT).TotalSeconds, 0.5) }
      $rate = Empty
      $stamp = Get-Date
      $mk = $stamp.ToString('yyyy-MM'); $dk = $stamp.ToString('yyyy-MM-dd')
      if (-not $state['months'][$mk]) { $state['months'][$mk] = Empty }
      if (-not $state['days'][$dk]) { $state['days'][$dk] = Empty }
      foreach ($k in $deltas.Keys) {
        AddTo $state['months'][$mk] $k $deltas[$k]
        AddTo $state['days'][$dk] $k $deltas[$k]
        AddTo $rate $k ($deltas[$k] / $dt)
      }
      $days = @($state['days'].Keys | Sort-Object)
      if ($days.Count -gt 62) { foreach ($k in $days[0..($days.Count - 63)]) { [void]$state['days'].Remove($k) } }
      $live = @{ rate = $rate; updated = $stamp.ToString('s'); ok = $true }
      $lastT = Get-Date
      $last = $cur; $lastTotal = $total
    } catch {  # sing-box 重启或没在运行：重新取基线
      $last = $null; $lastTotal = $null; $lastT = $null
      $live = @{ rate = $live.rate; updated = $live.updated; ok = $false; error = ([string]$_.Exception.Message) }
    }
    $state['live'] = $live
    $sh.json = $js.Serialize($state)
    [void]$state.Remove('live')
    $tick++
    if (((Get-Date) - $lastSave).TotalSeconds -gt 30) { try { Save } catch { }; $lastSave = Get-Date }
    $wait = 1000 - ((Get-Date) - $t0).TotalMilliseconds
    Start-Sleep -Milliseconds ([Math]::Max([int]$wait, 100))
  }
  try { Save } catch { }
  $sh.saved = $true
}

function StartTraffic() {
  if (-not $IsWin) { return }  # 用到 .NET Framework 的 JavaScriptSerializer，只有 Windows PowerShell 有
  $ps = [powershell]::Create()
  $ps.Runspace = [runspacefactory]::CreateRunspace()
  $ps.Runspace.Open()
  [void]$ps.AddScript($TrafficCollector.ToString()).AddArgument($script:Traffic)
  [void]$ps.BeginInvoke()
  $script:TrafficPs = $ps
}

# ---------- 运行 sing-box ----------
# 先让它自己退出（Ctrl+Break，见文件开头），10 秒没退再强杀。
# 强杀会留下没清理干净的 TUN 网卡：紧接着再启动时打不开 TUN（实测十几秒后以代码 1 退出）
function StopProcess($p) {
  if (-not $p -or $p.HasExited) { return }
  Log "停止 sing-box（pid $($p.Id)）"
  if ($IsWin) {
    try {
      $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
      Start-Process $ps -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PSCommandPath`" -SendCtrlC $($p.Id)" -WindowStyle Hidden -Wait
      if ($p.WaitForExit(10000)) { return }
      Log "sing-box（pid $($p.Id)）10 秒内没有正常退出，强制结束"
    } catch { }
  }
  try { $p.Kill(); [void]$p.WaitForExit(5000) } catch { }
}

function StopSingBox() {
  StopProcess $script:proc
  # 上一个助手留下的（助手升级、异常退出时）
  Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $SingBox } | ForEach-Object { StopProcess $_ }
  $script:proc = $null
}

function StartSingBox() {
  StopSingBox
  if (-not (Test-Path $SingBox)) { Log "找不到 $SingBox，重新运行 install.ps1"; return }
  FixWeakHost
  New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
  # 上一次的日志留一份：sing-box 退出的原因在里面，重新启动会把 sing-box.log 清空
  $log = Join-Path $Dir 'sing-box.log'
  if (Test-Path $log) { Move-Item $log (Join-Path $Dir 'sing-box.prev.log') -Force -ErrorAction SilentlyContinue }
  $script:lastStart = Get-Date
  $opt = @{
    FilePath = $SingBox; ArgumentList = "run -c `"$Config`" -D `"$DataDir`" --disable-color"; WorkingDirectory = $DataDir; PassThru = $true
    RedirectStandardError = (Join-Path $Dir 'sing-box.log'); RedirectStandardOutput = (Join-Path $Dir 'sing-box.out.log')
  }
  if ($env:OS -eq 'Windows_NT') { $opt.WindowStyle = 'Hidden' }  # 其他系统上的 PowerShell（开发测试）没有这个参数
  $script:proc = Start-Process @opt
  try { [void]$script:proc.Handle } catch { }  # 先拿住进程句柄，退出后才读得到退出代码
  Log "sing-box 已启动（pid $($script:proc.Id)）"
  $script:firstCheck = $true
}

# 每秒看一眼：退出了就重新拉起（两次之间至少隔 10 秒）；3 分钟内退出 5 次就不再拉起（安全模式）。
# 每 30 秒检查一次网络，连续 3 次「经 sing-box 不通、绕过它能通」也进安全模式；
# 连续 3 次「都不通」时停掉 sing-box 试一次（最多 10 分钟一次），停掉就通也进安全模式
function Supervise() {
  if ($script:safe) { return }
  $running = $script:proc -and -not $script:proc.HasExited
  if (-not $running) {
    if (((Get-Date) - $script:lastStart).TotalSeconds -lt 10) { return }
    if ($script:proc) {
      Log "sing-box 退出了（代码 $($script:proc.ExitCode)），原因见 sing-box.prev.log"
      $now = Get-Date
      [void]$script:restarts.Add($now)
      foreach ($t in @($script:restarts)) { if (($now - $t).TotalMinutes -gt 3) { $script:restarts.Remove($t) } }
      if ($script:restarts.Count -ge 5) { EnterSafeMode 'sing-box 3 分钟内退出了 5 次（看 sing-box.log 和 sing-box.prev.log）'; return }
    }
    StartSingBox
    return
  }
  if (((Get-Date) - $script:lastWatch).TotalSeconds -lt 30) { return }
  $script:lastWatch = Get-Date
  if (((Get-Date) - $script:lastStart).TotalSeconds -lt 20) { return }  # 刚启动，等它准备好
  FixWeakHost  # 新插上的网卡（网线、USB 网卡）
  $st = NetState
  if ($st -eq 'broken') { $script:fails++; Log "经 sing-box 上不了网，绕过它能上（第 $($script:fails) 次）" } else { $script:fails = 0 }
  if ($st -eq 'offline') { $script:offline++ } else { $script:offline = 0 }
  if ($st -eq 'ok') { ServerCheck ([bool]$script:firstCheck); $script:firstCheck = $false }
  if ($script:fails -ge 3) {
    $script:fails = 0
    EnterSafeMode '连续 3 次检查经 sing-box 上不了网、绕过它能上（配置或 sing-box 本身有问题）'
  } elseif ($script:offline -ge 3 -and ((Get-Date) - $script:lastStopTest).TotalMinutes -ge 10) {
    $script:offline = 0
    Log '连续 3 次检查都上不了网，停掉 sing-box 试一下'
    if (OkWithoutSingBox) { EnterSafeMode '经 sing-box 上不了网，停掉它就能上（配置或 sing-box 本身有问题）' }
  }
}

# ---------- 更新配置（/apply）----------
# sing-box 以 SYSTEM 运行：配置里指向本机文件的字段必须在安装目录内，否则一份配置就能让它往系统任意位置写文件
function FilePaths($node, $list) {
  if ($node -is [System.Management.Automation.PSCustomObject]) {
    foreach ($p in $node.PSObject.Properties) {
      if ($p.Value -is [string] -and $p.Name -match '_path$' -and $p.Name -notmatch '^process_path') { [void]$list.Add(@($p.Name, $p.Value)) }
      else { FilePaths $p.Value $list }
    }
  } elseif ($node -is [System.Array]) { foreach ($x in $node) { FilePaths $x $list } }
}

function CheckPaths($c) {
  $list = New-Object System.Collections.ArrayList
  if ($c.log.output) { [void]$list.Add(@('log.output', $c.log.output)) }
  if ($c.experimental.cache_file.path) { [void]$list.Add(@('cache_file.path', $c.experimental.cache_file.path)) }
  if ($c.experimental.clash_api.external_ui) { [void]$list.Add(@('clash_api.external_ui', $c.experimental.clash_api.external_ui)) }
  foreach ($rs in @($c.route.rule_set)) { if ($rs -and $rs.path) { [void]$list.Add(@('rule_set.path', $rs.path)) } }
  FilePaths $c $list
  foreach ($kv in $list) {
    $k = $kv[0]; $v = [string]$kv[1]
    if ([System.IO.Path]::IsPathRooted($v)) {
      $full = [System.IO.Path]::GetFullPath($v)  # Windows 上会把 C:/x/y 规范成 C:\x\y
      $sep = [System.IO.Path]::DirectorySeparatorChar
      if (-not ($full -ieq $Dir -or $full.StartsWith("$Dir$sep", [StringComparison]::OrdinalIgnoreCase))) { Bad "配置里的 $k 指向安装目录（$Dir）以外：$v" }
    } elseif (($v -replace '\\', '/').Split('/') -contains '..') { Bad "配置里的 $k 不能包含 ..：$v" }
  }
}

function ApplyUpdate($src) {
  $src = [System.IO.Path]::GetFullPath([string]$src)
  $cfgFile = Join-Path $src 'config.json'
  if (-not (Test-Path $cfgFile)) { Bad "$src 里没有 config.json" }
  try { $new = [System.IO.File]::ReadAllText($cfgFile, $utf8) | ConvertFrom-Json } catch { Bad "config.json 不是合法的 JSON：$($_.Exception.Message)" }
  CheckPaths $new
  $panel = Join-Path $Dir 'panel'; $rules = Join-Path $Dir 'rules'
  New-Item -ItemType Directory -Force -Path $panel, $rules | Out-Null
  foreach ($n in 'index.html', 'groups.json') {
    $p = Join-Path (Join-Path $src 'panel') $n
    if (Test-Path $p) { Copy-Item $p (Join-Path $panel $n) -Force }
  }
  $lib = Join-Path (Join-Path $src 'panel') 'lib'  # 面板在浏览器里生成配置用的模块
  if (Test-Path $lib) {
    New-Item -ItemType Directory -Force -Path (Join-Path $panel 'lib') | Out-Null
    foreach ($f in Get-ChildItem $lib -File) { Copy-Item $f.FullName (Join-Path (Join-Path $panel 'lib') $f.Name) -Force }
  }
  if (Test-Path (Join-Path $src 'VERSION')) { Copy-Item (Join-Path $src 'VERSION') $VersionFile -Force }
  $pf = Join-Path $src 'profile.json'  # update.ps1：命令行的设置覆盖面板里的
  if (Test-Path $pf) {
    $new = -not (Test-Path $ProfileFile)
    Copy-Item $pf $ProfileFile -Force
    if ($new -and $IsWin) { & icacls $ProfileFile /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null }
  }
  if (Test-Path (Join-Path $src 'rules')) {
    foreach ($f in Get-ChildItem (Join-Path $src 'rules') -Filter '*.srs') { Copy-Item $f.FullName (Join-Path $rules $f.Name) -Force }
    foreach ($f in Get-ChildItem (Join-Path $src 'rules') -Filter 'user-*.json') {  # 「我的规则」只补缺的
      $t = Join-Path $rules $f.Name
      if (-not (Test-Path $t)) { Copy-Item $f.FullName $t }
    }
  }
  foreach ($rs in @($new.route.rule_set)) {
    if ($rs -and $rs.type -eq 'local' -and ([string]$rs.tag).StartsWith('user-') -and -not (Test-Path $rs.path)) {
      [System.IO.File]::WriteAllText($rs.path, '{"version":2,"rules":[]}', $utf8)
    }
  }
  $staged = "$Config.new"
  Copy-Item $cfgFile $staged -Force
  Protect $staged
  $out = & $SingBox check --disable-color -c $staged 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) { Remove-Item $staged -Force; Bad "sing-box 检查没通过，旧配置没动：$($out.Trim())" }
  Copy-Item $Config "$Config.prev" -Force
  Protect "$Config.prev"
  Move-Item $staged $Config -Force
  LoadConfig
  PublishSecret
  ApplyRules (LoadRules)
  if ($script:safe) { LeaveSafeMode } else { StartSingBox }  # 更新配置 = 重新启用
  if ((CheckAfterStart) -eq 'broken') {
    Move-Item "$Config.prev" $Config -Force
    LoadConfig
    StartSingBox
    $st = CheckAfterStart
    if ($st -eq 'broken') { EnterSafeMode '新配置和旧配置经 sing-box 都上不了网' }
    Log '新配置装上后经 sing-box 上不了网，已换回旧配置'
    $extra = if ($st -eq 'broken') { '；旧配置也不通，已暂停 sing-box（安全模式）' } else { '' }
    Bad "新配置装上后经 sing-box 上不了网，已自动换回旧配置$extra。看 sing-box.log；离开校园网时先在面板里选「不用服务器」"
  }
  $newHelper = Join-Path $src 'helper.ps1'
  $updated = $false
  if ((Test-Path $newHelper) -and ((Get-FileHash $newHelper).Hash -ne (Get-FileHash $PSCommandPath).Hash)) {
    Copy-Item $newHelper $PSCommandPath -Force
    $updated = $true
  }
  ServerCheck $true; $script:firstCheck = $false
  [ordered]@{ ok = $true; restarted = $true; helper_updated = $updated; server_fallback = (LoadFallback) }
}

# ---------- 客户端：订阅、节点、设置都在面板里管（与 mac/helper.py 相同）----------
# 面板保存的全部设置存在安装目录的 profile.json（只有管理员和 SYSTEM 能读）。面板在浏览器里用 lib/build.js 生成配置，
# 再交给 /apply 安装；助手只负责存取设置、代为下载订阅（浏览器有跨域限制）。
# 设置和配置都按原文存取，不经 ConvertTo-Json：它会截断层数深的 JSON，PowerShell 5.1 的 ConvertFrom-Json 也有 2MB 上限
$ProfileFile = Join-Path $Dir 'profile.json'
$MaxBody = 32MB
$MaxDownload = 20MB
$Json = $null
try {  # Windows PowerShell 5.1（.NET Framework）才有；PowerShell 7 用 ConvertFrom-Json -AsHashtable（没有 2MB 上限）
  Add-Type -AssemblyName System.Web.Extensions
  $Json = New-Object System.Web.Script.Serialization.JavaScriptSerializer
  $Json.MaxJsonLength = [int]::MaxValue
} catch { }
function ParseJson([string]$text) {
  if ($Json) { return $Json.DeserializeObject($text) }
  return ($text | ConvertFrom-Json -AsHashtable)
}

# 和这次安装绑定、面板不该改的设置：从正在用的配置里读，面板生成配置时用它们覆盖 profile 里的同名项
function InstallDefaults() {
  $clash = $script:cfg.experimental.clash_api
  $main = @(@($script:cfg.inbounds) | Where-Object { $_ -and $_.tag -eq 'main' })[0]
  $srs = @(@($script:cfg.route.rule_set) | Where-Object { $_ -and $_.type -eq 'local' -and $_.format -eq 'binary' } | ForEach-Object { [string]$_.path })
  $dirOf = { param($p) $p.Substring(0, $p.LastIndexOfAny([char[]]'/\')) }
  [ordered]@{
    platform = 'windows'; clash_api = [string]$clash.external_controller; clash_api_secret = $script:Secret
    windows_panel_dir = if ($clash.external_ui) { [string]$clash.external_ui } else { "$Dir/panel" -replace '\\', '/' }
    windows_rules_dir = if ($srs.Count) { & $dirOf $srs[0] } else { "$Dir/rules" -replace '\\', '/' }
    listen = if ($main.listen) { [string]$main.listen } else { '127.0.0.1' }
    main_port = if ($main.listen_port) { [int]$main.listen_port } else { 10808 }
    traffic_port = $Port
  }
}

function SaveProfile([string]$text) {
  try { $o = ParseJson $text } catch { Bad '设置的格式不对' }
  if (-not ($o -is [System.Collections.IDictionary])) { Bad '设置的格式不对' }
  $new = -not (Test-Path $ProfileFile)
  WriteText $ProfileFile $text
  if ($new -and $IsWin) { & icacls $ProfileFile /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null }
  [ordered]@{ ok = $true }
}

# 下载：返回 @{ status; userinfo; disposition; bytes }（响应关闭后就读不到响应头了，先取出来）。.NET Framework 默认不开 TLS 1.2，先打开
function Download([string]$url, [string]$ua = 'neu-v6-free') {
  $u = $null
  if (-not [Uri]::TryCreate($url, 'Absolute', [ref]$u) -or ($u.Scheme -ne 'http' -and $u.Scheme -ne 'https')) { Bad '只支持 http / https 链接' }
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $r = [System.Net.HttpWebRequest]::Create($u)
  $r.UserAgent = $ua; $r.Timeout = 30000; $r.ReadWriteTimeout = 30000; $r.AutomaticDecompression = 'GZip, Deflate'
  try { $resp = $r.GetResponse() }
  catch [System.Net.WebException] {
    if ($_.Exception.Response) { Bad "服务器返回 $([int]$_.Exception.Response.StatusCode)（链接失效或过期？）" }
    Bad "下载失败：$($_.Exception.Message)"
  }
  try {
    $ms = New-Object System.IO.MemoryStream
    $s = $resp.GetResponseStream(); $buf = New-Object byte[] 65536
    while (($n = $s.Read($buf, 0, $buf.Length)) -gt 0) {
      $ms.Write($buf, 0, $n)
      if ($ms.Length -gt $MaxDownload) { Bad "内容太大（超过 $($MaxDownload / 1MB)MB）" }
    }
    return @{ status = [int]$resp.StatusCode; userinfo = $resp.Headers['subscription-userinfo']; disposition = $resp.Headers['Content-Disposition']; bytes = $ms.ToArray() }
  } finally { $resp.Close() }
}

function FetchSubscription([string]$url) {
  # 带 clash.meta 的 User-Agent：多数机场据此返回完整的 mihomo 配置
  $d = Download $url 'clash.meta (neu-v6-free)'
  [ordered]@{ status = $d.status; text = $utf8.GetString($d.bytes); userinfo = $d.userinfo; disposition = $d.disposition }
}

# 面板生成的配置：放进临时生成目录（和 cli.js 的输出一样的结构），缺的规则集按面板给的地址下载，再走 ApplyUpdate
function ApplyInline($body) {
  $cfgText = $body['config']; $panelText = $body['panel']
  if (-not ($cfgText -is [string]) -or -not ($panelText -is [string])) { Bad '缺少 config 或 panel' }
  try { $new = $cfgText | ConvertFrom-Json } catch { Bad "配置不是合法的 JSON（或超过 2MB）：$($_.Exception.Message)" }
  CheckPaths $new
  $urls = $body['rule_sets']
  $stage = Join-Path $Dir ('.stage-' + [guid]::NewGuid().ToString('N'))
  try {
    $stageRules = Join-Path $stage 'rules'; $stagePanel = Join-Path $stage 'panel'
    New-Item -ItemType Directory -Force -Path $stageRules, $stagePanel | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $stage 'config.json'), $cfgText, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $stagePanel 'groups.json'), $panelText, $utf8)
    foreach ($rs in @($new.route.rule_set)) {
      if (-not $rs -or $rs.type -ne 'local' -or $rs.format -ne 'binary' -or (Test-Path $rs.path)) { continue }
      $name = Split-Path ([string]$rs.path) -Leaf
      if ($name -notmatch '^[\w.!+-]+$') { Bad "规则集文件名不对：$name" }
      $url = if ($urls -is [System.Collections.IDictionary]) { $urls[[string]$rs.tag] } else { $null }
      if (-not ($url -is [string]) -or -not $url.StartsWith('https://')) { Bad "本机没有规则集 $($rs.tag)，也没有给下载地址" }
      [System.IO.File]::WriteAllBytes((Join-Path $stageRules $name), (Download $url).bytes)
    }
    return ApplyUpdate $stage
  } finally { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
}


# ---------- 自动更新：从 GitHub Releases 升级程序本身（与 mac/helper.py 相同）----------
# 只从本仓库的正式发布下载 Windows 安装包，按同一发布里的 SHA256SUMS 校验；装的是面板、生成器、规则集、本地助手和脚本，
# 配置、订阅与设置、我的规则都不动（新生成器要在面板里点一次「应用」才用上）。每天自动查一次，装要用户在面板里点
$UpdateRepo = 'Concrise/neu-v6-free'
$UpdateApi = if ($env:NEU_UPDATE_API) { $env:NEU_UPDATE_API } else { "https://api.github.com/repos/$UpdateRepo/releases/latest" }  # 环境变量只给测试用
$UpdatePrefix = if ($env:NEU_UPDATE_API) { '' } else { "https://github.com/$UpdateRepo/releases/download/" }
$VersionFile = Join-Path $Dir 'VERSION'
$script:upd = @{ latest = $null; notes = ''; url = $null; asset = $null; sums = $null; checked = $null; error = $null }
$script:nextUpdateCheck = (Get-Date).AddSeconds(90)

function CurrentVersion() {
  try { $v = ([IO.File]::ReadAllText($VersionFile)).Trim(); if ($v) { return $v } } catch { }
  return '0'  # 1.0.0 及更早的安装没有版本文件
}
function VNewer([string]$a, [string]$b) {
  $x = @([regex]::Matches($a, '\d+') | Select-Object -First 3 | ForEach-Object { [int]$_.Value }) + @(0, 0, 0)
  $y = @([regex]::Matches($b, '\d+') | Select-Object -First 3 | ForEach-Object { [int]$_.Value }) + @(0, 0, 0)
  for ($i = 0; $i -lt 3; $i++) { if ($x[$i] -ne $y[$i]) { return $x[$i] -gt $y[$i] } }
  return $false
}
function UpdateView() {
  $cur = CurrentVersion; $u = $script:upd
  $newer = [bool]$u.latest -and (VNewer $u.latest $cur)
  $err = if ($u.error) { $u.error } elseif ($newer -and -not $u.asset) { '新版本还没有 Windows 安装包' } else { $null }
  [ordered]@{ current = $cur; latest = $u.latest; available = ($newer -and [bool]$u.asset); notes = $u.notes; url = $u.url; checked = $u.checked; error = $err }
}
function CheckUpdate() {
  try {
    $rel = ParseJson ($utf8.GetString((Download $UpdateApi).bytes))
    $assets = @{}
    foreach ($a in @($rel['assets'])) { if ($a) { $assets[[string]$a['name']] = [string]$a['browser_download_url'] } }
    $win = @($assets.Keys | Where-Object { $_ -like '*-windows.zip' })[0]
    $script:upd.latest = ([string]$rel['tag_name']).TrimStart('v')
    $script:upd.notes = [string]$rel['body']; $script:upd.url = [string]$rel['html_url']
    $script:upd.asset = if ($win) { @{ name = $win; url = $assets[$win] } } else { $null }
    $script:upd.sums = $assets['SHA256SUMS']; $script:upd.error = $null
  } catch { $script:upd.error = "检查更新失败：$($_.Exception.Message)" }
  $script:upd.checked = (Get-Date).ToString('s')
  $script:nextUpdateCheck = (Get-Date).AddHours(24)
  UpdateView
}
function InstallUpdate() {
  $v = CheckUpdate
  if (-not $v.available) { if ($v.error) { Bad $v.error } else { Bad '已经是最新版本' } }
  $a = $script:upd.asset; $sumsUrl = [string]$script:upd.sums
  if (-not $sumsUrl) { Bad '发布里没有 SHA256SUMS，没法校验，不安装' }
  foreach ($u in @($a.url, $sumsUrl)) { if (-not $u.StartsWith($UpdatePrefix)) { Bad "下载地址不是本项目的发布：$u" } }
  $zip = (Download $a.url).bytes
  $sums = $utf8.GetString((Download $sumsUrl).bytes)
  $want = @($sums -split "`n" | Where-Object { $_.Trim().EndsWith($a.name) } | ForEach-Object { ($_.Trim() -split '\s+')[0] })[0]
  $got = -join ([Security.Cryptography.SHA256]::Create().ComputeHash($zip) | ForEach-Object { $_.ToString('x2') })
  if (-not $want -or $got -ne $want.ToLower()) { Bad '安装包校验不通过（SHA256 不符），没有安装' }
  $old = CurrentVersion
  $stage = Join-Path $Dir ('.update-' + [guid]::NewGuid().ToString('N'))
  try {
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    $zf = Join-Path $stage 'pkg.zip'
    [IO.File]::WriteAllBytes($zf, $zip)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $x = Join-Path $stage 'x'
    [IO.Compression.ZipFile]::ExtractToDirectory($zf, $x)  # 有 ..\ 之类越出目录的路径会直接报错
    $pkg = @(Get-ChildItem $x -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'VERSION') })[0]
    if (-not $pkg -or -not (Test-Path (Join-Path $pkg.FullName 'helper.ps1'))) { Bad '安装包的结构不对' }
    $p = $pkg.FullName
    $panel = Join-Path $Dir 'panel'
    Copy-Item (Join-Path (Join-Path $p 'panel') 'index.html') (Join-Path $panel 'index.html') -Force
    $lib = Join-Path $panel 'lib'
    New-Item -ItemType Directory -Force -Path $lib | Out-Null
    foreach ($f in Get-ChildItem (Join-Path (Join-Path $p 'panel') 'lib') -File) { Copy-Item $f.FullName (Join-Path $lib $f.Name) -Force }
    foreach ($f in Get-ChildItem (Join-Path $p 'rules') -Filter '*.srs' -ErrorAction SilentlyContinue) { Copy-Item $f.FullName (Join-Path $script:RulesDir $f.Name) -Force }
    InstallApp $p
    foreach ($n in 'update.ps1', 'uninstall.ps1', 'uninstall.bat', 'VERSION') {
      if (Test-Path (Join-Path $p $n)) { Copy-Item (Join-Path $p $n) (Join-Path $Dir $n) -Force }
    }
    $newHelper = Join-Path $p 'helper.ps1'
    $restart = (Get-FileHash $newHelper).Hash -ne (Get-FileHash $PSCommandPath).Hash
    if ($restart) { Copy-Item $newHelper $PSCommandPath -Force }
  } finally { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
  Log "已从 $old 更新到 $(CurrentVersion)"
  # 安装程序在「设置 → 应用」里登记的版本号也跟着改
  if ($IsWin) { Set-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\neu-v6-free' -Name DisplayVersion -Value (CurrentVersion) -ErrorAction SilentlyContinue }
  [ordered]@{ ok = $true; from = $old; to = (CurrentVersion); helper_restart = $restart }
}

# Windows 外壳（app\neu-v6-free.exe 和 WebView2 的几个 dll）。开着的程序文件不能覆盖、但能改名：
# 旧文件先改名成 *.old 再放新的，exe 最后放；开着的 App 发现自己的版本变了会重新打开，*.old 之后再删
function InstallApp([string]$p) {
  $src = Join-Path $p 'app'
  if (-not (Test-Path (Join-Path $src 'neu-v6-free.exe'))) { return }
  $dest = Join-Path $Dir 'app'
  foreach ($f in (Get-ChildItem $src -Recurse -File | Sort-Object { $_.Name -eq 'neu-v6-free.exe' })) {
    $t = Join-Path $dest $f.FullName.Substring($src.Length + 1)
    New-Item -ItemType Directory -Force -Path (Split-Path $t) | Out-Null
    if (Test-Path $t) { [IO.File]::Move($t, "$t.$([guid]::NewGuid().ToString('N').Substring(0, 8)).old") }
    Copy-Item $f.FullName $t -Force
  }
  CleanOldApp
}
function CleanOldApp() {
  Get-ChildItem (Join-Path $Dir 'app') -Recurse -Filter '*.old' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

# sing-box 停掉时面板（由 sing-box 提供）打不开，助手自己给一个最简单的状态页
$StatusPage = @'
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>校园网 v6 免流 · 状态</title><style>body{font:15px/1.6 "Segoe UI","Microsoft YaHei",-apple-system,sans-serif;max-width:620px;margin:40px auto;padding:0 16px;color:#1c2027}
.card{border:1px solid #e1e4ea;border-radius:12px;padding:16px 18px;margin:12px 0}.ok{color:#157f3b}.warn{color:#b45309}button{padding:6px 14px;border-radius:8px;border:1px solid #2457d6;background:#2457d6;color:#fff;cursor:pointer}
input{padding:6px 10px;border:1px solid #e1e4ea;border-radius:8px}.muted{color:#646b78;font-size:13px}</style></head><body>
<h2>校园网 v6 免流 · 状态</h2><div class="card" id="st">读取中……</div>
<div class="card"><input type="password" id="sec" placeholder="面板密钥"> <button id="go"></button><p class="muted" id="msg"></p></div>
<p class="muted">面板：<a href="http://127.0.0.1:9090/ui">http://127.0.0.1:9090/ui</a>（sing-box 运行时才能打开）</p>
<script>
const $=(i)=>document.getElementById(i);let h=null;try{$("sec").value=localStorage.getItem("neu-secret")||""}catch{}
async function load(){h=await (await fetch("/health",{cache:"no-store"})).json();
$("st").innerHTML=h.safe_mode?`<b class="warn">已暂停（安全模式）</b>：电脑现在走普通网络。<br>原因：${h.safe_mode.reason}<br><span class="muted">${String(h.safe_mode.since).replace("T"," ")} 起</span>`
:(h.singbox?'<b class="ok">运行中</b>：sing-box 正常接管网络。'+(h.server_fallback?`<br><span class="warn">连不上免流服务器，已自动改走「不用服务器」（原来是「${h.server_fallback.previous}」，${String(h.server_fallback.since).replace("T"," ")} 起）；能连上后自动切回。</span>`:''):'<b class="warn">sing-box 没有运行</b>');
$("go").textContent=h.safe_mode||!h.singbox?"重新启用":"暂停（回到普通网络）";}
$("go").onclick=async()=>{const s=$("sec").value.trim();try{localStorage.setItem("neu-secret",s)}catch{}
$("msg").textContent="处理中……（重新启用要等十几秒确认能上网）";
const r=await fetch(h.safe_mode||!h.singbox?"/resume":"/pause",{method:"POST",headers:{Authorization:"Bearer "+s}});
const d=await r.json().catch(()=>({}));$("msg").textContent=r.ok?"完成":(d.error||("失败 "+r.status));load();};
load();</script></body></html>
'@

function Reply($ctx, [int]$code, $obj) {
  $res = $ctx.Response
  $res.StatusCode = $code
  $res.ContentType = 'application/json; charset=utf-8'
  $bytes = $utf8.GetBytes((ConvertTo-Json -InputObject $obj -Depth 8 -Compress))
  $res.ContentLength64 = $bytes.Length
  $res.OutputStream.Write($bytes, 0, $bytes.Length)
  $res.Close()
}

function ReplyRaw($ctx, [int]$code, [string]$json) {
  $res = $ctx.Response
  $res.StatusCode = $code
  $res.ContentType = 'application/json; charset=utf-8'
  $bytes = $utf8.GetBytes($json)
  $res.ContentLength64 = $bytes.Length
  $res.OutputStream.Write($bytes, 0, $bytes.Length)
  $res.Close()
}

function Handle($ctx) {
  $req = $ctx.Request
  $res = $ctx.Response
  $origin = $req.Headers['Origin']
  if ($origin -and $script:Origins -contains $origin) {
    $res.AddHeader('Access-Control-Allow-Origin', $origin)
    $res.AddHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type')
    $res.AddHeader('Access-Control-Allow-Methods', 'GET, POST, PUT')
  }
  $path = $req.Url.AbsolutePath
  $method = $req.HttpMethod
  if ($method -eq 'OPTIONS') { $res.StatusCode = 204; $res.Close(); return }
  if ($path -eq '/health') {
    $running = [bool]($script:proc -and -not $script:proc.HasExited)
    return Reply $ctx 200 ([ordered]@{ ok = $true; rules = [bool]$script:Targets.Count; traffic = [bool]$script:TrafficPs; apply = $true; client = $true; singbox = $running; tun = ($running -and (TunUp)); safe_mode = $script:safe; server_fallback = (LoadFallback); server_checked = $script:guard.checked; version = (CurrentVersion); update = [ordered]@{ latest = $script:upd.latest; available = (UpdateView).available } })
  }
  if ($path -eq '/' -and $method -eq 'GET') {
    $bytes = $utf8.GetBytes($StatusPage)
    $res.ContentType = 'text/html; charset=utf-8'
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
    $res.Close()
    return
  }
  if (($path -eq '/pause' -or $path -eq '/resume') -and $method -eq 'POST') {
    # 只认面板和助手自己的状态页
    $own = @("http://127.0.0.1:$Port", "http://localhost:$Port")
    if (($origin -and ($script:Origins + $own) -notcontains $origin) -or ($script:Secret -and $req.Headers['Authorization'] -ne "Bearer $($script:Secret)")) {
      return Reply $ctx 401 ([ordered]@{ error = '密钥不对' })
    }
    try {
      if ($path -eq '/pause') { EnterSafeMode '手动暂停'; return Reply $ctx 200 ([ordered]@{ ok = $true }) }
      return Reply $ctx 200 (Resume)
    } catch [System.ArgumentException] { return Reply $ctx 400 ([ordered]@{ error = $_.Exception.Message }) }
  }
  if ($path -eq '/profile' -or $path -eq '/fetch' -or $path.StartsWith('/update') -or ($path -eq '/apply' -and $origin)) {
    # 客户端功能（设置、订阅、安装面板生成的配置）：和 /rules 一样只认面板页面 + 密钥
    if (-not $script:Secret -or ($origin -and $script:Origins -notcontains $origin) -or $req.Headers['Authorization'] -ne "Bearer $($script:Secret)") {
      return Reply $ctx 401 ([ordered]@{ error = '密钥不对' })
    }
    try {
      if ($path -eq '/profile' -and $method -eq 'GET') {
        $p = if (Test-Path $ProfileFile) { [System.IO.File]::ReadAllText($ProfileFile, $utf8) } else { 'null' }
        return ReplyRaw $ctx 200 ('{"profile":' + $p + ',"defaults":' + (ConvertTo-Json -InputObject (InstallDefaults) -Compress) + '}')
      }
      if ($path -eq '/update' -and $method -eq 'GET') { if ($script:upd.checked) { return Reply $ctx 200 (UpdateView) } else { return Reply $ctx 200 (CheckUpdate) } }
      if ($path -eq '/update/check' -and $method -eq 'POST') { return Reply $ctx 200 (CheckUpdate) }
      if ($path -eq '/update/install' -and $method -eq 'POST') {
        $result = InstallUpdate
        Reply $ctx 200 $result
        if ($result.helper_restart) { Log '助手已更新，退出后几秒内由计划任务拉起新版'; $script:restartSelf = $true }
        return
      }
      if ($req.ContentLength64 -gt $MaxBody) { Bad '内容太大' }
      $text = (New-Object System.IO.StreamReader($req.InputStream, $utf8)).ReadToEnd()
      if ($path -eq '/profile' -and $method -eq 'PUT') { return Reply $ctx 200 (SaveProfile $text) }
      if ($method -ne 'POST') { return Reply $ctx 404 ([ordered]@{ error = 'not found' }) }
      $body = ParseJson $text
      if (-not ($body -is [System.Collections.IDictionary])) { Bad '请求格式不对' }
      if ($path -eq '/fetch') { return Reply $ctx 200 (FetchSubscription ([string]$body['url'])) }
      $result = ApplyInline $body
      Reply $ctx 200 $result
      if ($result.helper_updated) { Log '助手已升级，退出后几秒内由计划任务拉起新版'; $script:restartSelf = $true }
    } catch [System.ArgumentException] { Reply $ctx 400 ([ordered]@{ error = $_.Exception.Message }) }
    return
  }
  if ($path -eq '/apply' -and $method -eq 'POST') {
    # 本机脚本（update.ps1）：交来生成目录的路径；必须有密钥
    if (-not $script:Secret -or $req.Headers['Authorization'] -ne "Bearer $($script:Secret)") {
      return Reply $ctx 401 ([ordered]@{ error = '密钥不对' })
    }
    $text = (New-Object System.IO.StreamReader($req.InputStream, $utf8)).ReadToEnd()
    try {
      $result = ApplyUpdate (($text | ConvertFrom-Json).src)
      Reply $ctx 200 $result
      if ($result.helper_updated) { Log '助手已升级，退出后几秒内由计划任务拉起新版'; $script:restartSelf = $true }
    } catch [System.ArgumentException] { Reply $ctx 400 ([ordered]@{ error = $_.Exception.Message }) }
    return
  }
  if ($path -eq '/traffic') {
    $j = $script:Traffic.json
    if (-not $j) { return Reply $ctx 503 ([ordered]@{ error = '流量统计还在启动' }) }
    $bytes = $utf8.GetBytes($j)
    $res.ContentType = 'application/json; charset=utf-8'
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
    $res.Close()
    return
  }
  if (-not $path.StartsWith('/rules')) { return Reply $ctx 404 ([ordered]@{ error = 'not found' }) }
  # 浏览器里别的网站也能向 127.0.0.1 发请求：要求密钥，并且只认面板页面
  if (($origin -and $script:Origins -notcontains $origin) -or ($script:Secret -and $req.Headers['Authorization'] -ne "Bearer $script:Secret")) {
    return Reply $ctx 401 ([ordered]@{ error = '密钥不对' })
  }
  $body = $null
  if ($method -eq 'POST' -or $method -eq 'PUT') {
    $reader = New-Object System.IO.StreamReader($req.InputStream, $utf8)
    $text = $reader.ReadToEnd()
    if ($text) { $body = $text | ConvertFrom-Json }
  }
  try {
    if ($method -eq 'GET' -and $path -eq '/rules') { return Reply $ctx 200 (View (LoadRules)) }
    if ($method -eq 'POST' -and $path -eq '/rules') { return Reply $ctx 200 (Change 'add' $body) }
    if ($method -eq 'POST' -and $path -eq '/rules/delete') { return Reply $ctx 200 (Change 'delete' $body) }
    if ($method -eq 'PUT' -and $path -eq '/rules') { return Reply $ctx 200 (Change 'replace' $body) }
    Reply $ctx 404 ([ordered]@{ error = 'not found' })
  } catch [System.ArgumentException] {
    Reply $ctx 400 ([ordered]@{ error = $_.Exception.Message })
  }
}

# 旧版留下的备份没收紧权限；App 用的密钥文件；上次更新换下来的 App 文件
foreach ($f in "$Config.prev", "$Config.new") { Protect $f }
PublishSecret
CleanOldApp
# 启动时按 user-rules.json 重写一遍规则文件（升级后新增的目标也会有文件），然后启动 sing-box
ApplyRules (LoadRules)
$script:safe = LoadSafeMode
if ($script:safe) { StopSingBox; RestoreWeakHost; Log "安全模式（$($script:safe.reason)）：保持 sing-box 停止，在 http://127.0.0.1:$Port/ 重新启用" }
else { StartSingBox }
$script:restartSelf = $false
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try { $listener.Start() } catch { Log "监听 127.0.0.1:$Port 失败（端口被占用，或没有管理员权限）：$_"; throw }
Log "已启动：127.0.0.1:$Port，安装目录 $Dir"
try { StartTraffic } catch { Log "流量统计启动失败：$_" }
while ($listener.IsListening -and -not $script:restartSelf) {
  $wait = $listener.BeginGetContext($null, $null)
  while (-not $wait.AsyncWaitHandle.WaitOne(1000)) {
    Supervise
    if ((Get-Date) -ge $script:nextUpdateCheck) { [void](CheckUpdate) }  # 每天查一次新版本
    if ((Get-Date) -ge $script:nextGrant) { GrantSecret }  # 换了登录用户时让新用户的 App 也能读密钥
  }
  $ctx = $listener.EndGetContext($wait)
  try { Handle $ctx }
  catch {
    Log "处理 $($ctx.Request.HttpMethod) $($ctx.Request.Url.AbsolutePath) 出错：$_"
    try { Reply $ctx 500 ([ordered]@{ error = "出错了：$($_.Exception.Message)" }) } catch { }
  }
  # 请求一个接一个来时（例如 install.ps1 每秒查一次 /health），上面的空闲等待一直轮不到看护：sing-box 退出了也不会被拉起
  Supervise
}
# 助手升级：退出后由计划任务拉起新版（sing-box 继续运行，新版启动时会接管）。
# 计划任务的「失败后重启」只管启动失败、不管退出代码，所以先起一个小进程，等本进程退出后再启动一次计划任务
$listener.Stop()
$script:Traffic.stop = $true  # 让统计线程先存盘
for ($i = 0; $i -lt 30 -and $script:TrafficPs -and -not $script:Traffic.saved; $i++) { Start-Sleep -Milliseconds 100 }
if ($IsWin) {
  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $cmd = "Wait-Process -Id $PID -Timeout 30 -ErrorAction SilentlyContinue; Start-Sleep 2; Start-ScheduledTask -TaskName 'neu-v6-free helper'"
  Start-Process $ps -ArgumentList "-NoProfile -NonInteractive -WindowStyle Hidden -Command `"$cmd`"" -WindowStyle Hidden
}
exit 1
