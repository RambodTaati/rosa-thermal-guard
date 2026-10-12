<#
  Rosa Thermal Guard - update checker (MIT License). Started by the guard about once a day, or from the
  tray menu. It only CHECKS, DOWNLOADS and VERIFIES; it never runs anything. The guard installs a verified
  update later, when the system is idle and cool (see ThermalGuard.ps1, "auto-update").
    - asks https://api.github.com/repos/RambodTaati/rosa-thermal-guard/releases/latest
    - newer semver only; assets must come from that release (github.com/<repo>/releases/download/<tag>/)
    - HTTPS only, also for every redirect, and only to GitHub hosts
    - RosaThermalGuard-Setup-<ver>.exe: name, size, PE header, version resource (product + version) checked
    - SHA-256 must match SHA256SUMS.txt of the same release and, when GitHub reports one, the API digest
  Result: <app>\update\ready.json (admin-only folder) + %ProgramData%\RosaThermalGuard\update-status.json
#>
param([switch]$Manual, [switch]$DryRun, [string]$AsVersion = '')
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$App = Split-Path -Parent $MyInvocation.MyCommand.Path
$Data = Join-Path $env:ProgramData 'RosaThermalGuard'
$Repo = 'RambodTaati/rosa-thermal-guard'
$Api = "https://api.github.com/repos/$Repo/releases/latest"
$UpdDir = Join-Path $App 'update'
$StatusFile = Join-Path $Data 'update-status.json'
$AllowedHosts = '^(github\.com|api\.github\.com|objects\.githubusercontent\.com|release-assets\.githubusercontent\.com|github-releases\.githubusercontent\.com)$'

function Log([string]$m) {
  $line = '{0} update: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  for ($i = 0; $i -lt 10; $i++) { try { Add-Content -Path (Join-Path $Data 'guard.log') -Value $line -Encoding UTF8 -ErrorAction Stop; break } catch { Start-Sleep -Milliseconds 150 } }
}
function Status([string]$r, [string]$latest, [string]$msg) {
  try { @{ at = (Get-Date).ToString('s'); result = $r; current = $script:cur; latest = $latest; manual = [bool]$Manual; message = $msg } | ConvertTo-Json | Set-Content $StatusFile -Encoding UTF8 } catch {}
}
# GET over HTTPS, following redirects by hand so every hop is HTTPS and a GitHub host
function Get-Https([string]$url, [string]$outFile = '', [long]$maxBytes = 64MB) {
  for ($hop = 0; $hop -lt 6; $hop++) {
    $u = [Uri]$url
    if ($u.Scheme -ne 'https' -or $u.Host -notmatch $AllowedHosts) { throw "refusing non-HTTPS or non-GitHub URL: $($u.Scheme)://$($u.Host)" }
    $rq = [Net.HttpWebRequest]::Create($u)
    $rq.AllowAutoRedirect = $false; $rq.Timeout = 30000; $rq.ReadWriteTimeout = 60000
    $rq.UserAgent = "RosaThermalGuard/$script:cur (+https://github.com/$Repo)"
    $rq.Accept = $(if ($outFile) { 'application/octet-stream' } else { 'application/vnd.github+json' })
    try { $rs = $rq.GetResponse() } catch [Net.WebException] { if ($_.Exception.Response) { $rs = $_.Exception.Response } else { throw } }
    try {
      $code = [int]$rs.StatusCode
      if ($code -ge 300 -and $code -lt 400) { $loc = $rs.Headers['Location']; if (-not $loc) { throw "redirect without Location" }; $url = ([Uri]::new($u, $loc)).AbsoluteUri; continue }
      if ($code -ne 200) { throw "HTTP $code from $($u.Host)" }
      if ($rs.ContentLength -gt $maxBytes) { throw "response too large ($($rs.ContentLength) bytes)" }
      $st = $rs.GetResponseStream()
      if ($outFile) {
        $fs = [IO.File]::Create($outFile)
        try { $buf = New-Object byte[] 65536; $tot = 0L; while (($n = $st.Read($buf, 0, $buf.Length)) -gt 0) { $tot += $n; if ($tot -gt $maxBytes) { throw 'download too large' }; $fs.Write($buf, 0, $n) } } finally { $fs.Close() }
        return $tot
      } else {
        $sr = New-Object IO.StreamReader($st, [Text.Encoding]::UTF8); try { return $sr.ReadToEnd() } finally { $sr.Close() }
      }
    } finally { $rs.Close() }
  }
  throw 'too many redirects'
}

