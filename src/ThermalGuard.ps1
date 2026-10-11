<#
  Rosa Thermal Guard - guard engine (MIT License)
  Keeps CPU and GPU below 100 C by throttling when hot and restoring when cool.
  Sensors: LibreHardwareMonitorLib (MPL-2.0) - needs admin rights and the PawnIO driver for CPU temps.
  CPU: steps "Maximum processor state" (all core classes, AC+DC) down at the throttle threshold,
       lowers priority of the top CPU users at the critical threshold, restores when cool.
  GPU (NVIDIA): nvidia-smi -pl (power limit) when the driver allows it, otherwise
       nvidia-smi -lgc (graphics clock cap), otherwise process priority.
  All thresholds come from config.json next to this script.
  Switches: -TestMode (simulated temps, real actions, then restore)
            -Restore  (put saved original settings back and exit)
            -Once     (print current temps and exit)
#>
param(
  [switch]$TestMode,
  [switch]$Restore,
  [switch]$Once,
  [hashtable]$Sync = $null,   # set by TrayApp.ps1 (status out, Pause/Stop in)
  [int]$PollSeconds = 2
)
$ErrorActionPreference = 'Continue'
$AppDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir   = Join-Path $env:ProgramData 'RosaThermalGuard'
$Root      = $DataDir
$LogFile   = Join-Path $DataDir 'guard.log'
$StateFile = Join-Path $DataDir 'state.json'
$StopFile  = Join-Path $DataDir 'stop.flag'   # create this file to stop the guard cleanly
$LhmDll    = Join-Path $AppDir 'lib\LibreHardwareMonitorLib.dll'

# ---- configuration (config.json next to the script; defaults below) ----
$Cfg = $null
try { $Cfg = Get-Content (Join-Path $AppDir 'config.json') -Raw -ErrorAction Stop | ConvertFrom-Json } catch {}
function CfgVal($obj, [string]$name, $default) {
  if ($obj -ne $null -and ($obj.PSObject.Properties.Name -contains $name) -and $obj.$name -ne $null) { return $obj.$name }
  return $default
}
$cCpu = CfgVal $Cfg 'cpu' $null; $cGpu = CfgVal $Cfg 'gpu' $null
$CPU_HOT  = [double](CfgVal $cCpu 'throttleC' 90)
$CPU_CRIT = [double](CfgVal $cCpu 'criticalC' 95)
$CPU_COOL = [double](CfgVal $cCpu 'restoreC' 80)
$COOL_SECONDS = [int](CfgVal $cCpu 'restoreAfterSeconds' 20)
$CPU_STEPS = @(CfgVal $cCpu 'maxStateSteps' @(100, 99, 85, 70, 55) | ForEach-Object { [int]$_ })   # 99% = turbo off
if ($CPU_STEPS[0] -ne 100) { $CPU_STEPS = @(100) + $CPU_STEPS }
$STEP_MIN_SECONDS = [int](CfgVal $cCpu 'minSecondsBetweenSteps' 6)
$HOLD_MAX = [int](CfgVal $cCpu 'maxTurboHoldSeconds' 600)   # longest wait before going back to full turbo
$GPU_HOT  = [double](CfgVal $cGpu 'throttleC' 88)
$GPU_COOL = [double](CfgVal $cGpu 'restoreC' 78)
$GPU_CLOCK_STEPS = @(CfgVal $cGpu 'clockStepsPercent' @(75, 55, 40) | ForEach-Object { [int]$_ })
$PAUSE_CANCEL = [double](CfgVal $Cfg 'pauseCancelC' 97)
$TOP_N = [int](CfgVal $Cfg 'lowerPriorityTopN' 3)
$NOTIFY = [bool](CfgVal $Cfg 'notifications' $true)
$ALLOW_SIM = [bool](CfgVal $Cfg 'allowSimulateFile' $false)
$MaxLogBytes = [int](CfgVal $Cfg 'maxLogKB' 1024) * 1KB
if ($PollSeconds -eq 2) { $PollSeconds = [int](CfgVal $Cfg 'pollSeconds' 2) }

