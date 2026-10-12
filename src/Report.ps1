<# Rosa Thermal Guard - graphical report window (dot-sourced by TrayApp.ps1).
   Data: %ProgramData%\RosaThermalGuard\history\h-YYYYMMDD.csv (one row per 5 s, written by the engine)
         and history\events.jsonl (one line per action). Parsing and geometry are done in a small compiled
         helper so even the 7-day view (~120k rows) opens in well under a second. #>
$HistDir = Join-Path $Root 'history'
function Ensure-Rtg {
if (-not ('RtgRep' -as [type])) {
Add-Type -Language CSharp -TypeDefinition @'
using System; using System.IO; using System.Text; using System.Globalization;
public class RtgRep {
  static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
  public int N; public double[] C, G, F1, F2; public bool[] Thr, Boost, Max, Game, Hot;
  public double C100Sec, G100Sec, C100Long, G100Long; public int C100Ep, G100Ep;
  public double CMax = double.NaN, GMax = double.NaN, CAvg = double.NaN, GAvg = double.NaN;
  public double Above90, ThrSec, BoostSec, MaxSec, GameSec; public int Samples;
  static double P(string s) { double v; return (s.Length > 0 && double.TryParse(s, NumberStyles.Float, Inv, out v)) ? v : double.NaN; }
  static int I(string s) { int v; return int.TryParse(s, out v) ? v : 0; }
  public static RtgRep Load(string dir, DateTime from, DateTime to, int n) {
    var r = new RtgRep(); r.N = n;
    r.C = new double[n]; r.G = new double[n]; r.F1 = new double[n]; r.F2 = new double[n];
    r.Thr = new bool[n]; r.Boost = new bool[n]; r.Max = new bool[n]; r.Game = new bool[n]; r.Hot = new bool[n];
    long lastCT = -100, lastGT = -100; double curC = 0, curG = 0;
    var cc = new int[n]; var gc = new int[n]; var fc = new int[n];
    long t0 = new DateTimeOffset(from).ToUnixTimeSeconds(), t1 = new DateTimeOffset(to).ToUnixTimeSeconds(); double span = Math.Max(1, t1 - t0);
    double cs = 0, gs = 0; int cn = 0, gn = 0;
    for (DateTime d = from.Date.AddDays(-1); d <= to.Date; d = d.AddDays(1)) {
      string f = Path.Combine(dir, "h-" + d.ToString("yyyyMMdd", Inv) + ".csv");
      if (!File.Exists(f)) continue;
      string text;
      try { using (var fs = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) using (var sr = new StreamReader(fs)) text = sr.ReadToEnd(); } catch { continue; }
      foreach (string raw in text.Split('\n')) {
        string[] p = raw.Trim().Split(',');
        if (p.Length < 11) continue;
        long t; if (!long.TryParse(p[0], out t) || t < t0 || t > t1) continue;
        int i = (int)Math.Min(n - 1, Math.Max(0, (t - t0) / span * n));
        double c = P(p[1]), g = P(p[2]), cm = P(p[3]), gm = P(p[4]), f1 = P(p[5]), f2 = P(p[6]);
        int lvl = I(p[7]), fan = I(p[9]); bool gt = p[8] == "1", game = p[10] == "1";
        r.Samples++;
        if (!double.IsNaN(c)) { r.C[i] += c; cc[i]++; cs += c; cn++; }
        if (!double.IsNaN(g)) { r.G[i] += g; gc[i]++; gs += g; gn++; }
        if (!double.IsNaN(f1) && !double.IsNaN(f2)) { r.F1[i] += f1; r.F2[i] += f2; fc[i]++; }
        if (!double.IsNaN(cm) && (double.IsNaN(r.CMax) || cm > r.CMax)) r.CMax = cm;
        if (!double.IsNaN(gm) && (double.IsNaN(r.GMax) || gm > r.GMax)) r.GMax = gm;
        if ((!double.IsNaN(c) && c >= 90) || (!double.IsNaN(g) && g >= 90)) r.Above90 += 5;
        if (lvl > 0 || gt) { r.Thr[i] = true; r.ThrSec += 5; }
        if (fan >= 1) { r.Boost[i] = true; r.BoostSec += 5; }
        if (fan >= 2) { r.Max[i] = true; r.MaxSec += 5; }
        if (game) { r.Game[i] = true; r.GameSec += 5; }
        // seconds at/above 100 C in this 5-s row (columns 12/13; older rows: one reading if the row max was >= 100)
        double c1 = p.Length > 11 ? P(p[11]) : double.NaN, g1 = p.Length > 12 ? P(p[12]) : double.NaN;
        if (double.IsNaN(c1)) c1 = (!double.IsNaN(cm) && cm >= 100) ? 1 : 0;
        if (double.IsNaN(g1)) g1 = (!double.IsNaN(gm) && gm >= 100) ? 1 : 0;
        if (c1 > 0) { r.C100Sec += c1; if (t - lastCT <= 6) curC += c1; else { r.C100Ep++; curC = c1; } lastCT = t; if (curC > r.C100Long) r.C100Long = curC; }
        if (g1 > 0) { r.G100Sec += g1; if (t - lastGT <= 6) curG += g1; else { r.G100Ep++; curG = g1; } lastGT = t; if (curG > r.G100Long) r.G100Long = curG; }
        if (c1 > 0 || g1 > 0) r.Hot[i] = true;
      }
    }
    for (int i = 0; i < n; i++) {
      r.C[i] = cc[i] > 0 ? r.C[i] / cc[i] : double.NaN; r.G[i] = gc[i] > 0 ? r.G[i] / gc[i] : double.NaN;
      r.F1[i] = fc[i] > 0 ? r.F1[i] / fc[i] : double.NaN; r.F2[i] = fc[i] > 0 ? r.F2[i] / fc[i] : double.NaN;
    }
    if (cn > 0) r.CAvg = cs / cn; if (gn > 0) r.GAvg = gs / gn;
    return r;
  }
  // polyline with gaps where there is no data
  public static string Line(double[] v, double w, double h, double lo, double hi) {
    var sb = new StringBuilder(); bool pen = false; int n = v.Length;
    for (int i = 0; i < n; i++) {
      if (double.IsNaN(v[i])) { pen = false; continue; }
      double x = (i + 0.5) * w / n, y = h - (Math.Max(lo, Math.Min(hi, v[i])) - lo) / (hi - lo) * h;
      sb.Append(pen ? " L " : " M ").Append(x.ToString("F1", Inv)).Append(',').Append(y.ToString("F1", Inv)); pen = true;
    }
    return sb.Length == 0 ? "M 0,0" : sb.ToString();
  }
  // one rectangle per run of flagged buckets
  public static string Band(bool[] f, double w, double y0, double y1) {
    var sb = new StringBuilder(); int n = f.Length;
    for (int i = 0; i < n; i++) {
      if (!f[i]) continue; int j = i; while (j + 1 < n && f[j + 1]) j++;
      string a = (i * w / n).ToString("F1", Inv), b = ((j + 1) * w / n).ToString("F1", Inv), ya = y0.ToString("F1", Inv), yb = y1.ToString("F1", Inv);
      sb.Append(" M ").Append(a).Append(',').Append(ya).Append(" L ").Append(b).Append(',').Append(ya).Append(" L ").Append(b).Append(',').Append(yb).Append(" L ").Append(a).Append(',').Append(yb).Append(" Z");
      i = j;
    }
    return sb.Length == 0 ? "M 0,0" : sb.ToString();
  }
}
'@
}
}

