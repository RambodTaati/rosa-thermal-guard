# Rosa Thermal Guard - registers the scheduled task (run elevated by the installer).
param([int]$Autostart = 1, [string]$Language = '')
$ErrorActionPreference = 'Stop'
$app = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($Language) {
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
if ($Autostart -ne 0) { $args_.Trigger = New-ScheduledTaskTrigger -AtLogOn }
Register-ScheduledTask @args_ | Out-Null
