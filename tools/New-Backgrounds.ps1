<#
.SYNOPSIS
  Generates the ArcadeMaster horizon backgrounds (1920x1080 JPEG, original procedural art):
    racing_*  : desert highway, coastal road, alpine pass, night-city highway, floodlit circuit
    flight_*  : above the clouds, ocean islands from altitude, aurora night, storm front, mountain ranges, edge of space
  Output: layouts\ArcadeMaster\images\bg\*.jpg   (rotation + shuffle handled by Set-LayoutThemes.ps1 -Shuffle)
#>
param([string]$OutDir = (Join-Path $PSScriptRoot '..\layouts\ArcadeMaster\images\bg'), [int]$Quality = 88)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$W = 1920; $H = 1080
$jpg = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object MimeType -eq 'image/jpeg'
$ep = New-Object Drawing.Imaging.EncoderParameters 1
$ep.Param[0] = New-Object Drawing.Imaging.EncoderParameter ([Drawing.Imaging.Encoder]::Quality), ([long]$Quality)

function C([string]$hex, [int]$a = 255) { $c = [Drawing.ColorTranslator]::FromHtml("#$hex"); [Drawing.Color]::FromArgb($a, $c) }
function New-Scene { $b = New-Object Drawing.Bitmap $W, $H; $g = [Drawing.Graphics]::FromImage($b); $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'; @{ B = $b; G = $g } }
function Save-Scene($s, [string]$name) { $s.G.Dispose(); $p = Join-Path $OutDir $name; $s.B.Save($p, $jpg, $ep); $s.B.Dispose(); Write-Host ("{0,-34} {1,8:N0} KB" -f $name, ((Get-Item $p).Length / 1KB)) }
function Sky($g, [string[]]$cols, [float[]]$pos, [int]$y0 = 0, [int]$y1 = $H) {
  $br = New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.Point]::new(0, $y0)), ([Drawing.Point]::new(0, $y1 + 1)), (C $cols[0]), (C $cols[-1])
  $cb = New-Object Drawing.Drawing2D.ColorBlend $cols.Count; $cb.Colors = @($cols | ForEach-Object { C $_ }); $cb.Positions = $pos; $br.InterpolationColors = $cb
  $g.FillRectangle($br, 0, $y0, $W, $y1 - $y0)
}
function Glow($g, [float]$x, [float]$y, [float]$r, [string]$hex, [int]$a) {
  $path = New-Object Drawing.Drawing2D.GraphicsPath; $path.AddEllipse($x - $r, $y - $r, 2 * $r, 2 * $r)
  $pb = New-Object Drawing.Drawing2D.PathGradientBrush $path; $pb.CenterColor = C $hex $a; $pb.SurroundColors = @(C $hex 0)
  $g.FillEllipse($pb, $x - $r, $y - $r, 2 * $r, 2 * $r)
}
function Disc($g, [float]$x, [float]$y, [float]$r, [string]$hex, [int]$a = 255) { $g.FillEllipse((New-Object Drawing.SolidBrush (C $hex $a)), $x - $r, $y - $r, 2 * $r, 2 * $r) }
function Ridge([int]$seed, [float]$base, [float]$amp, [float]$rough = 0.55, [int]$levels = 8) {
  # midpoint displacement -> skyline points
  $rnd = New-Object Random $seed; $n = [Math]::Pow(2, $levels); $ys = New-Object double[] ($n + 1)
  $ys[0] = $rnd.NextDouble(); $ys[$n] = $rnd.NextDouble(); $step = $n; $scale = 1.0
  while ($step -gt 1) { $half = $step / 2; for ($i = $half; $i -lt $n; $i += $step) { $ys[$i] = ($ys[$i - $half] + $ys[$i + $half]) / 2 + ($rnd.NextDouble() - 0.5) * $scale }; $scale *= $rough; $step = $half }
  $min = ($ys | Measure-Object -Minimum).Minimum; $max = ($ys | Measure-Object -Maximum).Maximum; $span = [Math]::Max(1e-6, $max - $min)
  $pts = New-Object 'System.Collections.Generic.List[Drawing.PointF]'
  for ($i = 0; $i -le $n; $i++) { $pts.Add([Drawing.PointF]::new($i * $W / $n, $base - ($ys[$i] - $min) / $span * $amp)) }
  , $pts
}
function Fill-Ridge($g, $pts, [string]$hex, [int]$a = 255, [float]$bottom = $H) {
  $all = New-Object 'System.Collections.Generic.List[Drawing.PointF]'; $all.Add([Drawing.PointF]::new(0, $bottom)); $all.AddRange($pts); $all.Add([Drawing.PointF]::new($W, $bottom))
  $g.FillPolygon((New-Object Drawing.SolidBrush (C $hex $a)), $all.ToArray())
}
function Stars($g, [int]$seed, [int]$n, [float]$maxY) { $r = New-Object Random $seed; for ($i = 0; $i -lt $n; $i++) { $s = $r.NextDouble() * 2.2 + 0.5; $g.FillEllipse((New-Object Drawing.SolidBrush (C 'ffffff' ($r.Next(50, 230)))), $r.Next(0, $W), $r.NextDouble() * $maxY, $s, $s) } }
function Cloud($g, [Random]$r, [float]$cx, [float]$cy, [float]$w, [string]$hi, [string]$lo, [int]$alpha) {
  for ($i = 0; $i -lt 26; $i++) {
    $px = $cx + ($r.NextDouble() - 0.5) * $w; $py = $cy + ($r.NextDouble() - 0.5) * $w * 0.22; $pr = $w * (0.07 + $r.NextDouble() * 0.12)
    Glow $g $px ($py + $pr * 0.25) $pr $lo ([int]($alpha * 0.8)); Glow $g $px ($py - $pr * 0.1) ($pr * 0.85) $hi $alpha
  }
}
function Road($g, [float]$vx, [float]$hy, [float]$botHalf, [string]$asphalt, [string]$edge, [string]$dash, [float]$t = 0) {
  $road = [Drawing.PointF[]]@([Drawing.PointF]::new($vx - 4, $hy), [Drawing.PointF]::new($vx + 4, $hy), [Drawing.PointF]::new($W / 2 + $botHalf, $H), [Drawing.PointF]::new($W / 2 - $botHalf, $H))
  $g.FillPolygon((New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.Point]::new(0, [int]$hy)), ([Drawing.Point]::new(0, $H + 1)), (C $asphalt 230), (C $asphalt)), $road)
  foreach ($s in -1, 1) { $g.DrawLine((New-Object Drawing.Pen (C $edge 220), 5), $vx + 3 * $s, $hy, $W / 2 + ($botHalf - 40) * $s, $H) }
  for ($k = 1; $k -lt 40; $k++) {                                                        # centre dashes, perspective-correct (z = k)
    $z1 = $k + $t; $z2 = $k + 0.45 + $t; $y1 = $hy + ($H - $hy) / $z1; $y2 = $hy + ($H - $hy) / $z2
    if ($y1 - $y2 -lt 1.2) { break }
    $f1 = ($y1 - $hy) / ($H - $hy); $f2 = ($y2 - $hy) / ($H - $hy); $x1 = $vx + ($W / 2 - $vx) * $f1; $x2 = $vx + ($W / 2 - $vx) * $f2
    $pen = New-Object Drawing.Pen (C $dash 235), ([float][Math]::Max(1, 16 * $f1)); $g.DrawLine($pen, $x1, $y1, $x2, $y2)
  }
}
function Haze($g, [float]$y, [float]$h, [string]$hex, [int]$a) {
  $br = New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.Point]::new(0, [int]($y - $h))), ([Drawing.Point]::new(0, [int]($y + $h))), (C $hex 0), (C $hex 0)
  $cb = New-Object Drawing.Drawing2D.ColorBlend 3; $cb.Colors = @((C $hex 0), (C $hex $a), (C $hex 0)); $cb.Positions = [float[]]@(0, 0.5, 1); $br.InterpolationColors = $cb
  $g.FillRectangle($br, 0, $y - $h, $W, 2 * $h)
}

