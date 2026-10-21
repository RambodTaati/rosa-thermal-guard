# Pure decisions for the guard loop. No sensors, no WMI, no fan registers.
# Temperature wins over releasing a limit. Bearing steps are not decided here.

function Get-ControlGapKind([double]$GapSeconds, [double]$PollSeconds, [bool]$PowerResume) {
  if ($PowerResume) { return 'resume' }
  $limit = [Math]::Max(30.0, 5.0 * $PollSeconds)
  if ($GapSeconds -gt $limit) { return 'stall' }
  return 'ok'
}

function Test-RiseSample([double]$GapSeconds, [double]$PollSeconds) {
  return ($GapSeconds -gt 0 -and $GapSeconds -le (2.0 * [Math]::Max(0.5, $PollSeconds) + 0.35))
}

function Test-SampleFresh([double]$AgeSeconds, [double]$StaleSeconds) {
  if ($AgeSeconds -lt 0) { return $false }
  return ($AgeSeconds -le $StaleSeconds)
}

# Seconds to add to "time at or above 100 C".
# A sample that was already hot across the whole gap counts the gap.
# A sample that just became hot counts at most one poll, so a blind window is not invented.
# Sleep is a hole: the chip was not observed.
function Get-HotSeconds([double]$GapSeconds, [double]$PollSeconds, [bool]$WasHot, [bool]$NowHot, [bool]$SleepHole) {
  if ($SleepHole -or -not $NowHot -or $GapSeconds -le 0) { return 0.0 }
  if ($WasHot) { return $GapSeconds }
  return [Math]::Min($GapSeconds, [Math]::Max(0.0, $PollSeconds))
}

function Test-AllowTurboReturn([bool]$Sticky, [int]$Level) {
  if ($Level -ne 1) { return $true }
  return -not $Sticky
}

# Next processor-state level. 100 C lands on the 85 % step at once.
# 95 C takes the next step on that same sample. 90 C still has to last, and further steps stay 6 s apart.
function Get-CpuStepTarget([int]$Level, [int]$StepCount, [double]$Cpu, [double]$HotC, [double]$CritC, [bool]$HotLongEnough, [double]$SinceStep, [double]$MinStepSec) {
  $last = [Math]::Max(0, $StepCount - 1)
  if ($Level -ge $last) { return $Level }
  if ($Cpu -ge 100 -and $Level -lt 2) { return [Math]::Min(2, $last) }
  if ($Cpu -ge $CritC) { return $Level + 1 }
  if ($Cpu -ge $HotC -and $HotLongEnough) {
    if ($Level -eq 0 -or $SinceStep -ge $MinStepSec) { return $Level + 1 }
  }
  return $Level
}

# Seconds the CPU must stay cool before a step is given back.
# The long anti-flap / post-spike hold guards only the return TO full turbo (stepping up
# from the turbo-off state) - that is the spike source. Restoring an intermediate cap
# (99/85/70 -> one notch up) uses the short cool-down, so a hot-but-cooling machine claws
# its way back to the 99% cap instead of dead-locking on the deepest one ("stuck at 55 %").
# $SpikeHold / $SpikeSeen are kept in the signature for the turbo-return contract; the
# post-spike since-spike gate is applied at the turbo-return call site, not to cap steps.
function Get-CpuRestoreWait([int]$Level, [double]$RestoreHold, [double]$CoolSeconds, [double]$SpikeHold, [bool]$SpikeSeen) {
  if ($Level -le 1) { return $RestoreHold }
  return $CoolSeconds
}

# Spikes is a List[datetime], mutated in place. Cpu and CoolSince may be $null.
function Update-TurboSticky($Now, [bool]$Spiked, $Cpu, [bool]$Sticky, $Spikes, $CoolSince, [int]$Repeat, [double]$WindowSec, [double]$CoolC, [double]$CoolSec) {
  $engaged = $false
  $released = $false
  if ($Spiked -and $Repeat -gt 0) {
    [void]$Spikes.Add($Now)
    for ($i = $Spikes.Count - 1; $i -ge 0; $i--) {
      if (($Now - $Spikes[$i]).TotalSeconds -gt $WindowSec) { $Spikes.RemoveAt($i) }
    }
    if ($Spikes.Count -ge $Repeat -and -not $Sticky) {
      $Sticky = $true
      $engaged = $true
      $CoolSince = $null
    }
  }
  if ($Sticky) {
    $cool = ($Cpu -ne $null -and [double]$Cpu -lt $CoolC)
    if (-not $cool) { $CoolSince = $null }
    elseif (-not $CoolSince) { $CoolSince = $Now }
    elseif (($Now - $CoolSince).TotalSeconds -ge $CoolSec) {
      $Sticky = $false
      $released = $true
      $CoolSince = $null
      $Spikes.Clear()
    }
  } else { $CoolSince = $null }
  return @{ Sticky = $Sticky; CoolSince = $CoolSince; Engaged = $engaged; Released = $released; Spikes = $Spikes.Count }
}
