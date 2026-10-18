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
  Game mode: GPU load + fullscreen/listed game -> earlier fan curve and the game is never deprioritized (fanBoost.gameMode).
  Sensor reads and fan WMI run beside this loop, with a 2 s WMI timeout. A stuck call holds the last power step and
  fan target: it does not release cooling and it does not jump the fans. After repeated turbo spikes, turbo stays off
  until the CPU has been continuously cool (spikeGuard stickyBelowC / stickySeconds).
  Auto-update: Updater.ps1 checks GitHub ~daily and downloads + verifies (SHA-256); the guard installs a verified update
        only when idle and cool (no game mode, no throttling, no fan control), after restoring everything (autoUpdate).
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
  [double]$PollSeconds = 0
)
$ErrorActionPreference = 'Continue'
$AppDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $AppDir 'GuardDecide.ps1')
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
$CPU_HOT_SEC = [Math]::Max(0.0, [double](CfgVal $cCpu 'triggerSeconds' 2))   # heat must last this long (spike filter)
# spike guard: at full turbo this CPU jumps from the 80s to 100-105 C within one 1-s reading, too fast for the 2-s filter.
# One reading >= fastC (or a fast rise >= risePerSec above riseFromC) turns turbo off at once (level 1 = 99 %), and turbo
# stays off until no such reading for holdSeconds (gameHoldSeconds in game mode). Further steps still need sustained heat.
function SG-Hold { $b = $(if ($GameMode) { $SG_GAME_HOLD } else { $SG_HOLD }); [Math]::Min([Math]::Max($b, [double]$HOLD_MAX), $b * $sgMul) }
$cSg = CfgVal $Cfg 'spikeGuard' $null
$SG_ON = [bool](CfgVal $cSg 'enabled' $true)
$SG_FAST_C = [double](CfgVal $cSg 'fastC' 95)
$SG_RISE_C = [double](CfgVal $cSg 'riseFromC' 92)
$SG_RISE = [Math]::Max(1.0, [double](CfgVal $cSg 'risePerSec' 5))
$SG_HOLD = [Math]::Max(0.0, [double](CfgVal $cSg 'holdSeconds' 120))
$SG_GAME_HOLD = [Math]::Max(0.0, [double](CfgVal $cSg 'gameHoldSeconds' 300))
$SG_REPEAT = [int](CfgVal $cSg 'repeatCount' 2)                 # spikes inside the window before turbo is held (0 disables)
$SG_WINDOW = [Math]::Max(60.0, [double](CfgVal $cSg 'repeatWindowSeconds' 3600))
$SG_COOL_C = [double](CfgVal $cSg 'stickyBelowC' 75)            # turbo stays off until the CPU is continuously under this
$SG_COOL_SEC = [Math]::Max(0.0, [double](CfgVal $cSg 'stickySeconds' 600))
$IO_STALE = [Math]::Max(0.5, [double](CfgVal $Cfg 'ioStaleSeconds' 2.5))   # older than this, the sample is not acted on
$script:TurboSticky = $false; $script:TurboCool = $null
$script:TurboSpikes = New-Object System.Collections.Generic.List[datetime]
$script:AcctAt = $null; $script:AcctWasC = $false; $script:AcctWasG = $false
$prevCpu = $null; $prevCpuAt = $null; $lastSpikeAt = $null; $over100C = 0.0; $over100G = 0.0; $sgMul = 1   # hold doubles (up to maxTurboHoldSeconds) when a spike follows right after turbo returns
$GPU_HOT_SEC = [Math]::Max(0.0, [double](CfgVal $cGpu 'triggerSeconds' 2))
$TOP_N = [int](CfgVal $Cfg 'lowerPriorityTopN' 3)
$NOTIFY = [bool](CfgVal $Cfg 'notifications' $true)
$ALLOW_SIM = [bool](CfgVal $Cfg 'allowSimulateFile' $false)
$cLog = CfgVal $Cfg 'logging' $null
$LOG_MAX = [Math]::Max(0.25, [double](CfgVal $cLog 'maxSizeMB' 5)) * 1MB      # rotate guard.log at this size
$LOG_KEEP = [Math]::Max(1, [int](CfgVal $cLog 'keepFiles' 5))                # guard.1.log.gz ... guard.N.log.gz
$LOG_DAYS = [Math]::Max(1.0, [double](CfgVal $cLog 'keepDays' 7))            # archives older than this are deleted
$LOG_TOTAL = [Math]::Max(1.0, [double](CfgVal $cLog 'totalMaxMB' 20)) * 1MB  # guard.log + archives never above this
$TEMPS_EVERY = [Math]::Max(1.0, [double](CfgVal $cLog 'tempsEverySec' 5))    # temps line while something is active (idle: 60 s); events always
$script:LogCheckAt = [datetime]::MinValue
if ($PollSeconds -le 0) { $PollSeconds = [double](CfgVal $Cfg 'pollSeconds' 1) }
$PollSeconds = [Math]::Max(0.5, [Math]::Min(10.0, $PollSeconds))   # sensor polling interval; everything else below is time-based
$cUpd = CfgVal $Cfg 'autoUpdate' $null
$UPD_ON = [bool](CfgVal $cUpd 'enabled' $true)
$UPD_HOURS = [Math]::Max(1.0, [double](CfgVal $cUpd 'checkHours' 24))
$AppVersion = '0.0.0'; try { $AppVersion = (Get-Content (Join-Path $AppDir 'version.txt') -Raw -ErrorAction Stop).Trim() } catch {}

# ---- auto-update (installs only files Updater.ps1 verified; re-verified right before running) ----
$script:TopScanAt = [datetime]::MinValue; $script:UpdFlagAt = [datetime]::MinValue
$UpdScript = Join-Path $AppDir 'Updater.ps1'
$UpdDir = Join-Path $AppDir 'update'             # under Program Files: admin-only
$UpdReady = Join-Path $UpdDir 'ready.json'
$UpdDone = Join-Path $DataDir 'update-done.json'
$UpdStatus = Join-Path $DataDir 'update-status.json'
$script:UpdNext = (Get-Date).AddSeconds(300 + (Get-Random -Minimum 0 -Maximum 180))   # first check ~5 min after start, with jitter
$script:UpdFail = 0; $script:UpdProc = $null; $script:UpdProcAt = $null; $script:UpdManual = $false; $script:UpdSafeSince = $null; $script:UpdReadyAt = [datetime]::MinValue; $script:UpdBusy = $false
function Update-Startup {
  if (-not (Test-Path $UpdDone)) { return }
  try {
    $d = Get-Content $UpdDone -Raw | ConvertFrom-Json
    if ([string]$d.to -eq $AppVersion) { Write-Log "update: now running v$AppVersion (updated from v$($d.from))"; Show-Notice 'nUpdated' $AppVersion; Remove-Item $UpdReady -Force -ErrorAction SilentlyContinue }
    else { Write-Log "update: install of v$($d.to) did not complete (still v$AppVersion) - see update-install.log; retrying later"; $script:UpdFail = 3; $script:UpdNext = (Get-Date).AddHours(6); Remove-Item $UpdReady -Force -ErrorAction SilentlyContinue }
  } catch {}
  Remove-Item $UpdDone -Force -ErrorAction SilentlyContinue
  Get-ChildItem $UpdDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'ready.json' -and -not (Test-Path $UpdReady) } | Remove-Item -Force -ErrorAction SilentlyContinue
}
function Update-Start([bool]$manual) {
  if (-not (Test-Path $UpdScript)) { return }
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$UpdScript`"")
  if ($manual) { $a += '-Manual' }
  $script:UpdProc = Start-Process "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $a -WindowStyle Hidden -PassThru
  $script:UpdProcAt = Get-Date; $script:UpdManual = $manual
}
function Update-Done {
  $st = $null; try { $st = Get-Content $UpdStatus -Raw | ConvertFrom-Json } catch {}
  $res = if ($st) { [string]$st.result } else { 'error' }
  if ($res -eq 'error') {
    $script:UpdFail++
    $h = [Math]::Min($UPD_HOURS, [Math]::Pow(2, $script:UpdFail - 1))     # backoff 1, 2, 4, 8 ... h, at most checkHours
    $script:UpdNext = (Get-Date).AddHours($h).AddMinutes((Get-Random -Minimum 0 -Maximum 20))
    Write-Log ("update: next try in ~{0:N0} h (failure {1})" -f $h, $script:UpdFail)
    if ($script:UpdManual) { Show-Notice 'nUpdateFail' $(if ($st) { [string]$st.message } else { '?' }) }
  } else {
    $script:UpdFail = 0
    $script:UpdNext = (Get-Date).AddHours($UPD_HOURS).AddMinutes((Get-Random -Minimum 0 -Maximum 60))
    if ($res -eq 'uptodate' -and $script:UpdManual) { Show-Notice 'nUpToDate' $AppVersion }
    if ($res -eq 'ready') { Show-Notice 'nUpdateReady' ([string]$st.latest) }
  }
  $script:UpdProc = $null; $script:UpdManual = $false
}
function Update-Tick($now, $cpu, $gpu, $sim, $paused) {
  if (($now - $script:UpdFlagAt).TotalSeconds -ge 5) { $script:UpdFlagAt = $now; $fl = Join-Path $DataDir 'checkupdate.flag'; if (Test-Path $fl) { Remove-Item $fl -Force -ErrorAction SilentlyContinue; $Sync.CheckUpdate = $true } }   # same as the tray menu item (a check is harmless)
  if ($Sync.CheckUpdate) { $Sync.CheckUpdate = $false; if (-not $script:UpdProc) { Write-Log 'update: check requested from the tray'; Update-Start $true } }
  if ($script:UpdProc) {
    if ($script:UpdProc.HasExited) { Update-Done }
    elseif (($now - $script:UpdProcAt).TotalMinutes -ge 15) { try { $script:UpdProc.Kill() } catch {}; Write-Log 'update: checker took over 15 min - stopped'; Update-Done }
    return
  }
  if ($UPD_ON -and $now -ge $script:UpdNext) { Update-Start $false; return }
  # install a verified update only when it is safe: nothing controlled, no game, cool, for 60 s in a row
  if (($now - $script:UpdReadyAt).TotalSeconds -lt 5) { return }
  $script:UpdReadyAt = $now
  if (-not (Test-Path $UpdReady)) { $script:UpdSafeSince = $null; return }
  $safe = -not $GameMode -and -not $FanBoosted -and $CpuLevel -eq 0 -and -not $GpuThrottled -and $Reniced.Count -eq 0 -and -not $sim -and -not $paused -and
          $cpu -ne $null -and $(if ($fanCpuS -ne $null) { $fanCpuS -lt 75 } else { $cpu -lt 80 }) -and $(if ($fanGpuS -ne $null) { $fanGpuS -lt 72 } elseif ($gpu -ne $null) { $gpu -lt 75 } else { $true })   # smoothed: brief turbo spikes do not block it
  if (-not $safe) { $script:UpdSafeSince = $null; return }
  if (-not $script:UpdSafeSince) { $script:UpdSafeSince = $now; return }
  if (($now - $script:UpdSafeSince).TotalSeconds -lt 60) { return }
  Install-Update
}
function Install-Update {
  try {
    $r = Get-Content $UpdReady -Raw | ConvertFrom-Json
    $name = [IO.Path]::GetFileName([string]$r.file)
    if ($name -notmatch '^RosaThermalGuard-Setup-(\d+\.\d+\.\d+)\.exe$' -or $matches[1] -ne [string]$r.version) { throw "bad installer name '$name'" }
    if ([version][string]$r.version -le [version]$AppVersion) { throw "v$($r.version) is not newer than v$AppVersion" }
    $exe = Join-Path $UpdDir $name
    if (-not (Test-Path $exe)) { throw "$name is missing" }
    # verify again right before running: hash vs ready.json AND vs the release's SHA256SUMS.txt, size, product
    $hash = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLower()
    $line = Get-Content (Join-Path $UpdDir 'SHA256SUMS.txt') -ErrorAction Stop | Where-Object { $_ -match ('^([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($name) + '\s*$') } | Select-Object -First 1
    $want = if ($line) { ($line -split '\s+')[0].ToLower() } else { '' }
    if ($hash -ne ([string]$r.sha256).ToLower() -or $hash -ne $want) { throw "SHA-256 check failed ($hash)" }
    if ((Get-Item $exe).Length -ne [long]$r.size) { throw 'size changed' }
    if (([string][Diagnostics.FileVersionInfo]::GetVersionInfo($exe).ProductName).Trim() -ne 'Rosa Thermal Guard') { throw 'not the Rosa Thermal Guard installer' }
  } catch {
    Write-Log "update: NOT installing - $($_.Exception.Message); files removed"
    Get-ChildItem $UpdDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    return
  }
  Write-Log "update: installing v$($r.version) (sha256 $hash verified) - restoring fans, power and GPU settings first"
  Restore-All 'installing update'
  @{ from = $AppVersion; to = [string]$r.version; at = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content $UpdDone -Encoding UTF8
  Remove-Item $UpdReady -Force -ErrorAction SilentlyContinue   # one attempt per download
  $cmd = "`"$exe`" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /LOG=`"$(Join-Path $DataDir 'update-install.log')`""
  # started through WMI so it is not part of the scheduled task's job (the installer stops this app, then restarts the task)
  $rc = (Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd }).ReturnValue
  Write-Log "update: installer started (rc=$rc) - the app will restart when it finishes"
}