# ===================================================================== RACING
# R1 desert highway at sunset
$s = New-Scene; $g = $s.G; $hy = 640
Sky $g @('1b0b3a', '5b1e6b', 'c2405b', 'ff8a3d', 'ffd27a') @(0, 0.35, 0.65, 0.88, 1) 0 $hy
Glow $g 960 ($hy - 40) 520 'ffb347' 170; Disc $g 960 ($hy - 40) 150 'ffe08a'
Fill-Ridge $g (Ridge 11 ($hy + 5) 150 0.35 6) '3a1630'                                    # distant mesas
$m = Ridge 12 ($hy + 8) 70 0.7 7; Fill-Ridge $g $m '24101f'
Sky $g @('4a2232', '8a4a3a', 'c27a4a') @(0, 0.5, 1) $hy $H
Haze $g $hy 26 'ffcf8a' 150
Road $g 960 $hy 760 '2b2228' 'f5e6c8' 'ffd166' 0.35
Save-Scene $s 'racing_desert_highway.jpg'

# R2 coastal road, bright day
$s = New-Scene; $g = $s.G; $hy = 560; $r = New-Object Random 31
Sky $g @('1f6fc7', '4fa0e6', '9fd3f5', 'e4f4ff') @(0, 0.45, 0.85, 1) 0 $hy
foreach ($i in 0..6) { Cloud $g $r ($r.Next(80, 1840)) ($r.Next(90, 330)) ($r.Next(260, 520)) 'ffffff' 'c9dbef' 150 }
Sky $g @('2a8cc2', '1a5f9a', '0f3f73') @(0, 0.4, 1) $hy $H                                # ocean
for ($i = 0; $i -lt 260; $i++) { $yy = $hy + [Math]::Pow($r.NextDouble(), 2) * ($H - $hy); $ww = 10 + ($yy - $hy) * 0.35; $g.FillRectangle((New-Object Drawing.SolidBrush (C 'e8f6ff' ($r.Next(40, 120)))), $r.Next(0, $W), $yy, $ww, 2) }
$cliff = Ridge 33 ($hy + 30) 260 0.5 7
$pts = New-Object 'System.Collections.Generic.List[Drawing.PointF]'; foreach ($p in $cliff) { if ($p.X -ge 1080) { $pts.Add($p) } }
$poly = New-Object 'System.Collections.Generic.List[Drawing.PointF]'; $poly.Add([Drawing.PointF]::new(1080, $H)); $poly.Add([Drawing.PointF]::new(1080, $hy + 20)); $poly.AddRange($pts); $poly.Add([Drawing.PointF]::new($W, $H))
$g.FillPolygon((New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.Point]::new(0, 300)), ([Drawing.Point]::new(0, $H)), (C '5f8f4a'), (C '2c4a24')), $poly.ToArray())
Haze $g $hy 18 'ffffff' 140
Road $g 1250 ($hy + 30) 820 '3a3d42' 'ffffff' 'ffd23f' 0.1
$g.DrawLine((New-Object Drawing.Pen (C 'd9dde3' 230), 7), 1244, ($hy + 34), 520, $H)    # guard rail
Save-Scene $s 'racing_coastal_road.jpg'

