<#
.SYNOPSIS
  Generates the original UI art for the ArcadeMaster RetroFE layout (racing / flight / lightgun).
  Pure System.Drawing - no external tools, all output is original and safe to commit.
.NOTES
  Rotating parts (wheel, needles, horizon, yoke) are drawn centred on a square canvas so a RetroFE
  `angle` animation rotates them about their own centre.
#>
param([string]$OutDir = (Join-Path $PSScriptRoot '..\layouts\ArcadeMaster\images'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path

function New-Canvas([int]$w, [int]$h) {
  $bmp = New-Object Drawing.Bitmap $w, $h, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'
  $g.PixelOffsetMode = 'HighQuality'; $g.TextRenderingHint = 'AntiAliasGridFit'
  $g.Clear([Drawing.Color]::Transparent)
  return @{ Bmp = $bmp; G = $g }
}
function Save-Canvas($c, [string]$name) {
  $c.G.Dispose(); $p = Join-Path $OutDir $name
  $c.Bmp.Save($p, [Drawing.Imaging.ImageFormat]::Png); $c.Bmp.Dispose()
  Write-Host ("{0,-28} {1,8:N0} bytes" -f $name, (Get-Item $p).Length)
}
function C([string]$hex, [int]$a = 255) { $c = [Drawing.ColorTranslator]::FromHtml("#$hex"); [Drawing.Color]::FromArgb($a, $c) }
function Pen([string]$hex, [float]$w, [int]$a = 255) { $p = New-Object Drawing.Pen (C $hex $a), $w; $p.StartCap = 'Round'; $p.EndCap = 'Round'; $p.LineJoin = 'Round'; $p }
function Brush([string]$hex, [int]$a = 255) { New-Object Drawing.SolidBrush (C $hex $a) }
function RadialBrush([Drawing.RectangleF]$r, [string]$centerHex, [string]$edgeHex, [int]$ca = 255, [int]$ea = 255) {
  $path = New-Object Drawing.Drawing2D.GraphicsPath; $path.AddEllipse($r)
  $b = New-Object Drawing.Drawing2D.PathGradientBrush $path
  $b.CenterColor = C $centerHex $ca; $b.SurroundColors = @(C $edgeHex $ea); $b
}
function RoundRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
  $p = New-Object Drawing.Drawing2D.GraphicsPath; $d = 2 * $r
  $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90); $p.CloseFigure(); $p
}
function Font([float]$px, [string]$style = 'Bold') { New-Object Drawing.Font 'Segoe UI', $px, ([Drawing.FontStyle]$style), ([Drawing.GraphicsUnit]::Pixel) }
function Text-Center($g, [string]$s, $font, $brush, [float]$x, [float]$y) {
  $sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
  $g.DrawString($s, $font, $brush, $x, $y, $sf)
}
function Polar([float]$cx, [float]$cy, [float]$r, [float]$deg) {
  # deg: 0 = up, clockwise positive (matches RetroFE angle animation)
  $rad = ($deg - 90) * [Math]::PI / 180
  New-Object Drawing.PointF ($cx + $r * [Math]::Cos($rad)), ($cy + $r * [Math]::Sin($rad))
}

