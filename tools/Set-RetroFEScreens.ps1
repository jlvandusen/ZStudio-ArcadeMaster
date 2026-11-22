<#
.SYNOPSIS
  Configures RetroFE's screens from cabinet.json: screen 0 = primary display (main game screen),
  screen 1 = the second display (pedestal / marquee touchscreen: banners, game header, touch buttons
  from layouts\ArcadeMaster\layout - 1.xml). Backs up settings.conf once (settings.conf.screens-backup).
  -Single reverts to one screen.

  Touch on the second display: Windows must map the USB touch digitizer to that display ONCE
  (Control Panel > Tablet PC Settings > Setup, or run:  MultiDigiMon.exe -touch). RetroFE then knows which
  screen a finger is on, so touch1... tokens in controls.conf only react to the pedestal screen.
#>
param(
  [string]$RetroFE = 'D:\ArcadeMaster\frontend\DRIVE-coinops',
  [string]$Cabinet = 'D:\ArcadeMaster\manifest\cabinet.json',
  [switch]$Single,
  [switch]$Windowed,
  [switch]$TouchOnly          # only (re)apply the touch setting for the current numScreens - boot health check
)
$ErrorActionPreference = 'Stop'
$sc = Join-Path $RetroFE 'settings.conf'
if (-not (Test-Path "$sc.screens-backup")) { Copy-Item $sc "$sc.screens-backup" }
$lines = [System.Collections.Generic.List[string]](Get-Content $sc)
function Set-Key([string]$k, [string]$v) {
  $i = -1; for ($n = 0; $n -lt $lines.Count; $n++) { if ($lines[$n] -match "^\s*$([regex]::Escape($k))\s*=") { $i = $n; break } }
  if ($i -ge 0) { $lines[$i] = "$k = $v" } else { $lines.Add("$k = $v") }
}
$caps = (Get-Content $Cabinet -Raw | ConvertFrom-Json).capabilities
$displays = @($caps.displays)
$fs = if ($Windowed) { 'no' } else { 'yes' }
if ($TouchOnly) { $Single = ([int]("0" + (($lines | Where-Object { $_ -match '^\s*numScreens\s*=' } | Select-Object -First 1) -replace '^[^=]*=\s*', '')) -lt 2) }
elseif ($Single -or $displays.Count -lt 2) {
  Set-Key 'numScreens' '1'; Set-Key 'screenNum0' '0'
  Write-Host ("RetroFE: 1 screen ({0} display(s) detected)" -f $displays.Count)
} else {
  # SDL display index follows Windows enumeration; find the primary and the first non-primary
  $primary = [array]::IndexOf(@($displays | ForEach-Object { [bool]$_.primary }), $true); if ($primary -lt 0) { $primary = 0 }
  # the pedestal's second screen is USB-connected (DisplayLink etc.): prefer that display for screen 1
  $usbIdx = @(0..($displays.Count - 1) | Where-Object { $_ -ne $primary -and $displays[$_].usb })
  $second = if ($usbIdx) { $usbIdx[0] } else { (0..($displays.Count - 1) | Where-Object { $_ -ne $primary } | Select-Object -First 1) }
  Set-Key 'numScreens' '2'
  Set-Key 'screenNum0' "$primary"; Set-Key 'fullscreen0' $fs; Set-Key 'horizontal0' "$($displays[$primary].width)"; Set-Key 'vertical0' "$($displays[$primary].height)"
  Set-Key 'screenNum1' "$second";  Set-Key 'fullscreen1' $fs; Set-Key 'horizontal1' "$($displays[$second].width)"; Set-Key 'vertical1' "$($displays[$second].height)"
  Write-Host ("RetroFE: 2 screens - screen 0 = display {0} ({1}x{2}), screen 1 = display {3} ({4}x{5})" -f $primary, $displays[$primary].width, $displays[$primary].height, $second, $displays[$second].width, $displays[$second].height)
}
if (-not $TouchOnly) { Set-Content $sc $lines -Encoding ascii }

# mouse-type touch board + 2 screens (and no real digitizer) -> RetroFE turns clicks on screen 1 into fingers
$cc = Join-Path $RetroFE 'controls.conf'
if (Test-Path $cc) {
  $mouseTouch = (-not $Single) -and $displays.Count -ge 2 -and @($caps.touchControllers).Count -gt 0 -and -not [int]$caps.touchScreens
  $cl = [System.Collections.Generic.List[string]](Get-Content $cc)
  $at = -1; for ($n = 0; $n -lt $cl.Count; $n++) { if ($cl[$n] -match '^\s*mouseTouchScreens\s*=') { $at = $n; break } }
  $want = if ($mouseTouch) { 'mouseTouchScreens = 1' } else { $null }
  $have = if ($at -ge 0) { $cl[$at].Trim() } else { $null }
  if ($want -ne $have) {
    if (-not (Test-Path "$cc.screens-backup")) { Copy-Item $cc "$cc.screens-backup" }
    if ($at -ge 0) { $cl.RemoveAt($at) }
    if ($want) { $cl.Add($want) }
    Set-Content $cc $cl -Encoding ascii; Write-Host "touch: CHANGED controls.conf mouseTouchScreens -> $(if ($want) { '1' } else { 'removed' })"
  }
  Write-Host $(if ($mouseTouch) { "touch: mouse-type board ($(@($caps.touchControllers)[0])) -> clicks on screen 1 become touches" } else { 'touch: no mouse-type touch board on a second screen' })
}
