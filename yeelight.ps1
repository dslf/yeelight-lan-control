<#
.SYNOPSIS
  Управление белыми лампочками Yeelight W3 White по LAN-протоколу.
.DESCRIPTION
  - scan: поиск лампочек (SSDP multicast + TCP-скан порта 55443).
  - У каждой лампочки стабильный алиас: привязка идёт по MAC (id), поэтому при
    смене IP лампочка остаётся той же и управляется тем же алиасом.
  - Лампочки объединяются в группы; команда группе применяется ко всем её членам.
  Настройки и состояния хранятся в config.json рядом со скриптом.
.PARAMETER Command
  scan | list | alias | status | on | off | toggle | bright | group
.PARAMETER Target
  Алиас, IP или имя группы, к которой применить команду. Пусто = все лампочки.
.PARAMETER Alias
  Новый алиас для команды 'alias'.
.PARAMETER Brightness
  Яркость 1-100 для команды 'bright'.
.PARAMETER Group
  Имя группы для команд 'group'.
.PARAMETER GroupAction
  add | remove | show | member-add | member-remove
.PARAMETER Members
  Список алиасов или IP для добавления в группу.
.PARAMETER Network
  Префикс подсети, например 192.168.88 (без последнего октета).
.PARAMETER TimeoutMs
  Время ожидания SSDP-ответов, мс. По умолчанию 3000.
.PARAMETER Sweep
  Принудительно выполнить полный TCP-скан подсети на порту 55443.
.PARAMETER Rescan
  Заново сканировать сеть перед командой (обновить текущие IP).
.EXAMPLE
  .\yeelight.ps1 scan
  .\yeelight.ps1 alias -Target 192.168.88.20 -Alias кухня
  .\yeelight.ps1 on
  .\yeelight.ps1 off -Target кухня
  .\yeelight.ps1 bright -Brightness 40 -Target спальня
  .\yeelight.ps1 group -GroupAction add -Group зал -Members кухня,спальня
  .\yeelight.ps1 on -Target зал
  .\yeelight.ps1 status
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('scan', 'list', 'alias', 'status', 'on', 'off', 'toggle', 'bright', 'group')]
  [string]$Command = 'list',

  [string]$Target,
  [string]$Alias,
  [int]$Brightness,

  [string]$Group,
  [ValidateSet('add', 'remove', 'show', 'member-add', 'member-remove')]
  [string]$GroupAction = 'show',
  [string[]]$Members,

  [string]$Network,
  [int]$TimeoutMs = 3000,
  [switch]$Sweep,
  [switch]$Rescan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CfgPath = Join-Path $PSScriptRoot 'config.json'
$script:CmdId = 1

function Get-LocalPrefix {
  if ($Network) { return $Network.TrimEnd('.') }
  $addr = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
    Sort-Object PrefixLength -Descending |
    Select-Object -First 1
  if (-not $addr) { return '192.168.88' }
  $p = $addr.IPAddress.Split('.')
  "$($p[0]).$($p[1]).$($p[2])"
}

function Normalize-Bulb {
  param($b)
  [pscustomobject]@{
    Mac    = [string]$b.Mac
    Id     = [string]$b.Id
    Alias  = [string]$b.Alias
    Ip     = [string]$b.Ip
    Port   = if ($b.Port) { [int]$b.Port } else { 55443 }
    Model  = [string]$b.Model
    Name   = [string]$b.Name
    Power  = [string]$b.Power
    Bright = [string]$b.Bright
    Source = [string]$b.Source
  }
}

function Get-Config {
  $cfg = @{ bulbs = @(); groups = @{} }
  if (Test-Path -LiteralPath $script:CfgPath) {
    try {
      $o = Get-Content -LiteralPath $script:CfgPath -Raw | ConvertFrom-Json
      if ($o.bulbs) { $cfg.bulbs = @($o.bulbs | ForEach-Object { Normalize-Bulb $_ }) }
      if ($o.groups) {
        foreach ($g in $o.groups.PSObject.Properties) { $cfg.groups[$g.Name] = @($g.Value) }
      }
    } catch { Write-Warning "config.json повреждён, перезаписываю: $_" }
  }
  $cfg
}