# ======================================================= RACING
# --- steering wheel (3-spoke, flat-bottom GT style), 640px
$c = New-Canvas 640 640; $g = $c.G; $cx = 320; $cy = 320
$g.FillEllipse((RadialBrush ([Drawing.RectangleF]::new(10, 10, 620, 620)) '000000' '000000' 90 0), 10, 14, 620, 620)   # soft drop shadow
$rimOuter = 300; $rimW = 46
$rim = New-Object Drawing.Drawing2D.GraphicsPath
$rim.AddEllipse($cx - $rimOuter, $cy - $rimOuter, 2 * $rimOuter, 2 * $rimOuter)
$rim.AddEllipse($cx - $rimOuter + $rimW, $cy - $rimOuter + $rimW, 2 * ($rimOuter - $rimW), 2 * ($rimOuter - $rimW))
$flat = New-Object Drawing.Region $rim; $flat.Exclude([Drawing.RectangleF]::new(0, 585, 640, 60))
$lg = New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.Point]::new(0, 20)), ([Drawing.Point]::new(0, 620)), (C '3a3d44'), (C '121317')
$g.FillRegion($lg, $flat)
$g.FillRectangle((Brush '1b1d22'), 150, 560, 340, 26)                                    # flat bottom bar
for ($a = -60; $a -le 60; $a += 6) {                                                     # grip stitching, both sides
  foreach ($side in -1, 1) { $p1 = Polar $cx $cy ($rimOuter - 6) (90 * $side + $a); $p2 = Polar $cx $cy ($rimOuter - $rimW + 6) (90 * $side + $a); $g.DrawLine((Pen '5b606b' 2 160), $p1, $p2) }
}
$g.DrawArc((Pen 'ff2fa0' 14), $cx - $rimOuter + 7, $cy - $rimOuter + 7, 2 * $rimOuter - 14, 2 * $rimOuter - 14, 265, 10)   # top-centre marker
$g.DrawArc((Pen '6c7380' 3 140), $cx - $rimOuter + 3, $cy - $rimOuter + 3, 2 * $rimOuter - 6, 2 * $rimOuter - 6, 200, 140) # rim highlight
$g.DrawArc((Pen 'ff2fa0' 10 60), $cx - $rimOuter, $cy - $rimOuter, 2 * $rimOuter, 2 * $rimOuter, 100, 340)                  # neon edge glow
$g.DrawArc((Pen 'ff4fd0' 3 230), $cx - $rimOuter + 1, $cy - $rimOuter + 1, 2 * $rimOuter - 2, 2 * $rimOuter - 2, 100, 340)
$ir = $rimOuter - $rimW; $g.DrawArc((Pen '2ec8ff' 3 200), $cx - $ir, $cy - $ir, 2 * $ir, 2 * $ir, 0, 360)
foreach ($deg in 90, 270, 180) {                                                         # spokes: left, right, bottom
  $w = if ($deg -eq 180) { 70 } else { 58 }
  $p1 = Polar $cx $cy 70 $deg; $p2 = Polar $cx $cy ($rimOuter - $rimW + 8) $deg
  $g.DrawLine((Pen '24272e' $w), $p1, $p2); $g.DrawLine((Pen '3b3f48' ($w - 18)), $p1, $p2)
}
$hub = [Drawing.RectangleF]::new($cx - 92, $cy - 92, 184, 184)
$g.FillEllipse((RadialBrush $hub '3f444e' '15171b'), $hub); $g.DrawEllipse((Pen '6c7380' 4), $hub)
$g.FillEllipse((Brush 'ff2fa0'), $cx - 46, $cy - 46, 92, 92)
Text-Center $g 'AM' (Font 40 'Bold') (Brush 'ffffff') $cx ($cy + 2)
foreach ($deg in 60, 120, 240, 300) { $p = Polar $cx $cy 66 $deg; $g.FillEllipse((Brush '8d95a3'), $p.X - 9, $p.Y - 9, 18, 18) }   # wheel buttons
Save-Canvas $c 'racing_wheel.png'

# --- gauge faces + needle (needle points UP at angle 0; zero position = -135, max = +135)
function New-Gauge([string]$name, [string]$label, [int]$max, [int]$step, [int]$red, [string]$unit) {
  $c = New-Canvas 512 512; $g = $c.G; $cx = 256; $cy = 256
  $g.FillEllipse((RadialBrush ([Drawing.RectangleF]::new(6, 6, 500, 500)) '1d2028' '07080a'), 6, 6, 500, 500)
  $g.DrawEllipse((Pen '4b5260' 10), 11, 11, 490, 490); $g.DrawEllipse((Pen '9aa3b2' 2 120), 18, 18, 476, 476)
  $span = 270.0; $start = -135.0
  $redStart = $start + $span * $red / $max
  $g.DrawArc((Pen 'ff2fa0' 18 220), 46, 46, 420, 420, [float]($redStart - 90), [float]($start + $span - $redStart))
  for ($v = 0; $v -le $max; $v += $step / 2) {
    $deg = $start + $span * $v / $max; $major = ($v % $step) -eq 0
    $p1 = Polar $cx $cy 222 $deg; $p2 = Polar $cx $cy ($(if ($major) { 186 } else { 204 })) $deg
    $col = if ($v -ge $red) { 'ff6b6b' } else { 'e8ecf2' }
    $g.DrawLine((Pen $col ($(if ($major) { 6 } else { 3 }))), $p1, $p2)
    if ($major) { $pt = Polar $cx $cy 152 $deg; Text-Center $g ([string]$v) (Font 34 'Bold') (Brush $col) $pt.X $pt.Y }
  }
  Text-Center $g $label (Font 30 'Bold') (Brush '8d95a3') $cx ($cy + 92)
  Text-Center $g $unit (Font 22 'Regular') (Brush '6c7380') $cx ($cy + 126)
  Save-Canvas $c $name
}
New-Gauge 'racing_speedo_face.png' 'SPEED' 320 40 260 'km/h'
New-Gauge 'racing_tacho_face.png'  'RPM'   9   1  7   'x1000'
$c = New-Canvas 512 512; $g = $c.G
$needle = New-Object Drawing.Drawing2D.GraphicsPath
$needle.AddPolygon([Drawing.PointF[]]@([Drawing.PointF]::new(256, 46), [Drawing.PointF]::new(265, 256), [Drawing.PointF]::new(256, 300), [Drawing.PointF]::new(247, 256)))
$g.FillPath((Brush '000000' 90), $needle.Clone()); $g.TranslateTransform(-3, 3); $g.FillPath((Brush '000000' 60), $needle); $g.ResetTransform()
$g.FillPath((Brush 'ff3b3b'), $needle); $g.DrawPath((Pen 'ffb3b3' 1.5 180), $needle)
$g.FillEllipse((RadialBrush ([Drawing.RectangleF]::new(226, 226, 60, 60)) '5b606b' '111216'), 226, 226, 60, 60)
Save-Canvas $c 'racing_needle.png'

