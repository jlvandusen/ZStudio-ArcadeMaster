<#
.SYNOPSIS
  Per-game controls cards: when a game is highlighted, the game list shows the cabinet's controller with every
  control the game uses lit up and numbered, and a legend of what each one does IN THAT GAME.
  Read from the LIVE configuration, so the card always matches what is really bound:
    TeknoParrot  UserProfiles\<game>.xml   ButtonName ("Shift Up", "View Change") + BindNameDi ("Driving Buttons4")
    Model 2      CFG\<rom>.input            decoded codes + the game's slot names (templates\m2emulator.json)
    Supermodel   Supermodel.ini             Input* keys (JOY1_BUTTON5 ...)
    MAME         cfg\<rom>.cfg + ctrlr      port types (P1_PEDAL = accelerate ...) and their sequences
  Writes collections\<col>\medium_artwork\am_controls\<item>.png (1100x300 card) and am_controls_wheel\<item>.png (300x300 G29 that turns with the real wheel), plus layouts\ArcadeMaster\images\controls\*.png (button / pedal glows).
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
# where each control sits on the G29 (300x300 wheel picture, centre 150,150): left spoke D-pad + Share + L2/L3,
# right spoke face buttons + Options + R2/R3, bottom +/- , red dial and PS; the paddles sit behind the rim
$Pos = [ordered]@{ 'Share' = @(80, 108); 'Options' = @(220, 108)
          'D-pad up' = @(84, 124); 'D-pad down' = @(84, 152); 'D-pad left' = @(70, 138); 'D-pad right' = @(98, 138)
          'Triangle' = @(216, 122); 'Square' = @(200, 138); 'Circle' = @(232, 138); 'Cross' = @(216, 154)
          'L2' = @(74, 178); 'L3' = @(98, 184); 'R2' = @(226, 178); 'R3' = @(202, 184)
          'Plus' = @(120, 196); 'Minus' = @(120, 220); 'Dial right' = @(180, 208); 'Dial left' = @(180, 208); 'Dial press' = @(180, 208); 'PS' = @(150, 238)
          'Left paddle' = @(16, 128); 'Right paddle' = @(284, 128) }