# R3 alpine pass at dawn
$s = New-Scene; $g = $s.G; $hy = 690
Sky $g @('2d3a74', '6b5fa5', 'e39ab8', 'ffd3b0') @(0, 0.4, 0.8, 1) 0 $hy
Glow $g 1350 ($hy - 120) 420 'ffc6a0' 140
$layers = @(@(41, 380, 'e9e6f5', 0.62), @(42, 260, '8f89c0', 0.55), @(43, 170, '5f5a92', 0.6))   # far range = snowfields
foreach ($L in $layers) { $pts = Ridge $L[0] ($hy - 40 + [int]($L[1] -lt 300) * 60) $L[1] $L[3] 7; Fill-Ridge $g $pts $L[2]; Haze $g ($hy - 60) 30 'ffd3b0' 60 }
$r = New-Object Random 44; $trees = New-Object Drawing.SolidBrush (C '1c2338')
Fill-Ridge $g (Ridge 45 ($hy + 70) 40 0.6 6) '232a44'
for ($i = 0; $i -lt 160; $i++) { $tx = $r.Next(0, $W); if ([Math]::Abs($tx - 960) -lt 330) { continue }; $th = $r.Next(40, 140); $ty = $hy + 40 + $r.Next(0, 80); $g.FillPolygon($trees, [Drawing.PointF[]]@([Drawing.PointF]::new($tx, $ty - $th), [Drawing.PointF]::new($tx - $th * 0.22, $ty), [Drawing.PointF]::new($tx + $th * 0.22, $ty))) }
$g.FillRectangle((New-Object Drawing.SolidBrush (C '1a2033')), 0, $hy + 110, $W, $H)
Road $g 960 ($hy + 40) 700 '30323d' 'f0f0f5' 'ffffff' 0.6
Save-Scene $s 'racing_alpine_pass.jpg'

