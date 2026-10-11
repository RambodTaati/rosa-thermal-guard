<#
  Rosa Thermal Guard - guard engine (MIT License)
  Keeps CPU and GPU below 100 C by throttling when hot and restoring when cool.
  Sensors: LibreHardwareMonitorLib (MPL-2.0) - needs admin rights and the PawnIO driver for CPU temps.
  CPU: steps "Maximum processor state" (all core classes, AC+DC) down at the throttle threshold,
       lowers priority of the top CPU users at the critical threshold, restores when cool.
  GPU (NVIDIA): nvidia-smi -pl (power limit) when the driver allows it, otherwise
       nvidia-smi -lgc (graphics clock cap), otherwise process priority.
  Fans (GIGABYTE laptops): bearing-friendly fan curve through GIGABYTE's own ACPI-WMI interface (root\WMI
       GB_WMIACPI_Set, the one Control Center uses): takes over from auto only when the temperature curve wants
       more airflow, moves the duty in small steps, hysteresis + minimum hold, 100 % only when critical, ramps down
       to about the auto speed before handing back (also on exit, uninstall and after a crash). See fanBoost.
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
$CPU_HOT_N = [Math]::Max(1, [int](CfgVal $cCpu 'triggerSamples' 2))   # ignore single-sample spikes
$GPU_HOT_N = [Math]::Max(1, [int](CfgVal $cGpu 'triggerSamples' 2))
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

