$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\src\GuardDecide.ps1')
$fail = 0
function Assert([bool]$cond, [string]$msg) {
  if (-not $cond) { Write-Host "FAIL $msg"; $script:fail++ } else { Write-Host "ok   $msg" }
}

Assert ((Get-ControlGapKind 10 1 $false) -eq 'ok') 'short gap is a normal poll'
Assert ((Get-ControlGapKind 40 1 $false) -eq 'stall') 'long gap without a power event is a stall'
Assert ((Get-ControlGapKind 40 1 $true) -eq 'resume') 'a real power resume resets, even after a long gap'
Assert ((Get-ControlGapKind 2 1 $true) -eq 'resume') 'power resume wins over a short gap'

Assert (Test-RiseSample 1.0 1) '1s gap is a valid rise sample'
Assert (-not (Test-RiseSample 10 1)) 'a 10s gap is not a deg/s spike'
Assert (-not (Test-RiseSample 0 1)) 'no gap is not a rise'

Assert (Test-SampleFresh 1.2 2.5) '1.2s sample is fresh'
Assert (-not (Test-SampleFresh 2.6 2.5)) '2.6s sample is stale'
Assert (-not (Test-SampleFresh -1 2.5)) 'negative age is stale'

Assert ([Math]::Abs((Get-HotSeconds 30 1 $true $true $false) - 30) -lt 0.001) 'hot across the gap counts the gap'
Assert ([Math]::Abs((Get-HotSeconds 30 1 $false $true $false) - 1) -lt 0.001) 'just became hot counts one poll'
Assert ((Get-HotSeconds 30 1 $true $true $true) -eq 0) 'sleep is a hole'
Assert ((Get-HotSeconds 30 1 $true $false $false) -eq 0) 'cool sample adds nothing'

Assert (Test-AllowTurboReturn $true 2) 'deeper than turbo-off can still step back'
Assert (-not (Test-AllowTurboReturn $true 1)) 'sticky blocks the return to turbo'
Assert (Test-AllowTurboReturn $false 1) 'a quiet chip can return to turbo'

Assert ((Get-CpuStepTarget 0 5 92 90 95 $false 0 6) -eq 0) 'a one-sample 92 C does not leave full turbo'
Assert ((Get-CpuStepTarget 0 5 92 90 95 $true 0 6) -eq 1) '92 C that lasts takes turbo off'
Assert ((Get-CpuStepTarget 1 5 93 90 95 $true 2 6) -eq 1) 'already limited, 93 C waits out the 6 s gap'
Assert ((Get-CpuStepTarget 1 5 93 90 95 $true 6 6) -eq 2) '93 C after 6 s steps to 85 percent'
Assert ((Get-CpuStepTarget 1 5 96 90 95 $false 1 6) -eq 2) '95 C steps at once even if the last step was recent'
Assert ((Get-CpuStepTarget 0 5 101 90 95 $false 0 6) -eq 2) '100 C goes straight to the 85 percent cap'
Assert ((Get-CpuStepTarget 2 5 101 90 95 $false 1 6) -eq 3) 'still at 100 C takes the next step'
Assert ((Get-CpuStepTarget 4 5 110 90 95 $true 20 6) -eq 4) 'the deepest step is the floor'

Assert ((Get-CpuRestoreWait 2 120 20 120 $true) -eq 20) 'a cap step-up uses the short cool-down even after a spike'
Assert ((Get-CpuRestoreWait 2 120 20 120 $false) -eq 20) 'a calm cap step-up uses the short cool-down'
Assert ((Get-CpuRestoreWait 4 600 20 600 $true) -eq 20) 'the 55% cap recovers to 70% on the short cool-down, not the 600s spike hold'
Assert ((Get-CpuRestoreWait 1 600 20 600 $true) -eq 600) 'the turbo return (99% -> 100%) keeps the full anti-flap hold'

$spikes = New-Object System.Collections.Generic.List[datetime]
$t0 = Get-Date
$r = Update-TurboSticky $t0 $true 96 $false $spikes $null 2 3600 75 600
Assert (-not $r.Sticky) 'one spike does not hold turbo'
Assert (-not $r.Engaged) 'one spike does not engage'
$r = Update-TurboSticky $t0.AddMinutes(8) $true 100 $r.Sticky $spikes $r.CoolSince 2 3600 75 600
Assert $r.Sticky 'second spike within the hour holds turbo'
Assert $r.Engaged 'the second spike is the moment turbo is held'
Assert ($r.CoolSince -eq $null) 'holding starts with the cool timer clear'

$r = Update-TurboSticky $t0.AddMinutes(9) $false 70 $r.Sticky $spikes $r.CoolSince 2 3600 75 600
Assert ($r.CoolSince -ne $null) 'under 75 C starts the release timer'
$mid = $r.CoolSince
$r = Update-TurboSticky $mid.AddSeconds(599) $false 74 $r.Sticky $spikes $r.CoolSince 2 3600 75 600
Assert $r.Sticky '599s under 75 C is not enough'
$r = Update-TurboSticky $mid.AddSeconds(600) $false 74 $r.Sticky $spikes $r.CoolSince 2 3600 75 600
Assert (-not $r.Sticky) '600s under 75 C releases turbo'
Assert $r.Released 'release is reported'
Assert ($spikes.Count -eq 0) 'a release clears the spike window'

$spikes = New-Object System.Collections.Generic.List[datetime]
$r = Update-TurboSticky $t0 $true 100 $false $spikes $null 2 3600 75 600
$r = Update-TurboSticky $t0.AddMinutes(1) $true 100 $r.Sticky $spikes $null 2 3600 75 600
$r = Update-TurboSticky $t0.AddMinutes(2) $false 70 $r.Sticky $spikes $r.CoolSince 2 3600 75 600
$r = Update-TurboSticky $t0.AddMinutes(3) $false 90 $r.Sticky $spikes $r.CoolSince 2 3600 75 600
Assert ($r.CoolSince -eq $null) 'leaving the cool band clears the release timer'
Assert $r.Sticky 'a warm reading does not release the hold'

if ($fail) { Write-Host "$fail failed"; exit 1 }
Write-Host 'all passed'
exit 0
