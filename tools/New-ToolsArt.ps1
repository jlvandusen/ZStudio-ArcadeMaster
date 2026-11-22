<#
.SYNOPSIS
  Draws the RetroFE "Tools" list art from the cabinet's CURRENT state, so the menu itself is visual:
    medium_artwork\logo\<item>.png    neon label; toggles carry a live ON/OFF switch
    medium_artwork\video\<item>.png   preview card in the big frame: icon, what it does, and what is true now
                                      (devices plugged in, game counts, current backdrops, switch state, wheel profile)
    medium_artwork\fanart\<item>.jpg  full-screen backdrop in the tool's colour
  Items are found from collections\Tools\roms\*.bat (the -Tool argument). Run by New-CabinetToolsCollection,
  after every tool (Invoke-CabinetTool) and at boot (Start-ArcadeMaster), so the art never goes stale.
#>
param(
  [string]$RetroFE = 'D:\ArcadeMaster\frontend\DRIVE-coinops',
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [switch]$NoFanart
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\AmVisual.ps1'); . (Join-Path $PSScriptRoot 'lib\CabinetTypes.ps1')
$col = Join-Path $RetroFE 'collections\Tools'
# atomic save: write a temp file, then swap it in - RetroFE (already running at boot) never reads a half-written image
function Save-AmImage($bmp, [string]$path, [scriptblock]$save) {
  $tmp = "$path.tmp"; & $save $tmp
  if (Test-Path $path) { try { [IO.File]::Replace($tmp, $path, $null) } catch { Copy-Item $tmp $path -Force; Remove-Item $tmp -ErrorAction SilentlyContinue } } else { [IO.File]::Move($tmp, $path) }
}
if (-not (Test-Path (Join-Path $col 'roms'))) { Write-Warning "no Tools collection at $col (run New-CabinetToolsCollection.ps1)"; return }
foreach ($d in 'logo', 'video', 'fanart') { New-Item -ItemType Directory -Force (Join-Path $col "medium_artwork\$d") | Out-Null }

function Get-Setting([string]$key) { $m = Select-String -Path (Join-Path $RetroFE 'settings.conf') -Pattern "^\s*$([regex]::Escape($key))\s*=\s*(.*)$" -ErrorAction SilentlyContinue | Select-Object -Last 1; if ($m) { $m.Matches[0].Groups[1].Value.Trim() } }
$cab = $null; $cabFile = Join-Path $ManifestDir 'cabinet.json'; if (Test-Path $cabFile) { $cab = Get-Content $cabFile -Raw | ConvertFrom-Json }
$state = @{
  ffb = (Get-Setting 'ffb') -match '^(yes|true|1)$'
  screens = (Get-Setting 'numScreens') -eq '2'
  perf = [int]("0" + (Get-Setting 'perfLog')) -gt 0
}

$meta = @{
  WheelSetup         = @{ icon = 'setup'; color = 'ff2fa0'; what = 'Turn, press and release each control once. Every game gets a best-practice mapping for this wheel.' }
  DetectControllers  = @{ icon = 'detect'; color = '2ec8ff'; what = 'See everything plugged in: wheel, pedals, handbrake, pads, guns, trackball, screens.' }
  RepairIds          = @{ icon = 'repair'; color = '2ec8ff'; what = 'Controller moved to another USB port? Re-point every game to the controllers plugged in now.' }
  RebuildMenus       = @{ icon = 'rebuild'; color = 'ffb000'; what = 'Rescan the game library and rebuild the Racing, Flight and Arcade menus for this cabinet.' }
  ToggleFfb          = @{ icon = 'ffb'; color = 'ff2fa0'; what = 'Centre spring, detent ticks and a thunk on select while you browse. Released when a game starts.'; toggle = 'ffb' }
  ToggleSecondScreen = @{ icon = 'screen2'; color = '9be7ff'; what = 'Marquee banner, game header and touch buttons on the pedestal / second screen.'; toggle = 'screens' }
  ShuffleBackgrounds = @{ icon = 'shuffle'; color = '7b5cff'; what = 'Deal a fresh random set of game backdrops for the main menu.' }
  Themes             = @{ icon = 'shuffle'; color = '7b5cff'; what = 'Change the whole look - ArcadeMaster or a theme imported from CoinOPS / Core. Kept per cabinet mode.' }
  SystemHealth       = @{ icon = 'repair'; color = '3ddc84'; what = 'Check and repair the install: runtime, settings, controls, screens, menus, launchers, logs, disk, art.' }
  SystemSettings     = @{ icon = 'buttons'; color = 'ffb000'; what = 'Auto login, start the arcade at logon, quiet startup, no Windows pop-ups, game bezels, screen always on.' }
  CabinetType        = @{ icon = 'cabinet'; color = '2ec8ff'; what = 'Tell the arcade what it is - racing, flight, light gun, stand-up, multicade, or a combo. Shown in the boot intro.' }
  TogglePerfLog      = @{ icon = 'perf'; color = '9aa3b2'; what = 'Write frame times, p99 and hitches to log.txt every 10 seconds.'; toggle = 'perf' }
}

function PxFont([string]$f, [float]$px, [Drawing.FontStyle]$st = 'Regular') { New-Object Drawing.Font($f, $px, $st, [Drawing.GraphicsUnit]::Pixel) }
function RectF([double]$x, [double]$y, [double]$w, [double]$h) { New-Object Drawing.RectangleF([float]$x, [float]$y, [float]$w, [float]$h) }
$ffBlack = New-Object Drawing.FontFamily 'Segoe UI Black'

# ---- what is true right now, per tool (drawn into the preview card's lower area) ----
function Draw-Now($g, [string]$tool, $acc, [Drawing.RectangleF]$r) {
  $lbl = PxFont 'Segoe UI Semibold' 22; $val = PxFont 'Segoe UI Black' 40; $small = PxFont 'Segoe UI' 20
  [AmDraw]::Text($g, 'NOW', $lbl, [AmPal]::Amber, (RectF $r.X ($r.Y - 34) 200 30), 'Near', 'Center')
  $m = $meta[$tool]
  if ($m.toggle) {
    $on = [bool]$state[$m.toggle]
    [AmDraw]::Toggle($g, (RectF $r.X ($r.Y + 6) 200 84), $on, [AmPal]::Green, (PxFont 'Segoe UI Black' 34))
    $txt = switch ($m.toggle) {
      'screens' { $n = if ($cab) { @($cab.capabilities.displays).Count } else { 0 }; "$n display$(if ($n -ne 1) { 's' }) connected" }
      'ffb' { if ($cab -and ($cab.devices | Where-Object { $_.ffb })) { 'Wheel supports force feedback' } else { 'No force-feedback wheel found' } }
      default { if ($on) { 'Logging every 10 s' } else { 'Not logging' } }
    }
    [AmDraw]::Text($g, $txt, $small, [AmPal]::Dim, (RectF ($r.X + 230) ($r.Y + 6) ($r.Width - 230) 84), 'Near', 'Center')
    return
  }
  switch ($tool) {
    { $_ -in 'DetectControllers', 'RepairIds' } {
      $devs = @(); if ($cab) { $devs = @($cab.devices) }
      if (-not $devs.Count) { [AmDraw]::Text($g, 'No controllers detected yet', $small, [AmPal]::Dim, $r, 'Near', 'Near'); return }
      $x = $r.X; foreach ($d in ($devs | Select-Object -First 5)) {
        $c = switch -Regex ("$($d.role)") { 'wheel' { [AmPal]::Magenta } 'handbrake|pedal|shifter' { [AmPal]::Amber } 'gun' { [AmPal]::Red } default { [AmPal]::Cyan } }
        $cr = RectF $x $r.Y 150 ($r.Height); [AmDraw]::Card($g, $cr, $c, 14, $false)
        [AmDraw]::Icon($g, [AmDraw]::IconForRole("$($d.role)"), (RectF ($x + 40) ($r.Y + 10) 70 70), $c, 0)
        [AmDraw]::Text($g, "$($d.role)".ToUpper(), (PxFont 'Segoe UI Semibold' 18), $c, (RectF $x ($r.Y + 84) 150 26), 'Center', 'Center')
        $x += 164
      }
      if ($cab) { [AmDraw]::Text($g, ("checked " + ([datetime]$cab.detected).ToString('MMM d, HH:mm')), $small, [AmPal]::Dim, (RectF $x $r.Y ($r.Right - $x) $r.Height), 'Near', 'Center') }
    }
    'RebuildMenus' {
      $x = $r.X
      foreach ($n in 'Racing', 'Flight', 'Arcade', 'Lightgun') {
        $d = Join-Path $RetroFE "collections\$n"; if (-not (Test-Path $d)) { continue }
        $cnt = 0; Get-ChildItem $d -Filter *.sub -File | ForEach-Object { $cnt += @(Get-Content $_.FullName | Where-Object { $_.Trim() }).Count }
        $cr = RectF $x $r.Y 200 $r.Height; [AmDraw]::Card($g, $cr, [AmPal]::Amber, 14, $false)
        [AmDraw]::Icon($g, @{ Racing = 'wheel'; Flight = 'joystick'; Arcade = 'gamepad'; Lightgun = 'gun' }[$n], (RectF ($x + 14) ($r.Y + 22) 66 66), [AmPal]::Amber, 0)
        [AmDraw]::Text($g, "$cnt", $val, [AmPal]::Text, (RectF ($x + 86) ($r.Y + 8) 110 60), 'Near', 'Center')
        [AmDraw]::Text($g, $n.ToUpper(), (PxFont 'Segoe UI Semibold' 18), [AmPal]::Dim, (RectF ($x + 88) ($r.Y + 66) 110 30), 'Near', 'Center')
        $x += 214
      }
    }
    'ShuffleBackgrounds' {
      $bgs = @(Get-ChildItem (Join-Path $RetroFE 'layouts\ArcadeMaster\collections\Main\system_artwork') -Filter 'am_bg*' -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 3)
      $x = $r.X; $tw = [Math]::Min(200, ($r.Width - 30) / 3); $th = $tw * 9 / 16
      foreach ($b in $bgs) {
        try { $img = [Drawing.Image]::FromFile($b.FullName); $tr = RectF $x $r.Y $tw $th; $st = $g.Save(); $g.SetClip([AmDraw]::Round($tr, 10)); $g.DrawImage($img, $tr); $g.Restore($st); $img.Dispose()
              $g.DrawPath((New-Object Drawing.Pen ([AmPal]::Violet), 3), [AmDraw]::Round($tr, 10)) } catch { }
        $x += $tw + 15
      }
    }
    'Themes' {
      $cur = Get-Setting 'layout'; $reg = Join-Path $ManifestDir 'themes.json'; $n = 0; $pv = $null
      if (Test-Path $reg) { $all = @((Get-Content $reg -Raw | ConvertFrom-Json).themes | ForEach-Object { $_ }); $n = $all.Count; $pv = ($all | Where-Object { $_.name -eq $cur }).preview }
      $x = $r.X; if ($pv -and (Test-Path $pv)) { try { $img = [Drawing.Image]::FromFile($pv); $tr = RectF $x $r.Y 220 124; $st = $g.Save(); $g.SetClip([AmDraw]::Round($tr, 10)); $g.DrawImage($img, $tr); $g.Restore($st); $img.Dispose(); $x += 240 } catch { } }
      [AmDraw]::Text($g, "$cur", $val, [AmPal]::Text, (RectF $x $r.Y ($r.Right - $x) 60), 'Near', 'Center')
      [AmDraw]::Text($g, "$n theme(s) installed", $small, [AmPal]::Dim, (RectF ($x + 2) ($r.Y + 58) ($r.Right - $x) 34), 'Near', 'Center')
    }

    'SystemHealth' {
      $hf = Join-Path $ManifestDir 'health.json'
      if (Test-Path $hf) { $hj = Get-Content $hf -Raw | ConvertFrom-Json; $x = $r.X
        foreach ($tile in @(@('OK', $hj.ok, [AmPal]::Green), @('FIXED', $hj.fixed, [AmPal]::Cyan), @('NEEDS A LOOK', $hj.warn, $(if ($hj.warn) { [AmPal]::Amber } else { [AmPal]::Dim })))) {
          $cr = RectF $x $r.Y 230 $r.Height; [AmDraw]::Card($g, $cr, $tile[2], 14, $false)
          [AmDraw]::Text($g, "$($tile[1])", $val, $tile[2], (RectF ($x + 16) ($r.Y + 8) 200 60), 'Near', 'Center'); [AmDraw]::Text($g, $tile[0], (PxFont 'Segoe UI Semibold' 18), [AmPal]::Dim, (RectF ($x + 18) ($r.Y + 70) 200 30), 'Near', 'Center'); $x += 246 }
        [AmDraw]::Text($g, ("checked " + ([datetime]$hj.at).ToString('MMM d, HH:mm')), $small, [AmPal]::Dim, (RectF $x $r.Y ($r.Right - $x) $r.Height), 'Near', 'Center') }
      else { [AmDraw]::Text($g, 'Not checked yet - runs at every boot', $small, [AmPal]::Dim, $r, 'Near', 'Near') }
    }

    'SystemSettings' {
      $st = @(); try { $st = @((& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Set-CabinetSystem.ps1') -List -RetroFE $RetroFE -ManifestDir $ManifestDir | Out-String) | ConvertFrom-Json | ForEach-Object { $_ }) } catch { }   # PS 5.1 returns a JSON array as ONE object - unroll
      $x = $r.X; $y = $r.Y; $i = 0
      foreach ($s in $st) {
        $cx = $r.X + ($i % 3) * 316; $cy = $r.Y + [Math]::Floor($i / 3) * 62
        [AmDraw]::Toggle($g, (RectF $cx ($cy + 8) 84 40), [bool]$s.on, [AmPal]::Green, $null)
        [AmDraw]::Text($g, "$($s.label)", (PxFont 'Segoe UI Semibold' 19), $(if ($s.on) { [AmPal]::Text } else { [AmPal]::Dim }), (RectF ($cx + 94) $cy 220 56), 'Near', 'Center'); $i++
      }
    }
    'CabinetType' {
      $setting = Get-Setting 'cabinetType'; $ct = Resolve-AmCabinetType $setting $cab (Get-Setting 'cabinetTitle') (Get-Setting 'cabinetTagline')
      $x = $r.X; foreach ($ic in $ct.icons) { [AmDraw]::Icon($g, $ic, (RectF $x ($r.Y + 6) 84 84), [AmPal]::Hex($ct.color), 0); $x += 96 }
      [AmDraw]::Text($g, $ct.title, (PxFont 'Segoe UI Black' 40 'Italic'), [AmPal]::Text, (RectF ($x + 10) $r.Y ($r.Right - $x - 10) 60), 'Near', 'Center')
      [AmDraw]::Text($g, $(if (-not $setting -or $setting -eq 'auto') { 'auto - from the detected controllers' } else { "cabinetType = $setting" }), $small, [AmPal]::Dim, (RectF ($x + 12) ($r.Y + 58) ($r.Right - $x - 12) 34), 'Near', 'Center')
    }
    'WheelSetup' {
      $pf = Join-Path $PSScriptRoot 'wheelmap\profiles\G29.json'
      if (Test-Path $pf) {
        $p = Get-Content $pf -Raw | ConvertFrom-Json; $mapped = @($p.controls.PSObject.Properties | Where-Object { $_.Value.type -and $_.Value.type -ne 'none' }).Count
        $when = try { ([datetime]$p.created).ToString('MMM d, yyyy') } catch { '' }
        if ($p.confirmed) {
          [AmDraw]::Check($g, (RectF $r.X ($r.Y + 14) 64 64), 2, 0)
          [AmDraw]::Text($g, "$mapped controls captured", $val, [AmPal]::Text, (RectF ($r.X + 84) $r.Y ($r.Width - 84) 60), 'Near', 'Center')
          [AmDraw]::Text($g, ("profile $($p.name)" + $(if ($when) { "  -  captured $when" })), $small, [AmPal]::Dim, (RectF ($r.X + 86) ($r.Y + 58) ($r.Width - 86) 34), 'Near', 'Center')
        } else {
          # seeded from device names / old bindings - usable, but nobody has turned this wheel through the wizard yet
          [AmDraw]::Check($g, (RectF $r.X ($r.Y + 14) 64 64), 0, 0)
          [AmDraw]::Text($g, 'Guessed - run once to confirm', $val, [AmPal]::Amber, (RectF ($r.X + 84) $r.Y ($r.Width - 84) 60), 'Near', 'Center')
          [AmDraw]::Text($g, "$mapped controls guessed from device names and old bindings", $small, [AmPal]::Dim, (RectF ($r.X + 86) ($r.Y + 58) ($r.Width - 86) 34), 'Near', 'Center')
        }
      } else {
        [AmDraw]::Check($g, (RectF $r.X ($r.Y + 14) 64 64), 0, 0)
        [AmDraw]::Text($g, 'Not set up yet', $val, [AmPal]::Amber, (RectF ($r.X + 84) $r.Y ($r.Width - 84) 60), 'Near', 'Center')
      }
    }
  }
}

$made = 0
foreach ($bat in Get-ChildItem (Join-Path $col 'roms') -Filter *.bat -File) {
  $m0 = Select-String -Path $bat.FullName -Pattern '-Tool\s+(\w+)' | Select-Object -First 1; if (-not $m0) { continue }
  $tool = $m0.Matches[0].Groups[1].Value; $m = $meta[$tool]; if (-not $m) { continue }
  $name = $bat.BaseName; $acc = [AmPal]::Hex($m.color); $label = ($name -replace '^\d+\s+', '' -replace '\s+On-Off$', '').ToUpper()

  # ---- logo (1000x200): neon label, plus a live switch for toggles
  $bmp = New-Object Drawing.Bitmap 1000, 200; $g = [Drawing.Graphics]::FromImage($bmp); [AmDraw]::Hq($g); $g.Clear([Drawing.Color]::Transparent)
  if ($m.toggle) {
    $tr = RectF 0 0 770 200; $fs = if ($label.Length -gt 14) { 62 } else { 76 }
    [AmDraw]::Neon($g, $label, $ffBlack, [Drawing.FontStyle]::Italic, $fs, $acc, $tr, 'Center')
    [AmDraw]::Toggle($g, (RectF 790 55 190 90), [bool]$state[$m.toggle], [AmPal]::Green, (PxFont 'Segoe UI Black' 36))
  } else {
    $fs = if ($label.Length -gt 18) { 64 } else { 78 }
    [AmDraw]::Neon($g, $label, $ffBlack, [Drawing.FontStyle]::Italic, $fs, $acc, (RectF 0 0 1000 200), 'Center')
  }
  $g.Dispose(); Save-AmImage $bmp (Join-Path $col "medium_artwork\logo\$name.png") { param($f) $bmp.Save($f, [Drawing.Imaging.ImageFormat]::Png) }; $bmp.Dispose()

  # ---- preview card (1040x585) for the big frame
  $bmp = New-Object Drawing.Bitmap 1040, 585; $g = [Drawing.Graphics]::FromImage($bmp); [AmDraw]::Hq($g); $g.Clear([AmPal]::Bg)
  $glow = New-Object Drawing.Drawing2D.GraphicsPath; $glow.AddEllipse((RectF -300 -300 900 900))
  $pb = New-Object Drawing.Drawing2D.PathGradientBrush $glow; $pb.CenterColor = [AmPal]::A($acc, 70); $pb.SurroundColors = @([AmPal]::A($acc, 0)); $g.FillPath($pb, $glow)
  $g.DrawPath((New-Object Drawing.Pen ([AmPal]::A($acc, 220)), 4), [AmDraw]::Round((RectF 2 2 1036 581), 26))
  $live = if ($m.icon -eq 'perf') { 0.62 } elseif ($m.icon -in 'wheel', 'setup', 'ffb') { -18 } else { 0 }
  [AmDraw]::Icon($g, $m.icon, (RectF 46 46 250 250), $acc, [float]$live)
  [AmDraw]::Neon($g, $label, $ffBlack, [Drawing.FontStyle]::Italic, $(if ($label.Length -gt 16) { 50 } else { 62 }), [AmPal]::Cyan, (RectF 330 40 690 110), 'Near')
  [AmDraw]::Text($g, $m.what, (PxFont 'Segoe UI' 28), [AmPal]::Text, (RectF 334 150 670 150), 'Near', 'Near')
  $g.FillRectangle((New-Object Drawing.SolidBrush ([AmPal]::A($acc, 120))), (RectF 46 330 948 3))
  Draw-Now $g $tool $acc (RectF 46 395 948 140)
  $g.Dispose(); Save-AmImage $bmp (Join-Path $col "medium_artwork\video\$name.png") { param($f) $bmp.Save($f, [Drawing.Imaging.ImageFormat]::Png) }; $bmp.Dispose()

  # ---- backdrop (1920x1080): dark field, glow and a huge faint icon in the tool colour
  if (-not $NoFanart) {
    $bmp = New-Object Drawing.Bitmap 1920, 1080; $g = [Drawing.Graphics]::FromImage($bmp); [AmDraw]::Hq($g); $g.Clear([AmPal]::Bg)
    $glow = New-Object Drawing.Drawing2D.GraphicsPath; $glow.AddEllipse((RectF 700 -200 1600 1400))
    $pb = New-Object Drawing.Drawing2D.PathGradientBrush $glow; $pb.CenterColor = [AmPal]::A($acc, 60); $pb.SurroundColors = @([AmPal]::A($acc, 0)); $g.FillPath($pb, $glow)
    # giant icon drawn on its own layer, then faded as a whole (icons have fixed-colour details, e.g. green checks)
    $lay = New-Object Drawing.Bitmap 900, 900; $lg = [Drawing.Graphics]::FromImage($lay); [AmDraw]::Hq($lg); $lg.Clear([Drawing.Color]::Transparent)
    [AmDraw]::Icon($lg, $m.icon, (RectF 0 0 900 900), $acc, [float]$live); $lg.Dispose()
    $cm = New-Object Drawing.Imaging.ColorMatrix; $cm.Matrix33 = 0.13; $ia = New-Object Drawing.Imaging.ImageAttributes; $ia.SetColorMatrix($cm)
    $g.DrawImage($lay, (New-Object Drawing.Rectangle 1100, 300, 900, 900), 0, 0, 900, 900, [Drawing.GraphicsUnit]::Pixel, $ia); $lay.Dispose()
    $enc = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object MimeType -eq 'image/jpeg'; $ep = New-Object Drawing.Imaging.EncoderParameters 1; $ep.Param[0] = New-Object Drawing.Imaging.EncoderParameter ([Drawing.Imaging.Encoder]::Quality), 88L
    $g.Dispose(); Save-AmImage $bmp (Join-Path $col "medium_artwork\fanart\$name.jpg") { param($f) $bmp.Save($f, $enc, $ep) }; $bmp.Dispose()
  }
  $made++
}
Write-Host "Tools art: $made items (logo + preview card$(if (-not $NoFanart) { ' + backdrop' })) -> $col\medium_artwork"
