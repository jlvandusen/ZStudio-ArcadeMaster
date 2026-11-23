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
  [switch]$PrepOnly                    # run every boot step and log the timings, but do not start RetroFE
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\RetroFEPaths.ps1')
$exe = Get-AmRetroFEExe $Root   # retrofe\retrofe.exe, core\retrofe.exe (CoinOPS LEGENDS / CORE) or <root>\retrofe.exe
if (-not $exe) { throw "RetroFE not found under $Root (looked in retrofe\, core\ and the root)" }
$log = Join-Path $Root 'arcademaster-launcher.log'
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
    $modesNow = (@($now.modes) | Sort-Object) -join ','; $modesFile = Join-Path $ManifestDir 'last-modes.txt'
    $modesLast = if (Test-Path $modesFile) { (Get-Content $modesFile -Raw).Trim() } else { '' }
    if ($modesNow -ne $modesLast) {
      Write-Log "cabinet modes changed ('$modesLast' -> '$modesNow') - regenerating menus"
      Invoke-Tool 'New-RetroFECollections.ps1' @('-RetroFE', $Root, '-Cabinet', $cabFile, '-Manifest', (Join-Path $ManifestDir 'games.json'), '-RebuildDatabase') | Out-Null
      Set-Content $modesFile $modesNow
    }
  } catch { Write-Log "device check failed: $($_.Exception.Message)" }   # never block boot on diagnostics
}

# the main menu's wheel shows the wheel this cabinet really has (G HUB's picture of it); redrawn only when it changed
try { $rw = Invoke-Tool 'New-RealWheelArt.ps1' @('-RetroFE', $Root, '-ManifestDir', $ManifestDir, '-Layout', $Layout); if ($rw -match '->|removed') { Write-Log (($rw -split "`r?`n" | Where-Object { $_ -match 'real wheel' }) -join ' ') } } catch { Write-Log "real wheel art failed: $($_.Exception.Message)" }

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
$active = ((Select-String -Path (Join-Path $Root 'settings.conf') -Pattern '^\s*layout\s*=\s*(.+)$' | Select-Object -Last 1).Matches[0].Groups[1].Value).Trim()
# the intro card and the Tools list art (live state: devices, switches, game counts) write different files, so they
# render side by side, each in its own powershell. The boot waits for the intro (max 60 s); the Tools art is only seen
# inside Tools (never during the intro), so it finishes in the background at low priority while RetroFE starts - its
# images are swapped in atomically
$parallel = @(@{ name = 'New-CabinetIntro'; wait = $true; args = @('-RetroFE', $Root, '-ManifestDir', $ManifestDir, '-Layout', $active) })
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
$bgArt = @($procs | Where-Object { -not $_.wait })

$jtk = Join-Path $Root 'JoyToKey\JoyToKey.exe'
if ((Test-Path $jtk) -and -not (Get-Process JoyToKey -ErrorAction SilentlyContinue)) { Start-Process $jtk -WorkingDirectory (Split-Path $jtk) -WindowStyle Minimized; Write-Log 'JoyToKey started' }

# self-healing: check (and conservatively repair) the install before every boot
try { $h = Invoke-Tool 'Repair-ArcadeHealth.ps1' @('-RetroFE', $Root, '-ManifestDir', $ManifestDir); Write-Log ((($h -split "`r?`n") | Where-Object { $_ -match 'FIXED|WARN|health:' } | ForEach-Object { $_.Trim() }) -join ' | ') } catch { Write-Log "health check failed: $($_.Exception.Message)" }

Write-Log ('boot prep {0:N1}s: {1}' -f $bootClock.Elapsed.TotalSeconds, ($script:timings -join ', '))
if ($PrepOnly) { foreach ($x in $bgArt) { [void]$x.p.WaitForExit(60000); Write-Host ("{0} (background) exit {1}" -f $x.name, $x.p.ExitCode) }; Write-Host ('boot prep {0:N1}s: {1}' -f $bootClock.Elapsed.TotalSeconds, ($script:timings -join ', ')); return }

# Stream Deck: tools\streamdeck\amdeck.py drives the deck (themes, switches, in-game keys) when one is plugged in
# and Python + the streamdeck package are present. It exits on its own if no deck is found or Elgato's app owns it,
# and its named mutex (Global\ArcadeMasterStreamDeck) keeps a single copy - so no process scan here (~0.1-1 s of WMI)
$deck = Join-Path $PSScriptRoot 'streamdeck\amdeck.py'
$pyw = (Get-Command pythonw.exe -All -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch '\\WindowsApps\\' } | Select-Object -First 1).Source   # not the Store stub
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
if ($pyw -and (Test-Path $deck)) {
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
while ($true) {
  Write-Log 'starting RetroFE'
  $p = Start-Process $exe -WorkingDirectory (Split-Path $exe) -PassThru
  # stable for 3 minutes -> remember this configuration as last-known-good (once per boot)
  if (-not $snapshotDone -and -not $p.WaitForExit(180000)) {
    try { Invoke-Tool 'Repair-ArcadeHealth.ps1' @('-RetroFE', $Root, '-ManifestDir', $ManifestDir, '-Snapshot', '-NoFix') | Out-Null; Write-Log 'stable 3 min - last-known-good configs saved' } catch { }
    $snapshotDone = $true
  }
  $p.WaitForExit()
  $code = $p.ExitCode
  if (Test-Path -LiteralPath $restartFlag) {
    $why = (Get-Content -LiteralPath $restartFlag -Raw -ErrorAction SilentlyContinue); Remove-Item -LiteralPath $restartFlag -Force -ErrorAction SilentlyContinue
    Write-Log "restart requested ($("$why".Trim())) - RetroFE exit $code"; continue
  }
  if (Test-Path -LiteralPath $exitFlag) {
    Remove-Item -LiteralPath $exitFlag -Force -ErrorAction SilentlyContinue
    Write-Log "Exit chosen in the menu - RetroFE closed (exit $code), not restarting"; break
  }
  $crashed = ($code -ne 0) -or (Select-String -Path (Join-Path $Root 'log.txt') -Pattern 'FATAL CRASH' -Quiet -ErrorAction SilentlyContinue)
  if (-not $crashed) { Write-Log "RetroFE exited cleanly ($code)"; break }
  $now = Get-Date; $crashes.Add($now); $recent = @($crashes | Where-Object { ($now - $_).TotalSeconds -le $CrashWindowSec })
  # milliseconds + -Force: after a settings restore the retry is immediate, and two crashes in the same second used to
  # collide on the folder name - that error stopped the watchdog itself
  $keep = Join-Path $Root ("crash-{0:yyyyMMdd-HHmmss-fff}" -f $now); New-Item -ItemType Directory -Force $keep | Out-Null
  foreach ($f in 'log.txt', 'retrofe_crash.dmp') { $src = Join-Path $Root $f; if (Test-Path $src) { Copy-Item $src $keep } }
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
