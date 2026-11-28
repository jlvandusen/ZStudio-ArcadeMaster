<#
.SYNOPSIS
  ArcadeMaster boot launcher (replaces DRIVE.exe):
    1. deals a new random set/order of horizon backgrounds (Set-LayoutThemes -Shuffle -BackgroundsOnly)
    2. starts input helpers (JoyToKey if present)
    3. runs RetroFE and restarts it if it crashes (our build exits instead of showing a modal dialog)
  A clean exit of RetroFE (menu Exit / quit key) ends the launcher. Five crashes within 60 s also stop it,
  so a broken config can't loop forever.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File Start-ArcadeMaster.ps1 -Root D:\ArcadeMaster\frontend\DRIVE-coinops
#>
param(
  [Parameter(Mandatory)][string]$Root,                    # RetroFE root (contains retrofe\retrofe.exe, layouts\, collections\)
  [string]$Layout = 'ArcadeMaster',
  [switch]$NoShuffle,
  [int]$MaxCrashes = 5, [int]$CrashWindowSec = 60,
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [int]$WaitForWheelSec = 30,          # USB wheels often finish enumerating after logon
  [switch]$NoDeviceCheck,
  [switch]$PrepOnly,                   # run every boot step and log the timings, but do not start RetroFE
  [int]$ThemeConfirmSec = 15,          # a new theme must be confirmed on screen within this time, or it is undone
  [int]$ThemeSettleSec = 8             # ... asked once RetroFE has run this long and nothing it started is still open
)
$ErrorActionPreference = 'Stop'
# Started from a PowerShell 7 window (or by something it launched), Windows PowerShell 5.1 inherits 7's PSModulePath,
# loads 7's modules and loses built-ins such as Get-FileHash ('not recognized') - the series playlists step failed
# that way on DESKTOP-RACE2 (a Store PowerShell 7: ...\windowsapps\microsoft.powershell_7...\Modules). Keep only 5.1's own
# module folders (and non-PowerShell ones) for this boot and every tool it runs.
if ($PSVersionTable.PSVersion.Major -lt 6) { $env:PSModulePath = (($env:PSModulePath -split ';') | Where-Object { $_ -and ($_ -notmatch 'powershell' -or $_ -match 'WindowsPowerShell') }) -join ';' }
. (Join-Path $PSScriptRoot 'lib\RetroFEPaths.ps1')
. (Join-Path $PSScriptRoot 'lib\AmSettings.ps1'); . (Join-Path $PSScriptRoot 'lib\AmTheme.ps1')
$exe = Get-AmRetroFEExe $Root   # retrofe\retrofe.exe, core\retrofe.exe (CoinOPS LEGENDS / CORE) or <root>\retrofe.exe
if (-not $exe) { throw "RetroFE not found under $Root (looked in retrofe\, core\ and the root)" }
# CoinOPS builds (core\retrofe.exe) run from the build's root folder, like their own CabinetLauncher.exe: their launchers
# use paths relative to it (emulators\MAME\mame64.exe). Started inside core\, every game failed to start.
$exeDir = if ((Split-Path (Split-Path $exe) -Leaf) -eq 'core') { $Root } else { Split-Path $exe }
$log = Join-Path $Root 'arcademaster-launcher.log'
# A launcher started from a hardened shell (a remote / agent session sets NoDefaultCurrentDirectoryInExePath=1) hands that
# to RetroFE and every game: cmd then refuses to run a batch file by bare name from its own folder, which is how the
# menu's EXIT entry and the PC-game launchers start (cmd.exe /C "EXIT.bat"). On 2026-11-26 EXIT only gave an error on
# DESKTOP-RACE1 for that reason. Whatever started us, the frontend gets the normal behaviour.
Remove-Item Env:NoDefaultCurrentDirectoryInExePath -ErrorAction SilentlyContinue
function Write-Log($m) { Add-Content $log ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $m) }

$bootClock = [Diagnostics.Stopwatch]::StartNew(); $script:timings = New-Object System.Collections.Generic.List[string]
# Boot tools run inside this PowerShell, not one new powershell.exe each: a PowerShell start costs ~0.3 s on the racing
# PC and ~1.2 s on the pedestal's i3, and compiled helper types (Add-AmCachedType) stay loaded for the next tool.
# Each tool still gets its own script scope; 'exit N' in a tool ends only that tool. AM_BOOT_SEPARATE=1 goes back to
# one process per tool (to rule this out when a tool misbehaves).
$separate = $env:AM_BOOT_SEPARATE -eq '1'
function Invoke-Tool([string]$name, [string[]]$toolArgs) {
  $sw = [Diagnostics.Stopwatch]::StartNew(); $path = Join-Path $PSScriptRoot $name
  if ($separate) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $path @toolArgs 2>&1 | Out-String; $code = $LASTEXITCODE
  } else {
    # '-Name value' / '-Switch' string list -> named parameters
    $named = @{}; for ($i = 0; $i -lt $toolArgs.Count; $i++) {
      $k = $toolArgs[$i].TrimStart('-')
      if ($i + 1 -lt $toolArgs.Count -and -not $toolArgs[$i + 1].StartsWith('-')) { $named[$k] = $toolArgs[$i + 1]; $i++ } else { $named[$k] = $true }
    }
    $ErrorActionPreference = 'Continue'   # a tool that sets none gets PowerShell's default, as in its own process
    $global:LASTEXITCODE = 0; $code = 0
    try { $out = & $path @named *>&1 | Out-String; $code = $global:LASTEXITCODE }
    catch { $out = "$($_.Exception.Message)"; $code = 1 }
  }
  $script:timings.Add(('{0} {1:N1}s' -f ($name -replace '\.ps1$'), $sw.Elapsed.TotalSeconds))
  if ($code) { Write-Log "$name failed ($code): $($out.Trim())" }
  return $out
}

