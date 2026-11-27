<#
.SYNOPSIS
  Runs one ArcadeMaster maintenance command for the in-frontend TOOLS menu. Normally hosted by
  Show-ToolScreen.ps1, which draws it full screen: besides readable text this script emits structured
  "@AM {json}" lines (devices, switches, steps, tiles, images) that the tool screen turns into visuals.
  Run on its own it still works in a console (the @AM lines are hidden unless AM_VISUAL=1).
  Afterwards it refreshes the Tools list art (state shown on each item) - RetroFE restarts (reboot = yes).
#>
param(
  [Parameter(Mandatory)][ValidateSet('WheelSetup', 'FlightSetup', 'GpuDriver', 'RestartPC', 'ShutdownPC', 'EmulatorUpdates', 'MenuButtons', 'PanelTest', 'DetectControllers', 'RepairIds', 'RebuildMenus', 'ToggleFfb', 'ToggleTactile', 'ToggleSecondScreen', 'ShuffleBackgrounds', 'TogglePerfLog', 'MenuMusic', 'CabinetType', 'SystemSettings', 'SystemHealth', 'Themes', 'ResetTheme')]
  [string]$Tool,
  [Parameter(Mandatory)][string]$RetroFE,
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [int]$AutoCloseSec = 15,
  [string]$Choice                    # Themes: apply this theme without asking (Stream Deck, scripts)
)
$ErrorActionPreference = 'Continue'
$t = $PSScriptRoot
$visual = $env:AM_VISUAL -eq '1'
try { $Host.UI.RawUI.WindowTitle = "ArcadeMaster Tools - $Tool" } catch { }
function Emit([hashtable]$o) { if ($visual) { [Console]::Out.WriteLine('@AM ' + (ConvertTo-Json $o -Compress -Depth 6)) } }
function Banner([string]$s) { Write-Host ''; Write-Host ('=' * 70) -ForegroundColor Magenta; Write-Host "  $s" -ForegroundColor Cyan; Write-Host ('=' * 70) -ForegroundColor Magenta; Write-Host '' }
# runs a sibling script; its output streams through (for the tool screen) and is also returned for parsing
function Run([string]$script, [string[]]$a) {
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $t $script) @a 2>&1 | ForEach-Object { $s = "$_"; [Console]::Out.WriteLine($s); $s }
  $script:lastExit = $LASTEXITCODE
}
function Step([string]$id, [string]$label, [string]$status) { Emit @{ type = 'step'; id = $id; label = $label; status = $status } }
function Set-Setting([string]$key, [string]$value) {
  $sc = Join-Path $RetroFE 'settings.conf'; $lines = [System.Collections.Generic.List[string]](Get-Content $sc); $done = $false
  for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match "^\s*$([regex]::Escape($key))\s*=") { $lines[$i] = "$key = $value"; $done = $true } }
  if (-not $done) { $lines.Add("$key = $value") }; Set-Content $sc $lines -Encoding ascii
}
function Get-Setting([string]$key) { $m = Select-String -Path (Join-Path $RetroFE 'settings.conf') -Pattern "^\s*$([regex]::Escape($key))\s*=\s*(.*)$" | Select-Object -Last 1; if ($m) { $m.Matches[0].Groups[1].Value.Trim() } }
$cab = Join-Path $ManifestDir 'cabinet.json'; $hist = Join-Path $ManifestDir 'device-history.json'; $games = Join-Path $ManifestDir 'games.json'

function Emit-Devices {
  if (-not (Test-Path $cab)) { return }
  $c = Get-Content $cab -Raw | ConvertFrom-Json; $k = $c.capabilities
  $devs = @(foreach ($d in $c.devices) { @{ name = $d.name; role = $d.role; ffb = [bool]$d.ffb; axes = @($d.axes).Count; buttons = [int]$d.buttons; hats = [int]$d.hats } })
  if ($k.touchScreens -gt 0) { $devs += @{ name = "Touch screen x$($k.touchScreens)"; role = 'touch'; ffb = $false; axes = 0; buttons = 0; hats = 0 } }
  if ($k.keyboard) { $devs += @{ name = 'Keyboard / encoder'; role = 'keyboard'; ffb = $false; axes = 0; buttons = 0; hats = 0 } }
  Emit @{ type = 'devices'; devices = $devs }
  Emit @{ type = 'tiles'; tiles = @(
      @{ label = 'PLAYERS'; value = "$($k.players)"; icon = 'gamepad' },
      @{ label = 'MODES'; value = ((@($k.modes) | ForEach-Object { $_.ToUpper() }) -join ' + '); icon = 'wheel' },
      @{ label = 'DISPLAYS'; value = "$(@($k.displays).Count)"; icon = 'display' },
      @{ label = 'RESTRICTOR'; value = $(if ($k.restrictor) { 'YES' } else { 'NO' }); icon = 'joystick' }) }
}
function Emit-IdCheck([string[]]$out, [bool]$applied) {
  $changed = 0; $m = $out | Select-String '(\d+) profile files would change' | Select-Object -First 1; if ($m) { $changed = [int]$m.Matches[0].Groups[1].Value }
  $left = 0; $in = $false; foreach ($l in $out) { if ($l -match '^left alone') { $in = $true; continue }; if ($in -and $l -match '^\s+(\d+) x') { $left += [int]$Matches[1] } }
  Emit @{ type = 'stats'; stats = @(
      @{ label = $(if ($applied) { 'PROFILES REPAIRED' } else { 'PROFILES NEEDING REPAIR' }); value = "$changed"; tone = $(if ($changed -eq 0 -or $applied) { 'good' } else { 'warn' }) },
      @{ label = 'BINDINGS FOR UNPLUGGED DEVICES'; value = "$left"; tone = $(if ($left) { 'dim' } else { 'good' }) }) }
}
function Emit-Collections {
  $tiles = @()
  foreach ($n in 'Racing', 'Flight', 'Arcade', 'Lightgun') {
    $d = Join-Path $RetroFE "collections\$n"; if (-not (Test-Path $d)) { continue }
    $cnt = 0; Get-ChildItem $d -Filter *.sub -File | ForEach-Object { $cnt += @(Get-Content $_.FullName | Where-Object { $_.Trim() }).Count }
    $tiles += @{ label = $n.ToUpper(); suffix = ' GAMES'; value = "$cnt"; icon = @{ Racing = 'wheel'; Flight = 'joystick'; Arcade = 'gamepad'; Lightgun = 'gun' }[$n] }
  }
  if ($tiles) { Emit @{ type = 'tiles'; tiles = $tiles } }
}
function Emit-Backgrounds {
  $dir = Join-Path $RetroFE 'layouts\ArcadeMaster\collections\Main\system_artwork'
  $files = @(Get-ChildItem $dir -Filter 'am_bg*' -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.FullName })
  Emit @{ type = 'images'; title = 'MAIN MENU BACKDROPS - NEW ORDER'; files = $files }
}

