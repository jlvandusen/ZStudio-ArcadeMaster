<#
.SYNOPSIS
  First run on a new PC: everything ArcadeMaster needs, found and set up in one go (docs/BACKLOG 1a, James 2026-11-27:
  "introduce the ampanel to a new environment and have it discover everything and emulators etc set it up and
  configure"; "find all the stuff and do the same thing to each thus not effecting another frontend").
  DRY RUN by default: every step reports what it would do and nothing changes. -Apply does it.

  1. discovery    Find-Emulators.py: every emulator, RetroArch core and game folder on the local drives (read-only)
  2. lists        Import-RetroBatSystems.py: a game list per system that has games and an emulator (from RetroBat
                  when there is one; its maker menus either way)
  3. launchers    New-DirectLaunchers.py: each list runs its emulator directly (no RetroBat), bezels, pads, and the
                  panel's keys in every emulator (Set-EmulatorPanelKeys.py)
  4. links        Move-OffRetroBat.py: folder links in ArcadeMaster's tree to the emulators, BIOS, saves and game
                  folders another frontend owns; that frontend keeps working (-Move: move them in instead)
  5. content      Update-CabinetContent.ps1 -Force: stories, art, tiles, hero menus, controls cards, search index;
                  New-LedColorsAuto.py: the button lights
  6. check        Test-ArcadeMaster.ps1 -Cabinet
  Log: <manifest>\first-run.log. Safe to run again: every step only adds or refreshes what is ArcadeMaster's own.
.EXAMPLE
  tools\Invoke-FirstRun.ps1 -RetroFE R:\ArcadeMaster\frontend\LEGENDS-am -ManifestDir R:\ArcadeMaster\manifest
  tools\Invoke-FirstRun.ps1 -RetroFE ... -ManifestDir ... -Apply
#>
param(
  [Parameter(Mandatory)][string]$RetroFE,
  [Parameter(Mandatory)][string]$ManifestDir,
  [string]$RetroBat,                 # found on the local drives when not given
  [switch]$Apply,
  [switch]$Move,                     # step 4: move the other frontend's folders in instead of linking them
  [switch]$SkipDiscovery,            # reuse discovery.json (a full scan takes minutes)
  [string]$ImportFolder,             # take in this folder first (tools/Import-Folder.py: an emulator, a system's games, or many)
  [string]$ImportSystem              # the system the folder's games are for, when its name does not say
)
$ErrorActionPreference = 'Stop'
$tools = $PSScriptRoot
$root = Split-Path $ManifestDir
$log = Join-Path $ManifestDir 'first-run.log'
function Say([string]$m) { Write-Host $m; Add-Content $log ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $m) -Encoding UTF8 }
$py = (Get-Command python -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch 'WindowsApps' } | Select-Object -First 1).Source
if (-not $py) { $py = Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe", "$env:ProgramFiles\Python3*\python.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
if (-not $py) { throw 'Python 3 not found - run tools\Install-Prerequisites.ps1 first' }
function Step([string]$name, [string]$exe, [string[]]$argv) {
  Say "--- $name"
  # a tool's error text is logged, never a stop (PowerShell 5.1 turns a native program's stderr into errors)
  $ErrorActionPreference = 'Continue'
  $out = & $exe @argv 2>&1 | ForEach-Object { "$_" }
  $code = $LASTEXITCODE
  foreach ($l in ($out | Select-Object -Last 25)) { Say "    $l" }
  if ($code) { Say "    (exit $code)" }
}
Say ("=== first run on {0}: {1}" -f $env:COMPUTERNAME, $(if ($Apply) { 'APPLY' } else { 'dry run - nothing changes; -Apply to do it' }))

# 0. an import: the folder is recognised, linked into the tree and recorded in discovery.json - then the steps below
#    make its lists, launchers, keys, art and lights. No full drive scan for an import.
if ($ImportFolder) {
  $imp0 = @((Join-Path $tools 'Import-Folder.py'), '--folder', $ImportFolder, '--retrofe', $RetroFE, '--manifest', $ManifestDir)
  if ($ImportSystem) { $imp0 += @('--system', $ImportSystem) }
  if ($Move) { $imp0 += '--move' }
  if ($Apply) { $imp0 += '--apply' }
  Step 'import' $py $imp0
  $SkipDiscovery = $true
}
# 1. discovery (read-only, so it runs in a dry run too)
if (-not $SkipDiscovery -or -not (Test-Path (Join-Path $ManifestDir 'discovery.json'))) {
  Step 'discovery' $py @((Join-Path $tools 'Find-Emulators.py'), '--manifest', $ManifestDir)
}

# RetroBat: given; else the one this frontend's lists already use (a PC can hold several); else the first one on a
# local fixed drive (X:\RetroBat, X:\*\RetroBat, X:\*\*\RetroBat)
if (-not $RetroBat) {
  $rb = Get-ChildItem (Join-Path $RetroFE 'launchers.windows') -Filter 'AM_RB_*.conf' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($rb) { $m = Select-String -LiteralPath $rb.FullName -Pattern '^executable\s*=\s*(.+?)\\emulationstation\\emulatorLauncher\.exe' | Select-Object -First 1; if ($m) { $RetroBat = $m.Matches[0].Groups[1].Value.Trim() } }
}
if (-not $RetroBat) {
  # every RetroBat on the local drives; the one with the most systems that hold games wins (a PC can keep an old or empty
  # one - the pedestal has R:\RetroBat next to the real R:\CP78\RetroBat): the most games, then the most systems
  $found = @()
  foreach ($d in (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { $_.DeviceID })) {
    foreach ($pat in "$d\RetroBat", "$d\*\RetroBat", "$d\*\*\RetroBat") {
      foreach ($hit in @(Get-Item $pat -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'emulationstation\emulatorLauncher.exe') })) {
        $sys = 0; $games = 0
        foreach ($rd in @(Get-ChildItem (Join-Path $hit.FullName 'roms') -Directory -ErrorAction SilentlyContinue)) {
          $g = @(Get-ChildItem $rd.FullName -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^(gamelist\.xml|_info\.txt)$' }).Count
          if ($g) { $sys++; $games += $g }
        }
        $found += [pscustomobject]@{ Path = $hit.FullName; Systems = $sys; Games = $games }
      }
    }
  }
  $found = @($found | Sort-Object Games, Systems -Descending)
  if ($found.Count) {
    $RetroBat = $found[0].Path
    if ($found.Count -gt 1) { Say ("RetroBat installs: " + (($found | ForEach-Object { "$($_.Path) ($($_.Games) games in $($_.Systems) systems)" }) -join ', ') + " - using the first; -RetroBat picks another") }
  }
}
Say $(if ($RetroBat) { "RetroBat found: $RetroBat (its emulators and games are used; RetroBat itself is never changed)" } else { 'no RetroBat: lists come from the frontend''s own systems' })

