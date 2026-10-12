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

# 1b. Rosa Guard SDK 1.2.2 (shared "SDK" component): bundle the OFFICIAL prebuilt bin\ unmodified - every file must match bin\SHA256SUMS.
#     Source: the official read-only release folder named by C:\Users\<you>\RosaGuard-SDK-LATEST.txt, else ..\RosaGuard-SDK
$sdkVer = '1.2.2'; $sdk = $null
$latest = Join-Path $env:USERPROFILE 'RosaGuard-SDK-LATEST.txt'
if (Test-Path $latest) { $c = (Get-Content $latest | Select-Object -First 1).Trim(); if ($c -and (Test-Path (Join-Path $c 'bin\VERSION')) -and (Get-Content (Join-Path $c 'bin\VERSION') -Raw).Trim() -eq $sdkVer) { $sdk = $c } }
if (-not $sdk) { $sdk = Join-Path (Split-Path $root -Parent) 'RosaGuard-SDK' }
$sums = Join-Path $sdk 'bin\SHA256SUMS'
if (-not (Test-Path $sums)) { throw "RosaGuard SDK bin\SHA256SUMS not found in $sdk" }
$listed = @()
foreach ($line in Get-Content $sums) {
  if ($line -notmatch '^([0-9a-f]{64})\s+\*?(.+)$') { continue }
  $f = Join-Path $sdk ('bin\' + $matches[2].Trim()); $want = $matches[1]; $listed += $matches[2].Trim()
  if (-not (Test-Path $f)) { throw "RosaGuard SDK: missing $f" }
  $got = (Get-FileHash $f -Algorithm SHA256).Hash.ToLower()
  if ($got -ne $want) { throw "RosaGuard SDK: $f does not match the official SHA256SUMS ($got)" }
}
$v = (Get-Content (Join-Path $sdk 'bin\VERSION') -Raw).Trim()
if ($v -ne $sdkVer) { throw "RosaGuard SDK: bin\VERSION is $v, expected $sdkVer" }
if (-not ($listed -contains 'RosaGuard.Interop.dll')) { throw 'RosaGuard SDK: RosaGuard.Interop.dll not listed in SHA256SUMS' }
$extra = Get-ChildItem (Join-Path $sdk 'bin') -File | Where-Object { $_.Extension -in '.dll', '.exe' -and $listed -notcontains $_.Name }
if ($extra) { throw "RosaGuard SDK: unlisted binaries in bin\: $($extra.Name -join ', ')" }
$srcHash = (Get-FileHash (Join-Path $sdk 'src\RosaGuard.Interop.cs') -Algorithm SHA256).Hash.ToLower()
if ($srcHash -ne ((Get-Content (Join-Path $sdk 'bin\RosaGuard.Interop.src.sha256') -Raw).Trim().Split(' ')[0].ToLower())) { throw 'RosaGuard SDK: src\RosaGuard.Interop.cs does not match bin\RosaGuard.Interop.src.sha256' }
Write-Host "RosaGuard SDK $v ($sdk): official bin\ verified"

# 2. compile
if (-not $Iscc) {
  $Iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $Iscc) { throw 'ISCC.exe (Inno Setup 6) not found - winget install JRSoftware.InnoSetup' }
& $Iscc /Q "/DRG_SdkSource=$sdk" (Join-Path $root 'installer\RosaThermalGuard.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC failed ($LASTEXITCODE)" }

# 3. checksums
Push-Location $dist
Get-ChildItem *.exe | ForEach-Object { '{0}  {1}' -f (Get-FileHash $_.Name -Algorithm SHA256).Hash.ToLower(), $_.Name } | Set-Content SHA256SUMS.txt -Encoding ASCII
Get-Content SHA256SUMS.txt
Pop-Location