# --- road dashes (seamless vertical strip: period 180px), speed lines, checkered band
$c = New-Canvas 24 1440; $g = $c.G
for ($y = 0; $y -lt 1440; $y += 180) { $g.FillRectangle((Brush 'f1f3f7' 230), 0, $y, 24, 100) }
Save-Canvas $c 'racing_road_dash.png'
$c = New-Canvas 1920 1080; $g = $c.G; $rnd = New-Object Random 7
for ($i = 0; $i -lt 140; $i++) {
  $deg = $rnd.Next(0, 360); $r1 = $rnd.Next(380, 700); $r2 = $r1 + $rnd.Next(160, 520)
  $p1 = Polar 960 540 $r1 $deg; $p2 = Polar 960 540 $r2 $deg
  $g.DrawLine((Pen 'ffffff' ($rnd.Next(1, 4)) ($rnd.Next(40, 140))), $p1, $p2)
}
Save-Canvas $c 'racing_speedlines.png'
$c = New-Canvas 1920 48; $g = $c.G
for ($x = 0; $x -lt 1920; $x += 24) { for ($row = 0; $row -lt 2; $row++) { if ((($x / 24) + $row) % 2 -eq 0) { $g.FillRectangle((Brush 'ffffff' 235), $x, $row * 24, 24, 24) } else { $g.FillRectangle((Brush '111111' 235), $x, $row * 24, 24, 24) } } }
Save-Canvas $c 'racing_checker.png'

# ======================================================= FLIGHT
# --- attitude indicator: horizon disk (rolls + pitches) behind a plate with a round window
$c = New-Canvas 700 700; $g = $c.G; $cx = 350; $cy = 350
$clip = New-Object Drawing.Drawing2D.GraphicsPath; $clip.AddEllipse(0, 0, 700, 700); $g.SetClip($clip)
$g.FillRectangle((New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.Point]::new(0, 0)), ([Drawing.Point]::new(0, 352)), (C '0b3d91'), (C '4fa3e0')), 0, 0, 700, 352)
$g.FillRectangle((New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.Point]::new(0, 348)), ([Drawing.Point]::new(0, 700)), (C '8a5a2b'), (C '3d2410')), 0, 350, 700, 350)
$g.DrawLine((Pen 'ffffff' 5), 0, 350, 700, 350)
foreach ($pitch in -30, -20, -10, 10, 20, 30) {                                          # pitch ladder: 4px per degree
  $y = 350 - $pitch * 4; $half = if ([Math]::Abs($pitch) % 20 -eq 0) { 90 } else { 55 }
  $g.DrawLine((Pen 'ffffff' 4), ($cx - $half), $y, ($cx + $half), $y)
  Text-Center $g ([string][Math]::Abs($pitch)) (Font 24 'Bold') (Brush 'ffffff') ($cx - $half - 28) $y
  Text-Center $g ([string][Math]::Abs($pitch)) (Font 24 'Bold') (Brush 'ffffff') ($cx + $half + 28) $y
}
for ($y = 350 - 50 * 4 + 20; $y -le 350 + 50 * 4; $y += 20) { if ((350 - $y) % 40 -ne 0) { $g.DrawLine((Pen 'ffffff' 2 160), $cx - 22, $y, $cx + 22, $y) } }
Save-Canvas $c 'flight_horizon.png'