# R4 night city highway
$s = New-Scene; $g = $s.G; $hy = 600; $r = New-Object Random 51
Sky $g @('03040e', '0c1233', '2a1f5a', '5a2a6e') @(0, 0.5, 0.85, 1) 0 $hy
Stars $g 52 140 350; Disc $g 1560 170 46 'f3f0e1'; Glow $g 1560 170 160 'c9d6ff' 60
for ($x = -20; $x -lt $W; $x += $r.Next(30, 90)) {                                      # skyline with lit windows
  $bw = $r.Next(40, 120); $bh = $r.Next(80, 360); $by = $hy - $bh
  $g.FillRectangle((New-Object Drawing.SolidBrush (C '0b0d1c')), $x, $by, $bw, $bh + 2)
  for ($wy = $by + 10; $wy -lt $hy - 8; $wy += 14) { for ($wx = $x + 6; $wx -lt $x + $bw - 6; $wx += 11) { if ($r.NextDouble() -lt 0.38) { $g.FillRectangle((New-Object Drawing.SolidBrush (C ($(if ($r.NextDouble() -lt 0.8) { 'ffd98a' } else { '8fd3ff' })) ($r.Next(110, 230)))), $wx, $wy, 5, 7) } } }
  if ($r.NextDouble() -lt 0.15) { Glow $g ($x + $bw / 2) $by 18 'ff3b3b' 220 }
}
Haze $g $hy 40 '6a3fa0' 120
Sky $g @('14152a', '0a0b16') @(0, 1) $hy $H
Road $g 960 $hy 900 '17181f' 'cfd3ff' 'ffffff' 0.2
for ($i = 0; $i -lt 26; $i++) {                                                          # traffic light trails
  $side = if ($i % 2) { 1 } else { -1 }; $col = if ($side -lt 0) { 'ff3b3b' } else { 'fff3d0' }; $off = 120 + $r.Next(0, 300)
  $pen = New-Object Drawing.Pen (C $col ($r.Next(90, 200))), ([float]$r.Next(2, 6)); $g.DrawLine($pen, 960 + $side * 6, $hy + 2, 960 + $side * $off, $H)
}
Save-Scene $s 'racing_night_city.jpg'

# R5 floodlit circuit at dusk
$s = New-Scene; $g = $s.G; $hy = 620; $r = New-Object Random 61
Sky $g @('101836', '2c3d7a', 'a25a7a', 'f0a36a') @(0, 0.45, 0.85, 1) 0 $hy
$g.FillRectangle((New-Object Drawing.SolidBrush (C '141524')), 0, $hy - 150, $W, 152)    # grandstand
for ($row = 0; $row -lt 9; $row++) { for ($x = 0; $x -lt $W; $x += 9) { if ($r.NextDouble() -lt 0.55) { $g.FillRectangle((New-Object Drawing.SolidBrush (C ($(@('e8e8f0', 'ff6b6b', '4fc3f7', 'ffd166')[$r.Next(0, 4)])) ($r.Next(40, 140)))), $x, $hy - 140 + $row * 15, 4, 6) } } }
$g.FillPolygon((New-Object Drawing.SolidBrush (C '0d0e19')), [Drawing.PointF[]]@([Drawing.PointF]::new(0, $hy - 150), [Drawing.PointF]::new($W, $hy - 150), [Drawing.PointF]::new($W, $hy - 175), [Drawing.PointF]::new(0, $hy - 190)))
foreach ($tx in 160, 620, 1300, 1760) {                                                  # floodlight towers
  $g.FillRectangle((New-Object Drawing.SolidBrush (C '0b0c14')), $tx - 6, $hy - 470, 12, 330)
  $g.FillRectangle((New-Object Drawing.SolidBrush (C 'fffbe6')), $tx - 40, $hy - 490, 80, 26); Glow $g $tx ($hy - 478) 260 'fff3c4' 150
}
$g.FillRectangle((New-Object Drawing.SolidBrush (C '2c5a2e')), 0, $hy, $W, $H - $hy)
$track = [Drawing.PointF[]]@([Drawing.PointF]::new(0, $hy + 60), [Drawing.PointF]::new($W, $hy + 20), [Drawing.PointF]::new($W, $hy + 200), [Drawing.PointF]::new(0, $H))
$g.FillPolygon((New-Object Drawing.SolidBrush (C '3a3c44')), $track)
for ($i = 0; $i -lt 40; $i++) { $t1 = $i / 40; $t2 = ($i + 1) / 40; $col = if ($i % 2) { 'e63946' } else { 'f5f5f5' }
  $g.DrawLine((New-Object Drawing.Pen (C $col), 14), [float]($t1 * $W), [float]($hy + 60 - 40 * $t1), [float]($t2 * $W), [float]($hy + 60 - 40 * $t2)) }   # kerb
$g.DrawLine((New-Object Drawing.Pen (C 'ffffff' 200), 6), 0, $H - 20, $W, $hy + 190)
Save-Scene $s 'racing_circuit_dusk.jpg'

