# Rosa Thermal Guard - stops the app, restores original settings and (unless -StopOnly) removes the task.
param([switch]$StopOnly)
$app = Split-Path -Parent $MyInvocation.MyCommand.Path
$data = Join-Path $env:ProgramData 'RosaThermalGuard'
if (Test-Path $data) { New-Item (Join-Path $data 'stop.flag') -ItemType File -Force | Out-Null }
$mine = { Get-CimInstance Win32_Process -Filter "Name='powershell.exe' or Name='wscript.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine -like "*$app*" -and $_.ProcessId -ne $PID } }
$t0 = Get-Date
while ((& $mine) -and ((Get-Date) - $t0).TotalSeconds -lt 25) { Start-Sleep -Milliseconds 500 }
Stop-ScheduledTask -TaskName RosaThermalGuard -ErrorAction SilentlyContinue
& $mine | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Remove-Item (Join-Path $data 'stop.flag') -Force -ErrorAction SilentlyContinue
# put back anything a killed instance left behind (power plan, GPU clocks)
& (Join-Path $app 'ThermalGuard.ps1') -Restore
if (-not $StopOnly) { Unregister-ScheduledTask -TaskName RosaThermalGuard -Confirm:$false -ErrorAction SilentlyContinue }
exit 0
