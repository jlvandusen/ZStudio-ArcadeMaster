<#
.SYNOPSIS
  Renders the cabinet-type title card that the boot splash plays after the Real Z Studios logo:
  studio logo -> fade to black -> "RACING CABINET" (icons slide up, neon title punches in, line draws out, tagline).
  The type comes from settings.conf (cabinetType / cabinetTitle / cabinetTagline, see lib\CabinetTypes.ps1);
  'auto' uses the detected hardware in manifest\cabinet.json. Writes layouts\<Layout>\images\intro\*.png.
  Run at every boot by Start-ArcadeMaster.ps1 and by the Tools menu "Cabinet Type" picker.
#>
param(
  [string]$RetroFE = 'D:\ArcadeMaster\frontend\DRIVE-coinops',
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [string]$Layout = 'ArcadeMaster',
  # render this type instead of the setting (preview / repo default art)
  [string]$Type,
  [string]$OutDir
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\AmVisual.ps1'); . (Join-Path $PSScriptRoot 'lib\CabinetTypes.ps1')
function Get-Setting([string]$key) { $m = Select-String -Path (Join-Path $RetroFE 'settings.conf') -Pattern "^\s*$([regex]::Escape($key))\s*=\s*(.*)$" -ErrorAction SilentlyContinue | Select-Object -Last 1; if ($m) { $m.Matches[0].Groups[1].Value.Trim() } }
$cab = $null; $cf = Join-Path $ManifestDir 'cabinet.json'; if (Test-Path $cf) { $cab = Get-Content $cf -Raw | ConvertFrom-Json }
$setting = if ($Type) { $Type } else { Get-Setting 'cabinetType' }
$ct = Resolve-AmCabinetType $setting $cab (Get-Setting 'cabinetTitle') (Get-Setting 'cabinetTagline')
if (-not $OutDir) { $OutDir = Join-Path $RetroFE "layouts\$Layout\images\intro" }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$c1 = [AmPal]::Hex($ct.color); $c2 = [AmPal]::Hex($ct.color2)
function RectF([double]$x, [double]$y, [double]$w, [double]$h) { New-Object Drawing.RectangleF([float]$x, [float]$y, [float]$w, [float]$h) }
function New-Canvas([int]$w, [int]$h) { $b = New-Object Drawing.Bitmap $w, $h; $g = [Drawing.Graphics]::FromImage($b); [AmDraw]::Hq($g); $g.Clear([Drawing.Color]::Transparent); return $b, $g }
function Save([Drawing.Bitmap]$b, $g, [string]$name) { $g.Dispose(); $b.Save((Join-Path $OutDir $name), [Drawing.Imaging.ImageFormat]::Png); $b.Dispose() }

# 1. colour glow behind everything (two-tone for hybrids)
$b, $g = New-Canvas 1920 1080
foreach ($spot in @(@(560, $c1), @(1360, $c2))) {
  $gp = New-Object Drawing.Drawing2D.GraphicsPath; $gp.AddEllipse((RectF ($spot[0] - 760) -120 1520 1320))
  $pb = New-Object Drawing.Drawing2D.PathGradientBrush $gp; $pb.CenterColor = [AmPal]::A($spot[1], 95); $pb.SurroundColors = @([AmPal]::A($spot[1], 0)); $g.FillPath($pb, $gp)
}
# glow only - no grid / scanline 'retro' look

Save $b $g 'intro_glow.png'

# 2. icons row
$icons = @($ct.icons); $n = $icons.Count; $sz = if ($n -ge 4) { 300 } else { 360 }; $gap = 70
$b, $g = New-Canvas 1600 440
$x0 = (1600 - ($n * $sz + ($n - 1) * $gap)) / 2
for ($i = 0; $i -lt $n; $i++) {
  $col = if ($ct.parts.Count -gt 1 -and $i -ge [Math]::Ceiling($n / 2)) { $c2 } else { $c1 }
  $live = switch ($icons[$i]) { 'wheel' { -14 } 'plane' { -8 } 'handbrake' { 0.5 } 'joystick' { 10 } default { 0 } }
  $r = RectF ($x0 + $i * ($sz + $gap)) ((440 - $sz) / 2) $sz $sz
  # soft halo then the icon
  $hp = New-Object Drawing.Drawing2D.GraphicsPath; $hp.AddEllipse((RectF ($r.X - 40) ($r.Y - 40) ($r.Width + 80) ($r.Height + 80)))
  $hb = New-Object Drawing.Drawing2D.PathGradientBrush $hp; $hb.CenterColor = [AmPal]::A($col, 70); $hb.SurroundColors = @([AmPal]::A($col, 0)); $g.FillPath($hb, $hp)
  [AmDraw]::Icon($g, $icons[$i], $r, $col, [float]$live)
}
Save $b $g 'intro_icons.png'

# 3. neon title (fit to width)
$b, $g = New-Canvas 1800 240
$ff = New-Object Drawing.FontFamily 'Segoe UI Black'; $px = 170
while ($px -gt 70) { $gp = New-Object Drawing.Drawing2D.GraphicsPath; $gp.AddString($ct.title, $ff, [int][Drawing.FontStyle]::Italic, $px, [Drawing.PointF]::new(0, 0), [Drawing.StringFormat]::GenericDefault); if ($gp.GetBounds().Width -le 1700) { break }; $px -= 6 }
[AmDraw]::Neon($g, $ct.title, $ff, [Drawing.FontStyle]::Italic, [float]$px, $c1, (RectF 0 0 1800 240), 'Center')
Save $b $g 'intro_title.png'

# 4. accent line (draws outward in the splash)
$b, $g = New-Canvas 1600 10
$lb = New-Object Drawing.Drawing2D.LinearGradientBrush ((RectF 0 0 1600 10)), ([AmPal]::A($c1, 0)), ([AmPal]::A($c2, 0)), ([float]0)
$blend = New-Object Drawing.Drawing2D.ColorBlend 4; $blend.Colors = @([AmPal]::A($c1, 0), $c1, $c2, [AmPal]::A($c2, 0)); $blend.Positions = @(0, 0.3, 0.7, 1); $lb.InterpolationColors = $blend
$g.FillRectangle($lb, 0, 2, 1600, 6); Save $b $g 'intro_line.png'

# 5. tagline, letter-spaced
$b, $g = New-Canvas 1600 90
$spaced = (($ct.tagline -split ' ') | ForEach-Object { $_.ToCharArray() -join ' ' }) -join '     '
[AmDraw]::Text($g, $spaced, (New-Object Drawing.Font('Segoe UI Semibold', 44, [Drawing.GraphicsUnit]::Pixel)), [AmPal]::Text, (RectF 0 0 1600 90), 'Center', 'Center')
Save $b $g 'intro_tagline.png'

Set-Content (Join-Path $OutDir 'intro.txt') ("type={0}`r`nsetting={1}`r`ntitle={2}`r`ntagline={3}`r`nicons={4}" -f $ct.id, $(if ($setting) { $setting } else { 'auto' }), $ct.title, $ct.tagline, ($ct.icons -join ',')) -Encoding ascii
Write-Host ("intro: {0}  ({1}{2})  icons: {3}" -f $ct.title, $ct.id, $(if ($ct.auto) { ', auto-detected' } else { '' }), ($ct.icons -join ', '))
