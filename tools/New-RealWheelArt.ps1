<#
.SYNOPSIS
  The main menu's centre wheel shows the wheel this cabinet actually has: a front view, upright (top of the rim at the
  top, which is where it sits when the wheel is centred), in the same place and size as the drawn ArcadeMaster wheel.

  Where the picture comes from, first found wins:
    1. Logitech G HUB on this PC: C:\ProgramData\LGHUB\depots\<n>\<model>\<model>_wheel_front.png (e.g. g29)
    2. the local wheel cache, C:\ProgramData\ArcadeMaster\wheels\<key>.png (downloaded earlier)
    3. a download from the maker's picture listed in tools\wheels\wheels.json, into that cache. A white product-shot
       background is removed (flood fill from the edges).
  The wheel is recognised by USB id (VID:PID) or by a piece of the name Windows reports (tools\wheels\wheels.json).
  Pictures are never copied into the repo; each cabinet keeps its own. Writes <layout>\images\racing_wheel_real.png;
  Set-LayoutThemes puts it in the am_realwheel slot. No wheel, or no picture for it -> the file is removed and the
  drawn wheel comes back. Only redraws when the wheel or its picture changed (cheap at every boot).
.EXAMPLE
  tools\New-RealWheelArt.ps1                                  # the detected wheel
  tools\New-RealWheelArt.ps1 -Model 't300' -Out test.png      # try another wheel from the list
  tools\New-RealWheelArt.ps1 -Prefetch                        # download every wheel in the list into the cache
#>
param(
  [string]$RetroFE = 'D:\ArcadeMaster\frontend\DRIVE-coinops',
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [string]$Layout = 'ArcadeMaster',
  [int]$Size = 512,
  [string]$Model,                 # use this wheel-list key instead of the detected wheel
  [string]$Out,                   # write here instead of the layout (with -Model, for previews)
  [switch]$Prefetch,              # download every wheel picture in the list into the cache
  [string]$Catalog = (Join-Path $PSScriptRoot 'wheels\wheels.json'),
  [string]$Cache = (Join-Path $env:ProgramData 'ArcadeMaster\wheels')
)
$ErrorActionPreference = 'Stop'
if (-not $Out) { $Out = Join-Path $RetroFE "layouts\$Layout\images\racing_wheel_real.png" }
$stamp = Join-Path $ManifestDir 'racing_wheel_real.src'
$list = @(); if (Test-Path $Catalog) { $list = @((Get-Content $Catalog -Raw | ConvertFrom-Json).wheels) }

# ---------------------------------------------------------------- picture sources
. (Join-Path $PSScriptRoot 'lib\GHubPictures.ps1')
function Get-GHubPicture([string]$token) {
  if (-not $token) { return $null }
  # older G HUB: <model>\<model>_wheel_front.png; newer G HUB: <model>\images\wheel_front.webp, converted to PNG once
  $dir = Get-AmGHubPictures $token
  if ($dir) { Get-ChildItem $dir -Filter '*wheel*front*.png' -File -ErrorAction SilentlyContinue | Select-Object -First 1 }
}
function Get-CachedPicture($entry) {
  if (-not $entry -or -not $entry.image) { return $null }
  New-Item -ItemType Directory -Force $Cache | Out-Null
  $ext = [IO.Path]::GetExtension(([Uri]$entry.image).AbsolutePath); if ($ext -notmatch '^\.(png|jpe?g|webp)$') { $ext = '.img' }
  $file = Join-Path $Cache ("$($entry.key)$ext")
  if (Test-Path $file) { return Get-Item $file }
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $tmp = "$file.part"
    # a normal browser request (some shops refuse bare clients); JPEG/PNG only - no WebP/AVIF, which Windows' picture
    # library can't read. curl.exe (in Windows 10/11) first: Windows PowerShell's own client drops the Accept header
    # and gets 403 from some image servers (Micro Center); Invoke-WebRequest stays as the fallback.
    $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
    $accept = 'image/jpeg,image/png,image/*;q=0.8,*/*;q=0.5'
    $curl = Join-Path $env:WINDIR 'System32\curl.exe'
    $got = $false
    if (Test-Path $curl) { & $curl -s -f -L --max-time 25 -A $ua -H "Accept: $accept" -H 'Accept-Language: en-US,en;q=0.9' -o $tmp $entry.image; $got = ($LASTEXITCODE -eq 0) -and (Test-Path $tmp) }
    if (-not $got) { Invoke-WebRequest -Uri $entry.image -OutFile $tmp -UseBasicParsing -TimeoutSec 25 -UserAgent $ua -Headers @{ Accept = $accept } }    # keep it only if it really is a picture
    try { $probe = [Drawing.Image]::FromFile($tmp); $probe.Dispose() } catch { Remove-Item $tmp -Force; Write-Host "wheel picture for $($entry.key) is not an image: $($entry.image)"; return $null }
    Move-Item $tmp $file -Force
    Write-Host "downloaded $($entry.model) -> $file"
    return Get-Item $file
  } catch { Remove-Item "$file.part" -Force -ErrorAction SilentlyContinue; Write-Host "could not download $($entry.model): $($_.Exception.Message)"; return $null }
}