$c = New-Canvas 760 760; $g = $c.G; $cx = 380; $cy = 380; $win = 232
$plate = New-Object Drawing.Drawing2D.GraphicsPath; $plate.AddPath((RoundRect 0 0 760 760 70), $false); $plate.AddEllipse($cx - $win, $cy - $win, 2 * $win, 2 * $win)
$g.FillPath((New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.Point]::new(0, 0)), ([Drawing.Point]::new(0, 760)), (C '2b2f37'), (C '0e1013')), $plate)
$g.DrawEllipse((Pen '5b606b' 14), $cx - $win - 6, $cy - $win - 6, 2 * $win + 12, 2 * $win + 12)
$g.DrawEllipse((Pen '9aa3b2' 2 140), $cx - $win - 14, $cy - $win - 14, 2 * $win + 28, 2 * $win + 28)
foreach ($deg in -60, -45, -30, -20, -10, 0, 10, 20, 30, 45, 60) {                       # bank scale on the plate
  $len = if ($deg % 30 -eq 0) { 30 } else { 16 }
  $g.DrawLine((Pen 'e8ecf2' 4), (Polar $cx $cy ($win + 18) $deg), (Polar $cx $cy ($win + 18 + $len) $deg))
}
$tri = Polar $cx $cy ($win + 4) 0
$g.FillPolygon((Brush 'ffb000'), [Drawing.PointF[]]@($tri, [Drawing.PointF]::new($tri.X - 14, $tri.Y + 24), [Drawing.PointF]::new($tri.X + 14, $tri.Y + 24)))
$g.DrawLine((Pen 'ffb000' 9), $cx - 150, $cy, $cx - 60, $cy); $g.DrawLine((Pen 'ffb000' 9), $cx - 60, $cy, $cx - 40, $cy + 22)   # fixed aircraft symbol
$g.DrawLine((Pen 'ffb000' 9), $cx + 150, $cy, $cx + 60, $cy); $g.DrawLine((Pen 'ffb000' 9), $cx + 60, $cy, $cx + 40, $cy + 22)
$g.FillEllipse((Brush 'ffb000'), $cx - 9, $cy - 9, 18, 18)
Text-Center $g 'ATTITUDE' (Font 26 'Bold') (Brush '8d95a3') $cx 706
Save-Canvas $c 'flight_attitude_plate.png'

# --- control yoke (square canvas so it rotates about its column)
$c = New-Canvas 640 640; $g = $c.G; $cx = 320; $cy = 320
$y = New-Object Drawing.Drawing2D.GraphicsPath
$y.AddPolygon([Drawing.PointF[]]@(
  [Drawing.PointF]::new(70, 230), [Drawing.PointF]::new(130, 230), [Drawing.PointF]::new(170, 300), [Drawing.PointF]::new(470, 300),
  [Drawing.PointF]::new(510, 230), [Drawing.PointF]::new(570, 230), [Drawing.PointF]::new(590, 270), [Drawing.PointF]::new(560, 420),
  [Drawing.PointF]::new(505, 420), [Drawing.PointF]::new(480, 365), [Drawing.PointF]::new(160, 365), [Drawing.PointF]::new(135, 420),
  [Drawing.PointF]::new(80, 420), [Drawing.PointF]::new(50, 270)))
$g.TranslateTransform(0, 10); $g.FillPath((Brush '000000' 80), $y); $g.ResetTransform()
$g.FillPath((New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.Point]::new(0, 230)), ([Drawing.Point]::new(0, 420)), (C '3f444e'), (C '15171b')), $y)
$g.DrawPath((Pen '6c7380' 3), $y)
$g.FillRectangle((Brush '24272e'), 290, 365, 60, 200)                                    # column
foreach ($p in @(@(92, 260), @(520, 260))) { $g.FillEllipse((Brush 'ff2fa0'), $p[0], $p[1], 26, 26); $g.FillEllipse((Brush 'ffb000'), $p[0] + 2, $p[1] + 44, 22, 22) }
$g.FillEllipse((Brush '111216'), 280, 300, 80, 80); Text-Center $g 'AM' (Font 30 'Bold') (Brush 'e8ecf2') 320 341
Save-Canvas $c 'flight_yoke.png'

# --- HUD reticle, drifting cloud band, compass tape (seamless: period 360px)
$c = New-Canvas 400 400; $g = $c.G; $hp = Pen '2ec8ff' 4 230
$g.DrawEllipse($hp, 140, 140, 120, 120); $g.FillEllipse((Brush '2ec8ff' 230), 194, 194, 12, 12)
foreach ($d in 0, 90, 180, 270) { $g.DrawLine($hp, (Polar 200 200 70 $d), (Polar 200 200 130 $d)) }
$g.DrawArc($hp, 40, 40, 320, 320, 200, 50); $g.DrawArc($hp, 40, 40, 320, 320, 290, 50)
Save-Canvas $c 'flight_hud_reticle.png'
$c = New-Canvas 3840 420; $g = $c.G; $rnd = New-Object Random 11
for ($i = 0; $i -lt 90; $i++) {
  $x = $rnd.Next(0, 1920); $yy = $rnd.Next(60, 300); $w = $rnd.Next(160, 420); $h = [int]($w * 0.42)
  foreach ($off in 0, 1920) { $g.FillEllipse((RadialBrush ([Drawing.RectangleF]::new($x + $off, $yy, $w, $h)) 'ffffff' 'ffffff' ($rnd.Next(40, 90)) 0), $x + $off, $yy, $w, $h) }
}
Save-Canvas $c 'flight_clouds.png'
$c = New-Canvas 1440 90; $g = $c.G
$g.FillRectangle((Brush '0e1013' 200), 0, 0, 1440, 90)
for ($deg = 0; $deg -lt 720; $deg += 5) {
  $x = $deg * 2; $major = $deg % 30 -eq 0
  $g.DrawLine((Pen '2ec8ff' ($(if ($major) { 3 } else { 2 })) 220), $x, 0, $x, $(if ($major) { 30 } else { 16 }))
  if ($major) { $lbl = switch ($deg % 360) { 0 { 'N' } 90 { 'E' } 180 { 'S' } 270 { 'W' } default { [string](($deg % 360) / 10) } }; Text-Center $g $lbl (Font 26 'Bold') (Brush '2ec8ff') $x 58 }
}
Save-Canvas $c 'flight_compass_tape.png'