# ---- logging ----
function Write-Log([string]$msg) {
  try {
    if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt $MaxLogBytes)) {
      Move-Item $LogFile "$LogFile.1" -Force
    }
    $line = '{0} {1}{2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), ($(if ($TestMode) { '[TEST] ' } else { '' })), $msg
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    if ($TestMode -or $Once) { Write-Host $line }
  } catch {}
}

$NoticeEn = @{ nCpuHot = 'CPU at {0} C - slowing down to cool off'; nGpuHot = 'GPU at {0} C - slowing down to cool off'; nCool = 'Cool again - full speed restored' }
function Show-Notice([string]$key, $val) {
  if (-not $NOTIFY) { return }
  if ($Sync) { $Sync.Notify = @($key, $val); return }   # tray app shows it in the UI language
  try {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $b = [Security.SecurityElement]::Escape(($NoticeEn[$key] -f $val))
    $xml.LoadXml("<toast><visual><binding template='ToastGeneric'><text>Rosa Thermal Guard</text><text>$b</text></binding></visual></toast>")
    $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show((New-Object Windows.UI.Notifications.ToastNotification $xml))
  } catch { Write-Log "toast failed: $($_.Exception.Message)" }
}

# ---- powercfg helpers ----
function Get-SchemeGuid {
  $o = powercfg /getactivescheme 2>$null | Out-String
  if ($o -match '([0-9a-fA-F-]{36})') { return $Matches[1] } ; return $null
}
function Get-ProcMax([string]$scheme, [string]$alias) {
  $o = powercfg /qh $scheme SUB_PROCESSOR $alias 2>$null | Out-String
  $m = [regex]::Matches($o, ':\s*0x([0-9a-fA-F]{8})')
  if ($m.Count -ge 2) {
    return @{ AC = [Convert]::ToInt32($m[$m.Count-2].Groups[1].Value,16); DC = [Convert]::ToInt32($m[$m.Count-1].Groups[1].Value,16) }
  }
  return $null
}
function Set-ProcMax([string]$scheme, [string]$alias, [int]$ac, [int]$dc) {
  powercfg /setacvalueindex $scheme SUB_PROCESSOR $alias $ac 2>$null | Out-Null
  powercfg /setdcvalueindex $scheme SUB_PROCESSOR $alias $dc 2>$null | Out-Null
}

# ---- state (crash-safe originals) ----
$State = $null   # @{ Scheme; Orig = @{ alias = @{AC;DC} }; GpuDefaultW }
function Save-State { try { $State | ConvertTo-Json -Depth 5 | Set-Content $StateFile -Encoding UTF8 } catch {} }
function Load-State {
  if (Test-Path $StateFile) {
    try {
      $j = Get-Content $StateFile -Raw | ConvertFrom-Json
      $orig = @{}
      foreach ($p in $j.Orig.PSObject.Properties) { $orig[$p.Name] = @{ AC = [int]$p.Value.AC; DC = [int]$p.Value.DC } }
      return @{ Scheme = $j.Scheme; Orig = $orig; GpuDefaultW = $j.GpuDefaultW; GpuLgc = [bool]$j.GpuLgc }
    } catch {}
  }
  return $null
}

$script:CpuLevel = 0
$script:GpuThrottled = $false
$script:Reniced = @{}   # pid -> original priority class

function Ensure-Originals {
  if ($State) { return }
  $scheme = Get-SchemeGuid
  $orig = @{}
  foreach ($a in 'PROCTHROTTLEMAX','PROCTHROTTLEMAX1') { $v = Get-ProcMax $scheme $a; if ($v) { $orig[$a] = $v } }
  $script:State = @{ Scheme = $scheme; Orig = $orig; GpuDefaultW = $null; GpuLgc = $false }
  Save-State
}