function Save-Config {
  param($cfg)
  @{
    bulbs  = @($cfg.bulbs)
    groups = $cfg.groups
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:CfgPath -Encoding utf8BOM
}

function Get-BulbMac {
  param([string]$Ip)
  try {
    $n = Get-NetNeighbor -IPAddress $Ip -AddressFamily IPv4 -ErrorAction Stop |
      Where-Object { $_.LinkLayerAddress } |
      Select-Object -First 1
    if ($n) { return $n.LinkLayerAddress.ToLowerInvariant() }
  } catch { }
  $null
}

function ConvertFrom-SsdpResponse {
  param([string]$Text)
  $props = @{}
  foreach ($l in ($Text -split "`r?`n")) {
    if ($l -match '^([^:]+):\s*(.*)$') { $props[$Matches[1].ToLowerInvariant()] = $Matches[2] }
  }
  $loc = [string]$props['location']
  $ip = ''
  $port = 55443
  if ($loc -match '^[a-z]+://([^:]+)(?::(\d+))?') {
    $ip = $Matches[1]
    if ($Matches[2]) { $port = [int]$Matches[2] }
  }
  $mac = [string]$props['id']
  if ($mac -like '0x*') { $mac = $mac.Substring(2) }
  [pscustomobject]@{
    Mac    = $mac.ToLowerInvariant()
    Id     = [string]$props['id']
    Alias  = ''
    Ip     = $ip
    Port   = $port
    Model  = [string]$props['model']
    Name   = [string]$props['name']
    Power  = [string]$props['power']
    Bright = [string]$props['bright']
    Source = 'ssdp'
  }
}

function Find-YeelightSsdp {
  param([int]$TimeoutMs = 3000)
  $result = [System.Collections.Generic.List[object]]::new()
  $group = [Net.IPAddress]::Parse('239.255.255.250')
  $msg = @"
M-SEARCH * HTTP/1.1
HOST: 239.255.255.250:1982
MAN: "ssdp:discover"
ST: wifi_bulb
MX: 5
ORST: wifi_bulb

"@
  $req = [Text.Encoding]::ASCII.GetBytes($msg)
  Write-Verbose 'SSDP: M-SEARCH 239.255.255.250:1982 (ST=wifi_bulb)'
  $udp = $null
  try {
    $udp = [Net.Sockets.UdpClient]::new()
    $udp.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::Socket, [Net.Sockets.SocketOptionName]::ReuseAddress, $true)
    $bound = $false
    try {
      $udp.Client.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Any, 1982))
      $bound = $true
    } catch {
      $udp.Client.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Any, 0))
    }
    if ($bound) {
      try { $udp.JoinMulticastGroup($group) | Out-Null }
      catch { Write-Verbose "SSDP: join group failed: $_" }
    }
    $udp.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::IP, [Net.Sockets.SocketOptionName]::MulticastTimeToLive, 2)
    $end = (Get-Date).AddMilliseconds($TimeoutMs)
    $lastSend = [datetime]::MinValue
    while ((Get-Date) -lt $end) {
      if ((Get-Date) -gt $lastSend.AddMilliseconds(1500)) {
        $udp.Send($req, $req.Length, [Net.IPEndPoint]::new($group, 1982)) | Out-Null
        $lastSend = Get-Date
      }
      $ar = $udp.BeginReceive($null, $null)
      if ($ar.AsyncWaitHandle.WaitOne(500)) {
        $remote = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
        try {
          $data = $udp.EndReceive($ar, [ref]$remote)
          if ($data.Length -gt 0) {
            $text = [Text.Encoding]::ASCII.GetString($data)
            if ($text -match 'wifi_bulb|yeelink|yeelight') {
              $b = ConvertFrom-SsdpResponse -Text $text
              if ($b.Ip) { $result.Add($b) }
            }
          }
        } catch { }
      }
    }
  } finally {
    if ($udp) { $udp.Close() }
  }
  $result
}