# ======================================================= LIGHTGUN
$c = New-Canvas 400 400; $g = $c.G
$g.DrawEllipse((Pen 'ff3b3b' 8), 70, 70, 260, 260); $g.DrawEllipse((Pen 'ff3b3b' 3 180), 130, 130, 140, 140)
foreach ($d in 0, 90, 180, 270) { $g.DrawLine((Pen 'ffffff' 6), (Polar 200 200 40 $d), (Polar 200 200 160 $d)) }
$g.FillEllipse((Brush 'ff3b3b'), 192, 192, 16, 16)
Save-Canvas $c 'gun_crosshair.png'
$c = New-Canvas 400 400; $g = $c.G
$ring = 0; foreach ($r in 190, 150, 110, 70, 32) { $g.FillEllipse((Brush $(if ($ring % 2 -eq 0) { 'f1f3f7' } else { 'ff2fa0' }) 235), 200 - $r, 200 - $r, 2 * $r, 2 * $r); $ring++ }
Save-Canvas $c 'gun_target.png'
$c = New-Canvas 400 400; $g = $c.G                                                       # muzzle flash
$g.FillEllipse((RadialBrush ([Drawing.RectangleF]::new(40, 40, 320, 320)) 'fff3b0' 'ff7b00' 255 0), 40, 40, 320, 320)
$rnd = New-Object Random 3; for ($i = 0; $i -lt 14; $i++) { $d = $rnd.Next(0, 360); $g.DrawLine((Pen 'ffd166' ($rnd.Next(6, 14)) 200), (Polar 200 200 40 $d), (Polar 200 200 ($rnd.Next(130, 195)) $d)) }
Save-Canvas $c 'gun_flash.png'

# ======================================================= SYNTHWAVE BACKDROP (matches the Real Z Studios mark)
$c = New-Canvas 1920 1080; $g = $c.G; $hz = 600
$sky = New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.Point]::new(0, 0)), ([Drawing.Point]::new(0, $hz)), (C '0b0420'), (C 'ff2f7a')
$cb = New-Object Drawing.Drawing2D.ColorBlend 4
$cb.Colors = @((C '05010f'), (C '2a0a5e'), (C '8a1f9c'), (C 'ff6a3d')); $cb.Positions = [float[]]@(0, 0.45, 0.8, 1); $sky.InterpolationColors = $cb
$g.FillRectangle($sky, 0, 0, 1920, $hz)
$rnd = New-Object Random 21
for ($i = 0; $i -lt 220; $i++) { $sx = $rnd.Next(0, 1920); $sy = $rnd.Next(0, 380); $s = $rnd.NextDouble() * 2.6 + 0.6; $g.FillEllipse((Brush 'ffffff' ($rnd.Next(60, 230))), $sx, $sy, $s, $s) }
$sunR = 270; $sunCy = $hz - 40
$sunRect = [Drawing.RectangleF]::new(960 - $sunR, $sunCy - $sunR, 2 * $sunR, 2 * $sunR)
$g.FillEllipse((RadialBrush ([Drawing.RectangleF]::new(960 - 520, $sunCy - 520, 1040, 1040)) 'ff4fb0' 'ff4fb0' 120 0), 960 - 520, $sunCy - 520, 1040, 1040)
$sunPath = New-Object Drawing.Drawing2D.GraphicsPath; $sunPath.AddEllipse($sunRect)
$sunReg = New-Object Drawing.Region $sunPath
for ($k = 0; $k -lt 9; $k++) { $gapY = $sunCy - 20 + $k * 30; $sunReg.Exclude([Drawing.RectangleF]::new(0, $gapY, 1920, 4 + $k * 1.6)) }   # retro sun stripes
$sunReg.Intersect([Drawing.RectangleF]::new(0, 0, 1920, $hz))
$g.FillRegion((New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.Point]::new(0, [int]($sunCy - $sunR))), ([Drawing.Point]::new(0, $hz)), (C 'ffe259'), (C 'ff2fa0')), $sunReg)
foreach ($layer in @(@{ Col = '2a0a5e'; A = 255; Base = $hz; Amp = 150; Seed = 5 }, @{ Col = '14052e'; A = 255; Base = $hz; Amp = 90; Seed = 9 })) {   # mountains
  $r2 = New-Object Random $layer.Seed; $pts = New-Object 'System.Collections.Generic.List[Drawing.PointF]'
  $pts.Add([Drawing.PointF]::new(0, $hz)); $x = 0
  while ($x -le 1920) { $pts.Add([Drawing.PointF]::new($x, $layer.Base - $r2.Next(10, $layer.Amp))); $x += $r2.Next(60, 170) }
  $pts.Add([Drawing.PointF]::new(1920, $hz)); $g.FillPolygon((Brush $layer.Col $layer.A), $pts.ToArray())
  $g.DrawLines((Pen '2ec8ff' 2 90), $pts.GetRange(1, $pts.Count - 2).ToArray())
}
$g.FillRectangle((Brush '0b0420'), 0, $hz, 1920, 1080 - $hz)
$g.DrawLine((Pen 'ff2fa0' 4), 0, $hz, 1920, $hz)
Save-Canvas $c 'bg_synthwave.png'

