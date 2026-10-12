<#  Rosa Thermal Guard - Rosa Guard suite membership (IPC), contract 1.1 (Rosa Guard SDK 1.1.2).
    Runs in its OWN runspace inside the tray process (started by TrayApp.ps1), never on the guard engine's thread.
    It only talks to the engine through the shared $Sync table, and every value it hands over has an expiry time,
    so a hung or crashed worker can never hold cooling on (or off): leases simply run out.
    If the shared SDK component is missing or broken, this script logs one line and ends: Thermal Guard then runs
    exactly as the standalone 1.2 release does.
    No tab, no window: Thermal has its own window only (the shared tabbed window is not used).
      in : $Sync.Pressure (engine), $Sync.GameMode/GameName
      out: $Sync.LeaseLevel/LeaseUntil/LeaseFrom, $Sync.SuiteGamingUntil/SuiteGamingSrc, $Sync.WifiWant/WifiWantAt (effective power-lease value + heartbeat; the engine applies it),
           $Sync.SuiteUp/SuiteState #>
param($Sync, [string]$AppDir, [string]$Root)
$ErrorActionPreference = 'Continue'
function SLog([string]$m) {
  $line = "{0} [SUITE] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m; $b = [Text.Encoding]::UTF8.GetBytes($line + "`r`n")
  for ($i = 0; $i -lt 6; $i++) { try { $fs = New-Object IO.FileStream((Join-Path $Root 'guard.log'), [IO.FileMode]::Append, [Security.AccessControl.FileSystemRights]::AppendData, [IO.FileShare]'ReadWrite, Delete', 4096, [IO.FileOptions]::None); try { $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }; break } catch { Start-Sleep -Milliseconds 30 } }
}
$Sync.SuiteState = 'starting'; $Sync.SuiteUp = $false
$cfg = $null; try { $cfg = Get-Content (Join-Path $AppDir 'config.json') -Raw -ErrorAction Stop | ConvertFrom-Json } catch {}
$cs = if ($cfg -and $cfg.PSObject.Properties['suite']) { $cfg.suite } else { $null }
function CV($o, [string]$n, $d) { if ($o -and $o.PSObject.Properties[$n] -and $null -ne $o.$n) { $o.$n } else { $d } }
if (-not [bool](CV $cs 'enabled' $true)) { $Sync.SuiteState = 'off'; SLog 'suite integration switched off in config (suite.enabled = false) - standalone'; return }
$allowCool = [bool](CV $cs 'allowPeerCooldown' $true); $allowPower = [bool](CV $cs 'allowPowerSetting' $true)

# production only: never pick up the SDK test-isolation variables
foreach ($k in 'ROSAGUARD_TEST_PIPEPREFIX', 'ROSAGUARD_TEST_REGROOT', 'ROSAGUARD_TEST_SHAREDROOT', 'ROSAGUARD_TEST_SETTINGS', 'ROSAGUARD_TEST_STATE', 'ROSAGUARD_TEST_MUTEX', 'ROSAGUARD_TEST_NOSHOW') { [Environment]::SetEnvironmentVariable($k, $null, 'Process') }

# resolve the shared SDK component (installed under its component name "TabHost"; only the IPC part is used): newest complete 1.x >= 1.1.2 under %CommonProgramFiles%\RosaGuard\TabHost (contract 11)
$need = [version]'1.1.2'; $sdk = $null
try {
  $base = Join-Path $(if ($env:CommonProgramW6432) { $env:CommonProgramW6432 } else { $env:CommonProgramFiles }) 'RosaGuard\TabHost'
  $sdk = Get-ChildItem $base -Directory -ErrorAction Stop | Where-Object { $v = $null; [version]::TryParse($_.Name, [ref]$v) -and $v.Major -eq 1 -and $v -ge $need -and (Test-Path (Join-Path $_.FullName 'rosaguard-component.json')) -and (Test-Path (Join-Path $_.FullName 'RosaGuard.psd1')) } |
         Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1 -ExpandProperty FullName
} catch {}
if (-not $sdk) { $Sync.SuiteState = 'no-sdk'; SLog 'Rosa Guard shared component (TabHost/SDK 1.1.2+) not found - standalone'; return }

