<#  Rosa Thermal Guard - tray app (MIT License)
    One hidden PowerShell process: the guard engine (ThermalGuard.ps1) runs in a background runspace,
    the UI is a tray icon (rose thermometer with the live CPU temperature) plus a compact dark WPF window (fa/en/ar/zh-CN).
    Rosa Guard suite IPC (thermal.pressure, cooldown and power leases, suite.gaming) runs in a third runspace (Suite.ps1);
    without the shared SDK component it simply does not start and the app behaves exactly like the standalone 1.2 release.
    Flag files in %ProgramData%\RosaThermalGuard: show.flag opens the window, snap.flag saves ui.png, report.flag opens the report window, graph.flag (open/close) toggles the graph, autostart.flag (on/off) sets Start with Windows,
    minimize.flag minimizes it, stop.flag exits cleanly (settings restored). #>
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Join-Path $env:ProgramData 'RosaThermalGuard'
if (-not (Test-Path $Root)) { New-Item -ItemType Directory $Root -Force | Out-Null }
$Inv = [Globalization.CultureInfo]::InvariantCulture
function UiLog([string]$m) { $line = "{0} [UI] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m; $b = [Text.Encoding]::UTF8.GetBytes($line + "`r`n"); for ($i = 0; $i -lt 6; $i++) { try { $fs = New-Object IO.FileStream((Join-Path $Root 'guard.log'), [IO.FileMode]::Append, [Security.AccessControl.FileSystemRights]::AppendData, [IO.FileShare]'ReadWrite, Delete', 4096, [IO.FileOptions]::None); try { $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }; break } catch { Start-Sleep -Milliseconds 30 } } }   # shared append: never locks out the guard

$uiMutex = New-Object Threading.Mutex($false, 'Global\RosaThermalGuardUI')
if (-not $uiMutex.WaitOne(0)) { exit 0 }

# ---------- guard engine in a runspace ----------
$sync = [hashtable]::Synchronized(@{ Stop = $false; PauseUntil = [datetime]::MinValue; Notify = $null })
$sync.Leases = [hashtable]::Synchronized(@{})
$script:guardPs = $null; $script:guardHandle = $null; $script:lastGuardStart = [datetime]::MinValue
# Rosa Guard suite IPC in its own runspace: never on the guard's thread, never blocking the UI. Missing/broken SDK = standalone.
$script:suitePs = $null; $script:suiteHandle = $null; $script:lastSuiteStart = [datetime]::MinValue
function Start-Suite {
  try {
    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({ param($s, $f, $a, $r) & $f -Sync $s -AppDir $a -Root $r }).AddArgument($sync).AddArgument((Join-Path $AppDir 'Suite.ps1')).AddArgument($AppDir).AddArgument($Root)
    $sync.SuiteStop = $false
    $script:suitePs = $ps; $script:suiteHandle = $ps.BeginInvoke(); $script:lastSuiteStart = Get-Date
  } catch { UiLog "suite worker could not start: $($_.Exception.Message)" }
}
function Start-Guard {
  $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.Open()
  $ps = [powershell]::Create(); $ps.Runspace = $rs
  [void]$ps.AddScript({ param($s, $f) & $f -Sync $s }).AddArgument($sync).AddArgument((Join-Path $AppDir 'ThermalGuard.ps1'))
  $script:guardPs = $ps; $script:guardHandle = $ps.BeginInvoke(); $script:lastGuardStart = Get-Date
  UiLog 'guard engine started'
}

# ---------- tray icon ----------
$script:iconHandle = [IntPtr]::Zero
. (Join-Path $AppDir 'TrayIcon.ps1')
if (-not ('RTG.Win' -as [type])) {
  Add-Type -Namespace RTG -Name Win -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool BringWindowToTop(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
"@
}
$script:iconSize = Get-TrayIconSize; $script:lightBar = Test-LightTaskbar; $script:lastTheme = Get-Date
function Set-TrayIcon([string]$hex, [string]$text) {
  $bmp = New-TrayBitmap $hex $text $script:iconSize $script:lightBar
  $h = $bmp.GetHicon(); $bmp.Dispose()
  $old = $notify.Icon
  $notify.Icon = [Drawing.Icon]::FromHandle($h)
  if ($old) { $old.Dispose() }
  if ($script:iconHandle -ne [IntPtr]::Zero) { [void][RTG.Native]::DestroyIcon($script:iconHandle) }
  $script:iconHandle = $h
}


# ---------- language: settings.json (user pick) > config.json > Windows UI language ----------
$LangDir = Join-Path $AppDir 'lang'
$UserSettings = Join-Path $Root 'settings.json'
$LangNames = [ordered]@{ 'fa' = 'فارسی'; 'en' = 'English'; 'ar' = 'العربية'; 'zh-CN' = '中文' }
function Get-UserSettings { try { return (Get-Content $UserSettings -Raw -ErrorAction Stop | ConvertFrom-Json) } catch { return $null } }
function Save-UserSettings([hashtable]$changes) {
  $h = [ordered]@{}; $u = Get-UserSettings
  if ($u) { foreach ($pp in $u.PSObject.Properties) { $h[$pp.Name] = $pp.Value } }
  foreach ($k in $changes.Keys) { $h[$k] = $changes[$k] }
  try { ($h | ConvertTo-Json) | Set-Content $UserSettings -Encoding UTF8 } catch {}
}
$script:graphOpen = $false; try { $script:graphOpen = [bool](Get-UserSettings).graphOpen } catch {}
function Get-LangCode {
  $code = $null
  try { $u = Get-Content $UserSettings -Raw -ErrorAction Stop | ConvertFrom-Json; if ($u.language) { $code = [string]$u.language } } catch {}
  if (-not $code -or $code -eq 'auto') {
    try { $c = Get-Content (Join-Path $AppDir 'config.json') -Raw -ErrorAction Stop | ConvertFrom-Json; if ($c.language) { $code = [string]$c.language } } catch {}
  }
  if (-not $code -or $code -eq 'auto') {
    $code = switch ((Get-UICulture).TwoLetterISOLanguageName) { 'fa' { 'fa' } 'ar' { 'ar' } 'zh' { 'zh-CN' } default { 'en' } }
  }
  if (-not (Test-Path (Join-Path $LangDir "$code.json"))) { $code = 'en' }
  return $code
}
function Load-Lang([string]$code) {
  $script:lang = $code
  $script:T = [IO.File]::ReadAllText((Join-Path $LangDir "$code.json"), [Text.Encoding]::UTF8) | ConvertFrom-Json
  $script:IsRtl = ($T.dir -eq 'RightToLeft')
}
function N([string]$s) { if ($T.digits -ne 'persian') { return $s }; $d = '۰۱۲۳۴۵۶۷۸۹'; -join ($s.ToCharArray() | ForEach-Object { if ($_ -ge '0' -and $_ -le '9') { $d[[int][string]$_] } else { $_ } }) }
Load-Lang (Get-LangCode)

# ---------- window ----------
function Get-ArcGeometry([double]$frac, [double]$radius = 62) {
  $frac = [Math]::Max(0.001, [Math]::Min(1.0, $frac))   # 1.0, not 1: [Math]::Min(1, x) picks the int overload and rounds x to 0 or 1 (the "ring suddenly full" bug)
  $cx = 75; $cy = 75; $r = $radius; $start = 135; $sweep = 270 * $frac
  $a1 = $start * [Math]::PI / 180; $a2 = ($start + $sweep) * [Math]::PI / 180
  $x1 = $cx + $r * [Math]::Cos($a1); $y1 = $cy + $r * [Math]::Sin($a1)
  $x2 = $cx + $r * [Math]::Cos($a2); $y2 = $cy + $r * [Math]::Sin($a2)
  $large = if ($sweep -gt 180) { 1 } else { 0 }
  [Windows.Media.Geometry]::Parse([string]::Format($Inv, 'M {0:F2},{1:F2} A {2},{2} 0 {3} 1 {4:F2},{5:F2}', $x1, $y1, $r, $large, $x2, $y2))
}
# ---------- temperature arcs: linear 0-100 C for CPU and GPU (60 C = 60 % filled, 100 C = full), clamped; eased toward the reading ----------
# rises ease with ~2 s, falls with ~1.2 s, so a single-sample turbo spike moves the arc a little instead of filling it
$script:arc = @{ Ct = $null; Cp = $null; Gt = $null; Gp = $null; Ck = ''; Gk = '' }
$script:arcLast = 0.0
function Arc-Frac($t, [double]$lo, [double]$hi) { if ($t -eq $null) { return 0.0 }; return [Math]::Max(0.0, [Math]::Min(1.0, ([double]$t - $lo) / ($hi - $lo))) }
function Step-ArcAnim([double]$now) {
  $dt = [Math]::Min(0.25, [Math]::Max(0.0, $now - $script:arcLast)); $script:arcLast = $now
  $a = $script:arc
  foreach ($k in 'C', 'G') {
    $tgt = $a["${k}t"]; if ($tgt -eq $null) { continue }
    $cur = $a["${k}p"]; if ($cur -eq $null) { $cur = [double]$tgt }
    $tau = if ($tgt -gt $cur) { 2.0 } else { 1.2 }
    $cur = $cur + ($tgt - $cur) * (1.0 - [Math]::Exp(-$dt / $tau)); $a["${k}p"] = $cur
    $hi = 100.0
    $f = Arc-Frac $cur 0.0 $hi
    $key = [string][Math]::Round($f * 600)          # redraw only when it moved visibly (0.45 deg)
    if ($key -ne $a["${k}k"]) { $a["${k}k"] = $key; $ui["${k}puArc"].Data = Get-ArcGeometry $f }
    $hex = Temp-Hex $cur
    if ($ui["${k}puArc"].Tag -ne $hex) { $ui["${k}puArc"].Tag = $hex; $ui["${k}puArc"].Stroke = Brush $hex }
  }
}
function Temp-Hex($t) { if ($t -eq $null) { '#4B5263' } elseif ($t -lt 80) { '#34D399' } elseif ($t -lt 90) { '#FBBF24' } elseif ($t -lt 95) { '#FB923C' } else { '#F43F5E' } }
function Get-TempBrush($t) {
  $hex = if ($t -eq $null) { '#4B5263' } elseif ($t -lt 80) { '#34D399' } elseif ($t -lt 90) { '#FBBF24' } elseif ($t -lt 95) { '#FB923C' } else { '#F43F5E' }
  New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex))
}
function Color([string]$hex) { [Windows.Media.ColorConverter]::ConvertFromString($hex) }
function Fade-Brush($brush, [string]$hex, [int]$ms = 450) {
  $c = Color $hex
  if ($brush.Color -eq $c) { return }
  if (-not $window.IsVisible) { $brush.BeginAnimation([Windows.Media.SolidColorBrush]::ColorProperty, $null); $brush.Color = $c; return }
  $an = New-Object Windows.Media.Animation.ColorAnimation($c, (New-Object Windows.Duration([TimeSpan]::FromMilliseconds($ms))))
  $ez = New-Object Windows.Media.Animation.QuadraticEase; $ez.EasingMode = 'EaseInOut'; $an.EasingFunction = $ez
  $brush.BeginAnimation([Windows.Media.SolidColorBrush]::ColorProperty, $an)
}
function Brush([string]$hex) { New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex)) }
$history = New-Object Collections.Generic.List[object]
$GMIN = 30; $GMAX = 110
function Update-Graph {
  $w = $ui.Graph.ActualWidth; if ($w -le 0) { $w = 330 }; $h = 90
  $y = { param($v) $h - (([Math]::Max($GMIN, [Math]::Min($GMAX, $v)) - $GMIN) / ($GMAX - $GMIN)) * $h }
  $ui.L100.X1 = 0; $ui.L100.X2 = $w; $ui.L100.Y1 = & $y 100; $ui.L100.Y2 = $ui.L100.Y1
  $ui.L90.X1 = 0; $ui.L90.X2 = $w; $ui.L90.Y1 = & $y 90; $ui.L90.Y2 = $ui.L90.Y1
  [Windows.Controls.Canvas]::SetLeft($ui.T100, 2); [Windows.Controls.Canvas]::SetTop($ui.T100, $ui.L100.Y1 - 12)
  $cp = New-Object Windows.Media.PointCollection; $gp = New-Object Windows.Media.PointCollection
  $n = 150; $step = $w / ($n - 1); $off = $n - $history.Count
  for ($i = 0; $i -lt $history.Count; $i++) {
    $x = ($off + $i) * $step
    if ($history[$i].C -ne $null) { $cp.Add((New-Object Windows.Point($x, (& $y $history[$i].C)))) }
    if ($history[$i].G -ne $null) { $gp.Add((New-Object Windows.Point($x, (& $y $history[$i].G)))) }
  }
  $ui.CpuLine.Points = $cp; $ui.GpuLine.Points = $gp
  # fan speed (% of each fan's own max) on a 0-100 % scale + fan-mode shading and a thin band at the bottom
  $fy = { param($v) ($h - 5) - ([Math]::Max(0.0, [Math]::Min(100.0, [double]$v)) / 100.0) * ($h - 10) }
  [Windows.Controls.Canvas]::SetLeft($ui.TFan, $w - 24); [Windows.Controls.Canvas]::SetTop($ui.TFan, (& $fy 100) - 4)
  $f1 = New-Object Windows.Media.PointCollection; $f2 = New-Object Windows.Media.PointCollection
  $sb = New-Object Windows.Media.GeometryGroup; $sm = New-Object Windows.Media.GeometryGroup
  $bb = New-Object Windows.Media.GeometryGroup; $bm = New-Object Windows.Media.GeometryGroup
  $runM = 0; $runStart = 0
  for ($i = 0; $i -le $history.Count; $i++) {
    $md = if ($i -lt $history.Count) { [int]$history[$i].M } else { -1 }
    if ($i -lt $history.Count) {
      $x = ($off + $i) * $step
      if ($history[$i].F1 -ne $null) { $f1.Add((New-Object Windows.Point($x, (& $fy $history[$i].F1)))) }
      if ($history[$i].F2 -ne $null) { $f2.Add((New-Object Windows.Point($x, (& $fy $history[$i].F2)))) }
    }
    if ($md -ne $runM) {
      if ($runM -gt 0 -and $i -gt $runStart) {
        $x0 = [Math]::Max(0.0, ($off + $runStart) * $step - $step / 2); $x1 = [Math]::Min($w, ($off + $i - 1) * $step + $step / 2)
        $shade = New-Object Windows.Media.RectangleGeometry (New-Object Windows.Rect($x0, 0, [Math]::Max(1.0, $x1 - $x0), $h))
        $band = New-Object Windows.Media.RectangleGeometry (New-Object Windows.Rect($x0, ($h - 3), [Math]::Max(1.0, $x1 - $x0), 3))
        if ($runM -ge 2) { $sm.Children.Add($shade); $bm.Children.Add($band) } else { $sb.Children.Add($shade); $bb.Children.Add($band) }
      }
      $runM = $md; $runStart = $i
    }
  }
  $ui.Fan1Line.Points = $f1; $ui.Fan2Line.Points = $f2
  # game mode: thin violet band along the top
  $gg = New-Object Windows.Media.GeometryGroup; $gs = -1
  for ($i = 0; $i -le $history.Count; $i++) {
    $on = ($i -lt $history.Count) -and [bool]$history[$i].GM
    if ($on -and $gs -lt 0) { $gs = $i }
    if (-not $on -and $gs -ge 0) {
      $x0 = [Math]::Max(0.0, ($off + $gs) * $step - $step / 2); $x1 = [Math]::Min($w, ($off + $i - 1) * $step + $step / 2)
      $gg.Children.Add((New-Object Windows.Media.RectangleGeometry (New-Object Windows.Rect($x0, 0, [Math]::Max(1.0, $x1 - $x0), 3)))); $gs = -1
    }
  }
  $ui.GameBand.Data = $gg
  $ui.ShadeBoost.Data = $sb; $ui.ShadeMax.Data = $sm; $ui.BandBoost.Data = $bb; $ui.BandMax.Data = $bm
  $ui.TFan.Visibility = $(if ($f1.Count -gt 0 -or $f2.Count -gt 0) { 'Visible' } else { 'Collapsed' })
}