switch ($Tool) {
  'WheelSetup' {
    Banner 'WHEEL SETUP - follow the prompts (turn, press, release)'
    Emit @{ type = 'wizard'; state = 'start' }
    Run 'wheelmap\WheelMap.ps1' @('-Capture', '-Name', 'G29') | Out-Null
    Emit @{ type = 'wizard'; state = 'end'; ok = ($script:lastExit -eq 0) }
    Run 'Get-CabinetDevices.ps1' @('-Out', $cab, '-History', $hist) | Out-Null
    Emit-Devices
  }
  'FlightSetup' {
    # the flight stick / HOTAS counterpart of Wheel Setup: WheelMap's flight wizard (roll, pitch, twist, throttle,
    # fire, missile ...) into the HOTAS profile, which the flight games' controls are generated from
    Banner 'FLIGHT STICK SETUP - follow the prompts (stick, twist, throttle, buttons)'
    Emit @{ type = 'wizard'; state = 'start' }
    Run 'wheelmap\WheelMap.ps1' @('-Capture', '-Name', 'HOTAS', '-CabinetType', 'flight') | Out-Null
    Emit @{ type = 'wizard'; state = 'end'; ok = ($script:lastExit -eq 0) }
    Run 'Get-CabinetDevices.ps1' @('-Out', $cab, '-History', $hist) | Out-Null
    Emit-Devices
  }
  'GpuDriver' {
    # newest NVIDIA / AMD driver for this card (legacy cards too): check, then download, verify the maker's signature and
    # install - Windows asks for admin first, the screen blinks, and a restart finishes it
    Banner 'GRAPHICS DRIVER - checking NVIDIA / AMD for the newest driver for this card'
    $gf = Join-Path $ManifestDir 'gpu-driver.json'
    Run 'Update-GpuDriver.ps1' @('-Cache', $gf) | Out-Null
    $gd = Get-Content $gf -Raw | ConvertFrom-Json
    Emit @{ type = 'tiles'; tiles = @(@($gd.cards) | ForEach-Object { @{ label = ($_.card -replace '^(NVIDIA|AMD)\s+', '').ToUpper(); value = "$($_.installed)"; suffix = $(if ($_.newer) { " -> $($_.latest)" } else { ' NEWEST' }); icon = 'display' } }) }
    if (@($gd.cards | Where-Object { $_.newer }).Count) {
      # the install runs detached (outside this panel's job, which ends when the panel closes) and moves the frontend out
      # of the way: Windows shows its admin prompt in front only for the program in front, and the prompt waited unseen
      # behind the frontend and this panel (James 2026-11-27). This panel closes so the prompt can be answered.
      $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $t 'Start-GpuDriverInstall.ps1')`" -ManifestDir `"$ManifestDir`""
      $ok = $false
      try { $r = ([wmiclass]'Win32_Process').Create($cmd, $t, $null); $ok = $r.ReturnValue -eq 0 } catch { }
      if (-not $ok) { Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', (Join-Path $t 'Start-GpuDriverInstall.ps1'), '-ManifestDir', $ManifestDir) }
      Write-Host 'The driver install is starting: the menu steps aside. Answer Windows'' admin prompt with YES (if it does not show, click the flashing shield on the taskbar). The screen may go black for a moment; the menu comes back when it is done. Restart the PC afterwards.' -ForegroundColor Yellow
      Start-Sleep -Seconds 4
      Emit @{ type = 'close'; why = 'driver install started - Windows'' admin prompt must be seen' }
    }
    else { Write-Host 'The newest driver is already installed.' -ForegroundColor Green }
  }
  'MenuButtons' {
    # the one menu layout (catalog\menu-controls.json), named for this cabinet's controllers
    Banner 'MENU BUTTONS - the same on every cabinet'
    . (Join-Path $t 'lib\AmMenuButtons.ps1')
    $mb = @(Get-AmMenuButtons (Split-Path $t) $ManifestDir)
    foreach ($m in $mb) { Write-Host ("  {0,-26} {1}" -f $m.does, $m.text) }
    Write-Host ''; Write-Host '  Move: stick / D-pad / turn the wheel.  Close the frontend: Q on a keyboard only.'
    Emit @{ type = 'tiles'; tiles = @($mb | ForEach-Object { @{ label = $_.does.ToUpper(); value = $(if ($_.parts) { $_.parts[0].names } else { '-' }); suffix = ''; icon = 'buttons' } }) }
  }
  'EmulatorUpdates' {
    # every emulator the menus use against its newest release; the ones that can be updated safely are offered one by
    # one (settings, saves and our wheel bindings kept, replaced files backed up); MAME is shown only (ROM sets),
    # TeknoParrot's own updater is opened on request
    Banner 'EMULATOR UPDATES - checking each emulator against its newest release'
    Run 'Update-Emulators.ps1' @('-RetroFE', $RetroFE, '-ManifestDir', $ManifestDir) | Out-Null
    $ev = Get-Content (Join-Path $ManifestDir 'emulator-versions.json') -Raw | ConvertFrom-Json
    Emit @{ type = 'tiles'; tiles = @(@($ev.emulators) | ForEach-Object { @{ label = ($_.name -replace ' \(.*$', '').ToUpper(); value = "$($_.installed)"; suffix = $(switch ($_.status) { 'newer' { " -> $($_.latest)" } 'newest' { ' NEWEST' } default { '' } }); icon = 'rebuild' } }) }
    $opts = @(foreach ($x in @($ev.emulators | Where-Object { $_.status -eq 'newer' -and $_.action -eq 'update' })) {
      $short = ($x.name -replace ' \(.*$', '').ToUpper(); $sub = "$($x.installed) -> $($x.latest). $($x.note)"; if ($x.warn) { $sub += ' ' + $x.warn }
      @{ id = $x.id; label = 'UPDATE ' + $short; sub = $sub }
    })
    if (@($ev.emulators | Where-Object { $_.action -eq 'own-updater' }).Count) { $opts += @{ id = 'teknoparrot'; label = 'OPEN TEKNOPARROT UPDATER'; sub = 'TeknoParrot checks its own parts; our wheel bindings (UserProfiles) are kept' } }
    $opts += @{ id = 'none'; label = 'NOT NOW'; sub = 'Nothing is changed' }
    $chosen = $null
    if ($visual -and $env:AM_WIZ_KEYFILE) {
      Emit @{ type = 'choice'; title = 'UPDATE AN EMULATOR?'; prompt = 'Old files are kept in am-update-backup in the emulator folder'; options = $opts; selected = $opts.Count - 1 }
      $deadline = (Get-Date).AddSeconds(180)
      while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $env:AM_WIZ_KEYFILE) {
          $k = (Get-Content -LiteralPath $env:AM_WIZ_KEYFILE -Raw).Trim(); Remove-Item -LiteralPath $env:AM_WIZ_KEYFILE -Force -ErrorAction SilentlyContinue
          if ($k -like 'CHOICE:*') { $chosen = $k.Substring(7); break }
        }
        Start-Sleep -Milliseconds 100
      }
    } elseif ($Choice) { $chosen = $Choice }
    if ($chosen -eq 'teknoparrot') {
      $tp = Join-Path $RetroFE 'emulators\TeknoParrot\TeknoParrotUi.exe'
      if (Test-Path $tp) { Start-Process $tp -WorkingDirectory (Split-Path $tp); Write-Host 'TeknoParrot opened: use its update check, then close it.' }
    } elseif ($chosen -and $chosen -ne 'none') {
      Run 'Update-Emulators.ps1' @('-RetroFE', $RetroFE, '-ManifestDir', $ManifestDir, '-Update', $chosen) | Out-Null
      Run 'Update-Emulators.ps1' @('-RetroFE', $RetroFE, '-ManifestDir', $ManifestDir) | Out-Null   # fresh answer for System Health
    } else { Write-Host 'Nothing changed.' }
  }
  { $_ -in 'RestartPC', 'ShutdownPC' } {
    # restart / shut down the cabinet from the Tools menu (James 2026-11-26). 10 s to change your mind: BACK closes this
    # page and ends this script before Windows is told anything. AM_SYSTEM_DRYRUN=1: says what it would do, does nothing.
    $restart = $Tool -eq 'RestartPC'
    $what = if ($restart) { 'RESTARTING' } else { 'SHUTTING DOWN' }
    Banner "$what THE CABINET - press BACK to cancel"
    for ($s = 10; $s -ge 1; $s--) {
      Emit @{ type = 'tiles'; tiles = @(@{ label = $what; value = "$s"; suffix = ' s'; icon = $(if ($restart) { 'restart' } else { 'power' }) }) }
      Write-Host ("  {0} in {1} s ... BACK cancels" -f $what.ToLower(), $s); Start-Sleep -Seconds 1
    }
    $cmd = if ($restart) { '/r' } else { '/s' }
    if ($env:AM_SYSTEM_DRYRUN -eq '1') { Write-Host "DRY RUN (AM_SYSTEM_DRYRUN=1): would run shutdown.exe $cmd /t 0 /f" -ForegroundColor Yellow }
    else { & (Join-Path $env:WINDIR 'System32\shutdown.exe') $cmd /t 0 /f /d p:0:0 /c 'ArcadeMaster Tools' }
  }
  'PanelTest' {
    # the control panel's counterpart of Wheel Setup: every control pressed shows up with its panel name and the key /
    # joystick input it sends (Watch-Inputs.ps1, read-only). Saved to manifest\input-capture.txt for mapping work.
    # AmPanel's guided capture first (Capture.cs: it knows which device sent each press and writes panel.json); the
    # key-code logger below only when AmPanel is not running
    try {
      $pc = New-Object IO.Pipes.NamedPipeClientStream('.', 'ArcadeMaster.Panel', 'InOut'); $pc.Connect(1500)
      $pw = New-Object IO.StreamWriter($pc); $pw.AutoFlush = $true; $pw.WriteLine('{"cmd":"capture"}')
      $rep = (New-Object IO.StreamReader($pc)).ReadLine(); $pc.Dispose()
      if ($rep -match '"ok":true') { Banner 'PANEL TEST - opened on the cabinet screen (AmPanel)'; return }
    } catch { }
    Banner 'PANEL TEST - press every button, move every stick, spin the dial (30 s)'
    $env:AM_VISUAL = $(if ($visual) { '1' } else { '' })
    Run 'Watch-Inputs.ps1' @('-Seconds', '30', '-Panel', (Join-Path $ManifestDir 'panel.json'), '-Out', (Join-Path $ManifestDir 'input-capture.txt')) | Out-Null
  }
  'DetectControllers' {
    Banner 'CONTROLLERS DETECTED'
    Run 'Get-CabinetDevices.ps1' @('-Out', $cab, '-History', $hist) | Out-Null
    Run 'Set-DolphinControllers.ps1' @('-ManifestDir', $ManifestDir) | Out-Null
    Emit-Devices
    Banner 'CONTROLLER ID CHECK (dry run - use Repair Controller IDs to apply)'
    $o = Run 'Update-ControllerIds.ps1' @('-RetroFE', $RetroFE, '-Cabinet', $cab, '-History', $hist)
    Emit-IdCheck $o $false
  }
  'RepairIds' {
    Banner 'REPAIR CONTROLLER IDS'
    Run 'Get-CabinetDevices.ps1' @('-Out', $cab, '-History', $hist) | Out-Null
    Emit-Devices
    $o = Run 'Update-ControllerIds.ps1' @('-RetroFE', $RetroFE, '-Cabinet', $cab, '-History', $hist, '-Apply')
    Emit-IdCheck $o $true
  }
  'RebuildMenus' {
    Banner 'REBUILD GAME MENUS'
    $plan = [ordered]@{
      devices     = @('Detect controllers', 'Get-CabinetDevices.ps1', @('-Out', $cab, '-History', $hist))
      catalog     = @('Scan game library', 'Build-Manifest.ps1', @('-RetroFE', $RetroFE, '-Out', $games))
      controls    = @('Match games to controls', 'Add-GameControls.ps1', @('-Manifest', $games, '-Cabinet', $cab))
      clips       = @('Menu videos from the games'' own movies', 'New-GameClips.ps1', @())
      collections = @('Build Racing / Flight / Arcade menus', 'New-RetroFECollections.ps1', @('-Manifest', $games, '-RetroFE', $RetroFE, '-Cabinet', $cab, '-RebuildDatabase'))
      # the menu builder lists every mode that has games; the cabinet mode then hides the ones whose controls are not
      # plugged in (as at boot) - without this, Flight showed on a wheel-only cabinet until the next boot
      series      = @('Group racing games by series', 'New-SeriesPlaylists.ps1', @('-RetroFE', $RetroFE))
      mode        = @('Show only what this cabinet can play', 'Set-CabinetMode.ps1', @('-RetroFE', $RetroFE, '-ManifestDir', $ManifestDir))
      backdrops   = @('Deal new game backdrops', 'Set-LayoutThemes.ps1', @('-LayoutDir', (Join-Path $RetroFE 'layouts\ArcadeMaster'), '-CollectionsDir', (Join-Path $RetroFE 'collections'), '-ManifestDir', $ManifestDir, '-Shuffle'))
    }
    foreach ($id in $plan.Keys) { Step $id $plan[$id][0] 'pending' }
    foreach ($id in $plan.Keys) {
      Step $id $plan[$id][0] 'run'
      Run $plan[$id][1] $plan[$id][2] | Out-Null
      Step $id $plan[$id][0] $(if ($script:lastExit -eq 0) { 'ok' } else { 'fail' })
    }
    # how many games can start, and where the reasons for the others are (Build-Manifest writes games-cant-start.txt)
    if (Test-Path $games) {
      $gl = @((Get-Content $games -Raw | ConvertFrom-Json).games)
      $myModes = @(if (Test-Path $cab) { (Get-Content $cab -Raw | ConvertFrom-Json).capabilities.modes }); if ($myModes) { $gl = @($gl | Where-Object { $myModes -contains $_.category }) }
      $cantN = @($gl | Where-Object { -not @($_.variants.PSObject.Properties | Where-Object { $_.Value.ok }).Count }).Count
      Step 'games' ("{0} of {1} games can start{2}" -f ($gl.Count - $cantN), $gl.Count, $(if ($cantN) { " - why the other $cantN can't: manifest\games-cant-start.txt" } else { '' })) 'ok'   # information, not a failure of the rebuild
    }
    # joystick-panel cabinets (pedestal / stand-up, no wheel): a button-layout card for every game (tools/New-PanelControlsArt.py)
    $capNow = if (Test-Path $cab) { (Get-Content $cab -Raw | ConvertFrom-Json).capabilities } else { $null }
    . (Join-Path $t 'lib\AmPython.ps1')
    $py = Find-AmPython   # found even when Python is not on this process's PATH
    if (-not $py) { Write-Host 'cards, stories and preview videos skipped: no Python found' }
    # learn the control panel from LEDBlinky when it lights the buttons (keys, positions, devices, clashes -> panel.json)
    if ($py) {
      Step 'panel' 'Learn the control panel from LEDBlinky' 'run'
      & $py (Join-Path $t 'Import-LEDBlinkyPanel.py') --retrofe $RetroFE --manifest $ManifestDir 2>&1 | ForEach-Object { [Console]::Out.WriteLine("$_") }
      Step 'panel' 'Learn the control panel from LEDBlinky' $(if ($LASTEXITCODE -eq 0) { 'ok' } else { 'fail' })
    }
    if ($capNow -and $capNow.controlPanel -and -not $capNow.wheel -and $py) {
      Step 'panelcards' 'Button layout cards' 'run'
      & $py (Join-Path $t 'New-PanelControlsArt.py') --retrofe $RetroFE --manifest $ManifestDir 2>&1 | ForEach-Object { [Console]::Out.WriteLine("$_") }
      Step 'panelcards' 'Button layout cards' $(if ($LASTEXITCODE -eq 0) { 'ok' } else { 'fail' })
    }
    # every cabinet: the story panel's text for each game (history.dat, the build's story files, games.json)
    if ($py) {
      Step 'stories' 'Game stories' 'run'
      & $py (Join-Path $t 'New-GameStories.py') --retrofe $RetroFE --manifest $ManifestDir 2>&1 | ForEach-Object { [Console]::Out.WriteLine("$_") }
      Step 'stories' 'Game stories' $(if ($LASTEXITCODE -eq 0) { 'ok' } else { 'fail' })
      # light preview videos + video backdrops for games added since the last run (skips everything up to date)
      # first run on a cabinet with hundreds of videos takes hours: 10 minutes per run, the next run continues
      # (every game still plays its original video meanwhile)
      $pvLabel = 'Preview videos and backdrops (10 min per run - a big first run continues next time)'
      Step 'previews' $pvLabel 'run'
      & $py (Join-Path $t 'New-PreviewMedia.py') --retrofe $RetroFE --max-minutes 10 2>&1 | ForEach-Object { [Console]::Out.WriteLine("$_") }
      Step 'previews' $pvLabel $(if ($LASTEXITCODE -eq 0) { 'ok' } else { 'fail' })
      # a marquee for every game (a real one from another build when there is one, else a placeholder) and for
      # every main-menu collection; only the missing ones are made
      Step 'marquees' 'Game marquees' 'run'
      & $py (Join-Path $t 'New-Marquees.py') --retrofe $RetroFE --manifest $ManifestDir 2>&1 | ForEach-Object { [Console]::Out.WriteLine("$_") }
      Step 'marquees' 'Game marquees' $(if ($LASTEXITCODE -eq 0) { 'ok' } else { 'fail' })
      # art too small or portrait-shaped for a full-screen background: the boot shuffle leaves it out
      Step 'lowres' 'Find blurry backgrounds' 'run'
      & $py (Join-Path $t 'Find-LowResArt.py') --retrofe $RetroFE --manifest $ManifestDir 2>&1 | ForEach-Object { [Console]::Out.WriteLine("$_") }
      Step 'lowres' 'Find blurry backgrounds' $(if ($LASTEXITCODE -eq 0) { 'ok' } else { 'fail' })
      # which UltraStik map every game wants (4-way, 2-way, diagonal, analog) - AmPanel loads it at game start
      Step 'sticks' 'UltraStik maps per game' 'run'
      & $py (Join-Path $t 'New-StickMaps.py') --manifest $ManifestDir 2>&1 | ForEach-Object { [Console]::Out.WriteLine("$_") }
      Step 'sticks' 'UltraStik maps per game' $(if ($LASTEXITCODE -eq 0) { 'ok' } else { 'fail' })
      # games where this cabinet offers more than one controller (the "which controller?" question at game start)
      Step 'choices' 'Controller choices per game' 'run'
      & $py (Join-Path $t 'New-ControllerChoices.py') --manifest $ManifestDir 2>&1 | ForEach-Object { [Console]::Out.WriteLine("$_") }
      Step 'choices' 'Controller choices per game' $(if ($LASTEXITCODE -eq 0) { 'ok' } else { 'fail' })
      # classic systems from RetroBat (C64, Amiga, NES ... Xbox) through its emulatorLauncher (docs/15); skips itself
      # on a cabinet without RetroBat
      Step 'retrobat' 'Classic systems (RetroBat)' 'run'
      & $py (Join-Path $t 'Import-RetroBatSystems.py') --retrofe $RetroFE --manifest $ManifestDir 2>&1 | ForEach-Object { [Console]::Out.WriteLine("$_") }
      # Xbox (xemu) played on the panel: keyboard -> pad map from panel.json (skips itself without xemu)
      & $py (Join-Path $t 'Set-XemuPanelMap.py') --manifest $ManifestDir 2>&1 | ForEach-Object { [Console]::Out.WriteLine("$_") }
      Step 'retrobat' 'Classic systems (RetroBat)' $(if ($LASTEXITCODE -eq 0) { 'ok' } else { 'fail' })
    }
    Emit-Collections
  }
  'ToggleFfb' {
    $on = (Get-Setting 'ffb') -match '^(yes|true|1)$'
    Set-Setting 'ffb' $(if ($on) { 'no' } else { 'yes' })
    if (-not $on -and -not (Get-Setting 'ffbDevice')) { Set-Setting 'ffbDevice' 'G29' }
    Banner ("FORCE FEEDBACK IN THE MENUS: " + $(if ($on) { 'OFF' } else { 'ON' }))
    Emit @{ type = 'toggle'; label = 'FORCE FEEDBACK'; icon = 'ffb'; on = (-not $on); detail = $(if ($on) { 'The wheel stays loose in the menus' } else { 'Centre spring, detent ticks and a thunk on select - released when a game starts' }) }
  }
  'ToggleTactile' {
    # bass shakers from the game sound (tools\tactile\Set-ShakerAudio.ps1 through VoiceMeeter): on / off, remembered
    # in manifest\tactile.json. -Choice 'strength:NN' sets the strength (0-100) and switches on.
    $tj = Join-Path $ManifestDir 'tactile.json'
    $st = if (Test-Path $tj) { Get-Content $tj -Raw | ConvertFrom-Json } else { $null }
    $strength = if ($Choice -match '^strength:(\d+)$') { [int]$Matches[1] } elseif ($st -and $st.strength) { [int]$st.strength } else { 70 }
    $wasOn = $st -and $st.on -and -not ($Choice -match '^strength:')
    $sa = Join-Path $t 'tactile\Set-ShakerAudio.ps1'
    $out = if ($wasOn) { Run 'tactile\Set-ShakerAudio.ps1' @('-Off', '-ManifestDir', $ManifestDir) } else { Run 'tactile\Set-ShakerAudio.ps1' @('-Apply', '-Strength', "$strength", '-ManifestDir', $ManifestDir) }
    $nowOn = -not $wasOn -and (($out -join "`n") -match 'shakers on|DRY RUN')
    $why = if (-not $wasOn -and -not $nowOn) { if (($out -join "`n") -match 'shaker sound card') { 'Plug the bass shakers'' USB sound card in first' } else { (($out | Select-Object -Last 1) -replace '^.*?:\s*', '') } } elseif ($nowOn) { "Game sound to the shakers at $strength% - the amp's low-pass keeps the rumble" } else { 'Game sound to the speakers only' }
    Banner ("BASS SHAKERS: " + $(if ($nowOn) { 'ON' } else { 'OFF' }))
    Write-Host "  $why"
    Emit @{ type = 'toggle'; label = 'BASS SHAKERS'; icon = 'ffb'; on = $nowOn; detail = $why }
  }
  'ToggleSecondScreen' {
    $two = (Get-Setting 'numScreens') -eq '2'
    Run 'Get-CabinetDevices.ps1' @('-Out', $cab, '-History', $hist) | Out-Null
    if ($two) { Run 'Set-RetroFEScreens.ps1' @('-RetroFE', $RetroFE, '-Cabinet', $cab, '-Single') | Out-Null } else { Run 'Set-RetroFEScreens.ps1' @('-RetroFE', $RetroFE, '-Cabinet', $cab) | Out-Null }
    $now = (Get-Setting 'numScreens') -eq '2'
    Banner ("SECOND SCREEN: numScreens = " + (Get-Setting 'numScreens'))
    $disp = @(); if (Test-Path $cab) { $disp = @((Get-Content $cab -Raw | ConvertFrom-Json).capabilities.displays | ForEach-Object { @{ w = $_.width; h = $_.height; primary = [bool]$_.primary } }) }
    Emit @{ type = 'toggle'; label = 'SECOND SCREEN'; icon = 'screen2'; on = $now; detail = $(if ($now) { 'Marquee banner, game header and touch buttons on the second display' } elseif ($disp.Count -lt 2) { 'Only one display is connected' } else { 'Everything on the main display' }) }
    Emit @{ type = 'displays'; displays = $disp; used = $(if ($now) { 2 } else { 1 }) }
  }
  'ShuffleBackgrounds' {
    Run 'Set-LayoutThemes.ps1' @('-LayoutDir', (Join-Path $RetroFE 'layouts\ArcadeMaster'), '-CollectionsDir', (Join-Path $RetroFE 'collections'), '-ManifestDir', $ManifestDir, '-Shuffle', '-BackgroundsOnly') | Out-Null
    Banner 'BACKGROUNDS SHUFFLED'
    Emit-Backgrounds
  }
  'CabinetType' {
    . (Join-Path $t 'lib\CabinetTypes.ps1')
    $cabObj = if (Test-Path $cab) { Get-Content $cab -Raw | ConvertFrom-Json } else { $null }
    $current = Get-Setting 'cabinetType'; if (-not $current) { $current = 'auto' }
    $ids = @(Get-AmCabinetChoices)
    $opts = @(foreach ($id in $ids) {
      $r = Resolve-AmCabinetType $id $cabObj '' ''
      @{ id = $id; label = $(if ($id -eq 'auto') { 'AUTO' } else { $r.title }); sub = $(if ($id -eq 'auto') { "detected: $($r.title)" } else { $r.tagline }); icons = @($r.icons); color = $r.color; color2 = $r.color2 }
    })
    $sel = [Math]::Max(0, [array]::IndexOf($ids, $current.ToLower()))
    Banner "CABINET TYPE - now: $current"
    $chosen = $null
    if ($visual -and $env:AM_WIZ_KEYFILE) {
      Emit @{ type = 'choice'; title = 'WHAT IS THIS CABINET?'; prompt = 'Shown in the boot intro after the studio logo'; options = $opts; selected = $sel }
      $deadline = (Get-Date).AddSeconds(180)
      while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $env:AM_WIZ_KEYFILE) {
          $k = (Get-Content -LiteralPath $env:AM_WIZ_KEYFILE -Raw).Trim(); Remove-Item -LiteralPath $env:AM_WIZ_KEYFILE -Force -ErrorAction SilentlyContinue
          if ($k -like 'CHOICE:*') { $chosen = $k.Substring(7); break }
        }
        Start-Sleep -Milliseconds 100
      }
    }
    if ($chosen -and $ids -contains $chosen) {
      Set-Setting 'cabinetType' $chosen
      Write-Host "cabinetType = $chosen"
    } else { Write-Host 'no change' }
    $out = Join-Path $RetroFE 'layouts\ArcadeMaster\images\intro'
    Run 'New-CabinetIntro.ps1' @('-RetroFE', $RetroFE, '-ManifestDir', $ManifestDir) | Out-Null
    Emit @{ type = 'intro'; dir = $out; setting = (Get-Setting 'cabinetType') }
  }  'SystemSettings' {
    # every cabinet setting, grouped, with its value: the frontend / cabinet ones (Set-CabinetSettings.ps1) and the
    # Windows switches (Set-CabinetSystem.ps1). The page sends TOGGLE:<id> (flip a switch, next preset of a value,
    # run an action) or TOGGLE:<id>=<value>; each id belongs to one of the two scripts.
    $owners = [ordered]@{ cab = (Join-Path $t 'Set-CabinetSettings.ps1'); sys = (Join-Path $t 'Set-CabinetSystem.ps1') }
    $listOf = { param([string]$o) $j = (& powershell -NoProfile -ExecutionPolicy Bypass -File $owners[$o] -List -RetroFE $RetroFE -ManifestDir $ManifestDir | Out-String)
      @($j | ConvertFrom-Json | ForEach-Object { $_ } | ForEach-Object {
          @{ id = $_.id; label = $_.label; detail = $_.detail; on = [bool]$_.on; owner = $o
            group = $(if ($_.group) { "$($_.group)" } else { 'WINDOWS' }); kind = $(if ($_.kind) { "$($_.kind)" } else { 'switch' })
            value = $(if ($null -ne $_.value) { "$($_.value)" } elseif ($_.on) { 'ON' } else { 'OFF' })
            confirm = $(if ($null -ne $_.confirm) { [bool]$_.confirm } else { $true }) } }) }   # Windows switches: a confirming second press
    $lists = @{ cab = @(& $listOf 'cab'); sys = @(& $listOf 'sys') }
    $all = { @($lists.cab) + @($lists.sys) }
    $toEvent = { param($items) @($items | ForEach-Object { @{ id = $_.id; label = $_.label; detail = $_.detail; on = $_.on; group = $_.group; kind = $_.kind; value = $_.value; confirm = $_.confirm } }) }
    Banner 'CABINET SETTINGS'
    if (-not ($visual -and $env:AM_WIZ_KEYFILE)) {
      $g0 = $null; foreach ($it in (& $all)) { if ($it.group -ne $g0) { Write-Host ''; Write-Host "  $($it.group)" -ForegroundColor Magenta; $g0 = $it.group }; Write-Host ("    {0,-34} {1}" -f $it.label, $it.value) }
      break
    }
    Emit @{ type = 'settings'; items = (& $toEvent (& $all)); message = 'Pick a setting and press a button to change it' }
    $deadline = (Get-Date).AddSeconds(300)
    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Milliseconds 100
      if (-not (Test-Path -LiteralPath $env:AM_WIZ_KEYFILE)) { continue }
      $k = (Get-Content -LiteralPath $env:AM_WIZ_KEYFILE -Raw).Trim(); Remove-Item -LiteralPath $env:AM_WIZ_KEYFILE -Force -ErrorAction SilentlyContinue
      if ($k -eq 'CHOICE:done') { break }
      if ($k -notlike 'TOGGLE:*') { continue }
      $id, $val = $k.Substring(7) -split '=', 2; $deadline = (Get-Date).AddSeconds(300)
      $cur = (& $all) | Where-Object { $_.id -eq $id } | Select-Object -First 1
      if (-not $cur) { continue }
      if ($id -eq 'autoLogin' -and -not $cur.on) { Emit @{ type = 'yield'; message = 'Finish the Windows sign-in box, then the arcade comes back' } }
      $out = (& powershell -NoProfile -ExecutionPolicy Bypass -File $owners[$cur.owner] -Set "$id=$(if ($val) { $val } else { 'toggle' })" -RetroFE $RetroFE -ManifestDir $ManifestDir 2>&1 | Out-String).Trim()
      Write-Host $out
      $lists[$cur.owner] = @(& $listOf $cur.owner)
      if ($id -eq 'restoreDefaults') { $lists.cab = @(& $listOf 'cab') }
      $msg = ($out -split "`r?`n" | Where-Object { $_ -match '->' } | Select-Object -Last 1) -replace '^\S+\s+->\s+', ''
      if (-not $msg) { $msg = ($out -split "`r?`n" | Select-Object -Last 1) }
      Emit @{ type = 'settings'; items = (& $toEvent (& $all)); message = "$($cur.label): $msg"; resume = $true }
    }
  }  'ResetTheme' {
    # the manual fallback when a theme went wrong: ArcadeMaster layout, the original style, no per-mode theme overrides
    Banner 'RESET THEME TO ARCADEMASTER'
    Step 'reset' 'ArcadeMaster layout, original style, no per-mode themes' 'run'
    $o = Run 'Reset-Theme.ps1' @('-RetroFE', $RetroFE, '-ManifestDir', $ManifestDir)
    Step 'reset' $(if ($script:lastExit -eq 0) { (($o | Where-Object { $_ -like 'theme reset:*' } | Select-Object -Last 1) -replace '^theme reset:\s*', '') } else { 'Reset failed - see the log' }) $(if ($script:lastExit -eq 0) { 'ok' } else { 'fail' })
  }  'SystemHealth' {
    Banner 'SYSTEM HEALTH'
    Run 'Repair-ArcadeHealth.ps1' @('-RetroFE', $RetroFE, '-ManifestDir', $ManifestDir) | Out-Null
  }
  'Themes' {
    $reg = Join-Path $ManifestDir 'themes.json'
    $list = @(); if (Test-Path $reg) { $list = @((Get-Content $reg -Raw | ConvertFrom-Json).themes | ForEach-Object { $_ }) }
    $list = @($list | Where-Object { Test-Path (Join-Path $RetroFE "layouts\$($_.name)\layout.xml") })
    # a layout's own theme.json (New-ArcadeThemes.py writes one) gives the picker a real name ("Tile Wall"), a line about it and a preview
    $tmeta = @{}
    foreach ($th in $list) { $tj = Join-Path $RetroFE "layouts\$($th.name)\theme.json"; if (Test-Path $tj) { try { $tmeta[$th.name] = Get-Content $tj -Raw | ConvertFrom-Json } catch { } } }
    $tLabel = { param($n) if ($tmeta[$n] -and $tmeta[$n].label) { [string]$tmeta[$n].label } elseif ($n -like 'CO-*') { (($n -replace '^CO-', '') -replace '-\+-', ' + ' -replace '-', ' ') + ' (imported)' } else { $n } }
    $tAbout = { param($n) if ($tmeta[$n] -and $tmeta[$n].about) { " - $($tmeta[$n].about)" } else { '' } }
    $tPreview = { param($th) if ($th.preview) { $th.preview } else { $p = Join-Path $RetroFE "layouts\$($th.name)\preview.png"; if (Test-Path $p) { $p } else { $null } } }
    $cur = Get-Setting 'layout'; $mode = $null; $mf = Join-Path $ManifestDir 'cabinet-mode.json'; if (Test-Path $mf) { $mode = ((Get-Content $mf -Raw | ConvertFrom-Json).effective -split '\+')[0] }
    Banner "THEMES - now: $cur$(if ($mode) { " (cabinet mode: $mode)" })"
    # ArcadeMaster styles (New-ThemeSkins) for this mode's family: same layout, different dials / wheel / colours - as fast
    # as the original. Chosen per family in manifest\skins.json; "random" deals a new one at every start.
    $fam = switch ($mode) { 'flight' { 'flight' } { $_ -in 'racing', 'simulation' } { 'racing' } default { $null } }
    $amDir = Join-Path $RetroFE 'layouts\ArcadeMaster'; $skinFile = Join-Path $ManifestDir 'skins.json'
    $skinCfg = $null; if (Test-Path (Join-Path $amDir 'themes.json')) { $skinCfg = (Get-Content (Join-Path $amDir 'themes.json') -Raw | ConvertFrom-Json).skins }
    $skinNow = if ($fam -and (Test-Path $skinFile)) { [string](Get-Content $skinFile -Raw | ConvertFrom-Json).$fam } else { '' }; if (-not $skinNow) { $skinNow = $fam }
    $skinOpts = @(); $skinLabel = @{}
    if ($fam -and $skinCfg -and $skinCfg.$fam) {
      foreach ($sp in $skinCfg.$fam.PSObject.Properties) {
        $skinLabel[$sp.Name] = $sp.Value.label; $inUse = $cur -eq 'ArcadeMaster' -and $skinNow -eq $sp.Name
        $pvf = Join-Path $amDir "images\skins\$($sp.Name)_preview.png"
        $skinOpts += @{ id = "skin:$($sp.Name)"; label = $sp.Value.label; sub = $(if ($inUse) { "IN USE - $($sp.Value.about)" } else { $sp.Value.about }); preview = $(if (Test-Path $pvf) { $pvf } else { $null }); icons = @(); color = $(if ($inUse) { '3ddc84' } else { 'ff2fa0' }); color2 = '2ec8ff' }
      }
      $skinOpts += @{ id = 'skin:random'; label = 'Surprise me'; sub = $(if ($skinNow -eq 'random') { 'IN USE - a different style every start' } else { "a different $fam style every start" }); preview = $null; icons = @(); color = $(if ($skinNow -eq 'random') { '3ddc84' } else { 'ffb000' }); color2 = '2ec8ff' }
    }
    if (-not $Choice -and (-not ($visual -and $env:AM_WIZ_KEYFILE) -or -not ($list -or $skinOpts))) { $skinOpts | ForEach-Object { Write-Host ("  {0,-24} {1}" -f $_.id, $_.label) }; $list | ForEach-Object { Write-Host ("  {0,-24} {1,-22} coverage {2}%" -f $_.name, (& $tLabel $_.name), $_.score) }; break }
    $chosen = $null
    if ($Choice) { $chosen = $Choice } else {
    $opts = @($skinOpts) + @($list | Sort-Object { $_.name -ne $cur }, { -[int]$_.score } | ForEach-Object { @{ id = $_.name; label = (& $tLabel $_.name); sub = $(if ($_.name -eq $cur) { "IN USE - artwork $($_.score)%$(& $tAbout $_.name)" } else { "artwork coverage $($_.score)%$(if ($_.name -like 'CO-*') { ' - imported' })$(& $tAbout $_.name)" }); preview = (& $tPreview $_); icons = @(); color = $(if ($_.name -eq $cur) { '3ddc84' } else { '2ec8ff' }); color2 = '2ec8ff' } })
    Emit @{ type = 'choice'; title = "PICK A THEME$(if ($mode) { " FOR $($mode.ToUpper()) MODE" })"; prompt = 'After the restart press START or button 1 within 15 s to keep it'; options = $opts; selected = 0 }
    $deadline = (Get-Date).AddSeconds(180)
    while ((Get-Date) -lt $deadline) { if (Test-Path -LiteralPath $env:AM_WIZ_KEYFILE) { $k = (Get-Content -LiteralPath $env:AM_WIZ_KEYFILE -Raw).Trim(); Remove-Item -LiteralPath $env:AM_WIZ_KEYFILE -Force -ErrorAction SilentlyContinue; if ($k -like 'CHOICE:*') { $chosen = $k.Substring(7); break } }; Start-Sleep -Milliseconds 100 }
    }
    # every real change waits for a confirm on screen after the restart (Start-ArcadeMaster -> Confirm-ThemeChange):
    # no START / button 1 within 15 s puts this state back (manifest\theme-pending.json)
    . (Join-Path $t 'lib\AmSettings.ps1'); . (Join-Path $t 'lib\AmTheme.ps1')
    $same = ($chosen -like 'skin:*' -and $cur -eq 'ArcadeMaster' -and $skinNow -eq $chosen.Substring(5)) -or ($chosen -eq $cur -and (-not $mode -or (Get-Setting "cabinetTheme.$mode") -eq $chosen))
    if ($chosen -and -not $same -and (($chosen -like 'skin:*' -and $fam) -or ($list | Where-Object { $_.name -eq $chosen }))) {
      Save-AmThemePending $RetroFE $ManifestDir $mode $chosen
      Write-Host 'after the restart: press START or button 1 within 15 s to keep it - otherwise the previous theme comes back'
    }
    if ($chosen -like 'skin:*' -and $fam) {
      $sk = $chosen.Substring(5)
      $sel = [ordered]@{}; if (Test-Path $skinFile) { (Get-Content $skinFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $sel[$_.Name] = $_.Value } }
      $sel[$fam] = $sk; $sel | ConvertTo-Json | Set-Content $skinFile -Encoding UTF8
      Set-Setting 'layout' 'ArcadeMaster'; if ($mode) { Set-Setting "cabinetTheme.$mode" 'ArcadeMaster' }
      Run 'Set-LayoutThemes.ps1' @('-LayoutDir', $amDir, '-CollectionsDir', (Join-Path $RetroFE 'collections'), '-ManifestDir', $ManifestDir, '-Shuffle') | Out-Null
      $name = if ($sk -eq 'random') { 'Surprise me' } else { $skinLabel[$sk] }
      $pv = Join-Path $amDir "images\skins\${sk}_preview.png"
      Emit @{ type = 'images'; title = "STYLE: $name - for $fam"; files = @(@($pv) | Where-Object { Test-Path $_ }) }
      Write-Host "skin ($fam) = $sk"
    } elseif ($chosen -and ($list | Where-Object { $_.name -eq $chosen })) {
      Set-Setting 'layout' $chosen
      if ($mode) { Set-Setting "cabinetTheme.$mode" $chosen }   # this mode keeps the theme across boots (Set-CabinetMode)
      Run 'New-CabinetIntro.ps1' @('-RetroFE', $RetroFE, '-ManifestDir', $ManifestDir, '-Layout', $chosen) | Out-Null
      $pv = ($list | Where-Object { $_.name -eq $chosen }).preview
      Emit @{ type = 'images'; title = "THEME: $($chosen -replace '^CO-','')$(if ($mode) { " - kept for $mode mode" })"; files = @($pv | Where-Object { $_ }) }
      Write-Host "layout = $chosen"
    } else { Write-Host 'no change' }
  }  'MenuMusic' {
    # James 2026-11-27: "Music too rave music etc or choices in the panel menu": each press moves to the next style
    # (off -> rave -> synthwave -> 80s -> computer -> mix -> off); -Choice <style> picks one directly
    $style = if ($Choice) { $Choice } else { 'next' }
    $out = & (Join-Path $PSScriptRoot 'Set-MenuMusic.ps1') -RetroFE $RetroFE -ManifestDir $ManifestDir -Style $style 6>&1 | Out-String
    $line = ($out -split "`r?`n" | Where-Object { $_ -match 'menu music' } | Select-Object -Last 1)
    Banner ($line.Trim().ToUpper())
    $on = $line -notmatch ': OFF'
    Emit @{ type = 'toggle'; label = 'MENU MUSIC'; icon = 'music'; on = $on; detail = $(if ($on) { ($line -replace '^.*menu music:\s*', '') + ' - press again for the next style' } else { 'Press again for RAVE, then SYNTHWAVE, 80s, COMPUTER, MIX' }) }
  }  'TogglePerfLog' {
    $on = [int]("0" + (Get-Setting 'perfLog')) -gt 0
    Set-Setting 'perfLog' $(if ($on) { '0' } else { '10' })
    Banner ("PERFORMANCE LOG: " + $(if ($on) { 'OFF' } else { 'ON (every 10 s, see log.txt [Perf] lines)' }))
    Emit @{ type = 'toggle'; label = 'PERFORMANCE LOG'; icon = 'perf'; on = (-not $on); detail = $(if ($on) { 'No frame-time logging' } else { 'Frame times, p99 and hitches written to log.txt every 10 s' }) }
  }
}

# refresh the Tools list art so each item shows its new state when RetroFE comes back
$art = Join-Path $t 'New-ToolsArt.ps1'
if (Test-Path $art) { & powershell -NoProfile -ExecutionPolicy Bypass -File $art -RetroFE $RetroFE -ManifestDir $ManifestDir -NoFanart | Out-Null }

if ($env:AM_TOOL_NOPAUSE -eq '1') { return }
Write-Host ''; Write-Host "Press any key to return to the arcade (closes by itself in $AutoCloseSec s)..." -ForegroundColor Yellow
$deadline = (Get-Date).AddSeconds($AutoCloseSec)
while ((Get-Date) -lt $deadline) { try { if ([Console]::KeyAvailable) { [void][Console]::ReadKey($true); break } } catch { break }; Start-Sleep -Milliseconds 100 }