# ===================================================================== FLIGHT
# F1 above the clouds, golden hour
$s = New-Scene; $g = $s.G; $r = New-Object Random 71
Sky $g @('173a7a', '3f6fb8', 'f2b36b', 'ffe0a8') @(0, 0.45, 0.85, 1) 0 620
Glow $g 520 520 520 'ffd08a' 170; Disc $g 520 520 70 'fff4d6'
$g.FillRectangle((New-Object Drawing.SolidBrush (C 'e9d6c2')), 0, 600, $W, $H)
for ($row = 0; $row -lt 7; $row++) { $yy = 600 + $row * 75; for ($i = 0; $i -lt 9; $i++) { Cloud $g $r ($r.Next(-100, 2020)) ($yy + $r.Next(-20, 30)) (300 + $row * 90) 'fff6ea' 'b9a6b8' 170 } }
Haze $g 600 50 'ffe2b8' 160
Save-Scene $s 'flight_above_clouds.jpg'

# F2 ocean islands from altitude (curved horizon)
$s = New-Scene; $g = $s.G; $r = New-Object Random 81
Sky $g @('0d2c66', '2f69b3', '9cc9ec', 'cfe6f7') @(0, 0.3, 0.33, 1) 0 $H
$path = New-Object Drawing.Drawing2D.GraphicsPath; $path.AddEllipse(-1400, 330, $W + 2800, 4000)
$g.FillPath((New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.Point]::new(0, 330)), ([Drawing.Point]::new(0, $H)), (C '6aa9d6'), (C '0b3d78')), $path)
for ($i = 0; $i -lt 14; $i++) {
  $ix = $r.Next(0, $W); $iy = $r.Next(430, 1040); $sc = 0.25 + ($iy - 380) / 700.0; $iw = $r.Next(80, 260) * $sc; $ih = $iw * 0.42
  Glow $g $ix $iy ($iw * 0.75) '7fe0e0' 120; $g.FillEllipse((New-Object Drawing.SolidBrush (C 'e9d9a6')), $ix - $iw / 2, $iy - $ih / 2, $iw, $ih)
  $g.FillEllipse((New-Object Drawing.SolidBrush (C '2f7a3c')), $ix - $iw * 0.42, $iy - $ih * 0.4, $iw * 0.84, $ih * 0.8)
}
for ($i = 0; $i -lt 18; $i++) { Cloud $g $r ($r.Next(0, $W)) ($r.Next(420, 1000)) ($r.Next(90, 220)) 'ffffff' 'c7d9ea' 110 }
Haze $g 345 40 'dff0ff' 200
Save-Scene $s 'flight_ocean_islands.jpg'

# F3 aurora night over a lit valley
$s = New-Scene; $g = $s.G; $r = New-Object Random 91; $hy = 760
Sky $g @('02030a', '07112a', '0f2a3c') @(0, 0.6, 1) 0 $hy
Stars $g 92 420 700
foreach ($band in @(@('39ff9e', 260, 0), @('7a5cff', 330, 90), @('2ee6ff', 210, 180))) {
  for ($x = 0; $x -lt $W; $x += 6) {
    $yy = $band[1] + 90 * [Math]::Sin(($x + $band[2]) / 260.0) + 40 * [Math]::Sin(($x + $band[2]) / 97.0)
    $len = 120 + 80 * [Math]::Sin($x / 140.0)
    $br = New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.Point]::new(0, [int]($yy - $len))), ([Drawing.Point]::new(0, [int]($yy + 40))), (C $band[0] 0), (C $band[0] 0)
    $cb = New-Object Drawing.Drawing2D.ColorBlend 3; $cb.Colors = @((C $band[0] 0), (C $band[0] 70), (C $band[0] 0)); $cb.Positions = [float[]]@(0, 0.8, 1); $br.InterpolationColors = $cb
    $g.FillRectangle($br, $x, $yy - $len, 7, $len + 40)
  }
}
Fill-Ridge $g (Ridge 93 ($hy + 10) 160 0.55 7) '050811'
for ($i = 0; $i -lt 900; $i++) { $cx = 960 + ($r.NextDouble() - 0.5) * 1400 * [Math]::Sqrt($r.NextDouble()); $cy = $hy + 60 + [Math]::Pow($r.NextDouble(), 1.6) * 300; $g.FillEllipse((New-Object Drawing.SolidBrush (C ($(if ($r.NextDouble() -lt 0.85) { 'ffcf7a' } else { 'bfe4ff' })) ($r.Next(80, 220)))), $cx, $cy, 2.4, 2.4) }
Glow $g 960 ($hy + 160) 600 'ff9a40' 40
Save-Scene $s 'flight_aurora_night.jpg'

