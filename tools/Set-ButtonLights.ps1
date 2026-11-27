<#
.SYNOPSIS
  Who drives the panel's button lights: LEDBlinky, or ArcadeMaster's own AmPanel (docs/13-panel-service.md).
  Tools > Cabinet Settings > BUTTON LIGHTS ENGINE calls this; it can also be run by hand.

  ArcadeMaster: RetroFE calls <LEDBlinkyDirectory>\LEDBlinky.exe on every event, so LEDBlinkyDirectory is pointed at
    <ArcadeMaster>\ampanel-shim, whose LEDBlinky.exe is a copy of AmPanel: it hands each call to the running AmPanel
    and exits. AmPanel.json gets Lights = own plus the real LEDBlinky folder (PacDrive32.dll, Colors.ini, input map).
    LEDBlinky is closed and AmPanel restarted, so only one program ever drives the boards. RetroFE itself is unchanged.
    Ultimarc's drivers and LEDBlinky's data are copied into <ArcadeMaster>\panel-data and AmPanel reads them there,
    so the LEDBlinky install can go later (-Refresh at every boot keeps the copy current and moves older cut-overs).
  LEDBlinky: everything back - LEDBlinkyDirectory restored (remembered in <manifest>\button-lights.json), AmPanel back
    to shadow mode, LEDBlinky started.
.EXAMPLE
  tools\Set-ButtonLights.ps1 -RetroFE R:\ArcadeMaster\frontend\LEGENDS-am -ManifestDir R:\ArcadeMaster\manifest -Engine ArcadeMaster
  tools\Set-ButtonLights.ps1 -RetroFE R:\ArcadeMaster\frontend\LEGENDS-am -ManifestDir R:\ArcadeMaster\manifest -Engine LEDBlinky
  tools\Set-ButtonLights.ps1 -RetroFE ... -ManifestDir ... -Show
#>
param(
  [Parameter(Mandatory)][string]$RetroFE,
  [Parameter(Mandatory)][string]$ManifestDir,
  [ValidateSet('LEDBlinky', 'ArcadeMaster')][string]$Engine,
  [switch]$Show,
  [switch]$Refresh      # boot: keep AmPanel's panel-data copy current (and move a cabinet already cut over onto it)
)
$ErrorActionPreference = 'Stop'
$sc = Join-Path $RetroFE 'settings.conf'
$amRoot = Split-Path $ManifestDir
$amExe = Join-Path $amRoot 'AmPanel.exe'
$shim = Join-Path $amRoot 'ampanel-shim'
$stateFile = Join-Path $ManifestDir 'button-lights.json'
$cfgFile = Join-Path $amRoot 'AmPanel.json'
function Get-Conf([string]$k) { $m = Select-String -Path $sc -Pattern "^\s*$([regex]::Escape($k))\s*=\s*(.*)$" -ErrorAction SilentlyContinue | Select-Object -Last 1; if ($m) { $m.Matches[0].Groups[1].Value.Trim() } }
function Set-Conf([string]$k, [string]$v) {
  $l = [Collections.Generic.List[string]](Get-Content $sc); $done = $false
  for ($i = 0; $i -lt $l.Count; $i++) { if ($l[$i] -match "^\s*$([regex]::Escape($k))\s*=") { $l[$i] = "$k = $v"; $done = $true } }
  if (-not $done) { $l.Add("$k = $v") }; Set-Content $sc $l -Encoding ascii
}
function Read-Json([string]$p) { if (Test-Path $p) { Get-Content $p -Raw | ConvertFrom-Json } else { $null } }
function Stop-ByPath([string]$name, [string]$path) {
  Get-Process $name -ErrorAction SilentlyContinue | Where-Object { $_.Path -and ($_.Path -ieq $path) } | ForEach-Object { Stop-Process -Id $_.Id -Force }
}

