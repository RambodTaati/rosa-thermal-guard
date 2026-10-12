# Rosa Thermal Guard - registers the scheduled task (run elevated by the installer).
param([int]$Autostart = 1, [string]$Language = '')
$ErrorActionPreference = 'Stop'
$app = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($Language -and $Language -ne 'keep') {
  $cfgPath = Join-Path $app 'config.json'
  $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
  $cfg.language = $Language
  ($cfg | ConvertTo-Json -Depth 5) | Set-Content $cfgPath -Encoding UTF8
}
$data = Join-Path $env:ProgramData 'RosaThermalGuard'
if (-not (Test-Path $data)) { New-Item -ItemType Directory $data -Force | Out-Null }
$users = ([Security.Principal.SecurityIdentifier]'S-1-5-32-545').Translate([Security.Principal.NTAccount]).Value
$action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\wscript.exe" -Argument ('"{0}"' -f (Join-Path $app 'RunHidden.vbs')) -WorkingDirectory $app
$principal = New-ScheduledTaskPrincipal -GroupId $users -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
  -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
$args_ = @{ TaskName = 'RosaThermalGuard'; Action = $action; Principal = $principal; Settings = $settings; Force = $true
            Description = 'Rosa Thermal Guard - keeps CPU and GPU below 100 C' }
# upgrade: keep Rosa's "Start with Windows" choice from the app window (a disabled logon trigger stays disabled)
$keepOff = $false
try { $old = Get-ScheduledTask -TaskName RosaThermalGuard -ErrorAction Stop; $lt = @($old.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' }); $keepOff = ($lt.Count -gt 0 -and -not ($lt | Where-Object { $_.Enabled })) } catch {}
if ($Autostart -ne 0) { $args_.Trigger = New-ScheduledTaskTrigger -AtLogOn }
Register-ScheduledTask @args_ | Out-Null
if ($Autostart -ne 0 -and $keepOff) {
  $t = Get-ScheduledTask -TaskName RosaThermalGuard; foreach ($x in $t.Triggers) { $x.Enabled = $false }; Set-ScheduledTask -InputObject $t | Out-Null
}