# grid floor animation frames (seamless loop: camera advances exactly one grid cell over $N frames)
$frameDir = Join-Path $OutDir '..\_gridframes'; New-Item -ItemType Directory -Force $frameDir | Out-Null
$N = 45; $W = 1920; $H = 480; $f = 120.0
for ($i = 0; $i -lt $N; $i++) {
  $c = New-Canvas $W $H; $g = $c.G; $g.Clear((C '0b0420')); $off = $i / $N
  for ($X = -40; $X -le 40; $X++) {                                                      # rails converge on the vanishing point
    $ex = [float](960 + $X * 260 * 4)                                                    # line from VP through (960+X*260, H), extended 4x
    $g.DrawLine((Pen 'ff2fa0' 6 40), [float]960, [float]0, $ex, [float]($H * 4)); $g.DrawLine((Pen 'ff4fd0' 2 200), [float]960, [float]0, $ex, [float]($H * 4))
  }
  for ($k = 0; $k -lt 80; $k++) {                                                        # sleepers: y = f / z
    $z = $k + 1 - $off; if ($z -le 0.05) { continue }
    $y = [float]($H / $z); if ($y -gt $H + 10) { continue }; if ($y -lt 2) { break }
    $a = [int][Math]::Min(255, 60 + 900 / ($z + 2))
    $g.DrawLine((Pen '2ec8ff' ([float][Math]::Max(1, 7 / [Math]::Sqrt($z))) ([int]($a * 0.25))), 0, $y, $W, $y)
    $g.DrawLine((Pen '9be7ff' ([float][Math]::Max(1, 2.6 / [Math]::Sqrt($z))) $a), 0, $y, $W, $y)
  }
  $fade = New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.Point]::new(0, 0)), ([Drawing.Point]::new(0, 140)), (C '0b0420' 255), (C '0b0420' 0)
  $g.FillRectangle($fade, 0, 0, $W, 140)                                                 # haze at the horizon
  $c.G.Dispose(); $c.Bmp.Save((Join-Path $frameDir ('f{0:D3}.png' -f $i)), [Drawing.Imaging.ImageFormat]::Png); $c.Bmp.Dispose()
}
Write-Host "grid frames: $N -> $frameDir (encode with tools\Build-GridVideo.ps1)"
$c = New-Canvas 1100 1100; $g = $c.G; $g.FillEllipse((RadialBrush ([Drawing.RectangleF]::new(0, 0, 1100, 1100)) 'ff7ac8' 'ff2fa0' 170 0), 0, 0, 1100, 1100)
Save-Canvas $c 'fx_sun_glow.png'