# Shows the window, restores it if Windows left it minimized (iconic) and brings it to the front.
# WPF can report IsVisible=True while the HWND is iconic (e.g. after Win+D / minimize -> Hide), so the
# native state is checked and SW_RESTORE is used before positioning.
function Show-Window([string]$why = '') {
  try {
    if ($window.WindowState -ne 'Normal') { $window.WindowState = 'Normal' }
    $window.Show()
    $h = (New-Object Windows.Interop.WindowInteropHelper $window).Handle
    if ($h -ne [IntPtr]::Zero -and [RTG.Win]::IsIconic($h)) { [void][RTG.Win]::ShowWindow($h, 9) }   # SW_RESTORE
    $wa = [Windows.SystemParameters]::WorkArea
    $window.Left = $wa.Right - 400 - 4
    $window.UpdateLayout()
    $window.Top = $wa.Bottom - $window.ActualHeight - 4
    $window.Topmost = $false; $window.Topmost = $true
    if ($h -ne [IntPtr]::Zero) { [void][RTG.Win]::BringWindowToTop($h); [void][RTG.Win]::SetForegroundWindow($h) }
    [void]$window.Activate()
    if ($why) { UiLog "window shown ($why)" }
  } catch { UiLog "show window error: $($_.Exception.Message)" }
}
function Set-GraphOpen([bool]$open, [bool]$animate) {
  $script:graphOpen = $open
  $ui.GraphBtnText.Text = $(if ($open) { $T.hideGraph } else { $T.showGraph })
  $rt = $ui.GraphChev.RenderTransform; $deg = $(if ($open) { 180.0 } else { 0.0 })
  if ($animate -and $window.IsVisible) {
    $ra = New-Object Windows.Media.Animation.DoubleAnimation($deg, (New-Object Windows.Duration([TimeSpan]::FromMilliseconds(240))))
    $re = New-Object Windows.Media.Animation.CubicEase; $re.EasingMode = 'EaseOut'; $ra.EasingFunction = $re
    $rt.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $ra)
  } else { $rt.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $null); $rt.Angle = $deg }
  $hp = [Windows.FrameworkElement]::HeightProperty
  if ($open) { try { Update-Graph } catch {} }
  if (-not $animate -or -not $window.IsVisible) {
    $ui.GraphWrap.BeginAnimation($hp, $null); $ui.GraphWrap.Height = $(if ($open) { [double]::NaN } else { 0.0 }); return
  }
  $w = [Math]::Max(100.0, $ui.GraphBtn.ActualWidth)
  $ui.GraphPanel.Measure((New-Object Windows.Size($w, [double]::PositiveInfinity)))
  $from = $ui.GraphWrap.ActualHeight; $to = $(if ($open) { $ui.GraphPanel.DesiredSize.Height } else { 0.0 })
  $an = New-Object Windows.Media.Animation.DoubleAnimation($from, $to, (New-Object Windows.Duration([TimeSpan]::FromMilliseconds(240))))
  $ez = New-Object Windows.Media.Animation.CubicEase; $ez.EasingMode = 'EaseOut'; $an.EasingFunction = $ez
  $an.Add_Completed({ $ui.GraphWrap.BeginAnimation([Windows.FrameworkElement]::HeightProperty, $null); $ui.GraphWrap.Height = $(if ($script:graphOpen) { [double]::NaN } else { 0.0 }) })
  $ui.GraphWrap.BeginAnimation($hp, $an)
}
function Toggle-Pause {
  if ($sync.PauseUntil -gt (Get-Date)) { $sync.PauseUntil = [datetime]::MinValue; UiLog 'resume clicked' }
  else { $sync.PauseUntil = (Get-Date).AddMinutes(15); UiLog 'pause 15 min clicked' }
}
# ---------- start with Windows = the logon trigger of the RosaThermalGuard task (enabled/disabled, never deleted, so the
# Start-menu shortcut can still run the task). Task Scheduler calls take 1-3 s: they run in a short-lived runspace.
$script:autoOn = $null; $script:autoJob = $null
function Start-AutoJob([string]$op) {
  if ($script:autoJob) { return }
  $rs = [runspacefactory]::CreateRunspace(); $rs.Open(); $ps = [powershell]::Create(); $ps.Runspace = $rs
  [void]$ps.AddScript({ param($op)
    try {
      $t = Get-ScheduledTask -TaskName RosaThermalGuard -ErrorAction Stop
      $lt = @($t.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' })
      if ($op -eq 'on') { if ($lt.Count) { foreach ($x in $lt) { $x.Enabled = $true } } else { $nt = New-ScheduledTaskTrigger -AtLogOn; $nt.Delay = 'PT15S'; $t.Triggers = @($t.Triggers) + @($nt) }; [void](Set-ScheduledTask -InputObject $t -ErrorAction Stop) }
      elseif ($op -eq 'off' -and $lt.Count) { foreach ($x in $lt) { $x.Enabled = $false }; [void](Set-ScheduledTask -InputObject $t -ErrorAction Stop) }
      $t = Get-ScheduledTask -TaskName RosaThermalGuard -ErrorAction Stop
      [bool](@($t.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' -and $_.Enabled }).Count)
    } catch { 'error: ' + $_.Exception.Message }
  }).AddArgument($op)
  $script:autoJob = @{ Ps = $ps; H = $ps.BeginInvoke(); Op = $op }
}
function Poll-AutoJob {
  $j = $script:autoJob; if (-not $j -or -not $j.H.IsCompleted) { return }
  $script:autoJob = $null
  $r = $null; try { $r = @($j.Ps.EndInvoke($j.H))[0] } catch { $r = "error: $($_.Exception.Message)" }
  try { $j.Ps.Runspace.Dispose(); $j.Ps.Dispose() } catch {}
  if ($r -is [bool]) { $script:autoOn = $r; if ($j.Op -ne 'get') { UiLog ("start with Windows -> " + $(if ($r) { 'on' } else { 'off' })) } }
  else { UiLog "start with Windows ($($j.Op)) failed: $r"; if ($j.Op -ne 'get') { $script:autoOn = -not $script:autoOn }; Start-AutoJob 'get' }
  Set-AutoUi $true
}
function Toggle-AutoStart {
  if ($script:autoJob -or $script:autoOn -eq $null) { return }
  $script:autoOn = -not $script:autoOn; Set-AutoUi $true          # optimistic, confirmed (or reverted) by Poll-AutoJob
  Start-AutoJob $(if ($script:autoOn) { 'on' } else { 'off' })
}
function Set-AutoUi([bool]$animate) {
  if (-not $ui.AutoKnob) { return }
  $on = [bool]$script:autoOn
  $ui.AutoRow.Opacity = $(if ($script:autoOn -eq $null) { 0.55 } else { 1.0 })
  $x = $(if ($on) { 16.0 } else { 0.0 }); $tt = $ui.AutoKnob.RenderTransform
  if ($animate -and $window.IsVisible) {
    $an = New-Object Windows.Media.Animation.DoubleAnimation($x, (New-Object Windows.Duration([TimeSpan]::FromMilliseconds(180))))
    $ez = New-Object Windows.Media.Animation.CubicEase; $ez.EasingMode = 'EaseOut'; $an.EasingFunction = $ez
    $tt.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $an)
  } else { $tt.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $null); $tt.X = $x }
  Fade-Brush $ui.AutoTrack.Background $(if ($on) { '#FFDB2777' } else { '#FF2A2730' }) 180
  Fade-Brush $ui.AutoKnob.Fill $(if ($on) { '#FFFFFFFF' } else { '#FF8C8796' }) 180
}
. (Join-Path $AppDir 'Report.ps1')   # graphical report window (Show-Report)
function Build-Window {
$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Rosa Thermal Guard" Width="400" SizeToContent="Height" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="NoResize" ShowInTaskbar="False" Topmost="True"
        FontFamily="{{font}}" UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display" TextOptions.TextHintingMode="Fixed">
  <!-- palette (rose identity): card #17161C, panel #1E1C24, control #24212B, track #2A2730, line #2B2731,
       text #F4F1F6 / #C9C5D1 / #8C8796, accent rose #DB2777 / #F472B6 / #FBCFE8. State colours stay semantic. -->
  <Border x:Name="Card" Margin="14" CornerRadius="18" Background="#FF17161C" BorderBrush="#FF2B2731" BorderThickness="1" Padding="18,16,18,16" FlowDirection="{{dir}}">
    <Border.Effect><DropShadowEffect BlurRadius="22" ShadowDepth="3" Opacity="0.5" Color="#000000"/></Border.Effect>
    <StackPanel>
      <!-- header: brand mark + title | minimise, close -->
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Canvas Width="16" Height="22" VerticalAlignment="Center" FlowDirection="LeftToRight">
            <Path Data="M5,3.2 A3,3 0 0 1 11,3.2 L11,12.6 A5,5 0 1 1 5,12.6 Z" Stroke="#FFDB2777" StrokeThickness="1.6" StrokeLineJoin="Round" Fill="#1FDB2777"/>
            <Rectangle Canvas.Left="7" Canvas.Top="7" Width="2" Height="9" RadiusX="1" RadiusY="1" Fill="#FFF472B6"/>
            <Ellipse Canvas.Left="5.4" Canvas.Top="14" Width="5.2" Height="5.2" Fill="#FFF472B6"/>
          </Canvas>
          <TextBlock Text="{{title}}" Foreground="#FFF4F1F6" FontSize="16" FontWeight="SemiBold" Margin="10,0,0,1" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Border x:Name="MinBtn" Width="28" Height="28" CornerRadius="14" Cursor="Hand" Margin="0,0,6,0" ToolTip="{{minTip}}">
            <Rectangle Width="10" Height="1.6" Fill="#FFC9C5D1" HorizontalAlignment="Center" VerticalAlignment="Center" RadiusX="0.8" RadiusY="0.8"/>
          </Border>
          <Border x:Name="CloseBtn" Width="28" Height="28" CornerRadius="14" Cursor="Hand" ToolTip="{{closeTip}}">
            <Path Data="M0,0 L9,9 M9,0 L0,9" Stroke="#FFC9C5D1" StrokeThickness="1.6" StrokeStartLineCap="Round" StrokeEndLineCap="Round" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
        </StackPanel>
      </Grid>
      <!-- status pill: state dot + text, colours cross-fade -->
      <Border x:Name="Pill" HorizontalAlignment="Left" Margin="0,14,0,0" CornerRadius="12" Padding="10,4,12,5" MinHeight="24">
        <StackPanel Orientation="Horizontal">
          <Ellipse x:Name="Dot" Width="8" Height="8" VerticalAlignment="Center" Margin="0,1,8,0"/>
          <TextBlock x:Name="StatusText" Text="{{stWait}}" FontSize="12.5" FontWeight="SemiBold" VerticalAlignment="Center" TextWrapping="Wrap" MaxWidth="300"/>
        </StackPanel>
      </Border>
      <!-- temperature rings -->
      <Grid Margin="0,12,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" HorizontalAlignment="Center">
          <Grid x:Name="CpuRing" Background="Transparent" Width="150" Height="150" FlowDirection="LeftToRight">
            <Path x:Name="CpuTrack" Stroke="#FF2A2730" StrokeThickness="10" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
            <Path x:Name="CpuArc" Stroke="#34D399" StrokeThickness="10" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
            <Path x:Name="CpuFanTrack" Stroke="#FF211F27" StrokeThickness="3" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
            <Path x:Name="CpuFanArc" Stroke="#FF0EA5E9" StrokeThickness="3" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
            <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center" Margin="0,4,0,0">
              <TextBlock x:Name="CpuVal" Text="--°" Foreground="#FFF4F1F6" FontSize="34" FontWeight="Light" HorizontalAlignment="Center" TextOptions.TextFormattingMode="Ideal" FontFamily="Segoe UI Variable Display, Segoe UI"/>
              <TextBlock Text="CPU" Foreground="#FF8C8796" FontSize="11" HorizontalAlignment="Center" Margin="0,-2,0,0" FontFamily="Segoe UI"/>
            </StackPanel>
          </Grid>
          <TextBlock Text="{{cpuTemp}}" Foreground="#FFC9C5D1" FontSize="12.5" HorizontalAlignment="Center" Margin="0,0,0,0" TextTrimming="CharacterEllipsis" MaxWidth="160"/>
        </StackPanel>
        <StackPanel Grid.Column="1" HorizontalAlignment="Center">
          <Grid x:Name="GpuRing" Background="Transparent" Width="150" Height="150" FlowDirection="LeftToRight">
            <Path x:Name="GpuTrack" Stroke="#FF2A2730" StrokeThickness="10" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
            <Path x:Name="GpuArc" Stroke="#60A5FA" StrokeThickness="10" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
            <Path x:Name="GpuFanTrack" Stroke="#FF211F27" StrokeThickness="3" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
            <Path x:Name="GpuFanArc" Stroke="#FF0EA5E9" StrokeThickness="3" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
            <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center" Margin="0,4,0,0">
              <TextBlock x:Name="GpuVal" Text="--°" Foreground="#FFF4F1F6" FontSize="34" FontWeight="Light" HorizontalAlignment="Center" TextOptions.TextFormattingMode="Ideal" FontFamily="Segoe UI Variable Display, Segoe UI"/>
              <TextBlock x:Name="GpuSub" Text="GPU" Foreground="#FF8C8796" FontSize="11" HorizontalAlignment="Center" Margin="0,-2,0,0"/>
            </StackPanel>
          </Grid>
          <TextBlock Text="{{gpuTemp}}" Foreground="#FFC9C5D1" FontSize="12.5" HorizontalAlignment="Center" TextTrimming="CharacterEllipsis" MaxWidth="160"/>
        </StackPanel>
      </Grid>
      <!-- limits + fans -->
      <Border Margin="0,16,0,0" CornerRadius="14" Background="#FF1E1C24" Padding="14,12,14,12">
        <StackPanel>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBlock Text="{{cpuMax}}" Foreground="#FF8C8796" FontSize="12.5" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Margin="0,0,10,0"/>
            <TextBlock Grid.Column="1" x:Name="MaxPct" Text="100" Foreground="#FFF4F1F6" FontSize="12.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
          </Grid>
          <Grid Margin="0,8,0,0">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBlock Text="{{gpuCtl}}" Foreground="#FF8C8796" FontSize="12.5" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Margin="0,0,10,0"/>
            <TextBlock Grid.Column="1" x:Name="GpuLimit" Text="—" Foreground="#FFF4F1F6" FontSize="12.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
          </Grid>
          <Border Height="1" Background="#FF2B2731" Margin="0,12,0,10"/>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBlock Text="{{fans}}" Foreground="#FF8C8796" FontSize="12.5" VerticalAlignment="Center"/>
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
              <Border x:Name="GameBadge" Visibility="Collapsed" VerticalAlignment="Center" CornerRadius="10" Padding="9,2,9,3" Margin="0,0,6,0" Background="#338B5CF6">
                <TextBlock x:Name="GameBadgeText" Text="{{gameMode}}" Foreground="#FFC4B5FD" FontSize="11.5" FontWeight="SemiBold"/>
              </Border>
              <Border x:Name="FanBadge" VerticalAlignment="Center" CornerRadius="10" Padding="9,2,9,3" Background="#2660A5FA">
                <TextBlock x:Name="FanBadgeText" Text="-" Foreground="#FF60A5FA" FontSize="11.5" FontWeight="SemiBold"/>
              </Border>
            </StackPanel>
          </Grid>
          <StackPanel Grid.IsSharedSizeScope="True">
            <Grid x:Name="FanRow1" Margin="0,10,0,0" Background="Transparent">
              <Grid.ColumnDefinitions><ColumnDefinition Width="26"/><ColumnDefinition Width="Auto" SharedSizeGroup="FanLbl"/><ColumnDefinition Width="*"/><ColumnDefinition Width="44"/></Grid.ColumnDefinitions>
              <Canvas Grid.Column="0" Width="18" Height="18" HorizontalAlignment="Left" VerticalAlignment="Center" FlowDirection="LeftToRight">
                <Ellipse Width="18" Height="18" Fill="#FF26232D"/>
                <Path x:Name="Fan1Icon" Fill="#FF34D399" Data="M9.00,7.20 C8.20,3.50 10.50,0.60 13.20,1.80 C14.60,3.20 12.40,6.40 10.40,8.20 Z M10.80,9.00 C14.50,8.20 17.40,10.50 16.20,13.20 C14.80,14.60 11.60,12.40 9.80,10.40 Z M9.00,10.80 C9.80,14.50 7.50,17.40 4.80,16.20 C3.40,14.80 5.60,11.60 7.60,9.80 Z M7.20,9.00 C3.50,9.80 0.60,7.50 1.80,4.80 C3.20,3.40 6.40,5.60 8.20,7.60 Z">
                  <Path.RenderTransform><RotateTransform CenterX="9" CenterY="9"/></Path.RenderTransform>
                </Path>
                <Ellipse Canvas.Left="6.5" Canvas.Top="6.5" Width="5" Height="5" Fill="#FF1E1C24" Stroke="#FF8C8796" StrokeThickness="0.8"/>
              </Canvas>
              <TextBlock Grid.Column="1" Text="{{cpu}}" Foreground="#FFC9C5D1" FontSize="12.5" VerticalAlignment="Center" Margin="2,0,12,0"/>
              <Grid Grid.Column="2" x:Name="Fan1Track" Height="6" VerticalAlignment="Center">
                <Border CornerRadius="3" Background="#FF2A2730"/>
                <Border x:Name="Fan1Fill" CornerRadius="3" HorizontalAlignment="Left" Width="0" Background="#FF34D399"/>
              </Grid>
              <TextBlock Grid.Column="3" x:Name="Fan1Pct" Text="" Foreground="#FF8C8796" FontSize="11.5" HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </Grid>
            <Grid x:Name="FanRow2" Margin="0,8,0,0" Background="Transparent">
              <Grid.ColumnDefinitions><ColumnDefinition Width="26"/><ColumnDefinition Width="Auto" SharedSizeGroup="FanLbl"/><ColumnDefinition Width="*"/><ColumnDefinition Width="44"/></Grid.ColumnDefinitions>
              <Canvas Grid.Column="0" Width="18" Height="18" HorizontalAlignment="Left" VerticalAlignment="Center" FlowDirection="LeftToRight">
                <Ellipse Width="18" Height="18" Fill="#FF26232D"/>
                <Path x:Name="Fan2Icon" Fill="#FF34D399" Data="M9.00,7.20 C8.20,3.50 10.50,0.60 13.20,1.80 C14.60,3.20 12.40,6.40 10.40,8.20 Z M10.80,9.00 C14.50,8.20 17.40,10.50 16.20,13.20 C14.80,14.60 11.60,12.40 9.80,10.40 Z M9.00,10.80 C9.80,14.50 7.50,17.40 4.80,16.20 C3.40,14.80 5.60,11.60 7.60,9.80 Z M7.20,9.00 C3.50,9.80 0.60,7.50 1.80,4.80 C3.20,3.40 6.40,5.60 8.20,7.60 Z">
                  <Path.RenderTransform><RotateTransform CenterX="9" CenterY="9"/></Path.RenderTransform>
                </Path>
                <Ellipse Canvas.Left="6.5" Canvas.Top="6.5" Width="5" Height="5" Fill="#FF1E1C24" Stroke="#FF8C8796" StrokeThickness="0.8"/>
              </Canvas>
              <TextBlock Grid.Column="1" Text="{{gpu}}" Foreground="#FFC9C5D1" FontSize="12.5" VerticalAlignment="Center" Margin="2,0,12,0"/>
              <Grid Grid.Column="2" x:Name="Fan2Track" Height="6" VerticalAlignment="Center">
                <Border CornerRadius="3" Background="#FF2A2730"/>
                <Border x:Name="Fan2Fill" CornerRadius="3" HorizontalAlignment="Left" Width="0" Background="#FF34D399"/>
              </Grid>
              <TextBlock Grid.Column="3" x:Name="Fan2Pct" Text="" Foreground="#FF8C8796" FontSize="11.5" HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </Grid>
          </StackPanel>
        </StackPanel>
      </Border>
      <!-- graph toggle -->
      <Border x:Name="GraphBtn" Margin="0,10,0,0" CornerRadius="12" Padding="12,7,12,8" Cursor="Hand" MinHeight="34">
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
          <Path x:Name="GraphChev" Data="M0,0 L4.5,4.5 L9,0" Stroke="#FFF472B6" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                Width="9" Height="5" VerticalAlignment="Center" Margin="0,1,8,0" RenderTransformOrigin="0.5,0.5">
            <Path.RenderTransform><RotateTransform Angle="0"/></Path.RenderTransform>
          </Path>
          <TextBlock x:Name="GraphBtnText" Text="{{showGraph}}" Foreground="#FFC9C5D1" FontSize="12.5" VerticalAlignment="Center"/>
        </StackPanel>
      </Border>
      <Border x:Name="GraphWrap" Height="0" ClipToBounds="True">
        <StackPanel x:Name="GraphPanel" VerticalAlignment="Top">
          <Grid Margin="2,12,2,6">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBlock Text="{{last5}}" Foreground="#FF8C8796" FontSize="12" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
              <Ellipse Width="8" Height="8" Fill="#FB923C" VerticalAlignment="Center"/>
              <TextBlock Text="{{cpu}}" Foreground="#FF8C8796" FontSize="12" Margin="5,0,12,0"/>
              <Ellipse Width="8" Height="8" Fill="#60A5FA" VerticalAlignment="Center"/>
              <TextBlock Text="{{gpu}}" Foreground="#FF8C8796" FontSize="12" Margin="5,0,0,0"/>
            </StackPanel>
          </Grid>
          <Border CornerRadius="14" Background="#FF1E1C24" Padding="8" FlowDirection="LeftToRight">
            <Canvas x:Name="Graph" Height="90" ClipToBounds="True">
              <Line x:Name="L100" Stroke="#66F43F5E" StrokeThickness="1" StrokeDashArray="4 3"/>
              <Line x:Name="L90" Stroke="#44FBBF24" StrokeThickness="1" StrokeDashArray="2 4"/>
              <TextBlock x:Name="T100" Text="100°" Foreground="#99F43F5E" FontSize="9"/>
              <Path x:Name="ShadeBoost" Fill="#12FBBF24"/>
              <Path x:Name="ShadeMax" Fill="#1CF43F5E"/>
              <Path x:Name="BandBoost" Fill="#CCFBBF24"/>
              <Path x:Name="BandMax" Fill="#DDF43F5E"/>
              <Path x:Name="GameBand" Fill="#DD8B5CF6"/>
              <TextBlock x:Name="TFan" Text="100%" Foreground="#992DD4BF" FontSize="9"/>
              <Polyline x:Name="Fan2Line" Stroke="#C4B5FD" StrokeThickness="1.3" StrokeDashArray="3 2" StrokeLineJoin="Round" Opacity="0.85"/>
              <Polyline x:Name="Fan1Line" Stroke="#2DD4BF" StrokeThickness="1.3" StrokeDashArray="3 2" StrokeLineJoin="Round" Opacity="0.85"/>
              <Polyline x:Name="GpuLine" Stroke="#60A5FA" StrokeThickness="1.8" StrokeLineJoin="Round"/>
              <Polyline x:Name="CpuLine" Stroke="#FB923C" StrokeThickness="1.8" StrokeLineJoin="Round"/>
            </Canvas>
          </Border>
          <WrapPanel x:Name="FanLegend" HorizontalAlignment="Center" Margin="0,8,0,2">
            <StackPanel Orientation="Horizontal" Margin="0,2,8,2"><Line X1="0" Y1="0" X2="10" Y2="0" Stroke="#2DD4BF" StrokeThickness="1.6" StrokeDashArray="3 2" VerticalAlignment="Center"/><TextBlock Text="{{lgCpuFan}}" Foreground="#FF8C8796" FontSize="10.5" Margin="3,0,0,0"/></StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,2,8,2"><Line X1="0" Y1="0" X2="10" Y2="0" Stroke="#C4B5FD" StrokeThickness="1.6" StrokeDashArray="3 2" VerticalAlignment="Center"/><TextBlock Text="{{lgGpuFan}}" Foreground="#FF8C8796" FontSize="10.5" Margin="3,0,0,0"/></StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,2,8,2"><Rectangle Width="10" Height="4" RadiusX="1" RadiusY="1" Fill="#CCFBBF24" VerticalAlignment="Center"/><TextBlock Text="{{lgBoost}}" Foreground="#FF8C8796" FontSize="10.5" Margin="3,0,0,0"/></StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,2,8,2"><Rectangle Width="10" Height="4" RadiusX="1" RadiusY="1" Fill="#DDF43F5E" VerticalAlignment="Center"/><TextBlock Text="{{lgMax}}" Foreground="#FF8C8796" FontSize="10.5" Margin="3,0,0,0"/></StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,2,0,2"><Rectangle Width="10" Height="4" RadiusX="1" RadiusY="1" Fill="#DD8B5CF6" VerticalAlignment="Center"/><TextBlock Text="{{gameMode}}" Foreground="#FF8C8796" FontSize="10.5" Margin="3,0,0,0"/></StackPanel>
          </WrapPanel>
        </StackPanel>
      </Border>
      <!-- start with Windows: logon trigger of the RosaThermalGuard task (starts hidden in the tray) -->
      <Border x:Name="AutoRow" Margin="0,10,0,0" CornerRadius="12" Background="#FF1E1C24" Padding="14,8,12,8" Cursor="Hand" ToolTip="{{autoStartTip}}" MinHeight="36">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBlock Text="{{autoStart}}" Foreground="#FFC9C5D1" FontSize="12.5" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Margin="0,0,10,0"/>
          <Border Grid.Column="1" x:Name="AutoTrack" Width="34" Height="18" CornerRadius="9" Background="#FF2A2730" VerticalAlignment="Center">
            <Ellipse x:Name="AutoKnob" Width="12" Height="12" Fill="#FF8C8796" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="3,0,0,0">
              <Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform>
            </Ellipse>
          </Border>
        </Grid>
      </Border>
      <!-- actions -->
      <Grid Margin="0,12,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="10"/><ColumnDefinition/></Grid.ColumnDefinitions>
        <Border x:Name="PauseBtn" Grid.Column="0" CornerRadius="12" Padding="8,9,8,10" Cursor="Hand" MinHeight="38">
          <TextBlock x:Name="PauseText" Text="{{pause15}}" Foreground="#FFF4F1F6" FontSize="13" HorizontalAlignment="Center" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
        </Border>
        <Border x:Name="LogBtn" Grid.Column="2" CornerRadius="12" Padding="8,9,8,10" Cursor="Hand" MinHeight="38">
          <TextBlock Text="{{report}}" Foreground="#FFF4F1F6" FontSize="13" HorizontalAlignment="Center" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
        </Border>
      </Grid>
      <StackPanel x:Name="LangBar" Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,12,0,0" FlowDirection="LeftToRight"/>
    </StackPanel>
  </Border>
</Window>
'@
foreach ($p in $T.PSObject.Properties) { $xamlText = $xamlText.Replace('{{' + $p.Name + '}}', [Security.SecurityElement]::Escape([string]$p.Value)) }
[xml]$xaml = $xamlText
$script:window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$script:ui = @{}
foreach ($n in 'GraphBtn','GraphChev','GraphBtnText','GraphWrap','GraphPanel','CpuRing','GpuRing','CpuFanTrack','CpuFanArc','GpuFanTrack','GpuFanArc','Card','Dot','CloseBtn','MinBtn','Pill','StatusText','CpuTrack','CpuArc','CpuVal','GpuTrack','GpuArc','GpuVal','GpuSub','MaxPct','GpuLimit','FanBadge','FanBadgeText','FanRow1','FanRow2','Fan1Icon','Fan2Icon','Fan1Track','Fan2Track','Fan1Fill','Fan2Fill','Fan1Pct','Fan2Pct','Graph','L100','L90','T100','GpuLine','CpuLine','ShadeBoost','ShadeMax','BandBoost','BandMax','GameBand','GameBadge','GameBadgeText','TFan','Fan1Line','Fan2Line','PauseBtn','PauseText','LogBtn','LangBar','AutoRow','AutoTrack','AutoKnob') { $ui[$n] = $window.FindName($n) }

$ui.CpuTrack.Data = Get-ArcGeometry 1; $ui.GpuTrack.Data = Get-ArcGeometry 1; $ui.CpuFanTrack.Data = Get-ArcGeometry 1 72; $ui.GpuFanTrack.Data = Get-ArcGeometry 1 72; $script:fanRingKey = @{ 1 = ""; 2 = "" }
$window.Add_IsVisibleChanged({ if ($window.IsVisible) { $script:fanLast = $fanSw.Elapsed.TotalSeconds; $script:arcLast = $script:fanLast; $script:arc.Cp = $null; $script:arc.Gp = $null; $script:arc.Ck = ""; $script:arc.Gk = ""; $script:arc.Ct = $sync.Cpu; $script:arc.Gt = $sync.Gpu; try { Step-ArcAnim $script:arcLast } catch {}; $fanAnim.Start() } else { $fanAnim.Stop() } })

$ui.GraphBtn.Add_MouseLeftButtonDown({ $_.Handled = $true; Set-GraphOpen (-not $script:graphOpen) $true; Save-UserSettings @{ graphOpen = $script:graphOpen }; UiLog ("graph " + $(if ($script:graphOpen) { 'shown' } else { 'hidden' })) })
# hover: every clickable surface lifts one step in the same palette (cross-faded); close warms to the rose
foreach ($hb in @(@($ui.GraphBtn, '#FF1E1C24', '#FF272430'), @($ui.PauseBtn, '#FF24212B', '#FF2F2B38'), @($ui.LogBtn, '#FF24212B', '#FF2F2B38'), @($ui.MinBtn, '#FF24212B', '#FF332E3B'), @($ui.CloseBtn, '#FF24212B', '#FF5A1F3D'))) {
  $br = New-Object Windows.Media.SolidColorBrush (Color $hb[1]); $hb[0].Background = $br; $hb[0].Tag = @($hb[1], $hb[2])
  $hb[0].Add_MouseEnter({ Fade-Brush $this.Background $this.Tag[1] 140 }); $hb[0].Add_MouseLeave({ Fade-Brush $this.Background $this.Tag[0] 200 })
}
$script:stFg = New-Object Windows.Media.SolidColorBrush (Color '#FF4B5263'); $script:stBg = New-Object Windows.Media.SolidColorBrush (Color '#244B5263')
$ui.Dot.Fill = $script:stFg; $ui.StatusText.Foreground = $script:stFg; $ui.Pill.Background = $script:stBg
$window.Add_SizeChanged({ if ($window.IsVisible -and $window.WindowState -eq 'Normal') { $wa = [Windows.SystemParameters]::WorkArea; $window.Top = [Math]::Max($wa.Top, $wa.Bottom - $window.ActualHeight - 4) } })
Set-GraphOpen $script:graphOpen $false
$window.Add_Closing({ if (-not $script:allowClose) { $_.Cancel = $true; $window.Hide() } })
$window.Add_MouseLeftButtonDown({ try { $window.DragMove() } catch {} })
$ui.CloseBtn.Add_MouseLeftButtonDown({ $_.Handled = $true; $window.Hide() })
$ui.MinBtn.Add_MouseLeftButtonDown({ $_.Handled = $true; $window.Hide() })
# Win+Down / system minimize -> tray, never the taskbar
$window.Add_StateChanged({ if ($window.WindowState -eq 'Minimized') { $window.Hide(); $window.WindowState = 'Normal'; UiLog 'minimized -> hidden to tray' } })
$ui.LogBtn.Add_MouseLeftButtonDown({ $_.Handled = $true; try { Show-Report '24h' } catch { UiLog "report failed: $($_.Exception.Message)"; Start-Process notepad.exe (Join-Path $Root 'guard.log') } })

$ui.PauseBtn.Add_MouseLeftButtonDown({ $_.Handled = $true; Toggle-Pause })

$ui.AutoRow.Add_MouseLeftButtonDown({ $_.Handled = $true; Toggle-AutoStart })
$ui.AutoTrack.Background = New-Object Windows.Media.SolidColorBrush (Color '#FF2A2730'); $ui.AutoKnob.Fill = New-Object Windows.Media.SolidColorBrush (Color '#FF8C8796')
Set-AutoUi $false
foreach ($code in $LangNames.Keys) {
  $b = New-Object Windows.Controls.Border
  $b.CornerRadius = New-Object Windows.CornerRadius 10; $b.Padding = New-Object Windows.Thickness(11, 3, 11, 4); $b.Margin = New-Object Windows.Thickness(2, 0, 2, 0)
  $b.Cursor = [Windows.Input.Cursors]::Hand; $b.Tag = $code; $b.MinHeight = 24
  $b.Background = $(if ($code -eq $lang) { Brush '#2EDB2777' } else { Brush '#00000000' })
  $b.BorderThickness = New-Object Windows.Thickness 1; $b.BorderBrush = $(if ($code -eq $lang) { Brush '#66DB2777' } else { Brush '#00000000' })
  if ($code -ne $lang) { $b.Add_MouseEnter({ $this.Background = Brush '#FF24212B' }); $b.Add_MouseLeave({ $this.Background = Brush '#00000000' }) }
  $tb = New-Object Windows.Controls.TextBlock
  $tb.Text = $LangNames[$code]; $tb.FontSize = 12; $tb.VerticalAlignment = 'Center'
  $tb.Foreground = $(if ($code -eq $lang) { Brush '#FFFBCFE8' } else { Brush '#FF8C8796' })
  $tb.FontFamily = New-Object Windows.Media.FontFamily $(if ($code -eq 'zh-CN') { 'Microsoft YaHei UI, Segoe UI' } else { 'Segoe UI, Tahoma' })
  $b.Child = $tb
  $b.Add_MouseLeftButtonDown({ $_.Handled = $true; Switch-Language ([string]$this.Tag) })
  [void]$ui.LangBar.Children.Add($b)
}
}
# ---------- fan gauges: spinning icon (speed ~ RPM) + bar (percent of max RPM), animated only while the window is visible ----------
# each gauge is scaled to its own fan's RPM at 100 % duty (fanBoost.maxRpmCpuFan / maxRpmGpuFan, sent by the engine),
# raised automatically if a fan is ever seen spinning faster (running max, this session)
$script:fanMaxRpm = @{ 1 = 6400.0; 2 = 6900.0 }; $script:fanMaxCfg = @{ 1 = 0.0; 2 = 0.0 }
$script:fanState = @{ T1 = 0.0; T2 = 0.0; P1 = 0.0; P2 = 0.0; A1 = 0.0; A2 = 0.0 }
$fanSw = [Diagnostics.Stopwatch]::StartNew(); $script:fanLast = 0.0
function Fan-Hex([double]$p) { if ($p -lt 0.55) { '#34D399' } elseif ($p -lt 0.80) { '#FBBF24' } else { '#F43F5E' } }
function Fan-Hex2([double]$p) { if ($p -lt 0.55) { '#A7F3D0' } elseif ($p -lt 0.80) { '#FDE68A' } else { '#FDA4AF' } }
function Step-FanAnim {
  $now = $fanSw.Elapsed.TotalSeconds; $dt = [Math]::Min(0.1, [Math]::Max(0.0, $now - $script:fanLast)); $script:fanLast = $now
  $k = 1.0 - [Math]::Exp(-6.0 * $dt)
  $fs = $script:fanState
  foreach ($i in 1, 2) {
    $fs["P$i"] = $fs["P$i"] + ($fs["T$i"] - $fs["P$i"]) * $k
    $pp = $fs["P$i"]
    $fs["A$i"] = ($fs["A$i"] + $dt * 900.0 * $pp) % 360.0      # 2.5 turns/s at full speed, still when the fan is off
    $ui["Fan${i}Icon"].RenderTransform.Angle = $fs["A$i"]
    $w = $ui["Fan${i}Track"].ActualWidth
    if ($w -gt 0) { $ui["Fan${i}Fill"].Width = $(if ($pp -lt 0.005) { 0 } else { [Math]::Min($w, [Math]::Max(8.0, $w * $pp)) }) }
    $rk = [string][Math]::Round($pp * 500)
    if ($rk -ne $script:fanRingKey[$i]) { $script:fanRingKey[$i] = $rk; $ra = $ui[$(if ($i -eq 1) { 'CpuFanArc' } else { 'GpuFanArc' })]; $ra.Data = Get-ArcGeometry $pp 72; $ra.Opacity = $(if ($pp -lt 0.005) { 0.0 } else { 1.0 }) }
  }
}
$fanAnim = New-Object Windows.Threading.DispatcherTimer
$fanAnim.Interval = [TimeSpan]::FromMilliseconds(33)   # ~30 fps, only while the window is visible
$fanAnim.Add_Tick({ try { Step-FanAnim } catch {}; try { Step-ArcAnim $fanSw.Elapsed.TotalSeconds } catch {} })
function Update-FanUi {
  $fs = $script:fanState
  $ui.GameBadge.Visibility = $(if ($sync.GameMode) { 'Visible' } else { 'Collapsed' })
  $ui.GameBadge.ToolTip = $(if ($sync.GameMode -and $sync.GameName) { [string]$sync.GameName } else { $null })
  $ok = [bool]$sync.FanOk -and [bool]$sync.FanMode
  if (-not $ok) {
    $fs.T1 = 0.0; $fs.T2 = 0.0
    $ui.FanBadge.Background = Brush '#26585363'; $ui.FanBadgeText.Foreground = Brush '#FF8C8796'; $ui.FanBadgeText.Text = $T.fanNA
    foreach ($i in 1, 2) { $ui["Fan${i}Pct"].Text = ''; $ui["FanRow$i"].ToolTip = $null; $ui["Fan${i}Icon"].Fill = Brush '#FF4B5263' }
    foreach ($k in 'Cpu', 'Gpu') { $ui["${k}FanArc"].Visibility = 'Collapsed'; $ui["${k}FanTrack"].Visibility = 'Collapsed'; $ui["${k}Ring"].ToolTip = $null }
    return
  }
  foreach ($i in 1, 2) {
    $rpm = [double]$sync["FanRpm$i"]
    $cfgMax = [double]$sync["FanMax$i"]; if ($cfgMax -ge 1000 -and $cfgMax -ne $script:fanMaxCfg[$i]) { $script:fanMaxCfg[$i] = $cfgMax; $script:fanMaxRpm[$i] = $cfgMax }
    if ($rpm -gt $script:fanMaxRpm[$i] -and $rpm -lt 12000) { $script:fanMaxRpm[$i] = $rpm }
    $pp = [Math]::Max(0.0, [Math]::Min(1.0, $rpm / $script:fanMaxRpm[$i])); $fs["T$i"] = $pp
    $hex = Fan-Hex $pp
    $ui["Fan${i}Icon"].Fill = Brush $hex
    $ui["Fan${i}Fill"].Background = New-Object Windows.Media.LinearGradientBrush ([Windows.Media.ColorConverter]::ConvertFromString((Fan-Hex2 $pp))), ([Windows.Media.ColorConverter]::ConvertFromString($hex)), 0.0
    $ui["Fan${i}Pct"].Text = N ($T.pct -f [int][Math]::Round($pp * 100))
    $ui["FanRow$i"].ToolTip = N ($T.fanRpm -f [int]$sync.FanRpm1, [int]$sync.FanRpm2)
    $k = if ($i -eq 1) { 'Cpu' } else { 'Gpu' }
    $ui["${k}FanArc"].Visibility = 'Visible'; $ui["${k}FanTrack"].Visibility = 'Visible'
    $rh = if ($sync.FanBoost -and [int]$sync.FanLevel -ge 2) { '#FFCFFAFE' } elseif ($sync.FanBoost) { '#FF22D3EE' } else { '#FF0EA5E9' }
    if ($ui["${k}FanArc"].Tag -ne $rh) { $ui["${k}FanArc"].Tag = $rh; $ui["${k}FanArc"].Stroke = Brush $rh }
    $ui["${k}Ring"].ToolTip = N ('{0}: {1:N0} RPM ({2}%)' -f $(if ($i -eq 1) { $T.lgCpuFan } else { $T.lgGpuFan }), [int]$rpm, [int][Math]::Round($pp * 100))
  }
  $b = if ($sync.FanBoost -and [int]$sync.FanLevel -ge 2) { @('#33F43F5E', '#FFFB7185', $T.fanBoost) }
       elseif ($sync.FanBoost) { @('#33FB923C', '#FFFB923C', (N ($(if ($T.fanBoostSoft) { $T.fanBoostSoft } else { '{0}%' }) -f [int]$sync.FanBoostPct))) }
       else { switch ($sync.FanMode) { 'max' { @('#33FB923C', '#FFFB923C', $T.fanMax) } 'fixed' { @('#33A78BFA', '#FFA78BFA', $T.fanFixed) } 'auto' { @('#2660A5FA', '#FF60A5FA', $T.fanAuto) } default { @('#2694A3B8', '#FFB4BCCB', $T.fanNormal) } } }
  $ui.FanBadge.Background = Brush $b[0]; $ui.FanBadgeText.Foreground = Brush $b[1]; $ui.FanBadgeText.Text = $b[2]
}

$script:allowClose = $false
Build-Window

# ---------- tray + menu ----------
$notify = New-Object Windows.Forms.NotifyIcon
$menu = New-Object Windows.Forms.ContextMenuStrip
$miOpen  = $menu.Items.Add('open')
$miPause = $menu.Items.Add('pause')
$miLog   = $menu.Items.Add('log')
$miUpd   = $menu.Items.Add('update')
$miLang  = New-Object Windows.Forms.ToolStripMenuItem 'lang'
[void]$menu.Items.Add($miLang)
foreach ($code in $LangNames.Keys) {
  $it = New-Object Windows.Forms.ToolStripMenuItem $LangNames[$code]
  $it.Tag = $code
  $it.Add_Click({ Switch-Language ([string]$this.Tag) })
  [void]$miLang.DropDownItems.Add($it)
}
[void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$miExit  = $menu.Items.Add('exit')
function Update-Menu {
  $menu.RightToLeft = $(if ($IsRtl) { 'Yes' } else { 'No' })
  $fname = ($T.font -split ',')[0].Trim()
  $menu.Font = New-Object Drawing.Font($fname, 9.5)
  $miOpen.Text = $T.mOpen; $miLog.Text = $T.mReport; $miUpd.Text = $T.mUpdate; $miExit.Text = $T.mExit; $miLang.Text = $T.mLang
  $miPause.Text = $(if ($sync.PauseUntil -gt (Get-Date)) { $T.mResume } else { $T.mPause })
  $miOpen.Font = New-Object Drawing.Font($fname, 9.5, [Drawing.FontStyle]::Bold)
  foreach ($it in $miLang.DropDownItems) {
    $it.Checked = ($it.Tag -eq $lang)
    $it.Font = New-Object Drawing.Font($(if ($it.Tag -eq 'zh-CN') { 'Microsoft YaHei UI' } else { 'Segoe UI' }), 9.5)
  }
}
function Switch-Language([string]$code) {
  if (-not (Test-Path (Join-Path $LangDir "$code.json"))) { return }
  Save-UserSettings @{ language = $code }
  $wasVisible = $window.IsVisible
  $script:allowClose = $true; try { $window.Close() } catch {}; $script:allowClose = $false
  Load-Lang $code
  Build-Window
  Update-Menu
  $script:lastIconKey = $null
  if ($wasVisible) { Show-Window }
  UiLog "language -> $code"
}
$notify.ContextMenuStrip = $menu
Update-Menu
$miOpen.Add_Click({ Show-Window 'menu' })
$miPause.Add_Click({ Toggle-Pause })
$miLog.Add_Click({ try { Show-Report '24h' } catch { UiLog "report failed: $($_.Exception.Message)"; Start-Process notepad.exe (Join-Path $Root 'guard.log') } })
$miUpd.Add_Click({ $sync.CheckUpdate = $true; UiLog 'check for updates clicked' })
$script:exiting = $false
function Exit-App {
  if ($script:exiting) { return }; $script:exiting = $true
  UiLog 'exit requested - restoring settings'
  $sync.Stop = $true
  $t0 = Get-Date
  while ($guardHandle -and -not $guardHandle.IsCompleted -and ((Get-Date) - $t0).TotalSeconds -lt 20) { Start-Sleep -Milliseconds 200 }
  if ($guardHandle -and -not $guardHandle.IsCompleted) {
    UiLog 'guard did not stop in time - running restore'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File (Join-Path $AppDir 'ThermalGuard.ps1') -Restore
  }
  $sync.SuiteStop = $true
  $t1 = Get-Date
  while ($script:suiteHandle -and -not $script:suiteHandle.IsCompleted -and ((Get-Date) - $t1).TotalSeconds -lt 4) { Start-Sleep -Milliseconds 100 }
  $notify.Visible = $false; $notify.Dispose()
  [Windows.Application]::Current.Shutdown()
}
$miExit.Add_Click({ Exit-App })
# left-click / double-click always open the window (hide it with its own - / x buttons); right-click shows the menu
$notify.Add_MouseClick({ if ($_.Button -eq [Windows.Forms.MouseButtons]::Left) { Show-Window 'tray click' } })
$notify.Add_MouseDoubleClick({ if ($_.Button -eq [Windows.Forms.MouseButtons]::Left) { Show-Window 'tray double-click' } })
Set-TrayIcon $TrayFill['wait'] ''
$notify.Text = 'Rosa Thermal Guard'
$notify.Visible = $true

# ---------- refresh loop ----------
$script:snapPending = 0; $script:snapDpi = 192
$script:lastHist = [datetime]::MinValue
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
  try {
    $now = Get-Date
    $cpu = $sync.Cpu; $gpu = $sync.Gpu
    $paused = [bool]$sync.Paused -or ($sync.PauseUntil -gt $now)
    $throttling = ($sync.Level -gt 0) -or [bool]$sync.GpuThrottled
    $hot = ($cpu -ne $null -and $cpu -ge 95) -or ($gpu -ne $null -and $gpu -ge 95)
    if ($hot) { $state = 'hot'; $col = '#F43F5E'; $st = $T.stHot }
    elseif ($throttling) { $state = 'cool'; $col = '#FB923C'; $st = $T.stCool }
    elseif ($paused) { $state = 'pause'; $col = '#94A3B8'; $st = $T.stPause -f (N $sync.PauseUntil.ToString('HH:mm')) }
    else { $state = 'ok'; $col = '#34D399'; $st = $T.stOk }
    if ($cpu -eq $null -and -not $sync.Updated) { $col = '#4B5263'; $st = $T.stWait }

    $txt = if ($cpu -ne $null) { [string][int][Math]::Round($cpu) } else { '…' }
    if (($now - $script:lastTheme).TotalSeconds -ge 5) { $script:lightBar = Test-LightTaskbar; $script:iconSize = Get-TrayIconSize; $script:lastTheme = $now }
    $ist = if ($cpu -eq $null -and -not $sync.Updated) { 'wait' } else { $state }
    $key = "$ist|$txt|$($script:lightBar)|$($script:iconSize)"
    if ($key -ne $script:lastIconKey) { Set-TrayIcon $TrayFill[$ist] $txt; $script:lastIconKey = $key }
    $tip = 'CPU {0}°C | GPU {1} | {2}' -f $(if ($cpu -ne $null) { [int]$cpu } else { '?' }), $(if ($gpu -ne $null) { "$([int]$gpu)°C" } else { '—' }), @{ok=$T.tipOk;cool=$T.tipCool;hot=$T.tipHot;pause=$T.tipPause}[$state]
    if ($sync.GameMode) { $tip = "$tip | $($T.gameMode)" }   # Game Mode: tooltip + window only, no pill on the icon
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
    $notify.Text = $tip
    $miPause.Text = if ($sync.PauseUntil -gt $now) { $T.mResume } else { $T.mPause }

    if ($sync.Notify) { $nk = @($sync.Notify); $sync.Notify = $null; $msg = ([string]$T.($nk[0])) -f $nk[1]; if ($msg) { $notify.ShowBalloonTip(5000, $T.title, $msg, $(if ([string]$nk[0] -like 'nUp*') { 'Info' } else { 'Warning' })) } }

    if (($now - $script:lastHist).TotalSeconds -ge 2 -and $sync.Updated) {
      $hf1 = $null; $hf2 = $null; $hm = 0
      if ($sync.FanOk -and $sync.FanMode) {
        if ($sync.FanRpm1 -ne $null) { $hf1 = 100.0 * [Math]::Min(1.0, [double]$sync.FanRpm1 / [Math]::Max(1000.0, $script:fanMaxRpm[1])) }
        if ($sync.FanRpm2 -ne $null) { $hf2 = 100.0 * [Math]::Min(1.0, [double]$sync.FanRpm2 / [Math]::Max(1000.0, $script:fanMaxRpm[2])) }
        if ($sync.FanBoost) { $hm = $(if ([int]$sync.FanLevel -ge 2) { 2 } else { 1 }) }
      }
      $history.Add([pscustomobject]@{ C = $cpu; G = $gpu; F1 = $hf1; F2 = $hf2; M = $hm; GM = [bool]$sync.GameMode }); if ($history.Count -gt 150) { $history.RemoveAt(0) }
      $script:lastHist = $now
    }

    if ($window.IsVisible) {
      Fade-Brush $script:stFg $col; Fade-Brush $script:stBg ('#24' + $col.Substring(1)); $ui.StatusText.Text = $st
      $ui.CpuVal.Text = $(if ($cpu -ne $null) { N "$([int][Math]::Round($cpu))°" } else { '--°' })
      $script:arc.Ct = $cpu   # the arc eases toward this (Step-ArcAnim), so a 1 s spike does not snap it to full
      if ($gpu -ne $null) {
        $ui.GpuVal.Text = N "$([int][Math]::Round($gpu))°"; $ui.GpuSub.Text = 'GPU'
        $script:arc.Gt = $gpu
      } else {
        $ui.GpuVal.Text = '—'; $ui.GpuSub.Text = $T.igpu
        $script:arc.Gt = $null; $script:arc.Gp = $null; $ui.GpuArc.Data = Get-ArcGeometry 0.001; $ui.GpuArc.Stroke = Brush '#4B5263'
      }
      $ui.MaxPct.Text = ($T.pct -f (N ([string]$(if ($sync.MaxPct) { $sync.MaxPct } else { 100 })))) + $(if ($sync.Level -gt 0) { $T.reduced } else { '' })
      $ui.GpuLimit.Text = switch ($sync.GpuMode) {
        'pl'  { $T.powerW -f (N ('{0:N0}' -f $sync.GpuLimitW)), (N ('{0:N0}' -f $sync.GpuDefaultW)) }
        'lgc' { if ($sync.GpuClockCap) { $T.clockCap -f (N ([string][int]$sync.GpuClockCap)) } else { $T.clockReady } }
        'priority' { $T.viaPrio }
        default { if ($sync.HasNvidia) { $T.viaPrio } else { $T.noNv } }
      }
      Update-FanUi
      $ui.PauseText.Text = if ($sync.PauseUntil -gt $now) { $T.resume } else { $T.pause15 }
      if ($script:graphOpen) { Update-Graph }   # collapsed: history keeps recording, nothing is drawn
    }

    try { Poll-AutoJob } catch {}
    $af = Join-Path $Root 'autostart.flag'   # 'on' / 'off' = the Start with Windows toggle
    if ((Test-Path $af) -and -not $script:autoJob -and $script:autoOn -ne $null) { $c = ([string](Get-Content $af -Raw)).Trim(); Remove-Item $af -Force; if (($c -eq 'on') -ne [bool]$script:autoOn) { Toggle-AutoStart } }
    # flags from outside (no admin needed)
    if (Test-Path (Join-Path $Root 'show.flag')) { Remove-Item (Join-Path $Root 'show.flag') -Force; Show-Window 'show.flag' }
    if (Test-Path (Join-Path $Root 'snap.flag')) { $sc = [string](Get-Content (Join-Path $Root 'snap.flag') -Raw); Remove-Item (Join-Path $Root 'snap.flag') -Force; $script:snapDpi = $(if ($sc -match '\b(96|120|144|192)\b') { [int]$matches[1] } else { 192 }); Show-Window; $script:snapPending = 3 }
    $gf = Join-Path $Root 'graph.flag'   # 'open' / 'close' expands or collapses the graph (same as the toggle button)
    if (Test-Path $gf) { $c = ([string](Get-Content $gf -Raw)).Trim(); Remove-Item $gf -Force; Set-GraphOpen ($c -eq 'open') $true; Save-UserSettings @{ graphOpen = $script:graphOpen }; UiLog ("graph " + $(if ($script:graphOpen) { 'shown' } else { 'hidden' }) + " (graph.flag)") }
    $rf = Join-Path $Root 'report.flag'   # 'report.flag' with e.g. '24h snap' opens the report (and saves report-<lang>.png)
    if (Test-Path $rf) { $c = ([string](Get-Content $rf -Raw)).Trim(); Remove-Item $rf -Force; $rg = if ($c -match '(1h|24h|7d)') { $matches[1] } else { '24h' }; try { if ($c -match 'snap') { Show-Report $rg (Join-Path $Root "report-$lang.png") -Hidden } else { Show-Report $rg } } catch { UiLog "report failed: $($_.Exception.Message)" } }
    if ($script:snapPending -gt 0) {
      $script:snapPending--
      if ($script:snapPending -eq 0) {
        $el = $window.Content
        $k = $script:snapDpi / 96.0; $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap([int][Math]::Ceiling(($el.ActualWidth + 28) * $k), [int][Math]::Ceiling(($el.ActualHeight + 28) * $k), $script:snapDpi, $script:snapDpi, [Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($el)
        $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $sn = $(if ($script:snapDpi -eq 192) { "ui-$lang.png" } else { "ui-$lang-$($script:snapDpi).png" }); $fs = [IO.File]::Create((Join-Path $Root $sn)); $enc.Save($fs); $fs.Close(); if ($script:snapDpi -eq 192) { Copy-Item (Join-Path $Root $sn) (Join-Path $Root 'ui.png') -Force }
        UiLog 'ui.png saved'
      }
    }
    $lf = Join-Path $Root 'lang.flag'
    if (Test-Path $lf) { $c = (Get-Content $lf -Raw).Trim(); Remove-Item $lf -Force; Switch-Language $c }
    if (Test-Path (Join-Path $Root 'minimize.flag')) { Remove-Item (Join-Path $Root 'minimize.flag') -Force; $window.WindowState = 'Minimized'; UiLog ("after minimize: visible=" + $window.IsVisible) }
    if (Test-Path (Join-Path $Root 'stop.flag')) { Exit-App; return }

    # keep the engine alive
    if ($guardHandle -and $guardHandle.IsCompleted -and -not $sync.Stop -and ($now - $lastGuardStart).TotalSeconds -gt 30) {
      $errs = ($guardPs.Streams.Error | ForEach-Object { $_.ToString() }) -join ' / '
      UiLog "guard engine stopped ($errs) - restarting"
      $guardPs.Dispose(); Start-Guard
    }
    # keep the suite worker alive (it ends on its own when the SDK is missing or switched off: then it stays off)
    if ($script:suiteHandle -and $script:suiteHandle.IsCompleted -and -not $sync.Stop -and $sync.SuiteState -in @('error', 'stopped') -and ($now - $script:lastSuiteStart).TotalSeconds -gt 300) {
      UiLog "suite worker ended ($($sync.SuiteState)) - starting it again"; try { $script:suitePs.Dispose() } catch {}; Start-Suite
    }
  } catch { UiLog "tick error: $($_.Exception.Message)" }
})

$app = New-Object Windows.Application
$app.ShutdownMode = 'OnExplicitShutdown'
Start-Guard
Start-Suite
Start-AutoJob 'get'
$timer.Start()
UiLog 'tray app started'
[void]$app.Run()
try { $uiMutex.ReleaseMutex() } catch {}
exit 0