# white product-shot background -> transparent: flood fill from every edge pixel close to the corner colour, so white
# parts INSIDE the wheel (logos, stitching) stay. A soft edge keeps the outline smooth.
. (Join-Path $PSScriptRoot 'lib\AmTypeCache.ps1')
Add-Type -AssemblyName System.Drawing
Add-AmCachedType -ProbeType 'AmWheelBg' -References @('System.Drawing') -Source @'
using System; using System.Drawing; using System.Drawing.Imaging; using System.Runtime.InteropServices; using System.Collections.Generic;
public static class AmWheelBg {
  public static bool HasTransparency(Bitmap b) {
    int w = b.Width, h = b.Height;
    foreach (var p in new[] { new Point(0,0), new Point(w-1,0), new Point(0,h-1), new Point(w-1,h-1), new Point(w/2,0), new Point(0,h/2) }) if (b.GetPixel(p.X, p.Y).A < 250) return true;
    return false;
  }
  public static void Remove(Bitmap b, int tol) {
    int w = b.Width, h = b.Height; var r = new Rectangle(0, 0, w, h);
    var d = b.LockBits(r, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb); int st = d.Stride; var px = new byte[st * h]; Marshal.Copy(d.Scan0, px, 0, px.Length);
    Func<int,int,int> I = (x, y) => y * st + x * 4;
    int rb = 0, rg = 0, rr = 0; foreach (var c in new[] { I(0,0), I(w-1,0), I(0,h-1), I(w-1,h-1) }) { rb += px[c]; rg += px[c+1]; rr += px[c+2]; } rb /= 4; rg /= 4; rr /= 4;
    Func<int,int> Dist = i => Math.Max(Math.Abs(px[i]-rb), Math.Max(Math.Abs(px[i+1]-rg), Math.Abs(px[i+2]-rr)));
    var seen = new bool[w * h]; var q = new Queue<int>();
    for (int x = 0; x < w; x++) { q.Enqueue(x); q.Enqueue((h-1)*w + x); } for (int y = 0; y < h; y++) { q.Enqueue(y*w); q.Enqueue(y*w + w-1); }
    while (q.Count > 0) {
      int k = q.Dequeue(); if (seen[k]) continue; seen[k] = true; int x = k % w, y = k / w, i = I(x, y); int dd = Dist(i);
      if (dd > tol * 2) continue;
      px[i+3] = (byte)(dd <= tol ? 0 : Math.Min(px[i+3], (dd - tol) * 255 / tol));   // soft edge between tol and 2*tol
      if (dd > tol) continue;
      if (x > 0) q.Enqueue(k-1); if (x < w-1) q.Enqueue(k+1); if (y > 0) q.Enqueue(k-w); if (y < h-1) q.Enqueue(k+w);
    }
    // holes: the gaps between rim and spokes are background too but not connected to the edge. Clear every enclosed
    // patch of background colour bigger than 0.4% of the picture (a white logo or button label is far smaller).
    int minHole = Math.Max(400, w * h / 250);
    for (int s = 0; s < w * h; s++) {
      if (seen[s] || Dist(I(s % w, s / w)) > tol) continue;
      var comp = new List<int>(); q.Enqueue(s); seen[s] = true;
      while (q.Count > 0) {
        int k = q.Dequeue(); comp.Add(k); int x = k % w, y = k / w;
        foreach (int n in new[] { x > 0 ? k-1 : -1, x < w-1 ? k+1 : -1, y > 0 ? k-w : -1, y < h-1 ? k+w : -1 })
          if (n >= 0 && !seen[n] && Dist(I(n % w, n / w)) <= tol) { seen[n] = true; q.Enqueue(n); }
      }
      if (comp.Count >= minHole) foreach (int k in comp) px[I(k % w, k / w) + 3] = 0;
    }
    // light fringe: an opaque pixel touching a cleared one keeps half its alpha (no bright outline on a dark menu)
    var fr = new List<int>();
    for (int y = 1; y < h-1; y++) for (int x = 1; x < w-1; x++) { int i = I(x, y); if (px[i+3] > 0 && (px[I(x-1,y)+3] == 0 || px[I(x+1,y)+3] == 0 || px[I(x,y-1)+3] == 0 || px[I(x,y+1)+3] == 0)) fr.Add(i); }
    foreach (int i in fr) px[i+3] = (byte)(px[i+3] / 2);
    Marshal.Copy(px, 0, d.Scan0, px.Length); b.UnlockBits(d);
  }
}
'@