$dry = if ($Apply) { @() } else { @('--dry-run') }
# the panel's keys: learned from LEDBlinky on a cabinet; a new PC gets the standard I-PAC / MAME keyboard layout
$pj = Join-Path $ManifestDir 'panel.json'
if (-not (Test-Path $pj)) {
  if ($Apply) { Copy-Item (Join-Path $tools 'panels\default-ipac.json') $pj; Say 'panel: none learned - the standard I-PAC / MAME keyboard layout is used (panel.json)' }
  else { Say 'panel: none learned - -Apply uses the standard I-PAC / MAME keyboard layout' }
}
# 2. lists
$imp = @((Join-Path $tools 'Import-RetroBatSystems.py'), '--retrofe', $RetroFE, '--manifest', $ManifestDir, '--all') + $dry
if ($RetroBat) { $imp += @('--retrobat', $RetroBat) }
Step 'lists' $py $imp
# 2b. lists for what discovery found that no list has yet: every system on a PC without RetroBat, the extra ones beside it
Step 'lists (found)' $py (@((Join-Path $tools 'New-ListsFromDiscovery.py'), '--retrofe', $RetroFE, '--manifest', $ManifestDir) + $dry)
# 3. launchers (+ panel keys in every emulator)
Step 'launchers' $py (@((Join-Path $tools 'New-DirectLaunchers.py'), '--retrofe', $RetroFE, '--manifest', $ManifestDir) + $dry)
if (-not $Apply) { Say '    (a dry run counts only the lists that exist already: with -Apply every list above gets its launcher)' }
# 4. links (or moves)
if ($RetroBat) {
  $mv = @((Join-Path $tools 'Move-OffRetroBat.py'), '--retrobat', $RetroBat, '--dest', $root, '--retrofe', $RetroFE, '--manifest', $ManifestDir, '--mode', $(if ($Move) { 'move' } else { 'link' }))
  if ($Apply) { $mv += '--apply' }
  Step $(if ($Move) { 'moves' } else { 'links' }) $py $mv
}
# 4b. the panel's keys in every emulator: after the links, because on a fresh install <root>\emulators only exists now
if ($Apply -and (Test-Path (Join-Path $root 'emulators'))) {
  Step 'panel keys' $py @((Join-Path $tools 'Set-EmulatorPanelKeys.py'), '--manifest', $ManifestDir, '--emulators', (Join-Path $root 'emulators'))
}
# 5. content + lights (only when applying: they write art and data)
if ($Apply) {
  Step 'content' 'powershell' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $tools 'Update-CabinetContent.ps1'), '-RetroFE', $RetroFE, '-ManifestDir', $ManifestDir, '-Force')
  Step 'lights' $py @((Join-Path $tools 'New-LedColorsAuto.py'), '--manifest', $ManifestDir, '--retrofe', $RetroFE)
} else { Say '--- content, lights: written with -Apply' }
# 5b. the system helpers (GPU reset, USB self-heal ...): missing or older ones, with one admin prompt
if ($Apply) { Step 'system helpers' 'powershell' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $tools 'Install-SystemTasks.ps1'), '-ManifestDir', $ManifestDir) }
else { Step 'system helpers' 'powershell' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $tools 'Install-SystemTasks.ps1'), '-ManifestDir', $ManifestDir, '-Check') }
# 6. check
Step 'check' 'powershell' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $tools 'Test-ArcadeMaster.ps1'), '-Cabinet')
Say "=== done. Log: $log"
