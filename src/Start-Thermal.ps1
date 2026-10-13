# Rosa Thermal Guard - start the guard through its scheduled task and confirm it is running (1.3.3).
# Run elevated (by setup, or by Open.vbs through a UAC prompt). Exit 0 = running, 1 = did not start.
$log = Join-Path $env:ProgramData 'RosaThermalGuard\guard.log'
function Fresh([datetime]$since) { (Test-Path $log) -and (Get-Item $log).LastWriteTime -gt $since }
for ($try = 1; $try -le 3; $try++) {
    $since = Get-Date
    $state = (schtasks.exe /Query /TN RosaThermalGuard /FO CSV /NH 2>$null | ConvertFrom-Csv -Header n,next,status).status
    if ($state -ne 'Running') { & schtasks.exe /run /tn RosaThermalGuard | Out-Null }
    for ($i = 0; $i -lt 30; $i++) { Start-Sleep 1; if (Fresh $since) { exit 0 } }
}
exit 1