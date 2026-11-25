<#
.SYNOPSIS
  Self-healing health check for an ArcadeMaster cabinet. Runs at every boot (Start-ArcadeMaster) and from
  Tools > System Health. Each check reports OK / FIXED / WARN; fixes are conservative and backed up.
    runtime    retrofe.exe + core DLLs present (restored from the last-known-good copy when missing)
    settings   layout installed, firstCollection exists, numScreens <= connected displays, enterOnCollection = no
    controls   controls.conf present (restored from last-known-good / .bak)
    screens    every 'layout - N.xml' declares monitor="N"
    menu       main-menu entries point at real collections
    launchers  each collection's launcher points at an emulator that exists (report only)
    games      TeknoParrot profiles in this frontend with a missing game path are repaired (backup first); how many
               catalog games can't start and why (moved / incomplete copy / not installed / never set up)
    logs       log.txt rotated above 20 MB, crash-* evidence folders capped at 10
    disk       free space on the frontend drive
    art        boot intro + Tools art present (regenerated when missing)
  -Snapshot   when everything is OK: save a last-known-good copy of the configs (manifest\lkg\<stamp>, keeps 3)
  -RestoreLkg put the newest last-known-good configs back (used by the watchdog after a crash loop)
  Writes manifest\health.json; with AM_VISUAL=1 it emits @AM step events for the visual tool page.
#>
param(
  [string]$RetroFE = 'D:\ArcadeMaster\frontend\DRIVE-coinops',
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [switch]$Snapshot,
  [switch]$RestoreLkg,
  [switch]$NoFix
)
$ErrorActionPreference = 'Continue'
$visual = $env:AM_VISUAL -eq '1'
function Emit([hashtable]$o) { if ($visual) { [Console]::Out.WriteLine('@AM ' + (ConvertTo-Json $o -Compress -Depth 5)) } }
$sc = Join-Path $RetroFE 'settings.conf'
$lkgRoot = Join-Path $ManifestDir 'lkg'
$lkgFiles = @('settings.conf', 'controls.conf', 'collections\Main\menu.txt')
function Get-Setting([string]$k) { $m = Select-String -Path $sc -Pattern "^\s*$([regex]::Escape($k))\s*=\s*(.*)$" -ErrorAction SilentlyContinue | Select-Object -Last 1; if ($m) { $m.Matches[0].Groups[1].Value.Trim() } }
function Set-Setting([string]$k, [string]$v) { $l = [Collections.Generic.List[string]](Get-Content $sc); $d = $false; for ($i = 0; $i -lt $l.Count; $i++) { if ($l[$i] -match "^\s*$([regex]::Escape($k))\s*=") { $l[$i] = "$k = $v"; $d = $true } }; if (-not $d) { $l.Add("$k = $v") }; Set-Content $sc $l -Encoding ascii }

if ($RestoreLkg) {
  $last = Get-ChildItem $lkgRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $last) { Write-Host 'no last-known-good snapshot'; exit 1 }
  foreach ($f in $lkgFiles + @(Get-ChildItem (Join-Path $last.FullName 'launchers.windows') -File -ErrorAction SilentlyContinue | ForEach-Object { "launchers.windows\$($_.Name)" })) {
    $s = Join-Path $last.FullName $f; if (Test-Path $s) { $d = Join-Path $RetroFE $f; if (Test-Path $d) { Copy-Item $d "$d.before-lkg" -Force }; Copy-Item $s $d -Force }
  }
  Write-Host "restored last-known-good configs from $($last.Name)"; exit 0
}

$results = New-Object Collections.Generic.List[object]
function Add-Result([string]$id, [string]$label, [string]$state, [string]$detail) {
  $results.Add([ordered]@{ id = $id; label = $label; state = $state; detail = $detail })
  Emit @{ type = 'step'; id = $id; label = "$label - $detail"; status = $(switch ($state) { 'OK' { 'ok' } 'FIXED' { 'ok' } 'WARN' { 'fail' } default { 'pending' } }) }
  Write-Host ("  {0,-6} {1,-10} {2}" -f $state, $id, $detail)
}
$fix = -not $NoFix
$cab = $null; $cf = Join-Path $ManifestDir 'cabinet.json'; if (Test-Path $cf) { $cab = Get-Content $cf -Raw | ConvertFrom-Json }
$checks = [ordered]@{ runtime = 'RetroFE runtime'; settings = 'Settings'; controls = 'Controls file'; screens = 'Second-screen layouts'; menu = 'Main menu'; launchers = 'Launchers'; games = 'Games that can start'; pedals = 'Pedals in TeknoParrot games'; logs = 'Logs'; disk = 'Disk space'; art = 'Intro + Tools art' }
foreach ($k in $checks.Keys) { Emit @{ type = 'step'; id = $k; label = $checks[$k]; status = 'pending' } }