# ---- structured history for the report window (history\h-YYYYMMDD.csv every 5 s + history\events.jsonl) ----
# CSV columns: unix time, CPU avg, GPU avg, CPU max, GPU max, CPU fan %, GPU fan %, CPU level, GPU throttled, fan level (0 auto, 1 curve, 2 = 100 %), game
# kept 8 days (the report shows up to 7); events.jsonl is trimmed to 7 days; simulated/test data is never recorded
$HistDir = Join-Path $DataDir 'history'
$HIST_SEC = 5
$script:HistAcc = $null; $script:HistAt = Get-Date; $script:HistDay = ''; $script:HistSim = $false
$Inv = [Globalization.CultureInfo]::InvariantCulture
function Hist-Prune {
  try {
    if (-not (Test-Path $HistDir)) { New-Item $HistDir -ItemType Directory -Force | Out-Null }
    Get-ChildItem $HistDir -Filter 'h-*.csv' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-8) } | Remove-Item -Force -ErrorAction SilentlyContinue
    $ev = Join-Path $HistDir 'events.jsonl'
    if (Test-Path $ev) {
      $cut = (Get-Date).AddDays(-7).ToString('s')
      $lines = @([IO.File]::ReadAllLines($ev) | Where-Object { $_.Length -gt 10 -and $_.Substring(6, 19) -ge $cut })
      if ($lines.Count -gt 20000) { $lines = $lines[($lines.Count - 20000)..($lines.Count - 1)] }
      [IO.File]::WriteAllLines($ev, [string[]]$lines)
    }
  } catch {}
}
function Hist-Event([string]$e, $v = $null) {
  if ($TestMode -or $script:HistSim) { return }
  try {
    if (-not (Test-Path $HistDir)) { New-Item $HistDir -ItemType Directory -Force | Out-Null }
    $o = [ordered]@{ t = (Get-Date).ToString('s'); e = $e }; if ($v -ne $null) { $o.v = [string]$v }
    [void](Append-Line (Join-Path $HistDir 'events.jsonl') ($o | ConvertTo-Json -Compress))
  } catch {}
}
# events come from the log messages, so every place that logs an action also feeds the report
function Hist-FromLog([string]$m) {
  switch -Regex ($m) {
    '^RosaThermalGuard started' { Hist-Event 'start'; break }
    '^restore all \(guard exiting\)' { Hist-Event 'stop'; break }
    '^CPU hot: ([\d.]+)' { Hist-Event 'cpuHot' ([int][double]$matches[1]); break }
    '^CPU fast heat: ([\d.]+)' { Hist-Event 'cpuFast' ([int][double]$matches[1]); break }
    '^CPU max processor state -> level 0' { Hist-Event 'cpuFull'; break }
    '^GPU hot: ([\d.]+)' { Hist-Event 'gpuHot' ([int][double]$matches[1]); break }
    '^GPU cool for' { Hist-Event 'gpuCool'; break }
    '^fans: controlled from [\d.]+% -> target ([\d.]+)%' { Hist-Event 'fanTake' $matches[1]; break }
    '^fans: critical' { Hist-Event 'fanCrit'; break }
    '^fan mode restored' { Hist-Event 'fanRelease'; break }
    '^fan watchdog:' { Hist-Event 'failsafe'; break }
    '^game mode ON' { Hist-Event 'gameOn' $script:GameName; break }
    '^game mode OFF' { Hist-Event 'gameOff'; break }
    '^priority (\S+) \(pid \d+\) \S+ -> BelowNormal' { Hist-Event 'prio' $matches[1]; break }
    '^update: now running v(\S+)' { Hist-Event 'update' $matches[1]; break }
    '^resume/stall detected' { Hist-Event 'resume'; break }
  }
}
function Hist-Sample($now, $cpu, $gpu, [bool]$SleepHole = $false) {
  if ($TestMode -or $script:HistSim) { $script:HistAcc = $null; $script:HistAt = $now; return }
  $a = $script:HistAcc
  if (-not $a) { $a = @{ c100 = 0.0; g100 = 0.0; c = 0.0; cn = 0; g = 0.0; gn = 0; cm = $null; gm = $null; f1 = 0.0; f2 = 0.0; fn = 0; lvl = 0; gt = $false; fan = 0; game = $false }; $script:HistAcc = $a }
  $gap = $(if ($script:HistLastT) { ($now - $script:HistLastT).TotalSeconds } else { [double]$PollSeconds }); $script:HistLastT = $now
  $nowC = ($cpu -ne $null -and [double]$cpu -ge 100); $nowG = ($gpu -ne $null -and [double]$gpu -ge 100)
  $a.c100 += Get-HotSeconds $gap $PollSeconds ([bool]$script:HistWasC) $nowC $SleepHole
  $a.g100 += Get-HotSeconds $gap $PollSeconds ([bool]$script:HistWasG) $nowG $SleepHole
  $script:HistWasC = $nowC; $script:HistWasG = $nowG
  if ($cpu -ne $null) { $a.c += $cpu; $a.cn++; if ($a.cm -eq $null -or $cpu -gt $a.cm) { $a.cm = $cpu } }
  if ($gpu -ne $null) { $a.g += $gpu; $a.gn++; if ($a.gm -eq $null -or $gpu -gt $a.gm) { $a.gm = $gpu } }
  if ($FanInfo) { $a.f1 += 100.0 * [Math]::Min(1.0, [double]$FanInfo.Rpm1 / [Math]::Max(1000.0, [double]$FAN_MAXRPM1)); $a.f2 += 100.0 * [Math]::Min(1.0, [double]$FanInfo.Rpm2 / [Math]::Max(1000.0, [double]$FAN_MAXRPM2)); $a.fn++ }
  $a.lvl = [Math]::Max($a.lvl, [int]$CpuLevel); $a.gt = $a.gt -or [bool]$GpuThrottled
  if ($FanBoosted) { $a.fan = [Math]::Max($a.fan, $(if ([int]$FanLevel -ge 2) { 2 } else { 1 })) }
  $a.game = $a.game -or [bool]$GameMode
  if (($now - $script:HistAt).TotalSeconds -lt $HIST_SEC - 0.05) { return }
  $script:HistAt = $now; $script:HistAcc = $null
  $day = $now.ToString('yyyyMMdd'); if ($day -ne $script:HistDay) { $script:HistDay = $day; Hist-Prune }
  $f = { param($v) if ($v -eq $null) { '' } else { ([double]$v).ToString('0.#', $Inv) } }
  $line = '{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10},{11},{12}' -f [long]([DateTimeOffset]$now).ToUnixTimeSeconds(),
    (& $f $(if ($a.cn) { $a.c / $a.cn })), (& $f $(if ($a.gn) { $a.g / $a.gn })), (& $f $a.cm), (& $f $a.gm),
    (& $f $(if ($a.fn) { $a.f1 / $a.fn })), (& $f $(if ($a.fn) { $a.f2 / $a.fn })), $a.lvl, $(if ($a.gt) { 1 } else { 0 }), $a.fan, $(if ($a.game) { 1 } else { 0 }), ([Math]::Round($a.c100)), ([Math]::Round($a.g100))
  [void](Append-Line (Join-Path $HistDir "h-$day.csv") $line)
}

