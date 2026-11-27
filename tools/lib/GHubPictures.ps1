# Logitech G HUB's product pictures of a wheel (wheel, pedals, shifter), as PNGs our art tools can read.
# Dot-source it, then:  $dir = Get-AmGHubPictures 'g29'   ->  a folder with g29_wheel_front.png, g29_pedals.png, ...
#
# G HUB has two layouts:
#   older G HUB: C:\ProgramData\LGHUB\depots\<n>\g29\g29_wheel_front.png ...       (PNG, used as they are)
#   newer G HUB: C:\ProgramData\LGHUB\depots\<n>\g29\images\wheel_front.webp ...  (WebP, which Windows' picture library
#                cannot read - found on DESKTOP-RACE2 2026-11-27, where the tools fell back to the plain drawing)
# WebP is converted once with ffmpeg into this PC's cache (C:\ProgramData\ArcadeMaster\wheels\<model>) under the old
# names. The cache is also copied to the cabinets' share (Z:\ArcadeMaster\media\ghub-<model>), so a cabinet without
# G HUB (RACE1 after its uninstall) still gets the real pictures. The pictures stay on the cabinets and the NAS, never
# in the repo.
function Get-AmFfmpeg {
  foreach ($p in 'D:\ArcadeMaster\_tools\ffmpeg\ffmpeg.exe') { if (Test-Path $p) { return $p } }
  $c = Get-Command ffmpeg -ErrorAction SilentlyContinue; if ($c) { return $c.Source }
  $w = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Gyan.FFmpeg*\*\bin\ffmpeg.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($w) { return $w.FullName }
  $null
}

function Get-AmGHubPictures([string]$Model = 'g29') {
  $cache = Join-Path $env:ProgramData "ArcadeMaster\wheels\$Model"
  $share = "Z:\ArcadeMaster\media\ghub-$Model"
  $front = "${Model}_wheel_front.png"
  $depots = @(Get-ChildItem 'C:\ProgramData\LGHUB\depots' -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
  $old = $depots | ForEach-Object { Join-Path $_.FullName $Model } | Where-Object { Test-Path (Join-Path $_ $front) } | Select-Object -First 1
  $new = $depots | ForEach-Object { Join-Path $_.FullName "$Model\images" } | Where-Object { Test-Path (Join-Path $_ 'wheel_front.webp') } | Select-Object -First 1
  try {
    if ($old) {
      if (-not (Test-Path (Join-Path $cache $front))) { New-Item -ItemType Directory -Force $cache | Out-Null; Copy-Item (Join-Path $old '*.png') $cache -Force }
    }
    elseif ($new) {
      $ff = Get-AmFfmpeg
      if ($ff) {
        New-Item -ItemType Directory -Force $cache | Out-Null
        foreach ($w in Get-ChildItem $new -Filter *.webp -File) {
          $png = Join-Path $cache ("${Model}_" + $w.BaseName + '.png')
          if ((Test-Path $png) -and (Get-Item $png).LastWriteTime -ge $w.LastWriteTime) { continue }
          # ffmpeg writes its banner to stderr: under 'Stop' Windows PowerShell would make that fatal - judge by the file
          $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
          & $ff -hide_banner -loglevel error -y -i $w.FullName $png 2>$null | Out-Null
          $ErrorActionPreference = $eap
        }
      }
    }
    elseif (-not (Test-Path (Join-Path $cache $front)) -and (Test-Path (Join-Path $share $front))) {
      New-Item -ItemType Directory -Force $cache | Out-Null; Copy-Item (Join-Path $share '*.png') $cache -Force   # no G HUB here
    }
    if ((Test-Path (Join-Path $cache $front)) -and (Test-Path 'Z:\ArcadeMaster') -and -not (Test-Path (Join-Path $share $front))) {
      New-Item -ItemType Directory -Force $share | Out-Null; Copy-Item (Join-Path $cache '*.png') $share -Force
    }
  } catch { }
  if ($old) { return $old }
  if (Test-Path (Join-Path $cache $front)) { return $cache }
  # no full picture set for this model (G HUB downloads it only for a wheel that has been plugged in): its 500 px
  # thumbnail, which G HUB carries for every Logitech wheel, from this PC or the share
  $thumb = Get-AmGHubWheelThumb $Model
  if ($thumb) { New-Item -ItemType Directory -Force $cache | Out-Null; Copy-Item $thumb (Join-Path $cache $front) -Force; return $cache }
  $null
}

# Every Logitech wheel, base, rim, pedal set and shifter G HUB has a thumbnail of (G HUB carries them all, not only the
# connected wheel) -> PNG in Z:\ArcadeMaster\media\ghub-wheels\<name>.png, so any cabinet can show any wheel
# (James 2026-11-27: "we need all the wheels avail"). Converted once; returns how many are on the share.
$AmWheelThumbPattern = '^(g2[5-9]|g92\d(_.*)?|pro_(wheel_base|base_.*|racing_pedals)|rs50_.*|rs_.*)$'   # wheels only, not G9xx mice / headsets
function Export-AmGHubWheelThumbs {
  $share = 'Z:\ArcadeMaster\media\ghub-wheels'
  $src = Get-ChildItem 'C:\ProgramData\LGHUB\depots\*\core_assets\thumbnails' -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
  $ff = Get-AmFfmpeg
  if ($src -and $ff -and (Test-Path 'Z:\ArcadeMaster')) {
    New-Item -ItemType Directory -Force $share | Out-Null
    foreach ($w in Get-ChildItem $src.FullName -Filter *.webp -File | Where-Object { $_.BaseName -match $AmWheelThumbPattern }) {
      $png = Join-Path $share ($w.BaseName + '.png')
      if (Test-Path $png) { continue }
      $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
      & $ff -hide_banner -loglevel error -y -i $w.FullName $png 2>$null | Out-Null
      $ErrorActionPreference = $eap
    }
  }
  @(Get-ChildItem $share -Filter *.png -ErrorAction SilentlyContinue).Count
}

# one wheel's thumbnail as PNG: from the share, else converted from this PC's G HUB. 'g923' also finds g923_pc.
function Get-AmGHubWheelThumb([string]$Model) {
  foreach ($n in @($Model, "${Model}_pc")) {
    $p = Join-Path 'Z:\ArcadeMaster\media\ghub-wheels' "$n.png"
    if (Test-Path $p) { return $p }
  }
  if ((Export-AmGHubWheelThumbs) -gt 0) { foreach ($n in @($Model, "${Model}_pc")) { $p = Join-Path 'Z:\ArcadeMaster\media\ghub-wheels' "$n.png"; if (Test-Path $p) { return $p } } }
  $null
}