# runtime
Emit @{ type = 'step'; id = 'runtime'; label = $checks.runtime; status = 'run' }
. (Join-Path $PSScriptRoot 'lib\RetroFEPaths.ps1'); $rexe = Get-AmRetroFEExe $RetroFE   # retrofe\, core\ (CoinOPS) or the root
$rt = if ($rexe) { Split-Path $rexe } else { Join-Path $RetroFE 'retrofe' }; $need = @('retrofe.exe', 'SDL2.dll', 'gstreamer-1.0-0.dll', 'glib-2.0-0.dll')
$miss = @($need | Where-Object { -not (Test-Path (Join-Path $rt $_)) })
if (-not $miss) { Add-Result 'runtime' $checks.runtime 'OK' "$((Get-ChildItem $rt -File -ErrorAction SilentlyContinue).Count) files" }
else {
  $src = Get-ChildItem (Join-Path $lkgRoot 'runtime') -File -ErrorAction SilentlyContinue
  if ($fix -and $src) { foreach ($m in $miss) { $s = Join-Path $lkgRoot "runtime\$m"; if (Test-Path $s) { Copy-Item $s (Join-Path $rt $m) } }; $still = @($need | Where-Object { -not (Test-Path (Join-Path $rt $_)) }) }
  else { $still = $miss }
  if ($still) { Add-Result 'runtime' $checks.runtime 'WARN' "missing: $($still -join ', ')" } else { Add-Result 'runtime' $checks.runtime 'FIXED' "restored $($miss -join ', ') from last-known-good" }
}

# settings
Emit @{ type = 'step'; id = 'settings'; label = $checks.settings; status = 'run' }
if (-not (Test-Path $sc)) { Add-Result 'settings' $checks.settings 'WARN' 'settings.conf missing (watchdog restores last-known-good)' }
else {
  $did = @()
  $lay = Get-Setting 'layout'; if (-not $lay -or -not (Test-Path (Join-Path $RetroFE "layouts\$lay\layout.xml"))) { if ($fix -and (Test-Path (Join-Path $RetroFE 'layouts\ArcadeMaster\layout.xml'))) { Set-Setting 'layout' 'ArcadeMaster'; $did += "layout '$lay' not installed -> ArcadeMaster" } }
  $fc = Get-Setting 'firstCollection'; if ($fc -and -not (Test-Path (Join-Path $RetroFE "collections\$fc"))) { if ($fix) { Set-Setting 'firstCollection' 'Main'; $did += "firstCollection '$fc' missing -> Main" } }
  $ns = [int]("0" + (Get-Setting 'numScreens')); $disp = if ($cab) { @($cab.capabilities.displays).Count } else { 1 }
  if ($ns -gt $disp -and $disp -ge 1) { if ($fix) { Set-Setting 'numScreens' "$disp"; $did += "numScreens $ns -> $disp (displays connected)" } }
  if ((Get-Setting 'enterOnCollection') -ne 'no') { if ($fix) { Set-Setting 'enterOnCollection' 'no'; $did += 'enterOnCollection -> no' } }
  if ($did) { Add-Result 'settings' $checks.settings 'FIXED' ($did -join '; ') } else { Add-Result 'settings' $checks.settings 'OK' "layout $(Get-Setting 'layout'), $disp display(s)" }
}

