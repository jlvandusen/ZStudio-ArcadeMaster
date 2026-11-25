<#
.SYNOPSIS
  Draws the live dashboard overlays for the menu's two dials. RetroFE shows each only while the matching control is
  used (layout attributes liveButton / liveAxis, RetroFE patch 0007):
    live_gear_1..6, live_gear_R   the gear the H-shifter is in, above the rev counter's hub
    live_shift_up / live_shift_down   a flash while a shift paddle is pulled (right = up, left = down)
    live_brake_glow               red glow around the speedo, brighter the harder the brake is pressed
  Each is a 512x512 picture on the same square as the dial face (mostly transparent, a few KB), so it lines up with a
  dial of any size. Original art, System.Drawing + Segoe UI, safe to commit.
#>
param([string]$OutDir = (Join-Path $PSScriptRoot '..\layouts\ArcadeMaster\images\live'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force $OutDir | Out-Null; $OutDir = (Resolve-Path $OutDir).Path
function New-Canvas { $b = New-Object Drawing.Bitmap 512, 512, ([Drawing.Imaging.PixelFormat]::Format32bppArgb); $g = [Drawing.Graphics]::FromImage($b); $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'; $g.Clear([Drawing.Color]::Transparent); @{ B = $b; G = $g } }
function Save($c, $name) { $c.G.Dispose(); $p = Join-Path $OutDir $name; $c.B.Save($p, [Drawing.Imaging.ImageFormat]::Png); $c.B.Dispose(); "{0,-22} {1,6:N0} bytes" -f $name, (Get-Item $p).Length }
function C([string]$hex, [int]$a = 255) { [Drawing.Color]::FromArgb($a, [Drawing.ColorTranslator]::FromHtml("#$hex")) }
function Glow-Text($g, [string]$s, [float]$px, [string]$hex, [float]$x, [float]$y) {
  $sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
  $path = New-Object Drawing.Drawing2D.GraphicsPath
  $path.AddString($s, (New-Object Drawing.FontFamily 'Segoe UI'), [int][Drawing.FontStyle]::Bold, $px, (New-Object Drawing.PointF $x, $y), $sf)
  foreach ($w in 22, 14, 8) { $pen = New-Object Drawing.Pen (C $hex 40), $w; $pen.LineJoin = 'Round'; $g.DrawPath($pen, $path) }   # soft glow
  $g.FillPath((New-Object Drawing.SolidBrush (C 'ffffff')), $path); $g.DrawPath((New-Object Drawing.Pen (C $hex), 3), $path)
}

# gear the shifter is in: big digit between the hub and the top numerals of the rev counter
foreach ($gear in '1', '2', '3', '4', '5', '6', 'R') {
  $c = New-Canvas; Glow-Text $c.G $gear 92 $(if ($gear -eq 'R') { 'ff4040' } else { '2ec8ff' }) 256 176; Save $c "live_gear_$gear.png"
}
# paddle flashes either side of the hub: right paddle = shift up, left = shift down
foreach ($dir in @(@('up', 344, -1), @('down', 168, 1))) {
  $c = New-Canvas; $g = $c.G; $x = $dir[1]; $y = 256; $s = 30 * $dir[2]
  $tri = [Drawing.PointF[]]@((New-Object Drawing.PointF $x, ($y + $s)), (New-Object Drawing.PointF ($x - 30), ($y - $s)), (New-Object Drawing.PointF ($x + 30), ($y - $s)))
  foreach ($w in 18, 10) { $pen = New-Object Drawing.Pen (C 'ff2fa0' 60), $w; $pen.LineJoin = 'Round'; $g.DrawPolygon($pen, $tri) }
  $g.FillPolygon((New-Object Drawing.SolidBrush (C 'ff2fa0')), $tri); Save $c "live_shift_$($dir[0]).png"
}
# brake: red glow just inside the speedo's bezel (its alpha follows the pedal)
$c = New-Canvas; $g = $c.G
foreach ($i in 0..9) { $w = 34 - $i * 3; $pen = New-Object Drawing.Pen (C 'ff1e1e' (20 + $i * 18)), $w; $r = 226 - $i * 0.8; $g.DrawEllipse($pen, 256 - $r, 256 - $r, 2 * $r, 2 * $r) }
Save $c 'live_brake_glow.png'
