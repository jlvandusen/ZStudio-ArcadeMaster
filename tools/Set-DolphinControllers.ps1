<#
.SYNOPSIS
  Keeps Dolphin (Wii / GameCube) matched to the controllers that are plugged in RIGHT NOW. Runs at boot
  (Start-ArcadeMaster) and from Tools > Detect Controllers.
    - Real Wii Remotes ("wands", Bluetooth or Mayflash DolphinBar): Wii Remote slots 1..N switch to Source = 2 (Real)
      and continuous scanning is enabled; unplug them and the slots go back to what they were (normally the
      emulated Wii Remote mapped to the wheel by WheelMap).
    - Balance Board: [BalanceBoard] Source = 2 while one is connected.
    - GameCube controller adapter (Wii U / Switch, 057E:0337): GC ports 2-4 become 'GC Adapter' (SIDevice 12);
      port 1 stays the wheel-mapped standard controller. Restored when the adapter is unplugged.
    - Stale devices: a profile bound to a controller that is not connected (e.g. 'DInput/0/... G920 ...' on a
      G29 cabinet) is re-pointed to the connected wheel / stick of the same kind.
  Original values are remembered in <User>\Config\ArcadeMaster-controllers.json so every change is reversible.
#>
param(
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [string[]]$DolphinUser,
  [string]$Targets
)
$ErrorActionPreference = 'Stop'
$cab = Get-Content (Join-Path $ManifestDir 'cabinet.json') -Raw | ConvertFrom-Json
$wii = $cab.capabilities.wii
if (-not $DolphinUser) {
  if (-not $Targets) { $Targets = Join-Path $PSScriptRoot "wheelmap\targets\$env:COMPUTERNAME.json"; if (-not (Test-Path $Targets)) { $Targets = Join-Path $PSScriptRoot 'wheelmap\targets\default.json' } }
  $tj = Get-Content $Targets -Raw | ConvertFrom-Json
  $DolphinUser = @($tj.dolphin | ForEach-Object { $_.user }) | Where-Object { $_ -and (Test-Path $_) }
}
# a DolphinBar's slots count as real remotes: a remote synced to any slot then just works (continuous scanning)
$real = if ($wii) { [Math]::Min(4, [int]$wii.wiimotes + [int]$wii.dolphinBarSlots) } else { 0 }
$realSlots = @(1..4 | Where-Object { $_ -le $real })
# AmPanel watches a DolphinBar and writes which of its slots has a remote synced right now (WiiRemotes.cs):
# only those become Real; the others keep the emulated remote on the panel, so a Wii game works with either
$liveFile = Join-Path $ManifestDir 'wii-remotes.json'
if ($wii -and [int]$wii.dolphinBarSlots -gt 0 -and (Test-Path $liveFile)) {
  try {
    $live = @((Get-Content $liveFile -Raw | ConvertFrom-Json).slots | ForEach-Object { [int]$_ })
    $bt = [Math]::Min(4, [int]$wii.wiimotes)   # remotes paired over Bluetooth take the first free slots
    $realSlots = @($live) + @(1..4 | Where-Object { $live -notcontains $_ } | Select-Object -First $bt)
    $real = $realSlots.Count
  } catch { }
}
$board = $wii -and [int]$wii.balanceBoard -gt 0
$gcad = $wii -and [bool]$wii.gcAdapter
$present = @($cab.devices | Where-Object { $_.type -ne 'Nintendo' } | ForEach-Object { $_.name })
$wheelName = ($cab.devices | Where-Object { $_.role -eq 'wheel' -or $_.type -eq 'Driving' } | Select-Object -First 1).name
$stickName = ($cab.devices | Where-Object { $_.type -match 'Flight|Joystick' -and $_.role -notmatch 'wheel|handbrake' } | Select-Object -First 1).name

