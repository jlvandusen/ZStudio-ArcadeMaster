<#
.SYNOPSIS
  Switches on the telemetry output of the PC racing games that have one, so the bass shakers (SimHub "ShakeIt Bass
  Shakers") can play rumble strips, engine, gear changes, road texture and impacts from the game's own data.

  Codemasters games (DiRT, GRID, F1) keep it in Documents\My Games\<game>\hardwaresettings\hardware_settings_config.xml:
    newer games   <udp enabled="false" ...>                      -> enabled="true", extradata="3", ip 127.0.0.1
    older games   <motion enabled="true" ip="dbox" ... extradata="0">  -> ip 127.0.0.1, extradata="3"
                  (they were set for a D-BOX seat; extradata 3 = the full packet SimHub reads)
  Port 20777 (Codemasters' standard) is kept. Data only goes to this PC; with nothing listening it is simply dropped.
  Other telemetry games need no file change: Wreckfest, Project CARS (Options > System > Shared Memory), the truck
  simulators (SimHub installs their telemetry plugin) - see docs\12-tactile.md.
  Dry run by default; -Apply keeps <file>.am-telemetry.bak beside each changed file.
.EXAMPLE
  tools\tactile\Set-GameTelemetry.ps1            # what would change
  tools\tactile\Set-GameTelemetry.ps1 -Apply
#>
param([string]$Documents = [Environment]::GetFolderPath('MyDocuments'), [switch]$Apply)
$ErrorActionPreference = 'Stop'
$files = @(Get-ChildItem (Join-Path $Documents 'My Games') -Recurse -Depth 3 -Filter hardware_settings_config.xml -File -ErrorAction SilentlyContinue)
if (-not $files) { Write-Host 'no Codemasters games set up on this PC (no hardware_settings_config.xml)'; return }
$changed = 0
foreach ($f in $files) {
  $game = $f.Directory.Parent.Name
  $t = [IO.File]::ReadAllText($f.FullName); $new = $t
  # newer games: <udp enabled="..." ...>
  $new = [regex]::Replace($new, '<udp\b[^>]*/?>', {
      param($m) $s = $m.Value
      $s = $s -replace 'enabled="[^"]*"', 'enabled="true"'
      if ($s -match 'extradata="') { $s = $s -replace 'extradata="[^"]*"', 'extradata="3"' }
      if ($s -match '\bip="') { $s = $s -replace '\bip="[^"]*"', 'ip="127.0.0.1"' }
      $s })
  # older games: <motion enabled="..." ip="dbox" ...> (a bare <motion> wrapper element is left alone)
  $new = [regex]::Replace($new, '<motion\b[^>]*\bport="[^"]*"[^>]*/?>', {
      param($m) $s = $m.Value
      $s = $s -replace 'enabled="[^"]*"', 'enabled="true"' -replace '\bip="[^"]*"', 'ip="127.0.0.1"'
      if ($s -match 'extradata="') { $s = $s -replace 'extradata="[^"]*"', 'extradata="3"' } else { $s = $s -replace '\s*/?>$', ' extradata="3" />' }
      $s })
  if ($new -eq $t) { Write-Host ("{0,-16} telemetry already on" -f $game); continue }
  $changed++
  $was = ([regex]::Match($t, '<(udp|motion)\b[^>]*\bport="[^"]*"[^>]*/?>')).Value; $now = ([regex]::Match($new, '<(udp|motion)\b[^>]*\bport="[^"]*"[^>]*/?>')).Value
  Write-Host ("{0,-16} {1}`n{2,-16} -> {3}" -f $game, $was, '', $now)
  if ($Apply) {
    [xml]$null = $new   # still valid XML, or stop before writing
    if (-not (Test-Path "$($f.FullName).am-telemetry.bak")) { Copy-Item $f.FullName "$($f.FullName).am-telemetry.bak" }
    $bom = ([IO.File]::ReadAllBytes($f.FullName))[0] -eq 0xEF
    [IO.File]::WriteAllText($f.FullName, $new, (New-Object Text.UTF8Encoding $bom))
  }
}
Write-Host ("{0} game(s) {1}" -f $changed, $(if ($Apply) { 'switched on (backups: *.am-telemetry.bak)' } else { 'would be switched on - add -Apply' }))