$mtx = New-Object Threading.Mutex($false, 'Global\RosaThermalGuardUpdater')
if (-not $mtx.WaitOne(0)) { exit 3 }
$script:cur = '0.0.0'
try {
  $script:cur = $(if ($AsVersion) { $AsVersion } else { (Get-Content (Join-Path $App 'version.txt') -Raw).Trim() })
  $curV = [version]$script:cur
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Log ("checking for updates ({0}, current {1}{2})" -f $(if ($Manual) { 'manual' } else { 'scheduled' }), $script:cur, $(if ($DryRun) { ', dry run' } else { '' }))
  $rel = (Get-Https $Api -maxBytes 2MB) | ConvertFrom-Json
  $tag = [string]$rel.tag_name
  if ($rel.draft -or $rel.prerelease) { Log "latest release $tag is a draft/pre-release - ignored"; Status 'uptodate' $tag ''; exit 0 }
  if ($tag -notmatch '^v?(\d+)\.(\d+)\.(\d+)$') { throw "unexpected release tag '$tag'" }
  $newV = [version]("{0}.{1}.{2}" -f $matches[1], $matches[2], $matches[3]); $newS = $newV.ToString(3)
  if ($newV -le $curV) { Log "up to date ($script:cur, latest release $tag)"; Status 'uptodate' $newS ''; exit 0 }
  Log "new version available: $tag (current $script:cur)"

  $name = "RosaThermalGuard-Setup-$newS.exe"
  $prefix = "https://github.com/$Repo/releases/download/$tag/"
  $exeA = @($rel.assets | Where-Object { $_.name -eq $name })
  $sumA = @($rel.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' })
  if ($exeA.Count -ne 1 -or $sumA.Count -ne 1) { throw "release $tag does not have exactly one $name and SHA256SUMS.txt" }
  $exeA = $exeA[0]; $sumA = $sumA[0]
  foreach ($a in $exeA, $sumA) { if (-not ([string]$a.browser_download_url).StartsWith($prefix, [StringComparison]::Ordinal)) { throw "asset URL is not from release ${tag}: $($a.browser_download_url)" } }
  $size = [long]$exeA.size
  if ($size -lt 1MB -or $size -gt 60MB) { throw "installer size $size is not plausible" }

  New-Item $UpdDir -ItemType Directory -Force | Out-Null
  Get-ChildItem $UpdDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
  $sumPath = Join-Path $UpdDir 'SHA256SUMS.txt'; $part = Join-Path $UpdDir "$name.part"; $exe = Join-Path $UpdDir $name
  [void](Get-Https $sumA.browser_download_url $sumPath 64KB)
  $line = Get-Content $sumPath | Where-Object { $_ -match ('^([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($name) + '\s*$') } | Select-Object -First 1
  if (-not $line) { throw "SHA256SUMS.txt has no line for $name" }
  $want = ($line -split '\s+')[0].ToLower()
  Log "downloading $name ($([Math]::Round($size / 1MB, 1)) MB)"
  $got = Get-Https $exeA.browser_download_url $part 60MB
  if ($got -ne $size) { throw "downloaded $got bytes, the release says $size" }
  $hash = (Get-FileHash $part -Algorithm SHA256).Hash.ToLower()
  if ($hash -ne $want) { throw "SHA-256 mismatch: file $hash, SHA256SUMS.txt $want" }
  $dig = [string]$exeA.digest
  if ($dig -match '^sha256:([0-9a-fA-F]{64})$' -and $matches[1].ToLower() -ne $hash) { throw "SHA-256 mismatch with the GitHub API digest ($dig)" }
  # is it the installer we build?
  $fsr = [IO.File]::OpenRead($part); try { $mz = New-Object byte[] 2; [void]$fsr.Read($mz, 0, 2) } finally { $fsr.Close() }
  if ($mz[0] -ne 0x4D -or $mz[1] -ne 0x5A) { throw 'not a Windows executable' }
  $vi = [Diagnostics.FileVersionInfo]::GetVersionInfo($part)
  if (([string]$vi.ProductName).Trim() -ne 'Rosa Thermal Guard') { throw "unexpected product name '$($vi.ProductName)'" }
  if (-not ([string]$vi.FileVersion).Trim().StartsWith($newS)) { throw "installer version '$($vi.FileVersion)' does not match $newS" }
  Move-Item $part $exe -Force
  Log "verified ${name}: sha256 $hash matches SHA256SUMS.txt$(if ($dig) { ' and the GitHub digest' }), size $size, product '$(([string]$vi.ProductName).Trim())' $(([string]$vi.FileVersion).Trim())"
  if ($DryRun) { Remove-Item $exe, $sumPath -Force -ErrorAction SilentlyContinue; Log 'dry run - downloaded and verified, nothing kept'; Status 'verified' $newS 'dry run'; exit 0 }
  @{ version = $newS; tag = $tag; file = $name; sha256 = $hash; size = $size; at = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content (Join-Path $UpdDir 'ready.json') -Encoding ASCII
  Log "update $newS is ready - it installs when the PC is cool, idle and no game is running"
  Status 'ready' $newS ''
  exit 0
} catch {
  $m = $_.Exception.Message
  Log "update check failed: $m"
  Get-ChildItem $UpdDir -Filter '*.part' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
  if ($m -match 'mismatch|not a Windows|unexpected product|does not match|not from release|non-HTTPS') { Get-ChildItem $UpdDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue }
  Status 'error' '' $m
  exit 1
} finally { try { $mtx.ReleaseMutex() } catch {} }
