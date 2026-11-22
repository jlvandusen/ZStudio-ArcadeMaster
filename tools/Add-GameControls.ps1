<#
.SYNOPSIS
  Enriches games.json with, per game:
    controls   - what the game expects: wheel, pedals, shifter (paddles|hpattern), handbrake, flightStick, throttle,
                 lightgun (+gun players), trackball/spinner, analog stick, buttons, players, extras (view/boost/...)
                 sources: TeknoParrot GameProfiles (ButtonName/AnalogType), MAME -listxml (also Model 2/3 sets)
    preferred  - which variant/emulator to launch and why (newest TeknoParrot install, m2emulator over MAME's
                 preliminary Model 2 driver, Supermodel for Model 3, ...); weaker duplicates get hidden=true
    fit        - native | mapped | unsupported for THIS cabinet (cabinet.json from Get-CabinetDevices.ps1) + notes
#>
param(
  [string]$Manifest = 'D:\ArcadeMaster\manifest\games.json',
  [string]$Cabinet = 'D:\ArcadeMaster\manifest\cabinet.json',
  [string]$Mame = 'E:\DRIVE Collection\emulators\MAME\mame.exe',
  [string[]]$MameSetCollections = @('MAME', 'Sega Model 2', 'Sega Model 3'),
  [string[]]$NewestTPFirst = @('E:\DRIVE Collection\emulators\TeknoParrot', 'E:\DRIVE Collection\emulators\TeknoParrotMulti', 'D:\Emulators\TeknoParrot'),
  [string]$Report = (Join-Path $PSScriptRoot '..\reports\game-controls.md')
)
$ErrorActionPreference = 'Stop'
$m = Get-Content $Manifest -Raw | ConvertFrom-Json
$cab = (Get-Content $Cabinet -Raw | ConvertFrom-Json).capabilities

function New-Controls { [ordered]@{ wheel = $false; pedals = $false; shifter = $null; handbrake = $false; flightStick = $false; throttle = $false; lightgun = $false; gunPlayers = 0; trackball = $false; spinner = $false; analogStick = $false; gamepad = $false; buttons = 0; players = 1; extras = @(); source = $null } }

# ---------- TeknoParrot GameProfile -> controls
function Get-TPControls([string]$profilePath) {
  $c = New-Controls; $c.source = "teknoparrot:$([IO.Path]::GetFileName($profilePath))"
  $t = [IO.File]::ReadAllText($profilePath)
  $names = @([regex]::Matches($t, '<ButtonName>([^<]+)</ButtonName>') | ForEach-Object { $_.Groups[1].Value.ToLower() })
  $types = @([regex]::Matches($t, '<AnalogType>([^<]+)</AnalogType>') | ForEach-Object { $_.Groups[1].Value })
  $maps = @([regex]::Matches($t, '<InputMapping>([^<]+)</InputMapping>') | ForEach-Object { $_.Groups[1].Value })
  $all = $names -join '|'
  $c.wheel = ($types -contains 'Wheel') -or ($all -match 'wheel|steer|handle')
  $c.pedals = ($types -contains 'Gas') -or ($types -contains 'Brake') -or ($all -match '\bgas\b|accel|brake pedal|\bbrake\b')
  if ($all -match '(1st|2nd|3rd|4th|5th|6th)\s*gear|gear\s*[1-6]\b|\bgear [1-6]') { $c.shifter = 'hpattern' }
  elseif ($all -match 'shift up|shift down|gear up|gear down|gear shift|gear change|\bgear\b') { $c.shifter = 'paddles' }
  $c.handbrake = $all -match 'hand ?brake|side ?brake|e-?brake|parking'
  # a real lightgun has aiming axes; "gun trigger"/"gun cannon" on a flight stick (After Burner, MachStorm) is just a fire button
  $c.lightgun = ($maps -match '^P\dLightGun$').Count -gt 0 -or ($all -match 'light ?gun|gun x|gun y')
  if ($c.lightgun) { $c.gunPlayers = @($maps | Where-Object { $_ -match '^P(\d)LightGun$' } | ForEach-Object { $_.Substring(1, 1) } | Sort-Object -Unique).Count; if ($c.gunPlayers -lt 1) { $c.gunPlayers = 1 } }
  $c.throttle = ($types -contains 'SWThrottle') -or ($all -match 'throttle|power lever|master controller power')
  $c.analogStick = ($types -match 'AnalogJoystick').Count -gt 0 -and -not $c.wheel
  $c.flightStick = $c.analogStick -and ($c.throttle -or $all -match 'stick|pitch|roll|yaw|rudder|missile|cannon')
  $c.trackball = ($maps -contains 'P1Trackball') -or ($all -match 'trackball')
  $c.buttons = @($maps | Where-Object { $_ -match '^P1Button\d+$' } | Sort-Object -Unique).Count
  $pl = @($maps | Where-Object { $_ -match '^(JvsTwo)?P(\d)' } | ForEach-Object { [int]([regex]::Match($_, 'P(\d)').Groups[1].Value) })
  if ($pl) { $c.players = ($pl | Measure-Object -Maximum).Maximum }
  $c.extras = @(foreach ($x in @(@('view', 'view'), @('boost|nitro|turbo', 'boost'), @('horn', 'horn'), @('reload', 'reload'), @('missile|lock', 'weapons'), @('kick|punch|block', 'fighting'))) { if ($all -match $x[0]) { $x[1] } })
  $c.gamepad = -not ($c.wheel -or $c.lightgun -or $c.flightStick -or $c.trackball)
  $emu = [regex]::Match($t, '<EmulatorType>([^<]+)</EmulatorType>').Groups[1].Value
  return @{ Controls = $c; Backend = $emu }
}