# ---- no real Wii Remote: the panel plays as the remote + nunchuk (James 2026-11-27, 2P stand-up: "mapping nunchuck for
# 8 way and buttons ... along with the standup standard buttons and joysticks"). Built from the button capture
# (manifest\panel.json): P1 stick = nunchuk stick, buttons 1-6 = B A Z C 1 2, START / COIN = + / -, the P2 stick =
# the remote's d-pad, the trackball (the mouse) = the pointer, HOME = TAB, shake = the Tron stick's second button (A2)
# when captured. Only on a cabinet without a wheel: a wheel cabinet's emulated remote stays WheelMap's.
$panelMap = $null; $sideMap = $null; $classicMap = $null
$pj = Join-Path $ManifestDir 'panel.json'
if (-not $cab.capabilities.wheel -and (Test-Path $pj)) {
  try {
    $pn = Get-Content $pj -Raw | ConvertFrom-Json
    $p1 = @($pn.players)[0]; $p2 = @($pn.players)[1]
    $dk = @{ LCONTROL = 'LCONTROL'; RCONTROL = 'RCONTROL'; LALT = 'LMENU'; RALT = 'RMENU'; LSHIFT = 'LSHIFT'; RSHIFT = 'RSHIFT'; ENTER = 'RETURN'; ESC = 'ESCAPE' }
    function DKey($k) { if (-not $k) { return $null }; $k = "$k".ToUpper() -replace '^KEYCODE_', ''; if ($dk.ContainsKey($k)) { $k = $dk[$k] }; '`' + $k + '`' }
    if ($p1 -and $p1.keys) {
      $panelMap = [ordered]@{
        'Device' = 'DInput/0/Keyboard Mouse'; 'Extension' = 'Nunchuk'
        'Buttons/B' = DKey $p1.keys.P1B1; 'Buttons/A' = DKey $p1.keys.P1B2; 'Nunchuk/Buttons/Z' = DKey $p1.keys.P1B3; 'Nunchuk/Buttons/C' = DKey $p1.keys.P1B4
        'Buttons/1' = DKey $p1.keys.P1B5; 'Buttons/2' = DKey $p1.keys.P1B6; 'Buttons/+' = DKey $p1.keys.P1START; 'Buttons/-' = DKey $p1.keys.P1COIN; 'Buttons/Home' = '`TAB`'
        'Nunchuk/Stick/Up' = DKey $p1.stick.UP; 'Nunchuk/Stick/Down' = DKey $p1.stick.DOWN; 'Nunchuk/Stick/Left' = DKey $p1.stick.LEFT; 'Nunchuk/Stick/Right' = DKey $p1.stick.RIGHT
        'IR/Up' = '`Cursor Y-`'; 'IR/Down' = '`Cursor Y+`'; 'IR/Left' = '`Cursor X-`'; 'IR/Right' = '`Cursor X+`'
      }
      if ($p2 -and $p2.stick) { $panelMap['D-Pad/Up'] = DKey $p2.stick.UP; $panelMap['D-Pad/Down'] = DKey $p2.stick.DOWN; $panelMap['D-Pad/Left'] = DKey $p2.stick.LEFT; $panelMap['D-Pad/Right'] = DKey $p2.stick.RIGHT }
      if ($pn.tronStick -and "$($pn.tronStick.secondButton)" -match '^([A-Z0-9]+)\b') { $sk = DKey $Matches[1]; foreach ($a in 'X', 'Y', 'Z') { $panelMap["Shake/$a"] = $sk } }
      foreach ($k in @($panelMap.Keys)) { if (-not $panelMap[$k]) { $panelMap.Remove($k) } }
      foreach ($d in 'Up', 'Down', 'Left', 'Right') { $panelMap["IMUAccelerometer/$d"] = '' }   # the old tilt sat on the arrows = the nunchuk stick now
      # the remote held sideways (New Super Mario Bros., Donkey Kong Country Returns): the stick drives the d-pad turned a
      # quarter, 2 / 1 on buttons 1 / 2, A / B on 3 / 4, shake on 5 and on A2
      $sideMap = [ordered]@{
        'Device' = 'DInput/0/Keyboard Mouse'; 'Extension' = 'None'
        'D-Pad/Up' = DKey $p1.stick.LEFT; 'D-Pad/Down' = DKey $p1.stick.RIGHT; 'D-Pad/Left' = DKey $p1.stick.DOWN; 'D-Pad/Right' = DKey $p1.stick.UP
        'Buttons/2' = DKey $p1.keys.P1B1; 'Buttons/1' = DKey $p1.keys.P1B2; 'Buttons/A' = DKey $p1.keys.P1B3; 'Buttons/B' = DKey $p1.keys.P1B4
        'Buttons/+' = DKey $p1.keys.P1START; 'Buttons/-' = DKey $p1.keys.P1COIN; 'Buttons/Home' = '`TAB`'
        'IR/Up' = '`Cursor Y-`'; 'IR/Down' = '`Cursor Y+`'; 'IR/Left' = '`Cursor X-`'; 'IR/Right' = '`Cursor X+`'
      }
      $shake = DKey $p1.keys.P1B5; if ($panelMap['Shake/X']) { $shake = "$shake | $($panelMap['Shake/X'])" }
      foreach ($a in 'X', 'Y', 'Z') { $sideMap["Shake/$a"] = $shake }
      foreach ($d in 'Up', 'Down', 'Left', 'Right') { $sideMap["IMUAccelerometer/$d"] = '' }
      # the Classic Controller (Smash Bros. Brawl, Monster Hunter Tri, Xenoblade): P1 stick = left stick and d-pad, P2 stick =
      # right stick, top row B A R, bottom row Y X L, ZL / ZR on P2 buttons 1 / 2
      $classicMap = [ordered]@{
        'Device' = 'DInput/0/Keyboard Mouse'; 'Extension' = 'Classic'
        'Classic/Buttons/B' = DKey $p1.keys.P1B1; 'Classic/Buttons/A' = DKey $p1.keys.P1B2; 'Classic/Triggers/R' = DKey $p1.keys.P1B3
        'Classic/Buttons/Y' = DKey $p1.keys.P1B4; 'Classic/Buttons/X' = DKey $p1.keys.P1B5; 'Classic/Triggers/L' = DKey $p1.keys.P1B6
        'Classic/Buttons/+' = DKey $p1.keys.P1START; 'Classic/Buttons/-' = DKey $p1.keys.P1COIN; 'Classic/Buttons/Home' = '`TAB`'
        'Classic/Left Stick/Up' = DKey $p1.stick.UP; 'Classic/Left Stick/Down' = DKey $p1.stick.DOWN; 'Classic/Left Stick/Left' = DKey $p1.stick.LEFT; 'Classic/Left Stick/Right' = DKey $p1.stick.RIGHT
        'Classic/D-Pad/Up' = DKey $p1.stick.UP; 'Classic/D-Pad/Down' = DKey $p1.stick.DOWN; 'Classic/D-Pad/Left' = DKey $p1.stick.LEFT; 'Classic/D-Pad/Right' = DKey $p1.stick.RIGHT
      }
      if ($p2) {
        foreach ($d in 'UP', 'DOWN', 'LEFT', 'RIGHT') { $classicMap["Classic/Right Stick/$((Get-Culture).TextInfo.ToTitleCase($d.ToLower()))"] = DKey $p2.stick.$d }
        $classicMap['Classic/Buttons/ZL'] = DKey $p2.keys.P2B1; $classicMap['Classic/Buttons/ZR'] = DKey $p2.keys.P2B2
      }
      foreach ($m in $sideMap, $classicMap) { foreach ($k in @($m.Keys)) { if ($null -eq $m[$k]) { $m.Remove($k) } } }
    }
  } catch { Write-Warning "panel.json not read for the Wii Remote mapping: $_" }
}

