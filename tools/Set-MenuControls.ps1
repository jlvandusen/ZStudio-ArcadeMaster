<#
.SYNOPSIS
  One menu control layout on every cabinet - standup, sit-down, racing rig, flight rig, pedestal: the same action is
  on the same button position everywhere (catalog\menu-controls.json). Writes the shared buttons into the frontend's
  controls.conf:
    - each shared action gets its keys and joystick buttons (by position: 0 = A / button 1 / Cross, 1 = B ...);
    - anything a cabinet has on top (pedal axes, touch gestures, mouse, a panel's own keys) is kept;
    - a button the shared layout gives to another action is taken off the line that had it (so one press never
      does two things), on any action line, also ones outside the shared list;
    - letter shortcuts (O P N M R F Q) only on cabinets without a control panel, and taken off their action on a
      panel cabinet: a keyboard-wired panel (I-PAC) sends letters for player 2, so R / Q would jump or quit;
    - stick-down (joyAxis1+) is added only on cabinets without pedals (a pedal axis can rest at one end); a racing
      rig keeps whatever its own file has there.
  Lines that are not actions (deadZone, touch settings) are left alone. Dry run by default: shows each change;
  -Apply backs controls.conf up once as controls.conf.am-menu-<time> and writes it.
.EXAMPLE
  tools\Set-MenuControls.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE-coinops
  tools\Set-MenuControls.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE-coinops -Apply
#>
param(
  [Parameter(Mandatory)][string]$RetroFE,
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [string]$Map,
  [switch]$Apply
)
$ErrorActionPreference = 'Stop'
if (-not $Map) { $Map = Join-Path (Split-Path $PSScriptRoot) 'catalog\menu-controls.json' }
$cc = Join-Path $RetroFE 'controls.conf'
if (-not (Test-Path -LiteralPath $cc)) { Write-Host "no controls.conf in $RetroFE"; return }
$roles = (Get-Content -LiteralPath $Map -Raw | ConvertFrom-Json).roles
# this cabinet's own changes on top of the shared layout: <manifest>\menu-controls-local.json, same shape
# ({"roles": {"letterDown": {"keys": ["Left Shift"]}}}); a role's keys / joy / letters given there replace the shared ones.
# The 2P stand-up (James, 2026-11-26): letter jump on its panel's buttons 4 and 6, not 5 and 6.
. (Join-Path $PSScriptRoot 'lib\AmMenuButtons.ps1')
$roles = Merge-AmMenuLocal $roles $ManifestDir
$cab = Join-Path $ManifestDir 'cabinet.json'
$pedals = $false; $panel = $false
if (Test-Path -LiteralPath $cab) { $c = (Get-Content -LiteralPath $cab -Raw | ConvertFrom-Json).capabilities; $pedals = [bool]($c.pedals -or $c.wheel); $panel = [bool]$c.controlPanel }

# RetroFE's input actions (UserInput.cpp MapKey): only these lines hold buttons
$actions = 'playlistUp playlistDown playlistLeft playlistRight collectionUp collectionDown collectionLeft collectionRight pageDown pageUp letterDown letterUp favPlaylist nextPlaylist prevPlaylist cyclePlaylist nextCyclePlaylist prevCyclePlaylist addPlaylist removePlaylist togglePlaylist random menu reboot saveFirstPlaylist kiosk showFps cycleCollection prevCycleCollection toggleGameInfo toggleCollectionInfo toggleBuildInfo settings quickPlaylist jbFastForward1m jbFastRewind1m jbFastForward5p jbFastRewind5p jbPause jbRestart up down left right select back quit' -split ' '

# the shared tokens, and which action owns each
$want = [ordered]@{}; $owner = @{}; $dropOnPanel = @{}
foreach ($p in $roles.PSObject.Properties) {
  $t = @($p.Value.keys) + @($p.Value.joy); if (-not $pedals) { $t += @($p.Value.joyNoPedals) }
  if (-not $panel) { $t += @($p.Value.letters) }   # letter shortcuts only where no keyboard-wired panel sends letters for player 2
  $t = @($t | Where-Object { $_ })
  $want[$p.Name] = $t
  if ($panel) { $dropOnPanel[$p.Name] = @($p.Value.letters | Where-Object { $_ } | ForEach-Object { $_.ToLower() }) }
  # a token can belong to several actions (Left = left AND prevPlaylist: in a vertical list the cross axis needs both, patch 0018)
  foreach ($x in $t) { $k = $x.ToLower(); if (-not $owner.ContainsKey($k)) { $owner[$k] = @() }; $owner[$k] += $p.Name }
}

$lines = [System.Collections.Generic.List[string]]([IO.File]::ReadAllLines($cc))
$seen = @{}; $changes = @()
for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -notmatch '^\s*([A-Za-z0-9]+)\s*=\s*(.*?)\s*$') { continue }
  $key = $Matches[1]; $val = $Matches[2]
  $act = $actions | Where-Object { $_ -ieq $key } | Select-Object -First 1
  if (-not $act) { continue }
  $old = @($val -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $new = New-Object System.Collections.Generic.List[string]; $lower = @{}
  if ($want.Contains($act)) { foreach ($t in $want[$act]) { if (-not $lower.ContainsKey($t.ToLower())) { $new.Add($t); $lower[$t.ToLower()] = 1 } }; $seen[$act] = $true }
  foreach ($t in $old) {
    $o = $owner[$t.ToLower()]
    if ($o -and $o -notcontains $act) { $changes += "${act}: '$t' removed (the shared layout puts it on $($o -join ' / '))"; continue }
    if ($script:AmMenuDropped -contains "$act|$($t.ToLower())") { $changes += "${act}: '$t' removed (this cabinet's menu-controls-local.json)"; continue }
    if ($dropOnPanel.Contains($act) -and $dropOnPanel[$act] -contains $t.ToLower()) { $changes += "${act}: '$t' removed (a keyboard-wired panel sends it for player 2)"; continue }
    if (-not $lower.ContainsKey($t.ToLower())) { $new.Add($t); $lower[$t.ToLower()] = 1 }
  }
  $line = if ($new.Count) { "$act = " + ($new -join ',') } else { "# $act = (no button for this on this cabinet)" }
  if (($old -join ',') -ne ($new -join ',')) {
    $added = @($new | Where-Object { $old -notcontains $_ }); if ($added) { $changes += "${act}: + $($added -join ', ')" }
    $lines[$i] = $line
  }
}
# shared actions the file did not have yet
foreach ($a in $want.Keys) {
  if ($seen[$a] -or -not $want[$a].Count) { continue }
  $lines.Add("$a = " + ($want[$a] -join ',')); $changes += "${a}: new line ($($want[$a] -join ', '))"
}