# controls
Emit @{ type = 'step'; id = 'controls'; label = $checks.controls; status = 'run' }
$cc = Join-Path $RetroFE 'controls.conf'
if (Test-Path $cc) {
  # The ArcadeMaster game list scrolls UP/DOWN. CoinOPS builds switch playlists (filters) with Up/Down because their
  # lists scroll sideways; under our layout that leaves the filters unreachable. Move them to Left/Right (+ stick).
  $lines = [Collections.Generic.List[string]](Get-Content $cc); $moved = $false
  if ((Get-Setting 'layout') -eq 'ArcadeMaster') {
    $want = @{ nextPlaylist = 'Right,joyHat0Right,joyAxis0+'; prevPlaylist = 'Left,joyHat0Left,joyAxis0-' }
    for ($i = 0; $i -lt $lines.Count; $i++) {
      if ($lines[$i] -match '^\s*(nextPlaylist|prevPlaylist)\s*=\s*(.*)$') {
        $key = $Matches[1]; $val = $Matches[2]          # keep them: the next -match overwrites $Matches
        if ($val -match '\b(Up|Down)\b') { $lines[$i] = "$key = $($want[$key])"; $moved = $true }
      }
    }
  }
  # Esc must go BACK, never quit: CoinOPS builds ship quit = Escape, so one press closed the whole frontend. Take the
  # quit key from the cabinet's controls profile (retrofe\controls\controls-<type>.conf: all say quit = Q) and make sure
  # back has Escape. Only these two keys change; back keeps the build's own keys (Escape is added in front), because a
  # profile's touch / mouse tokens are unknown to stock CoinOPS RetroFE builds. Other keys (wheel mappings) are untouched.
  $profDir = Join-Path (Split-Path $PSScriptRoot) 'retrofe\controls'
  $modeFile = if ($ManifestDir) { Join-Path $ManifestDir 'cabinet-mode.json' } else { '' }
  $mode = if ($modeFile -and (Test-Path $modeFile)) { (((Get-Content $modeFile -Raw | ConvertFrom-Json).effective) -split '\+')[0] } else { '' }
  $profName = @{ racing = 'racing-wheel'; simulation = 'racing-wheel'; lightgun = 'lightgun'; touch = 'touch-kiosk' }[$mode]
  if (-not $profName) { $profName = 'pedestal-4p' }
  $prof = Join-Path $profDir "controls-$profName.conf"
  $profQuit = 'Q'
  if (Test-Path $prof) { $pq = Select-String -Path $prof -Pattern '^\s*quit\s*=\s*(.+)$' | Select-Object -First 1; if ($pq) { $profQuit = $pq.Matches[0].Groups[1].Value.Trim() } }
  $escFix = @()
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*quit\s*=\s*(.*)$') {
      $qv = $Matches[1]
      if (@($qv -split ',' | ForEach-Object { $_.Trim() }) -contains 'Escape') { $lines[$i] = "quit = $profQuit"; $escFix += "quit '$($qv.Trim())' -> '$profQuit'" }
    }
    elseif ($lines[$i] -match '^\s*back\s*=\s*(.*)$') {
      $bv = $Matches[1]
      if (@($bv -split ',' | ForEach-Object { $_.Trim() }) -notcontains 'Escape') {
        $nb = (@('Escape') + @($bv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) -join ', '
        $lines[$i] = "back = $nb"; $escFix += "back '$($bv.Trim())' -> '$nb'"
      }
    }
  }
  if (($moved -or $escFix) -and $fix) {
    if ($moved -and -not (Test-Path "$cc.am-playlist-keys")) { Copy-Item $cc "$cc.am-playlist-keys" }
    if ($escFix) { Copy-Item $cc "$cc.bak" -Force }
    Set-Content $cc $lines -Encoding ascii
    $what = @(); if ($moved) { $what += 'filters (playlists) moved to Left/Right: the ArcadeMaster list scrolls up/down' }
    if ($escFix) { $what += "Esc goes back instead of quitting ($($escFix -join '; '); profile $profName)" }
    Add-Result 'controls' $checks.controls 'FIXED' ($what -join '; ')
  } elseif ($escFix) { Add-Result 'controls' $checks.controls 'WARN' "Esc quits the frontend ($($escFix -join '; '))" }
  else { Add-Result 'controls' $checks.controls 'OK' 'present; Esc goes back' }
}
else {
  $cand = @((Get-ChildItem $lkgRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'controls.conf' }) + @("$cc.bak") | Where-Object { Test-Path $_ } | Select-Object -First 1)
  if ($fix -and $cand) { Copy-Item $cand[0] $cc; Add-Result 'controls' $checks.controls 'FIXED' "restored from $($cand[0])" } else { Add-Result 'controls' $checks.controls 'WARN' 'controls.conf missing' }
}