# ---------- latest RetroFE: a build made in the background while the frontend was open goes in now (seconds; nothing
# to do when it is current). Then the full update - pull main, compile RetroFE when the patches changed - starts in the
# background at low priority and never holds up the boot (Update-Cabinet.ps1; also every 15 min by its scheduled task).
# Not for the self-test's temporary frontends, nor with AM_NO_UPDATE=1.
if (-not $PrepOnly -and $env:AM_NO_UPDATE -ne '1' -and -not $Root.StartsWith($env:TEMP, [StringComparison]::OrdinalIgnoreCase)) {
  try { $u = Invoke-Tool 'Update-Cabinet.ps1' @('-Root', $Root, '-ManifestDir', $ManifestDir, '-DeployOnly'); if ($u -match 'installed RetroFE') { Write-Log ((($u -split "`r?`n") | Where-Object { $_ -match 'installed RetroFE' }) -join ' ') } } catch { Write-Log "update (install a waiting build) failed: $($_.Exception.Message)" }
  try {
    $pw = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if ($pw) { $up = Start-Process $pw -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $PSScriptRoot 'Update-Cabinet.ps1')`"", '-Root', "`"$Root`"", '-ManifestDir', "`"$ManifestDir`"") -WindowStyle Hidden -PassThru; try { $up.PriorityClass = 'BelowNormal' } catch { } }
  } catch { Write-Log "background update did not start: $($_.Exception.Message)" }
}

# ---------- controllers: wait for the wheel, refresh capabilities, re-point profiles if device IDs moved
if (-not $NoDeviceCheck) {
  try {
    $cabFile = Join-Path $ManifestDir 'cabinet.json'
    $prev = if (Test-Path $cabFile) { (Get-Content $cabFile -Raw | ConvertFrom-Json).capabilities } else { $null }
    $deadline = (Get-Date).AddSeconds($WaitForWheelSec)
    do {
      Invoke-Tool 'Get-CabinetDevices.ps1' @('-Out', $cabFile, '-History', (Join-Path $ManifestDir 'device-history.json')) | Out-Null
      $now = (Get-Content $cabFile -Raw | ConvertFrom-Json).capabilities
      if ($now.wheel -or -not ($prev -and $prev.wheel)) { break }
      Write-Log 'wheel not detected yet - waiting'; Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)
    if ($prev -and $prev.wheel -and -not $now.wheel) { Write-Log "WARNING: racing wheel not detected after $WaitForWheelSec s - wheel games will not respond until it is plugged in" }
    # Dolphin follows what is plugged in: real Wii Remotes / Balance Board / GC adapter, stale device names
    $dol = Invoke-Tool 'Set-DolphinControllers.ps1' @('-ManifestDir', $ManifestDir); if ($dol -match '->') { Write-Log ('dolphin: ' + (($dol -split "`r?`n" | Where-Object { $_ -match '->' } | ForEach-Object { $_.Trim() }) -join '; ')) }
    $ids = Invoke-Tool 'Update-ControllerIds.ps1' @('-RetroFE', $Root, '-Cabinet', $cabFile, '-History', (Join-Path $ManifestDir 'device-history.json'), '-Apply')
    if ($ids -match 'APPLIED: (\d+)' -and [int]$Matches[1] -gt 0) { Write-Log "controller IDs changed - re-pointed $($Matches[1]) profile files" }
    # MAME, Supermodel (Model 3), Model 2 and Cemu store a device id or number too: follow it after a reboot / port change
    $emu = Invoke-Tool 'Repair-EmulatorDevices.ps1' @('-RetroFE', $Root, '-ManifestDir', $ManifestDir, '-ScanFile', (Join-Path $ManifestDir 'directinput-scan.txt'), '-Apply')
    if ($emu -match '(\d+) file\(s\) fixed') { Write-Log ("controllers renumbered - re-pointed $($Matches[1]) emulator file(s): " + (($emu -split "`r?`n" | Where-Object { $_ -match ' -> ' } | ForEach-Object { $_.Trim() }) -join '; ')) }
    $modesNow = (@($now.modes) | Sort-Object) -join ','; $modesFile = Join-Path $ManifestDir 'last-modes.txt'
    $modesLast = if (Test-Path $modesFile) { (Get-Content $modesFile -Raw).Trim() } else { '' }
    if ($modesNow -ne $modesLast) {
      Write-Log "cabinet modes changed ('$modesLast' -> '$modesNow') - regenerating menus"
      Invoke-Tool 'New-RetroFECollections.ps1' @('-RetroFE', $Root, '-Cabinet', $cabFile, '-Manifest', (Join-Path $ManifestDir 'games.json'), '-RebuildDatabase') | Out-Null
      # the Tools list follows the controls too (Flight Stick Setup only while a flight stick is plugged in)
      if (Test-Path (Join-Path $Root 'collections\Tools')) { Invoke-Tool 'New-CabinetToolsCollection.ps1' @('-RetroFE', $Root, '-ManifestDir', $ManifestDir) | Out-Null }
      Set-Content $modesFile $modesNow
    }
  } catch { Write-Log "device check failed: $($_.Exception.Message)" }   # never block boot on diagnostics
}