# ---- logging ----
# guard.log is appended line by line (open/append/close) by the guard, the tray and the updater. Rotation renames it
# (the next line of any writer starts a fresh file), gzips it to guard.1.log.gz and shifts older archives; a named mutex
# keeps two rotations from overlapping. Bounded by keepFiles, keepDays and totalMaxMB.
function Rotate-Log([switch]$Force) {
  $m = $null
  try {
    $m = New-Object Threading.Mutex($false, 'Global\RosaThermalGuardLogRotate')
    if (-not $m.WaitOne(3000)) { $m.Dispose(); return }
  } catch { return }
  try {
    $arc = { param($n) Join-Path $DataDir ("guard.{0}.log.gz" -f $n) }
    if ((Test-Path $LogFile) -and ($Force -or (Get-Item $LogFile).Length -ge $LOG_MAX)) {
      $tmp = Join-Path $DataDir 'guard.rotating.log'
      if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
      $moved = $false
      for ($i = 0; $i -lt 10 -and -not $moved; $i++) { try { [IO.File]::Move($LogFile, $tmp); $moved = $true } catch { Start-Sleep -Milliseconds 50 } }
      if ($moved) {
        $last = & $arc $LOG_KEEP; if (Test-Path $last) { Remove-Item $last -Force -ErrorAction SilentlyContinue }
        for ($n = $LOG_KEEP - 1; $n -ge 1; $n--) { $f = & $arc $n; if (Test-Path $f) { Move-Item $f (& $arc ($n + 1)) -Force } }
        $in = [IO.File]::OpenRead($tmp)
        try { $out = [IO.File]::Create((& $arc 1)); try { $gz = New-Object IO.Compression.GZipStream($out, [IO.Compression.CompressionMode]::Compress); try { $in.CopyTo($gz) } finally { $gz.Dispose() } } finally { $out.Dispose() } } finally { $in.Dispose() }
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
      }
    }
    # retention: age, count, total size (oldest first)
    $all = @(Get-ChildItem $DataDir -Filter 'guard.*.log.gz' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
    foreach ($f in $all) { if ($f.LastWriteTime -lt (Get-Date).AddDays(-$LOG_DAYS) -or ($f.Name -match '^guard\.(\d+)\.log\.gz$' -and [int]$matches[1] -gt $LOG_KEEP)) { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue } }
    $all = @(Get-ChildItem $DataDir -Filter 'guard.*.log.gz' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
    $cur = $(if (Test-Path $LogFile) { (Get-Item $LogFile).Length } else { 0 })
    $tot = $cur + ($all | Measure-Object Length -Sum).Sum
    foreach ($f in $all) { if ($tot -le $LOG_TOTAL) { break }; $tot -= $f.Length; Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue }
    # other files that could grow: legacy guard.log.1, the update installer's log
    foreach ($x in 'guard.log.1', 'update-install.log') { $fx = Join-Path $DataDir $x; if ((Test-Path $fx) -and ($x -eq 'guard.log.1' -or (Get-Item $fx).Length -gt 1MB)) { Remove-Item $fx -Force -ErrorAction SilentlyContinue } }
  } catch {} finally { try { $m.ReleaseMutex() } catch {}; $m.Dispose() }
}
# append one line with full sharing, so the tray, the guard and the updater never lock each other out
# (Add-Content opens the file exclusively; with two writers most appends failed in a stress test). AppendData-only access
# makes every write an atomic append at the current end, so concurrent writers never overwrite each other.
function Append-Line([string]$path, [string]$line) {
  for ($i = 0; $i -lt 6; $i++) {
    try { $fs = New-Object IO.FileStream($path, [IO.FileMode]::Append, [Security.AccessControl.FileSystemRights]::AppendData, [IO.FileShare]'ReadWrite, Delete', 4096, [IO.FileOptions]::None); try { $b = [Text.Encoding]::UTF8.GetBytes($line + "`r`n"); $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }; return $true } catch { Start-Sleep -Milliseconds 30 }
  }
  return $false
}
function Write-Log([string]$msg) {
  try {
    if (((Get-Date) - $script:LogCheckAt).TotalSeconds -ge 30) { $script:LogCheckAt = Get-Date; Rotate-Log }
    $line = '{0} {1}{2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), ($(if ($TestMode) { '[TEST] ' } else { '' })), $msg
    [void](Append-Line $LogFile $line)   # the tray and the updater write too
    if ($TestMode -or $Once) { Write-Host $line }
    if (-not $TestMode -and -not $Once -and -not $Restore) { Hist-FromLog $msg }
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
      if ($GM_PROTECT -and $GameMode -and $script:GamePids.ContainsKey($p.Id)) {
        if (-not $script:GameProtectLogged) { Write-Log "priority: $($p.ProcessName) (pid $($p.Id)) is the running game - not lowered [$why]"; $script:GameProtectLogged = $true }
        continue
      }
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
  # no sleep: the previous poll's snapshot is the baseline, so the hottest second is not frozen
  $procs = @(Get-Process -ErrorAction SilentlyContinue)
  $nowMap = @{}
  foreach ($p in $procs) { try { $nowMap[$p.Id] = $p.TotalProcessorTime.TotalMilliseconds } catch {} }
  $prev = $script:CpuSnap; $prevAt = $script:CpuSnapAt
  $script:CpuSnap = $nowMap; $script:CpuSnapAt = Get-Date
  if (-not $prev -or -not $prevAt) { return @() }
  $dt = [Math]::Max(0.5, ($script:CpuSnapAt - $prevAt).TotalSeconds)
  $need = 200.0 * $dt   # 200 ms of CPU time per second of wall time: 20 % of one core, same bar as the old 1 s sample
  $list = foreach ($p in $procs) {
    try {
      if ($p.Id -eq $PID -or $p.SessionId -eq 0 -or $Protected -contains $p.ProcessName) { continue }
      if (-not $prev.ContainsKey($p.Id)) { continue }
      $d = $nowMap[$p.Id] - $prev[$p.Id]
      if ($d -gt $need) { [pscustomobject]@{ P = $p; D = $d } }
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
      $r = Invoke-NvSmi ("-pl {0}" -f $target) 2500
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
    $r = Invoke-NvSmi ("-lgc 0,{0}" -f $mhz) 2500
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
    $r = Invoke-NvSmi ("-pl {0}" -f $Nv.Default) 2500
    if ($r -and $r.Code -eq 0) { $script:Nv.Cur = $Nv.Default; Write-Log "GPU power limit restored to $($Nv.Default)W" }
  } elseif ($State -and $State.GpuDefaultW) {
    $r = Invoke-NvSmi ("-pl {0}" -f $State.GpuDefaultW) 2500
    if ($r -and $r.Code -eq 0) { Write-Log "GPU power limit restored to $($State.GpuDefaultW)W" }
  }
  if (($Nv -and $Nv.LgcMhz) -or ($State -and $State.GpuLgc)) {
    $r = Invoke-NvSmi '-rgc' 2500
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
function Get-FanCurve([string]$name, $def, $from = $cFan) {
  $src = CfgVal $from $name $null
  $pts = New-Object Collections.Generic.List[double[]]
  if ($src) { foreach ($p in $src) { try { $pts.Add([double[]]@([double]$p[0], [Math]::Max(0.0, [Math]::Min(100.0, [double]$p[1])))) } catch {} } }
  if ($pts.Count -lt 2) { $pts.Clear(); foreach ($p in $def) { $pts.Add([double[]]@([double]$p[0], [double]$p[1])) } }
  $pts.Sort([Comparison[double[]]] { param($a, $b) $a[0].CompareTo($b[0]) })
  return , $pts
}
$FAN_CURVE_CPU = Get-FanCurve 'curveCpu' @(@(75, 50), @(80, 60), @(85, 72), @(89, 82), @(92, 88))   # 88 % by 92 C, 100 % only at 95 C
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
$FAN_CRIT_SEC = [Math]::Max(0.0, [double](CfgVal $cFan 'criticalSeconds' 4))   # critical heat must last this long before 100 %
# ---- game mode: earlier, steeper fan curve and a protected game process while a game is running ----
$cGame = CfgVal $cFan 'gameMode' $null
$GM_ON = [bool](CfgVal $cGame 'enabled' $true)
# ---- Rosa Guard suite (v1.3): the IPC worker in the tray process feeds $Sync; nothing here waits on a peer ----
$cSuite = CfgVal $Cfg 'suite' $null
$LEASE_FAN_C = [Math]::Max(0.0, [Math]::Min(10.0, [double](CfgVal $cSuite 'leaseFanShiftC' 5)))   # cooldown lease: fan curve this many C earlier (+1 step)
$PR_DOWN_SEC = 30            # thermal.pressure steps down only after 30 s below (contract 7.4)
$WifiStateFile = Join-Path $DataDir 'wifistate.json'   # original wireless power-saving values while a peer holds a lease (crash-safe)
$WIFI_SUB = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'; $WIFI_SET = '12bbebe6-58d6-4636-95bb-3217ef867c1a'
$script:WifiApplied = 'default'; $script:LeaseNow = $null; $script:PrLevel = 0; $script:PrLowSince = $null
function Get-WifiPs([string]$scheme) {
  $o = powercfg /q $scheme $WIFI_SUB $WIFI_SET 2>$null
  $ac = $o | Select-String 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)' | Select-Object -First 1
  $dc = $o | Select-String 'Current DC Power Setting Index:\s*0x([0-9a-fA-F]+)' | Select-Object -First 1
  if (-not $ac -or -not $dc) { return $null }
  @{ AC = [Convert]::ToInt32($ac.Matches[0].Groups[1].Value, 16); DC = [Convert]::ToInt32($dc.Matches[0].Groups[1].Value, 16) }
}
function Restore-Wifi([string]$why) {
  $script:WifiApplied = 'default'
  if (-not (Test-Path $WifiStateFile)) { return }
  try {
    $w = Get-Content $WifiStateFile -Raw | ConvertFrom-Json
    powercfg /setacvalueindex $w.Scheme $WIFI_SUB $WIFI_SET ([int]$w.AC) 2>$null | Out-Null
    powercfg /setdcvalueindex $w.Scheme $WIFI_SUB $WIFI_SET ([int]$w.DC) 2>$null | Out-Null
    powercfg /setactive $w.Scheme 2>$null | Out-Null
    $now = Get-WifiPs $w.Scheme
    Write-Log "wireless power saving restored ($why): AC=$($now.AC) DC=$($now.DC)"
    Remove-Item $WifiStateFile -Force -ErrorAction SilentlyContinue
  } catch { Write-Log "wireless power saving restore failed: $($_.Exception.Message)" }
}
function Apply-WifiMax([string]$from) {
  $script:WifiApplied = 'max_performance'   # also on failure: no retry storm; the next change of the lease state tries again
  if (Test-Path $WifiStateFile) { return }
  $scheme = ((powercfg /getactivescheme) -replace '.*GUID:\s*([0-9a-fA-F-]{36}).*', '$1').Trim()
  $o = Get-WifiPs $scheme
  if (-not $o) { Write-Log "wireless power saving: this power plan has no such setting - lease from $from not applied"; return }
  @{ Scheme = $scheme; AC = $o.AC; DC = $o.DC } | ConvertTo-Json | Set-Content $WifiStateFile -Encoding ASCII   # saved first: crash-safe
  powercfg /setacvalueindex $scheme $WIFI_SUB $WIFI_SET 0 2>$null | Out-Null
  powercfg /setdcvalueindex $scheme $WIFI_SUB $WIFI_SET 0 2>$null | Out-Null
  powercfg /setactive $scheme 2>$null | Out-Null
  Write-Log "wireless power saving -> Maximum Performance (power lease: $from; was AC=$($o.AC) DC=$($o.DC))"
}$GM_GPU_UTIL = [double](CfgVal $cGame 'gpuUtilPercent' 60)       # GPU load that counts as "busy"
$GM_ENTER = [int](CfgVal $cGame 'enterSeconds' 10)               # game signs for this long -> game mode on
$GM_EXIT = [int](CfgVal $cGame 'exitSeconds' 60)                 # no game signs for this long -> game mode off
$GM_FULLSCREEN = [bool](CfgVal $cGame 'detectFullscreen' $true)
$GM_PROTECT = [bool](CfgVal $cGame 'protectGame' $true)          # never lower the game's priority
$GM_UP_STEP = [Math]::Max(0.5, [double](CfgVal $cGame 'rampUpStepPercent' 3))
$GM_CURVE_CPU = Get-FanCurve 'curveCpu' @(@(65, 45), @(71, 55), @(77, 67), @(83, 78), @(88, 86), @(91, 90)) $cGame   # from Rosa's gaming log: CPU p10 73 / p50 86 C in games, 60-72 C at light load
$GM_CURVE_GPU = Get-FanCurve 'curveGpu' @(@(60, 45), @(66, 54), @(72, 64), @(78, 74), @(83, 82), @(87, 88)) $cGame   # GPU p25 64 / p50 77 C in games, idle p90 ~51 C
$GM_EXES = @(@(CfgVal $cGame 'exeList' @('cs2', 'valorant-win64-shipping', 'fortniteclient-win64-shipping', 'r5apex', 'eldenring', 'cyberpunk2077', 'gta5', 'gta5_enhanced', 'rdr2', 'bg3', 'bg3_dx11', 'fc25', 'fc26', 'bf2042', 'overwatch', 'dota2', 'league of legends', 'rocketleague', 'starfield', 'witcher3', 'helldivers2', 'minecraft.windows')) | ForEach-Object { ([string]$_ -replace '\.exe$', '').ToLower() })
$GM_EXCL = @(@(CfgVal $cGame 'excludeExes' @('explorer', 'shellexperiencehost', 'startmenuexperiencehost', 'searchhost', 'lockapp', 'textinputhost', 'applicationframehost', 'msedge', 'chrome', 'firefox', 'brave', 'opera', 'vlc', 'mpc-hc64', 'potplayermini64', 'ms-teams', 'teams', 'zoom', 'powerpnt')) | ForEach-Object { ([string]$_ -replace '\.exe$', '').ToLower() })
$SimGameFile = Join-Path $Root 'simgame.txt'     # dev test only (allowSimulateFile): name of a process to treat as the game
$script:GameMode = $false; $script:GameName = $null; $script:GamePids = @{}
if (-not ('RtgFg' -as [type])) {
  try {
    Add-Type -ErrorAction Stop -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class RtgFg {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint f);
  [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
  [DllImport("user32.dll")] static extern IntPtr GetShellWindow();
  [DllImport("user32.dll")] static extern IntPtr GetDesktopWindow();
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
  public static bool IsFullscreen(IntPtr h) {
    if (h == IntPtr.Zero || h == GetShellWindow() || h == GetDesktopWindow()) return false;
    RECT r; if (!GetWindowRect(h, out r)) return false;
    MONITORINFO mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
    if (!GetMonitorInfo(MonitorFromWindow(h, 2), ref mi)) return false;
    return r.L <= mi.rcMonitor.L && r.T <= mi.rcMonitor.T && r.R >= mi.rcMonitor.R && r.B >= mi.rcMonitor.B;
  }
}
"@
  } catch { Write-Log "game mode: foreground detection unavailable ($($_.Exception.Message))" }
}
function Get-FgInfo {
  try {
    if (-not ('RtgFg' -as [type])) { return $null }
    $h = [RtgFg]::GetForegroundWindow(); if ($h -eq [IntPtr]::Zero) { return $null }
    [uint32]$fp = 0; [void][RtgFg]::GetWindowThreadProcessId($h, [ref]$fp)
    if ($fp -eq 0 -or $fp -eq $PID) { return $null }
    $p = Get-Process -Id $fp -ErrorAction Stop
    return @{ Pid = [int]$fp; Name = $p.ProcessName; Full = [RtgFg]::IsFullscreen($h) }
  } catch { return $null }
}
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
$script:FanGetI = $null; $script:FanSetI = $null
function Fan-Get([string]$m) {
  # the CIM instance is reused; a call that does not return is abandoned after 2 s and looked up once more
  if (-not $script:FanGetI) { $script:FanGetI = Get-CimInstance -Namespace root\WMI -ClassName GB_WMIACPI_Get -OperationTimeoutSec 2 -ErrorAction Stop }
  try { return (Invoke-CimMethod -InputObject $script:FanGetI -MethodName $m -OperationTimeoutSec 2 -ErrorAction Stop).Data }
  catch { $script:FanGetI = Get-CimInstance -Namespace root\WMI -ClassName GB_WMIACPI_Get -OperationTimeoutSec 2 -ErrorAction Stop; return (Invoke-CimMethod -InputObject $script:FanGetI -MethodName $m -OperationTimeoutSec 2 -ErrorAction Stop).Data }
}
function Fan-Set([string]$m, [int]$v) {
  $script:FanModeAt = [datetime]::MinValue   # any write: re-read the mode registers on the next poll
  if (-not $script:FanSetI) { $script:FanSetI = Get-CimInstance -Namespace root\WMI -ClassName GB_WMIACPI_Set -OperationTimeoutSec 2 -ErrorAction Stop }
  try { [void](Invoke-CimMethod -InputObject $script:FanSetI -MethodName $m -Arguments @{ Data = [byte]$v } -OperationTimeoutSec 2 -ErrorAction Stop) }
  catch { $script:FanSetI = Get-CimInstance -Namespace root\WMI -ClassName GB_WMIACPI_Set -OperationTimeoutSec 2 -ErrorAction Stop; [void](Invoke-CimMethod -InputObject $script:FanSetI -MethodName $m -Arguments @{ Data = [byte]$v } -OperationTimeoutSec 2 -ErrorAction Stop) }
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
  $kc = if ($GameMode) { $GM_CURVE_CPU } else { $FAN_CURVE_CPU }; $kg = if ($GameMode) { $GM_CURVE_GPU } else { $FAN_CURVE_GPU }
  return [Math]::Max((Curve-Pct $kc $c), (Curve-Pct $kg $g))
}
function Fan-Critical($cpu, $gpu) { ($cpu -ne $null -and $cpu -ge $FAN_FULL_CPU) -or ($gpu -ne $null -and $gpu -ge $FAN_FULL_GPU) }
function Fan-ObservedPct {
  if (-not $FanInfo) { return $null }
  return 100.0 * [Math]::Min(1.0, [Math]::Max([double]$FanInfo.Rpm1 / [Math]::Max(1000, $FAN_MAXRPM1), [double]$FanInfo.Rpm2 / [Math]::Max(1000, $FAN_MAXRPM2)))
}
function Fan-Bucket($t) { [string]([int]([Math]::Floor([double]$t / 5.0) * 5)) }
function Learn-AutoFan($cpu) {
  # only while the firmware curve is in charge and nothing else forces the fans
  if (-not $script:FanFresh) { return }
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
$script:FanModeCache = $null; $script:FanModeAt = [datetime]::MinValue; $script:FanModeFresh = $false
function Read-Fan([switch]$Full) {
  if (-not $FanOk) { return }
  if ($script:FanWorkerOn) { Sync-FanBus; return }
  try {
    # RPM is read every poll; the 4-5 mode registers only every 5 s (or right after we changed something) - keeps WMI traffic low at a 1 s poll
    $script:FanModeFresh = $false
    if ($Full -or -not $script:FanModeCache -or ((Get-Date) - $script:FanModeAt).TotalSeconds -ge 5) { $script:FanModeCache = Get-FanMode; $script:FanModeAt = Get-Date; $script:FanModeFresh = $true }
    $m = $script:FanModeCache
    $mode = if ($m.Fixed -eq 1 -and $FanBoosted) { $(if ($m.Speed -ge $FAN_DUTY - 2) { 'max' } else { 'boost' }) } elseif ($m.Fixed -eq 1 -and $m.Speed -ge $FAN_DUTY - 2) { 'max' } elseif ($m.Fixed -eq 1) { 'fixed' } elseif ($m.Auto -eq 1) { 'auto' } else { 'normal' }
    $script:FanInfo = @{ Rpm1 = (Fan-Rpm 'getRpm1'); Rpm2 = (Fan-Rpm 'getRpm2'); Mode = $mode; Fixed = $m.Fixed; Speed = $m.Speed }
    $script:FanErr = 0; $script:FanFresh = $true
  } catch { $script:FanInfo = $null; $script:FanFresh = $false; if ($FanBoosted) { Fan-Fault "read: $($_.Exception.Message)" } }
}
# watchdog: if the vendor WMI calls keep failing while we hold the fans, hand them back to GIGABYTE auto mode
$script:FanErr = 0
function Fan-Fault([string]$msg) {
  $script:FanErr++
  Write-Log "fan WMI error #$($FanErr): $msg"
  if ($FanErr -ge 3) { Fan-Failsafe }
}
function Fan-Failsafe {
  if ($script:FanFailSent) { return }
  $script:FanFailSent = $true
  $holding = [bool]($script:FanBoosted -or (Test-Path $FanStateFile))
  if (-not $holding) {
    Write-Log 'fan watchdog: WMI calls keep failing - fans are not held, leaving firmware auto and turning fan control off for this session'
    $script:FanOk = $false
    if ($script:FanBus -and $script:FanLock) {
      [System.Threading.Monitor]::Enter($script:FanLock)
      try { $script:FanBus.Stop = $true } finally { [System.Threading.Monitor]::Exit($script:FanLock) }
    }
    $script:FanWorkerOn = $false
    return
  }
  Write-Log 'fan watchdog: WMI calls keep failing - handing the fans back to GIGABYTE auto mode and turning fan control off for this session'
  if ($script:FanWorkerOn) {
    $script:FanWaitMeta = @{ Type = 'failsafe' }
    if (Submit-Fan 'failsafe' 0 '' -Preempt) { return }
  }
  if ($script:FanHandle -and -not $script:FanHandle.IsCompleted) {
    Write-Log 'fan watchdog: a WMI call is still running - leaving fanstate.json for the next start'
    $script:FanOk = $false; return
  }
  $ok = $true
  foreach ($c in @(@('SetCurrentFanStep', 0), @('SetFixedFanStatus', 0), @('SetStepFanStatus', 0), @('SetAutoFanStatus', 1))) { try { Fan-Set $c[0] $c[1] } catch { $ok = $false; Write-Log "  $($c[0]) failed: $($_.Exception.Message)" } }
  if ($ok) { Remove-Item $FanStateFile -Force -ErrorAction SilentlyContinue }
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
  if ($script:FanPending) { return }
  if ($script:FanRetryAt -and (Get-Date) -lt $script:FanRetryAt) { return }
  if ($script:FanWorkerOn) {
    $script:FanWaitMeta = @{ Type = 'take'; Why = $why; Start = $startPct; Target = $target }
    [void](Submit-Fan 'take' $startPct '' -Preempt:($startPct -ge 99.5))
    return
  }
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
  # one ramp step toward the target (called every poll). A step already in flight waits; the ramp never runs faster than this.
  if (-not $FanBoosted -or $FanPct -eq $null -or $FanTarget -eq $null) { return }
  if ([Math]::Abs($FanPct - $FanTarget) -lt 0.25) { return }
  if ($script:FanPending) { return }
  if (((Get-Date) - $FanRampLast).TotalSeconds -lt $FAN_RAMP_SEC - 0.3) { return }
  $n = if ($FanPct -lt $FanTarget) { [Math]::Min($FanTarget, $FanPct + $(if ($GameMode) { $GM_UP_STEP } else { $FAN_UP_STEP })) } else { [Math]::Max($FanTarget, $FanPct - $FAN_DOWN_STEP) }
  if ($script:FanWorkerOn) {
    $script:FanWaitMeta = @{ Type = 'apply'; Pct = $n }
    [void](Submit-Fan 'apply' $n '')
    return
  }
  try { Fan-Apply $n; $script:FanRampLast = Get-Date; $script:FanLevel = $(if ($n -ge 99.5) { 2 } else { 1 }) } catch { Fan-Fault "step: $($_.Exception.Message)" }
}
function Restore-Fan([string]$why, [switch]$Abrupt) {
  if ($script:FanWorkerOn) {
    if ($script:FanPending) { return }
    if (-not $script:FanBoosted -and -not (Test-Path $FanStateFile)) { $script:FanLevel = 0; return }
    $goal = Auto-Pct $FanLastCpu
    $script:FanWaitMeta = @{ Type = $(if ($Abrupt) { 'restore' } else { 'restoreSoft' }); Why = $why }
    [void](Submit-Fan $(if ($Abrupt) { 'restore' } else { 'restoreSoft' }) $goal '')
    return
  }
  if ($script:FanHandle -and -not $script:FanHandle.IsCompleted) {
    Write-Log "fan restore deferred ($why) - a WMI call is still running; the next start restores from fanstate.json"
    return
  }
  if (-not (Test-Path $FanStateFile)) { $script:FanBoosted = $false; $script:FanLevel = 0; return }
  try {
    # soft landing: never drop from a high duty to auto in one jump
    if (-not $Abrupt) {
      $cur = $FanPct
      try {
        $m = Get-FanMode
        if ($m.Fixed -eq 1) { $live = 100.0 * $m.Speed / [Math]::Max(1, $FAN_DUTY); if ($cur -eq $null -or $live -lt $cur) { $cur = $live } }
      } catch {}
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

function Restore-All([string]$why, [switch]$SkipFan) {
  Write-Log "restore all ($why)"
  if ($State) {
    foreach ($a in $State.Orig.Keys) { $o = $State.Orig[$a]; Set-ProcMax $State.Scheme $a $o.AC $o.DC }
    powercfg /setactive $State.Scheme 2>$null | Out-Null
    $now = Get-ProcMax $State.Scheme 'PROCTHROTTLEMAX'
    Write-Log "CPU max processor state restored: AC=$($now.AC) DC=$($now.DC)"
  }
  Restore-Gpu
  Restore-Priorities
  if (-not $SkipFan -and $why -ne 'cooled down') { Restore-Fan $why }   # fans have their own, lower restore threshold
  $script:CpuLevel = 0
  Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
  $script:State = $null
}

# ---- sensors ----
$script:Computer = $null
$script:HasNvidia = $false
function Open-Sensors {
  Add-Type -Path $LhmDll -ErrorAction Stop
  # LHM reads each core by moving its thread from core to core. At the default 15.6 ms system timer that cost 0.4-0.9 s per
  # read on this 24-thread CPU (measured), at 1 ms about 0.06 s. Windows 11 scopes timeBeginPeriod to this process, and
  # Windows undoes it when the process ends.
  try {
    if (-not ('Rtg.RtgTimer' -as [type])) { Add-Type -Name RtgTimer -Namespace Rtg -MemberDefinition '[DllImport("winmm.dll")] public static extern uint timeBeginPeriod(uint p);' -ErrorAction Stop }
    if (-not $script:TimerRaised) { [void][Rtg.RtgTimer]::timeBeginPeriod(1); $script:TimerRaised = $true }
  } catch {}
  $c = New-Object LibreHardwareMonitor.Hardware.Computer
  $c.IsCpuEnabled = $true; $c.IsGpuEnabled = $true
  $c.Open()
  $script:Computer = $c
  $script:HasNvidia = [bool]($c.Hardware | Where-Object { $_.HardwareType -eq 'GpuNvidia' })
  Write-Log ("sensors: " + (($c.Hardware | ForEach-Object { "$($_.HardwareType)=$($_.Name)" }) -join '; '))
}
function Find-TempSensors {
  # walk all sensors once and keep only the ones Read-Temps needs (CPU package/core max, GPU core/hot spot, GPU core load)
  $list = New-Object Collections.Generic.List[object]
  foreach ($h in $Computer.Hardware) {
    $h.Update()
    foreach ($hw in @($h) + @($h.SubHardware)) {
      if ($hw -ne $h) { $hw.Update() }
      foreach ($s in $hw.Sensors) {
        $k = $null
        if ($h.HardwareType -eq 'Cpu' -and $s.SensorType -eq 'Temperature' -and ($s.Name -eq 'CPU Package' -or $s.Name -eq 'Core Max')) { $k = 'C' }
        elseif ($h.HardwareType -eq 'GpuNvidia' -or $h.HardwareType -eq 'GpuAmd') {
          if ($s.SensorType -eq 'Temperature' -and ($s.Name -eq 'GPU Core' -or $s.Name -eq 'GPU Hot Spot')) { $k = 'G' }
          elseif ($s.SensorType -eq 'Load' -and $s.Name -eq 'GPU Core') { $k = 'L' }
        }
        if ($k) { $list.Add(@{ K = $k; S = $s }) }
      }
    }
  }
  $script:TempSensors = $list
  $script:TempHw = @($Computer.Hardware | Where-Object { $_.HardwareType -eq 'Cpu' -or $_.HardwareType -eq 'GpuNvidia' -or $_.HardwareType -eq 'GpuAmd' })
  $script:TempNullN = 0
}
function Read-Temps {
  if ($script:Sense) {
    $s = $script:Sense.Sample
    if (-not $s) { return @{ Cpu = $null; Gpu = $null; GpuLoad = $null; Age = 999 } }
    return @{ Cpu = $s.Cpu; Gpu = $s.Gpu; GpuLoad = $s.Load; Age = ((Get-Date) - [datetime]$s.At).TotalSeconds }
  }
  # fast path (every poll): update only the CPU/GPU hardware and read the cached sensors
  if ($script:TempSensors -and $script:TempSensors.Count -gt 0) {
    foreach ($h in $script:TempHw) { $h.Update(); foreach ($sh in $h.SubHardware) { $sh.Update() } }
    $cpu = $null; $gpu = $null; $gl = $null
    foreach ($e in $script:TempSensors) {
      $v = $e.S.Value; if ($v -eq $null) { continue }; $v = [double]$v
      switch ($e.K) { 'C' { if ($cpu -eq $null -or $v -gt $cpu) { $cpu = $v } } 'G' { if ($gpu -eq $null -or $v -gt $gpu) { $gpu = $v } } 'L' { if ($gl -eq $null -or $v -gt $gl) { $gl = $v } } }
    }
    if ($cpu -ne $null) { $script:TempNullN = 0; return @{ Cpu = $cpu; Gpu = $gpu; GpuLoad = $gl; Age = 0 } }
    if (++$script:TempNullN -lt 5) { return @{ Cpu = $cpu; Gpu = $gpu; GpuLoad = $gl; Age = 0 } }
    $script:TempSensors = $null   # CPU sensor gone for 5 polls: rescan below
  }
  try { Find-TempSensors } catch {}
  $cpu = $null; $gpu = $null; $gl = $null
  foreach ($h in $Computer.Hardware) {
    $h.Update()
    $sens = @($h.Sensors) + @($h.SubHardware | ForEach-Object { $_.Update(); $_.Sensors })
    foreach ($s in $sens) {
      if ($s.SensorType -eq 'Load' -and $s.Value -ne $null -and $s.Name -eq 'GPU Core' -and ($h.HardwareType -eq 'GpuNvidia' -or $h.HardwareType -eq 'GpuAmd')) { if ($gl -eq $null -or [double]$s.Value -gt $gl) { $gl = [double]$s.Value } }
      if ($s.SensorType -ne 'Temperature' -or $s.Value -eq $null -or $s.Name -like '*Distance*') { continue }
      $v = [double]$s.Value
      if ($h.HardwareType -eq 'Cpu' -and ($s.Name -eq 'CPU Package' -or $s.Name -eq 'Core Max')) { if ($cpu -eq $null -or $v -gt $cpu) { $cpu = $v } }
      elseif ($h.HardwareType -eq 'GpuNvidia' -or $h.HardwareType -eq 'GpuAmd') {
        if ($s.Name -eq 'GPU Core' -or $s.Name -eq 'GPU Hot Spot') { if ($gpu -eq $null -or $v -gt $gpu) { $gpu = $v } }
      }
    }
  }
  return @{ Cpu = $cpu; Gpu = $gpu; GpuLoad = $gl; Age = 0 }
}

# ---- workers: LHM and fan WMI stay off the control thread. One command in flight; a critical 100 % may preempt it. ----
$script:Sense = $null; $script:SenseStop = $null; $script:SensePs = $null; $script:SenseRs = $null; $script:SenseHandle = $null
$script:FanBus = $null; $script:FanLock = $null; $script:FanPs = $null; $script:FanRs = $null; $script:FanHandle = $null
$script:FanWorkerOn = $false; $script:FanPending = $false; $script:FanWaitId = 0; $script:FanWaitMeta = $null
$script:FanFresh = $false; $script:FanRetryAt = [datetime]::MinValue; $script:FanFailSent = $false; $script:FanSeenRead = 0; $script:SeenModeAt = $null
function Submit-Fan([string]$type, [double]$pct, [string]$json, [switch]$Preempt) {
  if (-not $script:FanWorkerOn -or -not $script:FanBus -or -not $script:FanLock) { return $false }
  if ($script:FanPending -and -not $Preempt) { return $false }
  [System.Threading.Monitor]::Enter($script:FanLock)
  try {
    $script:FanBus.CmdJson = $json
    $script:FanBus.CmdPct = $pct
    $script:FanBus.CmdType = $type
    $script:FanBus.CmdErr = ''
    $script:FanBus.CmdId = [int]$script:FanBus.CmdId + 1
    $script:FanWaitId = [int]$script:FanBus.CmdId
  } finally { [System.Threading.Monitor]::Exit($script:FanLock) }
  $script:FanPending = $true
  return $true
}
function Fan-ModeName($m) {
  if ($m.Fixed -eq 1 -and $script:FanBoosted) { if ($m.Speed -ge $FAN_DUTY - 2) { return 'max' } else { return 'boost' } }
  if ($m.Fixed -eq 1 -and $m.Speed -ge $FAN_DUTY - 2) { return 'max' }
  if ($m.Fixed -eq 1) { return 'fixed' }
  if ($m.Auto -eq 1) { return 'auto' }
  return 'normal'
}
function Complete-FanRestore([string]$why, [string]$result) {
  if ($script:FanBoosted) { $script:FanSwitchAt = Get-Date }
  $script:FanBoosted = $false; $script:FanLevel = 0; $script:FanLevelSince = $null
  $script:FanPct = $null; $script:FanTarget = $null
  Write-Log ("fan mode restored ({0}): {1}" -f $why, $(if ($result) { $result } else { 'previous mode' }))
  try { if ($FanAuto.Count -gt 0) { $FanAuto | ConvertTo-Json | Set-Content $FanAutoFile -Encoding UTF8 } } catch {}
}
function Sync-FanBus {
  if (-not $script:FanBus -or -not $script:FanLock) { return }
  $done = 0; $err = ''; $applied = $null; $snap = $null; $rf = 0; $result = ''
  [System.Threading.Monitor]::Enter($script:FanLock)
  try {
    $done = [int]$script:FanBus.DoneId; $err = [string]$script:FanBus.CmdErr; $applied = $script:FanBus.AppliedPct
    $snap = $script:FanBus.Snap; $rf = [int]$script:FanBus.ReadFail; $result = [string]$script:FanBus.Result
  } finally { [System.Threading.Monitor]::Exit($script:FanLock) }
  if ($script:FanPending -and $done -eq $script:FanWaitId -and $done -ne 0) {
    $script:FanPending = $false
    $meta = $script:FanWaitMeta
    if ($err) {
      if ($meta -and [string]$meta.Type -eq 'take') { $script:FanRetryAt = (Get-Date).AddSeconds(5) }
      Fan-Fault $err
    } elseif ($meta) {
      switch ([string]$meta.Type) {
        'apply' {
          $script:FanPct = [double]$applied; $script:FanRampLast = Get-Date
          $script:FanLevel = $(if ($script:FanPct -ge 99.5) { 2 } else { 1 }); $script:FanModeAt = [datetime]::MinValue
        }
        'take' {
          $script:FanBoosted = $true; $script:FanPct = [double]$meta.Start; $script:FanTarget = [double]$meta.Target
          $script:FanRampLast = Get-Date; $script:FanSwitchAt = Get-Date; $script:FanRaiseAt = Get-Date; $script:FanLevelSince = Get-Date
          $script:FanLevel = $(if ([double]$meta.Start -ge 99.5) { 2 } else { 1 }); $script:FanRetryAt = [datetime]::MinValue
          Write-Log ("fans: controlled from {0:N0}% -> target {1:N0}% ({2})" -f $meta.Start, $meta.Target, $meta.Why)
        }
        'reassert' { $script:FanModeAt = [datetime]::MinValue }
        'restore' { Complete-FanRestore $meta.Why $result }
        'restoreSoft' { Complete-FanRestore $meta.Why $result }
        'failsafe' {
          $script:FanOk = $false; $script:FanBoosted = $false; $script:FanLevel = 0
          $script:FanPct = $null; $script:FanTarget = $null; $script:FanInfo = $null; $script:FanWorkerOn = $false
          try { $script:FanBus.Stop = $true } catch {}
        }
      }
    }
  }
  if ($snap) {
    $age = ((Get-Date) - [datetime]$snap.At).TotalSeconds
    $script:FanFresh = ($age -ge 0 -and $age -le $IO_STALE)
    if ($snap.ModeAt -and ($script:SeenModeAt -eq $null -or $snap.ModeAt -ne $script:SeenModeAt)) { $script:SeenModeAt = $snap.ModeAt; $script:FanModeFresh = $true } else { $script:FanModeFresh = $false }
    $script:FanInfo = @{ Rpm1 = $snap.Rpm1; Rpm2 = $snap.Rpm2; Mode = (Fan-ModeName $snap); Fixed = $snap.Fixed; Speed = $snap.Speed }
  } else { $script:FanFresh = $false }
  if ($rf -eq 0) { $script:FanSeenRead = 0 }
  else { while ($rf -gt $script:FanSeenRead -and -not $script:FanFailSent) { $script:FanSeenRead++; Fan-Fault 'RPM read failed' } }
}
function Start-SensorWorker {
  if (-not $script:Computer) { return }
  if ($script:SenseHandle -and -not $script:SenseHandle.IsCompleted) { return }
  $stop = [hashtable]::Synchronized(@{ Stop = $false })
  $bag = [hashtable]::Synchronized(@{ Sample = $null })
  $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.Open()
  $ps = [powershell]::Create(); $ps.Runspace = $rs
  [void]$ps.AddScript({
    param($Computer, $Bag, $Stop)
    $sensors = $null; $hw = $null; $nullN = 0
    while (-not $Stop.Stop) {
      $t0 = Get-Date
      try {
        if (-not $sensors -or $sensors.Count -eq 0 -or $nullN -ge 5) {
          $sensors = New-Object Collections.Generic.List[object]
          $hw = New-Object Collections.Generic.List[object]
          foreach ($h in @($Computer.Hardware)) {
            if ($h.HardwareType -ne 'Cpu' -and $h.HardwareType -ne 'GpuNvidia' -and $h.HardwareType -ne 'GpuAmd') { continue }
            $h.Update(); [void]$hw.Add($h)
            foreach ($sh in @($h.SubHardware)) { $sh.Update() }
            foreach ($hw2 in @($h) + @($h.SubHardware)) {
              foreach ($s in @($hw2.Sensors)) {
                $k = $null
                if ($h.HardwareType -eq 'Cpu' -and $s.SensorType -eq 'Temperature' -and ($s.Name -eq 'CPU Package' -or $s.Name -eq 'Core Max')) { $k = 'C' }
                elseif ($h.HardwareType -eq 'GpuNvidia' -or $h.HardwareType -eq 'GpuAmd') {
                  if ($s.SensorType -eq 'Temperature' -and ($s.Name -eq 'GPU Core' -or $s.Name -eq 'GPU Hot Spot')) { $k = 'G' }
                  elseif ($s.SensorType -eq 'Load' -and $s.Name -eq 'GPU Core') { $k = 'L' }
                }
                if ($k) { $sensors.Add(@{ K = $k; S = $s }) }
              }
            }
          }
          $nullN = 0
        } else { foreach ($h in $hw) { $h.Update(); foreach ($sh in @($h.SubHardware)) { $sh.Update() } } }
        $cpu = $null; $gpu = $null; $gl = $null
        foreach ($e in $sensors) {
          $v = $e.S.Value; if ($v -eq $null) { continue }; $v = [double]$v
          switch ($e.K) { 'C' { if ($cpu -eq $null -or $v -gt $cpu) { $cpu = $v } } 'G' { if ($gpu -eq $null -or $v -gt $gpu) { $gpu = $v } } 'L' { if ($gl -eq $null -or $v -gt $gl) { $gl = $v } } }
        }
        if ($cpu -eq $null) { $nullN++ } else { $nullN = 0 }
        $Bag.Sample = [pscustomobject]@{ Cpu = $cpu; Gpu = $gpu; Load = $gl; At = (Get-Date) }
      } catch {}
      $left = [Math]::Max(40, 1000 - [int]((Get-Date) - $t0).TotalMilliseconds); $n = 0
      while ($n -lt $left -and -not $Stop.Stop) { Start-Sleep -Milliseconds 40; $n += 40 }
    }
  }).AddArgument($script:Computer).AddArgument($bag).AddArgument($stop)
  $script:Sense = $bag; $script:SenseStop = $stop; $script:SensePs = $ps; $script:SenseRs = $rs
  $script:SenseHandle = $ps.BeginInvoke()
}
function Stop-SensorWorker([int]$waitMs = 3000) {
  if ($script:SenseStop) { $script:SenseStop.Stop = $true }
  if ($script:SenseHandle -and -not $script:SenseHandle.IsCompleted) { [void]$script:SenseHandle.AsyncWaitHandle.WaitOne($waitMs) }
  if ($script:SenseHandle -and $script:SenseHandle.IsCompleted) {
    $script:Sense = $null
    try { $script:SensePs.Dispose() } catch {}
    try { $script:SenseRs.Close(); $script:SenseRs.Dispose() } catch {}
    $script:SenseHandle = $null; $script:SensePs = $null; $script:SenseRs = $null
  }
}
function Start-FanWorker {
  if (-not $script:FanOk) { return }
  if ($script:FanHandle -and -not $script:FanHandle.IsCompleted) { $script:FanWorkerOn = $true; return }
  $lock = New-Object object
  $bus = [hashtable]::Synchronized(@{ CmdId = 0; CmdType = ''; CmdPct = 0.0; CmdJson = ''; CmdErr = ''; DoneId = 0; AppliedPct = $null; Stop = $false; Snap = $null; ReadFail = 0; Result = '' })
  $cfg = @{ Duty = [int]$FAN_DUTY; Down = [double]$FAN_DOWN_STEP; State = [string]$FanStateFile }
  $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.Open()
  $ps = [powershell]::Create(); $ps.Runspace = $rs
  [void]$ps.AddScript({
    param($Bus, $Lock, $Cfg)
    $script:getI = $null; $script:setI = $null; $script:fixed = 0; $script:step = 0; $script:auto = 0; $script:speed = 0; $script:gpuDuty = $null; $script:modeAt = [datetime]::MinValue
    $WGet = {
      param([string]$m)
      if (-not $script:getI) { $script:getI = Get-CimInstance -Namespace root\WMI -ClassName GB_WMIACPI_Get -OperationTimeoutSec 2 -ErrorAction Stop }
      try { return (Invoke-CimMethod -InputObject $script:getI -MethodName $m -OperationTimeoutSec 2 -ErrorAction Stop).Data }
      catch { $script:getI = Get-CimInstance -Namespace root\WMI -ClassName GB_WMIACPI_Get -OperationTimeoutSec 2 -ErrorAction Stop; return (Invoke-CimMethod -InputObject $script:getI -MethodName $m -OperationTimeoutSec 2 -ErrorAction Stop).Data }
    }
    $WSet = {
      param([string]$m, [int]$v)
      if (-not $script:setI) { $script:setI = Get-CimInstance -Namespace root\WMI -ClassName GB_WMIACPI_Set -OperationTimeoutSec 2 -ErrorAction Stop }
      try { [void](Invoke-CimMethod -InputObject $script:setI -MethodName $m -Arguments @{ Data = [byte]$v } -OperationTimeoutSec 2 -ErrorAction Stop) }
      catch { $script:setI = Get-CimInstance -Namespace root\WMI -ClassName GB_WMIACPI_Set -OperationTimeoutSec 2 -ErrorAction Stop; [void](Invoke-CimMethod -InputObject $script:setI -MethodName $m -Arguments @{ Data = [byte]$v } -OperationTimeoutSec 2 -ErrorAction Stop) }
    }
    $Duty = { param([double]$p) [int][Math]::Round([int]$Cfg.Duty * [Math]::Max(0.0, [Math]::Min(100.0, $p)) / 100.0) }
    $Rpm = { param([string]$m) $v = [int](& $WGet $m); return ((($v -band 0xFF) -shl 8) -bor ($v -shr 8)) }
    $Newer = { param([int]$id) [System.Threading.Monitor]::Enter($Lock); try { return (([int]$Bus.CmdId -ne $id) -or [bool]$Bus.Stop) } finally { [System.Threading.Monitor]::Exit($Lock) } }
    $Finish = {
      param([int]$id, [string]$err, $applied, [string]$result)
      [System.Threading.Monitor]::Enter($Lock)
      try { if ([int]$Bus.CmdId -eq $id) { if ($applied -ne $null) { $Bus.AppliedPct = [double]$applied }; $Bus.CmdErr = [string]$err; $Bus.Result = [string]$result; $Bus.DoneId = $id } }
      finally { [System.Threading.Monitor]::Exit($Lock) }
    }
    $ReadMode = {
      $script:fixed = [int](& $WGet 'GetFixedFanStatus'); $script:step = [int](& $WGet 'GetStepFanStatus')
      $script:auto = [int](& $WGet 'GetAutoFanStatus'); $script:speed = [int](& $WGet 'GetFixedFanSpeed'); $script:gpuDuty = $null
      if ($script:fixed -eq 1) { $script:gpuDuty = [int](& $WGet 'GetGPUFanDuty') }
      $script:modeAt = Get-Date
    }
    $SavePrev = {
      if (Test-Path $Cfg.State) { return }
      $prev = @{ Fixed = $script:fixed; Step = $script:step; Auto = $script:auto; Speed = $script:speed }
      if ($script:gpuDuty -ne $null) { $prev.GpuDuty = $script:gpuDuty }
      $prev | ConvertTo-Json | Set-Content $Cfg.State -Encoding UTF8
    }
    $ApplyDuty = { param([double]$p) $d = & $Duty $p; & $WSet 'SetFixedFanSpeed' $d; & $WSet 'SetGPUFanDuty' $d }
    $RestoreRegs = {
      if (-not (Test-Path $Cfg.State)) { return 'no saved mode' }
      $p = Get-Content $Cfg.State -Raw | ConvertFrom-Json
      & $WSet 'SetCurrentFanStep' 0
      & $WSet 'SetFixedFanStatus' ([int]$p.Fixed); & $WSet 'SetStepFanStatus' ([int]$p.Step); & $WSet 'SetFixedFanSpeed' ([int]$p.Speed)
      if ([int]$p.Fixed -eq 1 -and $p.PSObject.Properties.Name -contains 'GpuDuty' -and $p.GpuDuty -ne $null) { & $WSet 'SetGPUFanDuty' ([int]$p.GpuDuty) }
      & $WSet 'SetAutoFanStatus' ([int]$p.Auto)
      Remove-Item $Cfg.State -Force -ErrorAction SilentlyContinue
      return ("fixed={0} step={1} auto={2} speed={3}" -f $p.Fixed, $p.Step, $p.Auto, $p.Speed)
    }
    $seen = 0
    $nextRpm = [datetime]::MinValue
    while ($true) {
      $stop = $false; $id = 0; $type = ''; $pct = 0.0
      [System.Threading.Monitor]::Enter($Lock)
      try { $stop = [bool]$Bus.Stop; $id = [int]$Bus.CmdId; $type = [string]$Bus.CmdType; $pct = [double]$Bus.CmdPct } finally { [System.Threading.Monitor]::Exit($Lock) }
      if ($stop -and $id -eq $seen) { break }
      $abort = $false
      if ($id -ne $seen -and $type) {
        $seen = $id; $result = ''; $applied = $null
        try {
          switch ($type) {
            'apply' { & $ApplyDuty $pct; $applied = $pct; & $ReadMode }
            'take' { & $ReadMode; & $SavePrev; & $WSet 'SetCurrentFanStep' 0; & $WSet 'SetAutoFanStatus' 0; & $ApplyDuty $pct; & $WSet 'SetStepFanStatus' 1; & $WSet 'SetFixedFanStatus' 1; $applied = $pct; & $ReadMode }
            'reassert' { & $WSet 'SetCurrentFanStep' 0; & $WSet 'SetAutoFanStatus' 0; & $ApplyDuty $pct; & $WSet 'SetStepFanStatus' 1; & $WSet 'SetFixedFanStatus' 1; $applied = $pct; & $ReadMode }
            'restoreSoft' {
              & $ReadMode
              $cur = $(if ($script:fixed -eq 1) { 100.0 * $script:speed / [Math]::Max(1, [int]$Cfg.Duty) } else { $pct })
              $steps = [Math]::Max(1, [int][Math]::Ceiling([Math]::Max(0.0, $cur - $pct) / [Math]::Max(0.5, [double]$Cfg.Down)))
              $pause = [Math]::Min(1000, [Math]::Max(200, [int](12000 / $steps)))
              while ($cur -gt $pct + 0.25) {
                if (& $Newer $id) { $abort = $true; break }
                $cur = [Math]::Max($pct, $cur - [double]$Cfg.Down); & $ApplyDuty $cur
                $left = $pause
                while ($left -gt 0) { if (& $Newer $id) { $abort = $true; break }; $slice = [Math]::Min(100, $left); Start-Sleep -Milliseconds $slice; $left -= $slice }
                if ($abort) { break }
              }
              if (-not $abort) { $result = & $RestoreRegs; & $ReadMode }
            }
            'restore' { $result = & $RestoreRegs; & $ReadMode }
            'failsafe' {
              & $WSet 'SetCurrentFanStep' 0; & $WSet 'SetFixedFanStatus' 0; & $WSet 'SetStepFanStatus' 0; & $WSet 'SetAutoFanStatus' 1
              if (Test-Path $Cfg.State) { Remove-Item $Cfg.State -Force -ErrorAction SilentlyContinue }
              $result = 'auto'
            }
          }
          if (-not $abort) { & $Finish $id '' $applied $result }
        } catch { if (-not $abort) { & $Finish $id $_.Exception.Message $null '' } }
      }
      # RPM is asked of the EC once a second, the same rate as before. A waiting command is still picked up within 100 ms.
      # Reading RPM on every pass flooded GIGABYTE's controller (about ten calls a second) even while fans stayed on auto.
      if ((Get-Date) -ge $nextRpm) {
        $nextRpm = (Get-Date).AddSeconds(1)
        try {
          $r1 = & $Rpm 'getRpm1'; $r2 = & $Rpm 'getRpm2'
          if ($script:modeAt -eq [datetime]::MinValue -or ((Get-Date) - $script:modeAt).TotalSeconds -ge 5) { & $ReadMode }
          $snap = [pscustomobject]@{ At = (Get-Date); ModeAt = $script:modeAt; Rpm1 = $r1; Rpm2 = $r2; Fixed = $script:fixed; Step = $script:step; Auto = $script:auto; Speed = $script:speed; GpuDuty = $script:gpuDuty }
          [System.Threading.Monitor]::Enter($Lock); try { $Bus.Snap = $snap; $Bus.ReadFail = 0 } finally { [System.Threading.Monitor]::Exit($Lock) }
        } catch {
          [System.Threading.Monitor]::Enter($Lock); try { $Bus.ReadFail = [int]$Bus.ReadFail + 1 } finally { [System.Threading.Monitor]::Exit($Lock) }
        }
      }
      if (& $Newer $seen) { } else { Start-Sleep -Milliseconds 100 }
    }
  }).AddArgument($bus).AddArgument($lock).AddArgument($cfg)
  $script:FanBus = $bus; $script:FanLock = $lock; $script:FanPs = $ps; $script:FanRs = $rs
  $script:FanHandle = $ps.BeginInvoke(); $script:FanWorkerOn = $true
}
function Start-PowerWatch {
  try { Register-CimIndicationEvent -ClassName Win32_PowerManagementEvent -SourceIdentifier RosaThermalPower -ErrorAction Stop | Out-Null }
  catch { Write-Log "power resume watch unavailable: $($_.Exception.Message)" }
}
function Test-PowerResume {
  $hit = $false
  try {
    foreach ($e in @(Get-Event -SourceIdentifier RosaThermalPower -ErrorAction SilentlyContinue)) {
      try { $t = [int]$e.SourceEventArgs.NewEvent.EventType; if ($t -eq 7 -or $t -eq 18) { $hit = $true } } catch {}
      Remove-Event -EventIdentifier $e.EventIdentifier -ErrorAction SilentlyContinue
    }
  } catch {}
  return $hit
}
function Stop-GuardIo {
  if ($script:SenseStop) { $script:SenseStop.Stop = $true }
  if ($script:FanBus -and $script:FanLock) {
    [System.Threading.Monitor]::Enter($script:FanLock)
    try { $script:FanBus.Stop = $true } finally { [System.Threading.Monitor]::Exit($script:FanLock) }
  }
  $deadline = (Get-Date).AddSeconds(3)
  foreach ($h in @($script:SenseHandle, $script:FanHandle)) {
    if ($h -and -not $h.IsCompleted) { $ms = [Math]::Max(0, [int](($deadline - (Get-Date)).TotalMilliseconds)); [void]$h.AsyncWaitHandle.WaitOne($ms) }
  }
  $script:FanWorkerOn = $false
  if ($script:SenseHandle -and $script:SenseHandle.IsCompleted) { $script:Sense = $null }
  try { Unregister-Event -SourceIdentifier RosaThermalPower -ErrorAction SilentlyContinue } catch {}
  try { Get-Event -SourceIdentifier RosaThermalPower -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue } catch {}
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
if (Test-Path $WifiStateFile) { Restore-Wifi 'previous run did not exit cleanly' }
if ($Restore) { exit 0 }

try { Open-Sensors } catch { Write-Log "cannot load LibreHardwareMonitor: $($_.Exception.Message)"; exit 2 }
if (-not $isAdmin) { Write-Log 'WARNING: not running as admin - CPU temperatures need admin' }
Init-Fan
if ($HasNvidia) { Init-Nvidia } else { Write-Log 'no active NVIDIA/AMD GPU found by sensors (integrated GPU heat is covered by the CPU package sensor)' }

if ($Once) { $t = Read-Temps; Write-Log ("CPU={0} GPU={1}" -f $t.Cpu, $t.Gpu); exit 0 }

Start-SensorWorker
if ($FanOk) { Start-FanWorker }
Start-PowerWatch
[void](Get-TopCpuProcesses 1)

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
$fanRelSince = $null; $lastFanFix = [datetime]::MinValue; $prevCpu = $null; $prevCpuAt = $null; $fanCpuS = $null; $fanGpuS = $null; $fanCritN = 0; $fanSN = 0; $cpuHotN = 0; $gpuHotN = 0; $cpuHotSince = $null; $gpuHotSince = $null; $fanCritSince = $null; $fanEmaAt = $null; $fanSStart = $null; $lastLoopAt = $null; $gmCandSince = $null; $gmIdleSince = $null; $gmScanAt = [datetime]::MinValue; $gmListed = @(); $gmNamed = @(); $gmNvAt = [datetime]::MinValue; $gmNvLoad = $null
Write-Log "RosaThermalGuard started (admin=$isAdmin, poll=${PollSeconds}s, stale=${IO_STALE}s, fanRead=1s, cap100=85, CPU hot=$CPU_HOT crit=$CPU_CRIT cool=$CPU_COOL, GPU hot=$GPU_HOT cool=$GPU_COOL, turbo hold after $SG_REPEAT spikes until ${SG_COOL_C}C for ${SG_COOL_SEC}s)"
$exitCode = 0
try {
  Update-Startup
  $perfSw = New-Object Diagnostics.Stopwatch; $perfN = 0; $perfMs = 0.0; $perfMax = 0.0; $perfAt = Get-Date; $perfCpu0 = (Get-Process -Id $PID).TotalProcessorTime.TotalSeconds; $script:PerfAgeMax = 0.0
  while ($true) {
    if ($script:SenseHandle -and $script:SenseHandle.IsCompleted) {
      Write-Log 'sensor reader stopped - starting it again'
      try { $script:SensePs.Dispose() } catch {}
      try { $script:SenseRs.Dispose() } catch {}
      $script:Sense = $null; $script:SenseHandle = $null
      Start-SensorWorker
    }
    if ($FanOk -and $script:FanHandle -and $script:FanHandle.IsCompleted) {
      Write-Log 'fan reader stopped - starting it again'
      $script:FanWorkerOn = $false
      try { $script:FanPs.Dispose() } catch {}
      try { $script:FanRs.Dispose() } catch {}
      $script:FanHandle = $null
      Start-FanWorker
    }
    $loopT0 = Get-Date; $perfSw.Restart()
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
      $v = $sim.Dequeue(); $t.Cpu = $v[0]; $t.Gpu = $v[1]; $t.Age = 0
    }
    $now = Get-Date
    $powerResume = Test-PowerResume
    $kind = 'ok'
    if ($lastLoopAt) { $kind = Get-ControlGapKind ($now - $lastLoopAt).TotalSeconds $PollSeconds ([bool]$powerResume) }
    if ($kind -eq 'resume') {
      Write-Log ("resume/stall detected ({0:N0}s since last check) - re-reading fans and temperatures" -f ($now - $lastLoopAt).TotalSeconds)
      $prevCpu = $null; $prevCpuAt = $null; $fanCpuS = $null; $fanGpuS = $null; $fanCritN = 0; $fanSN = 0; $cpuHotN = 0; $gpuHotN = 0; $cpuHotSince = $null; $gpuHotSince = $null; $fanCritSince = $null; $fanEmaAt = $null; $fanSStart = $null; $lastLoopAt = $null; $gmCandSince = $null; $gmIdleSince = $null; $gmScanAt = [datetime]::MinValue; $gmListed = @(); $gmNamed = @(); $gmNvAt = [datetime]::MinValue; $gmNvLoad = $null; $lastFanFix = [datetime]::MinValue
      $script:TurboCool = $null
    } elseif ($kind -eq 'stall') {
      Write-Log ("control stall ({0:N0}s) - keeping fan smoothing and the last CPU sample" -f ($now - $lastLoopAt).TotalSeconds)
      $script:TurboCool = $null; $coolSince = $null; $gpuCoolSince = $null; $fanRelSince = $null
    }
    $lastLoopAt = $now
    $cpu = $t.Cpu; $gpu = $t.Gpu
    $age = 999.0
    if ($t -and $t.ContainsKey('Age') -and $t.Age -ne $null) { $age = [double]$t.Age }
    if ($TestMode -or $simActive) { $age = 0 }
    $fresh = Test-SampleFresh $age $IO_STALE
    if ($age -gt $script:PerfAgeMax) { $script:PerfAgeMax = $age }
    if (-not $fresh -and $age -lt 30 -and -not $script:StaleLogged) { Write-Log ("sensor sample is {0:N1}s old - holding power steps and fan targets" -f $age); $script:StaleLogged = $true }
    elseif ($fresh -and $script:StaleLogged) { Write-Log 'sensor sample is fresh again'; $script:StaleLogged = $false }
    $lease = $null
    if ($Sync -and $Sync.LeaseLevel -and $Sync.LeaseUntil -is [datetime] -and $Sync.LeaseUntil -gt $now) { $lease = [string]$Sync.LeaseLevel }
    if ($lease -ne $script:LeaseNow) {
      if ($lease) { Write-Log "peer cooldown lease: $lease ($($Sync.LeaseFrom)) - fan curve ${LEASE_FAN_C} C earlier$(if ($lease -eq 'strong') { ', turbo off' }); protection unchanged" }
      else { Write-Log 'peer cooldown lease ended - normal curve (steps back only through the usual cool timers)' }
      $script:LeaseNow = $lease
    }

    $paused = $false
    if ($Sync -and $Sync.PauseUntil -gt $now) {
      if (-not $fresh -and $age -gt 10) { $Sync.PauseUntil = [datetime]::MinValue; Write-Log 'pause cancelled - temperature sample went stale' }
      elseif ($fresh -and $cpu -ne $null -and $cpu -ge $PAUSE_CANCEL) { $Sync.PauseUntil = [datetime]::MinValue; Write-Log "pause cancelled - CPU $cpu C" }
      else {
        $paused = $true
        if (-not $wasPaused) { Write-Log "guard paused by user until $($Sync.PauseUntil.ToString('HH:mm'))" }
        if (-not $script:PausePowerSent -and ($CpuLevel -gt 0 -or $GpuThrottled -or $Reniced.Count -gt 0)) { Restore-All 'paused by user' -SkipFan; $script:PausePowerSent = $true }
        if (-not $script:PauseFanSent -and -not $script:FanPending -and ($FanBoosted -or (Test-Path $FanStateFile))) { Restore-Fan 'paused by user'; $script:PauseFanSent = $true }
      }
    }
    if (-not $paused) { $script:PausePowerSent = $false; $script:PauseFanSent = $false }
    if ($wasPaused -and -not $paused) { Write-Log 'guard resumed' }
    $wasPaused = $paused

    $rise = $null
    if ($fresh) {
    if ($lease -eq 'strong' -and -not $paused -and $CpuLevel -eq 0) { Write-Log 'strong cooldown lease - turbo off (level 1)'; Apply-CpuLevel 1; $lastStep = $now; $lastStepTemp = $cpu; $coolSince = $null }
    $cpuHotSince = $(if ($cpu -ne $null -and $cpu -ge $CPU_HOT) { if ($cpuHotSince) { $cpuHotSince } else { $now } } else { $null })
    $gpuHotSince = $(if ($gpu -ne $null -and $gpu -ge $GPU_HOT) { if ($gpuHotSince) { $gpuHotSince } else { $now } } else { $null })
    if ($paused) { $coolSince = $null }
    elseif ($cpu -eq $null) {
      if (-not $nullSince) { $nullSince = $now; Write-Log 'CPU temperature not available (admin/PawnIO?)' }
    } else {
      $nullSince = $null
      $gapCpu = $(if ($prevCpuAt) { ($now - $prevCpuAt).TotalSeconds } else { 0.0 })
      $riseOk = Test-RiseSample $gapCpu $PollSeconds
      $rise = $(if ($riseOk -and $prevCpu -ne $null) { ($cpu - $prevCpu) / [Math]::Max(0.5, $gapCpu) } else { 0.0 })
      $spiked = ($cpu -ge $SG_FAST_C) -or ($riseOk -and $cpu -ge $SG_RISE_C -and $rise -ge $SG_RISE)
      if ($spiked) { $lastSpikeAt = $now }
      if ($SG_ON -and $CpuLevel -eq 0 -and $spiked) {
        Write-Log ("CPU fast heat: {0} C ({1:+0.0;-0.0} C/s) - turbo off now, before the 2-s filter (spike guard)" -f $cpu, $rise)
        if ($lastFullRestore -and ($now - $lastFullRestore).TotalSeconds -lt 120) { $restoreHold = [Math]::Min($HOLD_MAX, $restoreHold * 2); $sgMul = [Math]::Min(16, $sgMul * 2); Write-Log ("spike right after turbo came back - turbo now stays off until {0:N0}s without a spike" -f (SG-Hold)) }
        Apply-CpuLevel 1; $lastStep = $now; $lastStepTemp = $cpu; $coolSince = $null
        if (-not $script:SgNoticeAt -or ($now - $script:SgNoticeAt).TotalMinutes -ge 30) { $script:SgNoticeAt = $now; Show-Notice 'nCpuHot' ([int]$cpu) }
      }
      if ($SG_ON) {
        $st = Update-TurboSticky $now ([bool]$spiked) $cpu ([bool]$script:TurboSticky) $script:TurboSpikes $script:TurboCool $SG_REPEAT $SG_WINDOW $SG_COOL_C $SG_COOL_SEC
        $script:TurboSticky = [bool]$st.Sticky; $script:TurboCool = $st.CoolSince
        if ($st.Engaged) { Write-Log ("turbo held: {0} spikes in {1:N0} min - turbo stays off until CPU is under {2} C for {3:N0}s" -f $st.Spikes, ($SG_WINDOW / 60), $SG_COOL_C, $SG_COOL_SEC) }
        if ($st.Released) { Write-Log 'turbo hold released - CPU stayed cool' }
      }
      if ($script:TurboSticky -and $CpuLevel -eq 0 -and -not $paused) { Write-Log 'turbo held - staying off full turbo'; Apply-CpuLevel 1; $lastStep = $now; $lastStepTemp = $cpu; $coolSince = $null }
      $hotLong = $cpuHotSince -and (($now - $cpuHotSince).TotalSeconds -ge $CPU_HOT_SEC)
      if ($cpu -ge $CPU_HOT -and -not $hotLong -and $cpu -lt $CPU_CRIT) { if ($cpuHotSince -eq $now) { Write-Log "CPU spike $cpu C - waiting ${CPU_HOT_SEC}s to see if it lasts" } }
      $stepTo = Get-CpuStepTarget $CpuLevel $CPU_STEPS.Count $cpu $CPU_HOT $CPU_CRIT ([bool]$hotLong) (($now - $lastStep).TotalSeconds) $STEP_MIN_SECONDS
      if ($stepTo -gt $CpuLevel) {
        $coolSince = $null
        if ($CpuLevel -eq 0 -and $lastFullRestore -and ($now - $lastFullRestore).TotalSeconds -lt 120) {
          $restoreHold = [Math]::Min($HOLD_MAX, $restoreHold * 2)
          Write-Log "heat came back soon after full speed - next return to turbo waits ${restoreHold}s of cool"
        }
        $first = ($CpuLevel -eq 0)
        if ($cpu -ge 100 -and $stepTo -ge 2 -and $CpuLevel -lt 2) { Write-Log ("CPU {0} C - cap at {1}% now, before the package climbs further" -f $cpu, $CPU_STEPS[$stepTo]) }
        else { Write-Log "CPU hot: $cpu C" }
        Apply-CpuLevel $stepTo; $lastStep = $now; $lastStepTemp = $cpu
        if ($first) { Show-Notice 'nCpuHot' ([int]$cpu) }
      } elseif ($cpu -ge $CPU_HOT) { $coolSince = $null }
      elseif ($cpu -lt $CPU_COOL -and ($CpuLevel -gt 0 -or $Reniced.Count -gt 0)) {
        if (-not $coolSince) { $coolSince = $now }
        else {
          $spikeSeen = [bool]($SG_ON -and $lastSpikeAt)
          $wait = Get-CpuRestoreWait $CpuLevel $restoreHold $COOL_SECONDS (SG-Hold) $spikeSeen
          $spikeClear = (-not $spikeSeen) -or (($now - $lastSpikeAt).TotalSeconds -ge (SG-Hold))
          if (($now - $coolSince).TotalSeconds -ge $wait -and $spikeClear -and -not ($CpuLevel -eq 1 -and $lease -eq 'strong') -and (Test-AllowTurboReturn ([bool]$script:TurboSticky) ([int]$CpuLevel))) {
            Write-Log "CPU cool: $cpu C"
            if ($CpuLevel -gt 0) { Apply-CpuLevel ($CpuLevel - 1) }
            if (-not $GpuThrottled) { Restore-Priorities }
            $coolSince = $now
            if ($CpuLevel -eq 0 -and -not $GpuThrottled) { $lastFullRestore = $now; Restore-All 'cooled down'; Show-Notice 'nCool' $null }
          }
        }
      } else { $coolSince = $null }
      if ($cpu -ge $CPU_CRIT -and ($now - $script:TopScanAt).TotalSeconds -ge 30) { $script:TopScanAt = $now; Lower-Priority (Get-TopCpuProcesses $TOP_N) "CPU $cpu C" }
      $prevCpu = $cpu; $prevCpuAt = $now
    }
      $agap = if ($script:AcctAt) { ($now - $script:AcctAt).TotalSeconds } else { [double]$PollSeconds }
      $hole = ($kind -eq 'resume')
      $over100C += Get-HotSeconds $agap $PollSeconds ([bool]$script:AcctWasC) ($cpu -ne $null -and $cpu -ge 100) $hole
      $over100G += Get-HotSeconds $agap $PollSeconds ([bool]$script:AcctWasG) ($gpu -ne $null -and $gpu -ge 100) $hole
      $script:AcctAt = $now; $script:AcctWasC = ($cpu -ne $null -and $cpu -ge 100); $script:AcctWasG = ($gpu -ne $null -and $gpu -ge 100)
    }

    if ($fresh -and -not $paused -and $gpu -ne $null) {
      if ($gpu -ge $GPU_HOT -and ($now - $gpuHotSince).TotalSeconds -lt $GPU_HOT_SEC) { }
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

    # game mode: sustained GPU load + a fullscreen or listed game in front (or a listed game running), with hysteresis
    if ($GM_ON -and -not $paused) {
      $fgi = Get-FgInfo
      $gl = $t.GpuLoad
      if ($gl -eq $null -and $HasNvidia) {
        if ($fresh -and ($now - $gmNvAt).TotalSeconds -ge 10) { $gmNvAt = $now; $r = Invoke-NvSmi '--query-gpu=utilization.gpu --format=csv,noheader,nounits' 2000; $gmNvLoad = $(if ($r -and $r.Code -eq 0) { ToNum (($r.Out -split "`n")[0]) } else { $null }) }
        $gl = $gmNvLoad
      }
      if (($now - $gmScanAt).TotalSeconds -ge 5) { $gmScanAt = $now; $gmListed = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $GM_EXES -contains $_.ProcessName.ToLower() }); $gmNamed = $(if ($GameName) { @(Get-Process -Name $GameName -ErrorAction SilentlyContinue) } else { @() }) }
      $simGame = $null
      if ($ALLOW_SIM -and (Test-Path $SimGameFile) -and ((Get-Date) - (Get-Item $SimGameFile).LastWriteTime).TotalMinutes -lt 5) { $simGame = ([string](Get-Content $SimGameFile -Raw)).Trim().ToLower() }
      $fgName = if ($fgi) { $fgi.Name.ToLower() } else { '' }
      $listedFg = $fgName -and ($GM_EXES -contains $fgName)
      $fullFg = $GM_FULLSCREEN -and $fgi -and $fgi.Full -and ($GM_EXCL -notcontains $fgName)
      $busy = $gl -ne $null -and $gl -ge $GM_GPU_UTIL
      $suiteG = $Sync -and $Sync.SuiteGamingUntil -is [datetime] -and $Sync.SuiteGamingUntil -gt $now
      $cand = [bool]$simGame -or $listedFg -or ($busy -and ($fullFg -or $gmListed.Count -gt 0)) -or $suiteG
      if ($cand) { $gmIdleSince = $null; if (-not $gmCandSince) { $gmCandSince = $now } } else { $gmCandSince = $null; if (-not $gmIdleSince) { $gmIdleSince = $now } }
      if (-not $GameMode -and $gmCandSince -and ($now - $gmCandSince).TotalSeconds -ge $GM_ENTER) {
        $why = if ($simGame) { "simulated: $simGame" } elseif ($suiteG -and -not ($listedFg -or ($busy -and ($fullFg -or $gmListed.Count -gt 0)))) { "suite: $($Sync.SuiteGamingSrc)" } elseif ($listedFg) { "listed game in front: $($fgi.Name)" } elseif ($fullFg) { "GPU $([int]$gl)% + fullscreen $($fgi.Name)" } else { "GPU $([int]$gl)% + listed game running: $($gmListed[0].ProcessName)" }
        $script:GameMode = $true; $script:GameProtectLogged = $false
        $script:GameName = $(if ($simGame) { $simGame } elseif ($listedFg -or $fullFg) { $fgi.Name } elseif ($gmListed.Count) { $gmListed[0].ProcessName } else { $null })
        Write-Log "game mode ON ($why) - earlier fan curve, the game is protected from priority changes"
      } elseif ($GameMode -and $gmIdleSince -and ($now - $gmIdleSince).TotalSeconds -ge $GM_EXIT) {
        Write-Log "game mode OFF (no game activity for ${GM_EXIT}s) - back to the normal fan curve"
        $script:GameMode = $false; $script:GameName = $null; $script:GamePids = @{}
      }
      if ($GameMode) {
        $gp = @{}
        if ($fgi -and ($listedFg -or $fullFg -or $fgName -eq ([string]$GameName).ToLower())) { $gp[[int]$fgi.Pid] = $fgi.Name }
        foreach ($p in $gmListed) { $gp[$p.Id] = $p.ProcessName }
        foreach ($p in @($gmNamed)) { $gp[$p.Id] = $p.ProcessName }
        $script:GamePids = $gp
        foreach ($k in @($Reniced.Keys)) {
          if ($gp.ContainsKey($k)) { try { $pp = Get-Process -Id $k -ErrorAction Stop; $pp.PriorityClass = $Reniced[$k].Orig; Write-Log "priority $($pp.ProcessName) (pid $k) put back to $($Reniced[$k].Orig) - it is the running game" } catch {}; $script:Reniced.Remove($k) }
        }
      }
    }

    # fans: first line of defence, before any throttling (curve starts well below the throttle points)
    if ($FanOk) {
      Read-Fan
      if (-not $fresh) { if ($FanBoosted -and -not $paused) { Fan-Step } }
      else {
      if ($cpu -ne $null) { $script:FanLastCpu = $cpu }; if ($gpu -ne $null) { $script:FanLastGpu = $gpu }   # raw, for the exit soft landing
      if ($paused) { $fanRelSince = $null }
      # the fan logic works on smoothed temperatures (EMA, ~fanSmoothingSeconds) so single-sample spikes don't move the fans
      $fdt = if ($fanEmaAt) { [Math]::Min(10.0, ($now - $fanEmaAt).TotalSeconds) } else { $PollSeconds }; $fanEmaAt = $now
      $fa = [Math]::Min(1.0, $fdt / [Math]::Max(1.0, $FAN_SMOOTH))   # EMA weight from elapsed time, so the ~12 s window does not depend on the poll rate
      if ($fanCpuS -eq $null -and $fanGpuS -eq $null) { $fanSStart = $now }
      $fanWarm = $fanSStart -and ($now - $fanSStart).TotalSeconds -ge 8
      if ($cpu -ne $null) { $fanCpuS = $(if ($fanCpuS -eq $null) { [double]$cpu } else { $fanCpuS + $fa * ($cpu - $fanCpuS) }) } else { $fanCpuS = $null }
      if ($gpu -ne $null) { $fanGpuS = $(if ($fanGpuS -eq $null) { [double]$gpu } else { $fanGpuS + $fa * ($gpu - $fanGpuS) }) } else { $fanGpuS = $null }
      $rawCrit = Fan-Critical $cpu $gpu
      $fanCritSince = $(if ($rawCrit) { if ($fanCritSince) { $fanCritSince } else { $now } } else { $null })
      if (-not $paused) {
        $fc = if ($fanCpuS -ne $null) { [Math]::Round($fanCpuS, 1) } else { $null }; $fg = if ($fanGpuS -ne $null) { [Math]::Round($fanGpuS, 1) } else { $null }
        Learn-AutoFan $fc
        $tempTxt = "CPU $fc C, GPU $fg C smoothed (now $cpu / $gpu)$(if ($GameMode) { ' [game mode]' })"
        # 95 C still waits the usual few seconds. A raw 100 C sample is already in the shutdown zone, so the one allowed jump to 100 % happens on that sample.
        $shutdownZone = ($cpu -ne $null -and [double]$cpu -ge 100) -or ($gpu -ne $null -and [double]$gpu -ge 100)
        $crit = $shutdownZone -or ($fanCritSince -and ($now - $fanCritSince).TotalSeconds -ge $FAN_CRIT_SEC) -or ($fanWarm -and (Fan-Critical $fc $fg))
        $lOff = $(if ($lease) { $LEASE_FAN_C } else { 0.0 })
        $demand = Fan-Demand $fc $fg (-$lOff)
        $obs = Fan-ObservedPct
        if (-not $FanBoosted) {
          $fanRelSince = $null
          if ($crit) { Fan-Take "critical: $tempTxt" 100 100 }   # safety first: straight to 100 %, no ramp, no switch delay
          elseif ($fanWarm -and $script:FanFresh -and $obs -ne $null -and $demand -ge $obs + $FAN_ENGAGE_MARGIN -and ($now - $FanSwitchAt).TotalSeconds -ge $FAN_MIN_SWITCH) {
            Fan-Take ("curve {0:N0}% > fans {1:N0}%: {2}" -f $demand, $obs, $tempTxt) ([Math]::Round($obs)) $demand
          }
        } else {
          # keep control asserted if Control Center (or anything else) changed the fans while we need them
          if ($script:FanModeFresh -and $FanInfo -and $FanPct -ne $null -and ($FanInfo.Fixed -ne 1 -or [Math]::Abs($FanInfo.Speed - (Pct-Duty $FanPct)) -gt 3) -and ($now - $lastFanFix).TotalSeconds -ge 30 -and -not $script:FanPending) {
            Write-Log "fan mode was changed outside Thermal Guard ($($FanInfo.Mode), speed $($FanInfo.Speed)) - taking control again"
            $lastFanFix = $now
            if ($script:FanWorkerOn) { $script:FanWaitMeta = @{ Type = 'reassert' }; [void](Submit-Fan 'reassert' ([double]$FanPct) '') }
            else { Fan-Set 'SetCurrentFanStep' 0; Fan-Set 'SetAutoFanStatus' 0; Fan-Apply $FanPct; Fan-Set 'SetStepFanStatus' 1; Fan-Set 'SetFixedFanStatus' 1 }
          }
          $floor = [Math]::Min(90.0, (Auto-Pct $fc))      # while controlled, never below what auto would run (never 100 from this)
          if ($crit) {
            if ($FanPct -lt 99.5) {
              $jumping = $script:FanPending -and $script:FanWaitMeta -and [string]$script:FanWaitMeta.Type -eq 'apply' -and [double]$script:FanWaitMeta.Pct -ge 99.5
              if (-not $jumping) {
                Write-Log "fans: critical ($tempTxt) - 100% now"
                if ($script:FanWorkerOn) { $script:FanWaitMeta = @{ Type = 'apply'; Pct = 100.0 }; [void](Submit-Fan 'apply' 100 '' -Preempt) }
                else { Fan-Apply 100; $script:FanLevel = 2 }
              }
            }
            $script:FanTarget = 100; $script:FanRaiseAt = $now; $fanRelSince = $null
          } else {
            $want = [Math]::Max($demand, $floor)
            if ($want -gt $FanTarget + 0.5) { $script:FanTarget = $want; $script:FanRaiseAt = $now }
            elseif (($now - $FanRaiseAt).TotalSeconds -ge $FAN_MIN_HOLD) {
              # decreases use the curve shifted by the hysteresis (as if it were $FAN_HYST C hotter), so small wobbles don't move the fans
              $down = [Math]::Max((Fan-Demand $fc $fg (-$FAN_HYST - $lOff)), $floor)
              if ($down -lt $FanTarget - 0.5) { $script:FanTarget = $down }
            }
            # hand back to auto: cool long enough, held long enough, and already ramped down to about auto speed
            # decoupled from CPU/GPU throttling: only the (smoothed) temperatures decide
            $cool = ($fc -eq $null -or $fc -lt $FAN_REL_CPU) -and ($fg -eq $null -or $fg -lt $FAN_REL_GPU)
            if (-not $cool) { $fanRelSince = $null } elseif (-not $fanRelSince) { $fanRelSince = $now }
            if ($fanRelSince -and ($now - $fanRelSince).TotalSeconds -ge 300 -and $FanBoosted) {
              $script:FanTarget = $floor
              if ($FanPct -ne $null -and $FanPct -le $floor + $FAN_HB_MARGIN -and -not $script:FanPending) {
                Write-Log "fan stuck guard: cool for 5 min and already near auto - handing back ($tempTxt)"
                Restore-Fan 'stuck guard' -Abrupt; $fanRelSince = $null; $script:StuckLogged = $false
              } elseif (-not $script:StuckLogged) { Write-Log "fan stuck guard: cool for 5 min - stepping down toward auto ($tempTxt)"; $script:StuckLogged = $true }
            }
            if ($fanRelSince -and ($now - $fanRelSince).TotalSeconds -ge $FAN_REL_SEC -and ($now - $FanRaiseAt).TotalSeconds -ge $FAN_MIN_HOLD -and ($now - $FanSwitchAt).TotalSeconds -ge $FAN_MIN_SWITCH) {
              $script:FanTarget = $floor
              if ($FanPct -le $floor + $FAN_HB_MARGIN -and -not $script:FanPending) {
                Write-Log ("fans: cool for {0}s and down to {1:N0}% (auto runs ~{2:N0}% here) - handing back to auto ({3})" -f [int]($now - $fanRelSince).TotalSeconds, $FanPct, $floor, $tempTxt)
                Restore-Fan 'cooled down' -Abrupt; $fanRelSince = $null; Read-Fan -Full
              }
            }
          }
          if ($FanBoosted) { $fp0 = $FanPct; Fan-Step; if ($FanPct -ne $fp0) { $script:FanModeAt = [datetime]::MinValue }; Read-Fan }   # a duty change forces a fresh mode read
        }
      }
      }
    }

    if (($now - $lastInfo).TotalSeconds -ge $(if ($TestMode -or $CpuLevel -gt 0 -or $GpuThrottled -or $FanBoosted -or $GameMode) { $TEMPS_EVERY - 0.05 } else { [Math]::Max(60.0, $TEMPS_EVERY) - 0.05 })) {
      Write-Log ("temps CPU={0} GPU={1} level={2} gpuThrottled={3}{5}{4}" -f $cpu, $gpu, $CpuLevel, $GpuThrottled, $(if ($TestMode -or $simActive) { " (SIM, $real)" } else { '' }), $(if ($FanInfo) { " fan=$($FanInfo.Mode) $($FanInfo.Rpm1)/$($FanInfo.Rpm2)rpm" } else { '' }))
      $lastInfo = $now
    }
    if ($CpuLevel -eq 0 -and $lastFullRestore -and ($now - $lastFullRestore).TotalSeconds -gt $HOLD_MAX -and ($restoreHold -ne $COOL_SECONDS -or $sgMul -ne 1)) { $restoreHold = $COOL_SECONDS; $sgMul = 1; Write-Log 'stable at full speed - hold time reset' }
    # NVIDIA can appear later (MUX/hybrid switch): re-scan every 10 min
    if (-not $HasNvidia -and ($now - $lastRescan).TotalMinutes -ge 10) {
      $lastRescan = $now
      Stop-SensorWorker 2000
      if ($script:SenseHandle -and -not $script:SenseHandle.IsCompleted) { Write-Log 'sensor read still in progress - skipping GPU rescan' }
      else { try { if ($Computer) { $Computer.Close() }; Open-Sensors; if ($HasNvidia) { Init-Nvidia }; Start-SensorWorker } catch {} }
    }
    # thermal.pressure (contract 7.4): 3 critical, 2 throttling, 1 warm / fans ramping, 0 normal; up at once, down after 30 s
    $pcs = $(if ($fanCpuS -ne $null) { $fanCpuS } else { $cpu }); $pgs = $(if ($fanGpuS -ne $null) { $fanGpuS } else { $gpu })
    $wc = $(if ($GameMode) { 65 } else { 75 }); $wg = $(if ($GameMode) { 60 } else { 72 })
    $prRaw = 0; $prWhy = 'normal'
    if (($fanCritSince -and ($now - $fanCritSince).TotalSeconds -ge $FAN_CRIT_SEC) -or ($pcs -ne $null -and $pcs -ge 95) -or ($pgs -ne $null -and $pgs -ge 90)) { $prRaw = 3; $prWhy = 'critical' }
    elseif ($CpuLevel -gt 0 -or $GpuThrottled) { $prRaw = 2; $prWhy = $(if ($CpuLevel -gt 0) { 'cpu.limited' } else { 'gpu.limited' }) }
    elseif ($FanBoosted -or ($pcs -ne $null -and $pcs -ge $wc) -or ($pgs -ne $null -and $pgs -ge $wg)) { $prRaw = 1; $prWhy = $(if ($FanBoosted) { 'fans.ramping' } else { 'warm' }) }
    if ($prRaw -ge $script:PrLevel) { $script:PrLevel = $prRaw; $script:PrLowSince = $null }
    elseif (-not $script:PrLowSince) { $script:PrLowSince = $now }
    elseif (($now - $script:PrLowSince).TotalSeconds -ge $PR_DOWN_SEC) { $script:PrLevel = $prRaw; $script:PrLowSince = $null }
    # wireless power-saving leases (thermal.request_power_setting): the SDK decides the leases, the worker hands over the
    # effective value with a heartbeat; only the owner (here) changes the plan. Stale (worker gone) or critical = default.
    $ww = 'default'; $wwWhy = 'no lease'
    if ($Sync -and $Sync.WifiWant -eq 'max_performance') {
      if (-not ($Sync.WifiWantAt -is [datetime]) -or ($now - $Sync.WifiWantAt).TotalSeconds -gt 30) { $wwWhy = 'suite worker silent' }
      elseif ($script:PrLevel -ge 3) { $wwWhy = 'critical temperature' }
      else { $ww = 'max_performance' }
    }
    if ($ww -ne $script:WifiApplied) { try { if ($ww -eq 'max_performance') { Apply-WifiMax ([string]$Sync.WifiFrom) } else { Restore-Wifi $wwWhy } } catch { Write-Log "wireless power saving: $($_.Exception.Message)" } }
    if ($Sync) {
      $Sync.Pressure = @{ level = $script:PrLevel; cpuC = $(if ($cpu -ne $null) { [Math]::Round([double]$cpu, 1) } else { $null }); gpuC = $(if ($gpu -ne $null) { [Math]::Round([double]$gpu, 1) } else { $null })
        trend = $(if ($rise -ne $null) { [Math]::Max(-50.0, [Math]::Min(50.0, [Math]::Round([double]$rise, 1))) } else { 0.0 })
        fanMode = $(if (-not $FanOk) { 'unknown' } elseif ($FanBoosted -and $FanLevel -ge 2) { 'max' } elseif ($FanBoosted) { 'ramp' } else { 'auto' })
        gaming = [bool]$GameMode; reason = $(if ($script:PrLevel -eq $prRaw) { $prWhy } else { 'cooling.down' }); at = $now; wifi = $(if ($script:WifiApplied -eq 'max_performance') { 1 } else { 0 }) }
      $Sync.Cpu = $cpu; $Sync.Gpu = $gpu; $Sync.Level = $CpuLevel; $Sync.MaxPct = $CPU_STEPS[$CpuLevel]
      $Sync.GpuThrottled = $GpuThrottled; $Sync.Paused = $paused; $Sync.HasNvidia = $HasNvidia; $Sync.Sim = $simActive
      $Sync.GpuMode = $(if ($Nv) { $Nv.Mode } else { $null }); $Sync.GpuLimitW = $(if ($Nv) { $Nv.Cur } else { $null }); $Sync.GpuDefaultW = $(if ($Nv) { $Nv.Default } else { $null }); $Sync.GpuClockCap = $(if ($Nv) { $Nv.LgcMhz } else { $null })
      $Sync.FanOk = $FanOk; $Sync.FanBoost = $FanBoosted; $Sync.FanLevel = $FanLevel; $Sync.FanBoostPct = $(if ($FanPct -ne $null) { [int][Math]::Round($FanPct) } else { $null }); $Sync.FanTarget = $(if ($FanTarget -ne $null) { [int][Math]::Round($FanTarget) } else { $null }); $Sync.FanMax1 = $FAN_MAXRPM1; $Sync.FanMax2 = $FAN_MAXRPM2; $Sync.GameMode = $GameMode; $Sync.GameName = $GameName; $Sync.TurboHeld = [bool]$script:TurboSticky
      if ($FanInfo) { $Sync.FanRpm1 = $FanInfo.Rpm1; $Sync.FanRpm2 = $FanInfo.Rpm2; $Sync.FanMode = $FanInfo.Mode } else { $Sync.FanMode = $null }
      $Sync.Reniced = $Reniced.Count; $Sync.Updated = Get-Date
      if ($Sync.Stop) { Write-Log 'exit requested from tray'; break }
    }
    if ($fresh) { $script:HistSim = $simActive; Hist-Sample $now $cpu $gpu ($kind -eq 'resume') }
  if ($Sync -and -not $TestMode) { try { Update-Tick $now $cpu $gpu $simActive $paused } catch { Write-Log "update: error $($_.Exception.Message)" } }
    if (-not $TestMode -and -not $Sync -and (Test-Path $StopFile)) { Remove-Item $StopFile -Force -ErrorAction SilentlyContinue; Write-Log 'stop.flag found - stopping'; break }
    $perfSw.Stop(); $perfN++; $perfMs += $perfSw.Elapsed.TotalMilliseconds; $perfMax = [Math]::Max($perfMax, $perfSw.Elapsed.TotalMilliseconds)
    if (((Get-Date) - $perfAt).TotalSeconds -ge 600) {
      $pc = (Get-Process -Id $PID).TotalProcessorTime.TotalSeconds; $el = ((Get-Date) - $perfAt).TotalSeconds
      Write-Log ("perf: {0} polls in {1:N0}s, work avg {2:N0} ms / max {3:N0} ms per poll; process CPU {4:N1}% of one core (incl. window); at/above 100 C: CPU {5:N0}s, GPU {6:N0}s; sensor age max {7:N1}s" -f $perfN, $el, ($perfMs / [Math]::Max(1, $perfN)), $perfMax, (100 * ($pc - $perfCpu0) / $el), $over100C, $over100G, $script:PerfAgeMax); $over100C = 0.0; $over100G = 0.0
      $perfN = 0; $perfMs = 0.0; $perfMax = 0.0; $perfAt = Get-Date; $perfCpu0 = $pc; $script:PerfAgeMax = 0.0
    }
    Start-Sleep -Milliseconds ([Math]::Max(100, [int]($PollSeconds * 1000 - ((Get-Date) - $loopT0).TotalMilliseconds)))
  }
} catch {
  Write-Log "CRASH: $($_.Exception.Message)"; $exitCode = 1
} finally {
  Stop-GuardIo
  Restore-All $(if ($TestMode) { 'test finished' } else { 'guard exiting' })
  Restore-Wifi 'guard exiting'
  if (-not ($script:SenseHandle -and -not $script:SenseHandle.IsCompleted)) { try { $Computer.Close() } catch {} }
  else { Write-Log 'sensor read still in progress - leaving it to process exit' }
  try { $mutex.ReleaseMutex() } catch {}
}
exit $exitCode
