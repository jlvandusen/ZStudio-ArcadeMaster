<#
.SYNOPSIS
  One-time setup (run elevated): the scheduled task "ArcadeMaster GPU Reset", which restarts the display adapter(s)
  with pnputil. It runs as SYSTEM, and any signed-in user may start it, so AmPanel (not elevated) can reset a stuck
  graphics driver: schtasks /run /tn "ArcadeMaster GPU Reset".
  Why: 2026-11-27 ARCADE-PEDESTAL - Pokken Tournament (TeknoParrot) exited and left the NVIDIA driver stuck. RetroFE
  then hung at start in NtGdiDdDDIGetDeviceState / nvoglv64, the screens stayed black and Alt+Tab did nothing.
  James: "can we detect it and kill and reload?" AmPanel's frontend watchdog uses this task (src/panel/AmPanel.cs).
.EXAMPLE
  Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File tools\Install-GpuReset.ps1 -RunNow'
#>
param([switch]$RunNow, [string]$ManifestDir = 'R:\ArcadeMaster\manifest')
$ErrorActionPreference = 'Stop'
$name = 'ArcadeMaster GPU Reset'
$log = Join-Path $ManifestDir 'gpu-reset.log'
# what the task runs: every present display adapter restarted, logged
$cmd = "`$l='$log'; Add-Content `$l ('[' + (Get-Date -f 'yyyy-MM-dd HH:mm:ss') + '] GPU reset asked'); " +
       "Get-PnpDevice -Class Display -PresentOnly | ForEach-Object { `$r = & pnputil.exe /restart-device `"`$(`$_.InstanceId)`" 2>&1; " +
       "Add-Content `$l ('  ' + `$_.FriendlyName + ': ' + ((`$r | Out-String).Trim() -replace '\s+', ' ')) }"
$enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
$svc = New-Object -ComObject Schedule.Service; $svc.Connect()
$def = $svc.NewTask(0)
$def.RegistrationInfo.Description = 'Restarts the display adapter when the graphics driver is stuck (ArcadeMaster AmPanel watchdog).'
$def.Settings.ExecutionTimeLimit = 'PT2M'; $def.Settings.AllowDemandStart = $true; $def.Settings.DisallowStartIfOnBatteries = $false
$def.Principal.UserId = 'S-1-5-18'; $def.Principal.LogonType = 5; $def.Principal.RunLevel = 1   # SYSTEM, highest
$act = $def.Actions.Create(0); $act.Path = 'powershell.exe'; $act.Arguments = "-NoProfile -WindowStyle Hidden -EncodedCommand $enc"
# SDDL: SYSTEM and Administrators full; Authenticated Users read + run (so the non-elevated AmPanel can start it)
$folder = $svc.GetFolder('\')
[void]$folder.RegisterTaskDefinition($name, $def, 6, 'SYSTEM', $null, 5, 'D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;AU)')
Write-Host "task '$name' registered (SYSTEM, any signed-in user may start it)"
if ($RunNow) { & schtasks.exe /run /tn $name | Out-Null; Start-Sleep 8; Get-Content $log -Tail 3 }