function Rep-Dur([double]$sec) {
  $m = [int][Math]::Round($sec / 60)
  if ($sec -lt 60) { return (N ($T.rpDurS -f [int]$sec)) }
  if ($m -lt 60) { return (N ($T.rpDurM -f $m)) }
  return (N ($T.rpDurHM -f [int][Math]::Floor($m / 60), ($m % 60)))
}
function Rep-Deg($v) { if ($v -eq $null -or [double]::IsNaN([double]$v)) { return [string][char]0x2014 }; N ('{0:0}°' -f [double]$v) }
function Rep-Events([datetime]$from, [datetime]$to) {
  $f = Join-Path $HistDir 'events.jsonl'; $out = New-Object System.Collections.ArrayList
  if (-not (Test-Path $f)) { return ,$out }
  $a = $from.ToString('s'); $b = $to.ToString('s')
  try {
    $fs = New-Object IO.FileStream($f, 'Open', 'Read', 'ReadWrite, Delete'); $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8); $txt = $sr.ReadToEnd(); $sr.Close()
    foreach ($ln in $txt.Split("`n")) {
      if ($ln.Length -lt 30) { continue }; $ts = $ln.Substring(6, 19)
      if ($ts -lt $a -or $ts -gt $b) { continue }
      # tiny fixed-format lines written by the engine: {"t":"...","e":"name","v":"value"} - a regex is much faster than ConvertFrom-Json
      if ($ln -match '"e":"(\w+)"(?:,"v":"((?:[^"\\]|\\.)*)")?') { [void]$out.Add([pscustomobject]@{ t = $ts; e = $matches[1]; v = $(if ($matches[2]) { [regex]::Unescape($matches[2]) } else { $null }) }) }
    }
  } catch {}
  return ,$out
}
$script:EvStyle = @{
  start = @('evStart', '#FF94A3B8'); stop = @('evStop', '#FF94A3B8'); resume = @('evResume', '#FF94A3B8'); update = @('evUpdate', '#FF60A5FA')
  cpuHot = @('evCpuHot', '#FFF43F5E'); cpuFast = @('evCpuFast', '#FFF97316'); cpuFull = @('evCpuFull', '#FF34D399'); gpuHot = @('evGpuHot', '#FFF43F5E'); gpuCool = @('evGpuCool', '#FF34D399')
  fanTake = @('evFanTake', '#FF38BDF8'); fanCrit = @('evFanCrit', '#FFF59E0B'); fanRelease = @('evFanRelease', '#FF7DD3FC'); failsafe = @('evFailsafe', '#FFF59E0B')
  gameOn = @('evGameOn', '#FFA78BFA'); gameOff = @('evGameOff', '#FFA78BFA'); prio = @('evPrio', '#FFFBBF24')
}

