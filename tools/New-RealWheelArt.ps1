<#
.SYNOPSIS
  The main menu's wheel (theme slot am_spinner) shows the wheel this cabinet actually has, in the same place and size
  as the drawn ArcadeMaster wheel.

  The picture comes from Logitech G HUB's own product images on this PC
  (C:\ProgramData\LGHUB\depots\<n>\<model>\<model>_wheel_front.png, e.g. g29). They are never copied into the repo:
  each cabinet makes its own from its own G HUB install. Writes <layout>\images\racing_wheel_real.png;
  Set-LayoutThemes uses it instead of racing_wheel.png while it exists. No wheel, or no G HUB picture for it ->
  the file is removed and the drawn wheel comes back.
  Only redraws when the wheel model or the G HUB picture changed (cheap at every boot).
#>
param(
  [string]$RetroFE = 'D:\ArcadeMaster\frontend\DRIVE-coinops',
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [string]$Layout = 'ArcadeMaster',
  [int]$Size = 512
)
$ErrorActionPreference = 'Stop'
$out = Join-Path $RetroFE "layouts\$Layout\images\racing_wheel_real.png"
$stamp = Join-Path $ManifestDir 'racing_wheel_real.src'

# the wheel this cabinet detected (Get-CabinetDevices -> cabinet.json), and its model number (G29, G920, G923, G27 ...)
$model = $null; $name = $null
$cab = Join-Path $ManifestDir 'cabinet.json'
if (Test-Path $cab) {
  $c = Get-Content $cab -Raw | ConvertFrom-Json
  $w = @($c.devices | Where-Object { $_.role -eq 'wheel' -or $_.type -eq 'Driving' }) | Select-Object -First 1
  if ($w) { $name = $w.name; if ($w.name -match '(?i)\bG\s?(\d{2,3})\b') { $model = "g$($Matches[1])" } }
}
$src = $null
if ($model) {
  $src = Get-ChildItem 'C:\ProgramData\LGHUB\depots' -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending |
    ForEach-Object { Get-ChildItem (Join-Path $_.FullName $model) -Filter "*wheel*front*.png" -File -ErrorAction SilentlyContinue } |
    Select-Object -First 1
}
if (-not $src) {
  if (Test-Path $out) { Remove-Item $out -Force; Remove-Item $stamp -ErrorAction SilentlyContinue; Write-Host 'real wheel: none detected or no G HUB picture - the drawn wheel is used' }
  else { Write-Host "real wheel: $(if ($name) { "no G HUB picture for $name" } else { 'no wheel detected' }) - the drawn wheel is used" }
  return
}
$key = "$($src.FullName)|$($src.LastWriteTimeUtc.Ticks)|$Size"
if ((Test-Path $out) -and (Test-Path $stamp) -and (Get-Content $stamp -Raw).Trim() -eq $key) { Write-Host "real wheel: $model up to date"; return }

Add-Type -AssemblyName System.Drawing
$img = [Drawing.Image]::FromFile($src.FullName)
try {
  # crop to the wheel itself (the G HUB picture has transparent margins), then fit it in the square slot
  $bmp = New-Object Drawing.Bitmap $img
  $step = [Math]::Max(1, [int]($bmp.Width / 400))
  $minX = $bmp.Width; $minY = $bmp.Height; $maxX = 0; $maxY = 0
  for ($y = 0; $y -lt $bmp.Height; $y += $step) { for ($x = 0; $x -lt $bmp.Width; $x += $step) { if ($bmp.GetPixel($x, $y).A -gt 24) { if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }; if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y } } } }
  $bmp.Dispose()
  $cw = $maxX - $minX + $step; $ch = $maxY - $minY + $step
  $canvas = New-Object Drawing.Bitmap $Size, $Size, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [Drawing.Graphics]::FromImage($canvas)
  $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'; $g.Clear([Drawing.Color]::Transparent)
  # a soft light disc behind it: the G29 is black and the menu is dark, so the wheel would vanish without it
  $glowPath = New-Object Drawing.Drawing2D.GraphicsPath; $glowPath.AddEllipse(0, 0, $Size, $Size)
  $glow = New-Object Drawing.Drawing2D.PathGradientBrush $glowPath
  $glow.CenterColor = [Drawing.Color]::FromArgb(150, 70, 80, 105); $glow.SurroundColors = @([Drawing.Color]::FromArgb(0, 20, 22, 30))
  $g.FillEllipse($glow, 0, 0, $Size, $Size)
  $fit = 0.94 * $Size / [Math]::Max($cw, $ch)
  $dw = $cw * $fit; $dh = $ch * $fit
  $g.DrawImage($img, (New-Object Drawing.RectangleF ((($Size - $dw) / 2), (($Size - $dh) / 2), $dw, $dh)), (New-Object Drawing.RectangleF $minX, $minY, $cw, $ch), [Drawing.GraphicsUnit]::Pixel)
  $g.Dispose(); $glow.Dispose(); $glowPath.Dispose()
  $tmp = "$out.tmp.png"; $canvas.Save($tmp, [Drawing.Imaging.ImageFormat]::Png); $canvas.Dispose()
  Move-Item $tmp $out -Force
  New-Item -ItemType Directory -Force $ManifestDir | Out-Null; Set-Content $stamp $key -Encoding ascii
  Write-Host "real wheel: $name -> $out"
} finally { $img.Dispose() }