# ======================================================= COMMON
$c = New-Canvas 1920 1080; $g = $c.G; for ($y = 0; $y -lt 1080; $y += 3) { $g.FillRectangle((Brush '000000' 46), 0, $y, 1920, 1) }
Save-Canvas $c 'fx_scanlines.png'
$c = New-Canvas 1920 1080; $g = $c.G
$path = New-Object Drawing.Drawing2D.GraphicsPath; $path.AddEllipse(-420, -330, 2760, 1740)
$vb = New-Object Drawing.Drawing2D.PathGradientBrush $path; $vb.CenterColor = C '000000' 0; $vb.SurroundColors = @(C '000000' 235)
$blend = New-Object Drawing.Drawing2D.Blend 3; $blend.Factors = [float[]]@(0, 0.15, 1); $blend.Positions = [float[]]@(0, 0.45, 1); $vb.Blend = $blend
$g.FillRectangle($vb, 0, 0, 1920, 1080); Save-Canvas $c 'fx_vignette.png'
$c = New-Canvas 512 512; $g = $c.G; $g.FillEllipse((RadialBrush ([Drawing.RectangleF]::new(0, 0, 512, 512)) 'ffffff' 'ffffff' 150 0), 0, 0, 512, 512)
Save-Canvas $c 'fx_glow.png'
$c = New-Canvas 1300 230; $g = $c.G; $rr = RoundRect 4 4 1292 222 28
$g.FillPath((New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.Point]::new(0, 0)), ([Drawing.Point]::new(0, 230)), (C '1d2028' 215), (C '07080a' 225)), $rr)
$g.DrawPath((Pen '4b5260' 3), $rr); $g.FillRectangle((Brush 'ff2fa0'), 30, 4, 180, 6)
Save-Canvas $c 'ui_info_panel.png'
$c = New-Canvas 560 150; $g = $c.G; $rr = RoundRect 6 6 548 138 30
$g.FillPath((Brush 'ffffff' 24), $rr); $g.DrawPath((Pen 'ffffff' 5 230), $rr)
Save-Canvas $c 'ui_select_frame.png'
$c = New-Canvas 2 2; $c.G.Clear((C '000000')); Save-Canvas $c 'black.png'
$c = New-Canvas 2 2; Save-Canvas $c 'blank.png'                                         # empty theme slot

# --- per-game background support (fanart is the backdrop; these keep the UI readable over any artwork)
$c = New-Canvas 1920 1080; $g = $c.G                                                    # neutral fallback when a game has no fanart
$p = New-Object Drawing.Drawing2D.GraphicsPath; $p.AddEllipse(-500, -400, 2920, 1880)
$nb = New-Object Drawing.Drawing2D.PathGradientBrush $p; $nb.CenterColor = C '1b2230'; $nb.SurroundColors = @(C '05070b')
$g.FillRectangle($nb, 0, 0, 1920, 1080); Save-Canvas $c 'bg_neutral.png'
$c = New-Canvas 1920 1080; $g = $c.G                                                    # game-list scrim: list column + cluster band + title band
$lb = New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.Point]::new(0, 0)), ([Drawing.Point]::new(960, 0)), (C '000000' 215), (C '000000' 0)
$cb = New-Object Drawing.Drawing2D.ColorBlend 3; $cb.Colors = @((C '000000' 215), (C '000000' 170), (C '000000' 0)); $cb.Positions = [float[]]@(0, 0.55, 1); $lb.InterpolationColors = $cb
$g.FillRectangle($lb, 0, 0, 960, 1080)
$bb = New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.Point]::new(0, 660)), ([Drawing.Point]::new(0, 1081)), (C '000000' 0), (C '000000' 230)
$g.FillRectangle($bb, 0, 660, 1920, 420)
$tb = New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.Point]::new(0, 0)), ([Drawing.Point]::new(0, 160)), (C '000000' 150), (C '000000' 0)
$g.FillRectangle($tb, 0, 0, 1920, 160); Save-Canvas $c 'fx_scrim_gamelist.png'
$c = New-Canvas 1920 1080; $g = $c.G                                                    # main-menu scrim: centre band behind the collection logos
$mb = New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.Point]::new(0, 0)), ([Drawing.Point]::new(0, 1081)), (C '000000' 0), (C '000000' 0)
$cb = New-Object Drawing.Drawing2D.ColorBlend 5; $cb.Colors = @((C '000000' 90), (C '000000' 185), (C '000000' 185), (C '000000' 60), (C '000000' 215)); $cb.Positions = [float[]]@(0, 0.22, 0.62, 0.74, 1); $mb.InterpolationColors = $cb
$g.FillRectangle($mb, 0, 0, 1920, 1080); Save-Canvas $c 'fx_scrim_main.png'
# touch button bar for the second (pedestal/marquee) screen: 5 equal cells = touch1Column1..5of5Row3of3
$labels = @(@('BACK', '9aa3b2', 'back'), @('PREV', '2ec8ff', 'left'), @('START', 'ff2fa0', 'play'), @('NEXT', '2ec8ff', 'right'), @('RANDOM', 'ffb000', 'dice'))
$c = New-Canvas 1920 360; $g = $c.G; $cw = 384
for ($i = 0; $i -lt 5; $i++) {
  $x = $i * $cw; $col = $labels[$i][1]; $rr = RoundRect ($x + 18) 22 ($cw - 36) 316 36
  $g.FillPath((New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.Point]::new(0, 22)), ([Drawing.Point]::new(0, 340)), (C '1d2028' 235), (C '07080a' 240)), $rr)
  foreach ($w in 14, 8) { $g.DrawPath((Pen $col $w ([int](40 + (14 - $w) * 14))), $rr) }; $g.DrawPath((Pen 'ffffff' 2 140), $rr)
  $cx = $x + $cw / 2; $cy = 140; $ip = Pen $col 14
  switch ($labels[$i][2]) {
    'back'  { $g.DrawArc($ip, $cx - 50, $cy - 50, 100, 100, 200, 250); $g.FillPolygon((Brush $col), [Drawing.PointF[]]@([Drawing.PointF]::new($cx - 70, $cy - 30), [Drawing.PointF]::new($cx - 30, $cy - 30), [Drawing.PointF]::new($cx - 52, $cy + 6))) }
    'left'  { $g.FillPolygon((Brush $col), [Drawing.PointF[]]@([Drawing.PointF]::new($cx + 45, $cy - 60), [Drawing.PointF]::new($cx + 45, $cy + 60), [Drawing.PointF]::new($cx - 60, $cy))) }
    'right' { $g.FillPolygon((Brush $col), [Drawing.PointF[]]@([Drawing.PointF]::new($cx - 45, $cy - 60), [Drawing.PointF]::new($cx - 45, $cy + 60), [Drawing.PointF]::new($cx + 60, $cy))) }
    'play'  { $g.FillEllipse((Brush $col 60), $cx - 70, $cy - 70, 140, 140); $g.FillPolygon((Brush 'ffffff'), [Drawing.PointF[]]@([Drawing.PointF]::new($cx - 28, $cy - 42), [Drawing.PointF]::new($cx - 28, $cy + 42), [Drawing.PointF]::new($cx + 44, $cy))) }
    'dice'  { $rd = RoundRect ($cx - 52) ($cy - 52) 104 104 18; $g.DrawPath($ip, $rd); foreach ($p in @(@(-24, -24), @(24, 24), @(0, 0), @(24, -24), @(-24, 24))) { $g.FillEllipse((Brush $col), $cx + $p[0] - 9, $cy + $p[1] - 9, 18, 18) } }
  }
  Text-Center $g $labels[$i][0] (Font 52 'Bold') (Brush 'ffffff') $cx 270
}
Save-Canvas $c 'ui_touchbar.png'

