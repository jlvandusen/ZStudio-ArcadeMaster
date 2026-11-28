<#
.SYNOPSIS
  Every emulator's ArcadeMaster settings, in one go (James 2026-11-28: "can you script this config of the emulators that
  are being done"). Everything set up on the pedestal by hand or by separate tools, in the order they depend on each
  other, so any cabinet - or a fresh install - gets the same result from one command. Safe to run again: each step only
  writes what is ArcadeMaster's and keeps a .am-bak of every file the first time it changes it.

  PANEL (arcade / console cabinets - ARCADE-PEDESTAL's part)
    1. launchers   New-DirectLaunchers.py     every list runs its emulator directly; RetroArch's settings (full screen,
                                              hotkeys behind F12, P1-P4 keys, pads), bezels; Cemu's GamePad profile;
                                              PCSX2 / xemu pads; Xenia's disclaimer marked seen
    2. keys        Set-EmulatorPanelKeys.py   the panel's keys in the controls-card layout: PCSX2, xemu, Xenia, Dolphin
                                              (GameCube + an emulated Wii Remote), PPSSPP, Citra, Yuzu, Supermodel
    3. dolphin     Set-DolphinControllers.ps1 real Wii Remotes / Balance Board / GameCube adapter take over when plugged in
    4. devices     Repair-EmulatorDevices.ps1 MAME / Supermodel / Model 2 / Cemu follow controllers Windows renumbered
    5. cards       New-SystemCards.py         each system's how-to-play card from the same button table
    6. lights      New-LedColorsAuto.py       each list lights the buttons its emulator uses
  DRIVING (wheel / flight cabinets - DESKTOP-RACE2's part, James 2026-11-28)
    7. driving     the driving emulators' steps go here (WheelMap and the racing tools); until they are added this step
                   says so and does nothing
  Dry run by default (-Apply writes). -Only takes step names (launchers, keys, dolphin, devices, cards, lights, driving).
.EXAMPLE
  tools\Configure-Emulators.ps1 -RetroFE R:\ArcadeMaster\frontend\LEGENDS-am -ManifestDir R:\ArcadeMaster\manifest -Apply
#>
param(
  [Parameter(Mandatory)][string]$RetroFE,
  [Parameter(Mandatory)][string]$ManifestDir,
  [string[]]$Only,
  [switch]$Apply
)
$ErrorActionPreference = 'Stop'
$tools = $PSScriptRoot
$emuRoot = Join-Path (Split-Path $ManifestDir) 'emulators'
$log = Join-Path $ManifestDir 'configure-emulators.log'
function Say([string]$m) { Write-Host $m; Add-Content $log ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $m) -Encoding UTF8 }
$py = (Get-Command python -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch 'WindowsApps' } | Select-Object -First 1).Source
if (-not $py) { $py = Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe", "$env:ProgramFiles\Python3*\python.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
if (-not $py) { throw 'Python 3 not found - tools\Install-Prerequisites.ps1 -Runtime' }
function Want([string]$n) { -not $Only -or $Only -contains $n }
function Step([string]$name, [string]$exe, [string[]]$argv) {
  if (-not (Want $name)) { return }
  Say "--- $name"
  $ErrorActionPreference = 'Continue'
  & $exe @argv 2>&1 | ForEach-Object { "$_" } | Select-Object -Last 20 | ForEach-Object { Say "    $_" }
  if ($LASTEXITCODE) { Say "    (exit $LASTEXITCODE)" }
}
Say ("=== configure emulators on {0}: {1}" -f $env:COMPUTERNAME, $(if ($Apply) { 'APPLY' } else { 'dry run - -Apply to write' }))
if (Get-Process retrofe -ErrorAction SilentlyContinue) { Say 'note: the frontend is open - emulators read their settings when a game starts, so the next game uses them' }
$dry = if ($Apply) { @() } else { @('--dry-run') }

# PANEL
Step 'launchers' $py (@((Join-Path $tools 'New-DirectLaunchers.py'), '--retrofe', $RetroFE, '--manifest', $ManifestDir) + $dry)
if (Test-Path $emuRoot) { Step 'keys' $py (@((Join-Path $tools 'Set-EmulatorPanelKeys.py'), '--manifest', $ManifestDir, '--emulators', $emuRoot) + $dry) }
elseif (Want 'keys') { Say "--- keys`n    no $emuRoot (run Set up this PC first: it links the emulators into ArcadeMaster's tree)" }
if ($Apply) {
  Step 'dolphin' 'powershell' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $tools 'Set-DolphinControllers.ps1'), '-ManifestDir', $ManifestDir)
  $scan = Join-Path $ManifestDir 'directinput.json'
  $dev = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $tools 'Repair-EmulatorDevices.ps1'), '-RetroFE', $RetroFE, '-ManifestDir', $ManifestDir)
  if (Test-Path $scan) { $dev += @('-ScanFile', $scan) }
  Step 'devices' 'powershell' $dev
  Step 'cards' $py @((Join-Path $tools 'New-SystemCards.py'), '--retrofe', $RetroFE)
  Step 'lights' $py @((Join-Path $tools 'New-LedColorsAuto.py'), '--manifest', $ManifestDir, '--retrofe', $RetroFE)
}
else { foreach ($n in 'dolphin', 'devices', 'cards', 'lights') { if (Want $n) { Say "--- $n`n    (runs with -Apply)" } } }

# DRIVING - DESKTOP-RACE2 adds its steps here (WheelMap and the racing tools). Keep the same Step / Want pattern.
if (Want 'driving') {
  Say '--- driving'
  Say '    no driving steps yet (DESKTOP-RACE2 adds them)'
}
Say "=== done. Log: $log"
