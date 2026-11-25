<#
.SYNOPSIS
  Manual fallback when a theme went wrong: puts the frontend back on the ArcadeMaster layout with its original style.
    settings.conf  layout = ArcadeMaster; every cabinetTheme.<mode> override removed (one line each, file backed up
                   once as settings.conf.am-bak)
    manifest       skins.json removed (copy kept as skins.json.am-bak) = the original style for every mode;
                   theme-pending.json removed (a change still waiting for its confirm)
    art            the ArcadeMaster slots and the boot intro are redrawn for it
  Also in the frontend: Tools > Reset Theme. Logged to <RetroFE>\arcademaster-launcher.log.
  -Restart: also restarts a running frontend (restart.request, then it is closed; the launcher brings it back) - for a
  desktop shortcut or a remote session when the frontend itself is unusable.
.EXAMPLE
  Reset-Theme.ps1 -RetroFE R:\ArcadeMaster\frontend\LEGENDS-am -ManifestDir R:\ArcadeMaster\manifest
#>
param(
  [string]$RetroFE = 'D:\ArcadeMaster\frontend\DRIVE-coinops',
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [switch]$NoArt,             # settings only (tests)
  [switch]$Restart
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\AmSettings.ps1'); . (Join-Path $PSScriptRoot 'lib\AmTheme.ps1')
try { $msg = Reset-AmTheme $RetroFE $ManifestDir -NoArt:$NoArt } catch { Write-Host "theme reset failed: $($_.Exception.Message)"; exit 1 }
Write-Host $msg
if ($Restart) {
  . (Join-Path $PSScriptRoot 'lib\RetroFEPaths.ps1'); $exe = Get-AmRetroFEExe $RetroFE
  $f = if ($exe) { @(Get-Process retrofe -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe }) } else { @() }
  if ($f) {
    [IO.File]::WriteAllText((Join-Path $ManifestDir 'restart.request'), 'theme reset to ArcadeMaster')
    foreach ($p in $f) { try { [void]$p.CloseMainWindow() } catch { }; if (-not $p.WaitForExit(6000)) { try { $p.Kill() } catch { } } }
    Write-Host 'frontend restarted'; Write-AmLauncherLog $RetroFE 'theme reset: frontend restarted'
  } else { Write-Host 'the frontend is not running - the reset shows at its next start' }
}
exit 0