# screens: layout - N.xml must declare monitor
Emit @{ type = 'step'; id = 'screens'; label = $checks.screens; status = 'run' }
$fixedL = 0; $u8 = New-Object Text.UTF8Encoding $false
foreach ($lf in Get-ChildItem (Join-Path $RetroFE 'layouts') -Recurse -Filter 'layout - *.xml' -File -ErrorAction SilentlyContinue) {
  if ($lf.BaseName -notmatch 'layout - (\d+)$') { continue }; $mon = $Matches[1]
  $t = [IO.File]::ReadAllText($lf.FullName); $m = [regex]::Match($t, '<layout\b[^>]*>')
  if ($m.Success -and $m.Value -notmatch '\bmonitor=' -and $fix) { Copy-Item $lf.FullName "$($lf.FullName).bak" -Force; $t = $t.Substring(0, $m.Index) + $m.Value.Replace('<layout', "<layout monitor=`"$mon`"") + $t.Substring($m.Index + $m.Length); [IO.File]::WriteAllText($lf.FullName, $t, $u8); $fixedL++ }
}
# a mouse-type touch board plugged in / pulled since last boot: re-apply controls.conf mouseTouchScreens (patch 0006)
$touchMsg = $null
$ccFile = Join-Path $RetroFE 'controls.conf'
if ($fix -and $cab -and (Test-Path $ccFile) -and (@($cab.capabilities.touchControllers).Count -or (Select-String $ccFile -Pattern '^\s*mouseTouchScreens\s*=' -Quiet))) {   # only when there is something to decide (saves ~0.4 s per boot)
  $cabPath = Join-Path $ManifestDir 'cabinet.json'
  $tOut = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Set-RetroFEScreens.ps1') -RetroFE $RetroFE -Cabinet $cabPath -TouchOnly 2>&1 | Out-String
  if ($tOut -match 'touch: CHANGED (.+)') { $touchMsg = $Matches[1].Trim() }
}
if ($fixedL -or $touchMsg) { Add-Result 'screens' $checks.screens 'FIXED' ((@($(if ($fixedL) { "$fixedL layout(s) given monitor= (they drew over the main screen)" }), $touchMsg) | Where-Object { $_ }) -join '; ') } else { Add-Result 'screens' $checks.screens 'OK' 'all declare their monitor' }

# menu
Emit @{ type = 'step'; id = 'menu'; label = $checks.menu; status = 'run' }
$exitMsg = $null
# the menu's EXIT item force-closes RetroFE (taskkill /f -> exit code 1, which looks like a crash). It must leave
# exit.request in the frontend folder first, so Start-ArcadeMaster stops instead of restarting the frontend.
$exitBat = Join-Path $RetroFE 'collections\Main\roms\EXIT.bat'
if ((Test-Path $exitBat) -and -not (Select-String $exitBat -Pattern 'exit\.request' -Quiet) -and $fix) {
  Copy-Item $exitBat "$exitBat.bak" -Force
  Set-Content $exitBat @('@echo off', 'rem ArcadeMaster: tell the launcher this exit was chosen in the menu (not a crash), then close the frontend', 'echo menu exit> "%~dp0..\..\..\exit.request"', 'taskkill /f /im RetroFE.exe') -Encoding ascii
  $exitMsg = 'menu Exit now really exits (the launcher used to restart the frontend)'
}
$mt = Join-Path $RetroFE 'collections\Main\menu.txt'
if (Test-Path $mt) {
  $menu = @(Get-Content $mt | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
  $bad = @($menu | Where-Object { -not (Test-Path (Join-Path $RetroFE "collections\$_")) })
  if ($bad -and $fix) { Copy-Item $mt "$mt.bak" -Force; Set-Content $mt @($menu | Where-Object { $bad -notcontains $_ }) -Encoding ascii; Add-Result 'menu' $checks.menu 'FIXED' "removed entries with no collection: $($bad -join ', ')" }
  elseif ($bad) { Add-Result 'menu' $checks.menu 'WARN' "no collection for: $($bad -join ', ')" }
  elseif ($exitMsg) { Add-Result 'menu' $checks.menu 'FIXED' $exitMsg }
  else { Add-Result 'menu' $checks.menu 'OK' ($menu -join ', ') }
} else { Add-Result 'menu' $checks.menu 'WARN' 'Main\menu.txt missing' }


# launchers (report only - emulators are never touched)
Emit @{ type = 'step'; id = 'launchers'; label = $checks.launchers; status = 'run' }
$broken = @(); $toolsLauncherFixed = $false
foreach ($c in Get-ChildItem (Join-Path $RetroFE 'collections') -Directory) {
  $cs = Join-Path $c.FullName 'settings.conf'; if (-not (Test-Path $cs)) { continue }
  $ln = (Select-String -Path $cs -Pattern '^\s*launcher\s*=\s*(.+)$' | Select-Object -First 1); if (-not $ln) { continue }
  $lname = $ln.Matches[0].Groups[1].Value.Trim() -replace '%ITEM_COLLECTION_NAME%', $c.Name; $lc = Join-Path $RetroFE "launchers.windows\$lname.conf"
  if (-not (Test-Path $lc) -and $lname -eq 'AM_TOOLS' -and $fix -and (Test-Path (Join-Path $c.FullName 'RunHidden.vbs'))) {
    # ArcadeMaster's own Tools launcher (the one launcher this check may write): same text as New-CabinetToolsCollection
    Set-Content $lc "executable = C:\Windows\System32\wscript.exe`r`narguments = `"$($c.FullName)\RunHidden.vbs`" `"%ITEM_FILEPATH%`"`r`nreboot = yes" -Encoding ascii
    $toolsLauncherFixed = $true; continue
  }
  if (-not (Test-Path $lc)) { $broken += "$($c.Name): launcher '$lname' missing"; continue }
  $ex = (Select-String -Path $lc -Pattern '^\s*executable\s*=\s*(.+)$' | Select-Object -First 1); if (-not $ex) { continue }
  $exe = $ex.Matches[0].Groups[1].Value.Trim().Trim('"'); if ($exe -match '%') { continue }
  $full = if ([IO.Path]::IsPathRooted($exe)) { $exe } else { Join-Path $RetroFE $exe }
  if (-not (Test-Path $full)) { $broken += "$($c.Name): $exe not found" }
}
if ($toolsLauncherFixed -and -not $broken) { Add-Result 'launchers' $checks.launchers 'FIXED' 'Tools menu launcher (AM_TOOLS) was missing - put back' }
elseif ($broken) { Add-Result 'launchers' $checks.launchers 'WARN' (($broken | Select-Object -First 4) -join '; ') + $(if ($broken.Count -gt 4) { " (+$($broken.Count - 4) more)" }) } else { Add-Result 'launchers' $checks.launchers 'OK' 'every launcher points at an existing program' }

# games: TeknoParrot profiles inside THIS frontend whose game path is gone get repaired (Repair-TPProfiles: backup
# first, path taken from the same profile in another TeknoParrot install, or found by file name); then the catalog
# says how many games can't start and why (lib\AmGameDoctor.ps1 fills that in on every catalog build)
Emit @{ type = 'step'; id = 'games'; label = $checks.games; status = 'run' }
$gDid = @(); $gWarn = @()
. (Join-Path $PSScriptRoot 'lib\AmMachine.ps1')
foreach ($tpd in Get-ChildItem (Join-Path $RetroFE 'emulators') -Directory -Filter 'TeknoParrot*' -ErrorAction SilentlyContinue) {
  $up = Join-Path $tpd.FullName 'UserProfiles'; if (-not (Test-Path $up)) { continue }
  $gone = @(foreach ($f in Get-ChildItem $up -Filter *.xml -File) {
    $m = [regex]::Match([IO.File]::ReadAllText($f.FullName), '<GamePath>(.+?)</GamePath>'); if (-not $m.Success) { continue }
    $p = $m.Groups[1].Value; $full = if ([IO.Path]::IsPathRooted($p)) { $p } else { [IO.Path]::GetFullPath((Join-Path $tpd.FullName $p)) }
    if (-not (Test-Path -LiteralPath $full)) { $f.BaseName } })
  if (-not $gone) { continue }
  # the same set already found unfixable last time: don't search the disks again on every boot
  $memo = Join-Path $ManifestDir ("games-unfixable-{0}.txt" -f $tpd.Name); $key = ($gone | Sort-Object) -join ','
  if ($fix -and (Test-Path $memo) -and (Get-Content $memo -Raw).Trim() -eq $key) { $gWarn += "$($tpd.Name): game files not found for $($gone -join ', ')"; continue }
  if ($fix) {
    $hints = @(Get-AmTeknoParrotRoots -RetroFE $RetroFE | Where-Object { $_.TrimEnd('\') -ne $tpd.FullName.TrimEnd('\') })
    $rep = Join-Path $PSScriptRoot 'Repair-TPProfiles.ps1'
    $dry = & $rep -TpDir $tpd.FullName -HintDirs $hints *>&1 | Out-String   # back up + write only when something can be fixed
    $o = if ($dry -match 'resolvable=([1-9]\d*)') { & $rep -TpDir $tpd.FullName -HintDirs $hints -BackupRoot (Join-Path $ManifestDir 'backup') -Apply *>&1 | Out-String } else { '' }
    $done = @([regex]::Matches($o, '(?m)^fixed (\S+)\.xml') | ForEach-Object { $_.Groups[1].Value })
    $left = @($gone | Where-Object { $done -notcontains $_ })
    if ($left) { Set-Content $memo (($left | Sort-Object) -join ',') } else { Remove-Item $memo -ErrorAction SilentlyContinue }
    if ($done) { $gDid += "$($tpd.Name): game path repaired for $($done -join ', ')" }
    if ($left) { $gWarn +="$($tpd.Name): game files not found for $($left -join ', ')" }
  } else { $gWarn += "$($tpd.Name): game path broken for $($gone -join ', ')" }
}
$gInfo = ''
$gj = Join-Path $ManifestDir 'games.json'
if (Test-Path $gj) {
  $glist = @((Get-Content $gj -Raw | ConvertFrom-Json).games)
  # only the games this cabinet plays (a shooter on the racing cabinet is not its problem)
  $myModes = @(if ($cab) { $cab.capabilities.modes }); if ($myModes) { $glist = @($glist | Where-Object { $myModes -contains $_.category }) }
  $cant = @($glist | Where-Object { -not @($_.variants.PSObject.Properties | Where-Object { $_.Value.ok }).Count })
  $why = @($cant | ForEach-Object { @($_.variants.PSObject.Properties | ForEach-Object { $_.Value.problem } | Where-Object { $_ })[0] }) | Group-Object | ForEach-Object { "$($_.Count) $($_.Name -replace '-', ' ')" }
  $gInfo = "{0} of {1} games can start" -f ($glist.Count - $cant.Count), $glist.Count
  if ($cant) { $gInfo += "; $($cant.Count) can't" + $(if ($why) { " ($($why -join ', '))" } else { '' }) + " - list with reasons: manifest\games-cant-start.txt" }
}
if ($gWarn) { Add-Result 'games' $checks.games 'WARN' ((@($gWarn) + @($gDid) + @($gInfo) | Where-Object { $_ }) -join '; ') }
elseif ($gDid) { Add-Result 'games' $checks.games 'FIXED' ((@($gDid) + @($gInfo) | Where-Object { $_ }) -join '; ') }
else { Add-Result 'games' $checks.games 'OK' $(if ($gInfo) { $gInfo } else { 'every TeknoParrot game path in this frontend exists' }) }

# pedals: TeknoParrot profiles this frontend launches whose brake or clutch sits on the wrong pedal (Repair-TPPedals:
# Logitech layout gas Y / brake RotationZ / clutch Slider0, backup first). Only the installs the frontend's own launchers
# start - never another frontend's copy. A fingerprint (profile count + newest change per install) skips the scan
# when nothing changed since the last clean check.
Emit @{ type = 'step'; id = 'pedals'; label = $checks.pedals; status = 'run' }
$tpDirs = @(Get-ChildItem (Join-Path $RetroFE 'launchers.windows') -Filter *.conf -File -ErrorAction SilentlyContinue | ForEach-Object {
  $m = Select-String -LiteralPath $_.FullName -Pattern '^\s*executable\s*=\s*(.+TeknoParrotUi\.exe)\s*$' | Select-Object -First 1
  if ($m) { $e = $m.Matches[0].Groups[1].Value.Trim().Trim('"'); if (-not [IO.Path]::IsPathRooted($e)) { $e = Join-Path $RetroFE $e }; Split-Path $e } } |
  Where-Object { Test-Path (Join-Path $_ 'UserProfiles') } | Sort-Object -Unique)
if (-not $tpDirs) { Add-Result 'pedals' $checks.pedals 'OK' 'no TeknoParrot launcher in this frontend' }
else {
  $fp = ($tpDirs | ForEach-Object { $fs = @(Get-ChildItem (Join-Path $_ 'UserProfiles') -Filter *.xml -File -ErrorAction SilentlyContinue); $n = 0L; foreach ($f in $fs) { if ($f.LastWriteTimeUtc.Ticks -gt $n) { $n = $f.LastWriteTimeUtc.Ticks } }; "$_|$($fs.Count)|$n" }) -join ';'
  $fpFile = Join-Path $ManifestDir 'pedals.fingerprint'
  if ((Test-Path $fpFile) -and (Get-Content $fpFile -Raw).Trim() -eq $fp) { Add-Result 'pedals' $checks.pedals 'OK' "unchanged since the last check ($($tpDirs.Count) TeknoParrot installs)" }
  else {
    $rep = Join-Path $PSScriptRoot 'Repair-TPPedals.ps1'
    $o = & $rep -TpDir $tpDirs *>&1 | Out-String
    $wrong = [regex]::Match($o, '(\d+) profile\(s\) with the brake or clutch on the wrong pedal')
    if ($wrong.Success -and $fix) {
      $o2 = & $rep -TpDir $tpDirs -BackupRoot (Join-Path $ManifestDir 'backup') -Apply *>&1 | Out-String
      $done = @([regex]::Matches($o2, '(?m)^fixed (\S+)') | ForEach-Object { $_.Groups[1].Value })
      Add-Result 'pedals' $checks.pedals 'FIXED' "brake / clutch back on the right pedal in $($done -join ', ') (profiles backed up)"
    } elseif ($wrong.Success) { Add-Result 'pedals' $checks.pedals 'WARN' "$($wrong.Groups[1].Value) game(s) have the brake or clutch on the wrong pedal - Repair-TPPedals.ps1 -Apply" }
    else { Add-Result 'pedals' $checks.pedals 'OK' "every TeknoParrot game uses clutch LEFT, brake MIDDLE, gas RIGHT" }
    # remember the state only when it is clean (after a fix the files changed: recompute)
    if (-not $wrong.Success -or $fix) {
      $fp = ($tpDirs | ForEach-Object { $fs = @(Get-ChildItem (Join-Path $_ 'UserProfiles') -Filter *.xml -File -ErrorAction SilentlyContinue); $n = 0L; foreach ($f in $fs) { if ($f.LastWriteTimeUtc.Ticks -gt $n) { $n = $f.LastWriteTimeUtc.Ticks } }; "$_|$($fs.Count)|$n" }) -join ';'
      Set-Content $fpFile $fp -Encoding ascii
    }
  }
}
# logs
Emit @{ type = 'step'; id = 'logs'; label = $checks.logs; status = 'run' }
$did = @(); $log = Join-Path $RetroFE 'log.txt'
if ((Test-Path $log) -and (Get-Item $log).Length -gt 20MB -and $fix) { Move-Item $log "$log.$(Get-Date -f yyyyMMdd-HHmmss).old" -Force; $did += 'log.txt rotated' }
foreach ($old in Get-ChildItem $RetroFE -Filter '*.old' -File | Sort-Object LastWriteTime -Descending | Select-Object -Skip 3) { if ($fix) { Remove-Item $old.FullName -Force } }
$crash = @(Get-ChildItem $RetroFE -Directory -Filter 'crash-*' | Sort-Object Name -Descending)
if ($crash.Count -gt 10 -and $fix) { $crash | Select-Object -Skip 10 | Remove-Item -Recurse -Force; $did += "pruned $($crash.Count - 10) old crash folder(s)" }
if ($did) { Add-Result 'logs' $checks.logs 'FIXED' ($did -join '; ') } else { Add-Result 'logs' $checks.logs 'OK' "$($crash.Count) crash folder(s) kept" }

# disk
Emit @{ type = 'step'; id = 'disk'; label = $checks.disk; status = 'run' }
$drv = (Get-Item $RetroFE).PSDrive; $free = [Math]::Round($drv.Free / 1GB, 1)
if ($free -lt 5) { Add-Result 'disk' $checks.disk 'WARN' "only $free GB free on $($drv.Name):" } else { Add-Result 'disk' $checks.disk 'OK' "$free GB free on $($drv.Name):" }

# art
Emit @{ type = 'step'; id = 'art'; label = $checks.art; status = 'run' }
$did = @(); $lay = Get-Setting 'layout'
if (-not (Test-Path (Join-Path $RetroFE "layouts\$lay\images\intro\intro_title.png")) -and $fix) { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'New-CabinetIntro.ps1') -RetroFE $RetroFE -ManifestDir $ManifestDir -Layout $lay | Out-Null; $did += 'boot intro regenerated' }
$tools = Join-Path $RetroFE 'collections\Tools'
# every cabinet needs a way into its settings from the game menu: install the Tools list when a build has none
if (-not (Test-Path $tools) -and $fix -and (Test-Path (Join-Path $RetroFE 'collections\Main\menu.txt'))) { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'New-CabinetToolsCollection.ps1') -RetroFE $RetroFE -ManifestDir $ManifestDir | Out-Null; $did += 'Tools (settings) list installed on the main menu' }
# button lights: a copied build still points LEDBlinky at the build it was copied from (often the live frontend, which
# LEDBlinky then writes to). When the build has its own LEDBlinky folder, use it, and point its Settings.ini there too.
$lbDir = Get-Setting 'LEDBlinkyDirectory'; $ownLb = Join-Path $RetroFE 'LEDBlinky'
if ($fix -and $lbDir -and (Test-Path (Join-Path $ownLb 'LEDBlinky.exe')) -and ([IO.Path]::GetFullPath($lbDir).TrimEnd('\') -ne [IO.Path]::GetFullPath($ownLb).TrimEnd('\'))) {
  $oldRoot = Split-Path ([IO.Path]::GetFullPath($lbDir).TrimEnd('\'))
  Set-Setting 'LEDBlinkyDirectory' $ownLb
  $ini = Join-Path $ownLb 'Settings.ini'
  if (Test-Path $ini) {
    if (-not (Test-Path "$ini.am-ledblinky")) { Copy-Item $ini "$ini.am-ledblinky" }
    $txt = [IO.File]::ReadAllText($ini, [Text.Encoding]::Default)
    [IO.File]::WriteAllText($ini, $txt.Replace($oldRoot, $RetroFE.TrimEnd('\')), [Text.Encoding]::Default)
  }
  $did += "button lights use this build's own LEDBlinky (was $lbDir)"
}
if ((Test-Path (Join-Path $tools 'ARCADEMASTER-TOOLS.txt')) -and -not (Get-ChildItem (Join-Path $tools 'medium_artwork\video') -File -ErrorAction SilentlyContinue) -and $fix) { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'New-ToolsArt.ps1') -RetroFE $RetroFE -ManifestDir $ManifestDir | Out-Null; $did += 'Tools art regenerated' }
if ($did) { Add-Result 'art' $checks.art 'FIXED' ($did -join '; ') } else { Add-Result 'art' $checks.art 'OK' 'present' }

# summary + last-known-good snapshot
$warn = @($results | Where-Object { $_.state -eq 'WARN' }).Count; $fixed = @($results | Where-Object { $_.state -eq 'FIXED' }).Count
$summary = [ordered]@{ at = (Get-Date).ToString('s'); ok = @($results | Where-Object { $_.state -eq 'OK' }).Count; fixed = $fixed; warn = $warn; checks = $results; lkg = $null }
if ($Snapshot -and (Test-Path $sc)) {
  $dir = Join-Path $lkgRoot (Get-Date -f 'yyyyMMdd-HHmmss'); New-Item -ItemType Directory -Force $dir | Out-Null
  foreach ($f in $lkgFiles) { $s = Join-Path $RetroFE $f; if (Test-Path $s) { $d = Join-Path $dir $f; New-Item -ItemType Directory -Force (Split-Path $d) | Out-Null; Copy-Item $s $d } }
  New-Item -ItemType Directory -Force (Join-Path $dir 'launchers.windows') | Out-Null; Copy-Item (Join-Path $RetroFE 'launchers.windows\*.conf') (Join-Path $dir 'launchers.windows') -ErrorAction SilentlyContinue
  # runtime: core files only (the full runtime is 400+ MB); kept once, refreshed when retrofe.exe changes
  $rtDst = Join-Path $lkgRoot 'runtime'; New-Item -ItemType Directory -Force $rtDst | Out-Null
  foreach ($n in $need) { $s = Join-Path $rt $n; $d = Join-Path $rtDst $n; if ((Test-Path $s) -and (-not (Test-Path $d) -or (Get-Item $s).LastWriteTime -gt (Get-Item $d).LastWriteTime)) { Copy-Item $s $d -Force } }
  Get-ChildItem $lkgRoot -Directory | Where-Object { $_.Name -ne 'runtime' } | Sort-Object Name -Descending | Select-Object -Skip 3 | Remove-Item -Recurse -Force
  $summary.lkg = $dir
}
New-Item -ItemType Directory -Force $ManifestDir | Out-Null
$summary | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $ManifestDir 'health.json') -Encoding UTF8
Emit @{ type = 'tiles'; tiles = @(@{ label = 'OK'; value = "$($summary.ok)"; icon = 'rebuild' }, @{ label = 'FIXED'; value = "$fixed"; icon = 'repair' }, @{ label = 'NEEDS A LOOK'; value = "$warn"; icon = 'detect' }) }
Write-Host ("health: {0} ok, {1} fixed, {2} warning(s){3}" -f $summary.ok, $fixed, $warn, $(if ($summary.lkg) { "; last-known-good saved" } else { '' }))
exit 0
