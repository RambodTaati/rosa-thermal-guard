<#  Rosa Thermal Guard - tray app (MIT License)
    One hidden PowerShell process: the guard engine (ThermalGuard.ps1) runs in a background runspace,
    the UI is a tray icon (green / orange / red) plus a compact dark WPF window (English or Persian).
    Flag files in %ProgramData%\RosaThermalGuard: show.flag opens the window, snap.flag saves ui.png,
    minimize.flag minimizes it, stop.flag exits cleanly (settings restored). #>
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Join-Path $env:ProgramData 'RosaThermalGuard'
if (-not (Test-Path $Root)) { New-Item -ItemType Directory $Root -Force | Out-Null }
$Inv = [Globalization.CultureInfo]::InvariantCulture
function UiLog([string]$m) { try { Add-Content (Join-Path $Root 'guard.log') ("{0} [UI] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8 } catch {} }

$uiMutex = New-Object Threading.Mutex($false, 'Global\RosaThermalGuardUI')
if (-not $uiMutex.WaitOne(0)) { exit 0 }

# ---------- guard engine in a runspace ----------
$sync = [hashtable]::Synchronized(@{ Stop = $false; PauseUntil = [datetime]::MinValue; Notify = $null })
$script:guardPs = $null; $script:guardHandle = $null; $script:lastGuardStart = [datetime]::MinValue
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
function Get-ArcGeometry([double]$frac) {
  $frac = [Math]::Max(0.001, [Math]::Min(1, $frac))
  $cx = 75; $cy = 75; $r = 62; $start = 135; $sweep = 270 * $frac
  $a1 = $start * [Math]::PI / 180; $a2 = ($start + $sweep) * [Math]::PI / 180
  $x1 = $cx + $r * [Math]::Cos($a1); $y1 = $cy + $r * [Math]::Sin($a1)
  $x2 = $cx + $r * [Math]::Cos($a2); $y2 = $cy + $r * [Math]::Sin($a2)
  $large = if ($sweep -gt 180) { 1 } else { 0 }
  [Windows.Media.Geometry]::Parse([string]::Format($Inv, 'M {0:F2},{1:F2} A {2},{2} 0 {3} 1 {4:F2},{5:F2}', $x1, $y1, $r, $large, $x2, $y2))
}
function Get-TempBrush($t) {
  $hex = if ($t -eq $null) { '#4B5263' } elseif ($t -lt 80) { '#34D399' } elseif ($t -lt 90) { '#FBBF24' } elseif ($t -lt 95) { '#FB923C' } else { '#F43F5E' }
  New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex))
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
function Toggle-Pause {
  if ($sync.PauseUntil -gt (Get-Date)) { $sync.PauseUntil = [datetime]::MinValue; UiLog 'resume clicked' }
  else { $sync.PauseUntil = (Get-Date).AddMinutes(15); UiLog 'pause 15 min clicked' }
}
function Build-Window {
$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Rosa Thermal Guard" Width="400" SizeToContent="Height" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="NoResize" ShowInTaskbar="False" Topmost="True"
        FontFamily="{{font}}" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Border x:Name="Card" Margin="14" CornerRadius="20" Background="#FF15171E" BorderBrush="#FF2A2E3A" BorderThickness="1" Padding="20,16,20,18" FlowDirection="{{dir}}">
    <Border.Effect><DropShadowEffect BlurRadius="24" ShadowDepth="4" Opacity="0.55" Color="#000000"/></Border.Effect>
    <StackPanel>
      <Grid>
        <StackPanel Orientation="Horizontal">
          <Ellipse x:Name="Dot" Width="10" Height="10" Fill="#34D399" Margin="0,0,0,0" VerticalAlignment="Center"/>
          <TextBlock Text="{{title}}" Foreground="#FFF1F3F8" FontSize="17" FontWeight="SemiBold" Margin="10,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Border x:Name="MinBtn" Width="28" Height="28" CornerRadius="14" Background="#FF222632" Cursor="Hand" Margin="0,0,8,0" ToolTip="{{minTip}}">
            <TextBlock Text="–" Foreground="#FFA0A6B8" FontSize="15" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-2,0,0"/>
          </Border>
          <Border x:Name="CloseBtn" Width="28" Height="28" CornerRadius="14" Background="#FF222632" Cursor="Hand" ToolTip="{{closeTip}}">
            <TextBlock Text="✕" Foreground="#FFA0A6B8" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
        </StackPanel>
      </Grid>
      <Border x:Name="Pill" HorizontalAlignment="Left" Margin="0,12,0,4" CornerRadius="11" Padding="12,4" Background="#2234D399">
        <TextBlock x:Name="StatusText" Text="{{stOk}}" Foreground="#FF34D399" FontSize="13" FontWeight="SemiBold"/>
      </Border>
      <Grid Margin="0,10,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" HorizontalAlignment="Center">
          <Grid Width="150" Height="150" FlowDirection="LeftToRight">
            <Path x:Name="CpuTrack" Stroke="#FF262A36" StrokeThickness="11" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
            <Path x:Name="CpuArc" Stroke="#34D399" StrokeThickness="11" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
            <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
              <TextBlock x:Name="CpuVal" Text="--°" Foreground="#FFF1F3F8" FontSize="34" FontWeight="Light" HorizontalAlignment="Center"/>
              <TextBlock Text="CPU" Foreground="#FF6B7285" FontSize="11" HorizontalAlignment="Center"/>
            </StackPanel>
          </Grid>
          <TextBlock Text="{{cpuTemp}}" Foreground="#FFC9CEDB" FontSize="13" HorizontalAlignment="Center" Margin="0,2,0,0"/>
        </StackPanel>
        <StackPanel Grid.Column="1" HorizontalAlignment="Center">
          <Grid Width="150" Height="150" FlowDirection="LeftToRight">
            <Path x:Name="GpuTrack" Stroke="#FF262A36" StrokeThickness="11" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
            <Path x:Name="GpuArc" Stroke="#60A5FA" StrokeThickness="11" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
            <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
              <TextBlock x:Name="GpuVal" Text="--°" Foreground="#FFF1F3F8" FontSize="34" FontWeight="Light" HorizontalAlignment="Center"/>
              <TextBlock x:Name="GpuSub" Text="GPU" Foreground="#FF6B7285" FontSize="11" HorizontalAlignment="Center"/>
            </StackPanel>
          </Grid>
          <TextBlock Text="{{gpuTemp}}" Foreground="#FFC9CEDB" FontSize="13" HorizontalAlignment="Center" Margin="0,2,0,0"/>
        </StackPanel>
      </Grid>
      <Border Margin="0,16,0,0" CornerRadius="14" Background="#FF1B1E27" Padding="14,10">
        <StackPanel>
          <Grid Margin="0,2">
            <TextBlock Text="{{cpuMax}}" Foreground="#FF8A91A5" FontSize="13"/>
            <TextBlock x:Name="MaxPct" Text="100" Foreground="#FFF1F3F8" FontSize="13" FontWeight="SemiBold" HorizontalAlignment="Right"/>
          </Grid>
          <Grid Margin="0,6,0,2">
            <TextBlock Text="{{gpuCtl}}" Foreground="#FF8A91A5" FontSize="13"/>
            <TextBlock x:Name="GpuLimit" Text="—" Foreground="#FFF1F3F8" FontSize="13" FontWeight="SemiBold" HorizontalAlignment="Right"/>
          </Grid>
          <Border Height="1" Background="#FF262A36" Margin="0,10,0,8"/>
          <Grid>
            <TextBlock Text="{{fans}}" Foreground="#FF8A91A5" FontSize="13" VerticalAlignment="Center"/>
            <Border x:Name="FanBadge" HorizontalAlignment="Right" VerticalAlignment="Center" CornerRadius="9" Padding="10,2,10,3" Background="#2660A5FA">
              <TextBlock x:Name="FanBadgeText" Text="-" Foreground="#FF60A5FA" FontSize="11.5" FontWeight="SemiBold"/>
            </Border>
          </Grid>
          <StackPanel Grid.IsSharedSizeScope="True" Margin="0,0,0,2">
            <Grid x:Name="FanRow1" Margin="0,8,0,0" Background="Transparent">
              <Grid.ColumnDefinitions><ColumnDefinition Width="24"/><ColumnDefinition Width="Auto" SharedSizeGroup="FanLbl"/><ColumnDefinition Width="*"/><ColumnDefinition Width="42"/></Grid.ColumnDefinitions>
              <Canvas Grid.Column="0" Width="18" Height="18" HorizontalAlignment="Left" VerticalAlignment="Center">
                <Ellipse Width="18" Height="18" Fill="#FF20242F"/>
                <Path x:Name="Fan1Icon" Fill="#FF34D399" Data="M9.00,7.20 C8.20,3.50 10.50,0.60 13.20,1.80 C14.60,3.20 12.40,6.40 10.40,8.20 Z M10.80,9.00 C14.50,8.20 17.40,10.50 16.20,13.20 C14.80,14.60 11.60,12.40 9.80,10.40 Z M9.00,10.80 C9.80,14.50 7.50,17.40 4.80,16.20 C3.40,14.80 5.60,11.60 7.60,9.80 Z M7.20,9.00 C3.50,9.80 0.60,7.50 1.80,4.80 C3.20,3.40 6.40,5.60 8.20,7.60 Z">
                  <Path.RenderTransform><RotateTransform CenterX="9" CenterY="9"/></Path.RenderTransform>
                </Path>
                <Ellipse Canvas.Left="6.5" Canvas.Top="6.5" Width="5" Height="5" Fill="#FF1B1E27" Stroke="#FF8A91A5" StrokeThickness="0.8"/>
              </Canvas>
              <TextBlock Grid.Column="1" Text="{{cpu}}" Foreground="#FFC9CEDB" FontSize="12.5" VerticalAlignment="Center" Margin="4,0,12,0"/>
              <Grid Grid.Column="2" x:Name="Fan1Track" Height="8" VerticalAlignment="Center">
                <Border CornerRadius="4" Background="#FF262A36"/>
                <Border x:Name="Fan1Fill" CornerRadius="4" HorizontalAlignment="Left" Width="0" Background="#FF34D399"/>
              </Grid>
              <TextBlock Grid.Column="3" x:Name="Fan1Pct" Text="" Foreground="#FF6B7285" FontSize="11" HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </Grid>            <Grid x:Name="FanRow2" Margin="0,8,0,0" Background="Transparent">
              <Grid.ColumnDefinitions><ColumnDefinition Width="24"/><ColumnDefinition Width="Auto" SharedSizeGroup="FanLbl"/><ColumnDefinition Width="*"/><ColumnDefinition Width="42"/></Grid.ColumnDefinitions>
              <Canvas Grid.Column="0" Width="18" Height="18" HorizontalAlignment="Left" VerticalAlignment="Center">
                <Ellipse Width="18" Height="18" Fill="#FF20242F"/>
                <Path x:Name="Fan2Icon" Fill="#FF34D399" Data="M9.00,7.20 C8.20,3.50 10.50,0.60 13.20,1.80 C14.60,3.20 12.40,6.40 10.40,8.20 Z M10.80,9.00 C14.50,8.20 17.40,10.50 16.20,13.20 C14.80,14.60 11.60,12.40 9.80,10.40 Z M9.00,10.80 C9.80,14.50 7.50,17.40 4.80,16.20 C3.40,14.80 5.60,11.60 7.60,9.80 Z M7.20,9.00 C3.50,9.80 0.60,7.50 1.80,4.80 C3.20,3.40 6.40,5.60 8.20,7.60 Z">
                  <Path.RenderTransform><RotateTransform CenterX="9" CenterY="9"/></Path.RenderTransform>
                </Path>
                <Ellipse Canvas.Left="6.5" Canvas.Top="6.5" Width="5" Height="5" Fill="#FF1B1E27" Stroke="#FF8A91A5" StrokeThickness="0.8"/>
              </Canvas>
              <TextBlock Grid.Column="1" Text="{{gpu}}" Foreground="#FFC9CEDB" FontSize="12.5" VerticalAlignment="Center" Margin="4,0,12,0"/>
              <Grid Grid.Column="2" x:Name="Fan2Track" Height="8" VerticalAlignment="Center">
                <Border CornerRadius="4" Background="#FF262A36"/>
                <Border x:Name="Fan2Fill" CornerRadius="4" HorizontalAlignment="Left" Width="0" Background="#FF34D399"/>
              </Grid>
              <TextBlock Grid.Column="3" x:Name="Fan2Pct" Text="" Foreground="#FF6B7285" FontSize="11" HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </Grid>          </StackPanel>

        </StackPanel>
      </Border>
      <Grid Margin="0,14,0,6">
        <TextBlock Text="{{last5}}" Foreground="#FF8A91A5" FontSize="12"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Ellipse Width="8" Height="8" Fill="#FB923C" VerticalAlignment="Center"/>
          <TextBlock Text="{{cpu}}" Foreground="#FF8A91A5" FontSize="12" Margin="5,0,12,0"/>
          <Ellipse Width="8" Height="8" Fill="#60A5FA" VerticalAlignment="Center"/>
          <TextBlock Text="{{gpu}}" Foreground="#FF8A91A5" FontSize="12" Margin="5,0,0,0"/>
        </StackPanel>
      </Grid>
      <Border CornerRadius="14" Background="#FF1B1E27" Padding="8" FlowDirection="LeftToRight">
        <Canvas x:Name="Graph" Height="90" ClipToBounds="True">
          <Line x:Name="L100" Stroke="#66F43F5E" StrokeThickness="1" StrokeDashArray="4 3"/>
          <Line x:Name="L90" Stroke="#44FBBF24" StrokeThickness="1" StrokeDashArray="2 4"/>
          <TextBlock x:Name="T100" Text="100°" Foreground="#99F43F5E" FontSize="9"/>
          <Path x:Name="ShadeBoost" Fill="#12FBBF24"/>
          <Path x:Name="ShadeMax" Fill="#1CF43F5E"/>
          <Path x:Name="BandBoost" Fill="#CCFBBF24"/>
          <Path x:Name="BandMax" Fill="#DDF43F5E"/>
          <TextBlock x:Name="TFan" Text="100%" Foreground="#992DD4BF" FontSize="9"/>
          <Polyline x:Name="Fan2Line" Stroke="#C4B5FD" StrokeThickness="1.3" StrokeDashArray="3 2" StrokeLineJoin="Round" Opacity="0.85"/>
          <Polyline x:Name="Fan1Line" Stroke="#2DD4BF" StrokeThickness="1.3" StrokeDashArray="3 2" StrokeLineJoin="Round" Opacity="0.85"/>
          <Polyline x:Name="GpuLine" Stroke="#60A5FA" StrokeThickness="1.8" StrokeLineJoin="Round"/>
          <Polyline x:Name="CpuLine" Stroke="#FB923C" StrokeThickness="1.8" StrokeLineJoin="Round"/>
        </Canvas>
      </Border>
      <WrapPanel x:Name="FanLegend" HorizontalAlignment="Center" Margin="0,6,0,0">
        <Line X1="0" Y1="0" X2="12" Y2="0" Stroke="#2DD4BF" StrokeThickness="1.6" StrokeDashArray="3 2" VerticalAlignment="Center"/>
        <TextBlock Text="{{lgCpuFan}}" Foreground="#FF8A91A5" FontSize="11" Margin="4,0,10,0"/>
        <Line X1="0" Y1="0" X2="12" Y2="0" Stroke="#C4B5FD" StrokeThickness="1.6" StrokeDashArray="3 2" VerticalAlignment="Center"/>
        <TextBlock Text="{{lgGpuFan}}" Foreground="#FF8A91A5" FontSize="11" Margin="4,0,10,0"/>
        <Rectangle Width="10" Height="4" RadiusX="1" RadiusY="1" Fill="#CCFBBF24" VerticalAlignment="Center"/>
        <TextBlock Text="{{lgBoost}}" Foreground="#FF8A91A5" FontSize="11" Margin="4,0,10,0"/>
        <Rectangle Width="10" Height="4" RadiusX="1" RadiusY="1" Fill="#DDF43F5E" VerticalAlignment="Center"/>
        <TextBlock Text="{{lgMax}}" Foreground="#FF8A91A5" FontSize="11" Margin="4,0,0,0"/>
      </WrapPanel>
      <Grid Margin="0,14,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="10"/><ColumnDefinition/></Grid.ColumnDefinitions>
        <Border x:Name="PauseBtn" Grid.Column="0" CornerRadius="12" Background="#FF232734" Padding="0,8" Cursor="Hand">
          <TextBlock x:Name="PauseText" Text="{{pause15}}" Foreground="#FFE2E6EF" FontSize="13" HorizontalAlignment="Center"/>
        </Border>
        <Border x:Name="LogBtn" Grid.Column="2" CornerRadius="12" Background="#FF232734" Padding="0,8" Cursor="Hand">
          <TextBlock Text="{{log}}" Foreground="#FFE2E6EF" FontSize="13" HorizontalAlignment="Center"/>
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
foreach ($n in 'Card','Dot','CloseBtn','MinBtn','Pill','StatusText','CpuTrack','CpuArc','CpuVal','GpuTrack','GpuArc','GpuVal','GpuSub','MaxPct','GpuLimit','FanBadge','FanBadgeText','FanRow1','FanRow2','Fan1Icon','Fan2Icon','Fan1Track','Fan2Track','Fan1Fill','Fan2Fill','Fan1Pct','Fan2Pct','Graph','L100','L90','T100','GpuLine','CpuLine','ShadeBoost','ShadeMax','BandBoost','BandMax','TFan','Fan1Line','Fan2Line','PauseBtn','PauseText','LogBtn','LangBar') { $ui[$n] = $window.FindName($n) }

$ui.CpuTrack.Data = Get-ArcGeometry 1; $ui.GpuTrack.Data = Get-ArcGeometry 1
$window.Add_IsVisibleChanged({ if ($window.IsVisible) { $script:fanLast = $fanSw.Elapsed.TotalSeconds; $fanAnim.Start() } else { $fanAnim.Stop() } })

$window.Add_Closing({ if (-not $script:allowClose) { $_.Cancel = $true; $window.Hide() } })
$window.Add_MouseLeftButtonDown({ try { $window.DragMove() } catch {} })
$ui.CloseBtn.Add_MouseLeftButtonDown({ $_.Handled = $true; $window.Hide() })
$ui.MinBtn.Add_MouseLeftButtonDown({ $_.Handled = $true; $window.Hide() })
foreach ($btn in $ui.MinBtn, $ui.CloseBtn) {
  $btn.Add_MouseEnter({ $this.Background = Brush '#FF2E3342' }); $btn.Add_MouseLeave({ $this.Background = Brush '#FF222632' })
}
# Win+Down / system minimize -> tray, never the taskbar
$window.Add_StateChanged({ if ($window.WindowState -eq 'Minimized') { $window.Hide(); $window.WindowState = 'Normal'; UiLog 'minimized -> hidden to tray' } })
$ui.LogBtn.Add_MouseLeftButtonDown({ $_.Handled = $true; Start-Process notepad.exe (Join-Path $Root 'guard.log') })

$ui.PauseBtn.Add_MouseLeftButtonDown({ $_.Handled = $true; Toggle-Pause })

foreach ($code in $LangNames.Keys) {
  $b = New-Object Windows.Controls.Border
  $b.CornerRadius = New-Object Windows.CornerRadius 9; $b.Padding = New-Object Windows.Thickness(10, 3, 10, 4); $b.Margin = New-Object Windows.Thickness(3, 0, 3, 0)
  $b.Cursor = [Windows.Input.Cursors]::Hand; $b.Tag = $code
  $b.Background = $(if ($code -eq $lang) { Brush '#FF2E3342' } else { Brush '#00000000' })
  $tb = New-Object Windows.Controls.TextBlock
  $tb.Text = $LangNames[$code]; $tb.FontSize = 12
  $tb.Foreground = $(if ($code -eq $lang) { Brush '#FFF1F3F8' } else { Brush '#FF6B7285' })
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
  }
}
$fanAnim = New-Object Windows.Threading.DispatcherTimer
$fanAnim.Interval = [TimeSpan]::FromMilliseconds(40)   # 25 fps
$fanAnim.Add_Tick({ try { Step-FanAnim } catch {} })
function Update-FanUi {
  $fs = $script:fanState
  $ok = [bool]$sync.FanOk -and [bool]$sync.FanMode
  if (-not $ok) {
    $fs.T1 = 0.0; $fs.T2 = 0.0
    $ui.FanBadge.Background = Brush '#264B5263'; $ui.FanBadgeText.Foreground = Brush '#FF8A91A5'; $ui.FanBadgeText.Text = $T.fanNA
    foreach ($i in 1, 2) { $ui["Fan${i}Pct"].Text = ''; $ui["FanRow$i"].ToolTip = $null; $ui["Fan${i}Icon"].Fill = Brush '#FF4B5263' }
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
  $miOpen.Text = $T.mOpen; $miLog.Text = $T.mLog; $miExit.Text = $T.mExit; $miLang.Text = $T.mLang
  $miPause.Text = $(if ($sync.PauseUntil -gt (Get-Date)) { $T.mResume } else { $T.mPause })
  $miOpen.Font = New-Object Drawing.Font($fname, 9.5, [Drawing.FontStyle]::Bold)
  foreach ($it in $miLang.DropDownItems) {
    $it.Checked = ($it.Tag -eq $lang)
    $it.Font = New-Object Drawing.Font($(if ($it.Tag -eq 'zh-CN') { 'Microsoft YaHei UI' } else { 'Segoe UI' }), 9.5)
  }
}
function Switch-Language([string]$code) {
  if (-not (Test-Path (Join-Path $LangDir "$code.json"))) { return }
  try { (@{ language = $code } | ConvertTo-Json) | Set-Content $UserSettings -Encoding UTF8 } catch {}
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
$miLog.Add_Click({ Start-Process notepad.exe (Join-Path $Root 'guard.log') })
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
$script:snapPending = 0
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
    if (($now - $script:lastTheme).TotalSeconds -ge 30) { $script:lightBar = Test-LightTaskbar; $script:iconSize = Get-TrayIconSize; $script:lastTheme = $now }
    $ist = if ($cpu -eq $null -and -not $sync.Updated) { 'wait' } else { $state }
    $key = "$ist|$txt|$($script:lightBar)|$($script:iconSize)"
    if ($key -ne $script:lastIconKey) { Set-TrayIcon $TrayFill[$ist] $txt; $script:lastIconKey = $key }
    $tip = 'CPU {0}°C | GPU {1} | {2}' -f $(if ($cpu -ne $null) { [int]$cpu } else { '?' }), $(if ($gpu -ne $null) { "$([int]$gpu)°C" } else { '—' }), @{ok=$T.tipOk;cool=$T.tipCool;hot=$T.tipHot;pause=$T.tipPause}[$state]
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
    $notify.Text = $tip
    $miPause.Text = if ($sync.PauseUntil -gt $now) { $T.mResume } else { $T.mPause }

    if ($sync.Notify) { $nk = @($sync.Notify); $sync.Notify = $null; $msg = ([string]$T.($nk[0])) -f $nk[1]; if ($msg) { $notify.ShowBalloonTip(4000, $T.title, $msg, 'Warning') } }

    if (($now - $script:lastHist).TotalSeconds -ge 2 -and $sync.Updated) {
      $hf1 = $null; $hf2 = $null; $hm = 0
      if ($sync.FanOk -and $sync.FanMode) {
        if ($sync.FanRpm1 -ne $null) { $hf1 = 100.0 * [Math]::Min(1.0, [double]$sync.FanRpm1 / [Math]::Max(1000.0, $script:fanMaxRpm[1])) }
        if ($sync.FanRpm2 -ne $null) { $hf2 = 100.0 * [Math]::Min(1.0, [double]$sync.FanRpm2 / [Math]::Max(1000.0, $script:fanMaxRpm[2])) }
        if ($sync.FanBoost) { $hm = $(if ([int]$sync.FanLevel -ge 2) { 2 } else { 1 }) }
      }
      $history.Add([pscustomobject]@{ C = $cpu; G = $gpu; F1 = $hf1; F2 = $hf2; M = $hm }); if ($history.Count -gt 150) { $history.RemoveAt(0) }
      $script:lastHist = $now
    }

    if ($window.IsVisible) {
      $b = Brush $col
      $ui.Dot.Fill = $b; $ui.StatusText.Text = $st; $ui.StatusText.Foreground = $b
      $ui.Pill.Background = Brush ('#26' + $col.Substring(1))
      $ui.CpuVal.Text = $(if ($cpu -ne $null) { "$([int][Math]::Round($cpu))°" } else { '--°' })
      $ui.CpuArc.Data = Get-ArcGeometry $(if ($cpu -ne $null) { ($cpu - 30) / 75 } else { 0 })
      $ui.CpuArc.Stroke = Get-TempBrush $cpu
      if ($gpu -ne $null) {
        $ui.GpuVal.Text = "$([int][Math]::Round($gpu))°"; $ui.GpuSub.Text = 'GPU'
        $ui.GpuArc.Data = Get-ArcGeometry (($gpu - 30) / 75); $ui.GpuArc.Stroke = Get-TempBrush $gpu
      } else {
        $ui.GpuVal.Text = '—'; $ui.GpuSub.Text = $T.igpu
        $ui.GpuArc.Data = Get-ArcGeometry 0.001; $ui.GpuArc.Stroke = Brush '#4B5263'
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
      Update-Graph
    }

    # flags from outside (no admin needed)
    if (Test-Path (Join-Path $Root 'show.flag')) { Remove-Item (Join-Path $Root 'show.flag') -Force; Show-Window 'show.flag' }
    if (Test-Path (Join-Path $Root 'snap.flag')) { Remove-Item (Join-Path $Root 'snap.flag') -Force; Show-Window; $script:snapPending = 3 }
    if ($script:snapPending -gt 0) {
      $script:snapPending--
      if ($script:snapPending -eq 0) {
        $el = $window.Content
        $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap([int]($el.ActualWidth * 2 + 56), [int]($el.ActualHeight * 2 + 56), 192, 192, [Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($el)
        $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $fs = [IO.File]::Create((Join-Path $Root "ui-$lang.png")); $enc.Save($fs); $fs.Close(); Copy-Item (Join-Path $Root "ui-$lang.png") (Join-Path $Root 'ui.png') -Force
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
  } catch { UiLog "tick error: $($_.Exception.Message)" }
})

$app = New-Object Windows.Application
$app.ShutdownMode = 'OnExplicitShutdown'
Start-Guard
$timer.Start()
UiLog 'tray app started'
[void]$app.Run()
try { $uiMutex.ReleaseMutex() } catch {}
exit 0
