<#
.SYNOPSIS
  Per-game controls cards: when a game is highlighted, the game list shows the cabinet's controller with every
  control the game uses lit up and numbered, and a legend of what each one does IN THAT GAME.
  Read from the LIVE configuration, so the card always matches what is really bound:
    TeknoParrot  UserProfiles\<game>.xml   ButtonName ("Shift Up", "View Change") + BindNameDi ("Driving Buttons4")
    Model 2      CFG\<rom>.input            decoded codes + the game's slot names (templates\m2emulator.json)
    Supermodel   Supermodel.ini             Input* keys (JOY1_BUTTON5 ...)
    MAME         cfg\<rom>.cfg + ctrlr      port types (P1_PEDAL = accelerate ...) and their sequences
  Writes collections\<col>\medium_artwork\am_controls\<item>.png (1100x300) for the game list layout.
#>
param(
  [string]$RetroFE = 'D:\ArcadeMaster\frontend\DRIVE-coinops',
  [string]$Targets,
  [string[]]$Collections,
  [switch]$Preview          # also writes a contact sheet to %TEMP%\am-controls-sheet.png
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\AmVisual.ps1')
if (-not $Targets) { $Targets = Join-Path $PSScriptRoot "wheelmap\targets\$env:COMPUTERNAME.json"; if (-not (Test-Path $Targets)) { $Targets = Join-Path $PSScriptRoot 'wheelmap\targets\default.json' } }
$tg = Get-Content $Targets -Raw | ConvertFrom-Json

# ---------------- physical controls of the cabinet controller (G29 layout; unknown devices fall back to "Button n")
$G29 = @{ 0 = 'Cross'; 1 = 'Square'; 2 = 'Circle'; 3 = 'Triangle'; 4 = 'Right paddle'; 5 = 'Left paddle'; 6 = 'R2'; 7 = 'L2'; 8 = 'Share'; 9 = 'Options'; 10 = 'R3'; 11 = 'L3'
          12 = 'Gear 1'; 13 = 'Gear 2'; 14 = 'Gear 3'; 15 = 'Gear 4'; 16 = 'Gear 5'; 17 = 'Gear 6'; 18 = 'Reverse'; 19 = 'Plus'; 20 = 'Minus'; 21 = 'Dial right'; 22 = 'Dial left'; 23 = 'Dial press'; 24 = 'PS' }
# positions on a 300x300 wheel face (x, y) - paddles sit on the rim
$Pos = @{ 'Cross' = @(222, 140); 'Square' = @(201, 119); 'Circle' = @(243, 119); 'Triangle' = @(222, 98); 'D-pad up' = @(78, 98); 'D-pad down' = @(78, 140); 'D-pad left' = @(57, 119); 'D-pad right' = @(99, 119)
          'Right paddle' = @(268, 52); 'Left paddle' = @(32, 52); 'R2' = @(232, 168); 'L2' = @(68, 168); 'R3' = @(212, 190); 'L3' = @(88, 190); 'Share' = @(104, 80); 'Options' = @(196, 80)
          'Plus' = @(240, 196); 'Minus' = @(60, 196); 'Dial right' = @(196, 214); 'Dial left' = @(196, 214); 'Dial press' = @(196, 214); 'PS' = @(150, 222) }
function Get-Physical([string]$bind) {
  # TeknoParrot BindNameDi: "Driving Buttons4", "Driving X -", "Driving RotationZ -", "Driving PointOfViewControllers0 UP", "Keyboard Button Return", "Supplemental Sliders0 +"
  if (-not $bind) { return $null }
  if ($bind -match '^Keyboard (?:Button )?(.+)$') { return "Key $($Matches[1])" }
  if ($bind -match '^(\w+) Buttons(\d+)') { $n = [int]$Matches[2]; if ($Matches[1] -eq 'Driving' -and $G29.ContainsKey($n)) { return $G29[$n] }; return "Button $($n + 1)" }
  if ($bind -match 'PointOfViewControllers\d+ (\w+)') { return 'D-pad ' + $Matches[1].ToLower() }
  if ($bind -match '^Supplemental') { return 'Handbrake' }
  if ($bind -match '^(\w+) (\w+)') { switch -Regex ($Matches[2]) { '^X$' { return 'Steering' } '^Y$' { return 'Gas pedal' } '^RotationZ$' { return 'Brake pedal' } '^Sliders0$' { return 'Clutch pedal' } '^Z$' { return 'Z axis' } default { return $Matches[2] } } }
  return $bind
}
function Get-PhysicalFromButton([int]$n) { if ($G29.ContainsKey($n)) { $G29[$n] } else { "Button $($n + 1)" } }

# ---------------- per-emulator readers -> ordered list of @{ action; physical }
function Read-TeknoParrot([string]$item) {
  foreach ($r in @($tg.teknoparrot)) {
    $f = Join-Path $r.root "UserProfiles\$item.xml"; if (-not (Test-Path -LiteralPath $f)) { continue }
    $x = [xml](Get-Content -LiteralPath $f -Raw); $rows = @(); $seen = @{}
    foreach ($b in $x.GameProfile.JoystickButtons.JoystickButtons) {
      $name = "$($b.ButtonName)"; $phys = Get-Physical "$($b.BindNameDi)"
      if (-not $phys -or $name -match '(?i)volume|^test|service|wheel axis (left|right)|^(gas|brake) (up|down)$') { continue }
      if ($name -match '(?i)wheel axis|steering') { $name = 'Steer' }
      $k = "$name|$phys"; if ($seen[$k]) { continue }; $seen[$k] = $true
      $rows += @{ action = $name; physical = $phys }
    }
    return $rows
  }
  return $null
}
$m2tpl = $null; $m2tplFile = Join-Path $PSScriptRoot 'wheelmap\templates\m2emulator.json'; if (Test-Path $m2tplFile) { $m2tpl = Get-Content $m2tplFile -Raw | ConvertFrom-Json }
function Read-Model2([string]$rom) {
  foreach ($r in @($tg.m2emulator)) {
    $f = Join-Path $r.root "CFG\$rom.input"; if (-not (Test-Path -LiteralPath $f) -or -not $m2tpl) { continue }
    $schema = $m2tpl.games.$rom; if (-not $schema) { $schema = @{ 72 = 'drive18'; 84 = 'rally21'; 96 = 'drive24' }[(Get-Item $f).Length - 8] }
    $slots = @($m2tpl.schemas.$schema); if (-not $slots) { return $null }
    $b = [IO.File]::ReadAllBytes($f); $rows = @()
    for ($i = 0; $i -lt $slots.Count; $i++) {
      $s = $slots[$i]; if ($s -match '^(Up|Down|Left|Right|Show render stats|Toggle tilemap render|Cycle Tilemap update rate|Service|Test|Test 2)$') { continue }
      $c = [long][BitConverter]::ToUInt32($b, $i * 4); $phys = $null
      if (([long]$c -band [long]4278190080) -eq [long]4278190080) { $ax = $c -band 0xFF; $phys = switch ($s) { { $_ -match 'Steer|Bank|Handle' } { 'Steering' } { $_ -match 'Accel|Throttle' } { 'Gas pedal' } { $_ -match 'Brake' } { 'Brake pedal' } default { "Axis $ax" } } }
      elseif ($c -ge 0x100) { $lo = $c -band 0xFF; if ($lo -ge 0x0C -and $lo -le 0x0F) { $phys = 'D-pad ' + @('left', 'right', 'up', 'down')[$lo - 0x0C] } else { $n = (($c -shr 12) -band 0xF) * 16 + (($c -shr 4) -band 0xF); $phys = Get-PhysicalFromButton ($n - 1) } }
      elseif ($c -gt 0) { $phys = 'Keyboard' }
      if ($phys -and $phys -ne 'Keyboard') { $rows += @{ action = ($s -replace '^VR ?', 'View ' -replace '^Shift (\d)$', 'Gear $1'); physical = $phys } }
    }
    return $rows
  }
  return $null
}
$smMap = [ordered]@{ InputSteering = 'Steer'; InputAccelerator = 'Accelerate'; InputBrake = 'Brake'; InputGearShiftUp = 'Shift up'; InputGearShiftDown = 'Shift down'; InputGearShift1 = 'Gear 1'; InputGearShift2 = 'Gear 2'; InputGearShift3 = 'Gear 3'; InputGearShift4 = 'Gear 4'
           InputViewChange = 'View change'; InputVR1 = 'View 1'; InputVR2 = 'View 2'; InputVR3 = 'View 3'; InputVR4 = 'View 4'; InputStart1 = 'Start'; InputCoin1 = 'Coin'; InputHandBrake = 'Handbrake'; InputMusicSelect = 'Music select'; InputTwinJoyTurbo1 = 'Turbo' }
function Read-Supermodel {
  foreach ($r in @($tg.supermodel)) {
    if (-not (Test-Path -LiteralPath $r.ini)) { continue }
    $rows = @(); $in = $false
    foreach ($l in Get-Content -LiteralPath $r.ini) {
      if ($l -match '^\s*\[(.+)\]') { $in = $Matches[1] -eq 'Global'; continue }
      if (-not $in -or $l -notmatch '^\s*(Input\w+)\s*=\s*"?([^"]*)"?') { continue }
      $k = $Matches[1]; $v = $Matches[2]; if (-not $smMap.Contains($k)) { continue }
      $phys = $null
      if ($v -match 'JOY\d+_BUTTON(\d+)') { $phys = Get-PhysicalFromButton ([int]$Matches[1] - 1) }
      elseif ($v -match 'JOY\d+_POV\d+_(\w+)') { $phys = 'D-pad ' + $Matches[1].ToLower() }
      elseif ($v -match 'JOY\d+_XAXIS') { $phys = 'Steering' } elseif ($v -match 'JOY\d+_YAXIS') { $phys = 'Gas pedal' } elseif ($v -match 'JOY\d+_RZAXIS') { $phys = 'Brake pedal' } elseif ($v -match 'JOY\d+_SLIDER') { $phys = 'Clutch pedal' }
      if ($phys) { $rows += @{ action = $smMap[$k]; physical = $phys } }
    }
    return $rows
  }
  return $null
}
$mamePort = [ordered]@{ P1_PADDLE = 'Steer'; P1_DIAL = 'Steer'; P1_POSITIONAL = 'Steer'; P1_PEDAL = 'Accelerate'; P1_PEDAL2 = 'Brake'; P1_PEDAL3 = 'Clutch'; P1_AD_STICK_X = 'Bank / steer'; P1_AD_STICK_Y = 'Climb / dive'; P1_AD_STICK_Z = 'Throttle'
             P1_BUTTON1 = 'Gear shift'; P1_BUTTON2 = 'View'; P1_BUTTON3 = 'Button 3'; P1_BUTTON4 = 'Button 4'; START1 = 'Start'; COIN1 = 'Coin' }
function Read-Mame([string]$rom) {
  foreach ($r in @($tg.mame)) {
    $rows = @(); $seq = @{}
    foreach ($f in @((Join-Path $r.root 'ctrlr\wheelmap.cfg'), (Join-Path $r.root "cfg\$rom.cfg"))) {
      if (-not (Test-Path -LiteralPath $f)) { continue }
      $x = [xml](Get-Content -LiteralPath $f -Raw)
      foreach ($p in $x.SelectNodes('//port')) { $ty = $p.GetAttribute('type'); $s = $p.SelectSingleNode('newseq'); if ($s -and $mamePort.Contains($ty)) { $seq[$ty] = $s.InnerText.Trim() } }
    }
    if (-not $seq.Count) { continue }
    foreach ($ty in $mamePort.Keys) {
      if (-not $seq.ContainsKey($ty)) { continue }; $v = $seq[$ty]; $phys = @()
      foreach ($m in [regex]::Matches($v, 'JOYCODE_\d+_(BUTTON(\d+)|HAT\d+(UP|DOWN|LEFT|RIGHT)|XAXIS|YAXIS|RZAXIS|SLIDER\d)')) {
        if ($m.Groups[2].Success) { $phys += Get-PhysicalFromButton ([int]$m.Groups[2].Value - 1) } elseif ($m.Groups[3].Success) { $phys += 'D-pad ' + $m.Groups[3].Value.ToLower() }
        else { $phys += @{ XAXIS = 'Steering'; YAXIS = 'Gas pedal'; RZAXIS = 'Brake pedal'; SLIDER1 = 'Clutch pedal' }[$m.Groups[1].Value] }
      }
      foreach ($ph in ($phys | Where-Object { $_ } | Select-Object -Unique)) { $rows += @{ action = $mamePort[$ty]; physical = $ph } }
    }
    # MAME games the default file covers: keep only controls this game has (paddle/dial/pedals appear in its own cfg)
    return $rows
  }
  return $null
}

# Dolphin (GameCube / Wii / Triforce) and Cemu: the template says which emulated button carries which profile control;
# what the button DOES in the game comes from this table.
$GameActions = @{
  'Mario Kart: Double Dash!!' = @{ 'Buttons/A' = 'Accelerate'; 'Buttons/B' = 'Brake / reverse'; 'Buttons/X' = 'Item'; 'Buttons/Y' = 'Item (other driver)'; 'Buttons/Z' = 'Swap drivers'; 'Buttons/Start' = 'Pause'; 'Triggers/L' = 'Drift / hop'; 'Triggers/R' = 'Drift / hop'; 'Main Stick/Left' = 'Steer'; 'Main Stick/Right' = 'Steer' }
  'F-Zero GX' = @{ 'Buttons/A' = 'Accelerate'; 'Buttons/B' = 'Air brake'; 'Buttons/Y' = 'Boost'; 'Buttons/X' = 'Spin attack'; 'Buttons/Start' = 'Pause'; 'Triggers/L' = 'Side attack / drift left'; 'Triggers/R' = 'Side attack / drift right'; 'Main Stick/Left' = 'Steer'; 'Main Stick/Right' = 'Steer' }
  'Auto Modellista' = @{ 'Buttons/A' = 'Accelerate'; 'Buttons/B' = 'Brake'; 'Buttons/X' = 'View'; 'Buttons/Start' = 'Pause'; 'Triggers/L' = 'Shift down'; 'Triggers/R' = 'Shift up'; 'Main Stick/Left' = 'Steer'; 'Main Stick/Right' = 'Steer'; 'Main Stick/Up' = 'Throttle'; 'Main Stick/Down' = 'Brake' }
  'Mario Kart Wii' = @{ 'Classic/Buttons/A' = 'Accelerate'; 'Classic/Buttons/B' = 'Brake / reverse'; 'Classic/Triggers/R' = 'Drift / hop'; 'Classic/Triggers/L' = 'Item'; 'Classic/Buttons/+' = 'Pause'; 'Classic/Left Stick/Left' = 'Steer'; 'Classic/Left Stick/Right' = 'Steer' }
  'F-Zero AX' = @{ 'Buttons/A' = 'Accelerate'; 'Buttons/B' = 'Brake'; 'Buttons/Y' = 'Boost'; 'Triggers/L' = 'Side attack left'; 'Triggers/R' = 'Side attack right'; 'Buttons/Start' = 'Start'; 'Main Stick/Left' = 'Steer'; 'Main Stick/Right' = 'Steer' }
  'Mario Kart Arcade GP' = @{ 'Buttons/A' = 'Item'; 'Buttons/B' = 'Mario button / cancel'; 'Triggers/R-Analog' = 'Accelerate'; 'Triggers/L-Analog' = 'Brake'; 'Buttons/Start' = 'Start'; 'Main Stick/Left' = 'Steer'; 'Main Stick/Right' = 'Steer' }
  'Mario Kart 8' = @{ '1' = 'Accelerate (A)'; '2' = 'Brake / reverse (B)'; '3' = 'Rear view (X)'; '4' = 'Item (Y)'; '5' = 'Item (L)'; '6' = 'Drift / hop (R)'; '7' = 'Item (ZL)'; '8' = 'Drift / hop (ZR)'; '9' = 'Pause (+)'; '10' = 'Map (-)'; '20' = 'Steer'; '21' = 'Steer' }
}
$GameActions['Mario Kart Arcade GP 2'] = $GameActions['Mario Kart Arcade GP']
function Get-Norm([string]$s) { ($s -replace '\(.*?\)', '' -replace '[^A-Za-z0-9]', '').ToLower() }
$wmProfile = $null; $pf = Join-Path $PSScriptRoot 'wheelmap\profiles\G29.json'; if (Test-Path $pf) { $wmProfile = Get-Content $pf -Raw | ConvertFrom-Json }
function Get-ProfilePhysical([string]$spec) {
  foreach ($c in ($spec -split '\|')) {
    $c = $c -replace '[+-]$', ''; $b = $wmProfile.controls.$c; if (-not $b -or -not $b.type -or $b.type -eq 'none') { continue }
    switch ($b.type) {
      'button' { if ($b.device -eq 'wheel') { return Get-PhysicalFromButton ([int]$b.button) } else { return "$($b.device) button $([int]$b.button + 1)" } }
      'pov' { return "D-pad $("$($b.dir)".ToLower())" }
      'axis' { if ($b.device -ne 'wheel') { return 'Handbrake' }; return @{ X = 'Steering'; Y = 'Gas pedal'; RotationZ = 'Brake pedal'; Sliders0 = 'Clutch pedal' }["$($b.axis)"] }
      'key' { return "Key $($b.name)" }
    }
  }
  return $null
}
function Read-TemplateGame([string]$item, [string]$kind) {
  if (-not $wmProfile) { return $null }
  $tplName = if ($kind -eq 'cemu') { 'cemu' } else { 'dolphin' }
  $tpl = Get-Content (Join-Path $PSScriptRoot "wheelmap\templates\$tplName.json") -Raw | ConvertFrom-Json
  $n = Get-Norm $item
  $title = ($GameActions.Keys | Where-Object { $n.StartsWith((Get-Norm $_)) } | Sort-Object Length -Descending | Select-Object -First 1); if (-not $title) { return $null }
  $acts = $GameActions[$title]; $map = $null
  if ($kind -eq 'cemu') { $g = $tpl.games.PSObject.Properties | Where-Object { (Get-Norm $_.Value.title).StartsWith((Get-Norm $title)) } | Select-Object -First 1; if ($g) { $map = $tpl.layouts.($g.Value.layout) } }
  else { foreach ($sec in 'gcpad', 'wiimote', 'triforce') { foreach ($e in $tpl.$sec.PSObject.Properties) { $tt = if ($e.Value.title) { $e.Value.title } else { $e.Name }; if ((Get-Norm $tt).StartsWith((Get-Norm $title)) -or (Get-Norm $title).StartsWith((Get-Norm $tt))) { $map = $e.Value.map; break } }; if ($map) { break } } }
  if (-not $map) { return $null }
  $rows = @(); $seen = @{}
  foreach ($p in $map.PSObject.Properties) {
    if (-not $acts.ContainsKey($p.Name)) { continue }
    $spec = @($p.Value)[0]; $phys = Get-ProfilePhysical "$spec"; if (-not $phys) { continue }
    $k = "$($acts[$p.Name])|$phys"; if ($seen[$k]) { continue }; $seen[$k] = $true
    $rows += @{ action = $acts[$p.Name]; physical = $phys }
  }
  return $rows
}
# ---------------- drawing
$pal = @([AmPal]::Magenta, [AmPal]::Cyan, [AmPal]::Amber, [AmPal]::Green, [AmPal]::Violet, [AmPal]::Red, [AmPal]::Hex('9be7ff'), [AmPal]::Hex('ff8a3d'))
function New-Card([string]$title, $rows, [string]$path) {
  $W = 1100; $H = 300
  $bmp = New-Object Drawing.Bitmap $W, $H; $g = [Drawing.Graphics]::FromImage($bmp); [AmDraw]::Hq($g); $g.Clear([Drawing.Color]::Transparent)
  $card = New-Object Drawing.RectangleF 2, 2, ($W - 4), ($H - 4)
  $p = [AmDraw]::Round($card, 22); $g.FillPath((New-Object Drawing.SolidBrush ([AmPal]::A([AmPal]::Bg, 232))), $p); $g.DrawPath((New-Object Drawing.Pen ([AmPal]::A([AmPal]::Magenta, 200)), 3), $p)
  # wheel face
  $ox = 14; $oy = 0; $face = New-Object Drawing.RectangleF ($ox + 10), ($oy + 10), 280, 280
  $g.DrawEllipse((New-Object Drawing.Pen ([AmPal]::A([AmPal]::Text, 70)), 22), $face)
  $g.FillEllipse((New-Object Drawing.SolidBrush ([AmPal]::A([AmPal]::Card2, 255))), (New-Object Drawing.RectangleF ($ox + 95), ($oy + 95), 110, 110))
  # pedals (clutch left, brake middle, gas right) + handbrake + shifter column
  $px = 316
  $used = @{}; $i = 0
  foreach ($r in $rows) { if (-not $used.ContainsKey($r.physical)) { $used[$r.physical] = @{ n = ++$i; color = $pal[($i - 1) % $pal.Count] } } }
  $pedals = @(@('Clutch pedal', 'CLUTCH'), @('Brake pedal', 'BRAKE'), @('Gas pedal', 'GAS'))
  for ($k = 0; $k -lt 3; $k++) {
    $pr = New-Object Drawing.RectangleF ($px + $k * 46), 150, 36, ($(if ($k -eq 2) { 110 } else { 96 })); $pr.Y = 262 - $pr.Height
    $u = $used[$pedals[$k][0]]; $c = if ($u) { $u.color } else { [AmPal]::Faint }
    $pp = [AmDraw]::Round($pr, 8); $g.FillPath((New-Object Drawing.SolidBrush ([AmPal]::A($c, $(if ($u) { 120 } else { 40 })))), $pp); $g.DrawPath((New-Object Drawing.Pen $c, 2), $pp)
    [AmDraw]::Text($g, $pedals[$k][1], (New-Object Drawing.Font('Segoe UI Semibold', 11, [Drawing.GraphicsUnit]::Pixel)), $(if ($u) { [AmPal]::Text } else { [AmPal]::Dim }), (New-Object Drawing.RectangleF ($pr.X - 8), 266, ($pr.Width + 16), 18), 'Center', 'Center')
    if ($u) { Draw-Badge $g ($pr.X + $pr.Width / 2) ($pr.Y - 14) $u }
  }
  foreach ($extra in @(@('Handbrake', 'handbrake', 448, 120), @('Shifter', 'shifter', 448, 30))) {
    $hit = @($used.Keys | Where-Object { ($extra[0] -eq 'Handbrake' -and $_ -eq 'Handbrake') -or ($extra[0] -eq 'Shifter' -and $_ -match '^(Gear \d|Reverse)$') })
    $c = if ($hit) { $used[$hit[0]].color } else { [AmPal]::Faint }
    [AmDraw]::Icon($g, $extra[1], (New-Object Drawing.RectangleF $extra[2], $extra[3], 84, 84), $c, $(if ($extra[1] -eq 'handbrake') { [float]0.4 } else { [float]0 }))
    if ($hit -and $extra[0] -eq 'Handbrake') { Draw-Badge $g ($extra[2] + 70) ($extra[3] + 10) $used[$hit[0]] }
  }
  # wheel-face controls
  foreach ($k in $Pos.Keys) {
    $xy = $Pos[$k]; $u = $used[$k]
    $rr = New-Object Drawing.RectangleF ($ox + $xy[0] - 9), ($oy + $xy[1] - 9), 18, 18
    if ($k -match 'paddle') { $rr = New-Object Drawing.RectangleF ($ox + $xy[0] - 16), ($oy + $xy[1] - 8), 32, 16 }
    $g.FillEllipse((New-Object Drawing.SolidBrush $(if ($u) { $u.color } else { [AmPal]::A([AmPal]::Faint, 200) })), $rr)
    if ($u) { Draw-Badge $g ($ox + $xy[0] + 14) ($oy + $xy[1] - 14) $u }
  }
  if ($used['Steering']) { Draw-Badge $g ($ox + 150) ($oy + 30) $used['Steering'] }
  # title + legend
  $lx = 560
  [AmDraw]::Text($g, $title.ToUpper(), (New-Object Drawing.Font('Segoe UI Black', 22, [Drawing.FontStyle]::Italic, [Drawing.GraphicsUnit]::Pixel)), [AmPal]::Cyan, (New-Object Drawing.RectangleF $lx, 12, 520, 32), 'Near', 'Center')
  $lf = New-Object Drawing.Font('Segoe UI Semibold', 16, [Drawing.GraphicsUnit]::Pixel); $pf = New-Object Drawing.Font('Segoe UI', 14, [Drawing.GraphicsUnit]::Pixel)
  $rowsShown = @($rows | Select-Object -First 14); $colW = 262; $rh = 34
  for ($j = 0; $j -lt $rowsShown.Count; $j++) {
    $r = $rowsShown[$j]; $u = $used[$r.physical]; $cx = $lx + [Math]::Floor($j / 7) * $colW; $cy = 52 + ($j % 7) * $rh
    Draw-Badge $g ($cx + 12) ($cy + 15) $u
    [AmDraw]::Text($g, "$($r.action)", $lf, [AmPal]::Text, (New-Object Drawing.RectangleF ($cx + 30), $cy, ($colW - 34), 18), 'Near', 'Center')
    [AmDraw]::Text($g, "$($r.physical)", $pf, $u.color, (New-Object Drawing.RectangleF ($cx + 30), ($cy + 16), ($colW - 34), 16), 'Near', 'Center')
  }
  $g.Dispose(); New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null; $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}
function Draw-Badge($g, [float]$x, [float]$y, $u) {
  $r = New-Object Drawing.RectangleF ($x - 11), ($y - 11), 22, 22
  $g.FillEllipse((New-Object Drawing.SolidBrush $u.color), $r)
  [AmDraw]::Text($g, "$($u.n)", (New-Object Drawing.Font('Segoe UI Black', 13, [Drawing.GraphicsUnit]::Pixel)), [AmPal]::Bg, $r, 'Center', 'Center')
}

# display titles from the catalog (games.json): id / TeknoParrot profile / ROM -> "Daytona USA"
$titles = @{}
$catFile = 'D:\ArcadeMaster\manifest\games.json'
if (Test-Path $catFile) { foreach ($gm in (Get-Content $catFile -Raw | ConvertFrom-Json).games) { if ($gm.id -and $gm.title) { $titles[(Get-Norm $gm.id)] = $gm.title }; foreach ($v in $gm.variants.PSObject.Properties) { foreach ($k in 'profile', 'rom') { if ($v.Value.$k) { $titles[(Get-Norm $v.Value.$k)] = $gm.title } } } } }
function Get-Title([string]$item) { $k = Get-Norm $item; if ($titles.ContainsKey($k)) { return $titles[$k] }; return ($item -replace '\s*\(.*?\)', '') }

# ---------------- which games: every item of the merged mode collections (Racing / Flight ...) and their sources
$cols = if ($Collections) { $Collections } else { @('Racing', 'Flight', 'Lightgun', 'Arcade') }
$done = 0; $skipped = @(); $made = New-Object Collections.Generic.List[string]
foreach ($top in $cols) {
  $dir = Join-Path $RetroFE "collections\$top"; if (-not (Test-Path $dir)) { continue }
  foreach ($sub in Get-ChildItem $dir -Filter *.sub -File) {
    $src = $sub.BaseName
    foreach ($item in (Get-Content $sub.FullName | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })) {
      $rows = $null
      if ($src -match 'TeknoParrot|AM_TP') { $rows = Read-TeknoParrot $item }
      elseif ($src -eq 'Sega Model 2') { $rows = Read-Model2 $item }
      elseif ($src -eq 'Sega Model 3') { $rows = Read-Supermodel }
      elseif ($src -eq 'MAME') { $rows = Read-Mame $item }
      elseif ($src -match 'Gamecube|Nintendo Wii\b|Nintendo Wii\$|Triforce') { $rows = Read-TemplateGame $item 'dolphin' }
      elseif ($src -match 'Wii U') { $rows = Read-TemplateGame $item 'cemu' }
      if (-not $rows) { $skipped += "$src/$item"; continue }
      $out = Join-Path $RetroFE "collections\$src\medium_artwork\am_controls\$item.png"
      New-Card (Get-Title $item) $rows $out; $made.Add($out); $done++
    }
  }
}
Write-Host "controls cards: $done made; no live mapping found for $($skipped.Count) (PC games use their own in-game control menus)"
if ($Preview -and $made.Count) {
  $pick = @($made | Get-Random -Count ([Math]::Min(6, $made.Count)))
  $sheet = New-Object Drawing.Bitmap 1100, (310 * $pick.Count); $g = [Drawing.Graphics]::FromImage($sheet); $g.Clear([Drawing.Color]::FromArgb(40, 40, 46)); $y = 0
  foreach ($f in $pick) { $im = [Drawing.Image]::FromFile($f); $g.DrawImage($im, 0, $y, 1100, 300); $im.Dispose(); $y += 310 }
  $g.Dispose(); $sheet.Save((Join-Path $env:TEMP 'am-controls-sheet.png')); $sheet.Dispose(); Write-Host "preview: $(Join-Path $env:TEMP 'am-controls-sheet.png')"
}