# series playlists + favourite buttons: made again only when the tool or catalog\series.json changed (a pull brought a
# new version), so every cabinet gets them without a Rebuild Game Menus
try {
  $spTool = Join-Path $PSScriptRoot 'New-SeriesPlaylists.ps1'; $spCat = Join-Path (Split-Path $PSScriptRoot) 'catalog\series.json'
  if ((Test-Path (Join-Path $Root 'collections\Racing')) -and (Test-Path $spCat)) {
    $spKey = ((Get-FileHash $spTool).Hash + (Get-FileHash $spCat).Hash).Substring(0, 24); $spFile = Join-Path $ManifestDir 'series-key.txt'
    if (-not (Test-Path $spFile) -or (Get-Content $spFile -Raw).Trim() -ne $spKey) {
      $sp = Invoke-Tool 'New-SeriesPlaylists.ps1' @('-RetroFE', $Root); Set-Content $spFile $spKey
      Write-Log ('series playlists made again: ' + (($sp -split "`r?`n" | Where-Object { $_ -match '^(settings|controls)\.conf' }) -join '; '))
    }
  }
} catch { Write-Log "series playlists failed: $($_.Exception.Message)" }
# the filter bar's banners (ALL GAMES, FAVOURITES, each series ...): a wheel cabinet never ran the panel card tool that
# also draws them, so its filter bar was empty (RACE1, 2026-11-27). Made here when a playlist has no banner yet.
try {
  $bnDir = Join-Path $Root 'layouts\ArcadeMaster\collections\_common\medium_artwork\playlist'
  $bnNeed = @('all', 'favorites') + @(Get-ChildItem (Join-Path $Root 'collections') -Directory -ErrorAction SilentlyContinue | ForEach-Object { Get-ChildItem (Join-Path $_.FullName 'playlists') -Filter *.txt -File -ErrorAction SilentlyContinue | ForEach-Object BaseName })
  if (@($bnNeed | Select-Object -Unique | Where-Object { -not (Test-Path -LiteralPath (Join-Path $bnDir "$_.png")) }).Count) {
    . (Join-Path $PSScriptRoot 'lib\AmPython.ps1'); $bnPy = Find-AmPython
    if ($bnPy) { $bn = & $bnPy (Join-Path $PSScriptRoot 'New-PanelControlsArt.py') --retrofe $Root --manifest $ManifestDir --banners-only 2>&1 | Out-String; Write-Log ($bn.Trim() -split "`r?`n" | Select-Object -Last 1) }
  }
} catch { Write-Log "filter banners failed: $($_.Exception.Message)" }
# the main menu follows menu.txt (Racing / Flight ... first, as New-RetroFECollections orders it) instead of A-Z, which
# put EXIT first: every cabinet booted with EXIT selected and an idle cabinet sat on it
try {
  $mainConf = Join-Path $Root 'collections\Main\settings.conf'
  if ((Test-Path $mainConf) -and (Select-String -LiteralPath $mainConf -Pattern '^\s*list\.menuSort\s*=\s*(yes|true)' -Quiet)) {
    if (-not (Test-Path "$mainConf.am-sort-bak")) { Copy-Item -LiteralPath $mainConf "$mainConf.am-sort-bak" }
    $mc0 = [IO.File]::ReadAllText($mainConf) -replace '(?m)^(\s*list\.menuSort\s*=\s*)(yes|true)', '${1}no'
    [IO.File]::WriteAllText($mainConf, $mc0); Write-Log 'main menu: follows menu.txt order (was A-Z, which put EXIT first)'
  }
} catch { Write-Log "main menu order failed: $($_.Exception.Message)" }
# one menu control layout on every cabinet type (catalog\menu-controls.json); quick and silent once it matches
try { $mc = Invoke-Tool 'Set-MenuControls.ps1' @('-RetroFE', $Root, '-ManifestDir', $ManifestDir, '-Apply'); if ($mc -match 'change\(s\) written') { Write-Log ('menu controls: ' + (($mc -split "`r?`n" | Where-Object { $_ -match '^\s+\S' } | ForEach-Object { $_.Trim() }) -join '; ')) } } catch { Write-Log "menu controls failed: $($_.Exception.Message)" }

# the main menu's wheel shows the wheel this cabinet really has (G HUB's picture of it); redrawn only when it changed
try { $rw = Invoke-Tool 'New-RealWheelArt.ps1' @('-RetroFE', $Root, '-ManifestDir', $ManifestDir, '-Layout', $Layout); if ($rw -match '->|removed') { Write-Log (($rw -split "`r?`n" | Where-Object { $_ -match 'real wheel' }) -join ' ') } } catch { Write-Log "real wheel art failed: $($_.Exception.Message)" }
# a hand-held controller is plugged in: the console lists show that controller's card; none: the panel's cards (tools\Set-PadCards.ps1)
try { $pc = Invoke-Tool 'Set-PadCards.ps1' @('-RetroFE', $Root); if ($pc -match 'shown on|are back') { Write-Log (($pc -split "`r?`n" | Where-Object { $_ -match 'pad cards' }) -join ' ') } } catch { Write-Log "pad cards failed: $($_.Exception.Message)" }

# the per-game controls cards (the real G29 with the game's buttons numbered, the pedals, the legend) are drawn from the
# LIVE bindings: remade when a wheel cabinet has none yet, or a TeknoParrot binding is newer than the cards (Wheel Setup,
# a profile edit). James 2026-11-27: "the bottom controller preview is back to default and not the detected wheel" -
# RACE2 had never had them made (New-GameControlsArt was never run there). Before RetroFE starts, which only finds art
# folders that exist at its start. About 10 s, and only when needed.
try {
  $cm = Join-Path $ManifestDir 'cabinet-mode.json'
  $wheelCab = (Test-Path $cm) -and ("$((Get-Content $cm -Raw | ConvertFrom-Json).effective)" -match 'racing|simulation|flight')
  if ($wheelCab) {
    $cards = Join-Path $Root 'collections\TeknoParrot\medium_artwork\am_controls_wheel'
    $newest = if (Test-Path $cards) { (Get-ChildItem $cards -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime } else { $null }
    $prof = Get-ChildItem (Join-Path $Root 'emulators\TeknoParrot\UserProfiles') -Filter *.xml -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest -or ($prof -and $prof.LastWriteTime -gt $newest)) {
      $ca = Invoke-Tool 'New-GameControlsArt.ps1' @('-RetroFE', $Root)
      Write-Log ("controls cards remade ($(if (-not $newest) { 'none yet' } else { "$($prof.Name) is newer" })): " + (($ca -split "`r?`n" | Where-Object { $_ -match 'controls cards:' }) -join ' '))
    }
  }
} catch { Write-Log "controls cards failed: $($_.Exception.Message)" }