# F4 storm front with lightning
$s = New-Scene; $g = $s.G; $r = New-Object Random 101
Sky $g @('1a1f2a', '2e3644', '55606f', '8a96a3') @(0, 0.45, 0.8, 1) 0 $H
for ($row = 0; $row -lt 6; $row++) { for ($i = 0; $i -lt 10; $i++) { Cloud $g $r ($r.Next(-100, 2020)) (80 + $row * 70 + $r.Next(-20, 20)) (380 + $row * 40) '6f7886' '1c222c' 190 } }
Glow $g 1340 760 520 'ffe0a0' 90
$x = 1180.0; $y = 330.0; $bolt = New-Object 'System.Collections.Generic.List[Drawing.PointF]'; $bolt.Add([Drawing.PointF]::new($x, $y))
while ($y -lt 980) { $x += ($r.NextDouble() - 0.45) * 70; $y += 30 + $r.NextDouble() * 50; $bolt.Add([Drawing.PointF]::new([float]$x, [float]$y)) }
Glow $g 1180 620 300 'c9d8ff' 120
$g.DrawLines((New-Object Drawing.Pen (C 'a9c2ff' 120), 14), $bolt.ToArray()); $g.DrawLines((New-Object Drawing.Pen (C 'ffffff'), 4), $bolt.ToArray())
for ($i = 0; $i -lt 700; $i++) { $rx = $r.Next(0, $W); $ry = $r.Next(380, $H); $g.DrawLine((New-Object Drawing.Pen (C 'c9d3df' ($r.Next(30, 90))), 1.4), $rx, $ry, $rx - 8, $ry + 34) }
Fill-Ridge $g (Ridge 102 1010 70 0.6 6) '12161d'
Save-Scene $s 'flight_storm_front.jpg'

# F5 mountain ranges from the air at dusk (atmospheric perspective)
$s = New-Scene; $g = $s.G
Sky $g @('1f1446', '5a2f7d', 'd8607a', 'ffb36b') @(0, 0.4, 0.8, 1) 0 520
Glow $g 1500 470 460 'ffb070' 150; Disc $g 1500 470 64 'ffe2b0'
$cols = @('c9849a', 'a06a92', '7a5487', '563f78', '3a2c63', '241c48', '140f2c')
for ($i = 0; $i -lt $cols.Count; $i++) { Fill-Ridge $g (Ridge (110 + $i) (470 + $i * 95) (120 + $i * 25) 0.55 7) $cols[$i]; Haze $g (470 + $i * 95) 22 'ffc8a8' ([int](70 - $i * 8)) }
Save-Scene $s 'flight_mountain_dusk.jpg'

# F6 edge of space
$s = New-Scene; $g = $s.G; $r = New-Object Random 121
$g.Clear((C '01020a')); Stars $g 122 600 820
$path = New-Object Drawing.Drawing2D.GraphicsPath; $path.AddEllipse(-1600, 720, $W + 3200, 3600)
Glow $g 960 760 1400 '3aa0ff' 70
$g.FillPath((New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.Point]::new(0, 720)), ([Drawing.Point]::new(0, $H)), (C '2a6fc0'), (C '0a2a5a')), $path)
$g.SetClip($path); for ($i = 0; $i -lt 60; $i++) { Cloud $g $r ($r.Next(0, $W)) ($r.Next(760, 1080)) ($r.Next(120, 360)) 'ffffff' 'b8cbe0' 90 }; $g.ResetClip()
$g.DrawEllipse((New-Object Drawing.Pen (C '8fd0ff' 230), 6), -1600, 720, $W + 3200, 3600)
$g.DrawEllipse((New-Object Drawing.Pen (C '3aa0ff' 90), 26), -1612, 708, $W + 3224, 3624)
Glow $g 1700 640 140 'ffffff' 180
Save-Scene $s 'flight_edge_of_space.jpg'

