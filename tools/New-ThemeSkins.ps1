<#
.SYNOPSIS
  Draws the extra racing and flight styles ("skins") for the ArcadeMaster layout and registers them in themes.json.

  A skin is only a different set of pictures for the slots the layout already has (centre wheel / yoke, two dials and
  their needle, flight horizon + HUD sight, the select flash and the drifting band), at the same sizes as the
  built-in ones. The layout, its layers and animations stay the same, so every skin is exactly as fast as the
  original: RetroFE loads the same number of images of the same size.

  Racing skins keep the cabinet's real wheel in the middle when it has one (New-RealWheelArt); their own wheel is
  only used without one. Pure System.Drawing with Segoe UI, original art, safe to commit.
  Output: layouts\ArcadeMaster\images\skins\<skin>_*.png + <skin>_preview.png, themes.json "themes" + "skins".
.EXAMPLE
  tools\New-ThemeSkins.ps1                 # draw every skin
  tools\New-ThemeSkins.ps1 -Only rally     # one skin
#>
param(
  [string]$LayoutDir = (Join-Path $PSScriptRoot '..\layouts\ArcadeMaster'),
  [string[]]$Only
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$LayoutDir = (Resolve-Path $LayoutDir).Path
$OutDir = Join-Path $LayoutDir 'images\skins'; New-Item -ItemType Directory -Force $OutDir | Out-Null

# ------------------------------------------------------------------ drawing helpers (same conventions as New-LayoutArt)
function New-Canvas([int]$w, [int]$h) {
  $bmp = New-Object Drawing.Bitmap $w, $h, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'; $g.TextRenderingHint = 'AntiAliasGridFit'
  $g.Clear([Drawing.Color]::Transparent)
  @{ Bmp = $bmp; G = $g }
}
function Save-Canvas($c, [string]$name) { $c.G.Dispose(); $p = Join-Path $OutDir $name; $c.Bmp.Save($p, [Drawing.Imaging.ImageFormat]::Png); $c.Bmp.Dispose(); $p }
function C([string]$hex, [int]$a = 255) { $c = [Drawing.ColorTranslator]::FromHtml("#$hex"); [Drawing.Color]::FromArgb($a, $c) }
function Pen([string]$hex, [float]$w, [int]$a = 255) { $p = New-Object Drawing.Pen (C $hex $a), $w; $p.StartCap = 'Round'; $p.EndCap = 'Round'; $p.LineJoin = 'Round'; $p }
function Brush([string]$hex, [int]$a = 255) { New-Object Drawing.SolidBrush (C $hex $a) }
function Radial([float]$x, [float]$y, [float]$w, [float]$h, [string]$ch, [string]$eh, [int]$ca = 255, [int]$ea = 255) {
  $path = New-Object Drawing.Drawing2D.GraphicsPath; $path.AddEllipse($x, $y, $w, $h)
  $b = New-Object Drawing.Drawing2D.PathGradientBrush $path; $b.CenterColor = C $ch $ca; $b.SurroundColors = @(C $eh $ea); $b
}
function Linear([float]$y1, [float]$y2, [string]$h1, [string]$h2) { New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.PointF]::new(0, $y1)), ([Drawing.PointF]::new(0, $y2)), (C $h1), (C $h2) }
function RoundRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
  $p = New-Object Drawing.Drawing2D.GraphicsPath; $d = 2 * $r
  $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90); $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90); $p.CloseFigure(); $p
}
function Font([float]$px, [string]$style = 'Bold') { New-Object Drawing.Font 'Segoe UI', $px, ([Drawing.FontStyle]$style), ([Drawing.GraphicsUnit]::Pixel) }
function Text-Center($g, [string]$s, $font, $brush, [float]$x, [float]$y) { $sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'; $g.DrawString($s, $font, $brush, $x, $y, $sf) }
function Polar([float]$cx, [float]$cy, [float]$r, [float]$deg) { $rad = ($deg - 90) * [Math]::PI / 180; New-Object Drawing.PointF ($cx + $r * [Math]::Cos($rad)), ($cy + $r * [Math]::Sin($rad)) }

# ------------------------------------------------------------------ racing pieces
# dial face, 512x512, 270-degree sweep (zero = -135, max = +135) - the needle slot rotates on that scale
function New-Dial($s, [string]$file, [string]$label, [int]$max, [int]$step, [int]$red, [string]$unit) {
  $c = New-Canvas 512 512; $g = $c.G; $cx = 256; $cy = 256
  $g.FillEllipse((Radial 6 6 500 500 $s.face1 $s.face2), 6, 6, 500, 500)
  if ($s.texture -eq 'carbon') {                                         # carbon weave: small alternating cells
    $clip = New-Object Drawing.Drawing2D.GraphicsPath; $clip.AddEllipse(20, 20, 472, 472); $g.SetClip($clip)
    for ($y = 20; $y -lt 492; $y += 12) { for ($x = 20; $x -lt 492; $x += 12) { if ((($x + $y) / 12) % 2 -eq 0) { $g.FillRectangle((Brush 'ffffff' 10), $x, $y, 12, 6) } else { $g.FillRectangle((Brush '000000' 40), $x, $y + 6, 12, 6) } } }
    $g.ResetClip()
  }
  $g.DrawEllipse((Pen $s.bezel 12), 11, 11, 490, 490); $g.DrawEllipse((Pen $s.bezelHi 3 150), 19, 19, 474, 474)
  $span = 270.0; $start = -135.0; $redStart = $start + $span * $red / $max
  if ($s.leds) {                                                        # LED segments: green -> amber -> red
    for ($v = 0; $v -lt $max; $v += $max / 30.0) {
      $deg = $start + $span * $v / $max; $col = if ($v -ge $red) { 'ff2d2d' } elseif ($v -ge $red * 0.8) { 'ffc400' } else { '27e06b' }
      $g.DrawArc((Pen $col 16 230), 44, 44, 424, 424, [float]($deg - 90 + 1), [float]($span / 30 - 3))
    }
  } else { $g.DrawArc((Pen $s.red 18 220), 46, 46, 420, 420, [float]($redStart - 90), [float]($start + $span - $redStart)) }
  for ($v = 0; $v -le $max; $v += $step / 2) {
    $deg = $start + $span * $v / $max; $major = ($v % $step) -eq 0
    $col = if ($v -ge $red) { $s.redNum } else { $s.tick }
    $g.DrawLine((Pen $col ($(if ($major) { 6 } else { 3 }))), (Polar $cx $cy 222 $deg), (Polar $cx $cy ($(if ($major) { 186 } else { 204 })) $deg))
    if ($major) { $pt = Polar $cx $cy 150 $deg; Text-Center $g ([string]$v) (Font 34 $s.numStyle) (Brush $col) $pt.X $pt.Y }
  }
  Text-Center $g $label (Font 30 'Bold') (Brush $s.label) $cx ($cy + 92)
  Text-Center $g $unit (Font 22 'Regular') (Brush $s.label 170) $cx ($cy + 126)
  if ($s.shiftLight -and $label -eq 'RPM') { $g.FillEllipse((Radial ($cx - 22) ($cy - 112) 44 44 'ff6b6b' 'b00000'), ($cx - 22), ($cy - 112), 44, 44) }
  Save-Canvas $c $file | Out-Null
}
function New-Needle($s, [string]$file) {
  $c = New-Canvas 512 512; $g = $c.G
  $n = New-Object Drawing.Drawing2D.GraphicsPath
  $w = if ($s.thinNeedle) { 5 } else { 9 }
  $n.AddPolygon([Drawing.PointF[]]@([Drawing.PointF]::new(256, 46), [Drawing.PointF]::new(256 + $w, 256), [Drawing.PointF]::new(256, 300), [Drawing.PointF]::new(256 - $w, 256)))
  $g.TranslateTransform(-3, 3); $g.FillPath((Brush '000000' 70), $n); $g.ResetTransform()
  $g.FillPath((Brush $s.needle), $n); $g.DrawPath((Pen $s.needleHi 1.5 180), $n)
  $g.FillEllipse((Radial 226 226 60 60 $s.hub1 $s.hub2), 226, 226, 60, 60)
  Save-Canvas $c $file | Out-Null
}
# the skin's own wheel (used only when the cabinet has no real wheel picture): GT wheel in the skin's colours
function New-Wheel($s, [string]$file) {
  $c = New-Canvas 640 640; $g = $c.G; $cx = 320; $cy = 320; $ro = 300; $rw = 46
  $g.FillEllipse((Radial 10 10 620 620 '000000' '000000' 90 0), 10, 14, 620, 620)
  $rim = New-Object Drawing.Drawing2D.GraphicsPath; $rim.AddEllipse($cx - $ro, $cy - $ro, 2 * $ro, 2 * $ro); $rim.AddEllipse($cx - $ro + $rw, $cy - $ro + $rw, 2 * ($ro - $rw), 2 * ($ro - $rw))
  $g.FillPath((Linear 20 620 $s.rim1 $s.rim2), $rim)
  $g.DrawArc((Pen $s.accent 14), $cx - $ro + 7, $cy - $ro + 7, 2 * $ro - 14, 2 * $ro - 14, 265, 10)
  $g.DrawArc((Pen $s.accent 3 200), $cx - $ro + 1, $cy - $ro + 1, 2 * $ro - 2, 2 * $ro - 2, 100, 340)
  foreach ($deg in 90, 270, 180) { $wd = if ($deg -eq 180) { 70 } else { 58 }; $p1 = Polar $cx $cy 70 $deg; $p2 = Polar $cx $cy ($ro - $rw + 8) $deg; $g.DrawLine((Pen $s.rim2 $wd), $p1, $p2); $g.DrawLine((Pen $s.rim1 ($wd - 18)), $p1, $p2) }
  $g.FillEllipse((Radial ($cx - 92) ($cy - 92) 184 184 $s.rim1 $s.rim2), ($cx - 92), ($cy - 92), 184, 184); $g.DrawEllipse((Pen $s.bezelHi 4), ($cx - 92), ($cy - 92), 184, 184)
  $g.FillEllipse((Brush $s.accent), $cx - 46, $cy - 46, 92, 92); Text-Center $g 'AM' (Font 40 'Bold') (Brush 'ffffff') $cx ($cy + 2)
  Save-Canvas $c $file | Out-Null
}
# select flash, 1920x1080 transparent, sparse (compresses small)
function New-Burst($s, [string]$file) {
  # soft effects (dust, smoke) are drawn at half size and stretched to the 1920x1080 slot: same look, a quarter of the file
  $half = $s.burst -in 'dust', 'smoke'
  $c = if ($half) { New-Canvas 960 540 } else { New-Canvas 1920 1080 }; $g = $c.G; $rnd = New-Object Random 17
  if ($half) { $g.ScaleTransform(0.5, 0.5) }   # same 1920x1080 drawing coordinates, half-size picture
  switch ($s.burst) {
    'lines' { for ($i = 0; $i -lt 120; $i++) { $deg = $rnd.Next(0, 360); $r1 = $rnd.Next(380, 700); $g.DrawLine((Pen $s.burstColor ($rnd.Next(1, 4)) ($rnd.Next(40, 140))), (Polar 960 540 $r1 $deg), (Polar 960 540 ($r1 + $rnd.Next(160, 520)) $deg)) } }
    'dust'  { for ($i = 0; $i -lt 260; $i++) { $deg = $rnd.Next(-80, 80); $r = $rnd.Next(300, 900); $p = Polar 960 1080 $r $deg; $sz = $rnd.Next(4, 18); $g.FillEllipse((Brush $s.burstColor ($rnd.Next(60, 170))), $p.X, $p.Y, $sz, $sz * 0.8) } }
    'smoke' { for ($i = 0; $i -lt 26; $i++) { $x = $rnd.Next(0, 1920); $y = $rnd.Next(620, 1080); $w = $rnd.Next(260, 560); $g.FillEllipse((Radial $x $y $w ($w * 0.6) $s.burstColor $s.burstColor ($rnd.Next(50, 110)) 0), $x, $y, $w, $w * 0.6) } }
    'rain'  { for ($i = 0; $i -lt 240; $i++) { $x = $rnd.Next(-200, 1920); $y = $rnd.Next(0, 1080); $l = $rnd.Next(40, 110); $g.DrawLine((Pen $s.burstColor 2 ($rnd.Next(50, 130))), $x, $y, $x + $l * 0.35, $y + $l) } }
    'stars' { for ($i = 0; $i -lt 160; $i++) { $deg = $rnd.Next(0, 360); $r1 = $rnd.Next(120, 600); $g.DrawLine((Pen $s.burstColor ($rnd.Next(1, 3)) ($rnd.Next(80, 220))), (Polar 960 540 $r1 $deg), (Polar 960 540 ($r1 + $rnd.Next(30, 140)) $deg)) } }
  }
  Save-Canvas $c $file | Out-Null
}
# drifting band, 3840x420, seamless at 1920 (the layout scrolls it)
function New-Drift($s, [string]$file) {
  $c = New-Canvas 3840 420; $g = $c.G; $rnd = New-Object Random 23
  for ($i = 0; $i -lt 70; $i++) {
    $x = $rnd.Next(0, 1920); $yy = $rnd.Next(40, 320)
    foreach ($off in 0, 1920) {
      switch ($s.drift) {
        'clouds' { $w = $rnd.Next(160, 420); $g.FillEllipse((Radial ($x + $off) $yy $w ($w * 0.42) $s.driftColor $s.driftColor ($rnd.Next(40, 90)) 0), ($x + $off), $yy, $w, $w * 0.42) }
        'stars'  { $sz = $rnd.Next(2, 6); $g.FillEllipse((Brush $s.driftColor ($rnd.Next(120, 255))), ($x + $off), $yy, $sz, $sz); $g.DrawLine((Pen $s.driftColor 1 60), ($x + $off - 40), ($yy + $sz / 2), ($x + $off), ($yy + $sz / 2)) }
        'smoke'  { $w = $rnd.Next(200, 480); $g.FillEllipse((Radial ($x + $off) $yy $w ($w * 0.5) $s.driftColor $s.driftColor ($rnd.Next(25, 60)) 0), ($x + $off), $yy, $w, $w * 0.5) }
      }
    }
  }
  Save-Canvas $c $file | Out-Null
}

# ------------------------------------------------------------------ flight pieces
function New-Horizon($s, [string]$file) {
  $c = New-Canvas 700 700; $g = $c.G; $cx = 350
  $clip = New-Object Drawing.Drawing2D.GraphicsPath; $clip.AddEllipse(0, 0, 700, 700); $g.SetClip($clip)
  $g.FillRectangle((Linear 0 352 $s.sky1 $s.sky2), 0, 0, 700, 352); $g.FillRectangle((Linear 348 700 $s.ground1 $s.ground2), 0, 350, 700, 350)
  if ($s.starsInSky) { $rnd = New-Object Random 5; for ($i = 0; $i -lt 70; $i++) { $g.FillEllipse((Brush 'ffffff' ($rnd.Next(90, 230))), $rnd.Next(0, 700), $rnd.Next(0, 340), 3, 3) } }
  $g.DrawLine((Pen $s.ladder 5), 0, 350, 700, 350)
  foreach ($pitch in -30, -20, -10, 10, 20, 30) {
    $y = 350 - $pitch * 4; $half = if ([Math]::Abs($pitch) % 20 -eq 0) { 90 } else { 55 }
    $g.DrawLine((Pen $s.ladder 4), ($cx - $half), $y, ($cx + $half), $y)
    foreach ($sx in -1, 1) { Text-Center $g ([string][Math]::Abs($pitch)) (Font 24 'Bold') (Brush $s.ladder) ($cx + $sx * ($half + 28)) $y }
  }
  Save-Canvas $c $file | Out-Null
}
function New-AttitudePlate($s, [string]$file) {
  $c = New-Canvas 760 760; $g = $c.G; $cx = 380; $cy = 380; $win = 232
  $plate = New-Object Drawing.Drawing2D.GraphicsPath; $plate.AddPath((RoundRect 0 0 760 760 70), $false); $plate.AddEllipse($cx - $win, $cy - $win, 2 * $win, 2 * $win)
  $g.FillPath((Linear 0 760 $s.plate1 $s.plate2), $plate)
  $g.DrawEllipse((Pen $s.bezel 14), $cx - $win - 6, $cy - $win - 6, 2 * $win + 12, 2 * $win + 12)
  $g.DrawEllipse((Pen $s.bezelHi 2 140), $cx - $win - 14, $cy - $win - 14, 2 * $win + 28, 2 * $win + 28)
  foreach ($deg in -60, -45, -30, -20, -10, 0, 10, 20, 30, 45, 60) { $len = if ($deg % 30 -eq 0) { 30 } else { 16 }; $g.DrawLine((Pen $s.tick 4), (Polar $cx $cy ($win + 18) $deg), (Polar $cx $cy ($win + 18 + $len) $deg)) }
  $tri = Polar $cx $cy ($win + 4) 0
  $g.FillPolygon((Brush $s.symbol), [Drawing.PointF[]]@($tri, [Drawing.PointF]::new($tri.X - 14, $tri.Y + 24), [Drawing.PointF]::new($tri.X + 14, $tri.Y + 24)))
  foreach ($sx in -1, 1) { $g.DrawLine((Pen $s.symbol 9), ($cx + $sx * 150), $cy, ($cx + $sx * 60), $cy); $g.DrawLine((Pen $s.symbol 9), ($cx + $sx * 60), $cy, ($cx + $sx * 40), ($cy + 22)) }
  $g.FillEllipse((Brush $s.symbol), $cx - 9, $cy - 9, 18, 18)
  Text-Center $g $s.plateLabel (Font 26 'Bold') (Brush $s.label) $cx 706
  Save-Canvas $c $file | Out-Null
}
function New-Reticle($s, [string]$file) {
  $c = New-Canvas 400 400; $g = $c.G; $hp = Pen $s.hud 4 230
  switch ($s.reticle) {
    'fighter' { $g.DrawEllipse($hp, 150, 150, 100, 100); $g.FillEllipse((Brush $s.hud), 195, 195, 10, 10); foreach ($d in 0, 90, 270) { $g.DrawLine($hp, (Polar 200 200 50 $d), (Polar 200 200 90 $d)) }; for ($a = -60; $a -le 60; $a += 20) { $g.DrawLine((Pen $s.hud 3 200), (Polar 200 200 160 $a), (Polar 200 200 176 $a)) } }
    'pfd'     { $g.DrawLine((Pen $s.hud 6), 90, 200, 170, 200); $g.DrawLine((Pen $s.hud 6), 230, 200, 310, 200); $g.DrawLine((Pen $s.hud 6), 200, 90, 200, 170); $g.DrawLine((Pen $s.hud 6), 200, 230, 200, 310); $g.DrawRectangle((Pen 'ffffff' 3), 190, 190, 20, 20) }
    'space'   { foreach ($r in 40, 90, 150) { $g.DrawEllipse((Pen $s.hud 3 (240 - $r)), 200 - $r, 200 - $r, 2 * $r, 2 * $r) }; foreach ($d in 45, 135, 225, 315) { $g.DrawLine($hp, (Polar 200 200 100 $d), (Polar 200 200 140 $d)) } }
    default   { $g.DrawEllipse($hp, 140, 140, 120, 120); $g.FillEllipse((Brush $s.hud 230), 194, 194, 12, 12); foreach ($d in 0, 90, 180, 270) { $g.DrawLine($hp, (Polar 200 200 70 $d), (Polar 200 200 130 $d)) } }
  }
  Save-Canvas $c $file | Out-Null
}
function New-Control($s, [string]$file) {
  $c = New-Canvas 640 640; $g = $c.G; $cx = 320
  switch ($s.control) {
    'stick' {                                                            # fighter side-stick grip, seen from the pilot
      $grip = RoundRect 240 120 160 330 70
      $g.TranslateTransform(0, 10); $g.FillPath((Brush '000000' 80), $grip); $g.ResetTransform()
      $g.FillPath((Linear 120 450 $s.rim1 $s.rim2), $grip); $g.DrawPath((Pen $s.bezelHi 3), $grip)
      $g.FillRectangle((Brush $s.rim2), 290, 450, 60, 140)
      $g.FillEllipse((Brush $s.accent), 300, 150, 40, 40); $g.FillEllipse((Brush $s.symbol), 256, 215, 28, 28); $g.FillEllipse((Brush $s.symbol), 356, 215, 28, 28)
      $g.FillRectangle((Brush $s.accent 200), 262, 300, 116, 18)
    }
    'wheel' {                                                            # vintage bomber control wheel
      $g.DrawEllipse((Pen $s.rim2 40), 110, 110, 420, 420); $g.DrawEllipse((Pen $s.rim1 24), 110, 110, 420, 420)
      foreach ($deg in 0, 120, 240) { $g.DrawLine((Pen $s.rim1 26), (Polar 320 320 60 $deg), (Polar 320 320 200 $deg)) }
      $g.FillEllipse((Radial 240 240 160 160 $s.rim1 $s.rim2), 240, 240, 160, 160); $g.FillEllipse((Brush $s.accent), 290, 290, 60, 60)
    }
    default {                                                            # yoke (airliner ram's horn)
      $y = New-Object Drawing.Drawing2D.GraphicsPath
      $y.AddPolygon([Drawing.PointF[]]@([Drawing.PointF]::new(70, 230), [Drawing.PointF]::new(130, 230), [Drawing.PointF]::new(170, 300), [Drawing.PointF]::new(470, 300), [Drawing.PointF]::new(510, 230), [Drawing.PointF]::new(570, 230), [Drawing.PointF]::new(590, 270), [Drawing.PointF]::new(560, 420), [Drawing.PointF]::new(505, 420), [Drawing.PointF]::new(480, 365), [Drawing.PointF]::new(160, 365), [Drawing.PointF]::new(135, 420), [Drawing.PointF]::new(80, 420), [Drawing.PointF]::new(50, 270)))
      $g.TranslateTransform(0, 10); $g.FillPath((Brush '000000' 80), $y); $g.ResetTransform()
      $g.FillPath((Linear 230 420 $s.rim1 $s.rim2), $y); $g.DrawPath((Pen $s.bezelHi 3), $y)
      $g.FillRectangle((Brush $s.rim2), 290, 365, 60, 200)
      foreach ($p in @(@(92, 260), @(520, 260))) { $g.FillEllipse((Brush $s.accent), $p[0], $p[1], 26, 26); $g.FillEllipse((Brush $s.symbol), $p[0] + 2, $p[1] + 44, 22, 22) }
    }
  }
  Save-Canvas $c $file | Out-Null
}

# ------------------------------------------------------------------ the skins
$base = @{ numStyle = 'Bold'; texture = ''; leds = $false; shiftLight = $false; thinNeedle = $false; hub1 = '5b606b'; hub2 = '111216'; burst = 'lines'; burstColor = 'ffffff'; drift = ''; driftColor = 'ffffff' }
$racing = [ordered]@{
  rally     = @{ name = 'Rally Stage';   about = 'cream dials, orange needles, gravel spray';    face1 = 'f6efd9'; face2 = 'd8c9a0'; bezel = '15130f'; bezelHi = 'fff6dc'; tick = '1d1a14'; redNum = 'd94a00'; red = 'ff7a00'; label = '3d3528'; needle = 'ff6a00'; needleHi = 'ffd0a8'; rim1 = '3a332a'; rim2 = '15120e'; accent = 'ff7a00'; burst = 'dust'; burstColor = 'b08a5a' }
  gt        = @{ name = 'GT Carbon';     about = 'carbon-fibre dials, white numbers, red needles'; face1 = '2a2c31'; face2 = '0c0d10'; texture = 'carbon'; bezel = '3d4048'; bezelHi = 'c7ccd6'; tick = 'f2f4f8'; redNum = 'ff3030'; red = 'e10600'; label = 'b9bfca'; needle = 'e10600'; needleHi = 'ff9a9a'; rim1 = '33363d'; rim2 = '101114'; accent = 'e10600' }
  pitwall   = @{ name = 'Pit Wall';      about = 'race-car LED shift lights, teal numbers';       face1 = '101418'; face2 = '030405'; leds = $true; bezel = '2a3038'; bezelHi = '5ce1e6'; tick = '5ce1e6'; redNum = 'ff4d4d'; red = 'ff2d2d'; label = '5ce1e6'; needle = '5ce1e6'; needleHi = 'e8ffff'; thinNeedle = $true; rim1 = '252a31'; rim2 = '0b0d10'; accent = '00c2c7'; burstColor = '5ce1e6' }
  tokyo     = @{ name = 'Tokyo Drift';   about = 'violet neon dials and tyre smoke';              face1 = '2a1640'; face2 = '0d0618'; bezel = '3b2160'; bezelHi = 'c77dff'; tick = 'e9d5ff'; redNum = '22e1ff'; red = '22e1ff'; label = 'c77dff'; needle = 'ff3fd8'; needleHi = 'ffc2f3'; rim1 = '35205a'; rim2 = '120a20'; accent = 'ff3fd8'; burst = 'smoke'; burstColor = 'e6e6f0'; drift = 'smoke'; driftColor = 'd8cfe8' }
  vintage   = @{ name = 'Vintage Chrome'; about = 'ivory dials, chrome rims, brass needles';      face1 = 'fbf6e8'; face2 = 'e6dcc2'; numStyle = 'Regular'; bezel = '9aa1ab'; bezelHi = 'ffffff'; tick = '22201c'; redNum = 'a01818'; red = 'b22222'; label = '5a5246'; needle = '1c1a17'; needleHi = 'c9a227'; hub1 = 'e0c46a'; hub2 = '7a5d12'; rim1 = '6b4a2b'; rim2 = '2e1d0f'; accent = 'c9a227'; burst = '' }
  lemans    = @{ name = 'Le Mans Night'; about = 'night-lit green dials and rain';                face1 = '0f1a2e'; face2 = '04080f'; bezel = '22324d'; bezelHi = '7fffb0'; tick = '9dffc4'; redNum = 'ff6b6b'; red = 'ff4040'; label = '6fdc9c'; needle = '7fff9d'; needleHi = 'eaffef'; rim1 = '1b2a42'; rim2 = '070c16'; accent = '2fe07a'; burst = 'rain'; burstColor = 'a9cdfa'; drift = 'clouds'; driftColor = '8fa9c9' }
  dragstrip = @{ name = 'Dragstrip';     about = 'white dials, big red line, shift light, flames'; face1 = 'ffffff'; face2 = 'e9e9e9'; shiftLight = $true; bezel = '111111'; bezelHi = '9a9a9a'; tick = '111111'; redNum = 'e00000'; red = 'e00000'; label = '444444'; needle = 'e00000'; needleHi = 'ffb0b0'; rim1 = '2b2b2b'; rim2 = '0a0a0a'; accent = 'e00000'; burstColor = 'ff8a00' }
}
$flight = [ordered]@{
  fighter  = @{ name = 'Fighter HUD';    about = 'green head-up display and a side stick';     sky1 = '06210f'; sky2 = '0d3d1f'; ground1 = '0a1a0d'; ground2 = '020603'; ladder = '39ff7a'; plate1 = '1b1f1c'; plate2 = '070908'; bezel = '2f3a32'; bezelHi = '39ff7a'; tick = '39ff7a'; symbol = '39ff7a'; label = '39ff7a'; plateLabel = 'HUD'; hud = '39ff7a'; reticle = 'fighter'; control = 'stick'; rim1 = '3a3f3b'; rim2 = '121513'; accent = 'd62828'; drift = 'clouds'; driftColor = 'b5ffcf' }
  warbird  = @{ name = 'Warbird';        about = 'brass and olive 1940s instruments, bomber wheel'; sky1 = '1d3a5c'; sky2 = '6d8fa8'; ground1 = '4a3a22'; ground2 = '1e170c'; ladder = 'f3e6c4'; plate1 = '4b5132'; plate2 = '1f2214'; bezel = 'b08d3c'; bezelHi = 'f0d58a'; tick = 'f3e6c4'; symbol = 'ffb000'; label = 'e8d9b0'; plateLabel = 'GYRO HORIZON'; hud = 'f0d58a'; reticle = 'default'; control = 'wheel'; rim1 = '5a3a1e'; rim2 = '24160a'; accent = 'b08d3c'; drift = 'clouds'; driftColor = 'f5ecd8' }
  airliner = @{ name = 'Glass Cockpit';  about = 'airliner flight display, magenta guidance';   sky1 = '1559c4'; sky2 = '3d8fe8'; ground1 = 'a0632b'; ground2 = '5c3511'; ladder = 'ffffff'; plate1 = '2b2e33'; plate2 = '111316'; bezel = '44484f'; bezelHi = 'aab1bc'; tick = 'ffffff'; symbol = 'ffd400'; label = 'aab1bc'; plateLabel = 'PFD'; hud = 'ff40ff'; reticle = 'pfd'; control = 'yoke'; rim1 = '4a4e56'; rim2 = '17191c'; accent = 'ff40ff'; drift = 'clouds'; driftColor = 'ffffff' }
  space    = @{ name = 'Starfighter';    about = 'violet space horizon, cyan sight, star streaks'; sky1 = '05010f'; sky2 = '1a0a3a'; ground1 = '3a1a6e'; ground2 = '12052b'; starsInSky = $true; ladder = '5ef2ff'; plate1 = '1a1030'; plate2 = '07030f'; bezel = '3b2a6b'; bezelHi = '5ef2ff'; tick = '5ef2ff'; symbol = 'ff5ef2'; label = '9d8cff'; plateLabel = 'NAV'; hud = '5ef2ff'; reticle = 'space'; control = 'stick'; rim1 = '2c2050'; rim2 = '0c0718'; accent = '5ef2ff'; burst = 'stars'; burstColor = 'bfefff'; drift = 'stars'; driftColor = 'dff7ff' }
  nightops = @{ name = 'Night Ops';      about = 'night-vision green on black';                 sky1 = '021006'; sky2 = '06280f'; ground1 = '031a08'; ground2 = '000502'; ladder = '7dff8a'; plate1 = '0b120c'; plate2 = '010301'; bezel = '1d2b1f'; bezelHi = '7dff8a'; tick = '7dff8a'; symbol = '7dff8a'; label = '5fcf6a'; plateLabel = 'NVG'; hud = '7dff8a'; reticle = 'fighter'; control = 'yoke'; rim1 = '1c2a1e'; rim2 = '050a06'; accent = '7dff8a'; drift = 'clouds'; driftColor = '5fcf6a' }
}

function New-Preview([string]$name, [string[]]$parts) {
  # 640x360 card for Tools > Themes: the skin's pieces over a dark backdrop
  $c = New-Canvas 640 360; $g = $c.G; $g.FillRectangle((Linear 0 360 '1a1c22' '07080a'), 0, 0, 640, 360)
  $pos = @(@(20, 90, 190), @(225, 40, 190), @(430, 90, 190))
  for ($i = 0; $i -lt $parts.Count -and $i -lt 3; $i++) { foreach ($layer in $parts[$i] -split '\+') { $im = [Drawing.Image]::FromFile($layer); $g.DrawImage($im, $pos[$i][0], $pos[$i][1], $pos[$i][2], $pos[$i][2]); $im.Dispose() } }
  Save-Canvas $c "${name}_preview.png" | Out-Null
}

$cfgPath = Join-Path $LayoutDir 'themes.json'
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
if (-not $cfg.PSObject.Properties['skins']) { $cfg | Add-Member -NotePropertyName skins -NotePropertyValue ([pscustomobject]@{}) }
$skinsReg = [ordered]@{ racing = [ordered]@{ racing = [ordered]@{ label = 'Neon Night'; about = 'the original ArcadeMaster look' } }; flight = [ordered]@{ flight = [ordered]@{ label = 'Classic Cockpit'; about = 'the original ArcadeMaster look' } } }
$sw = [Diagnostics.Stopwatch]::StartNew()

foreach ($k in $racing.Keys) {
  $s = @{}; foreach ($e in $base.GetEnumerator()) { $s[$e.Key] = $e.Value }; foreach ($e in $racing[$k].GetEnumerator()) { $s[$e.Key] = $e.Value }
  $id = "racing-$k"; $skinsReg.racing[$id] = [ordered]@{ label = $s.name; about = $s.about }
  if ($Only -and $Only -notcontains $k) { continue }
  New-Wheel $s "${id}_wheel.png"; New-Dial $s "${id}_speedo.png" 'SPEED' 320 40 260 'km/h'; New-Dial $s "${id}_tacho.png" 'RPM' 9 1 7 'x1000'; New-Needle $s "${id}_needle.png"
  $burst = if ($s.burst) { New-Burst $s "${id}_burst.png"; "skins/${id}_burst.png" } else { 'blank.png' }
  $drift = 'blank.png'   # am_drift has no element in any layout (nothing shows it): no file, no load
  $theme = [ordered]@{ am_spinner = "skins/${id}_wheel.png"; am_gauge_face = "skins/${id}_speedo.png"; am_gauge_under = 'blank.png'; am_gauge_over = "skins/${id}_needle.png"; am_gauge2_face = "skins/${id}_tacho.png"; am_gauge2_over = "skins/${id}_needle.png"; am_burst = $burst; am_drift = $drift }
  $cfg.themes | Add-Member -Force -NotePropertyName $id -NotePropertyValue ([pscustomobject]$theme)
  $o = Join-Path $OutDir $id; New-Preview $id @("${o}_speedo.png+${o}_needle.png", "${o}_wheel.png", "${o}_tacho.png+${o}_needle.png")
  Write-Host ("{0,-18} {1}" -f $id, $s.name)
}
foreach ($k in $flight.Keys) {
  $s = @{}; foreach ($e in $base.GetEnumerator()) { $s[$e.Key] = $e.Value }; foreach ($e in $flight[$k].GetEnumerator()) { $s[$e.Key] = $e.Value }
  $id = "flight-$k"; $skinsReg.flight[$id] = [ordered]@{ label = $s.name; about = $s.about }
  if ($Only -and $Only -notcontains $k) { continue }
  New-Control $s "${id}_control.png"; New-Horizon $s "${id}_horizon.png"; New-AttitudePlate $s "${id}_plate.png"; New-Reticle $s "${id}_reticle.png"
  $burst = if ($s.burst -and $s.burst -ne 'lines') { New-Burst $s "${id}_burst.png"; "skins/${id}_burst.png" } else { 'blank.png' }
  $drift = 'blank.png'   # am_drift has no element in any layout (nothing shows it): no file, no load
  $theme = [ordered]@{ am_spinner = "skins/${id}_control.png"; am_gauge_face = "skins/${id}_plate.png"; am_gauge_under = "skins/${id}_horizon.png"; am_gauge_over = 'blank.png'; am_gauge2_face = "skins/${id}_reticle.png"; am_gauge2_over = 'blank.png'; am_burst = $burst; am_drift = $drift }
  $cfg.themes | Add-Member -Force -NotePropertyName $id -NotePropertyValue ([pscustomobject]$theme)
  $o = Join-Path $OutDir $id; New-Preview $id @("${o}_horizon.png+${o}_plate.png", "${o}_control.png", "${o}_reticle.png")
  Write-Host ("{0,-18} {1}" -f $id, $s.name)
}
$cfg.skins = [pscustomobject]$skinsReg
$cfg | ConvertTo-Json -Depth 6 | Set-Content $cfgPath -Encoding UTF8
$kb = (Get-ChildItem $OutDir -File | Measure-Object Length -Sum).Sum / 1KB
Write-Host ("skins drawn in {0:N1}s; images\skins = {1:N0} KB; registered in themes.json" -f $sw.Elapsed.TotalSeconds, $kb)