if (-not $NoShuffle) {
  try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & (Join-Path $PSScriptRoot 'Set-LayoutThemes.ps1') -LayoutDir (Join-Path $Root "layouts\$Layout") -CollectionsDir (Join-Path $Root 'collections') -ManifestDir $ManifestDir -Shuffle -BackgroundsOnly | Out-Null
    $script:timings.Add(('Shuffle {0:N1}s' -f $sw.Elapsed.TotalSeconds)); Write-Log 'backgrounds shuffled'
  } catch { Write-Log "shuffle failed: $($_.Exception.Message)" }   # never block boot on cosmetics
}

# boot intro: render the cabinet-type title card (settings.conf cabinetType, auto = detected hardware)
# cabinet mode follows the hardware (racing stays racing with a wheel; flight stick instead -> flight cab ...)
try { $mode = Invoke-Tool 'Set-CabinetMode.ps1' @('-RetroFE', $Root, '-ManifestDir', $ManifestDir); Write-Log (($mode -split "`r?`n" | Where-Object { $_.Trim() }) -join ' | ') } catch { Write-Log "cabinet mode failed: $($_.Exception.Message)" }
# play time, Most played and save backups: start / end hooks in every game launcher (idempotent; menus rebuilt above
# rewrote some launchers)
try { $h = & (Join-Path $PSScriptRoot 'Set-GameHooks.ps1') -RetroFE $Root -ManifestDir $ManifestDir -Quiet 6>&1 | Out-String; if ($h.Trim()) { Write-Log $h.Trim() } } catch { Write-Log "game hooks failed: $($_.Exception.Message)" }
# a game that crashed with the pointer hidden (Set-GameCursor) must not leave it hidden: show it at every boot
try { & (Join-Path $PSScriptRoot 'Set-GameCursor.ps1') -Show | Out-Null } catch { }
# Game of the Month (A18): a featured playlist per menu, picked once a month (silent when the month has not changed)
try { $gm = & (Join-Path $PSScriptRoot 'New-FeaturedPlaylist.ps1') -RetroFE $Root -ManifestDir $ManifestDir 6>&1 | Out-String; if ($gm.Trim()) { Write-Log $gm.Trim() } } catch { Write-Log "game of the month failed: $($_.Exception.Message)" }
# fleet view: what this cabinet runs, written to the NAS for Compare-Cabinets.ps1 (never blocks the boot)
try { & (Join-Path $PSScriptRoot 'Write-CabinetState.ps1') -Root $Root -ManifestDir $ManifestDir 6>$null | Out-Null } catch { Write-Log "cabinet state failed: $($_.Exception.Message)" }
# layout options from Tools > Cabinet Settings (story panel, control reminders, menu sounds, video volume): only on a
# cabinet that changed one (manifest\ui.json); re-applied every boot so a layout updated from the repo keeps them
if (Test-Path (Join-Path $ManifestDir 'ui.json')) { try { $lu = Invoke-Tool 'Set-LayoutUi.ps1' @('-RetroFE', $Root, '-ManifestDir', $ManifestDir); if ($lu -match 'updated|WARNING') { Write-Log (($lu -split "`r?`n" | Where-Object { $_.Trim() }) -join ' | ') } } catch { Write-Log "layout options failed: $($_.Exception.Message)" } }
$active = ((Select-String -Path (Join-Path $Root 'settings.conf') -Pattern '^\s*layout\s*=\s*(.+)$' | Select-Object -Last 1).Matches[0].Groups[1].Value).Trim()
# the intro card and the Tools list art (live state: devices, switches, game counts) write different files, so they
# render side by side, each in its own powershell. The boot waits for the intro (max 60 s); the Tools art is only seen
# inside Tools (never during the intro), so it finishes in the background at low priority while RetroFE starts - its
# images are swapped in atomically
# the intro is only redrawn when its key changed (type, title, hardware or the drawing scripts): a PowerShell start and
# the C# drawing helpers cost ~2 s of every boot for a card that is usually the same as last time
$introCurrent = $false
try { . (Join-Path $PSScriptRoot 'lib\CabinetTypes.ps1'); $introCurrent = Test-AmIntroCurrent (Join-Path $Root "layouts\$active\images\intro") (Get-AmIntroSpec $Root $ManifestDir '') } catch { Write-Log "intro check failed: $($_.Exception.Message)" }
$parallel = @(if (-not $introCurrent) { @{ name = 'New-CabinetIntro'; wait = $true; args = @('-RetroFE', $Root, '-ManifestDir', $ManifestDir, '-Layout', $active) } })
if (Test-Path (Join-Path $Root 'collections\Tools\ARCADEMASTER-TOOLS.txt')) { $parallel += @{ name = 'New-ToolsArt'; wait = $false; args = @('-RetroFE', $Root, '-ManifestDir', $ManifestDir, '-NoFanart') } }
$sw = [Diagnostics.Stopwatch]::StartNew()
$procs = foreach ($t in $parallel) {
  try {
    $errFile = Join-Path $env:TEMP ("am-boot-{0}.err" -f $t.name)
    $quoted = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot "$($t.name).ps1")) + $t.args | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }
    $proc = Start-Process powershell -ArgumentList ($quoted -join ' ') -WindowStyle Hidden -PassThru -RedirectStandardError $errFile -RedirectStandardOutput "$errFile.out"
    [void]$proc.Handle   # open the handle now, or ExitCode stays empty after the process ends
    if (-not $t.wait) { try { $proc.PriorityClass = 'BelowNormal' } catch { } }
    @{ name = $t.name; wait = $t.wait; err = $errFile; p = $proc }
  } catch { Write-Log "$($t.name) failed to start: $($_.Exception.Message)" }
}
foreach ($x in @($procs | Where-Object { $_.wait })) {
  if (-not $x.p.WaitForExit(60000)) { Write-Log "$($x.name) still running after 60 s - starting RetroFE anyway"; continue }
  if ($x.p.ExitCode) { Write-Log "$($x.name) failed ($($x.p.ExitCode)): $((Get-Content $x.err -Raw -ErrorAction SilentlyContinue))" }
}
$script:timings.Add(('{0} {1:N1}s' -f (($parallel | ForEach-Object { if ($_.wait) { $_.name } else { $_.name + '(bg)' } }) -join '+'), $sw.Elapsed.TotalSeconds))
if ($introCurrent) { $script:timings.Add('intro unchanged') }
$bgArt = @($procs | Where-Object { -not $_.wait })