# AmPanel must outlive this script: from Tools > Cabinet Settings this runs inside RetroFE's job object, and Windows ends
# every process of that job when the Tools page closes - an AmPanel started with Start-Process went with it (DESKTOP-RACE2
# 2026-11-26: Esc stopped ending games). WMI's Win32_Process.Create starts it outside the job.
function Start-AmPanelDetached {
  try { $r = ([wmiclass]'Win32_Process').Create("`"$amExe`" 1", $amRoot, $null); if ($r.ReturnValue -eq 0) { return } } catch { }
  Start-Process $amExe -ArgumentList '1' -WorkingDirectory $amRoot   # no WMI: as before
}
# AmPanel's own copy of what it used to read from the LEDBlinky install (gap 3 of the 2026-11-26 consolidation audit):
# Ultimarc's PacDrive32 / UltraStik32 drivers and LEDBlinky's data - colours, the input map, the [Pixelcade] settings,
# the .lwax animations and the UltraStik maps. AmPanel.json's LEDBlinkyDir then points here, so LEDBlinky can be
# uninstalled without the lights going dark. Copy only: a file is copied when it is missing here or newer at the source;
# nothing is ever deleted, at either end. Edits made through AmPanel live in the manifest (led-colors.json, the learned
# input map), never in these copies.
$panelData = Join-Path $amRoot 'panel-data'
function Copy-PanelData([string]$src) {
  if (-not $src -or -not (Test-Path (Join-Path $src 'PacDrive32.dll'))) { return $null }
  if ([IO.Path]::GetFullPath($src).TrimEnd('\') -ieq [IO.Path]::GetFullPath($panelData).TrimEnd('\')) { return $panelData }
  New-Item -ItemType Directory -Force $panelData | Out-Null
  $n = 0
  foreach ($f in 'PacDrive32.dll', 'UltraStik32.dll', 'Colors.ini', 'Color-RGB.ini', 'LEDBlinkyInputMap.xml', 'Settings.ini') {
    $s = Join-Path $src $f; $d = Join-Path $panelData $f
    if ((Test-Path $s) -and (-not (Test-Path $d) -or (Get-Item $s).LastWriteTime -gt (Get-Item $d).LastWriteTime)) { Copy-Item $s $d -Force; $n++ }
  }
  foreach ($sub in 'lwa', 'jdr\UltraStik') {
    $s = Join-Path $src $sub; if (-not (Test-Path $s)) { continue }
    foreach ($f in Get-ChildItem $s -Recurse -File) {
      $d = Join-Path (Join-Path $panelData $sub) $f.FullName.Substring($s.Length).TrimStart('\')
      if (-not (Test-Path $d) -or $f.LastWriteTime -gt (Get-Item $d).LastWriteTime) { New-Item -ItemType Directory -Force (Split-Path $d) | Out-Null; Copy-Item $f.FullName $d -Force; $n++ }
    }
  }
  $script:panelDataCopied = $n
  $panelData
}

$cur = Get-Conf 'LEDBlinkyDirectory'
$state = Read-Json $stateFile
$now = if ($cur -and ($cur.TrimEnd('\') -ieq $shim)) { 'ArcadeMaster' } else { 'LEDBlinky' }

# -Refresh (every boot): a cabinet already on the ArcadeMaster engine gets AmPanel's own panel-data copy, and later
# LEDBlinky changes (a new Colors.ini) are picked up while the LEDBlinky install is still there. Nothing to do otherwise.
if ($Refresh) {
  $cfgNow = Read-Json $cfgFile
  if ($now -ne 'ArcadeMaster' -or -not $cfgNow -or "$($cfgNow.Lights)" -ine 'own') { return }
  $src = if ($state -and $state.ledBlinkyDir -and (Test-Path (Join-Path $state.ledBlinkyDir 'PacDrive32.dll'))) { $state.ledBlinkyDir } else { $cfgNow.LEDBlinkyDir }
  $script:panelDataCopied = 0
  $pd = Copy-PanelData $src
  if (-not $pd) { return }
  $msg = @(); if ($script:panelDataCopied) { $msg += "$($script:panelDataCopied) file(s) copied to $pd" }
  if ("$($cfgNow.LEDBlinkyDir)".TrimEnd('\') -ine $pd.TrimEnd('\')) {
    $cfg = [ordered]@{}; foreach ($p in $cfgNow.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
    $cfg['LEDBlinkyDir'] = $pd; $cfg | ConvertTo-Json | Set-Content $cfgFile -Encoding ascii
    if (Get-Process AmPanel -ErrorAction SilentlyContinue | Where-Object { $_.Path -ieq $amExe }) { Stop-ByPath 'AmPanel' $amExe; Start-Sleep -Milliseconds 500; Start-AmPanelDetached }
    $msg += "AmPanel now reads its own copy ($pd), not $($cfgNow.LEDBlinkyDir)"
  }
  if ($msg) { Write-Host "button lights: $($msg -join '; ')" }
  return
}
if ($Show -or -not $Engine) { Write-Host "button lights: $now (LEDBlinkyDirectory = $cur)"; return }
if ($Engine -eq $now) { Write-Host "button lights already: $now"; return }

if ($Engine -eq 'ArcadeMaster') {
  if (-not (Test-Path $amExe)) { throw "AmPanel is not installed ($amExe) - tools\Build-AmPanel.ps1 -InstallTo $amRoot" }
  $real = if ($cur) { $cur } else { Join-Path $RetroFE 'LEDBlinky' }
  # a cabinet with no button lights (a racing rig: no LEDBlinky, no Ultimarc board) still wants AmPanel for the game
  # start / stop events - Esc ends any game (ExitGuard), the loading screen, the controller question. AmPanel then runs in
  # shadow mode with nothing to drive: only the shim goes in, AmPanel.json gets no Lights / LEDBlinkyDir.
  $eventsOnly = -not (Test-Path (Join-Path $real 'PacDrive32.dll'))
  if ($eventsOnly) {
    [ordered]@{ engine = 'ArcadeMaster'; ledBlinkyDir = ''; eventsOnly = $true; at = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content $stateFile -Encoding UTF8
    New-Item -ItemType Directory -Force $shim | Out-Null
    Copy-Item $amExe (Join-Path $shim 'LEDBlinky.exe') -Force
    Set-Conf 'LEDBlinkyDirectory' $shim
    # LEDBlinky no longer gets the events, so its Pixelcade link goes quiet: AmPanel takes the marquee when there is one
    & (Join-Path $PSScriptRoot 'Set-Marquee.ps1') -RetroFE $RetroFE -ManifestDir $ManifestDir -NoRestart 6>&1 | Out-Null
    Stop-ByPath 'AmPanel' $amExe; Start-Sleep -Milliseconds 500; Start-AmPanelDetached
    Write-Host "button lights: none on this cabinet - AmPanel gets the frontend's game events through $shim (Esc ends any game)"
    return
  }
  [ordered]@{ engine = 'ArcadeMaster'; ledBlinkyDir = $real; at = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content $stateFile -Encoding UTF8
  New-Item -ItemType Directory -Force $shim | Out-Null
  Copy-Item $amExe (Join-Path $shim 'LEDBlinky.exe') -Force
  $cfg = [ordered]@{}; $old = Read-Json $cfgFile; if ($old) { foreach ($p in $old.PSObject.Properties) { $cfg[$p.Name] = $p.Value } }
  $pd = Copy-PanelData $real   # AmPanel's own copy of the drivers and LEDBlinky's data (see Copy-PanelData)
  $cfg['Lights'] = 'own'; $cfg['LEDBlinkyDir'] = $(if ($pd) { $pd } else { $real })
  $cfg | ConvertTo-Json | Set-Content $cfgFile -Encoding ascii
  Set-Conf 'LEDBlinkyDirectory' $shim
  & (Join-Path $PSScriptRoot 'Set-Marquee.ps1') -RetroFE $RetroFE -ManifestDir $ManifestDir -NoRestart 6>&1 | Out-Null   # the marquee too
  Stop-ByPath 'LEDBlinky' (Join-Path $real 'LEDBlinky.exe')
  Stop-ByPath 'AmPanel' $amExe
  Start-Sleep -Milliseconds 500
  Start-AmPanelDetached
  Write-Host "button lights: ArcadeMaster (AmPanel owns the boards; LEDBlinky closed; RetroFE calls reach AmPanel through $shim)"
}
else {
  $real = if ($state -and $state.ledBlinkyDir) { $state.ledBlinkyDir } else { Join-Path $RetroFE 'LEDBlinky' }
  Set-Conf 'LEDBlinkyDirectory' $real
  $old = Read-Json $cfgFile
  if ($old) { $cfg = [ordered]@{}; foreach ($p in $old.PSObject.Properties) { if ($p.Name -ne 'Lights') { $cfg[$p.Name] = $p.Value } }; $cfg | ConvertTo-Json | Set-Content $cfgFile -Encoding ascii }
  [ordered]@{ engine = 'LEDBlinky'; ledBlinkyDir = $real; at = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content $stateFile -Encoding UTF8
  Stop-ByPath 'AmPanel' $amExe
  Start-Sleep -Milliseconds 500
  if (Test-Path $amExe) { Start-AmPanelDetached }   # back in shadow mode
  $lb = Join-Path $real 'LEDBlinky.exe'; if (Test-Path $lb) { Start-Process $lb -ArgumentList '1' -WorkingDirectory $real }
  Write-Host "button lights: LEDBlinky (LEDBlinkyDirectory = $real; AmPanel back in shadow mode)"
}