function Apply-CpuLevel([int]$level) {
  Ensure-Originals
  $pct = $CPU_STEPS[$level]
  foreach ($a in $State.Orig.Keys) {
    $o = $State.Orig[$a]
    if ($level -eq 0) { Set-ProcMax $State.Scheme $a $o.AC $o.DC }
    else { Set-ProcMax $State.Scheme $a ([Math]::Min($pct,$o.AC)) ([Math]::Min($pct,$o.DC)) }
  }
  powercfg /setactive $State.Scheme 2>$null | Out-Null
  $script:CpuLevel = $level
  $now = Get-ProcMax $State.Scheme 'PROCTHROTTLEMAX'
  Write-Log ("CPU max processor state -> level {0} ({1}%), powercfg now AC={2} DC={3}" -f $level, $(if ($level -eq 0) { 'original' } else { $pct }), $now.AC, $now.DC)
}

# ---- process priority ----
$defaultProtected = @('System','Idle','Registry','smss','csrss','wininit','winlogon','services','lsass','svchost','dwm','explorer',
  'Memory Compression','MsMpEng','NisSrv','audiodg','fontdrvhost','spoolsv','SecurityHealthService','ctfmon','sihost',
  'taskhostw','RuntimeBroker','StartMenuExperienceHost','ShellExperienceHost','SearchHost','TextInputHost','conhost',
  'LogonUI','WUDFHost','dllhost','powershell','pwsh','wscript','nvidia-smi')
$Protected = @(CfgVal $Cfg 'protectedProcesses' $defaultProtected | ForEach-Object { [string]$_ -replace '\.exe$', '' })
function Lower-Priority($procs, [string]$why) {
  foreach ($p in $procs) {
    try {
      if ($script:Reniced.ContainsKey($p.Id)) { continue }
      $orig = $p.PriorityClass
      if ($orig -eq 'Idle' -or $orig -eq 'BelowNormal') { continue }
      $p.PriorityClass = 'BelowNormal'
      $script:Reniced[$p.Id] = @{ Name = $p.ProcessName; Orig = [string]$orig; Start = $p.StartTime }
      Write-Log "priority $($p.ProcessName) (pid $($p.Id)) $orig -> BelowNormal [$why]"
    } catch { Write-Log "priority change failed for $($p.ProcessName): $($_.Exception.Message)" }
  }
}
function Restore-Priorities {
  foreach ($procId in @($script:Reniced.Keys)) {
    $info = $script:Reniced[$procId]
    try {
      $p = Get-Process -Id $procId -ErrorAction Stop
      if ($p.StartTime -eq $info.Start) { $p.PriorityClass = $info.Orig; Write-Log "priority $($info.Name) (pid $procId) restored to $($info.Orig)" }
    } catch {}
    $script:Reniced.Remove($procId)
  }
}
function Get-TopCpuProcesses([int]$n = 3) {
  $mySession = (Get-Process -Id $PID).SessionId
  $a = @{}; Get-Process | ForEach-Object { try { $a[$_.Id] = $_.TotalProcessorTime.TotalMilliseconds } catch {} }
  Start-Sleep -Milliseconds 1000
  $list = foreach ($p in Get-Process) {
    try {
      if ($p.Id -eq $PID -or $p.SessionId -eq 0 -or $Protected -contains $p.ProcessName) { continue }
      if (-not $a.ContainsKey($p.Id)) { continue }
      $d = $p.TotalProcessorTime.TotalMilliseconds - $a[$p.Id]
      if ($d -gt 200) { [pscustomobject]@{ P = $p; D = $d } }
    } catch {}
  }
  return @($list | Sort-Object D -Descending | Select-Object -First $n | ForEach-Object { $_.P })
}
function Get-TopGpuProcesses([int]$n = 3) {
  try {
    $s = (Get-Counter '\GPU Engine(*engtype_3D)\Utilization Percentage' -ErrorAction Stop).CounterSamples
    $byPid = @{}
    foreach ($c in $s) { if ($c.InstanceName -match 'pid_(\d+)_') { $k = [int]$Matches[1]; $byPid[$k] = [double]$byPid[$k] + $c.CookedValue } }
    $out = foreach ($k in ($byPid.Keys | Sort-Object { $byPid[$_] } -Descending)) {
      if ($byPid[$k] -lt 10) { continue }
      try { $p = Get-Process -Id $k -ErrorAction Stop; if ($p.SessionId -ne 0 -and $Protected -notcontains $p.ProcessName -and $p.Id -ne $PID) { $p } } catch {}
    }
    return @($out | Select-Object -First $n)
  } catch { Write-Log "GPU usage counters unavailable: $($_.Exception.Message)"; return @() }
}