$jtk = Join-Path $Root 'JoyToKey\JoyToKey.exe'
if ((Test-Path $jtk) -and -not (Get-Process JoyToKey -ErrorAction SilentlyContinue)) { Start-Process $jtk -WorkingDirectory (Split-Path $jtk) -WindowStyle Minimized; Write-Log 'JoyToKey started' }

# self-healing: check (and conservatively repair) the install before every boot
try { $h = Invoke-Tool 'Repair-ArcadeHealth.ps1' @('-RetroFE', $Root, '-ManifestDir', $ManifestDir); Write-Log ((($h -split "`r?`n") | Where-Object { $_ -match 'FIXED|WARN|health:' } | ForEach-Object { $_.Trim() }) -join ' | ') } catch { Write-Log "health check failed: $($_.Exception.Message)" }

# every cabinet gets the same generated content (game stories, missing art, tiles, system stories, search index):
# in the background, low priority, at most once a day - RACE2 had no stories because only RACE1 ever ran the tool
try {
  $cc = Join-Path $PSScriptRoot 'Update-CabinetContent.ps1'
  if (Test-Path $cc) { Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$cc`"", '-RetroFE', "`"$Root`"", '-ManifestDir', "`"$ManifestDir`"") -WindowStyle Hidden | Out-Null }
} catch { Write-Log "content refresh not started: $($_.Exception.Message)" }

Write-Log ('boot prep {0:N1}s: {1}' -f $bootClock.Elapsed.TotalSeconds, ($script:timings -join ', '))
if ($PrepOnly) { foreach ($x in $bgArt) { [void]$x.p.WaitForExit(60000); Write-Host ("{0} (background) exit {1}" -f $x.name, $x.p.ExitCode) }; Write-Host ('boot prep {0:N1}s: {1}' -f $bootClock.Elapsed.TotalSeconds, ($script:timings -join ', ')); return }