# ===================================================================== ARCADE
# A1 neon arcade hall interior
$s = New-Scene; $g = $s.G; $r = New-Object Random 201; $hy = 440
Sky $g @('06030f', '0d0820', '1a0e30') @(0, 0.3, 1) 0 $hy
# neon tube lights on ceiling
foreach ($ty in 60, 160, 290) { $g.DrawLine((New-Object Drawing.Pen (C '7b5cff' 100), 3), 0, $ty, $W, $ty); Glow $g 960 $ty 900 '7b5cff' 20 }
$g.FillRectangle((New-Object Drawing.SolidBrush (C '0a0612')), 0, $hy, $W, $H - $hy)
# row of cabinet silhouettes with glowing screens
for ($x = -40; $x -lt $W; $x += $r.Next(80, 150)) {
  $bw = $r.Next(60, 100); $bh = $r.Next(260, 400)
  $g.FillRectangle((New-Object Drawing.SolidBrush (C '0d0a18')), $x, $hy - $bh + 60, $bw, $bh)
  $sw = $bw - 20; $sh = $r.Next(70, 130); $sy = $hy - $bh + 90
  $scol = @('7b5cff', '2ec8ff', 'ff2fa0', '39ff9e', 'ffe259')[$r.Next(0, 5)]
  $g.FillRectangle((New-Object Drawing.SolidBrush (C $scol ($r.Next(80, 180)))), $x + 10, $sy, $sw, $sh)
  Glow $g ($x + $bw / 2) ($sy + $sh / 2) ($bw * 1.2) $scol 50
}
# floor reflections
for ($fx = 0; $fx -lt $W; $fx += $r.Next(100, 220)) { Glow $g ($fx + 50) 700 200 (@('7b5cff', '2ec8ff', 'ff2fa0')[$r.Next(0, 3)]) 30 }
Haze $g $hy 50 '7b5cff' 70
Save-Scene $s 'arcade_neon_hall.jpg'

# A2 pixel city at night
$s = New-Scene; $g = $s.G; $r = New-Object Random 211; $hy = 580
Sky $g @('020210', '0a0830', '1a1050', '2a1660') @(0, 0.4, 0.8, 1) 0 $hy
Stars $g 212 300 480; Disc $g 1600 200 50 'e8e0f0'; Glow $g 1600 200 180 'b89aff' 50
for ($x = -20; $x -lt $W; $x += $r.Next(30, 100)) {
  $bw = $r.Next(40, 130); $bh = $r.Next(80, 480); $by = $hy - $bh
  $g.FillRectangle((New-Object Drawing.SolidBrush (C (@('0d0a1a', '100e22', '0a0816')[$r.Next(0, 3)]))), $x, $by, $bw, $bh + 2)
  for ($wy = $by + 12; $wy -lt $hy - 8; $wy += 16) { for ($wx = $x + 6; $wx -lt $x + $bw - 6; $wx += 12) {
    if ($r.NextDouble() -lt 0.35) { $g.FillRectangle((New-Object Drawing.SolidBrush (C (@('7b5cff', '2ec8ff', 'ff2fa0', 'ffe259', '39ff9e')[$r.Next(0, 5)]) ($r.Next(80, 200)))), $wx, $wy, 5, 7) }
  } }
  if ($r.NextDouble() -lt 0.12) { Glow $g ($x + $bw / 2) $by 50 (@('ff2fa0', '7b5cff', '2ec8ff')[$r.Next(0, 3)]) 200 }
}
Sky $g @('0a0816', '060310') @(0, 1) $hy $H; Haze $g $hy 30 '7b5cff' 100
Save-Scene $s 'arcade_pixel_city.jpg'

# A3 retro grid with joystick silhouette
$s = New-Scene; $g = $s.G; $hy = 500
Sky $g @('02010a', '0d0620', '2a1050', '5a2080') @(0, 0.4, 0.8, 1) 0 $hy; Stars $g 220 180 380
# large joystick silhouette (centred in the sky)
$g.FillRectangle((New-Object Drawing.SolidBrush (C '1a0e30' 180)), 920, 180, 80, 260)        # shaft
Glow $g 960 180 200 '7b5cff' 100
$g.FillEllipse((New-Object Drawing.SolidBrush (C '2a1050' 180)), 880, 100, 160, 160)         # ball-top
$g.FillRectangle((New-Object Drawing.SolidBrush (C '1a0e30' 180)), 760, 420, 400, 80)        # base
# grid floor
$g.FillRectangle((New-Object Drawing.SolidBrush (C '0a0612')), 0, $hy, $W, $H - $hy)
$g.DrawLine((New-Object Drawing.Pen (C 'ff2fa0' 200), 4), 0, $hy, $W, $hy)
for ($X = -40; $X -le 40; $X++) { $g.DrawLine((New-Object Drawing.Pen (C '7b5cff' 50), 2), [float]960, [float]$hy, [float](960 + $X * 1040), [float]($H * 4)) }
for ($k = 1; $k -lt 60; $k++) { $y = [int]($hy + 580.0 / $k); if ($y -gt $H -or $y -lt $hy) { continue }; $a = [int][Math]::Min(200, 50 + 500 / ($k + 1)); $g.DrawLine((New-Object Drawing.Pen (C '2ec8ff' ([int]($a * 0.4))), ([float][Math]::Max(1, 4 / [Math]::Sqrt($k)))), 0, $y, $W, $y) }
Glow $g 960 $hy 600 'ff2fa0' 60
Save-Scene $s 'arcade_retro_grid.jpg'