$ver = '0.0.0'; try { $ver = (Get-Content (Join-Path $AppDir 'version.txt') -Raw).Trim() } catch {}
$m = $null
try {
  Import-Module (Join-Path $sdk 'RosaGuard.psd1') -Force -ErrorAction Stop
  # -NoWindow: if elected hub, Thermal brokers suite.roles / suite.gaming headless (SDK 1.1.2, A10.5). No tab is registered.
  $args2 = @{ AppId = 'thermal'; AppVersion = $ver; Capabilities = @('gaming.detect'); Peers = @{ net = @('net.session') }; NoWindow = $true }
  $m = Start-RosaGuardSuiteMember @args2
  if (-not $m.Listening) { SLog 'own pipe could not be created (name in use?) - peers cannot reach Thermal; the rest of the suite link still runs' }
  if ($m.Listening) {
    [void](Enable-RosaGuardCooldownLeases -Server $m.Server -MaxLeases 8 -MaxDurationSec 600)
    $m.Server.Cooldown.Accepting = $allowCool
    $Sync.Leases = [hashtable]::Synchronized(@{})
    [void](Enable-RosaGuardPowerLeases -Server $m.Server -MaxLeases 8 -MaxDurationSec 3600)   # thermal.request_power_setting / cancel / thermal.leases
    $m.Server.Power.Accepting = $allowPower
    Register-RosaGuardLeaseHandler -Server $m.Server -Handler {
      param($l)
      if ($l.type -eq 'power') {   # the engine applies the effective value (heartbeat below); here only the log
        SLog "power lease $($l.action): $($l.peerAppId) $($l.setting)=$($l.value) ($($l.reason))$(if ($l.why) { ", $($l.why)" }) -> effective $($l.effectiveValue)"
        $Sync.WifiWant = [string]$l.effectiveValue; $Sync.WifiFrom = "$($l.peerAppId): $($l.reason)"; $Sync.WifiWantAt = Get-Date
        return
      }
      if ($l.action -eq 'granted') {
        $exp = [datetime]::MinValue; try { $exp = ([datetime]::Parse([string]$l.expiresUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)).ToLocalTime() } catch { $exp = (Get-Date).AddSeconds(60) }
        $Sync.Leases[[string]$l.peerAppId] = @{ Level = [string]$l.level; Until = $exp; Reason = [string]$l.reason }
        SLog "cooldown lease granted to $($l.peerAppId): $($l.level), $($l.reason), until $($exp.ToString('HH:mm:ss'))"
      } else {
        $Sync.Leases.Remove([string]$l.peerAppId); SLog "cooldown lease of $($l.peerAppId) $($l.action)$(if ($l.why) { " ($($l.why))" })"
      }
    }
  }
  $Sync.SuiteState = 'suite'
  SLog ("suite member started (SDK {0}, pipe {1}, headless hub candidate, no tab)" -f (Split-Path $sdk -Leaf), $(if ($m.Listening) { 'listening' } else { 'NOT listening' }))
} catch {
  $Sync.SuiteState = 'error'; SLog "suite start failed - standalone: $($_.Exception.Message)"
  if ($m) { try { Stop-RosaGuardSuiteMember -Member $m } catch {} }
  return
}