function Send-Yeelight {
  param([string]$Address, [int]$Port = 55443, [object]$Payload, [int]$DeadlineMs = 1200)
  function ConvertFrom-YeelightStream {
    param([string]$Text)
    $objects = [System.Collections.Generic.List[object]]::new()
    $depth = 0
    $inStr = $false
    $escaped = $false
    $start = -1
    for ($i = 0; $i -lt $Text.Length; $i++) {
      $c = $Text[$i]
      if ($inStr) {
        if ($escaped) { $escaped = $false; continue }
        if ($c -eq '\') { $escaped = $true; continue }
        if ($c -eq '"') { $inStr = $false }
        continue
      }
      if ($c -eq '"') { $inStr = $true; continue }
      if ($c -eq '{') {
        if ($depth -eq 0) { $start = $i }
        $depth++
        continue
      }
      if ($c -eq '}') {
        $depth--
        if ($depth -eq 0 -and $start -ge 0) {
          $chunk = $Text.Substring($start, $i - $start + 1)
          try { $objects.Add(($chunk | ConvertFrom-Json)) } catch { }
        }
      }
    }
    $objects
  }
  $client = [Net.Sockets.TcpClient]::new()
  try {
    $client.Connect($Address, $Port)
    $stream = $client.GetStream()
    $stream.ReadTimeout = 200
    $json = $Payload | ConvertTo-Json -Compress -Depth 6
    $body = [Text.Encoding]::ASCII.GetBytes($json + "`r`n")
    $stream.Write($body, 0, $body.Length)
    $stream.Flush()
    $sb = [Text.StringBuilder]::new()
    $buf = [byte[]]::new(8192)
    $fallback = $null
    $end = (Get-Date).AddMilliseconds($DeadlineMs)
    while ((Get-Date) -lt $end) {
      try {
        $n = $stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
      } catch { break }
      [void]$sb.Append([Text.Encoding]::ASCII.GetString($buf, 0, $n))
      $objects = ConvertFrom-YeelightStream -Text $sb.ToString()
      $match = @($objects | Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq $payload.id } | Select-Object -First 1)
      if ($match) { return $match[0] }
      if (-not $fallback) {
        $fallback = @($objects | Where-Object {
          $_.PSObject.Properties['result'] -or $_.PSObject.Properties['error']
        } | Select-Object -First 1)
      }
    }
    if ($fallback) { return $fallback[0] }
    return $null
  } finally {
    $client.Close()
  }
}

function Find-YeelightTcp {
  param([string]$Prefix, [int]$ConnectTimeoutMs = 250)
  Write-Verbose "TCP-scan: $Prefix.1 ... $Prefix.254:55443"
  $open = 1..254 | ForEach-Object -Parallel {
    $c = [Net.Sockets.TcpClient]::new()
    try {
      $t = $c.ConnectAsync("$($using:Prefix).$_", 55443)
      if ($t.Wait([int]$using:ConnectTimeoutMs) -and $c.Connected) { return "$($using:Prefix).$_" }
    } catch { }
    finally { $c.Close() }
  } -ThrottleLimit 64
  $result = [System.Collections.Generic.List[object]]::new()
  foreach ($addr in @($open)) {
    try {
      $r = Send-Yeelight -Address $addr -Payload @{ id = 1; method = 'get_prop'; params = @('power', 'bright', 'name') }
      if ($r -and $r.result -and $r.result.Count -ge 3) {
        $result.Add([pscustomobject]@{
          Mac    = (Get-BulbMac $addr)
          Id     = ''
          Alias  = ''
          Ip     = $addr
          Port   = 55443
          Model  = '(tcp)'
          Name   = [string]$r.result[2]
          Power  = [string]$r.result[0]
          Bright = [string]$r.result[1]
          Source = 'tcp-sweep'
        })
      }
    } catch { }
  }
  $result
}