# ---------- MAME -listxml for all MAME-style sets in one call
$mameInfo = @{}
$sets = @($m.games | Where-Object { $_.id -match '^(.+?):(.+)$' -and $MameSetCollections -contains $Matches[1] } | ForEach-Object { ($_.id -split ':', 2)[1] } | Sort-Object -Unique)
if ($sets.Count -and (Test-Path $Mame)) {
  $xmlText = & $Mame -listxml @sets 2>$null | Out-String
  if ($xmlText -match '<mame') {
    [xml]$mx = $xmlText
    foreach ($mc in $mx.mame.machine) {
      if ($sets -notcontains $mc.name) { continue }
      $c = New-Controls; $c.source = "mame -listxml $($mc.name)"
      $in = $mc.input
      if ($in) {
        $c.players = [int]$in.players
        foreach ($ctl in @($in.control)) {
          switch ($ctl.type) {
            'paddle' { $c.wheel = $true } 'pedal' { $c.pedals = $true } 'lightgun' { $c.lightgun = $true; $c.gunPlayers = [Math]::Max(1, [int]$in.players) }
            'stick' { $c.analogStick = $true } 'trackball' { $c.trackball = $true } 'dial' { $c.spinner = $true }
            'joy' { $c.gamepad = $true } 'doublejoy' { $c.gamepad = $true } 'positional' { $c.wheel = $true }
          }
          if ($ctl.buttons) { $c.buttons = [Math]::Max($c.buttons, [int]$ctl.buttons) }
        }
      }
      $mameInfo[$mc.name] = @{ Controls = $c; Status = $mc.driver.status; Emulation = $mc.driver.emulation; Description = $mc.description }
    }
  }
}