# A4 coin-op marquee wall
$s = New-Scene; $g = $s.G; $r = New-Object Random 231; $g.Clear((C '08060e'))
for ($by = 0; $by -lt $H; $by += 32) { $ox = if (($by / 32) % 2 -eq 0) { 0 } else { 40 }
  for ($bx = $ox - 80; $bx -lt $W; $bx += 80) { $sh = $r.Next(8, 18); $g.FillRectangle((New-Object Drawing.SolidBrush (C ("{0:X2}{1:X2}{2:X2}" -f $sh, [int]($sh * 0.8), [int]($sh * 1.2)))), $bx + 1, $by + 1, 78, 30) }
}
$mW = 280; $mH = 90; $cols = 6; $rows = 7; $xOff = ($W - $cols * ($mW + 20)) / 2; $yOff = ($H - $rows * ($mH + 30)) / 2
$mCols = @('7b5cff', 'ff2fa0', '2ec8ff', 'ffe259', '39ff9e', 'ff6b4a')
for ($row = 0; $row -lt $rows; $row++) { for ($col = 0; $col -lt $cols; $col++) {
  $mx = [int]($xOff + $col * ($mW + 20)); $my = [int]($yOff + $row * ($mH + 30))
  $c1 = $mCols[$r.Next(0, 6)]; $c2 = $mCols[$r.Next(0, 6)]
  $mbr = New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.Point]::new($mx, $my)), ([Drawing.Point]::new($mx + $mW, $my + $mH)), (C $c1 ($r.Next(140, 220))), (C $c2 ($r.Next(140, 220)))
  $g.FillRectangle($mbr, $mx, $my, $mW, $mH)
  $g.DrawRectangle((New-Object Drawing.Pen (C (@('ffffff', $c1)[$r.Next(0, 2)]) 200), 3), $mx, $my, $mW, $mH)
  Glow $g ($mx + $mW / 2) ($my + $mH + 20) ($mW * 0.6) $c1 40
} }
Save-Scene $s 'arcade_marquee_wall.jpg'

# A5 space-shooter starfield
$s = New-Scene; $g = $s.G; $r = New-Object Random 241; $g.Clear((C '010108'))
Stars $g 242 800 $H
foreach ($nb in @(@(400, 300, 500, '7b5cff', 40), @(1400, 700, 600, '2ec8ff', 35), @(1000, 500, 450, 'ff2fa0', 25), @(600, 800, 350, '39ff9e', 20))) { Glow $g $nb[0] $nb[1] $nb[2] $nb[3] $nb[4] }
for ($i = 0; $i -lt 50; $i++) { $sx = $r.Next(0, $W); $sy = $r.Next(0, $H); $len = $r.Next(20, 140); $g.DrawLine((New-Object Drawing.Pen (C 'ffffff' ($r.Next(50, 190))), ($r.NextDouble() * 1.6 + 0.4)), $sx, $sy, $sx + $len, $sy) }
for ($i = 0; $i -lt 14; $i++) {
  $ax = $r.Next(50, $W - 50); $ay = $r.Next(50, $H - 50); $ar = $r.Next(12, 42)
  $pts = New-Object 'System.Collections.Generic.List[Drawing.PointF]'
  for ($d = 0; $d -lt 360; $d += 36) { $rr = $ar * (0.6 + $r.NextDouble() * 0.8); $pts.Add([Drawing.PointF]::new([float]($ax + $rr * [Math]::Cos($d * [Math]::PI / 180)), [float]($ay + $rr * [Math]::Sin($d * [Math]::PI / 180)))) }
  $g.FillPolygon((New-Object Drawing.SolidBrush (C '2a2a3a' ($r.Next(100, 200)))), $pts.ToArray()); $g.DrawPolygon((New-Object Drawing.Pen (C '4a4a5a' ($r.Next(80, 160))), 1.5), $pts.ToArray())
}
Save-Scene $s 'arcade_starfield.jpg'