$lastPub = [datetime]::MinValue; $lastGame = [datetime]::MinValue; $lastStatus = [datetime]::MinValue
$wasUp = $null
try {
  while (-not $Sync.Stop -and -not $Sync.SuiteStop) {
    $now = Get-Date
    try { [void]@(Invoke-RosaGuardSuiteTick -Member $m) } catch {}   # pumps requests/leases (handlers above) and drains events
    try {
      # leases -> engine (expiry-stamped: if this worker dies the engine drops them on its own)
      $lv = $null; $until = [datetime]::MinValue; $from = @()
      foreach ($k in @($Sync.Leases.Keys)) { $x = $Sync.Leases[$k]; if ($x.Until -le $now) { $Sync.Leases.Remove($k); continue }; $from += $k; if ($x.Level -eq 'strong' -or -not $lv) { $lv = $x.Level }; if ($x.Until -gt $until) { $until = $x.Until } }
      if ($m.Listening -and $m.Server.Power) { try { $m.Server.Power.Expire() } catch {}; $Sync.WifiWant = $m.Server.Power.EffectiveValue('wireless_adapter_power_saving'); $Sync.WifiWantAt = $now }
      $Sync.LeaseFrom = ($from -join ','); $Sync.LeaseLevel = $lv; $Sync.LeaseUntil = $(if ($lv) { $until } else { [datetime]::MinValue })
      # gaming from the suite: suite.gaming (unless we published it) or net.session.gaming
      $g = $null; $src = ''
      $sg = Get-RosaGuardTopic -Link $m.Link -Topic 'suite.gaming'
      if ($sg -and $sg.active -and [string]$sg.detector -ne 'thermal') { $g = $true; $src = "suite.gaming from $($sg.detector)" }
      $ns = Get-RosaGuardTopic -Link $m.Link -Topic 'net.session'
      if ($ns -and $ns.gaming) { $g = $true; $src = "net.session$(if ($ns.app) { " ($($ns.app))" })" }
      if ($g) { $Sync.SuiteGamingUntil = $now.AddSeconds(6); $Sync.SuiteGamingSrc = $src }
      $up = $m.Link.IsUp('suite'); $Sync.SuiteUp = $up
      if ($up -ne $wasUp) { SLog ("hub link " + $(if ($up) { 'up' } else { 'down' })); $wasUp = $up }
    } catch {}
    # thermal.pressure every 2 s (contract: at most 5 s; ttl 15 s); only from a fresh engine reading
    if (($now - $lastPub).TotalSeconds -ge 2 -and $m.Listening) {
      $lastPub = $now
      try {
        $pr = $Sync.Pressure
        if ($pr -and $pr.at -is [datetime] -and ($now - $pr.at).TotalSeconds -le 10) {
          $nl = @($Sync.Leases.Keys).Count
          $d = @{ level = [int]$pr.level; cpuC = $pr.cpuC; gpuC = $pr.gpuC; cpuTrendCPerSec = [double]$pr.trend; fanMode = [string]$pr.fanMode; gaming = [bool]$pr.gaming; cooldown = @{ active = ($nl -gt 0); leases = $nl } }
          if ($pr.reason) { $d.reason = [string]$pr.reason }
          [void](Publish-RosaGuardTopic -Server $m.Server -Topic 'thermal.pressure' -Data $d -TtlMs 15000)
          if ([int]$pr.level -ge 3 -and $m.Server.Power) { $nr = $m.Server.Power.RevokeHeatAdding('critical'); if ($nr -gt 0) { SLog "critical temperature - revoked $nr heat-adding power lease(s)" } }
        }
      } catch { SLog "publish failed: $($_.Exception.Message)" }
    }
    # elected gaming detector: publish suite.gaming from our own detection every 5 s
    if (($now - $lastGame).TotalSeconds -ge 5) {
      $lastGame = $now
      try {
        $roles = Get-RosaGuardTopic -Link $m.Link -Topic 'suite.roles' -NoDefault
        if ($roles -and [string]$roles.gamingDetector -eq 'thermal') {
          $gd = @{ active = [bool]$Sync.GameMode; detector = 'thermal' }
          $gn = [string]$Sync.GameName; if ($Sync.GameMode -and $gn -match '^[A-Za-z0-9 ._()-]{1,64}$') { $gd.app = $gn }
          [void](Publish-RosaGuardSuiteTopic -Link $m.Link -Topic 'suite.gaming' -Data $gd -TtlMs 15000)
        }
      } catch {}
    }
    if (($now - $lastStatus).TotalSeconds -ge 5 -and $m.Listening) {
      $lastStatus = $now
      try {
        $nl = @($Sync.Leases.Keys).Count
        Set-RosaGuardStatus -Server $m.Server -Health $(if ($Sync.Updated -is [datetime] -and ($now - $Sync.Updated).TotalSeconds -lt 15) { 'ok' } else { 'degraded' }) -Mode $(if ($Sync.SuiteUp) { 'suite' } else { 'standalone' }) `
          -OwnedSettings @('power_plan', 'cpu_power_limit', 'gpu_clock', 'fan', 'process_priority') -ActiveLeases $nl -Details @{ pressure = $(if ($Sync.Pressure) { [int]$Sync.Pressure.level } else { 0 }); gameMode = [bool]$Sync.GameMode; peerCooldown = $allowCool; wifiLeases = $(if ($Sync.Pressure) { [int]$Sync.Pressure.wifi } else { 0 }) }
      } catch {}
    }
    Start-Sleep -Milliseconds 250
  }
} catch { SLog "suite worker error: $($_.Exception.Message)" }
finally {
  $Sync.LeaseLevel = $null; $Sync.LeaseUntil = [datetime]::MinValue; $Sync.SuiteUp = $false; $Sync.SuiteState = 'stopped'
  try { Stop-RosaGuardSuiteMember -Member $m } catch {}
  SLog 'suite member stopped'
}
