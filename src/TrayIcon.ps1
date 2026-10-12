# Tray icon drawing for Rosa Thermal Guard 1.3 (dot-sourced by TrayApp.ps1 and the preview script).
# Rosa Guard icon family (SDK ICONS.md): a thermometer silhouette (bulb left, tube right) stroked in Thermal's rose hue,
# filled with the state plate (-700 shades), carrying the live temperature as a white bold number. No state dot (by design).
# >= 100 C: the bulb is hidden and all three digits use the whole plate. Rendered per DPI at runtime, never scaled from 16 px.
Add-Type -AssemblyName System.Drawing
if (-not ('RTG.Native' -as [type])) {
  Add-Type -Namespace RTG -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool DestroyIcon(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr FindWindow(string cls, string name);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr MonitorFromWindow(System.IntPtr h, uint flags);
[System.Runtime.InteropServices.DllImport("shcore.dll")] public static extern int GetDpiForMonitor(System.IntPtr mon, int type, out uint x, out uint y);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int GetSystemMetricsForDpi(int idx, uint dpi);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr SetThreadDpiAwarenessContext(System.IntPtr ctx);
'@
}
# state -> plate (ICONS.md 5: normal / working / alert / paused; white text >= 5:1 on all of them)
$TrayFill = @{ ok = '#15803D'; cool = '#C2410C'; hot = '#B91C1C'; pause = '#4B5563'; wait = '#4B5563' }
$TrayStroke = @{ light = '#BE185D'; dark = '#F472B6' }   # Thermal identity hue #DB2777, tuned per taskbar (>= 5:1)

# Per-monitor DPI of the taskbar's monitor -> small-icon size (16/20/24/32 at 100/125/150/200 %).
function Get-TrayDpi {
  $dpi = 0
  try {
    $old = [RTG.Native]::SetThreadDpiAwarenessContext([IntPtr](-4))   # per-monitor v2 for this query only
    try {
      $tb = [RTG.Native]::FindWindow('Shell_TrayWnd', $null)
      $mon = [RTG.Native]::MonitorFromWindow($tb, 1)
      [uint32]$x = 0; [uint32]$y = 0
      if ([RTG.Native]::GetDpiForMonitor($mon, 0, [ref]$x, [ref]$y) -eq 0) { $dpi = [int]$x }
    } finally { if ($old -ne [IntPtr]::Zero) { [void][RTG.Native]::SetThreadDpiAwarenessContext($old) } }
  } catch {}
  if ($dpi -le 0) { try { $v = (Get-ItemProperty 'HKCU:\Control Panel\Desktop\WindowMetrics' -ErrorAction Stop).AppliedDPI; if ($v) { $dpi = [int]$v } } catch {} }
  if ($dpi -le 0) { $dpi = 96 }
  $dpi
}
function Get-TrayIconSize {
  $dpi = Get-TrayDpi; $px = 0
  try { $px = [RTG.Native]::GetSystemMetricsForDpi(49, [uint32]$dpi) } catch {}   # SM_CXSMICON
  if ($px -le 0) { $px = [int][Math]::Round(16 * $dpi / 96.0) }
  [Math]::Max(16, [Math]::Min(64, $px))
}
function Test-LightTaskbar {
  try { return [bool]((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction Stop).SystemUsesLightTheme) } catch { return $false }
}
$script:TrayFontFamily = $null
function Get-TrayFontFamily {
  if ($script:TrayFontFamily) { return $script:TrayFontFamily }
  $names = (New-Object Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name }
  foreach ($n in 'Bahnschrift SemiBold Condensed', 'Bahnschrift Condensed', 'Bahnschrift', 'Segoe UI') {
    if ($names -contains $n) { $script:TrayFontFamily = New-Object Drawing.FontFamily $n; return $script:TrayFontFamily }
  }
  $script:TrayFontFamily = [Drawing.FontFamily]::GenericSansSerif; return $script:TrayFontFamily
}
function New-RoundRect([double]$x, [double]$y, [double]$w, [double]$h, [double]$r) {
  $p = New-Object Drawing.Drawing2D.GraphicsPath
  $r = [Math]::Min($r, [Math]::Min($w, $h) / 2.0); $d = 2 * $r
  $p.AddArc([single]$x, [single]$y, [single]$d, [single]$d, 180, 90); $p.AddArc([single]($x + $w - $d), [single]$y, [single]$d, [single]$d, 270, 90)
  $p.AddArc([single]($x + $w - $d), [single]($y + $h - $d), [single]$d, [single]$d, 0, 90); $p.AddArc([single]$x, [single]($y + $h - $d), [single]$d, [single]$d, 90, 90)
  $p.CloseFigure(); $p
}
# Thermometer outline in grid units (ICONS.md masters): 32u master for >= 24 px, the pixel-tuned 16u source for 16/20 px.
function Get-ThermoShape([int]$size, [bool]$full) {
  $small = $size -lt 24
  if ($small) { $k = $size / 16.0; $g = @{ bx = 3.5; by = 8; br = 3; tx = 4.5; ty = 3.5; tw = 11; th = 9; tr = 4; fx = 1; sw = 1 } }
  else { $k = $size / 32.0; $g = @{ bx = 8; by = 16; br = 6; tx = 9; ty = 6; tw = 21; th = 20; tr = 10; fx = 2; sw = 2 } }
  $path = New-Object Drawing.Drawing2D.GraphicsPath
  $path.FillMode = 'Winding'
  if ($full) {   # 3 digits: plate spans bulb + tube
    $rr = New-RoundRect ($g.fx * $k) ($g.ty * $k) (($g.tx + $g.tw - $g.fx) * $k) ($g.th * $k) ($g.tr * $k); $path.AddPath($rr, $false); $rr.Dispose()
    $text = New-Object Drawing.RectangleF ([single](($g.fx + 0.6 * $g.sw) * $k)), ([single](($g.ty + 0.5 * $g.sw) * $k)), ([single](($g.tx + $g.tw - $g.fx - 1.2 * $g.sw) * $k)), ([single](($g.th - $g.sw) * $k))
  } else {
    $path.AddEllipse([single](($g.bx - $g.br) * $k), [single](($g.by - $g.br) * $k), [single](2 * $g.br * $k), [single](2 * $g.br * $k))
    $rr = New-RoundRect ($g.tx * $k) ($g.ty * $k) ($g.tw * $k) ($g.th * $k) ($g.tr * $k); $path.AddPath($rr, $false); $rr.Dispose()
    $text = New-Object Drawing.RectangleF ([single](($g.tx + 0.4 * $g.sw) * $k)), ([single](($g.ty + 0.5 * $g.sw) * $k)), ([single](($g.tw - 0.8 * $g.sw) * $k)), ([single](($g.th - $g.sw) * $k))
  }
  @{ Path = $path; Text = $text; K = $k; Small = $small }
}
function New-TrayBitmap([string]$fillHex, [string]$text, [int]$size, [bool]$lightTaskbar) {
  $bmp = New-Object Drawing.Bitmap $size, $size, ([Drawing.Imaging.PixelFormat]::Format32bppPArgb)
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'Half'; $g.TextRenderingHint = 'AntiAliasGridFit'   # never ClearType on a transparent bitmap
  $three = $text.Length -ge 3
  $sh = Get-ThermoShape $size $three
  $fill = [Drawing.ColorTranslator]::FromHtml($fillHex)
  if ($three -and $fillHex -eq $TrayFill.ok) { $fill = [Drawing.ColorTranslator]::FromHtml($TrayFill.hot) }   # >= 100 C is always the alert plate
  $stroke = [Drawing.ColorTranslator]::FromHtml($(if ($lightTaskbar) { $TrayStroke.light } else { $TrayStroke.dark }))
  $sw = $(if ($sh.Small) { 1.0 } else { [Math]::Max(1.0, 2.0 * $sh.K) })   # 2u stroke on the master, 1 px at 16/20
  $pen = New-Object Drawing.Pen($stroke, [single]$sw); $pen.LineJoin = 'Round'
  $br = New-Object Drawing.SolidBrush $fill
  $g.DrawPath($pen, $sh.Path)            # outline (half of it falls outside the plate)
  $g.FillPath($br, $sh.Path)             # plate on top: one silhouette, no inner seam
  $pen.Dispose(); $br.Dispose()
  if ($text) {
    $fam = Get-TrayFontFamily
    $style = if ($fam.Name -like 'Bahnschrift*') { [Drawing.FontStyle]::Regular } else { [Drawing.FontStyle]::Bold }
    if (-not $fam.IsStyleAvailable($style)) { $style = [Drawing.FontStyle]::Regular }
    $tp = New-Object Drawing.Drawing2D.GraphicsPath
    $tp.AddString($text, $fam, [int]$style, 100, (New-Object Drawing.PointF(0, 0)), [Drawing.StringFormat]::GenericTypographic)
    $b = $tp.GetBounds(); $r = $sh.Text
    # tube (or whole plate) rect: the largest number that fits, centred; tabular digits in this family
    $kk = [Math]::Min($r.Width / $b.Width, $r.Height * 0.86 / $b.Height)
    $m = New-Object Drawing.Drawing2D.Matrix
    $m.Translate($r.X + $r.Width / 2.0, $r.Y + $r.Height / 2.0); $m.Scale($kk, $kk); $m.Translate(-($b.X + $b.Width / 2.0), -($b.Y + $b.Height / 2.0))
    $tp.Transform($m)
    $g.FillPath([Drawing.Brushes]::White, $tp)
    $tp.Dispose(); $m.Dispose()
  }
  $sh.Path.Dispose(); $g.Dispose()
  return $bmp
}