# Stream Deck: tools\streamdeck\amdeck.py drives the deck (themes, switches, in-game keys) when one is plugged in
# and Python + the streamdeck package are present. It exits on its own if no deck is found or Elgato's app owns it,
# and its named mutex (Global\ArcadeMasterStreamDeck) keeps a single copy - so no process scan here (~0.1-1 s of WMI)
$deck = Join-Path $PSScriptRoot 'streamdeck\amdeck.py'
. (Join-Path $PSScriptRoot 'lib\AmPython.ps1')
$pyw = Find-AmPython -Windowed   # not the Store stub; found even when Python is not on this process's PATH
if (-not $pyw -and (Test-Path $deck)) { Write-Log 'Stream Deck controller skipped: no Python found' }
$deckOk = Join-Path $ManifestDir 'amdeck-packages.ok'   # first boot on a cabinet: install the deck's Python packages once, then never check again (no Python start on every boot)
$deckTried = Join-Path $ManifestDir 'amdeck-packages.tried'   # a failed install is retried once a day, not on every boot
$deckRetry = -not (Test-Path $deckTried) -or ((Get-Date) - (Get-Item $deckTried).LastWriteTime).TotalHours -ge 24
if ($pyw -and (Test-Path $deck) -and -not (Test-Path $deckOk) -and $deckRetry) {
  # Python writes to stderr when a package is missing. Under 'Stop', Windows PowerShell turns that into a fatal error
  # (even with 2>$null) - it ended the launcher before RetroFE started on a cabinet without the deck packages.
  # The deck is optional: nothing here may stop the boot.
  $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    $py = Join-Path (Split-Path $pyw) 'python.exe'
    & $py -c "import StreamDeck, PIL" 2>&1 | Out-Null
    if ($LASTEXITCODE) {
      $o = & $py -m pip install --user --quiet -r (Join-Path $PSScriptRoot 'streamdeck\requirements.txt') 2>&1 | Out-String
      Write-Log "Stream Deck packages install (exit $LASTEXITCODE) $($o.Trim())"
      & $py -c "import StreamDeck, PIL" 2>&1 | Out-Null
    }
    if (-not $LASTEXITCODE) { Set-Content $deckOk (Get-Date).ToString('s') } else { Set-Content $deckTried (Get-Date).ToString('s'); Write-Log 'Stream Deck packages not available - deck skipped, retried in a day' }
  } catch { Set-Content $deckTried (Get-Date).ToString('s'); Write-Log "Stream Deck package check failed: $($_.Exception.Message)" }
  finally { $ErrorActionPreference = $eap }
}
# AmPanel (docs/13-panel-service.md): the panel service in the tray - lights, outputs, triggers. Installed next to the
# launcher (Build-AmPanel.ps1 -InstallTo); single instance, so a second start just hands it "frontend start". In
# shadow mode it passes everything on to LEDBlinky, so having it running never changes the lights by itself.
$amPanel = Join-Path (Split-Path $ManifestDir) 'AmPanel.exe'
# the Pixelcade marquee: found and handed to AmPanel before it starts (2P stand-up's marquee went quiet once the shim
# replaced LEDBlinky, 2026-11-26). Changes nothing on a cabinet without one, or where LEDBlinky still gets the events.
# AmPanel itself follows the repo: rebuilt and installed when src\panel changed (before, only by hand)
if (Test-Path $amPanel) { try { $o = & (Join-Path $PSScriptRoot 'Update-AmPanel.ps1') -ManifestDir $ManifestDir -Boot 6>&1 | Out-String; if ($o.Trim()) { Write-Log $o.Trim() } } catch { Write-Log "AmPanel update failed: $($_.Exception.Message)" } }
# AmPanel's own copy of Ultimarc's drivers and LEDBlinky's data (panel-data), so the lights never depend on the LEDBlinky
# install; only does something on a cabinet whose lights AmPanel drives
if (Test-Path $amPanel) { try { $o = & (Join-Path $PSScriptRoot 'Set-ButtonLights.ps1') -RetroFE $Root -ManifestDir $ManifestDir -Refresh 6>&1 | Out-String; if ($o.Trim()) { Write-Log $o.Trim() } } catch { Write-Log "panel-data refresh failed: $($_.Exception.Message)" } }
if (Test-Path $amPanel) { try { $o = & (Join-Path $PSScriptRoot 'Set-Marquee.ps1') -RetroFE $Root -ManifestDir $ManifestDir 6>&1 | Out-String; if ($o -match '^marquee:') { Write-Log $o.Trim() } } catch { Write-Log "marquee check failed: $($_.Exception.Message)" } }
if (Test-Path $amPanel) { try { Start-Process $amPanel -ArgumentList '1' -WorkingDirectory (Split-Path $amPanel); Write-Log 'AmPanel started (tray)' } catch { Write-Log "AmPanel failed to start: $($_.Exception.Message)" } }
# hold-to-exit (James 2026-11-26): PS on a wheel, Back + Start on a pad, held 5 s, leaves any game the frontend started
try { if (-not $PrepOnly -and -not $Root.StartsWith($env:TEMP, [StringComparison]::OrdinalIgnoreCase)) { Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $PSScriptRoot 'Watch-GameExit.ps1')`"", '-ManifestDir', "`"$ManifestDir`"", '-ParentPid', "$PID") -WindowStyle Hidden; Write-Log 'hold-to-exit watcher started (PS / Back + Start, 5 s)' } } catch { Write-Log "hold-to-exit failed to start: $($_.Exception.Message)" }
# cabinet link (docs/16): similar cabinets browse in unison and start the same game. catalog\cabinet-link.json names
# the cabinets that have it on; a cabinet whose settings.conf already says linkEvents = ... keeps its own choice
# (Cabinet Settings > CABINET LINK). The helper ends with this launcher.
try {
  $lkCat = Join-Path (Split-Path $PSScriptRoot) 'catalog\cabinet-link.json'; $lkConf = Join-Path $Root 'settings.conf'
  if (-not $PrepOnly -and (Test-Path $lkCat) -and (Test-Path $lkConf) -and -not $Root.StartsWith($env:TEMP, [StringComparison]::OrdinalIgnoreCase)) {
    $lk = Get-Content $lkCat -Raw | ConvertFrom-Json
    $lkLine = Select-String -LiteralPath $lkConf -Pattern '^\s*linkEvents\s*=\s*(\S+)' | Select-Object -Last 1
    if (-not $lkLine -and @($lk.enabled) -contains $env:COMPUTERNAME) {
      $t0 = [IO.File]::ReadAllText($lkConf); [IO.File]::WriteAllText($lkConf, ($t0.TrimEnd() + "`r`nlinkEvents = yes`r`n")); Write-Log 'cabinet link: switched on for this cabinet (catalog\cabinet-link.json)'
      $lkLine = Select-String -LiteralPath $lkConf -Pattern '^\s*linkEvents\s*=\s*(\S+)' | Select-Object -Last 1
    }
    if ($lkLine -and $lkLine.Matches[0].Groups[1].Value -match '^(yes|true|1)$') {
      $lkArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $PSScriptRoot 'AmLink.ps1')`"", '-RetroFE', "`"$Root`"", '-ManifestDir', "`"$ManifestDir`"", '-IdleSec', "$([int]$lk.idleSec)", '-CountdownSec', "$([int]$lk.countdownSec)", '-ParentPid', "$PID")
      Start-Process powershell -ArgumentList $lkArgs -WindowStyle Hidden; Write-Log 'cabinet link helper started'
    }
  }
} catch { Write-Log "cabinet link failed to start: $($_.Exception.Message)" }
# Model 3 linked play (docs/16 part 5): two cabinets named as a pair in catalog\cabinet-link.json ("model3Pairs") keep
# Supermodel's network link on towards each other. Set at every start, because the other cabinet is looked up by name
# and its address comes from the router. Playing alone with the link on is fine (RACE2, 2026-11-27), so it stays on.
# The cabinet link's own switch decides: with linkEvents off, the Model 3 link is left as it is. When the twin cannot be
# found on the network, nothing is changed and the last address stays.
try {
  if (-not $PrepOnly -and $lk -and $lkLine -and $lkLine.Matches[0].Groups[1].Value -match '^(yes|true|1)$' -and (Test-Path (Join-Path $Root 'emulators\Supermodel\Config\Supermodel.ini'))) {
    $m3 = @($lk.model3Pairs | Where-Object { @($_) -contains $env:COMPUTERNAME } | Select-Object -First 1)
    $m3Peer = @($m3 | ForEach-Object { $_ } | Where-Object { $_ -and $_ -ne $env:COMPUTERNAME }) | Select-Object -First 1
    if ($m3Peer) { $m3Out = & (Join-Path $PSScriptRoot 'Set-SupermodelLink.ps1') -RetroFE $Root -Peer $m3Peer -Apply 6>&1 | Out-String; Write-Log ('Model 3 link: ' + (($m3Out.Trim() -split "`r?`n") -join '; ')) }
  }
} catch { Write-Log "Model 3 link not set: $($_.Exception.Message)" }
# Model 2 linked play (Daytona USA; tools\Set-Model2Link.ps1, RACE2 2026-11-27): the same pair, the same rule. The
# emulator links only while its m2network.ini exists and names the twin, so it is written again at every start.
try {
  if (-not $PrepOnly -and $lk -and $lkLine -and $lkLine.Matches[0].Groups[1].Value -match '^(yes|true|1)$' -and (Test-Path (Join-Path $Root 'emulators\m2emulator'))) {
    $m2 = @($lk.model3Pairs | Where-Object { @($_) -contains $env:COMPUTERNAME } | Select-Object -First 1)
    $m2Peer = @($m2 | ForEach-Object { $_ } | Where-Object { $_ -and $_ -ne $env:COMPUTERNAME }) | Select-Object -First 1
    if ($m2Peer) { $m2Out = & (Join-Path $PSScriptRoot 'Set-Model2Link.ps1') -RetroFE $Root -Peer $m2Peer -Apply 6>&1 | Out-String; Write-Log ('Model 2 link: ' + (($m2Out.Trim() -split "`r?`n") -join '; ')) }
  }
} catch { Write-Log "Model 2 link not set: $($_.Exception.Message)" }
$deckOn = [bool](Read-AmUi $ManifestDir).streamDeck   # Tools > Cabinet Settings > Stream Deck
if (-not $deckOn -and (Test-Path $deck)) { Write-Log 'Stream Deck controller off (Cabinet Settings)' }
if ($deckOn -and $pyw -and (Test-Path $deck)) {
  try { Start-Process $pyw -ArgumentList @("`"$deck`"", '--retrofe', "`"$Root`"", '--manifest', "`"$ManifestDir`"") -WindowStyle Hidden; Write-Log 'Stream Deck controller started' } catch { Write-Log "Stream Deck controller failed: $($_.Exception.Message)" }
}

