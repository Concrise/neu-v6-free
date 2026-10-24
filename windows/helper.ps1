# 本地助手（Windows）：开机以 SYSTEM 身份运行（install.ps1 注册的计划任务「neu-v6-free helper」），负责三件事：
#   1. 运行 sing-box：启动安装目录里的 sing-box.exe，退出了就重新拉起。
#   2. 我的规则（/rules）：面板里加的规则写进 rules\user-<目标>.json，sing-box 发现文件变了会自动重新加载。
#      全部规则另存一份在 rules\user-rules.json（面板显示顺序、备注都在这里）。
#   3. 更新配置（/apply）：update.ps1 把新生成的配置交给它，检查通过后替换并重启 sing-box。
#      助手本来就有管理员权限，所以只有第一次安装要点「是」，之后更新都不用。
# 只监听 127.0.0.1；/rules 和 /apply 要带和 Clash API 相同的密钥，/rules 只接受面板页面的跨域请求，/apply 不接受任何网页的请求。
# 手动运行（调试用，管理员 PowerShell）：powershell -ExecutionPolicy Bypass -File helper.ps1 [-Dir C:\neu-v6-free] [-Port 9091]
param(
  [string]$Dir = $PSScriptRoot,
  [int]$Port = 0
)
$ErrorActionPreference = 'Stop'
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

# ---------- 运行 sing-box ----------
function StopSingBox() {
  if ($script:proc -and -not $script:proc.HasExited) { try { $script:proc.Kill(); [void]$script:proc.WaitForExit(5000) } catch { } }
  # 上一个助手留下的（助手升级、异常退出时）
  Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $SingBox } | ForEach-Object {
    try { $_.Kill(); [void]$_.WaitForExit(5000) } catch { }
  }
  $script:proc = $null
}

function StartSingBox() {
  StopSingBox
  if (-not (Test-Path $SingBox)) { Log "找不到 $SingBox，重新运行 install.ps1"; return }
  New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
  $script:lastStart = Get-Date
  $opt = @{
    FilePath = $SingBox; ArgumentList = "run -c `"$Config`" -D `"$DataDir`" --disable-color"; WorkingDirectory = $DataDir; PassThru = $true
    RedirectStandardError = (Join-Path $Dir 'sing-box.log'); RedirectStandardOutput = (Join-Path $Dir 'sing-box.out.log')
  }
  if ($env:OS -eq 'Windows_NT') { $opt.WindowStyle = 'Hidden' }  # 其他系统上的 PowerShell（开发测试）没有这个参数
  $script:proc = Start-Process @opt
  Log "sing-box 已启动（pid $($script:proc.Id)）"
}

# 每秒看一眼：退出了就重新拉起（两次之间至少隔 10 秒，免得配置有错时疯狂重启）
function Supervise() {
  if ($script:proc -and -not $script:proc.HasExited) { return }
  if (((Get-Date) - $script:lastStart).TotalSeconds -lt 10) { return }
  if ($script:proc) { Log "sing-box 退出了（代码 $($script:proc.ExitCode)），重新启动；原因见 sing-box.log" }
  StartSingBox
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
    $p = Join-Path $src "panel\$n"
    if (Test-Path $p) { Copy-Item $p (Join-Path $panel $n) -Force }
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
  $out = & $SingBox check --disable-color -c $staged 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) { Remove-Item $staged -Force; Bad "sing-box 检查没通过，旧配置没动：$($out.Trim())" }
  Move-Item $staged $Config -Force
  LoadConfig
  ApplyRules (LoadRules)
  StartSingBox
  $newHelper = Join-Path $src 'helper.ps1'
  $updated = $false
  if ((Test-Path $newHelper) -and ((Get-FileHash $newHelper).Hash -ne (Get-FileHash $PSCommandPath).Hash)) {
    Copy-Item $newHelper $PSCommandPath -Force
    $updated = $true
  }
  [ordered]@{ ok = $true; restarted = $true; helper_updated = $updated }
}

function Reply($ctx, [int]$code, $obj) {
  $res = $ctx.Response
  $res.StatusCode = $code
  $res.ContentType = 'application/json; charset=utf-8'
  $bytes = $utf8.GetBytes((ConvertTo-Json -InputObject $obj -Depth 8 -Compress))
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
    return Reply $ctx 200 ([ordered]@{ ok = $true; rules = [bool]$script:Targets.Count; traffic = $false; apply = $true; singbox = $running })
  }
  if ($path -eq '/apply' -and $method -eq 'POST') {
    # 只给本机脚本用：网页发来的一律拒绝；必须有密钥
    if ($origin -or -not $script:Secret -or $req.Headers['Authorization'] -ne "Bearer $($script:Secret)") {
      return Reply $ctx 401 ([ordered]@{ error = '密钥不对（或请求来自网页）' })
    }
    $text = (New-Object System.IO.StreamReader($req.InputStream, $utf8)).ReadToEnd()
    try {
      $result = ApplyUpdate (($text | ConvertFrom-Json).src)
      Reply $ctx 200 $result
      if ($result.helper_updated) { Log '助手已升级，退出后由计划任务拉起新版'; $script:restartSelf = $true }
    } catch [System.ArgumentException] { Reply $ctx 400 ([ordered]@{ error = $_.Exception.Message }) }
    return
  }
  if ($path -eq '/traffic') { return Reply $ctx 404 ([ordered]@{ error = 'Windows 版暂不支持流量统计' }) }
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

# 启动时按 user-rules.json 重写一遍规则文件（升级后新增的目标也会有文件），然后启动 sing-box
ApplyRules (LoadRules)
StartSingBox
$script:restartSelf = $false
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try { $listener.Start() } catch { Log "监听 127.0.0.1:$Port 失败（端口被占用，或没有管理员权限）：$_"; throw }
Log "已启动：127.0.0.1:$Port，安装目录 $Dir"
while ($listener.IsListening -and -not $script:restartSelf) {
  $wait = $listener.BeginGetContext($null, $null)
  while (-not $wait.AsyncWaitHandle.WaitOne(1000)) { Supervise }
  $ctx = $listener.EndGetContext($wait)
  try { Handle $ctx }
  catch {
    Log "处理 $($ctx.Request.HttpMethod) $($ctx.Request.Url.AbsolutePath) 出错：$_"
    try { Reply $ctx 500 ([ordered]@{ error = "出错了：$($_.Exception.Message)" }) } catch { }
  }
}
# 助手升级：非零退出，计划任务约 1 分钟后拉起新版（sing-box 继续运行，新版启动时会接管）
$listener.Stop()
exit 1
