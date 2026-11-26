<#
.SYNOPSIS
  Starts (or restarts) the small helpers that run beside the frontend - the cabinet link (AmLink.ps1) and hold-to-exit
  (Watch-GameExit.ps1) - under the launcher that is already running, so a new helper or a fixed one is in use without a
  reboot or closing the frontend. With no launcher running it does nothing: the next start brings them up.
.EXAMPLE
  tools\Restart-CabinetHelpers.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE-coinops
#>
param(
  [Parameter(Mandatory)][string]$RetroFE,
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest'
)
$ErrorActionPreference = 'Stop'
$launcher = Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^(powershell|pwsh)\.exe$' -and $_.CommandLine -match 'Start-ArcadeMaster\.ps1' } | Select-Object -First 1
if (-not $launcher) { Write-Host 'no launcher running - the helpers start with the next start of the frontend'; return }
$lp = [int]$launcher.ProcessId
foreach ($p in Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match '(AmLink|Watch-GameExit)\.ps1' -and $_.Name -match '^(powershell|pwsh)\.exe$' }) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 800
Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $PSScriptRoot 'Watch-GameExit.ps1')`"", '-ManifestDir', "`"$ManifestDir`"", '-ParentPid', "$lp") -WindowStyle Hidden
Write-Host 'hold-to-exit: started'
$conf = Join-Path $RetroFE 'settings.conf'; $cat = Join-Path (Split-Path $PSScriptRoot) 'catalog\cabinet-link.json'
$line = Select-String -LiteralPath $conf -Pattern '^\s*linkEvents\s*=\s*(\S+)' | Select-Object -Last 1
if ($line -and $line.Matches[0].Groups[1].Value -match '^(yes|true|1)$' -and (Test-Path $cat)) {
  $lk = Get-Content $cat -Raw | ConvertFrom-Json
  Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $PSScriptRoot 'AmLink.ps1')`"", '-RetroFE', "`"$RetroFE`"", '-ManifestDir', "`"$ManifestDir`"", '-IdleSec', "$([int]$lk.idleSec)", '-CountdownSec', "$([int]$lk.countdownSec)", '-ParentPid', "$lp") -WindowStyle Hidden
  Write-Host 'cabinet link: started'
} else { Write-Host 'cabinet link: off on this cabinet (settings.conf linkEvents)' }
