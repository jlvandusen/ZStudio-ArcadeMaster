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

if (-not $changes) { Write-Host "menu controls: already the shared layout ($cc)"; return }
$changes | ForEach-Object { Write-Host "  $_" }
if ($Apply) {
  Copy-Item -LiteralPath $cc "$cc.am-menu-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
  [IO.File]::WriteAllText($cc, (($lines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($false)))
  Write-Host "menu controls: $($changes.Count) change(s) written to $cc (pedals: $pedals, panel: $panel)"
} else { Write-Host "menu controls: $($changes.Count) change(s) - dry run, -Apply to write (pedals: $pedals, panel: $panel)" }