function Discover-Yeelights {
  param([string]$Prefix, [bool]$ForceSweep = $false, [int]$TimeoutMs = 3000)
  $all = [System.Collections.Generic.List[object]]::new()
  foreach ($b in (Find-YeelightSsdp -TimeoutMs $TimeoutMs)) { $all.Add($b) }
  if ($ForceSweep -or $all.Count -eq 0) {
    foreach ($b in (Find-YeelightTcp -Prefix $Prefix)) { $all.Add($b) }
  }
  $seen = @{}
  $unique = @()
  foreach ($b in $all) {
    $key = if ($b.Mac) { "mac:$($b.Mac)" } else { "ip:$($b.Ip)" }
    if ($seen[$key]) { continue }
    $seen[$key] = $true
    $unique += $b
  }
  @($unique)
}

function Merge-Discovered {
  param([object[]]$Existing, [object[]]$Discovered)
  $result = [System.Collections.Generic.List[object]]::new()
  $matched = @{}
  foreach ($d in $Discovered) {
    $found = $null
    if ($d.Mac) {
      $cand = @($Existing | Where-Object { $_.Mac -eq $d.Mac -and $_.Mac })
      if ($cand) { $found = $cand[0] }
    }
    if (-not $found) {
      $cand2 = @($Existing | Where-Object { $_.Ip -eq $d.Ip -and $_.Ip })
      if ($cand2) { $found = $cand2[0] }
    }
    if ($found -and $matched[$found.Alias]) { continue }
    if ($found) { $matched[$found.Alias] = $true }
    $copy = @{
      Mac    = if ($d.Mac) { $d.Mac } elseif ($found) { $found.Mac } else { '' }
      Id     = if ($d.Id) { $d.Id } elseif ($found) { $found.Id } else { '' }
      Alias  = if ($found) { $found.Alias } else { New-AutoAlias -Existing $result }
      Ip     = $d.Ip
      Port   = $d.Port
      Model  = if ($d.Model) { $d.Model } elseif ($found) { $found.Model } else { '' }
      Name   = if ($d.Name) { $d.Name } elseif ($found) { $found.Name } else { '' }
      Power  = $d.Power
      Bright = $d.Bright
      Source = $d.Source
    }
    $result.Add([pscustomobject]$copy)
  }
  foreach ($e in $Existing) { if (-not $matched[$e.Alias]) { $result.Add($e) } }
  @($result)
}

function New-AutoAlias {
  param($Existing)
  $used = @{}
  foreach ($e in @($Existing)) { if ($e.Alias) { $used[$e.Alias] = $true } }
  $i = 1
  while ($used["bulb$i"]) { $i++ }
  "bulb$i"
}

function Free-Alias {
  param($Existing, [string]$Alias)
  if (-not $Alias) { return $false }
  $c = @($Existing | Where-Object { $_.Alias -eq $Alias })
  $c.Count -eq 0
}

function Resolve-Targets {
  param($Bulbs, $Groups, [string]$Target)
  if (-not $Target) { return @($Bulbs) }
  $byAlias = @($Bulbs | Where-Object { $_.Alias -eq $Target })
  if ($byAlias.Count) { return $byAlias }
  $byIp = @($Bulbs | Where-Object { $_.Ip -eq $Target })
  if ($byIp.Count) { return $byIp }
  if ($Groups.ContainsKey($Target)) {
    $aliases = @($Groups[$Target])
    return @($Bulbs | Where-Object { $_.Alias -and ($aliases -contains $_.Alias) })
  }
  $byLike = @($Bulbs | Where-Object { $_.Alias -like "*$Target*" })
  if ($byLike.Count) { return $byLike }
  @()
}

function Resolve-MembersToAliases {
  param($Bulbs, [string[]]$Members)
  $out = @()
  foreach ($m in @($Members)) {
    $b = @($Bulbs | Where-Object { $_.Alias -eq $m -or $_.Ip -eq $m } | Select-Object -First 1)
    if ($b) { $out += $b[0].Alias }
    else { Write-Warning "Пропускаю '$m': нет лампочки с таким алиасом или IP." }
  }
  $out
}

