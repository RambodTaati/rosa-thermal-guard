# Rosa Thermal Guard - build script: fetches LibreHardwareMonitor, compiles the installer, writes SHA256SUMS.txt
param([string]$Iscc = '')
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root  = $PSScriptRoot
$build = Join-Path $root 'build'; $dist = Join-Path $root 'dist'
New-Item -ItemType Directory $build, $dist -Force | Out-Null

# 1. LibreHardwareMonitor (MPL-2.0), pinned release + hash
$lhmVer = 'v0.9.6'
$lhmSha = '086d9f1b5a99e643edc2cfaaac16051685b551e4c5ac0b32a57c58c0e529c001'
$zip = Join-Path $build "LibreHardwareMonitor-$lhmVer.zip"
if (-not (Test-Path $zip)) {
  [Net.ServicePointManager]::SecurityProtocol = 'Tls12'
  Invoke-WebRequest "https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/download/$lhmVer/LibreHardwareMonitor.zip" -OutFile $zip -UseBasicParsing
}
$h = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
if ($lhmSha -notlike '*PLACEHOLDER*' -and $h -ne $lhmSha) { throw "LibreHardwareMonitor zip hash mismatch: $h" }
Write-Host "LHM $lhmVer sha256 $h"
$x = Join-Path $build 'lhm'; Remove-Item $x -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive $zip $x -Force
$lib = Join-Path $build 'lib'; Remove-Item $lib -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory $lib | Out-Null
$skip = 'Aga.Controls.dll', 'OxyPlot.dll', 'OxyPlot.WindowsForms.dll', 'Microsoft.Win32.TaskScheduler.dll'
Get-ChildItem $x -Filter *.dll | Where-Object { $skip -notcontains $_.Name } | Copy-Item -Destination $lib
Get-ChildItem $lib | Unblock-File

# 2. compile
if (-not $Iscc) {
  $Iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $Iscc) { throw 'ISCC.exe (Inno Setup 6) not found - winget install JRSoftware.InnoSetup' }
& $Iscc /Q (Join-Path $root 'installer\RosaThermalGuard.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC failed ($LASTEXITCODE)" }

# 3. checksums
Push-Location $dist
Get-ChildItem *.exe | ForEach-Object { '{0}  {1}' -f (Get-FileHash $_.Name -Algorithm SHA256).Hash.ToLower(), $_.Name } | Set-Content SHA256SUMS.txt -Encoding ASCII
Get-Content SHA256SUMS.txt
Pop-Location