function Get-Ini([string]$p) { $l = New-Object Collections.Generic.List[string]; if (Test-Path $p) { foreach ($x in Get-Content $p) { $l.Add($x) } }; return , $l }   # , = return the List itself (not unrolled)
function Get-IniValue($lines, [string]$sec, [string]$key) {
  $in = $false; foreach ($l in $lines) { if ($l -match '^\s*\[(.+)\]') { $in = $Matches[1] -eq $sec; continue }; if ($in -and $l -match "^\s*$([regex]::Escape($key))\s*=\s*(.*)$") { return $Matches[1].Trim() } }; return $null
}
function Set-IniValue($lines, [string]$sec, [string]$key, [string]$val) {
  $in = $false; $secAt = -1; $end = $lines.Count
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*\[(.+)\]') { if ($in) { $end = $i; break }; $in = $Matches[1] -eq $sec; if ($in) { $secAt = $i }; continue }
    if ($in -and $lines[$i] -match "^\s*$([regex]::Escape($key))\s*=") { $lines[$i] = "$key = $val"; return }
  }
  if ($secAt -lt 0) { $lines.Add("[$sec]"); $lines.Add("$key = $val") } else { $lines.Insert($end, "$key = $val") }
}

foreach ($u in $DolphinUser) {
  $cfg = Join-Path $u 'Config'; if (-not (Test-Path $cfg)) { continue }
  $stateFile = Join-Path $cfg 'ArcadeMaster-controllers.json'
  $state = if (Test-Path $stateFile) { Get-Content $stateFile -Raw | ConvertFrom-Json } else { [pscustomobject]@{ wiimoteSource = @{}; boardSource = $null; siDevice = @{} } }
  foreach ($p in 'wiimoteSource', 'siDevice') { if ($state.$p -isnot [hashtable]) { $h = @{}; if ($state.$p) { $state.$p.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value } }; $state.$p = $h } }
  $changes = @()

  # ---- WiimoteNew.ini
  $wf = Join-Path $cfg 'WiimoteNew.ini'; $w = Get-Ini $wf; $w0 = ($w -join "`n")
  for ($i = 1; $i -le 4; $i++) {
    $sec = "Wiimote$i"; $cur = Get-IniValue $w $sec 'Source'
    if ($realSlots -contains $i) {
      if ($cur -ne '2') { if (-not $state.wiimoteSource.ContainsKey($sec)) { $state.wiimoteSource[$sec] = $(if ($cur) { $cur } else { '1' }) }; Set-IniValue $w $sec 'Source' '2'; $changes += "$sec -> Real Wii Remote" }
    } elseif ($state.wiimoteSource.ContainsKey($sec)) {
      Set-IniValue $w $sec 'Source' $state.wiimoteSource[$sec]; $changes += "$sec -> restored Source $($state.wiimoteSource[$sec])"; $state.wiimoteSource.Remove($sec)
    }
  }
  if ($panelMap) {
    $was = @(); foreach ($k in $panelMap.Keys) { $was += "$k=$(Get-IniValue $w 'Wiimote1' $k)" }
    if (-not $state.PSObject.Properties['panelBefore']) { $state | Add-Member -NotePropertyName panelBefore -NotePropertyValue ($was -join "`n") }
    $diff = $false; foreach ($k in $panelMap.Keys) { if ((Get-IniValue $w 'Wiimote1' $k) -ne $panelMap[$k]) { Set-IniValue $w 'Wiimote1' $k $panelMap[$k]; $diff = $true } }
    if ($diff) { $changes += 'Wii Remote 1 without a real remote: the panel (nunchuk = P1 stick, B A Z C 1 2 = buttons 1-6, pointer = trackball)' }
    $pd = Join-Path $cfg 'Profiles\Wiimote'; New-Item -ItemType Directory -Force $pd | Out-Null
    Set-Content (Join-Path $pd 'ArcadeMaster Panel Nunchuk.ini') (@('[Profile]') + @($panelMap.Keys | ForEach-Object { "$_ = $($panelMap[$_])" })) -Encoding ASCII
    if ($sideMap) { Set-Content (Join-Path $pd 'ArcadeMaster Panel Sideways.ini') (@('[Profile]') + @($sideMap.Keys | ForEach-Object { "$_ = $($sideMap[$_])" })) -Encoding ASCII }
    if ($classicMap) { Set-Content (Join-Path $pd 'ArcadeMaster Panel Classic.ini') (@('[Profile]') + @($classicMap.Keys | ForEach-Object { "$_ = $($classicMap[$_])" })) -Encoding ASCII }
    # each Wii game's layout (tools\wii-layouts.json, the cabinet's own choices in <manifest>\wii-layouts.json win): its
    # GameSettings\<disc id>.ini [Controls] WiimoteProfile1. Only while slot 1 is the panel - a real remote is never
    # given a panel profile (the line is taken out again when one is synced).
    $layouts = @{}
    foreach ($lf in (Join-Path $PSScriptRoot 'wii-layouts.json'), (Join-Path $ManifestDir 'wii-layouts.json')) {
      if (Test-Path $lf) { try { (Get-Content $lf -Raw | ConvertFrom-Json).PSObject.Properties | Where-Object { $_.Name -notlike '_*' } | ForEach-Object { $layouts[$_.Name] = "$($_.Value)" } } catch { Write-Warning "$lf unreadable: $_" } }
    }
    $gsDir = Join-Path $u 'GameSettings'; New-Item -ItemType Directory -Force $gsDir | Out-Null
    $panelSlot1 = $realSlots -notcontains 1
    $set = 0; $cleared = 0
    foreach ($id in $layouts.Keys) {
      $gf = Join-Path $gsDir "$id.ini"; $g1 = Get-Ini $gf; $before = $g1 -join "`n"
      $want = @{ sideways = 'ArcadeMaster Panel Sideways'; nunchuk = 'ArcadeMaster Panel Nunchuk'; classic = 'ArcadeMaster Panel Classic' }[$layouts[$id].ToLower()]
      $cur = Get-IniValue $g1 'Controls' 'WiimoteProfile1'
      if ($panelSlot1 -and $want) { if ($cur -ne $want) { Set-IniValue $g1 'Controls' 'WiimoteProfile1' $want; $set++ } }
      elseif ($cur -like 'ArcadeMaster Panel*') { for ($i = $g1.Count - 1; $i -ge 0; $i--) { if ($g1[$i] -match '^\s*WiimoteProfile1\s*=\s*ArcadeMaster Panel') { $g1.RemoveAt($i) } }; $cleared++ }
      if (($g1 -join "`n") -ne $before) { if ((Test-Path $gf) -and -not (Test-Path "$gf.am-bak")) { Copy-Item $gf "$gf.am-bak" }; Set-Content $gf $g1 -Encoding ASCII }
    }
    if ($set) { $changes += "Wii games: $set given their panel layout (sideways / nunchuk / classic)" }
    if ($cleared) { $changes += "Wii games: $cleared panel layouts taken off (a real Wii Remote is in slot 1)" }
  }
  $bcur = Get-IniValue $w 'BalanceBoard' 'Source'
  if ($board -and $bcur -ne '2') { if ($null -eq $state.boardSource) { $state.boardSource = $(if ($bcur) { $bcur } else { '0' }) }; Set-IniValue $w 'BalanceBoard' 'Source' '2'; $changes += 'Balance Board -> Real' }
  elseif (-not $board -and $null -ne $state.boardSource) { Set-IniValue $w 'BalanceBoard' 'Source' $state.boardSource; $changes += 'Balance Board restored'; $state.boardSource = $null }

  # ---- stale devices in the emulated-controller profiles (WiimoteNew / GCPadNew)
  $gf = Join-Path $cfg 'GCPadNew.ini'; $g = Get-Ini $gf
  foreach ($file in @($wf, $gf)) {
    $lines = $g; if ($file -eq $wf) { $lines = $w }
    if ($lines -isnot [Collections.Generic.List[string]]) { throw 'internal: ini list was unrolled' }
    $before = $lines -join "`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
      if ($lines[$i] -match '^(\s*Device\s*=\s*DInput/\d+/)(.+?)\s*$') {
        $prefix = $Matches[1]; $name = $Matches[2]
        if ($present -notcontains $name) {
          $repl = if ($name -match '(?i)wheel|racing|driving|G2\d\d|G9\d\d|T\d{3}|fanatec') { $wheelName } elseif ($name -match '(?i)stick|flight|hotas|throttle') { $stickName } else { $null }
          if ($repl) { $lines[$i] = $prefix + $repl; $changes += "$(Split-Path $file -Leaf): '$name' is not connected -> '$repl'" }
        }
      }
    }
    if ($file -ne $wf -and ($lines -join "`n") -ne $before) { Copy-Item $file "$file.am-bak" -ErrorAction SilentlyContinue; Set-Content $file $lines -Encoding ASCII }
  }
  if (($w -join "`n") -ne $w0) { if (-not (Test-Path "$wf.am-bak")) { Copy-Item $wf "$wf.am-bak" -ErrorAction SilentlyContinue }; Set-Content $wf $w -Encoding ASCII }

  # ---- Dolphin.ini: scanning for real Wii Remotes, GC adapter on ports 2-4
  $df = Join-Path $cfg 'Dolphin.ini'; $d = Get-Ini $df; $d0 = ($d -join "`n")
  $scan = $(if ($real -gt 0 -or $board) { 'True' } else { 'False' })
  if ((Get-IniValue $d 'Core' 'WiimoteContinuousScanning') -ne $scan) { Set-IniValue $d 'Core' 'WiimoteContinuousScanning' $scan; $changes += "continuous Wii Remote scanning = $scan" }
  if ($real -gt 0 -and (Get-IniValue $d 'BluetoothPassthrough' 'Enabled') -eq 'True') { $changes += 'WARNING: Bluetooth passthrough is on - real Wii Remotes paired in Windows are not seen; turn it off or use a DolphinBar' }
  for ($p = 1; $p -le 3; $p++) {
    $k = "SIDevice$p"; $cur = Get-IniValue $d 'Core' $k
    if ($gcad) { if ($cur -ne '12') { if (-not $state.siDevice.ContainsKey($k)) { $state.siDevice[$k] = $(if ($cur) { $cur } else { '6' }) }; Set-IniValue $d 'Core' $k '12'; $changes += "GC port $($p + 1) -> GameCube adapter" } }
    elseif ($state.siDevice.ContainsKey($k)) { Set-IniValue $d 'Core' $k $state.siDevice[$k]; $changes += "GC port $($p + 1) restored"; $state.siDevice.Remove($k) }
  }
  if (($d -join "`n") -ne $d0) { if (-not (Test-Path "$df.am-bak")) { Copy-Item $df "$df.am-bak" -ErrorAction SilentlyContinue }; Set-Content $df $d -Encoding ASCII }

  $state | ConvertTo-Json -Depth 4 | Set-Content $stateFile -Encoding UTF8
  Write-Host ("Dolphin {0}: real Wii Remotes {1}, balance board {2}, GC adapter {3}" -f $u, $real, $board, $gcad)
  if ($changes) { $changes | ForEach-Object { Write-Host "  $_" } } else { Write-Host '  no change' }
}

