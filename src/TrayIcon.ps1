# Tray icon drawing for RosaThermalGuard (dot-sourced by TrayApp.ps1 and the preview script)
Add-Type -AssemblyName System.Drawing
if (-not ('RTG.Native' -as [type])) {
  Add-Type -Namespace RTG -Name Native -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool DestroyIcon(System.IntPtr h);'
}
# state -> icon fill (chosen so the WCAG pick gives white on green/red/grey, dark on orange)
$TrayFill = @{ ok = '#15803D'; cool = '#F59E0B'; hot = '#DC2626'; pause = '#4B5563'; wait = '#4B5563' }

function Get-RelLum([Drawing.Color]$c) {
  $f = { param($v) $s = $v / 255.0; if ($s -le 0.03928) { $s / 12.92 } else { [Math]::Pow(($s + 0.055) / 1.055, 2.4) } }
  0.2126 * (& $f $c.R) + 0.7152 * (& $f $c.G) + 0.0722 * (& $f $c.B)
}
function Get-TextColors([Drawing.Color]$fill) {
  $L = Get-RelLum $fill
  $dark = [Drawing.ColorTranslator]::FromHtml('#111111'); $Ld = Get-RelLum $dark
  $cWhite = 1.05 / ($L + 0.05); $cDark = ($L + 0.05) / ($Ld + 0.05)
  if ($cDark -gt $cWhite) { return @($dark, [Drawing.Color]::FromArgb(200, 255, 255, 255)) }   # text, halo
  return @([Drawing.Color]::White, [Drawing.Color]::FromArgb(170, 0, 0, 0))
}
function Get-TrayIconSize {
  $dpi = 96
  try { $v = (Get-ItemProperty 'HKCU:\Control Panel\Desktop\WindowMetrics' -ErrorAction Stop).AppliedDPI; if ($v) { $dpi = [int]$v } } catch {}
  $want = 16 * $dpi / 96
  foreach ($s in 16, 20, 24, 32) { if ($want -le $s) { return $s } }
  return 32
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
function New-TrayBitmap([string]$fillHex, [string]$text, [int]$size, [bool]$lightTaskbar) {
  $bmp = New-Object Drawing.Bitmap $size, $size, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'; $g.TextRenderingHint = 'SingleBitPerPixelGridFit'   # no ClearType
  $fill = [Drawing.ColorTranslator]::FromHtml($fillHex)
  # full-size circle + 1px edge that stands out against the taskbar
  $g.FillEllipse((New-Object Drawing.SolidBrush $fill), 0, 0, $size - 1, $size - 1)
  $edge = if ($lightTaskbar) { [Drawing.Color]::FromArgb(150, 0, 0, 0) } else { [Drawing.Color]::FromArgb(170, 255, 255, 255) }
  $pe = New-Object Drawing.Pen($edge, 1); $g.DrawEllipse($pe, 0.5, 0.5, $size - 2, $size - 2); $pe.Dispose()
  if ($text) {
    $tc = Get-TextColors $fill
    $fam = Get-TrayFontFamily
    $style = if ($fam.Name -like 'Bahnschrift*') { [Drawing.FontStyle]::Regular } else { [Drawing.FontStyle]::Bold }
    if (-not $fam.IsStyleAvailable($style)) { $style = [Drawing.FontStyle]::Regular }
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $path.AddString($text, $fam, [int]$style, 100, (New-Object Drawing.PointF(0, 0)), [Drawing.StringFormat]::GenericTypographic)
    $b = $path.GetBounds()
    $maxW = $size * $(if ($text.Length -ge 3) { 0.86 } else { 0.80 }); $maxH = $size * 0.60
    $k = [Math]::Min($maxW / $b.Width, $maxH / $b.Height)
    $m = New-Object Drawing.Drawing2D.Matrix
    $m.Translate($size / 2.0, $size / 2.0)
    $m.Scale($k, $k)
    $m.Translate(-($b.X + $b.Width / 2.0), -($b.Y + $b.Height / 2.0))
    $path.Transform($m)
    $halo = New-Object Drawing.Pen($tc[1], 2.0); $halo.LineJoin = 'Round'
    $g.DrawPath($halo, $path)                                  # 1px halo outside the glyphs
    $g.FillPath((New-Object Drawing.SolidBrush $tc[0]), $path)
    $halo.Dispose(); $path.Dispose(); $m.Dispose()
  }
  $g.Dispose()
  return $bmp
}
