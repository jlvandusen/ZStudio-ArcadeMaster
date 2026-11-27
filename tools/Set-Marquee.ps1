<#
.SYNOPSIS
  Finds a Pixelcade LED marquee on this cabinet and lets AmPanel drive it, with no hand-edited config.

  Why: once AmPanel's shim stands in for LEDBlinky.exe (Set-ButtonLights.ps1), RetroFE's events never reach the real
  LEDBlinky, so LEDBlinky's own Pixelcade link (UsePixelcade=1) goes quiet - the 2P stand-up's marquee stopped (James,
  2026-11-26). AmPanel has driven Pixelcade itself since docs/20 (src\panel\Marquee.cs), but only with
  AmPanel.json "Marquee": "pixelcade", which nothing wrote.

  Pixelcade is found by, in order: AmPanel.json PixelcadeDir; LEDBlinky's Settings.ini [Pixelcade] PixelcadeFolder;
  a running Pixelcade listener (java / pixelweb started from a folder with pixelweb.exe); <drive>:\Pixelcade and
  %USERPROFILE%\pixelcade; or a listener answering http://127.0.0.1:8080/v2/info.

  Only acts when RetroFE's events go to AmPanel (LEDBlinkyDirectory = the shim). With the real LEDBlinky in charge,
  LEDBlinky drives the marquee as before and nothing is changed. "Marquee": "off" in AmPanel.json is respected
  (-Off writes it; -On removes it again). A change restarts AmPanel (outside RetroFE's job), so it takes effect now.
  Idempotent: the boot runs it every time.
.EXAMPLE
  tools\Set-Marquee.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE -ManifestDir D:\ArcadeMaster\manifest
  tools\Set-Marquee.ps1 -RetroFE ... -ManifestDir ... -Show
  tools\Set-Marquee.ps1 -RetroFE ... -ManifestDir ... -Off
#>
param(
  [Parameter(Mandatory)][string]$RetroFE,
  [Parameter(Mandatory)][string]$ManifestDir,
  [switch]$Show,
  [switch]$Off,
  [switch]$On,
  [switch]$NoRestart
)
$ErrorActionPreference = 'Stop'
$amRoot = Split-Path $ManifestDir
$amExe = Join-Path $amRoot 'AmPanel.exe'
$shim = Join-Path $amRoot 'ampanel-shim'
$cfgFile = Join-Path $amRoot 'AmPanel.json'
$sc = Join-Path $RetroFE 'settings.conf'

function Read-Json([string]$p) { if (Test-Path $p) { try { Get-Content $p -Raw | ConvertFrom-Json } catch { $null } } }
function Get-Conf([string]$k) { $m = Select-String -Path $sc -Pattern "^\s*$([regex]::Escape($k))\s*=\s*(.*)$" -ErrorAction SilentlyContinue | Select-Object -Last 1; if ($m) { $m.Matches[0].Groups[1].Value.Trim() } }
function Test-PixelcadeDir([string]$d) { $d -and (Test-Path -LiteralPath (Join-Path $d 'pixelweb.exe')) }
function Get-IniPixelcadeDir([string]$lb) {
  if (-not $lb) { return $null }
  $ini = Join-Path $lb 'Settings.ini'; if (-not (Test-Path $ini)) { return $null }
  $in = $false
  foreach ($l in Get-Content $ini) {
    $t = $l.Trim()
    if ($t.StartsWith('[')) { $in = $t -ieq '[Pixelcade]'; continue }
    if ($in -and $t -match '^PixelcadeFolder\s*=\s*(.+)$') { return $Matches[1].Trim() }
  }
  $null
}
function Test-Listener {
  try {
    $r = Invoke-WebRequest 'http://127.0.0.1:8080/v2/info' -UseBasicParsing -TimeoutSec 2
    return ($r.Content -match '"type"')
  } catch { return $false }
}

$cfg = [ordered]@{}; $old = Read-Json $cfgFile; if ($old) { foreach ($p in $old.PSObject.Properties) { $cfg[$p.Name] = $p.Value } }
$lbConf = Get-Conf 'LEDBlinkyDirectory'
$viaShim = $lbConf -and ($lbConf.TrimEnd('\') -ieq $shim.TrimEnd('\'))

# the real LEDBlinky folder (its Settings.ini knows the Pixelcade folder and the texts this cabinet used)
$state = Read-Json (Join-Path $ManifestDir 'button-lights.json')
$lbDirs = @($cfg['LEDBlinkyDir'], $(if ($state) { $state.ledBlinkyDir }), $(if (-not $viaShim) { $lbConf }), (Join-Path $RetroFE 'LEDBlinky')) | Where-Object { $_ } | Select-Object -Unique
$realLb = $lbDirs | Where-Object { Test-Path (Join-Path $_ 'Settings.ini') } | Select-Object -First 1

# find Pixelcade
$found = $null; $how = $null
$cands = New-Object System.Collections.Generic.List[object]
if ($cfg['PixelcadeDir']) { $cands.Add(@($cfg['PixelcadeDir'], 'AmPanel.json')) }
foreach ($lb in $lbDirs) { $d = Get-IniPixelcadeDir $lb; if ($d) { $cands.Add(@($d, "LEDBlinky Settings.ini ($lb)")) } }
try {
  Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe' OR Name='pixelweb.exe'" | ForEach-Object {
    $p = $_.ExecutablePath; if (-not $p) { return }
    $d = Split-Path $p
    for ($i = 0; $i -lt 4 -and $d; $i++) { if (Test-PixelcadeDir $d) { $cands.Add(@($d, 'running listener')); break }; $d = Split-Path $d }
  }
} catch { }
foreach ($dr in [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }) { $cands.Add(@((Join-Path $dr.RootDirectory.FullName 'Pixelcade'), 'drive root')) }
$cands.Add(@((Join-Path $env:USERPROFILE 'pixelcade'), 'user folder'))
foreach ($c in $cands) { if (Test-PixelcadeDir $c[0]) { $found = (Resolve-Path -LiteralPath $c[0]).Path; $how = $c[1]; break } }
$listening = Test-Listener

$mode = [string]$cfg['Marquee']
$summary = "Pixelcade: $(if ($found) { "$found (found via $how)" } elseif ($listening) { 'listener answering on 8080 (folder not found)' } else { 'not found' }); events go to $(if ($viaShim) { 'AmPanel' } else { "LEDBlinky ($lbConf)" }); AmPanel marquee: $(if ($mode) { $mode } else { 'not set' })"
if ($Show) { Write-Host $summary; return }

$want = [ordered]@{}; foreach ($k in $cfg.Keys) { $want[$k] = $cfg[$k] }
if ($Off) { $want['Marquee'] = 'off' }
elseif ($On -and $mode -ieq 'off') { $want.Remove('Marquee'); $mode = '' }
if (-not $Off -and $mode -ine 'off') {
  if (-not $viaShim) {
    Write-Host "$summary - LEDBlinky gets the events and drives the marquee itself: nothing changed"; return
  }
  if (-not $found -and -not $listening) { Write-Host "$summary - no marquee on this cabinet: nothing changed"; return }
  $want['Marquee'] = 'pixelcade'
  if ($found) { $want['PixelcadeDir'] = $found }
  # LEDBlinky's [Pixelcade] texts and colour: AmPanel reads them from LEDBlinkyDir (lights stay off without "Lights": "own")
  if (-not $want['LEDBlinkyDir'] -and $realLb) { $want['LEDBlinkyDir'] = $realLb }
}
$before = ($cfg | ConvertTo-Json); $after = ($want | ConvertTo-Json)
if ($before -eq $after) { Write-Host "$summary - already right"; return }
$after | Set-Content $cfgFile -Encoding ascii
$msg = if ($Off) { 'marquee: off (AmPanel leaves Pixelcade alone)' } else { "marquee: AmPanel drives Pixelcade$(if ($found) { " ($found)" })" }
if (-not $NoRestart -and (Test-Path $amExe) -and (Get-Process AmPanel -ErrorAction SilentlyContinue | Where-Object { $_.Path -ieq $amExe })) {
  Get-Process AmPanel -ErrorAction SilentlyContinue | Where-Object { $_.Path -ieq $amExe } | Stop-Process -Force
  Start-Sleep -Milliseconds 500
  # outside RetroFE's job object (a Tools page closing would end it otherwise)
  try { $r = ([wmiclass]'Win32_Process').Create("`"$amExe`" 1", $amRoot, $null); if ($r.ReturnValue -ne 0) { throw "WMI $($r.ReturnValue)" } } catch { Start-Process $amExe -ArgumentList '1' -WorkingDirectory $amRoot }
  $msg += '; AmPanel restarted'
}
Write-Host $msg