# ---------- per game
$cabNote = @()
foreach ($g in $m.games) {
  $ctl = $null; $backend = $null; $status = $null
  # TeknoParrot: use the newest install that has this profile
  $tpVars = @($g.variants.PSObject.Properties | Where-Object { $_.Value.emulator -eq 'teknoparrot' })
  if ($tpVars) {
    foreach ($inst in $NewestTPFirst) {
      $p = Join-Path $inst "GameProfiles\$($tpVars[0].Value.profile).xml"
      if (Test-Path $p) { $r = Get-TPControls $p; $ctl = $r.Controls; $backend = $r.Backend; break }
    }
  }
  if (-not $ctl -and $g.id -match '^(.+?):(.+)$' -and $MameSetCollections -contains $Matches[1]) {
    $mi = $mameInfo[$Matches[2]]; if ($mi) { $ctl = $mi.Controls; $status = $mi.Status }
  }
  if (-not $ctl) {
    # console / PC games: gamepad, wheel-capable when racing (native DirectInput wheel support or emulator mapping)
    $ctl = New-Controls; $ctl.gamepad = $true; $ctl.source = 'default (console/PC)'
    if ($g.category -eq 'racing') { $ctl.wheel = $true; $ctl.pedals = $true; $ctl.shifter = 'paddles' }
    if ($g.category -eq 'flight') { $ctl.flightStick = $true; $ctl.throttle = $true }
  }

  # ---------- preferred variant
  $order = @($g.variants.PSObject.Properties | Where-Object { $_.Value.ok })
  $pref = $null; $reason = $null
  if ($order) {
    $rank = { param($v) switch -Regex ($v.Name) { '^standalone$' { 0 } '^default$' { 1 } '^exe$' { 2 } '^multicab' { 6 } '^launchbox' { 7 } default { 4 } } }
    $best = $order | Sort-Object { & $rank $_ } | Select-Object -First 1
    $pref = $best.Name
    $reason = switch -Regex ($best.Name) {
      '^standalone$' { 'newest TeknoParrot install (1.0.0.1919) with a working profile' }
      '^launchbox'  { 'only working setup is the older LaunchBox TeknoParrot install' }
      '^multicab'   { 'only the multicab (linked) setup works' }
      default       { 'only/primary working setup' }
    }
  }
  $emu = if ($pref) { $g.variants.$pref.emulator } else { $null }
  if (-not $emu -or $emu -match '%' -or $emu -eq 'launchbox') {
    # RetroFE launcher placeholders / LaunchBox exe entries -> the real emulator (first match wins)
    $col = if ($pref) { "$($g.variants.$pref.retrofeCollection)" } else { '' }
    $file = if ($pref) { "$($g.variants.$pref.file)" } else { '' }
    if ($col -like 'Nintendo Wii U*') { $emu = 'cemu' }
    elseif ($col -like 'Nintendo Gamecube*' -or $col -eq 'Nintendo Wii') { $emu = 'dolphin' }
    elseif ($col -like 'Sega Triforce*') { $emu = 'dolphin-triforce' }
    elseif ($col -like 'PC Games*' -or $file -match '(?i)\.(exe|bat)$') { $emu = 'pc-native' }
  }
  if ($g.id -like 'Sega Model 2:*') { $emu = 'm2emulator'; $reason = 'Sega Model 2 Emulator (MAME model2 driver is preliminary)' }
  if ($g.id -like 'Sega Model 3:*') { $emu = 'supermodel'; $reason = 'Supermodel (dedicated Model 3 emulator)' }
  if ($g.id -like 'Sega Triforce:*') { $emu = 'dolphin-triforce' }
  if ($g.id -like 'MAME:*') { $emu = 'mame'; if ($status -and $status -ne 'good') { $reason = "MAME (driver status: $status)" } }

  # ---------- cabinet fit
  $notes = New-Object System.Collections.Generic.List[string]; $fit = 'native'
  if ($ctl.lightgun -and $cab.lightguns -lt [Math]::Max(1, $ctl.gunPlayers)) { if ($cab.mice -ge 1) { $fit = 'mapped'; $notes.Add('lightgun game: mouse only, no lightgun detected') } else { $fit = 'unsupported'; $notes.Add('needs a lightgun') } }
  if ($ctl.wheel -and -not $cab.wheel) { $fit = 'mapped'; $notes.Add('wheel game on a non-wheel cabinet: analog stick steering') }
  if ($ctl.pedals -and -not $cab.pedals) { $fit = 'mapped'; $notes.Add('pedals mapped to triggers/buttons') }
  if ($ctl.flightStick -and -not $cab.flightStick) { if ($fit -eq 'native') { $fit = 'mapped' }; $notes.Add($(if ($cab.wheel) { 'flight stick mapped to wheel (roll) + pedals (throttle/brake)' } else { 'flight stick mapped to gamepad' })) }
  if ($ctl.shifter -eq 'hpattern' -and -not $cab.hShifter) { $notes.Add('uses an H-pattern shifter: map gears to buttons, or confirm the shifter with WheelMap -Capture') }
  if ($ctl.handbrake -and $cab.handbrake) { $notes.Add('handbrake supported') }
  if ($ctl.trackball -and -not $cab.trackball) { if ($fit -eq 'native') { $fit = 'mapped' }; $notes.Add('trackball mapped to mouse/stick') }
  if ($ctl.players -gt 1 -and $ctl.lightgun) { $notes.Add("$($ctl.gunPlayers)-gun game") }
  if ($status -and $status -ne 'good') { $notes.Add("emulation status: $status") }
  if ($g.wheelRotation) { $notes.Add("set wheel rotation to $($g.wheelRotation) deg") }

  $g | Add-Member -Force -NotePropertyName controls -NotePropertyValue $ctl
  $g | Add-Member -Force -NotePropertyName preferred -NotePropertyValue ([ordered]@{ variant = $pref; emulator = $emu; backend = $backend; reason = $reason })
  $g | Add-Member -Force -NotePropertyName fit -NotePropertyValue ([ordered]@{ cabinet = $env:COMPUTERNAME; level = $fit; notes = @($notes) })
}