# ---- fans (GIGABYTE ACPI-WMI: root\WMI GB_WMIACPI_Get / GB_WMIACPI_Set, the interface Control Center uses) ----
# Bearing-friendly fan curve. The firmware's own (auto) curve stays in charge until our temperature curve asks for
# MORE airflow than the fans are giving; then we take over at the speed the fans already run and move the duty in
# small steps. Decreases use hysteresis and a minimum hold; we hand back to auto only after ramping down slowly to
# about the speed auto would run at that temperature (learned by watching auto). 100 % only at critical temperatures.
$cFan = CfgVal $Cfg 'fanBoost' $null
$FAN_ON = [bool](CfgVal $cFan 'enabled' $true)
$FAN_DUTY = [int](CfgVal $cFan 'maxDuty' 229)   # 229 = 100 % duty on the GIGABYTE EC
function Get-FanCurve([string]$name, $def) {
  $src = CfgVal $cFan $name $null
  $pts = New-Object Collections.Generic.List[double[]]
  if ($src) { foreach ($p in $src) { try { $pts.Add([double[]]@([double]$p[0], [Math]::Max(0.0, [Math]::Min(100.0, [double]$p[1])))) } catch {} } }
  if ($pts.Count -lt 2) { $pts.Clear(); foreach ($p in $def) { $pts.Add([double[]]@([double]$p[0], [double]$p[1])) } }
  $pts.Sort([Comparison[double[]]] { param($a, $b) $a[0].CompareTo($b[0]) })
  return , $pts
}
$FAN_CURVE_CPU = Get-FanCurve 'curveCpu' @(@(75, 50), @(80, 58), @(85, 68), @(90, 80), @(94, 90))
$FAN_CURVE_GPU = Get-FanCurve 'curveGpu' @(@(72, 50), @(76, 57), @(80, 65), @(84, 74), @(88, 84))
$FAN_FULL_CPU = [double](CfgVal $cFan 'fullDutyCpuC' 95)       # 100 % only at/above these (no ramp)
$FAN_FULL_GPU = [double](CfgVal $cFan 'fullDutyGpuC' 90)
$FAN_HYST = [double](CfgVal $cFan 'hysteresisC' 4)              # duty only goes down once temps are this far below
$FAN_ENGAGE_MARGIN = [double](CfgVal $cFan 'engageMarginPercent' 5)
$FAN_REL_CPU = [double](CfgVal $cFan 'releaseCpuC' 70)          # hand back to auto below these ...
$FAN_REL_GPU = [double](CfgVal $cFan 'releaseGpuC' 67)
$FAN_REL_SEC = [int](CfgVal $cFan 'releaseAfterSeconds' 30)     # ... for this long
$FAN_MIN_HOLD = [int](CfgVal $cFan 'minHoldSeconds' 60)         # no decrease sooner than this after any increase
$FAN_MIN_SWITCH = [int](CfgVal $cFan 'minSwitchIntervalSeconds' 60)   # auto <-> controlled no more often than this
$FAN_UP_STEP = [Math]::Max(0.5, [double](CfgVal $cFan 'rampUpStepPercent' 2))
$FAN_DOWN_STEP = [Math]::Max(0.5, [double](CfgVal $cFan 'rampDownStepPercent' 2))
$FAN_RAMP_SEC = [Math]::Max(1.0, [double](CfgVal $cFan 'rampIntervalSeconds' 2))
$FAN_HB_FALLBACK = [double](CfgVal $cFan 'handBackFallbackPercent' 25)
$FAN_SMOOTH = [double](CfgVal $cFan 'smoothingSeconds' 12)
$FAN_CRIT_N = [Math]::Max(1, [int](CfgVal $cFan 'criticalSamples' 3))   # raw samples in a row at/above critical before 100 %          # EMA time constant for the temperatures the fan logic uses
$FAN_HB_MARGIN = [double](CfgVal $cFan 'handBackMarginPercent' 4)
$FAN_MAXRPM1 = [int](CfgVal $cFan 'maxRpmCpuFan' 6400)          # RPM at 100 % duty (AORUS Master 16: ~6,380 / ~6,850)
$FAN_MAXRPM2 = [int](CfgVal $cFan 'maxRpmGpuFan' 6900)
$FanStateFile = Join-Path $DataDir 'fanstate.json'   # previous fan mode while we control the fans (crash-safe)
$FanAutoFile = Join-Path $DataDir 'fanauto.json'     # learned: fan % that auto mode runs at each temperature
$script:FanOk = $false; $script:FanBoosted = $false; $script:FanInfo = $null
$script:FanLevel = 0          # 0 = auto (firmware), 1 = our curve, 2 = 100 % (critical)
$script:FanPct = $null; $script:FanTarget = $null; $script:FanRampLast = [datetime]::MinValue
$script:FanSwitchAt = [datetime]::MinValue; $script:FanRaiseAt = [datetime]::MinValue; $script:FanLevelSince = $null
$script:FanAuto = @{}; $script:FanAutoSaved = Get-Date; $script:FanLastCpu = $null; $script:FanLastGpu = $null
function Fan-Get([string]$m) {
  $i = Get-CimInstance -Namespace root\WMI -ClassName GB_WMIACPI_Get -ErrorAction Stop
  return (Invoke-CimMethod -InputObject $i -MethodName $m -ErrorAction Stop).Data
}
function Fan-Set([string]$m, [int]$v) {
  $i = Get-CimInstance -Namespace root\WMI -ClassName GB_WMIACPI_Set -ErrorAction Stop
  [void](Invoke-CimMethod -InputObject $i -MethodName $m -Arguments @{ Data = [byte]$v } -ErrorAction Stop)
}
function Fan-Rpm([string]$m) { $v = [int](Fan-Get $m); return ((($v -band 0xFF) -shl 8) -bor ($v -shr 8)) }   # the EC returns RPM byte-swapped
function Get-FanMode {
  $f = @{ Fixed = [int](Fan-Get 'GetFixedFanStatus'); Step = [int](Fan-Get 'GetStepFanStatus'); Auto = [int](Fan-Get 'GetAutoFanStatus'); Speed = [int](Fan-Get 'GetFixedFanSpeed') }
  if ($f.Fixed -eq 1) { $f.GpuDuty = [int](Fan-Get 'GetGPUFanDuty') }
  return $f
}
function Curve-Pct($pts, $t) {
  if ($t -eq $null -or $pts.Count -lt 1 -or $t -lt $pts[0][0]) { return 0.0 }
  for ($i = 1; $i -lt $pts.Count; $i++) {
    if ($t -le $pts[$i][0]) { $a = $pts[$i - 1]; $b = $pts[$i]; return $a[1] + ($b[1] - $a[1]) * ($t - $a[0]) / [Math]::Max(0.01, $b[0] - $a[0]) }
  }
  return $pts[$pts.Count - 1][1]
}
function Fan-Demand($cpu, $gpu, [double]$off = 0) {
  $c = if ($cpu -ne $null) { $cpu - $off } else { $null }; $g = if ($gpu -ne $null) { $gpu - $off } else { $null }
  return [Math]::Max((Curve-Pct $FAN_CURVE_CPU $c), (Curve-Pct $FAN_CURVE_GPU $g))
}
function Fan-Critical($cpu, $gpu) { ($cpu -ne $null -and $cpu -ge $FAN_FULL_CPU) -or ($gpu -ne $null -and $gpu -ge $FAN_FULL_GPU) }
function Fan-ObservedPct {
  if (-not $FanInfo) { return $null }
  return 100.0 * [Math]::Min(1.0, [Math]::Max([double]$FanInfo.Rpm1 / [Math]::Max(1000, $FAN_MAXRPM1), [double]$FanInfo.Rpm2 / [Math]::Max(1000, $FAN_MAXRPM2)))
}
function Fan-Bucket($t) { [string]([int]([Math]::Floor([double]$t / 5.0) * 5)) }
function Learn-AutoFan($cpu) {
  # only while the firmware curve is in charge and nothing else forces the fans
  if ($simActive -or $TestMode) { return }   # simulated temperatures would teach the wrong curve
  if ($cpu -eq $null -or $FanLevel -ne 0 -or -not $FanInfo -or $FanInfo.Fixed -eq 1 -or $FanInfo.Mode -notin @('auto', 'normal')) { return }
  if (((Get-Date) - $FanSwitchAt).TotalSeconds -lt 60) { return }   # auto is still settling after a hand-back
  $o = Fan-ObservedPct; if ($o -eq $null) { return }
  $k = Fan-Bucket $cpu
  $script:FanAuto[$k] = if ($FanAuto.ContainsKey($k)) { 0.9 * [double]$FanAuto[$k] + 0.1 * $o } else { $o }
  if (((Get-Date) - $FanAutoSaved).TotalMinutes -ge 5) { $script:FanAutoSaved = Get-Date; try { $FanAuto | ConvertTo-Json | Set-Content $FanAutoFile -Encoding UTF8 } catch {} }
}
function Auto-Pct($cpu) {
  # what auto mode would run now: learned value for this temperature (nearest bucket within 10 C), else the fallback
  if ($cpu -ne $null -and $FanAuto.Count -gt 0) {
    $b = [int](Fan-Bucket $cpu)
    foreach ($d in 0, -5, 5, -10, 10) { $k = [string]($b + $d); if ($FanAuto.ContainsKey($k)) { return [double]$FanAuto[$k] } }
  }
  return $FAN_HB_FALLBACK
}
function Init-Fan {
  if (-not $FAN_ON) { Write-Log 'fan boost disabled in config.json'; return }
  try {
    $m = Get-FanMode; $r1 = Fan-Rpm 'getRpm1'; $r2 = Fan-Rpm 'getRpm2'
    $script:FanOk = $true
    if (Test-Path $FanAutoFile) { try { $j = Get-Content $FanAutoFile -Raw | ConvertFrom-Json; foreach ($p in $j.PSObject.Properties) { $script:FanAuto[$p.Name] = [double]$p.Value } } catch {} }
    $cv = { param($c) ($c | % { '{0}C:{1}%' -f $_[0], $_[1] }) -join ' ' }
    Write-Log ("fan control: GIGABYTE ACPI-WMI found (fans {0}/{1} RPM, fixed={2} step={3} auto={4}); curve CPU [{5}] GPU [{6}], 100% at CPU {7} / GPU {8} C; ramp +{9}/-{10}% every {11}s; hysteresis {12} C, hold {13}s, min {14}s between auto/controlled; hand back below {15}/{16} C for {17}s; learned auto points: {18}" -f `
      $r1, $r2, $m.Fixed, $m.Step, $m.Auto, (& $cv $FAN_CURVE_CPU), (& $cv $FAN_CURVE_GPU), $FAN_FULL_CPU, $FAN_FULL_GPU, $FAN_UP_STEP, $FAN_DOWN_STEP, $FAN_RAMP_SEC, $FAN_HYST, $FAN_MIN_HOLD, $FAN_MIN_SWITCH, $FAN_REL_CPU, $FAN_REL_GPU, $FAN_REL_SEC, $FanAuto.Count)
  } catch { Write-Log 'fan control: GIGABYTE ACPI-WMI not available on this PC - fan boost off' }
}
function Read-Fan {
  if (-not $FanOk) { return }
  try {
    $m = Get-FanMode
    $mode = if ($m.Fixed -eq 1 -and $FanBoosted) { $(if ($m.Speed -ge $FAN_DUTY - 2) { 'max' } else { 'boost' }) } elseif ($m.Fixed -eq 1 -and $m.Speed -ge $FAN_DUTY - 2) { 'max' } elseif ($m.Fixed -eq 1) { 'fixed' } elseif ($m.Auto -eq 1) { 'auto' } else { 'normal' }
    $script:FanInfo = @{ Rpm1 = (Fan-Rpm 'getRpm1'); Rpm2 = (Fan-Rpm 'getRpm2'); Mode = $mode; Fixed = $m.Fixed; Speed = $m.Speed }
    $script:FanErr = 0
  } catch { $script:FanInfo = $null; if ($FanBoosted) { Fan-Fault "read: $($_.Exception.Message)" } }
}
# watchdog: if the vendor WMI calls keep failing while we hold the fans, hand them back to GIGABYTE auto mode
$script:FanErr = 0
function Fan-Fault([string]$msg) {
  $script:FanErr++
  Write-Log "fan WMI error #$($FanErr): $msg"
  if ($FanErr -ge 3) { Fan-Failsafe }
}
function Fan-Failsafe {
  Write-Log 'fan watchdog: WMI calls keep failing - handing the fans back to GIGABYTE auto mode and turning fan control off for this session'
  foreach ($c in @(@('SetCurrentFanStep', 0), @('SetFixedFanStatus', 0), @('SetStepFanStatus', 0), @('SetAutoFanStatus', 1))) { try { Fan-Set $c[0] $c[1] } catch { Write-Log "  $($c[0]) failed: $($_.Exception.Message)" } }
  Remove-Item $FanStateFile -Force -ErrorAction SilentlyContinue
  $script:FanOk = $false; $script:FanBoosted = $false; $script:FanLevel = 0; $script:FanPct = $null; $script:FanTarget = $null; $script:FanInfo = $null
}
function Pct-Duty([double]$p) { [int][Math]::Round($FAN_DUTY * [Math]::Max(0.0, [Math]::Min(100.0, $p)) / 100.0) }
function Fan-Apply([double]$p) {
  $d = Pct-Duty $p
  Fan-Set 'SetFixedFanSpeed' $d; Fan-Set 'SetGPUFanDuty' $d
  $script:FanPct = $p
}
function Fan-Take([string]$why, [double]$startPct, [double]$target) {
  # switch from auto to fixed duty at the speed the fans already run (no jump), then ramp from there
  try {
    $prev = $null
    if (-not (Test-Path $FanStateFile)) { $prev = Get-FanMode; $prev | ConvertTo-Json | Set-Content $FanStateFile -Encoding UTF8 }
    Fan-Set 'SetCurrentFanStep' 0; Fan-Set 'SetAutoFanStatus' 0
    Fan-Apply $startPct
    Fan-Set 'SetStepFanStatus' 1; Fan-Set 'SetFixedFanStatus' 1
    $script:FanBoosted = $true; $script:FanTarget = $target; $script:FanRampLast = Get-Date
    $script:FanSwitchAt = Get-Date; $script:FanRaiseAt = Get-Date; $script:FanLevelSince = Get-Date
    $script:FanLevel = $(if ($startPct -ge 99.5) { 2 } else { 1 })
    $pv = if ($prev) { "; saved previous mode fixed=$($prev.Fixed) step=$($prev.Step) auto=$($prev.Auto) speed=$($prev.Speed)" } else { '' }
    Write-Log ("fans: controlled from {0:N0}% -> target {1:N0}% ({2}){3}" -f $startPct, $target, $why, $pv)
  } catch { Write-Log "fan take-over failed: $($_.Exception.Message)" }
}
function Fan-Step {
  # one ramp step toward the target (called every poll)
  if (-not $FanBoosted -or $FanPct -eq $null -or $FanTarget -eq $null) { return }
  if ([Math]::Abs($FanPct - $FanTarget) -lt 0.25) { return }
  if (((Get-Date) - $FanRampLast).TotalSeconds -lt $FAN_RAMP_SEC - 0.3) { return }
  $n = if ($FanPct -lt $FanTarget) { [Math]::Min($FanTarget, $FanPct + $FAN_UP_STEP) } else { [Math]::Max($FanTarget, $FanPct - $FAN_DOWN_STEP) }
  try { Fan-Apply $n; $script:FanRampLast = Get-Date; $script:FanLevel = $(if ($n -ge 99.5) { 2 } else { 1 }) } catch { Fan-Fault "step: $($_.Exception.Message)" }
}
function Restore-Fan([string]$why, [switch]$Abrupt) {
  if (-not (Test-Path $FanStateFile)) { $script:FanBoosted = $false; $script:FanLevel = 0; return }
  try {
    # soft landing: never drop from a high duty to auto in one jump
    if (-not $Abrupt) {
      $cur = $FanPct
      if ($cur -eq $null) { try { $m = Get-FanMode; if ($m.Fixed -eq 1) { $cur = 100.0 * $m.Speed / $FAN_DUTY } } catch {} }
      $goal = Auto-Pct $FanLastCpu
      if ($cur -ne $null -and $cur -gt $goal + $FAN_HB_MARGIN) {
        $steps = [Math]::Ceiling(($cur - $goal) / $FAN_DOWN_STEP); $pause = [Math]::Min(1000, [Math]::Max(200, [int](12000 / [Math]::Max(1, $steps))))
        Write-Log ("fans: ramping down {0:N0}% -> {1:N0}% before handing back ({2})" -f $cur, $goal, $why)
        while ($cur -gt $goal + 0.25) { $cur = [Math]::Max($goal, $cur - $FAN_DOWN_STEP); Fan-Apply $cur; Start-Sleep -Milliseconds $pause }
      }
    }
    $p = Get-Content $FanStateFile -Raw | ConvertFrom-Json
    Fan-Set 'SetCurrentFanStep' 0
    Fan-Set 'SetFixedFanStatus' ([int]$p.Fixed); Fan-Set 'SetStepFanStatus' ([int]$p.Step)
    Fan-Set 'SetFixedFanSpeed' ([int]$p.Speed)
    if ([int]$p.Fixed -eq 1 -and $p.GpuDuty -ne $null) { Fan-Set 'SetGPUFanDuty' ([int]$p.GpuDuty) }
    Fan-Set 'SetAutoFanStatus' ([int]$p.Auto)
    Remove-Item $FanStateFile -Force -ErrorAction SilentlyContinue
    Write-Log ("fan mode restored ({0}): fixed={1} step={2} auto={3} speed={4}" -f $why, $p.Fixed, $p.Step, $p.Auto, $p.Speed)
  } catch { Write-Log "fan restore failed: $($_.Exception.Message)" }
  if ($FanBoosted) { $script:FanSwitchAt = Get-Date }
  $script:FanBoosted = $false; $script:FanLevel = 0; $script:FanLevelSince = $null
  $script:FanPct = $null; $script:FanTarget = $null
  try { if ($FanAuto.Count -gt 0) { $FanAuto | ConvertTo-Json | Set-Content $FanAutoFile -Encoding UTF8 } } catch {}
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
  if ($why -ne 'cooled down') { Restore-Fan $why }   # fans have their own, lower restore threshold
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
if (Test-Path $FanStateFile) { Restore-Fan 'previous run did not exit cleanly' }
if ($Restore) { exit 0 }

try { Open-Sensors } catch { Write-Log "cannot load LibreHardwareMonitor: $($_.Exception.Message)"; exit 2 }
if (-not $isAdmin) { Write-Log 'WARNING: not running as admin - CPU temperatures need admin' }
Init-Fan
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
$fanRelSince = $null; $lastFanFix = [datetime]::MinValue; $fanCpuS = $null; $fanGpuS = $null; $fanCritN = 0; $fanSN = 0; $cpuHotN = 0; $gpuHotN = 0; $lastLoopAt = $null
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
    if ($lastLoopAt -and ($now - $lastLoopAt).TotalSeconds -gt [Math]::Max(30, 5 * $PollSeconds)) {
      Write-Log ("resume/stall detected ({0:N0}s since last check) - re-reading fans and temperatures" -f ($now - $lastLoopAt).TotalSeconds)
      $fanCpuS = $null; $fanGpuS = $null; $fanCritN = 0; $fanSN = 0; $cpuHotN = 0; $gpuHotN = 0; $lastLoopAt = $null; $lastFanFix = [datetime]::MinValue
    }
    $lastLoopAt = $now
    $cpu = $t.Cpu; $gpu = $t.Gpu

    $paused = $false
    if ($Sync -and $Sync.PauseUntil -gt $now) {
      if ($cpu -ne $null -and $cpu -ge $PAUSE_CANCEL) { $Sync.PauseUntil = [datetime]::MinValue; Write-Log "pause cancelled - CPU $cpu C" }
      else {
        $paused = $true
        if (-not $wasPaused) { Write-Log "guard paused by user until $($Sync.PauseUntil.ToString('HH:mm'))" }
        if ($CpuLevel -gt 0 -or $GpuThrottled -or $Reniced.Count -gt 0 -or $FanBoosted) { Restore-All 'paused by user' }
      }
    }
    if ($wasPaused -and -not $paused) { Write-Log 'guard resumed' }
    $wasPaused = $paused

    $cpuHotN = $(if ($cpu -ne $null -and $cpu -ge $CPU_HOT) { $cpuHotN + 1 } else { 0 })
    $gpuHotN = $(if ($gpu -ne $null -and $gpu -ge $GPU_HOT) { $gpuHotN + 1 } else { 0 })
    if ($paused) { $coolSince = $null }
    elseif ($cpu -eq $null) {
      if (-not $nullSince) { $nullSince = $now; Write-Log 'CPU temperature not available (admin/PawnIO?)' }
    } else {
      $nullSince = $null
      if ($cpu -ge $CPU_HOT -and $cpuHotN -lt $CPU_HOT_N) { if ($cpuHotN -eq 1) { Write-Log "CPU spike $cpu C ignored (needs $CPU_HOT_N samples in a row)" } }
      elseif ($cpu -ge $CPU_HOT) {
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
      if ($gpu -ge $GPU_HOT -and $gpuHotN -lt $GPU_HOT_N) { }
      elseif ($gpu -ge $GPU_HOT) {
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

    # fans: first line of defence, before any throttling (curve starts well below the throttle points)
    if ($FanOk) {
      Read-Fan
      if ($cpu -ne $null) { $script:FanLastCpu = $cpu }; if ($gpu -ne $null) { $script:FanLastGpu = $gpu }   # raw, for the exit soft landing
      if ($paused) { $fanRelSince = $null }
      # the fan logic works on smoothed temperatures (EMA, ~fanSmoothingSeconds) so single-sample spikes don't move the fans
      $fa = [Math]::Min(1.0, $PollSeconds / [Math]::Max(1.0, $FAN_SMOOTH))
      $fanSN = $(if ($fanCpuS -eq $null -and $fanGpuS -eq $null) { 1 } else { $fanSN + 1 })
      if ($cpu -ne $null) { $fanCpuS = $(if ($fanCpuS -eq $null) { [double]$cpu } else { $fanCpuS + $fa * ($cpu - $fanCpuS) }) } else { $fanCpuS = $null }
      if ($gpu -ne $null) { $fanGpuS = $(if ($fanGpuS -eq $null) { [double]$gpu } else { $fanGpuS + $fa * ($gpu - $fanGpuS) }) } else { $fanGpuS = $null }
      $rawCrit = Fan-Critical $cpu $gpu
      $fanCritN = $(if ($rawCrit) { $fanCritN + 1 } else { 0 })
      if (-not $paused) {
        $fc = if ($fanCpuS -ne $null) { [Math]::Round($fanCpuS, 1) } else { $null }; $fg = if ($fanGpuS -ne $null) { [Math]::Round($fanGpuS, 1) } else { $null }
        Learn-AutoFan $fc
        $tempTxt = "CPU $fc C, GPU $fg C smoothed (now $cpu / $gpu)"
        # critical = criticalSamples raw samples in a row at/above the critical point, or the (warmed-up) smoothed value there
        $crit = $fanCritN -ge $FAN_CRIT_N -or ($fanSN -ge 5 -and (Fan-Critical $fc $fg))
        $demand = Fan-Demand $fc $fg 0
        $obs = Fan-ObservedPct
        if (-not $FanBoosted) {
          $fanRelSince = $null
          if ($crit) { Fan-Take "critical: $tempTxt" 100 100 }   # safety first: straight to 100 %, no ramp, no switch delay
          elseif ($fanSN -ge 5 -and $obs -ne $null -and $demand -ge $obs + $FAN_ENGAGE_MARGIN -and ($now - $FanSwitchAt).TotalSeconds -ge $FAN_MIN_SWITCH) {
            Fan-Take ("curve {0:N0}% > fans {1:N0}%: {2}" -f $demand, $obs, $tempTxt) ([Math]::Round($obs)) $demand
          }
        } else {
          # keep control asserted if Control Center (or anything else) changed the fans while we need them
          if ($FanInfo -and $FanPct -ne $null -and ($FanInfo.Fixed -ne 1 -or [Math]::Abs($FanInfo.Speed - (Pct-Duty $FanPct)) -gt 3) -and ($now - $lastFanFix).TotalSeconds -ge 30) {
            Write-Log "fan mode was changed outside Thermal Guard ($($FanInfo.Mode), speed $($FanInfo.Speed)) - taking control again"
            $lastFanFix = $now
            Fan-Set 'SetCurrentFanStep' 0; Fan-Set 'SetAutoFanStatus' 0; Fan-Apply $FanPct; Fan-Set 'SetStepFanStatus' 1; Fan-Set 'SetFixedFanStatus' 1
          }
          $floor = [Math]::Min(90.0, (Auto-Pct $fc))      # while controlled, never below what auto would run (never 100 from this)
          if ($crit) {
            if ($FanPct -lt 99.5) { Write-Log "fans: critical ($tempTxt) - 100% now"; Fan-Apply 100; $script:FanLevel = 2 }
            $script:FanTarget = 100; $script:FanRaiseAt = $now; $fanRelSince = $null
          } else {
            $want = [Math]::Max($demand, $floor)
            if ($want -gt $FanTarget + 0.5) { $script:FanTarget = $want; $script:FanRaiseAt = $now }
            elseif (($now - $FanRaiseAt).TotalSeconds -ge $FAN_MIN_HOLD) {
              # decreases use the curve shifted by the hysteresis (as if it were $FAN_HYST C hotter), so small wobbles don't move the fans
              $down = [Math]::Max((Fan-Demand $fc $fg (-$FAN_HYST)), $floor)
              if ($down -lt $FanTarget - 0.5) { $script:FanTarget = $down }
            }
            # hand back to auto: cool long enough, held long enough, and already ramped down to about auto speed
            # decoupled from CPU/GPU throttling: only the (smoothed) temperatures decide
            $cool = ($fc -eq $null -or $fc -lt $FAN_REL_CPU) -and ($fg -eq $null -or $fg -lt $FAN_REL_GPU)
            if (-not $cool) { $fanRelSince = $null } elseif (-not $fanRelSince) { $fanRelSince = $now }
            if ($fanRelSince -and ($now - $fanRelSince).TotalSeconds -ge 300 -and $FanBoosted) {
              # belt and braces: never stay in control for long once it is cool
              Write-Log "fan stuck guard: cool for 5 min but still controlled ($tempTxt) - ramping down and handing back"
              Restore-Fan 'stuck guard'; $fanRelSince = $null; Read-Fan
            }
            if ($fanRelSince -and ($now - $fanRelSince).TotalSeconds -ge $FAN_REL_SEC -and ($now - $FanRaiseAt).TotalSeconds -ge $FAN_MIN_HOLD -and ($now - $FanSwitchAt).TotalSeconds -ge $FAN_MIN_SWITCH) {
              $script:FanTarget = $floor
              if ($FanPct -le $floor + $FAN_HB_MARGIN) {
                Write-Log ("fans: cool for {0}s and down to {1:N0}% (auto runs ~{2:N0}% here) - handing back to auto ({3})" -f [int]($now - $fanRelSince).TotalSeconds, $FanPct, $floor, $tempTxt)
                Restore-Fan 'cooled down' -Abrupt; $fanRelSince = $null; Read-Fan
              }
            }
          }
          if ($FanBoosted) { Fan-Step; Read-Fan }
        }
      }
    }

    if ($TestMode -or ($now - $lastInfo).TotalSeconds -ge 60 -or $CpuLevel -gt 0 -or $GpuThrottled) {
      Write-Log ("temps CPU={0} GPU={1} level={2} gpuThrottled={3}{5}{4}" -f $cpu, $gpu, $CpuLevel, $GpuThrottled, $(if ($TestMode -or $simActive) { " (SIM, $real)" } else { '' }), $(if ($FanInfo) { " fan=$($FanInfo.Mode) $($FanInfo.Rpm1)/$($FanInfo.Rpm2)rpm" } else { '' }))
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
      $Sync.FanOk = $FanOk; $Sync.FanBoost = $FanBoosted; $Sync.FanLevel = $FanLevel; $Sync.FanBoostPct = $(if ($FanPct -ne $null) { [int][Math]::Round($FanPct) } else { $null }); $Sync.FanTarget = $(if ($FanTarget -ne $null) { [int][Math]::Round($FanTarget) } else { $null }); $Sync.FanMax1 = $FAN_MAXRPM1; $Sync.FanMax2 = $FAN_MAXRPM2
      if ($FanInfo) { $Sync.FanRpm1 = $FanInfo.Rpm1; $Sync.FanRpm2 = $FanInfo.Rpm2; $Sync.FanMode = $FanInfo.Mode } else { $Sync.FanMode = $null }
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