function Fill-Report([string]$range) {
  $r = $script:rep; $r.Range = $range; $u = $r.Ui
  foreach ($k in '1h','24h','7d') { $sel = ($k -eq $range); $u["R$k"].Background = Brush $(if ($sel) { '#FF3B4254' } else { '#FF1B1E27' }); $u["R$k"].Child.Foreground = Brush $(if ($sel) { '#FFFFFFFF' } else { '#FF9AA3B5' }) }
  $to = Get-Date; $from = switch ($range) { '1h' { $to.AddHours(-1) } '7d' { $to.AddDays(-7) } default { $to.AddHours(-24) } }
  $sw = [Diagnostics.Stopwatch]::StartNew(); Ensure-Rtg
  $n = switch ($range) { '1h' { 240 } '7d' { 336 } default { 288 } }
  $d = [RtgRep]::Load($HistDir, $from, $to, $n)
  $w = $u.Chart.ActualWidth; if ($w -lt 50) { $w = 640 }; $h = $u.Chart.Height; $lo = 20.0; $hi = 105.0
  $geo = { param($s) [Windows.Media.Geometry]::Parse($s) }
  $u.PCpu.Data = & $geo ([RtgRep]::Line($d.C, $w, $h, $lo, $hi)); $u.PGpu.Data = & $geo ([RtgRep]::Line($d.G, $w, $h, $lo, $hi))
  $u.PF1.Data = & $geo ([RtgRep]::Line($d.F1, $w, $h, 0, 100)); $u.PF2.Data = & $geo ([RtgRep]::Line($d.F2, $w, $h, 0, 100))
  $u.BThr.Data = & $geo ([RtgRep]::Band($d.Thr, $w, 0, $h)); $u.BBoost.Data = & $geo ([RtgRep]::Band($d.Boost, $w, $h - 12, $h - 6)); $u.BMax.Data = & $geo ([RtgRep]::Band($d.Max, $w, $h - 12, $h - 6))
  $u.BGame.Data = & $geo ([RtgRep]::Band($d.Game, $w, $h - 5, $h)); $u.BHot.Data = & $geo ([RtgRep]::Band($d.Hot, $w, 0, 5))
  foreach ($g in @(@('G50', 50), @('G70', 70), @('G90', 90), @('G100', 100))) { $y = $h - ($g[1] - $lo) / ($hi - $lo) * $h; $u[$g[0]].Y1 = $y; $u[$g[0]].Y2 = $y; $u[$g[0]].X2 = $w; [Windows.Controls.Canvas]::SetTop($u["T$($g[1])"], $y - 15) }
  # time axis
  $u.XAxis.Children.Clear()
  $fmt = if ($range -eq '7d') { 'MM/dd' } else { 'HH:mm' }
  for ($i = 0; $i -le 4; $i++) {
    $tb = New-Object Windows.Controls.TextBlock; $tb.Text = N ($from.AddSeconds(($to - $from).TotalSeconds * $i / 4).ToString($fmt, $Inv)); $tb.FontSize = 11; $tb.Foreground = Brush '#FF6B7385'
    $tb.Measure([Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity)); $x = $w * $i / 4 - $tb.DesiredSize.Width * $i / 4
    [Windows.Controls.Canvas]::SetLeft($tb, $x); [void]$u.XAxis.Children.Add($tb)
  }
  $u.NoData.Visibility = $(if ($d.Samples -eq 0) { 'Visible' } else { 'Collapsed' })
  # events
  $ev = Rep-Events $from $to
  $thr = @($ev | Where-Object { $_.e -eq 'cpuHot' -or $_.e -eq 'gpuHot' }).Count
  $games = @($ev | Where-Object { $_.e -eq 'gameOn' }).Count
  if ($games -eq 0 -and $d.GameSec -gt 0) { $games = 1 }
  $u.VCpuMax.Text = Rep-Deg $d.CMax; $u.VCpuAvg.Text = Rep-Deg $d.CAvg; $u.VGpuMax.Text = Rep-Deg $d.GMax; $u.VGpuAvg.Text = Rep-Deg $d.GAvg
  $u.VAbove.Text = Rep-Dur $d.Above90; $u.VThr.Text = N ([string]$thr); $u.VBoost.Text = Rep-Dur $d.BoostSec; $u.VGames.Text = N ([string]$games)
  foreach ($q in @(@('VC100', $d.C100Sec, $d.C100Ep, $d.C100Long), @('VG100', $d.G100Sec, $d.G100Ep, $d.G100Long))) {
    $u[$q[0]].Text = Rep-Dur $q[1]; $u[$q[0]].Foreground = Brush $(if ($q[1] -gt 0) { '#FFEF4444' } else { '#FF34D399' })
    $u["$($q[0])s"].Text = $(if ($q[2] -gt 0) { N ($T.rp100Sub -f $q[2], (Rep-Dur $q[3])) } else { '' })
  }
  $u.VAbove.Foreground = Brush $(if ($d.Above90 -gt 0) { '#FFFB7185' } else { '#FFF1F4FA' })
  foreach ($k in 'VCpuMax','VGpuMax') { $v = $(if ($k -eq 'VCpuMax') { $d.CMax } else { $d.GMax }); $u[$k].Foreground = Brush $(if ([double]::IsNaN($v)) { '#FFF1F4FA' } elseif ($v -ge 90) { '#FFFB7185' } elseif ($v -ge 75) { '#FFFBBF24' } else { '#FF34D399' }) }
  $u.Events.Children.Clear()
  $tfmt = if ($range -eq '7d') { 'MM/dd  HH:mm' } else { 'HH:mm:ss' }
  $list = @($ev | Select-Object -Last 150); [array]::Reverse($list)
  foreach ($e in $list) {
    $st = $script:EvStyle[[string]$e.e]; if (-not $st) { continue }
    $txt = [string]$T.($st[0]); if ($txt -match '\{0\}') { $v = [string]$e.v; if (-not $v) { $v = '?' }; $txt = $txt -f $v }
    $row = New-Object Windows.Controls.Grid; $row.Margin = '0,3,0,3'
    foreach ($cw in 'Auto','Auto','*') { $c = New-Object Windows.Controls.ColumnDefinition; $c.Width = $cw; $row.ColumnDefinitions.Add($c) }
    $tt = New-Object Windows.Controls.TextBlock; $tt.Text = N (([datetime]$e.t).ToString($tfmt, $Inv)); $tt.Foreground = Brush '#FF6B7385'; $tt.FontSize = 12; $tt.FlowDirection = 'LeftToRight'; $tt.MinWidth = $(if ($range -eq '7d') { 92 } else { 62 })
    $dot = New-Object Windows.Shapes.Ellipse; $dot.Width = 8; $dot.Height = 8; $dot.Fill = Brush $st[1]; $dot.Margin = '10,0,10,0'; $dot.VerticalAlignment = 'Center'; [Windows.Controls.Grid]::SetColumn($dot, 1)
    $tx = New-Object Windows.Controls.TextBlock; $tx.Text = N $txt; $tx.Foreground = Brush '#FFE2E6EF'; $tx.FontSize = 12.5; $tx.TextWrapping = 'Wrap'; [Windows.Controls.Grid]::SetColumn($tx, 2)
    [void]$row.Children.Add($tt); [void]$row.Children.Add($dot); [void]$row.Children.Add($tx); [void]$u.Events.Children.Add($row)
  }
  if ($u.Events.Children.Count -eq 0) { $tb = New-Object Windows.Controls.TextBlock; $tb.Text = $T.rpNoEvents; $tb.Foreground = Brush '#FF6B7385'; $tb.FontSize = 12.5; [void]$u.Events.Children.Add($tb) }
  $r.LoadMs = [int]$sw.ElapsedMilliseconds
}