# ---- Cemu (Wii U) follows the real Wii Remotes too (James 2026-11-28: "shouldn't it auto select if the controller is on?").
# Each synced remote becomes an emulated Wii Remote + nunchuk on Cemu's own Wiimote API, from Controller 2 on (Controller 1
# stays the Wii U GamePad on the panel: many Wii U games need a GamePad). A slot that had its own controller gets it back
# when the remote goes. Only a Cemu that is the frontend copy's own folder (never a junction into a live frontend).
# Format and numbers from Cemu's source (src/input: InputManager, emulated/WiimoteController, api/Wiimote): emulated ids
# A 1, B 2, 1 3, 2 4, Z 5, C 6, + 7, - 8, up 9, down 10, left 11, right 12, nunchuk stick 13-16, HOME 17; the remote's
# own buttons Left 0, Right 1, Down 2, Up 3, + 4, 2 8, 1 9, B 10, A 11, - 12, HOME 15, C 16, Z 17; stick axes X+ 38,
# Y+ 39, X- 44, Y- 45; device_type 1 = with a nunchuk.
$cemus = @()
foreach ($u in $DolphinUser) {
  $emu = Split-Path (Split-Path $u)   # <frontend>\emulators
  $c = Join-Path $emu 'Cemu'
  if ((Test-Path (Join-Path $c 'Cemu.exe')) -and -not (Get-Item $c).LinkType) { $cemus += $c }
}
$liveSlots = @()
$lf = Join-Path $ManifestDir 'wii-remotes.json'
if (Test-Path $lf) { try { $liveSlots = @((Get-Content $lf -Raw | ConvertFrom-Json).slots | ForEach-Object { [int]$_ }) } catch { } }
$amProfile = 'ArcadeMaster Wii Remote'
$wiimoteMap = @( @(1, 11), @(2, 10), @(3, 9), @(4, 8), @(5, 17), @(6, 16), @(7, 4), @(8, 12), @(9, 3), @(10, 2), @(11, 0), @(12, 1), @(13, 39), @(14, 45), @(15, 44), @(16, 38), @(17, 15) )
foreach ($c in $cemus) {
  $pd = Join-Path $c 'controllerProfiles'; New-Item -ItemType Directory -Force $pd | Out-Null
  $bak = Join-Path $pd 'ArcadeMaster-before'; New-Item -ItemType Directory -Force $bak | Out-Null
  $done = @()
  for ($i = 0; $i -lt 3; $i++) {   # Controller 2-4
    $f = Join-Path $pd "controller$($i + 1).xml"
    $ours = (Test-Path $f) -and ((Get-Content $f -Raw) -match "<profile>$([regex]::Escape($amProfile))")
    if ($i -lt $liveSlots.Count) {
      $slot = $liveSlots[$i]
      $entries = ($wiimoteMap | ForEach-Object { "`t`t`t<entry>`n`t`t`t`t<mapping>$($_[0])</mapping>`n`t`t`t`t<button>$($_[1])</button>`n`t`t`t</entry>" }) -join "`n"
      $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<emulated_controller>
	<type>Wiimote</type>
	<profile>$amProfile</profile>
	<controller>
		<api>Wiimote</api>
		<uuid>$($slot - 1)</uuid>
		<display_name>Controller $slot</display_name>
		<motion>true</motion>
		<rumble>0</rumble>
		<axis>
			<deadzone>0.25</deadzone>
			<range>1</range>
		</axis>
		<rotation>
			<deadzone>0.25</deadzone>
			<range>1</range>
		</rotation>
		<trigger>
			<deadzone>0.25</deadzone>
			<range>1</range>
		</trigger>
		<mappings>
$entries
		</mappings>
	</controller>
	<device_type>1</device_type>
</emulated_controller>
"@
      if (-not $ours -and (Test-Path $f) -and -not (Test-Path (Join-Path $bak (Split-Path $f -Leaf)))) { Copy-Item $f $bak }
      $before = if (Test-Path $f) { Get-Content $f -Raw } else { '' }
      if ($before -ne $xml) { [IO.File]::WriteAllText($f, $xml.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding $false)); $done += "Controller $($i + 2) = Wii Remote in DolphinBar slot $slot" }
    } elseif ($ours) {
      $b = Join-Path $bak (Split-Path $f -Leaf)
      if (Test-Path $b) { Move-Item $b $f -Force; $done += "Controller $($i + 2) back to what it was" } else { Remove-Item $f -Force; $done += "Controller $($i + 2) off (no remote)" }
    }
  }
  Write-Host ("Cemu {0}: real Wii Remotes {1}" -f $c, $liveSlots.Count)
  if ($done) { $done | ForEach-Object { Write-Host "  $_" } } else { Write-Host '  no change' }
}