function Write-NoBulbsHint {
  Write-Host 'Лампочки не найдены.' -ForegroundColor Yellow
  Write-Host '  1. Проверьте, что лампа в той же сети (подсеть и префикс).'
  Write-Host '  2. В приложении Mi Home / Yeelight включите "Управление по локальной сети" (LAN Control).'
  Write-Host '  3. Firewall: разрешите UDP multicast 239.255.255.250:1982 и TCP 55443.'
}

$prefix = Get-LocalPrefix
$cfg = Get-Config

if ($Command -eq 'scan') {
  Write-Host "Сканирование сети (префикс: $prefix) ..."
  $disc = Discover-Yeelights -Prefix $prefix -ForceSweep $Sweep -TimeoutMs $TimeoutMs
  if ($disc.Count -eq 0) {
    Write-NoBulbsHint
    exit
  }
  $oldKeys = @{}
  foreach ($b in $cfg.bulbs) {
    $oldKeys[($b.Mac ? "mac:$($b.Mac)" : "ip:$($b.Ip)")] = $true
  }
  $cfg.bulbs = @(Merge-Discovered -Existing $cfg.bulbs -Discovered $disc)
  Save-Config $cfg
  $newOnes = @()
  foreach ($d in $disc) {
    $key = if ($d.Mac) { "mac:$($d.Mac)" } else { "ip:$($d.Ip)" }
    if (-not $oldKeys[$key]) {
      $saved = @($cfg.bulbs | Where-Object { $_.Ip -eq $d.Ip } | Select-Object -First 1)
      if ($saved) { $newOnes += $saved[0] }
    }
  }
  $cfg.bulbs | Select-Object Alias, Ip, Mac, Power, Bright, Model, Source | Format-Table -AutoSize
  Write-Host "Лампочек: $($cfg.bulbs.Count) (всего), найдено сейчас: $($disc.Count)."
  if ($newOnes.Count) {
    Write-Host 'Новые лампочки получили авто-алиасы. Присвойте имена:' -ForegroundColor Cyan
    foreach ($n in $newOnes) {
      Write-Host "  $($n.Ip) -> алиас '$($n.Alias)'   (\yeelight.ps1 alias -Target $($n.Alias) -Alias имя)"
    }
  }
  exit
}

if ($Command -eq 'list') {
  if ($cfg.bulbs.Count) {
    Write-Host 'Лампочки:'
    $cfg.bulbs | Select-Object Alias, Ip, Mac, Power, Bright, Name, Model | Format-Table -AutoSize
  } else {
    Write-Host 'В конфигурации нет лампочек. Выполните: .\yeelight.ps1 scan'
  }
  if ($cfg.groups.Count) {
    Write-Host 'Группы:'
    foreach ($g in $cfg.groups.GetEnumerator()) {
      Write-Host "  $($g.Key): $($g.Value -join ', ')"
    }
  } else {
    Write-Host 'Группы: (нет)'
  }
  exit
}

if ($Command -eq 'alias') {
  if (-not $Target -or -not $Alias) {
    throw "Использование: .\yeelight.ps1 alias -Target <IP|алиас> -Alias <новый алиас>"
  }
  if ($Alias -notmatch '^[\p{L}\p{N}_.\- ]+$') { throw "Недопустимый алиас: '$Alias'" }
  $found = @($cfg.bulbs | Where-Object { $_.Alias -eq $Target -or $_.Ip -eq $Target -or $_.Mac -ieq $Target } | Select-Object -First 1)
  if (-not $found) { throw "Не найдена лампочка: $Target. Сначала выполните scan." }
  $old = $found[0].Alias
  if ($old -eq $Alias) { Write-Host "'$Alias' уже установлен."; exit }
  if (-not (Free-Alias -Existing $cfg.bulbs -Alias $Alias)) { throw "Алиас '$Alias' уже используется другой лампочкой." }
  $found[0].Alias = $Alias
  foreach ($k in @($cfg.groups.Keys)) {
    $cfg.groups[$k] = @($cfg.groups[$k] | ForEach-Object { if ($_ -eq $old) { $Alias } else { $_ } })
  }
  Save-Config $cfg
  Write-Host "Алиас: '$old' -> '$Alias' ($($found[0].Ip))"
  exit
}