# ---------- same set in several collections (e.g. MAME + Sega Model 2): keep the preferred one visible
$byShort = $m.games | Where-Object { $_.id -match '^(.+?):(.+)$' -and $MameSetCollections -contains $Matches[1] } | Group-Object { ($_.id -split ':', 2)[1] } | Where-Object Count -gt 1
foreach ($grp in $byShort) {
  $keep = $grp.Group | Sort-Object { switch -Wildcard ($_.id) { 'Sega Model 2:*' { 0 } 'Sega Model 3:*' { 0 } default { 1 } } } | Select-Object -First 1
  foreach ($o in $grp.Group) { if ($o.id -ne $keep.id) { $o | Add-Member -Force -NotePropertyName hidden -NotePropertyValue $true; $o | Add-Member -Force -NotePropertyName alternativeOf -NotePropertyValue $keep.id } }
}

$m | ConvertTo-Json -Depth 10 | Set-Content $Manifest -Encoding UTF8

# ---------- human-readable report
if ($Report) {
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("# Game controls, preferred emulator and cabinet fit ($env:COMPUTERNAME, $(Get-Date -Format yyyy-MM-dd))")
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('Generated by `tools/Add-GameControls.ps1` from TeknoParrot GameProfiles, MAME -listxml and the cabinet device scan (`Get-CabinetDevices.ps1`).')
  [void]$sb.AppendLine('Cabinet: ' + (($cab.PSObject.Properties | Where-Object { $_.Value -and $_.Value -ne 0 -and $_.Name -ne 'keyboard' } | ForEach-Object { $_.Name }) -join ', '))
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('| Game | Cat | Controls | Btn | Pl | Emulator (backend) | Fit | Notes |')
  [void]$sb.AppendLine('|---|---|---|---:|---:|---|---|---|')
  foreach ($g in $m.games | Where-Object { -not $_.hidden } | Sort-Object category, title) {
    $c = $g.controls
    $cs = @(if ($c.wheel) { 'wheel' }; if ($c.pedals) { 'pedals' }; if ($c.shifter) { $c.shifter }; if ($c.handbrake) { 'handbrake' }; if ($c.flightStick) { 'flight stick' }; if ($c.throttle) { 'throttle' }; if ($c.lightgun) { "lightgun x$($c.gunPlayers)" }; if ($c.trackball) { 'trackball' }; if ($c.spinner) { 'spinner' }; if ($c.gamepad -and -not $c.wheel) { 'gamepad' }) -join ', '
    $emu = if ($g.preferred.emulator) { $g.preferred.emulator + $(if ($g.preferred.backend) { " ($($g.preferred.backend))" } else { '' }) } else { '-' }
    $title = ($g.title -replace '\|', '/')
    [void]$sb.AppendLine("| $title | $($g.category) | $cs | $($c.buttons) | $($c.players) | $emu | $($g.fit.level) | $((@($g.fit.notes) -join '; ') -replace '\|', '/') |")
  }
  New-Item -ItemType Directory -Force (Split-Path $Report) | Out-Null
  [IO.File]::WriteAllText($Report, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
  Write-Host "report -> $Report"
}
$vis = @($m.games | Where-Object { -not $_.hidden })
Write-Host ("controls added to {0} games ({1} hidden duplicates) -> {2}" -f $m.games.Count, ($m.games.Count - $vis.Count), $Manifest)
$vis | Group-Object { $_.fit.level } | ForEach-Object { Write-Host ("  fit {0,-12} {1}" -f $_.Name, $_.Count) }
$vis | Group-Object { (@(if ($_.controls.wheel) { 'wheel' }; if ($_.controls.pedals) { 'pedals' }; if ($_.controls.shifter) { "shift:$($_.controls.shifter)" }; if ($_.controls.handbrake) { 'handbrake' }; if ($_.controls.flightStick) { 'flightstick' }; if ($_.controls.lightgun) { 'lightgun' }; if ($_.controls.trackball) { 'trackball' }; if ($_.controls.gamepad -and -not $_.controls.wheel) { 'gamepad' }) -join '+') } |
  Sort-Object Count -Descending | ForEach-Object { Write-Host ("  {0,3}  {1}" -f $_.Count, $_.Name) }