$HatMask = @{ 'D-pad up' = 1; 'D-pad right' = 2; 'D-pad down' = 4; 'D-pad left' = 8 }
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
# Three layers, so RetroFE can bring the wheel to life (retrofe patch 0007, liveSteer / liveButton / liveAxis):
#   am_controls        1100x300 card: pedals, shifter, handbrake and the legend (what every control does in this game)
#   am_controls_wheel   300x300 the G29 itself, the game's buttons coloured and numbered - turns with the real wheel
#   images\controls\    one glow per wheel button / pedal (same for every game) - lights while it is pressed
$pal = @([AmPal]::Magenta, [AmPal]::Cyan, [AmPal]::Amber, [AmPal]::Green, [AmPal]::Violet, [AmPal]::Red, [AmPal]::Hex('9be7ff'), [AmPal]::Hex('ff8a3d'), [AmPal]::Hex('f5f56b'), [AmPal]::Hex('7cf0c8'))
$PedalRect = @{ 'Clutch pedal' = @(336, 128, 46, 116); 'Brake pedal' = @(394, 128, 46, 116); 'Gas pedal' = @(452, 108, 46, 136) }   # x, y, w, h on the card
function Get-Friendly([string]$phys) {
  switch -Regex ($phys) {
    '^Key Return$' { return 'Enter key' }
    '^Key (.+)$' { return "$($Matches[1]) key" }
    '^Steering$' { return 'Turn the wheel' }
    '^(Left|Right) paddle$' { return "$phys (behind the wheel)" }
    '^(Cross|Square|Circle|Triangle)$' { return "$phys button" }
    '^(L2|L3|R2|R3|Share|Options|PS)$' { return "$phys button" }
    '^(Plus|Minus)$' { return "$phys button" }
    '^Gear (\d)$' { return "Shifter in gear $($Matches[1])" }
    '^Reverse$' { return 'Shifter in reverse' }
    '^Dial (left|right)$' { return "Red dial $($Matches[1])" }
    '^Dial press$' { return 'Press the red dial' }
    default { return $phys }
  }
}
function Get-UsedMap($rows) {
  $used = [ordered]@{}; $i = 0
  foreach ($r in $rows) { if ($r.physical -and -not $used.Contains($r.physical)) { $used[$r.physical] = @{ n = ++$i; color = $pal[($i - 1) % $pal.Count] } } }
  return $used
}
function Fill-Round($g, $rect, [float]$rad, $color) { $p = [AmDraw]::Round($rect, $rad); $g.FillPath((New-Object Drawing.SolidBrush $color), $p); $p.Dispose() }
function Draw-Num($g, [float]$cx, [float]$cy, [float]$r, $u) {
  $rr = New-Object Drawing.RectangleF ($cx - $r), ($cy - $r), (2 * $r), (2 * $r)
  $g.FillEllipse((New-Object Drawing.SolidBrush $u.color), $rr)
  $g.DrawEllipse((New-Object Drawing.Pen ([AmPal]::A([Drawing.Color]::White, 200)), 1.5), $rr)
  [AmDraw]::Text($g, "$($u.n)", (New-Object Drawing.Font('Segoe UI Black', [float]([Math]::Max(10, $r * 1.15)), [Drawing.GraphicsUnit]::Pixel)), [AmPal]::Bg, $rr, 'Center', 'Center')
}
function Draw-Glyph($g, [string]$name, [float]$cx, [float]$cy, $color) {
  $pen = New-Object Drawing.Pen $color, 1.8
  switch ($name) {
    'Cross'    { $g.DrawLine($pen, $cx - 4, $cy - 4, $cx + 4, $cy + 4); $g.DrawLine($pen, $cx - 4, $cy + 4, $cx + 4, $cy - 4) }
    'Circle'   { $g.DrawEllipse($pen, $cx - 4.5, $cy - 4.5, 9, 9) }
    'Square'   { $g.DrawRectangle($pen, $cx - 4, $cy - 4, 8, 8) }
    'Triangle' { $g.DrawPolygon($pen, [Drawing.PointF[]]@((New-Object Drawing.PointF $cx, ($cy - 5)), (New-Object Drawing.PointF ($cx + 5), ($cy + 4)), (New-Object Drawing.PointF ($cx - 5), ($cy + 4)))) }
    'Plus'     { $g.DrawLine($pen, $cx - 4, $cy, $cx + 4, $cy); $g.DrawLine($pen, $cx, $cy - 4, $cx, $cy + 4) }
    'Minus'    { $g.DrawLine($pen, $cx - 4, $cy, $cx + 4, $cy) }
  }
  $pen.Dispose()
}
# the G29 seen from the driver's seat; $used colours + numbers the controls this game uses (empty = plain wheel)
function Draw-G29($g, $used) {
  $c = 150
  # paddles behind the rim (drawn first so the rim overlaps them)
  foreach ($side in 'Left paddle', 'Right paddle') {
    $xy = $Pos[$side]; $u = if ($used) { $used[$side] } else { $null }
    $pr = New-Object Drawing.RectangleF ($xy[0] - 12), ($xy[1] - 26), 24, 52
    Fill-Round $g $pr 10 $(if ($u) { $u.color } else { [AmPal]::Hex('3a3f4a') })
  }
  # rim: dark leather with a lighter top edge and stitching
  $rim = New-Object Drawing.Pen ([AmPal]::Hex('23262d')), 30; $g.DrawEllipse($rim, 22, 22, 256, 256); $rim.Dispose()
  $hi = New-Object Drawing.Pen ([AmPal]::A([Drawing.Color]::White, 40)), 2; $g.DrawArc($hi, 9, 9, 282, 282, 200, 140); $hi.Dispose()
  $st = New-Object Drawing.Pen ([AmPal]::A([AmPal]::Hex('9aa4b2'), 90)), 1.2; $st.DashPattern = @(3, 3); $g.DrawEllipse($st, 22, 22, 256, 256); $st.Dispose()
  # three spokes (brushed metal) + hub
  $metal = New-Object Drawing.Drawing2D.LinearGradientBrush ((New-Object Drawing.PointF 0, 90)), ((New-Object Drawing.PointF 0, 250)), ([AmPal]::Hex('5b616d')), ([AmPal]::Hex('2b2f37'))
  $g.FillPath($metal, [AmDraw]::Round((New-Object Drawing.RectangleF 34, 96, 232, 100), 40))
  $g.FillPath($metal, [AmDraw]::Round((New-Object Drawing.RectangleF 104, 150, 92, 112), 24))
  $metal.Dispose()
  $g.FillEllipse((New-Object Drawing.SolidBrush ([AmPal]::Hex('1b1e24'))), 118, 112, 64, 64)
  $g.DrawEllipse((New-Object Drawing.Pen ([AmPal]::A([Drawing.Color]::White, 60)), 1.5), 118, 112, 64, 64)
  # the red dial
  $dial = $Pos['Dial press']; $g.FillEllipse((New-Object Drawing.SolidBrush ([AmPal]::Hex('c8202f'))), ($dial[0] - 15), ($dial[1] - 15), 30, 30)
  $g.FillEllipse((New-Object Drawing.SolidBrush ([AmPal]::Hex('1b1e24'))), ($dial[0] - 7), ($dial[1] - 7), 14, 14)
  $dialUse = if ($used) { @('Dial right', 'Dial left', 'Dial press' | Where-Object { $used.Contains($_) }) } else { @() }
  if ($dialUse) { Draw-Num $g ($dial[0] + 17) ($dial[1] - 15) 9 $used[$dialUse[0]] }
  # D-pad cross
  $dp = New-Object Drawing.SolidBrush ([AmPal]::Hex('15171c'))
  $g.FillRectangle($dp, 75, 116, 18, 44); $g.FillRectangle($dp, 62, 129, 44, 18); $dp.Dispose()
  # every other button
  foreach ($k in $Pos.Keys) {
    if ($k -match 'paddle|^Dial') { continue }
    $xy = $Pos[$k]; $u = if ($used) { $used[$k] } else { $null }
    $r = if ($k -match '^D-pad') { 8 } elseif ($k -match '^(Share|Options|Plus|Minus|PS)$') { 7.5 } else { 10 }
    if ($u) { Draw-Num $g $xy[0] $xy[1] ([Math]::Max($r, 9)) $u; continue }
    $b = New-Object Drawing.RectangleF ($xy[0] - $r), ($xy[1] - $r), (2 * $r), (2 * $r)
    if ($k -notmatch '^D-pad') { $g.FillEllipse((New-Object Drawing.SolidBrush ([AmPal]::Hex('15171c'))), $b); $g.DrawEllipse((New-Object Drawing.Pen ([AmPal]::A([Drawing.Color]::White, 50)), 1), $b) }
    Draw-Glyph $g $k $xy[0] $xy[1] ([AmPal]::A([Drawing.Color]::White, 150))
  }
  if ($used -and $used.Contains('Steering')) { Draw-Num $g 150 16 12 $used['Steering'] }   # top of the rim
  foreach ($side in 'Left paddle', 'Right paddle') { if ($used -and $used.Contains($side)) { $xy = $Pos[$side]; Draw-Num $g $xy[0] ($xy[1] - 34) 11 $used[$side] } }   # paddle numbers above the rim
}
function New-WheelPicture($used, [string]$path) {
  $bmp = New-Object Drawing.Bitmap 300, 300; $g = [Drawing.Graphics]::FromImage($bmp); [AmDraw]::Hq($g); $g.Clear([Drawing.Color]::Transparent)
  Draw-G29 $g $used
  $g.Dispose(); New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null; $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}