# <ManifestDir>\restart.request: written by the Stream Deck (or any tool) before it closes RetroFE on purpose,
# so the watchdog restarts it without counting a crash. The file holds the reason.
$restartFlag = Join-Path $ManifestDir 'restart.request'
Remove-Item -LiteralPath $restartFlag -Force -ErrorAction SilentlyContinue
# <Root>\exit.request: written by the menu's EXIT item (collections\Main\roms\EXIT.bat) just before it force-closes
# RetroFE. That forced close ends with exit code 1, so without this note the watchdog took it for a crash and restarted.
$exitFlag = Join-Path $Root 'exit.request'
Remove-Item -LiteralPath $exitFlag -Force -ErrorAction SilentlyContinue
$crashes = New-Object System.Collections.Generic.List[datetime]
$snapshotDone = $false; $lkgRestored = $false; $themeFallback = $false
# <ManifestDir>\theme-pending.json: Tools > Themes or the Stream Deck changed the theme. Once RetroFE shows it (running
# for ThemeSettleSec, nothing it started - the Tools page, a game - open for 6 s), Confirm-ThemeChange asks to keep it.
# No answer / Escape: it reverts, writes restart.request and ends RetroFE -> restarted below with the old theme.
# RetroFE closing or crashing while the change is unconfirmed reverts it here.
$pendingFile = Get-AmPendingPath $ManifestDir
function Get-BusyChildren([int]$id) { @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $id" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^(conhost|LEDBlinky|WerFault)\.exe$' }) }
function Start-ThemeConfirm([int]$id) {
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'Confirm-ThemeChange.ps1'), '-RetroFE', $Root, '-ManifestDir', $ManifestDir, '-TimeoutSec', "$ThemeConfirmSec", '-RetroFEPid', "$id")
  if ($env:AM_THEME_CONFIRM_NOUI -eq '1') { $a += '-NoUi' }   # tests: no window, the countdown runs out
  $q = $a | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }
  $cp = Start-Process powershell -ArgumentList ($q -join ' ') -WindowStyle Hidden -PassThru; [void]$cp.Handle
  Write-Log 'theme change waiting - asking to keep it'; return $cp
}
# Picture decoding threads: RetroFE uses at most 3 by default. Half this PC's cores (3 to 8) cut entering Racing on
# RACE1 (16 threads) from 92 to 84 ms (2026-11-25, docs/14 item 5). A value set by hand is kept.
if (-not $env:RETROFE_THREADPOOL_SIZE) { $env:RETROFE_THREADPOOL_SIZE = "$([Math]::Max(3, [Math]::Min(8, [int]([Environment]::ProcessorCount / 2))))" }
while ($true) {
  Write-Log "starting RetroFE ($($env:RETROFE_THREADPOOL_SIZE) picture threads)"
  $p = Start-Process $exe -WorkingDirectory $exeDir -PassThru; [void]$p.Handle
  $startedAt = Get-Date; $quietSince = $startedAt; $confirm = $null
  while (-not $p.WaitForExit(1000)) {
    $now = Get-Date; $pendingNow = Test-Path -LiteralPath $pendingFile
    # stable for 3 minutes -> remember this configuration as last-known-good (once per boot; never an unconfirmed theme)
    if (-not $snapshotDone -and -not $pendingNow -and ($now - $startedAt).TotalSeconds -ge 180) {
      try { Invoke-Tool 'Repair-ArcadeHealth.ps1' @('-RetroFE', $Root, '-ManifestDir', $ManifestDir, '-Snapshot', '-NoFix') | Out-Null; Write-Log 'stable 3 min - last-known-good configs saved' } catch { }
      $snapshotDone = $true
    }
    if ($confirm -and $confirm.HasExited) { $confirm = $null; $quietSince = $now }
    if (-not $pendingNow -or $confirm) { continue }
    if (@(Get-BusyChildren $p.Id).Count) { $quietSince = $now; continue }
    if (($now - $startedAt).TotalSeconds -ge $ThemeSettleSec -and ($now - $quietSince).TotalSeconds -ge 6) { $confirm = Start-ThemeConfirm $p.Id }
  }
  $code = $p.ExitCode
  if ($confirm -and -not $confirm.HasExited) { [void]$confirm.WaitForExit(3000); if (-not $confirm.HasExited) { & taskkill.exe /PID $confirm.Id /T /F 2>$null | Out-Null } }
  if (Test-Path -LiteralPath $restartFlag) {
    $why = (Get-Content -LiteralPath $restartFlag -Raw -ErrorAction SilentlyContinue); Remove-Item -LiteralPath $restartFlag -Force -ErrorAction SilentlyContinue
    Write-Log "restart requested ($("$why".Trim())) - RetroFE exit $code"; continue   # a waiting theme change is asked about after the restart
  }
  if (Test-Path -LiteralPath $pendingFile) {
    try { [void](Restore-AmThemePending $Root $ManifestDir "the frontend closed before it was confirmed (exit $code)") } catch { Write-Log "theme revert failed: $($_.Exception.Message)" }
  }
  if (Test-Path -LiteralPath $exitFlag) {
    Remove-Item -LiteralPath $exitFlag -Force -ErrorAction SilentlyContinue
    Write-Log "Exit chosen in the menu - RetroFE closed (exit $code), not restarting"; break
  }
  # (Select-String on a missing log.txt stops the script even with SilentlyContinue: check that it exists first)
  $rlog = Join-Path $Root 'log.txt'
  $crashed = ($code -ne 0) -or ((Test-Path -LiteralPath $rlog) -and (Select-String -LiteralPath $rlog -Pattern 'FATAL CRASH' -Quiet -ErrorAction SilentlyContinue))
  if (-not $crashed) { Write-Log "RetroFE exited cleanly ($code)"; break }
  $now = Get-Date; $crashes.Add($now); $recent = @($crashes | Where-Object { ($now - $_).TotalSeconds -le $CrashWindowSec })
  # milliseconds + -Force: after a settings restore the retry is immediate, and two crashes in the same second used to
  # collide on the folder name - that error stopped the watchdog itself
  $keep = Join-Path $Root ("crash-{0:yyyyMMdd-HHmmss-fff}" -f $now); New-Item -ItemType Directory -Force $keep | Out-Null
  Copy-Item (Join-Path $Root 'log.txt') $keep -ErrorAction SilentlyContinue
  # the minidump only when THIS run wrote it, and moved (not copied): an old retrofe_crash.dmp was copied into every later
  # crash folder, so a killed or hung RetroFE looked like the old crash again (RACE2, 2026-11-26)
  $dmp = Join-Path $Root 'retrofe_crash.dmp'
  if ((Test-Path $dmp) -and (Get-Item $dmp).LastWriteTime -ge $startedAt.AddSeconds(-5)) { Move-Item $dmp $keep -Force -ErrorAction SilentlyContinue }
  $stamp = Join-Path (Split-Path $exe) 'am-build.txt'; if (Test-Path $stamp) { Copy-Item $stamp $keep -ErrorAction SilentlyContinue }   # which build crashed
  Write-Log "RetroFE crashed (exit $code) - evidence in $keep"
  # crash loop: put the last-known-good configs back once and try again before giving up
  if ($recent.Count -ge 3 -and -not $lkgRestored) {
    $lkgRestored = $true; $crashes.Clear()
    $r = Invoke-Tool 'Repair-ArcadeHealth.ps1' @('-RetroFE', $Root, '-ManifestDir', $ManifestDir, '-RestoreLkg'); Write-Log "crash loop - $($r.Trim())"
    continue
  }
  if ($recent.Count -ge $MaxCrashes) {
    # last try before giving up: an imported theme (CO-*, a CoinOPS layout ...) that crashes RetroFE -> back to the
    # ArcadeMaster layout, which ships with the repo. Only settings.conf 'layout =' changes; a copy is kept.
    $sc = Join-Path $Root 'settings.conf'
    $cur = (Select-String -LiteralPath $sc -Pattern '^\s*layout\s*=\s*(.+)$' -ErrorAction SilentlyContinue | Select-Object -Last 1)
    $curLayout = if ($cur) { $cur.Matches[0].Groups[1].Value.Trim() } else { '' }
    if (-not $themeFallback -and $curLayout -and $curLayout -ne $Layout -and (Test-Path (Join-Path $Root "layouts\$Layout\layout.xml"))) {
      $themeFallback = $true; $crashes.Clear()
      Copy-Item -LiteralPath $sc "$sc.before-theme-fallback" -Force
      $txt = [IO.File]::ReadAllText($sc); $txt = [regex]::Replace($txt, '(?m)^(\s*layout\s*=\s*).+?(\r?)$', "`${1}$Layout`${2}")
      [IO.File]::WriteAllText($sc, $txt, (New-Object Text.UTF8Encoding $false))
      Write-Log "theme '$curLayout' keeps crashing RetroFE - switched back to the $Layout theme (old settings: settings.conf.before-theme-fallback)"
      continue
    }
    Write-Log "$MaxCrashes crashes in $CrashWindowSec s - giving up"; break
  }
  Start-Sleep -Seconds 2
}