# A wheel's red dial through JoyToKey (the frontend's own copy): press = Enter, turn right / left = Down / Up, so it
# selects and scrolls in the menus and answers "press Enter" in games and Windows (James, 2026-11-26: "what the enter
# button is on the wheel"). JoyToKey counts buttons from 1: dial right 22, dial left 23, dial press 24.
$jtk = Join-Path $RetroFE 'JoyToKey\Profile 1.cfg'
if ($pedals -and (Test-Path -LiteralPath $jtk) -and -not (Select-String -LiteralPath $jtk -Pattern '^Button24=' -Quiet)) {
  Write-Host "  wheel dial: press = Enter, turn = Down / Up (JoyToKey)$(if (-not $Apply) { ' - dry run' })"
  if ($Apply) {
    Copy-Item -LiteralPath $jtk "$jtk.am-dial-$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
    [IO.File]::WriteAllText($jtk, ([IO.File]::ReadAllText($jtk).TrimEnd() + "`r`nButton22=1, 28:00:00:00, 0.000, 0, 0`r`nButton23=1, 26:00:00:00, 0.000, 0, 0`r`nButton24=1, 0D:00:00:00, 0.000, 0, 0`r`n"), [Text.Encoding]::ASCII)
    Get-Process JoyToKey -ErrorAction SilentlyContinue | ForEach-Object { $exe = $_.Path; Stop-Process -Id $_.Id -Force; if ($exe) { Start-Process $exe -WorkingDirectory (Split-Path $exe) -WindowStyle Minimized } }   # it reads the profile at start
  }
}

if (-not $changes) { Write-Host "menu controls: already the shared layout ($cc)"; return }
$changes | ForEach-Object { Write-Host "  $_" }
if ($Apply) {
  Copy-Item -LiteralPath $cc "$cc.am-menu-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
  [IO.File]::WriteAllText($cc, (($lines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($false)))
  Write-Host "menu controls: $($changes.Count) change(s) written to $cc (pedals: $pedals, panel: $panel)"
} else { Write-Host "menu controls: $($changes.Count) change(s) - dry run, -Apply to write (pedals: $pedals, panel: $panel)" }