function Show-Report([string]$range = '24h', [string]$snapTo = $null, [switch]$Hidden) {
  if (-not $Hidden -and $script:rep -and $script:rep.Win -and $script:rep.Win.IsVisible -and $script:rep.Lang -eq $lang) {
    $script:rep.Win.Activate() | Out-Null; Fill-Report $range; if ($snapTo) { $script:rep.Snap = $snapTo; $script:rep.SnapTimer.Start() }; return
  }
  if (-not $Hidden -and $script:rep -and $script:rep.Win) { try { $script:rep.Win.Close() } catch {} }
$x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="{{rpTitle}} - Rosa Thermal Guard" Width="760" SizeToContent="Height" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" ShowInTaskbar="True" FontFamily="{{font}}" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Border Margin="14" CornerRadius="20" Background="#FF15171E" BorderBrush="#FF2A2E3A" BorderThickness="1" Padding="22,16,22,16" FlowDirection="{{dir}}">
    <Border.Effect><DropShadowEffect BlurRadius="24" ShadowDepth="4" Opacity="0.55" Color="#000000"/></Border.Effect>
    <StackPanel>
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Ellipse Width="10" Height="10" Fill="#FF34D399" Margin="0,0,10,0" VerticalAlignment="Center"/>
          <TextBlock Text="{{rpTitle}}" Foreground="#FFF1F4FA" FontSize="18" FontWeight="SemiBold" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" Margin="0,0,12,0" VerticalAlignment="Center">
          <Border x:Name="R1h" CornerRadius="10" Padding="12,5" Margin="2,0" Cursor="Hand"><TextBlock Text="{{r1h}}" FontSize="12.5"/></Border>
          <Border x:Name="R24h" CornerRadius="10" Padding="12,5" Margin="2,0" Cursor="Hand"><TextBlock Text="{{r24h}}" FontSize="12.5"/></Border>
          <Border x:Name="R7d" CornerRadius="10" Padding="12,5" Margin="2,0" Cursor="Hand"><TextBlock Text="{{r7d}}" FontSize="12.5"/></Border>
        </StackPanel>
        <Border x:Name="XBtn" Grid.Column="2" Width="28" Height="28" CornerRadius="14" Background="#FF222632" Cursor="Hand" ToolTip="{{closeTip}}">
          <TextBlock Text="&#x2715;" Foreground="#FFB8C0D0" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center" FontFamily="Segoe UI Symbol"/>
        </Border>
      </Grid>
      <Border Margin="0,14,0,0" CornerRadius="14" Background="#FF1B1E27" Padding="12,12,12,8" FlowDirection="LeftToRight">
        <StackPanel>
          <Grid>
            <Canvas x:Name="Chart" Height="210" ClipToBounds="True" Background="Transparent">
              <Path x:Name="BThr" Fill="#1CF43F5E"/>
              <Line x:Name="G50" Stroke="#FF262A36" StrokeThickness="1"/><Line x:Name="G70" Stroke="#FF262A36" StrokeThickness="1"/>
              <Line x:Name="G90" Stroke="#66F43F5E" StrokeThickness="1" StrokeDashArray="4 3"/>
              <Line x:Name="G100" Stroke="#B3EF4444" StrokeThickness="1"/>
              <TextBlock x:Name="T100" Text="100°" Foreground="#FFEF4444" FontSize="10.5" Canvas.Left="2"/>
              <TextBlock x:Name="T50" Text="50°" Foreground="#FF5B6375" FontSize="10.5" Canvas.Left="2"/>
              <TextBlock x:Name="T70" Text="70°" Foreground="#FF5B6375" FontSize="10.5" Canvas.Left="2"/>
              <TextBlock x:Name="T90" Text="90°" Foreground="#FFB4536A" FontSize="10.5" Canvas.Left="2"/>
              <Path x:Name="PF1" Stroke="#B338BDF8" StrokeThickness="1.3" StrokeDashArray="3 2"/>
              <Path x:Name="PF2" Stroke="#B32DD4BF" StrokeThickness="1.3" StrokeDashArray="3 2"/>
              <Path x:Name="PGpu" Stroke="#FF34D399" StrokeThickness="1.8" StrokeLineJoin="Round"/>
              <Path x:Name="PCpu" Stroke="#FFFBBF24" StrokeThickness="1.8" StrokeLineJoin="Round"/>
              <Path x:Name="BHot" Fill="#FFEF4444"/><Path x:Name="BBoost" Fill="#FF0EA5E9"/><Path x:Name="BMax" Fill="#FFF59E0B"/><Path x:Name="BGame" Fill="#FF8B5CF6"/>
            </Canvas>
            <TextBlock x:Name="NoData" Text="{{rpNoData}}" Foreground="#FF6B7385" FontSize="13" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
            <TextBlock x:Name="TFan100" Text="100%" Foreground="#FF4B7A94" FontSize="10" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,-2,2,0"/>
          </Grid>
          <Canvas x:Name="XAxis" Height="16" Margin="0,4,0,0"/>
        </StackPanel>
      </Border>
      <WrapPanel Margin="2,8,0,0" HorizontalAlignment="Center">
        <WrapPanel.Resources><Style TargetType="TextBlock"><Setter Property="Foreground" Value="#FF9AA3B5"/><Setter Property="FontSize" Value="11.5"/><Setter Property="Margin" Value="5,0,12,0"/><Setter Property="VerticalAlignment" Value="Center"/></Style></WrapPanel.Resources>
        <Rectangle Width="14" Height="3" Fill="#FFFBBF24" VerticalAlignment="Center"/><TextBlock Text="{{cpu}}"/>
        <Rectangle Width="14" Height="3" Fill="#FF34D399" VerticalAlignment="Center"/><TextBlock Text="{{gpu}}"/>
        <Rectangle Width="14" Height="2" Fill="#FF38BDF8" VerticalAlignment="Center"/><TextBlock Text="{{lgCpuFan}}"/>
        <Rectangle Width="14" Height="2" Fill="#FF2DD4BF" VerticalAlignment="Center"/><TextBlock Text="{{lgGpuFan}}"/>
        <Rectangle Width="12" Height="10" Fill="#55F43F5E" VerticalAlignment="Center"/><TextBlock Text="{{lgThrottle}}"/>
        <Rectangle Width="12" Height="5" Fill="#FFEF4444" VerticalAlignment="Center"/><TextBlock Text="{{lgOver100}}"/>
        <Rectangle Width="12" Height="5" Fill="#FF0EA5E9" VerticalAlignment="Center"/><TextBlock Text="{{lgBoost}}"/>
        <Rectangle Width="12" Height="5" Fill="#FFF59E0B" VerticalAlignment="Center"/><TextBlock Text="{{lgMax}}"/>
        <Rectangle Width="12" Height="5" Fill="#FF8B5CF6" VerticalAlignment="Center"/><TextBlock Text="{{gameMode}}"/>
      </WrapPanel>
      <UniformGrid Columns="4" Margin="-4,10,-4,0">
        <UniformGrid.Resources>
          <Style TargetType="Border"><Setter Property="Background" Value="#FF1B1E27"/><Setter Property="CornerRadius" Value="12"/><Setter Property="Padding" Value="14,10"/><Setter Property="Margin" Value="4"/></Style>
        </UniformGrid.Resources>
        <Border><StackPanel><TextBlock Text="{{rpCpuMax}}" Foreground="#FF8A93A6" FontSize="11.5"/><TextBlock x:Name="VCpuMax" Foreground="#FFF1F4FA" FontSize="22" FontWeight="SemiBold" Margin="0,2,0,0"/></StackPanel></Border>
        <Border><StackPanel><TextBlock Text="{{rpCpuAvg}}" Foreground="#FF8A93A6" FontSize="11.5"/><TextBlock x:Name="VCpuAvg" Foreground="#FFF1F4FA" FontSize="22" FontWeight="SemiBold" Margin="0,2,0,0"/></StackPanel></Border>
        <Border><StackPanel><TextBlock Text="{{rpGpuMax}}" Foreground="#FF8A93A6" FontSize="11.5"/><TextBlock x:Name="VGpuMax" Foreground="#FFF1F4FA" FontSize="22" FontWeight="SemiBold" Margin="0,2,0,0"/></StackPanel></Border>
        <Border><StackPanel><TextBlock Text="{{rpGpuAvg}}" Foreground="#FF8A93A6" FontSize="11.5"/><TextBlock x:Name="VGpuAvg" Foreground="#FFF1F4FA" FontSize="22" FontWeight="SemiBold" Margin="0,2,0,0"/></StackPanel></Border>
        <Border><StackPanel><TextBlock Text="{{rpAbove90}}" Foreground="#FF8A93A6" FontSize="11.5"/><TextBlock x:Name="VAbove" Foreground="#FFF1F4FA" FontSize="22" FontWeight="SemiBold" Margin="0,2,0,0"/></StackPanel></Border>
        <Border><StackPanel><TextBlock Text="{{rpThrottle}}" Foreground="#FF8A93A6" FontSize="11.5"/><TextBlock x:Name="VThr" Foreground="#FFF1F4FA" FontSize="22" FontWeight="SemiBold" Margin="0,2,0,0"/></StackPanel></Border>
        <Border><StackPanel><TextBlock Text="{{rpBoost}}" Foreground="#FF8A93A6" FontSize="11.5"/><TextBlock x:Name="VBoost" Foreground="#FF7DD3FC" FontSize="22" FontWeight="SemiBold" Margin="0,2,0,0"/></StackPanel></Border>
        <Border><StackPanel><TextBlock Text="{{rpGames}}" Foreground="#FF8A93A6" FontSize="11.5"/><TextBlock x:Name="VGames" Foreground="#FFC4B5FD" FontSize="22" FontWeight="SemiBold" Margin="0,2,0,0"/></StackPanel></Border>
      </UniformGrid>
      <UniformGrid Columns="2" Margin="-4,0,-4,0">
        <UniformGrid.Resources>
          <Style TargetType="Border"><Setter Property="Background" Value="#FF1B1E27"/><Setter Property="CornerRadius" Value="12"/><Setter Property="Padding" Value="14,10"/><Setter Property="Margin" Value="4"/></Style>
        </UniformGrid.Resources>
        <Border><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <StackPanel><TextBlock Text="{{rpCpu100}}" Foreground="#FF8A93A6" FontSize="11.5"/><TextBlock x:Name="VC100" Foreground="#FFF1F4FA" FontSize="22" FontWeight="SemiBold" Margin="0,2,0,0"/></StackPanel>
          <TextBlock x:Name="VC100s" Grid.Column="1" Foreground="#FF8A93A6" FontSize="11.5" VerticalAlignment="Bottom" HorizontalAlignment="Right" Margin="10,0,0,4" TextWrapping="Wrap" TextAlignment="Right"/></Grid></Border>
        <Border><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <StackPanel><TextBlock Text="{{rpGpu100}}" Foreground="#FF8A93A6" FontSize="11.5"/><TextBlock x:Name="VG100" Foreground="#FFF1F4FA" FontSize="22" FontWeight="SemiBold" Margin="0,2,0,0"/></StackPanel>
          <TextBlock x:Name="VG100s" Grid.Column="1" Foreground="#FF8A93A6" FontSize="11.5" VerticalAlignment="Bottom" HorizontalAlignment="Right" Margin="10,0,0,4" TextWrapping="Wrap" TextAlignment="Right"/></Grid></Border>
      </UniformGrid>
      <TextBlock Text="{{rpEvents}}" Foreground="#FFF1F4FA" FontSize="14" FontWeight="SemiBold" Margin="2,12,0,6"/>
      <Border CornerRadius="12" Background="#FF1B1E27" Padding="14,8">
        <ScrollViewer MaxHeight="170" VerticalScrollBarVisibility="Hidden" PanningMode="VerticalOnly"><StackPanel x:Name="Events"/></ScrollViewer>
      </Border>
      <Grid Margin="2,10,0,0">
        <TextBlock x:Name="RawLog" Text="{{rpRawLog}}" Foreground="#FF60A5FA" FontSize="12" Cursor="Hand" TextDecorations="Underline" HorizontalAlignment="Left"/>
        <TextBlock Text="Rosa Thermal Guard" Foreground="#FF4A5162" FontSize="11" HorizontalAlignment="Right"/>
      </Grid>
    </StackPanel>
  </Border>
</Window>
'@
  foreach ($p in $T.PSObject.Properties) { $x = $x.Replace('{{' + $p.Name + '}}', [Security.SecurityElement]::Escape([string]$p.Value)) }
  $win = [Windows.Markup.XamlReader]::Parse($x)
  $u = @{}
  foreach ($k in 'R1h','R24h','R7d','XBtn','Chart','BThr','G50','G70','G90','T50','T70','T90','PF1','PF2','PGpu','PCpu','BBoost','BMax','BGame','NoData','XAxis','VCpuMax','VCpuAvg','VGpuMax','VGpuAvg','VAbove','VThr','VBoost','VGames','Events','RawLog','TFan100','G100','T100','BHot','VC100','VC100s','VG100','VG100s') { $u[$k] = $win.FindName($k) }
  foreach ($k in 'T50','T70','T90','T100','TFan100') { $u[$k].Text = N $u[$k].Text }
  if ($Hidden) {
    # render straight to a PNG without ever showing a window (no focus change, safe while a game is in front)
    $prev = $script:rep; $script:rep = @{ Win = $win; Ui = $u; Lang = $lang; Range = $range; LoadMs = 0 }
    try {
      $el = $win.Content; $sz = [Windows.Size]::new(760, [double]::PositiveInfinity)
      $el.Measure($sz); $el.Arrange([Windows.Rect]::new(0, 0, 760, $el.DesiredSize.Height)); $el.UpdateLayout()
      Fill-Report $range
      $el.Measure($sz); $el.Arrange([Windows.Rect]::new(0, 0, 760, $el.DesiredSize.Height)); $el.UpdateLayout()
      $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap([int]($el.ActualWidth * 2 + 56), [int]($el.ActualHeight * 2 + 56), 192, 192, [Windows.Media.PixelFormats]::Pbgra32)
      $rtb.Render($el); $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
      $fs = [IO.File]::Create($snapTo); $enc.Save($fs); $fs.Close()
      UiLog "report snapshot saved ($range, load $($script:rep.LoadMs) ms): $snapTo"
    } finally { $script:rep = $prev; try { $win.Close() } catch {} }
    return
  }
  $snapT = New-Object Windows.Threading.DispatcherTimer; $snapT.Interval = [TimeSpan]::FromMilliseconds(900)
  $script:rep = @{ Win = $win; Ui = $u; Lang = $lang; Range = $range; Snap = $snapTo; SnapTimer = $snapT; LoadMs = 0 }
  $snapT.Add_Tick({
    $this.Stop(); $r = $script:rep; if (-not $r.Snap) { return }
    try {
      $el = $r.Win.Content
      $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap([int]($el.ActualWidth * 2 + 56), [int]($el.ActualHeight * 2 + 56), 192, 192, [Windows.Media.PixelFormats]::Pbgra32)
      $rtb.Render($el); $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
      $fs = [IO.File]::Create($r.Snap); $enc.Save($fs); $fs.Close(); UiLog "report snapshot saved ($($r.Range), load $($r.LoadMs) ms): $($r.Snap)"
    } catch { UiLog "report snapshot failed: $($_.Exception.Message)" }
    $r.Snap = $null
  })
  foreach ($k in '1h','24h','7d') {
    $u["R$k"].Tag = $k
    $u["R$k"].Add_MouseLeftButtonDown({ $_.Handled = $true; Fill-Report ([string]$this.Tag) })
  }
  $u.XBtn.Add_MouseLeftButtonDown({ $_.Handled = $true; $script:rep.Win.Close() })
  $u.XBtn.Add_MouseEnter({ $this.Background = Brush '#FF2E3342' }); $u.XBtn.Add_MouseLeave({ $this.Background = Brush '#FF222632' })
  $u.RawLog.Add_MouseLeftButtonDown({ $_.Handled = $true; Start-Process notepad.exe (Join-Path $Root 'guard.log') })
  $win.Add_MouseLeftButtonDown({ try { $script:rep.Win.DragMove() } catch {} })
  $win.Add_KeyDown({ if ($_.Key -eq 'Escape') { $script:rep.Win.Close() } })
  $win.Add_Loaded({
    $r = $script:rep; $wa = [Windows.SystemParameters]::WorkArea
    try { Fill-Report $r.Range } catch { UiLog "report fill failed: $($_.Exception.Message)" }
    $r.Win.UpdateLayout()
    $r.Win.Left = [Math]::Max($wa.Left, $wa.Left + ($wa.Width - $r.Win.ActualWidth) / 2); $r.Win.Top = [Math]::Max($wa.Top, $wa.Top + ($wa.Height - $r.Win.ActualHeight) / 2)
    if ($r.Snap) { $r.SnapTimer.Start() }
  })
  $win.Add_Closed({ if ($script:rep -and $script:rep.Win -eq $this) { $script:rep.Win = $null } })
  $win.Show(); $win.Activate() | Out-Null
  UiLog "report opened ($range)"
}