# ---- NVIDIA ----
function Invoke-NvSmi([string]$args_, [int]$timeoutMs = 8000) {
  $exe = Join-Path $env:WINDIR 'System32\nvidia-smi.exe'
  if (-not (Test-Path $exe)) { return $null }
  try {
    $psi = New-Object Diagnostics.ProcessStartInfo $exe, $args_
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $pr = [Diagnostics.Process]::Start($psi)
    $outTask = $pr.StandardOutput.ReadToEndAsync()
    if (-not $pr.WaitForExit($timeoutMs)) { try { $pr.Kill() } catch {}; return $null }
    return @{ Code = $pr.ExitCode; Out = $outTask.Result }
  } catch { return $null }
}
$script:Nv = $null   # @{ Mode = pl|lgc|priority; Default; Min; Cur; MaxClock; Step; LgcMhz }
function ToNum([string]$v) { $d = 0.0; if ([double]::TryParse($v.Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }; return $null }
function Init-Nvidia {
  $r = Invoke-NvSmi '--query-gpu=power.default_limit,power.min_limit,power.limit,clocks.max.graphics --format=csv,noheader,nounits'
  if (-not $r -or $r.Code -ne 0) { Write-Log 'nvidia-smi: no answer (NVIDIA GPU not active)'; return }
  $f = ($r.Out -split "`n")[0] -split ','
  $nv = @{ Default = (ToNum $f[0]); Min = (ToNum $f[1]); Cur = (ToNum $f[2]); MaxClock = (ToNum $f[3]); Step = 0; LgcMhz = $null; Mode = 'priority' }
  Write-Log ("NVIDIA: power default={0} min={1} current={2}, max graphics clock={3} MHz" -f $f[0].Trim(), $f[1].Trim(), $f[2].Trim(), $f[3].Trim())
  if ($nv.Default -and $nv.Min -and $nv.Cur) { $nv.Mode = 'pl' }
  elseif ($nv.MaxClock) {
    # probe: lock to the full max clock (no real change) and reset at once
    $p = Invoke-NvSmi ("-lgc 0,{0}" -f [int]$nv.MaxClock)
    if ($p -and $p.Code -eq 0) { [void](Invoke-NvSmi '-rgc'); $nv.Mode = 'lgc'; Write-Log 'NVIDIA power limit is locked by the driver - using clock cap (nvidia-smi -lgc)' }
    else { Write-Log ("NVIDIA -lgc not accepted ({0}) - using process priority" -f $(if ($p) { $p.Out.Trim() } else { 'timeout' })) }
  } else { Write-Log 'NVIDIA power/clock control not available - using process priority' }
  $script:Nv = $nv
}
function Step-GpuDown {
  if ($Nv -and $Nv.Mode -eq 'pl') {
    $target = [Math]::Max($Nv.Min, [Math]::Round($Nv.Cur - ($Nv.Default - $Nv.Min) / 3))
    if ($target -lt $Nv.Cur) {
      $r = Invoke-NvSmi ("-pl {0}" -f $target)
      if ($r -and $r.Code -eq 0) {
        if (-not $State.GpuDefaultW) { $State.GpuDefaultW = $Nv.Default; Save-State }
        $script:Nv.Cur = $target; $script:GpuThrottled = $true; Write-Log "GPU power limit -> ${target}W"; return
      }
      Write-Log "nvidia-smi -pl refused: $(if ($r) { $r.Out.Trim() } else { 'timeout' })"
      $script:Nv.Mode = $(if ($Nv.MaxClock) { 'lgc' } else { 'priority' })
    }
  }
  if ($Nv -and $Nv.Mode -eq 'lgc' -and $Nv.Step -lt $GPU_CLOCK_STEPS.Count) {
    $mhz = [int][Math]::Round($Nv.MaxClock * $GPU_CLOCK_STEPS[$Nv.Step] / 100)
    $r = Invoke-NvSmi ("-lgc 0,{0}" -f $mhz)
    if ($r -and $r.Code -eq 0) {
      $State.GpuLgc = $true; Save-State
      $script:Nv.Step++; $script:Nv.LgcMhz = $mhz; $script:GpuThrottled = $true
      Write-Log "GPU graphics clock capped at ${mhz} MHz ($($GPU_CLOCK_STEPS[$Nv.Step - 1])%)"; return
    }
    Write-Log "nvidia-smi -lgc refused: $(if ($r) { $r.Out.Trim() } else { 'timeout' }) - using process priority"
    $script:Nv.Mode = 'priority'
  }
  $script:GpuThrottled = $true
  Lower-Priority (Get-TopGpuProcesses $TOP_N) 'GPU hot'
}
function Restore-Gpu {
  if ($Nv -and $Nv.Mode -eq 'pl' -and $Nv.Cur -lt $Nv.Default) {
    $r = Invoke-NvSmi ("-pl {0}" -f $Nv.Default)
    if ($r -and $r.Code -eq 0) { $script:Nv.Cur = $Nv.Default; Write-Log "GPU power limit restored to $($Nv.Default)W" }
  } elseif ($State -and $State.GpuDefaultW) {
    $r = Invoke-NvSmi ("-pl {0}" -f $State.GpuDefaultW)
    if ($r -and $r.Code -eq 0) { Write-Log "GPU power limit restored to $($State.GpuDefaultW)W" }
  }
  if (($Nv -and $Nv.LgcMhz) -or ($State -and $State.GpuLgc)) {
    $r = Invoke-NvSmi '-rgc'
    if ($r -and $r.Code -eq 0) { Write-Log 'GPU graphics clock lock reset (-rgc)' }
    if ($Nv) { $script:Nv.LgcMhz = $null; $script:Nv.Step = 0 }
  }
  $script:GpuThrottled = $false
}

function Restore-All([string]$why) {
  Write-Log "restore all ($why)"
  if ($State) {
    foreach ($a in $State.Orig.Keys) { $o = $State.Orig[$a]; Set-ProcMax $State.Scheme $a $o.AC $o.DC }
    powercfg /setactive $State.Scheme 2>$null | Out-Null
    $now = Get-ProcMax $State.Scheme 'PROCTHROTTLEMAX'
    Write-Log "CPU max processor state restored: AC=$($now.AC) DC=$($now.DC)"
  }
  Restore-Gpu
  Restore-Priorities
  $script:CpuLevel = 0
  Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
  $script:State = $null
}

# ---- sensors ----
$script:Computer = $null
$script:HasNvidia = $false
function Open-Sensors {
  Add-Type -Path $LhmDll -ErrorAction Stop
  $c = New-Object LibreHardwareMonitor.Hardware.Computer
  $c.IsCpuEnabled = $true; $c.IsGpuEnabled = $true
  $c.Open()
  $script:Computer = $c
  $script:HasNvidia = [bool]($c.Hardware | Where-Object { $_.HardwareType -eq 'GpuNvidia' })
  Write-Log ("sensors: " + (($c.Hardware | ForEach-Object { "$($_.HardwareType)=$($_.Name)" }) -join '; '))
}
function Read-Temps {
  $cpu = $null; $gpu = $null
  foreach ($h in $Computer.Hardware) {
    $h.Update()
    $sens = @($h.Sensors) + @($h.SubHardware | ForEach-Object { $_.Update(); $_.Sensors })
    foreach ($s in $sens) {
      if ($s.SensorType -ne 'Temperature' -or $s.Value -eq $null -or $s.Name -like '*Distance*') { continue }
      $v = [double]$s.Value
      if ($h.HardwareType -eq 'Cpu' -and ($s.Name -eq 'CPU Package' -or $s.Name -eq 'Core Max')) { if ($cpu -eq $null -or $v -gt $cpu) { $cpu = $v } }
      elseif ($h.HardwareType -eq 'GpuNvidia' -or $h.HardwareType -eq 'GpuAmd') {
        if ($s.Name -eq 'GPU Core' -or $s.Name -eq 'GPU Hot Spot') { if ($gpu -eq $null -or $v -gt $gpu) { $gpu = $v } }
      }
    }
  }
  return @{ Cpu = $cpu; Gpu = $gpu }
}

# ================= main =================
if (-not (Test-Path $Root)) { New-Item -ItemType Directory $Root -Force | Out-Null }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$mutex = $null
if (-not $Restore) {
  $mutex = New-Object Threading.Mutex($false, 'Global\RosaThermalGuard')
  if (-not $mutex.WaitOne(0)) { Write-Log 'another instance is already running - exit'; exit 0 }
}
# leftovers from a crash/kill: put originals back first
$prev = Load-State
if ($prev) { $State = $prev; Restore-All 'previous run did not exit cleanly' }
if ($Restore) { exit 0 }

try { Open-Sensors } catch { Write-Log "cannot load LibreHardwareMonitor: $($_.Exception.Message)"; exit 2 }
if (-not $isAdmin) { Write-Log 'WARNING: not running as admin - CPU temperatures need admin' }
if ($HasNvidia) { Init-Nvidia } else { Write-Log 'no active NVIDIA/AMD GPU found by sensors (integrated GPU heat is covered by the CPU package sensor)' }

if ($Once) { $t = Read-Temps; Write-Log ("CPU={0} GPU={1}" -f $t.Cpu, $t.Gpu); exit 0 }

# test script: list of (cpu, gpu) simulated readings, one per poll
$sim = $null
if ($TestMode) {
  $sim = New-Object Collections.Queue
  foreach ($i in 1..4) { $sim.Enqueue(@(92, 90)) }     # hot -> step to 85%
  foreach ($i in 1..2) { $sim.Enqueue(@(96, 90)) }     # critical -> next step + priority
  foreach ($i in 1..24) { $sim.Enqueue(@(70, 70)) }    # cool -> restore step by step
  Write-Log 'test mode: simulated CPU 92 -> 96 -> 70, GPU 90 -> 70'
}

$coolSince = $null; $gpuCoolSince = $null; $lastStep = [datetime]::MinValue; $lastGpuStep = [datetime]::MinValue; $lastStepTemp = 0
$restoreHold = $COOL_SECONDS; $lastFullRestore = $null; $wasPaused = $false
$lastInfo = [datetime]::MinValue; $nullSince = $null; $lastRescan = Get-Date
Write-Log "RosaThermalGuard started (admin=$isAdmin, poll=${PollSeconds}s, CPU hot=$CPU_HOT crit=$CPU_CRIT cool=$CPU_COOL, GPU hot=$GPU_HOT cool=$GPU_COOL)"
$exitCode = 0
try {
  while ($true) {
    $t = Read-Temps
    $real = "real CPU=$($t.Cpu) GPU=$($t.Gpu)"
    $simActive = $false
    $simFile = Join-Path $Root 'simulate.txt'   # dev dry-run: 'cpu,gpu', ignored after 5 min
    if ($ALLOW_SIM -and -not $TestMode -and (Test-Path $simFile)) {
      if (((Get-Date) - (Get-Item $simFile).LastWriteTime).TotalMinutes -lt 5) {
        $sv = ((Get-Content $simFile -Raw).Trim()) -split ','
        $t.Cpu = [double]$sv[0]; if ($sv.Count -gt 1 -and $sv[1]) { $t.Gpu = [double]$sv[1] }; $simActive = $true
      } else { Remove-Item $simFile -Force -ErrorAction SilentlyContinue }
    }
    if ($TestMode) {
      if ($sim.Count -eq 0) { break }
      $v = $sim.Dequeue(); $t.Cpu = $v[0]; $t.Gpu = $v[1]
    }
    $now = Get-Date
    $cpu = $t.Cpu; $gpu = $t.Gpu

    $paused = $false
    if ($Sync -and $Sync.PauseUntil -gt $now) {
      if ($cpu -ne $null -and $cpu -ge $PAUSE_CANCEL) { $Sync.PauseUntil = [datetime]::MinValue; Write-Log "pause cancelled - CPU $cpu C" }
      else {
        $paused = $true
        if (-not $wasPaused) { Write-Log "guard paused by user until $($Sync.PauseUntil.ToString('HH:mm'))" }
        if ($CpuLevel -gt 0 -or $GpuThrottled -or $Reniced.Count -gt 0) { Restore-All 'paused by user' }
      }
    }
    if ($wasPaused -and -not $paused) { Write-Log 'guard resumed' }
    $wasPaused = $paused

    if ($paused) { $coolSince = $null }
    elseif ($cpu -eq $null) {
      if (-not $nullSince) { $nullSince = $now; Write-Log 'CPU temperature not available (admin/PawnIO?)' }
    } else {
      $nullSince = $null
      if ($cpu -ge $CPU_HOT) {
        $coolSince = $null
        $elapsed = ($now - $lastStep).TotalSeconds
        $want = $false
        if ($CpuLevel -eq 0) {
          $want = $true
          if ($lastFullRestore -and ($now - $lastFullRestore).TotalSeconds -lt 120) {
            $restoreHold = [Math]::Min($HOLD_MAX, $restoreHold * 2)
            Write-Log "heat came back soon after full speed - next return to turbo waits ${restoreHold}s of cool"
          }
        }
        elseif ($elapsed -ge $STEP_MIN_SECONDS -and ($cpu -ge $CPU_CRIT -or $cpu -gt $lastStepTemp)) { $want = $true }
        if ($want -and $CpuLevel -lt ($CPU_STEPS.Count - 1)) {
          $first = ($CpuLevel -eq 0)
          Write-Log "CPU hot: $cpu C"
          Apply-CpuLevel ($CpuLevel + 1); $lastStep = $now; $lastStepTemp = $cpu
          if ($first) { Show-Notice 'nCpuHot' ([int]$cpu) }
        }
        if ($cpu -ge $CPU_CRIT) { Lower-Priority (Get-TopCpuProcesses $TOP_N) "CPU $cpu C" }
      } elseif ($cpu -lt $CPU_COOL -and ($CpuLevel -gt 0 -or $Reniced.Count -gt 0)) {
        if (-not $coolSince) { $coolSince = $now }
        elseif (($now - $coolSince).TotalSeconds -ge $(if ($CpuLevel -eq 1) { $restoreHold } else { $COOL_SECONDS })) {
          Write-Log "CPU cool: $cpu C"
          if ($CpuLevel -gt 0) { Apply-CpuLevel ($CpuLevel - 1) }
          if (-not $GpuThrottled) { Restore-Priorities }
          $coolSince = $now
          if ($CpuLevel -eq 0 -and -not $GpuThrottled) { $lastFullRestore = $now; Restore-All 'cooled down'; Show-Notice 'nCool' $null }
        }
      } else { $coolSince = $null }
    }

    if (-not $paused -and $gpu -ne $null) {
      if ($gpu -ge $GPU_HOT) {
        $gpuCoolSince = $null
        if (($now - $lastGpuStep).TotalSeconds -ge $STEP_MIN_SECONDS -or -not $GpuThrottled) {
          Ensure-Originals
          Write-Log "GPU hot: $gpu C"
          if (-not $GpuThrottled) { Show-Notice 'nGpuHot' ([int]$gpu) }
          Step-GpuDown; $lastGpuStep = $now
        }
      } elseif ($gpu -lt $GPU_COOL -and $GpuThrottled) {
        if (-not $gpuCoolSince) { $gpuCoolSince = $now }
        elseif (($now - $gpuCoolSince).TotalSeconds -ge $COOL_SECONDS) {
          Write-Log "GPU cool for ${COOL_SECONDS}s: $gpu C"; Restore-Gpu
          if ($CpuLevel -eq 0) { Restore-All 'cooled down' }
        }
      }
    }

    if ($TestMode -or ($now - $lastInfo).TotalSeconds -ge 60 -or $CpuLevel -gt 0 -or $GpuThrottled) {
      Write-Log ("temps CPU={0} GPU={1} level={2} gpuThrottled={3}{4}" -f $cpu, $gpu, $CpuLevel, $GpuThrottled, $(if ($TestMode -or $simActive) { " (SIM, $real)" } else { '' }))
      $lastInfo = $now
    }
    if ($CpuLevel -eq 0 -and $lastFullRestore -and ($now - $lastFullRestore).TotalSeconds -gt $HOLD_MAX -and $restoreHold -ne $COOL_SECONDS) { $restoreHold = $COOL_SECONDS; Write-Log 'stable at full speed - hold time reset' }
    # NVIDIA can appear later (MUX/hybrid switch): re-scan every 10 min
    if (-not $HasNvidia -and ($now - $lastRescan).TotalMinutes -ge 10) {
      $lastRescan = $now
      try { $Computer.Close(); Open-Sensors; if ($HasNvidia) { Init-Nvidia } } catch {}
    }
    if ($Sync) {
      $Sync.Cpu = $cpu; $Sync.Gpu = $gpu; $Sync.Level = $CpuLevel; $Sync.MaxPct = $CPU_STEPS[$CpuLevel]
      $Sync.GpuThrottled = $GpuThrottled; $Sync.Paused = $paused; $Sync.HasNvidia = $HasNvidia; $Sync.Sim = $simActive
      $Sync.GpuMode = $(if ($Nv) { $Nv.Mode } else { $null }); $Sync.GpuLimitW = $(if ($Nv) { $Nv.Cur } else { $null }); $Sync.GpuDefaultW = $(if ($Nv) { $Nv.Default } else { $null }); $Sync.GpuClockCap = $(if ($Nv) { $Nv.LgcMhz } else { $null })
      $Sync.Reniced = $Reniced.Count; $Sync.Updated = Get-Date
      if ($Sync.Stop) { Write-Log 'exit requested from tray'; break }
    }
    if (-not $TestMode -and -not $Sync -and (Test-Path $StopFile)) { Remove-Item $StopFile -Force -ErrorAction SilentlyContinue; Write-Log 'stop.flag found - stopping'; break }
    Start-Sleep -Seconds $PollSeconds
  }
} catch {
  Write-Log "CRASH: $($_.Exception.Message)"; $exitCode = 1
} finally {
  Restore-All $(if ($TestMode) { 'test finished' } else { 'guard exiting' })
  try { $Computer.Close() } catch {}
  try { $mutex.ReleaseMutex() } catch {}
}
exit $exitCode
