<#
.SYNOPSIS
  Runs the library move (tools\Move-ToLibrary.py) system by system in the plan's order of work, then checks one game
  per system launches from the library. James 2026-11-25: "Yes 1-3" (consume every game into ArcadeMaster's library).

  For each system: a dry run first; if it finds games and nothing is refused, --apply (single-file games with
  --files, game folders with --all). Each run writes its own move log in manifest\library-moves (undo:
  Move-ToLibrary.py --rollback <log> --apply). After a move, one game is launched through RetroBat's emulatorLauncher
  from its library path for 15 s and closed; a system whose test fails is rolled back at once.

  Not in the default list, on purpose (plan docs): MAME versions (their own step, every override binary to test),
  TeknoParrot (its pilot), PC-game folders (windows*, ports, quake, halflife, sonic*: launchers point into them),
  model2 / model3 / daphne / triforce (bundles with their emulator folders), ps3 (largest, last), magazines.
.EXAMPLE
  tools\Invoke-LibraryMoves.ps1 -Systems snes,nes -WhatIf
  tools\Invoke-LibraryMoves.ps1
#>
param(
  [string[]]$Systems = @('nes', 'megadrive', 'gba', 'gb', 'gbc', 'mastersystem', 'gamegear', 'sg1000', 'sega32x', 'pcengine', 'supergrafx',
                         'n64', 'atari2600', 'atari5200', 'atari7800', 'atari800', 'lynx', 'jaguar', 'colecovision', 'ngp', 'ngpc', 'wonderswan',
                         'wonderswancolor', 'msx1', 'msx2', 'amstradcpc', 'zxspectrum', 'c64', 'amiga500', 'x68000', 'nds', '3do',
                         'fbneo', 'neogeo', 'atomiswave', 'naomi', 'segacd', 'pcenginecd', 'neogeocd', 'jaguarcd',
                         'psx', 'saturn', 'dreamcast', 'gamecube', 'wii', 'psp', 'ps2', 'xbox', 'xbox360', 'wiiu', 'switch', 'n3ds'),
  [string]$RetroBat = 'R:\CP78\RetroBat',
  [string]$Library = 'R:\ArcadeMaster\library',
  [switch]$WhatIf
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib\AmPython.ps1'); $py = Find-AmPython
$mover = Join-Path $PSScriptRoot 'Move-ToLibrary.py'
$es = [xml](Get-Content (Join-Path $RetroBat 'emulationstation\.emulationstation\es_systems.cfg') -Raw)
$sj = Get-Content 'R:\ArcadeMaster\manifest\systems.json' -Raw | ConvertFrom-Json
$report = Join-Path 'R:\ArcadeMaster\manifest\library-moves' ("run-{0:yyyyMMdd-HHmmss}.txt" -f (Get-Date))
function Say($m) { $l = "[{0:HH:mm:ss}] {1}" -f (Get-Date), $m; Write-Host $l; Add-Content $report $l -Encoding UTF8 }

function Test-Launch([string]$sys, [string]$rom) {
  $u = $sj.systems | Where-Object system -eq $sys | Select-Object -First 1
  if (-not $u -or -not $u.uses) { return 'no emulator known - not tested' }
  $a = @('-system', $sys, '-emulator', $u.uses.emulator); if ($u.uses.core) { $a += @('-core', $u.uses.core) }; $a += @('-rom', "`"$rom`"")
  $l = Start-Process (Join-Path $RetroBat 'emulationstation\emulatorLauncher.exe') -ArgumentList $a -WorkingDirectory (Join-Path $RetroBat 'emulationstation') -PassThru
  Start-Sleep 15
  # only the launcher's own process tree is looked at and closed
  $all = @(Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name)
  $tree = @($l.Id); $grew = $true
  while ($grew) { $grew = $false; foreach ($p in $all) { if ($tree -contains $p.ParentProcessId -and $tree -notcontains $p.ProcessId) { $tree += $p.ProcessId; $grew = $true } } }
  $alive = -not $l.HasExited
  $names = (@($all | Where-Object { $tree -contains $_.ProcessId -and $_.ProcessId -ne $l.Id } | ForEach-Object Name) | Select-Object -Unique) -join ','
  # never the cabinet's own services (RetroBat's launch chain can call AmPanel / LEDBlinky)
  $keep = @($all | Where-Object { $_.Name -match '^(AmPanel|LEDBlinky|retrofe|explorer)\.exe$' } | ForEach-Object ProcessId)
  foreach ($id in ($tree | Where-Object { $keep -notcontains $_ } | Sort-Object -Descending)) { try { Stop-Process -Id $id -Force -ErrorAction Stop } catch { } }
  Start-Sleep 2
  if ($alive) { "ran ($names)" } else { "FAILED (launcher exited within 15 s: $names)" }
}

foreach ($s in $Systems) {
  $dry = & $py $mover --system $s --files 2>&1 | Out-String
  if ($dry -match 'not in plan') { Say "$s - not in the plan, skipped"; continue }
  $nFiles = if ($dry -match 'into library: (\d+) files') { [int]$Matches[1] } else { 0 }
  $dryF = & $py $mover --system $s --all 2>&1 | Out-String
  $nDirs = if ($dryF -match 'into library: (\d+) files') { [int]$Matches[1] } else { 0 }
  Say ("{0}: {1} game files, {2} files in game folders (dry run)" -f $s, $nFiles, $nDirs)
  if ($WhatIf -or ($nFiles + $nDirs) -eq 0) { continue }
  $logs = @()
  if ($nFiles) { $o = & $py $mover --system $s --files --apply --show-left 0 2>&1 | Out-String; if ($o -match 'move log: (\S.*\.tsv)') { $logs += $Matches[1].Trim() }; if ($o -match 'STOP') { Say "$s STOPPED: $(($o -split "`n" | Select-String 'STOP').Line)"; } }
  if ($nDirs) { $o = & $py $mover --system $s --all --apply --show-left 0 2>&1 | Out-String; if ($o -match 'move log: (\S.*\.tsv)') { $logs += $Matches[1].Trim() } }
  Say ("{0}: moved - logs {1}" -f $s, ($logs -join ', '))
  # one game from the library, launched the way the frontend launches it
  $exts = (($es.systemList.system | Where-Object { $_.name -eq $s } | Select-Object -First 1).extension -split '\s+' | Where-Object { $_ }) | ForEach-Object { $_.ToLower() }
  $g = Get-ChildItem (Join-Path $Library "roms\$s") -File -ErrorAction SilentlyContinue | Where-Object { $exts -contains $_.Extension.ToLower() } | Select-Object -First 1
  if (-not $g) { Say "$s - no launchable file in the library to test"; continue }
  $r = Test-Launch $s $g.FullName
  Say "$s - test $($g.Name): $r"
  if ($r -like 'FAILED*') {
    foreach ($lg in $logs) { & $py $mover --rollback $lg --apply 2>&1 | Out-String | ForEach-Object { Say "$s ROLLED BACK: $($_.Trim() -split "`n" | Select-Object -Last 1)" } }
  }
}
Say "done - report $report"