function New-Card([string]$title, $rows, [string]$path) {
  $W = 1100; $H = 300; $used = Get-UsedMap $rows
  $bmp = New-Object Drawing.Bitmap $W, $H; $g = [Drawing.Graphics]::FromImage($bmp); [AmDraw]::Hq($g); $g.Clear([Drawing.Color]::Transparent)
  $card = New-Object Drawing.RectangleF 2, 2, ($W - 4), ($H - 4)
  $cp = [AmDraw]::Round($card, 22); $g.FillPath((New-Object Drawing.SolidBrush ([AmPal]::Hex('0b0d12'))), $cp); $g.DrawPath((New-Object Drawing.Pen ([AmPal]::A([AmPal]::Magenta, 220)), 3), $cp)
  # soft pool of light where the (separate, turning) wheel picture sits
  $pool = New-Object Drawing.Drawing2D.GraphicsPath; $pool.AddEllipse(14, 4, 292, 292)
  $pb = New-Object Drawing.Drawing2D.PathGradientBrush $pool; $pb.CenterColor = [AmPal]::Hex('1a1f2a'); $pb.SurroundColors = @([AmPal]::Hex('0b0d12')); $g.FillPath($pb, $pool); $pb.Dispose()
  # pedals: clutch LEFT, brake MIDDLE, gas RIGHT
  foreach ($pd in @(@('Clutch pedal', 'CLUTCH'), @('Brake pedal', 'BRAKE'), @('Gas pedal', 'GAS'))) {
    $q = $PedalRect[$pd[0]]; $pr = New-Object Drawing.RectangleF $q[0], $q[1], $q[2], $q[3]; $u = $used[$pd[0]]
    Fill-Round $g $pr 9 ([AmPal]::Hex('2b2f37'))
    for ($ry = $pr.Y + 12; $ry -lt $pr.Bottom - 8; $ry += 12) { $g.DrawLine((New-Object Drawing.Pen ([AmPal]::Hex('3c414c')), 3), ($pr.X + 9), $ry, ($pr.Right - 9), $ry) }   # grip ridges
    $g.DrawPath((New-Object Drawing.Pen $(if ($u) { $u.color } else { [AmPal]::Hex('3c414c') }), 2.5), [AmDraw]::Round($pr, 9))
    [AmDraw]::Text($g, $pd[1], (New-Object Drawing.Font('Segoe UI Semibold', 12, [Drawing.GraphicsUnit]::Pixel)), $(if ($u) { [AmPal]::Text } else { [AmPal]::Dim }), (New-Object Drawing.RectangleF ($pr.X - 10), ($pr.Bottom + 6), ($pr.Width + 20), 18), 'Center', 'Center')
    if ($u) { Draw-Num $g ($pr.X + $pr.Width / 2) ($pr.Y - 16) 12 $u }
  }
  # shifter + handbrake
  $gearUse = @($used.Keys | Where-Object { $_ -match '^(Gear \d|Reverse)$' })
  $hb = $used['Handbrake']
  [AmDraw]::Icon($g, 'shifter', (New-Object Drawing.RectangleF 516, 34, 62, 62), $(if ($gearUse) { $used[$gearUse[0]].color } else { [AmPal]::Hex('3c414c') }), [float]0)
  if ($gearUse) { Draw-Num $g 586 40 11 $used[$gearUse[0]] }
  [AmDraw]::Icon($g, 'handbrake', (New-Object Drawing.RectangleF 516, 150, 62, 62), $(if ($hb) { $hb.color } else { [AmPal]::Hex('3c414c') }), [float]0.4)
  if ($hb) { Draw-Num $g 586 156 11 $hb }
  $g.DrawLine((New-Object Drawing.Pen ([AmPal]::A([AmPal]::Magenta, 90)), 1.5), 606, 24, 606, 276)
  # legend: what each control does in this game
  $lx = 624
  [AmDraw]::Text($g, $title.ToUpper(), (New-Object Drawing.Font('Segoe UI Black', 24, [Drawing.FontStyle]::Italic, [Drawing.GraphicsUnit]::Pixel)), [AmPal]::Cyan, (New-Object Drawing.RectangleF $lx, 12, 460, 34), 'Near', 'Center')
  $af = New-Object Drawing.Font('Segoe UI Semibold', 17, [Drawing.GraphicsUnit]::Pixel); $pf = New-Object Drawing.Font('Segoe UI', 13, [Drawing.GraphicsUnit]::Pixel)
  $list = @($used.Keys | ForEach-Object { $ph = $_; $acts = @($rows | Where-Object { $_.physical -eq $ph } | ForEach-Object { $_.action } | Select-Object -Unique); @{ physical = $ph; action = ($acts -join ' / '); u = $used[$ph] } } | Select-Object -First 14)
  $perCol = [Math]::Max(1, [Math]::Ceiling($list.Count / 2)); $colW = 232; $rh = [Math]::Min(40, [Math]::Floor(236 / [Math]::Max(1, $perCol)))
  for ($j = 0; $j -lt $list.Count; $j++) {
    $it = $list[$j]; $cx = $lx + [Math]::Floor($j / $perCol) * $colW; $cy = 54 + ($j % $perCol) * $rh
    Draw-Num $g ($cx + 12) ($cy + 17) 12 $it.u
    [AmDraw]::Text($g, $it.action, $af, [AmPal]::Text, (New-Object Drawing.RectangleF ($cx + 32), $cy, ($colW - 36), 20), 'Near', 'Center')
    [AmDraw]::Text($g, (Get-Friendly $it.physical), $pf, $it.u.color, (New-Object Drawing.RectangleF ($cx + 32), ($cy + 19), ($colW - 36), 16), 'Near', 'Center')
  }
  $g.Dispose(); New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null; $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
  New-WheelPicture $used ($path -replace '\\am_controls\\', '\am_controls_wheel\')
}
# glow pictures (same for every game): one per G29 button / D-pad direction (300x300, turn with the wheel) + pedals
function New-GlowSet([string]$dir) {
  New-Item -ItemType Directory -Force $dir | Out-Null
  $names = @{}; foreach ($n in $G29.Keys) { if ($Pos.Contains($G29[$n])) { $names["btn$n"] = $G29[$n] } }
  foreach ($k in $HatMask.Keys) { $names["hat$($HatMask[$k])"] = $k }
  foreach ($f in $names.Keys) {
    $xy = $Pos[$names[$f]]; $bmp = New-Object Drawing.Bitmap 300, 300; $g = [Drawing.Graphics]::FromImage($bmp); [AmDraw]::Hq($g); $g.Clear([Drawing.Color]::Transparent)
    foreach ($ring in @(@(22, 40), @(17, 90), @(13, 200))) { $r = $ring[0]; $g.FillEllipse((New-Object Drawing.SolidBrush ([AmPal]::A([AmPal]::Hex('bff6ff'), $ring[1]))), ($xy[0] - $r), ($xy[1] - $r), (2 * $r), (2 * $r)) }
    $g.Dispose(); $bmp.Save((Join-Path $dir "$f.png"), [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
  }
  foreach ($pd in $PedalRect.Keys) {
    $q = $PedalRect[$pd]; $bmp = New-Object Drawing.Bitmap ([int]$q[2] + 24), ([int]$q[3] + 24); $g = [Drawing.Graphics]::FromImage($bmp); [AmDraw]::Hq($g); $g.Clear([Drawing.Color]::Transparent)
    foreach ($ring in @(@(0, 50), @(5, 110), @(10, 190))) { $i = $ring[0]; Fill-Round $g (New-Object Drawing.RectangleF $i, $i, ($q[2] + 24 - 2 * $i), ($q[3] + 24 - 2 * $i)) 12 ([AmPal]::A([AmPal]::Hex('bff6ff'), $ring[1])) }
    $g.Dispose(); $bmp.Save((Join-Path $dir ("pedal_" + ($pd -replace ' pedal', '').ToLower() + '.png')), [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
  }
}

# display titles from the catalog (games.json): id / TeknoParrot profile / ROM -> "Daytona USA"
$titles = @{}
$catFile = 'D:\ArcadeMaster\manifest\games.json'
if (Test-Path $catFile) { foreach ($gm in (Get-Content $catFile -Raw | ConvertFrom-Json).games) { if ($gm.id -and $gm.title) { $titles[(Get-Norm $gm.id)] = $gm.title; $titles[(Get-Norm ($gm.id -replace '^[^:]*:', ''))] = $gm.title };   # "MAME:sf2049se" -> also "sf2049se"
  foreach ($v in $gm.variants.PSObject.Properties) { if ($v.Value.file -and $gm.title) { $titles[(Get-Norm ([IO.Path]::GetFileNameWithoutExtension($v.Value.file)))] = $gm.title } }; foreach ($v in $gm.variants.PSObject.Properties) { foreach ($k in 'profile', 'rom') { if ($v.Value.$k) { $titles[(Get-Norm $v.Value.$k)] = $gm.title } } } } }
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
New-GlowSet (Join-Path $RetroFE 'layouts\ArcadeMaster\images\controls')
Write-Host "controls cards: $done made; no live mapping found for $($skipped.Count) (PC games use their own in-game control menus)"
if ($Preview -and $made.Count) {
  $pick = @($made | Get-Random -Count ([Math]::Min(6, $made.Count)))
  $sheet = New-Object Drawing.Bitmap 1100, (310 * $pick.Count); $g = [Drawing.Graphics]::FromImage($sheet); $g.Clear([Drawing.Color]::FromArgb(40, 40, 46)); $y = 0
  foreach ($f in $pick) { $im = [Drawing.Image]::FromFile($f); $g.DrawImage($im, 0, $y, 1100, 300); $im.Dispose(); $wf = $f -replace '\\am_controls\\', '\am_controls_wheel\'; if (Test-Path $wf) { $wi = [Drawing.Image]::FromFile($wf); $g.DrawImage($wi, 10, $y, 300, 300); $wi.Dispose() }; $y += 310 }
  $g.Dispose(); $sheet.Save((Join-Path $env:TEMP 'am-controls-sheet.png')); $sheet.Dispose(); Write-Host "preview: $(Join-Path $env:TEMP 'am-controls-sheet.png')"
}