# square, upright, centred on a soft light disc (a black wheel on the dark menu would vanish without it)
function Write-WheelPicture([string]$srcPath, [string]$dest, [string]$fit = '') {
  $raw = [Drawing.Image]::FromFile($srcPath)
  try {
    $bmp = New-Object Drawing.Bitmap $raw.Width, $raw.Height, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $gg = [Drawing.Graphics]::FromImage($bmp); $gg.DrawImage($raw, 0, 0, $raw.Width, $raw.Height); $gg.Dispose()
  } finally { $raw.Dispose() }
  if (-not [AmWheelBg]::HasTransparency($bmp)) { [AmWheelBg]::Remove($bmp, 28) }
  $step = [Math]::Max(1, [int]($bmp.Width / 400)); $minX = $bmp.Width; $minY = $bmp.Height; $maxX = 0; $maxY = 0
  for ($y = 0; $y -lt $bmp.Height; $y += $step) { for ($x = 0; $x -lt $bmp.Width; $x += $step) { if ($bmp.GetPixel($x, $y).A -gt 24) { if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }; if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y } } } }
  if ($maxX -le $minX) { $bmp.Dispose(); throw "nothing left of the picture after removing its background: $srcPath" }
  $cw = [Math]::Min($bmp.Width - $minX, $maxX - $minX + $step); $ch = [Math]::Min($bmp.Height - $minY, $maxY - $minY + $step)
  # "top-square": the photo shows the base under the rim (G920, PRO Racing Wheel). A rim is round, so a square as wide
  # as the rim, from the top, is the rim alone - and its centre is where the wheel turns.
  if ($fit -eq 'top-square') {
    # the rim's width comes from the upper part of the picture (only rim there); the base below can be wider
    $x1 = $bmp.Width; $x2 = 0; $yEnd = $minY + [int](0.45 * ($maxY - $minY))
    for ($y = $minY; $y -le $yEnd; $y += $step) { for ($x = 0; $x -lt $bmp.Width; $x += $step) { if ($bmp.GetPixel($x, $y).A -gt 24) { if ($x -lt $x1) { $x1 = $x }; if ($x -gt $x2) { $x2 = $x } } } }
    if ($x2 -gt $x1) { $minX = $x1; $cw = [Math]::Min($bmp.Width - $minX, $x2 - $x1 + $step); $ch = [Math]::Min($ch, $cw) }
  }
  # "rim:0.86": the rim is drawn that much shorter than wide (shot slightly from above): crop to the rim's height and
  # clear everything outside the rim's oval, so the base under it is gone and the picture turns about the rim's centre
  $rimOval = $null
  if ($fit -match '^rim:([\d.]+)$') {
    $ratio = [double]$Matches[1]; $x1 = $bmp.Width; $x2 = 0; $yEnd = $minY + [int](0.45 * ($maxY - $minY))
    for ($y = $minY; $y -le $yEnd; $y += $step) { for ($x = 0; $x -lt $bmp.Width; $x += $step) { if ($bmp.GetPixel($x, $y).A -gt 24) { if ($x -lt $x1) { $x1 = $x }; if ($x -gt $x2) { $x2 = $x } } } }
    if ($x2 -gt $x1) { $minX = $x1; $cw = $x2 - $x1 + $step; $ch = [Math]::Min($bmp.Height - $minY, [int]($cw * $ratio)); $rimOval = $true }
  }
  $canvas = New-Object Drawing.Bitmap $Size, $Size, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [Drawing.Graphics]::FromImage($canvas)
  $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'; $g.Clear([Drawing.Color]::Transparent)
  $gp = New-Object Drawing.Drawing2D.GraphicsPath; $gp.AddEllipse(0, 0, $Size, $Size)
  $glow = New-Object Drawing.Drawing2D.PathGradientBrush $gp; $glow.CenterColor = [Drawing.Color]::FromArgb(150, 70, 80, 105); $glow.SurroundColors = @([Drawing.Color]::FromArgb(0, 20, 22, 30))
  $g.FillEllipse($glow, 0, 0, $Size, $Size)
  $fit = 0.94 * $Size / [Math]::Max($cw, $ch); $dw = $cw * $fit; $dh = $ch * $fit
  $dstRect = New-Object Drawing.RectangleF ((($Size - $dw) / 2), (($Size - $dh) / 2), $dw, $dh)
  if ($rimOval) { $clip = New-Object Drawing.Drawing2D.GraphicsPath; $clip.AddEllipse($dstRect); $g.SetClip($clip) }
  $g.DrawImage($bmp, $dstRect, (New-Object Drawing.RectangleF $minX, $minY, $cw, $ch), [Drawing.GraphicsUnit]::Pixel)
  $g.ResetClip()
  $g.Dispose(); $glow.Dispose(); $gp.Dispose(); $bmp.Dispose()
  New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
  $tmp = "$dest.tmp.png"; $canvas.Save($tmp, [Drawing.Imaging.ImageFormat]::Png); $canvas.Dispose(); Move-Item $tmp $dest -Force
}