if ($Command -eq 'group') {
  switch ($GroupAction) {
    'add' {
      if (-not $Group) { throw "Укажите имя группы: -Group зал" }
      if ($cfg.groups.ContainsKey($Group)) { throw "Группа '$Group' уже существует. Используйте member-add." }
      $cfg.groups[$Group] = Resolve-MembersToAliases -Bulbs $cfg.bulbs -Members $Members
      Save-Config $cfg
      Write-Host "Группа '$Group' создана: $($cfg.groups[$Group] -join ', ')"
    }
    'remove' {
      if (-not $Group) { throw "Укажите имя группы: -Group зал" }
      if (-not $cfg.groups.Remove($Group)) { throw "Группа '$Group' не найдена." }
      Save-Config $cfg
      Write-Host "Группа '$Group' удалена."
    }
    'member-add' {
      if (-not $Group) { throw "Укажите имя группы и -Members." }
      if (-not $cfg.groups.ContainsKey($Group)) { throw "Группа '$Group' не найдена. Создайте через group add." }
      $add = Resolve-MembersToAliases -Bulbs $cfg.bulbs -Members $Members
      $cfg.groups[$Group] = @(($cfg.groups[$Group] + $add) | Select-Object -Unique)
      Save-Config $cfg
      Write-Host "Группа '$Group': $($cfg.groups[$Group] -join ', ')"
    }
    'member-remove' {
      if (-not $Group) { throw "Укажите имя группы и -Members." }
      if (-not $cfg.groups.ContainsKey($Group)) { throw "Группа '$Group' не найдена." }
      foreach ($m in @($Members)) {
        $cfg.groups[$Group] = @($cfg.groups[$Group] | Where-Object { $_ -ne $m })
      }
      Save-Config $cfg
      Write-Host "Группа '$Group': $($cfg.groups[$Group] -join ', ')"
    }
    'show' {
      if (-not $cfg.groups.Count) { Write-Host 'Групп нет. Создайте: group -GroupAction add -Group зал -Members кухня,спальня'; exit }
      foreach ($g in $cfg.groups.GetEnumerator()) {
        Write-Host "== $($g.Key) =="
        foreach ($a in @($g.Value)) {
          $b = @($cfg.bulbs | Where-Object { $_.Alias -eq $a } | Select-Object -First 1)
          if ($b) { Write-Host "   $($b[0].Alias)  $($b[0].Ip)  $($b[0].Power)  ярк. $($b[0].Bright)" }
          else { Write-Host "   $a  (не найдена)" }
        }
      }
      exit
    }
  }
  exit
}

if ($Command -in @('bright') -and -not $Brightness) {
  throw "Укажите яркость: .\yeelight.ps1 bright -Brightness 40"
}
if ($Command -eq 'bright' -and ($Brightness -lt 1 -or $Brightness -gt 100)) {
  throw 'Яркость должна быть 1-100.'
}

if ($cfg.bulbs.Count -eq 0 -or $Rescan) {
  Write-Verbose 'Конфигурация пуста или запрошен рескан — обнаружение сети...'
  $disc = Discover-Yeelights -Prefix $prefix -ForceSweep $Sweep -TimeoutMs $TimeoutMs
  if ($disc.Count -eq 0) {
    Write-Error 'Лампочки не найдены. Выполните: .\yeelight.ps1 scan'
    exit 1
  }
  $cfg.bulbs = @(Merge-Discovered -Existing $cfg.bulbs -Discovered $disc)
  Save-Config $cfg
}

