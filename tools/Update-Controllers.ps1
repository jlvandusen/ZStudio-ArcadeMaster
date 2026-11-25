<#
.SYNOPSIS
  A controller was plugged in or pulled: bring the cabinet up to date without a reboot. Run by AmPanel's hot-plug
  listener (WM_DEVICECHANGE, debounced); the same device steps Start-ArcadeMaster runs at boot, minus the wheel wait:
    Get-CabinetDevices    capabilities + device history (cabinet.json)
    Set-DolphinControllers   Dolphin follows what is plugged in
    Update-ControllerIds  game profiles re-pointed when a device's id moved
    Set-CabinetMode       racing / flight / gun mode follows the hardware
    menus                 rebuilt only when the cabinet's modes changed
  Ends with one line for the tray:  CHANGED: wheel False -> True; gamepads 0 -> 1     (or  CHANGED: nothing)
.EXAMPLE
  tools\Update-Controllers.ps1 -RetroFE R:\ArcadeMaster\frontend\LEGENDS-am -ManifestDir R:\ArcadeMaster\manifest
#>
param([Parameter(Mandatory)][string]$RetroFE, [Parameter(Mandatory)][string]$ManifestDir)
$ErrorActionPreference = 'Continue'
$t = $PSScriptRoot
$cab = Join-Path $ManifestDir 'cabinet.json'; $hist = Join-Path $ManifestDir 'device-history.json'
$prev = if (Test-Path $cab) { (Get-Content $cab -Raw | ConvertFrom-Json).capabilities } else { $null }
function Run([string]$script, [string[]]$a) { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $t $script) @a 2>&1 | Out-String }

[void](Run 'Get-CabinetDevices.ps1' @('-Out', $cab, '-History', $hist))
$now = (Get-Content $cab -Raw | ConvertFrom-Json).capabilities
$dol = Run 'Set-DolphinControllers.ps1' @('-ManifestDir', $ManifestDir)
$ids = Run 'Update-ControllerIds.ps1' @('-RetroFE', $RetroFE, '-Cabinet', $cab, '-History', $hist, '-Apply')
[void](Run 'Set-CabinetMode.ps1' @('-RetroFE', $RetroFE, '-ManifestDir', $ManifestDir))
$notes = @()
# which games now give a choice of controller (asked at game start)
. (Join-Path $t 'lib\AmPython.ps1'); $py = Find-AmPython
if ($py) { $ch = & $py (Join-Path $t 'New-ControllerChoices.py') --manifest $ManifestDir 2>&1 | Out-String; if ($ch -match 'on this cabinet: (\d+)') { $choiceGames = [int]$Matches[1] } }
if ($ids -match 'APPLIED: (\d+)' -and [int]$Matches[1] -gt 0) { $notes += "re-pointed $($Matches[1]) game profile(s)" }
if ($dol -match '->') { $notes += 'Dolphin updated' }

# menus only when what the cabinet can play changed (a wheel or a flight stick arrived / left)
$modesNow = (@($now.modes) | Sort-Object) -join ','; $modesFile = Join-Path $ManifestDir 'last-modes.txt'
$modesLast = if (Test-Path $modesFile) { (Get-Content $modesFile -Raw).Trim() } else { '' }
if ($modesNow -ne $modesLast) {
  [void](Run 'New-RetroFECollections.ps1' @('-RetroFE', $RetroFE, '-Cabinet', $cab, '-Manifest', (Join-Path $ManifestDir 'games.json'), '-RebuildDatabase'))
  Set-Content $modesFile $modesNow
  $notes += "menus rebuilt for modes $modesNow (restart the frontend to see them)"
}

# what changed, in words, for the tray
$diff = @()
foreach ($k in 'wheel', 'pedals', 'ffb', 'flightStick', 'lightguns', 'gamepads', 'trackball', 'arcadeSticks', 'players', 'touchScreens') {
  $a = if ($prev) { "$($prev.$k)" } else { '' }; $b = "$($now.$k)"
  if ($a -ne $b) { $diff += "$k $a -> $b" }
}
Write-Host ("CHANGED: " + $(if ($diff) { $diff -join '; ' } else { 'nothing' }) + $(if ($notes) { ' | ' + ($notes -join '; ') } else { '' }))