# ---------------------------------------------------------------- -Prefetch: fill the cache with every listed wheel
if ($Prefetch) {
  $ok = 0; foreach ($e in $list) { if (Get-CachedPicture $e) { $ok++ } }
  Write-Host "wheel cache: $ok of $($list.Count) pictures in $Cache"; return
}

# ---------------------------------------------------------------- which wheel
$entry = $null; $name = $null; $usb = $null
if ($Model) { $entry = $list | Where-Object { $_.key -eq $Model } | Select-Object -First 1; if (-not $entry) { throw "no wheel '$Model' in $Catalog" }; $name = $entry.model }
else {
  $cab = Join-Path $ManifestDir 'cabinet.json'
  if (Test-Path $cab) {
    $w = @((Get-Content $cab -Raw | ConvertFrom-Json).devices | Where-Object { $_.role -eq 'wheel' -or $_.type -eq 'Driving' }) | Select-Object -First 1
    if ($w) {
      $name = $w.name
      if ($w.id -match 'VID_([0-9A-F]{4})&PID_([0-9A-F]{4})') { $usb = "$($Matches[1]):$($Matches[2])" }
      # by name: the entry whose matching piece is the longest wins (G923 Xbox before G923)
      $byName = @($list | ForEach-Object { $e = $_; $hit = @($e.match | Where-Object { $_ -and $name -like "*$_*" } | Sort-Object Length -Descending)[0]; if ($hit) { [pscustomobject]@{ e = $e; len = $hit.Length } } } | Sort-Object len -Descending | ForEach-Object { $_.e })
      # by USB id; several wheels can share one (Fanatec CSL DD / GT DD Pro / ClubSport DD): then the name decides
      $byUsb = @($list | Where-Object { $usb -and @($_.usb) -contains $usb })
      $entry = if ($byUsb.Count -gt 1) { @($byName | Where-Object { $byUsb -contains $_ })[0] } else { $null }
      if (-not $entry -and $byUsb.Count) { $entry = $byUsb[0] }
      if (-not $entry -and $byName.Count) { $entry = $byName[0] }
    }
  }
}
# G HUB first for Logitech wheels (its token: g29, g920 ...), then the cache / a download
$token = if ($entry -and $entry.ghub) { $entry.ghub } elseif ($name -match '(?i)\bG\s?(\d{2,3})\b') { "g$($Matches[1])" } else { $null }
$src = Get-GHubPicture $token
if (-not $src -and $entry) { $src = Get-CachedPicture $entry }
if (-not $src) {
  if (-not $Model -and (Test-Path $Out)) { Remove-Item $Out -Force; Remove-Item $stamp -ErrorAction SilentlyContinue; Write-Host 'real wheel: none detected or no picture - the drawn wheel is used' }
  else { Write-Host "real wheel: $(if ($name) { "no picture for $name$(if ($usb) { " ($usb)" })" } else { 'no wheel detected' }) - the drawn wheel is used" }
  return
}
$key = "$($src.FullName)|$($src.LastWriteTimeUtc.Ticks)|$Size|2"
if (-not $Model -and (Test-Path $Out) -and (Test-Path $stamp) -and (Get-Content $stamp -Raw).Trim() -eq $key) { Write-Host "real wheel: $name up to date"; return }
$fitMode = if ($entry -and $entry.PSObject.Properties['fit'] -and $src.DirectoryName -eq $Cache) { [string]$entry.fit } else { '' }   # crop hints are for the downloaded photo, not G HUB's
Write-WheelPicture $src.FullName $Out $fitMode
if (-not $Model) { New-Item -ItemType Directory -Force $ManifestDir | Out-Null; Set-Content $stamp $key -Encoding ascii }
Write-Host "real wheel: $name -> $Out (picture: $($src.FullName))"