$targets = Resolve-Targets -Bulbs $cfg.bulbs -Groups $cfg.groups -Target $Target
if ($targets.Count -eq 0) {
  $hint = @('Доступные алиасы:') + @($cfg.bulbs.Alias) +
    @('Группы:') + @($cfg.groups.Keys)
  Write-Error "Не найдено лампочек по цели '$Target'. $($hint -join ', ')"
  exit 1
}

switch ($Command) {
  'on'     { $method = 'set_power';  $params = @('on', 'smooth', 300) }
  'off'    { $method = 'set_power';  $params = @('off', 'smooth', 300) }
  'toggle' { $method = 'toggle';     $params = @() }
  'bright' { $method = 'set_bright'; $params = @($Brightness, 'smooth', 300) }
  'status' { $method = 'get_prop';   $params = @('power', 'bright', 'name') }
}

$myId = Get-Random -Minimum 100000 -Maximum 2147483640
$sendFnSource = (${function:Send-Yeelight}).ToString()
$results = @($targets | ForEach-Object -Parallel {
  $t = $_
  $send = [ScriptBlock]::Create($using:sendFnSource)
  $payload = @{ id = $using:myId; method = $using:Method; params = $using:Params }
  $resp = & $send -Address $t.Ip -Port $t.Port -Payload $payload
  if ($using:Command -eq 'status') {
    $r = if ($resp) { @($resp.result) } else { @() }
    [pscustomobject]@{
      Alias  = $t.Alias
      Ip     = $t.Ip
      Power  = if ($r.Count -ge 1) { [string]$r[0] } else { '?' }
      Bright = if ($r.Count -ge 2) { [string]$r[1] } else { '?' }
      Name   = if ($r.Count -ge 3 -and $r[2]) { [string]$r[2] } else { '' }
      Ok     = $true
      Message = ''
    }
  } elseif ($resp -and ($resp.PSObject.Properties.Name -contains 'error')) {
    [pscustomobject]@{
      Alias = $t.Alias; Ip = $t.Ip
      Message = "ошибка $($resp.error.code): $($resp.error.message)"
      Ok = $false
    }
  } elseif ($resp) {
    [pscustomobject]@{
      Alias = $t.Alias; Ip = $t.Ip
      Message = ([string]::Join(',', @($resp.result)))
      Ok = $true
    }
  } else {
    [pscustomobject]@{
      Alias = $t.Alias; Ip = $t.Ip
      Message = 'нет ответа'
      Ok = $false
    }
  }
} -ThrottleLimit 16) | Sort-Object Ip

$report = @()
foreach ($res in $results) {
  $b = @($cfg.bulbs | Where-Object { $_.Ip -eq $res.Ip } | Select-Object -First 1)
  if ($Command -eq 'status') {
    $report += [pscustomobject]@{
      Alias  = $res.Alias
      Ip     = $res.Ip
      Power  = $res.Power
      Bright = $res.Bright
      Name   = $res.Name
      Model  = if ($b) { $b[0].Model } else { '' }
    }
    if ($b) {
      if ($res.Power -ne '?') { $b[0].Power = $res.Power }
      if ($res.Bright -ne '?') { $b[0].Bright = $res.Bright }
      if ($res.Name) { $b[0].Name = $res.Name }
    }
  } elseif (-not $res.Ok) {
    Write-Warning "$($res.Alias) ($($res.Ip)): $($res.Message)"
  } else {
    Write-Host "[$($res.Alias)] $($res.Ip): $method = $($res.Message)"
    if ($b) {
      if ($Command -eq 'on')         { $b[0].Power = 'on' }
      elseif ($Command -eq 'off')    { $b[0].Power = 'off' }
      elseif ($Command -eq 'bright') { $b[0].Bright = [string]$Brightness }
    }
  }
}

if ($report.Count) { $report | Format-Table -AutoSize }
if ($Command -ne 'status') { Save-Config $cfg }
