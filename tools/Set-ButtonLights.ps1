<#
.SYNOPSIS
  Who drives the panel's button lights: LEDBlinky, or ArcadeMaster's own AmPanel (docs/13-panel-service.md).
  Tools > Cabinet Settings > BUTTON LIGHTS ENGINE calls this; it can also be run by hand.

  ArcadeMaster: RetroFE calls <LEDBlinkyDirectory>\LEDBlinky.exe on every event, so LEDBlinkyDirectory is pointed at
    <ArcadeMaster>\ampanel-shim, whose LEDBlinky.exe is a copy of AmPanel: it hands each call to the running AmPanel
    and exits. AmPanel.json gets Lights = own plus the real LEDBlinky folder (PacDrive32.dll, Colors.ini, input map).
    LEDBlinky is closed and AmPanel restarted, so only one program ever drives the boards. RetroFE itself is unchanged.
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
  [switch]$Show
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
$cur = Get-Conf 'LEDBlinkyDirectory'
$state = Read-Json $stateFile
$now = if ($cur -and ($cur.TrimEnd('\') -ieq $shim)) { 'ArcadeMaster' } else { 'LEDBlinky' }
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
    Stop-ByPath 'AmPanel' $amExe; Start-Sleep -Milliseconds 500; Start-AmPanelDetached
    Write-Host "button lights: none on this cabinet - AmPanel gets the frontend's game events through $shim (Esc ends any game)"
    return
  }
  [ordered]@{ engine = 'ArcadeMaster'; ledBlinkyDir = $real; at = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content $stateFile -Encoding UTF8
  New-Item -ItemType Directory -Force $shim | Out-Null
  Copy-Item $amExe (Join-Path $shim 'LEDBlinky.exe') -Force
  $cfg = [ordered]@{}; $old = Read-Json $cfgFile; if ($old) { foreach ($p in $old.PSObject.Properties) { $cfg[$p.Name] = $p.Value } }
  $cfg['Lights'] = 'own'; $cfg['LEDBlinkyDir'] = $real
  $cfg | ConvertTo-Json | Set-Content $cfgFile -Encoding ascii
  Set-Conf 'LEDBlinkyDirectory' $shim
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