# neon 16:9 frame for the video snap (1120x650 outer, 1040x585 window)
$c = New-Canvas 1120 650; $g = $c.G; $rr = RoundRect 20 20 1080 610 26
foreach ($w in 26, 16, 8) { $g.DrawPath((Pen 'ff2fa0' $w ([int](30 + (26 - $w) * 6))), $rr) }
$g.DrawPath((Pen 'ffd0ec' 3 240), $rr); $rr2 = RoundRect 34 34 1052 582 18; $g.DrawPath((Pen '2ec8ff' 2 200), $rr2)
Save-Canvas $c 'ui_video_frame.png'

# neon text logos for main-menu collections -> layouts\ArcadeMaster\collections\Main\medium_artwork\logo\<name>.png
$logoDir = Join-Path $OutDir '..\collections\Main\medium_artwork\logo'; New-Item -ItemType Directory -Force $logoDir | Out-Null
$logos = [ordered]@{ 'Racing' = @('RACING', 'ff2fa0'); 'Flight' = @('FLIGHT', '2ec8ff'); 'Lightgun' = @('LIGHTGUN', 'ff3b3b'); 'Settings' = @('SETTINGS', 'ffb000');
  'GAMES' = @('ALL GAMES', 'ff2fa0'); 'Arcade' = @('ARCADE', '7b5cff'); 'Tools' = @('TOOLS', '9be7ff'); 'EXIT' = @('EXIT', '9aa3b2'); 'Favorites' = @('FAVORITES', 'ffe259') }
foreach ($k in $logos.Keys) {
  $txt = $logos[$k][0]; $col = $logos[$k][1]
  $c = New-Canvas 900 220; $g = $c.G; $font = New-Object Drawing.Font 'Segoe UI Black', 120, ([Drawing.FontStyle]::Italic), ([Drawing.GraphicsUnit]::Pixel)
  $gp = New-Object Drawing.Drawing2D.GraphicsPath; $sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
  $gp.AddString($txt, $font.FontFamily, [int]$font.Style, $font.Size, [Drawing.RectangleF]::new(0, 0, 900, 220), $sf)
  foreach ($w in 22, 14, 8) { $g.DrawPath((Pen $col $w ([int](25 + (22 - $w) * 5))), $gp) }               # outer glow
  $g.FillPath((New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.Point]::new(0, 50)), ([Drawing.Point]::new(0, 170)), (C 'ffffff'), (C $col)), $gp)
  $g.DrawPath((Pen '1a0633' 3 220), $gp)
  $c.G.Dispose(); $c.Bmp.Save((Join-Path $logoDir "$k.png"), [Drawing.Imaging.ImageFormat]::Png); $c.Bmp.Dispose()
}
Write-Host "main-menu logos: $($logos.Count) -> $logoDir"
