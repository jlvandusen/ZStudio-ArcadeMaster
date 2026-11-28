<#
.SYNOPSIS
  One-time setup (run elevated): the scheduled task "ArcadeMaster USB Heal", which brings back USB controls that
  dropped off - the touch screen, the button lights, pads. It runs as SYSTEM at start-up and every 2 minutes, and any
  signed-in user may also start it (schtasks /run /tn "ArcadeMaster USB Heal"). Each run:
    - a USB / HID device in an error state ("Unknown USB Device (Device Descriptor Request Failed)" ...) is removed
      and the hardware is scanned again, so Windows sets it up fresh - what James did by hand on the 2P stand-up to
      get its button lights back (Device Manager: uninstall the device, scan for hardware changes);
    - a touch screen or a button-light board this PC had before that is now missing gets a hardware scan.
  Nothing is done, and nothing logged, when every device is fine. Log: <manifest>\usb-heal.log.
  Why: 2026-11-28 ARCADE-PEDESTAL - the small screen's touch (USB 0483:5750) stopped; Windows showed the port as
  "Device Descriptor Request Failed". James: "I need you to perform it automagically self heal".
  The command is stored in the task itself (not a script file a user could change), as Install-GpuReset.ps1 does.
.EXAMPLE
  Start-Process powershell -Verb RunAs -ArgumentList '-NoExit -NoProfile -ExecutionPolicy Bypass -File "R:\repos\personal\ZStudio-ArcadeMaster\tools\Install-UsbHeal.ps1" -RunNow'
  Give -File a full path: an elevated PowerShell ignores -WorkingDirectory and starts in C:\Windows\System32.
#>
param([switch]$RunNow, [string]$ManifestDir = 'R:\ArcadeMaster\manifest')
$ErrorActionPreference = 'Stop'
$name = 'ArcadeMaster USB Heal'
$log = Join-Path $ManifestDir 'usb-heal.log'
# touch screens and button-light boards (Ultimarc PacDrive / I-PAC Ultimate IO / PacLED64 = VID D209) this PC has had
$watch = 'HID-compliant touch screen|VID_D209'
$cmd = @"
`$l = '$log'; `$msgs = New-Object Collections.ArrayList; function L(`$m) { [void]`$msgs.Add(`$m) }
`$all = @(Get-PnpDevice -ErrorAction SilentlyContinue)
`$bad = @(`$all | Where-Object { `$_.Present -and `$_.Status -eq 'Error' -and `$_.InstanceId -match '^(USB|HID)\\' })
`$gone = @(`$all | Where-Object { -not `$_.Present -and (`$_.FriendlyName -match '$watch' -or `$_.InstanceId -match '$watch') })
# an old copy from another port is not missing when the same device (vendor + product) is here and working
function VP(`$i) { if (`$i -match 'VID_\w{4}&PID_\w{4}') { `$matches[0] } else { `$i } }
`$back = @(`$all | Where-Object { `$_.Present -and `$_.Status -eq 'OK' } | ForEach-Object { VP `$_.InstanceId })
`$gone = @(`$gone | Where-Object { `$back -notcontains (VP `$_.InstanceId) })
# a light board counts only once this task has seen it working here (old boards from before stay quiet); a touch
# screen always counts (a cabinet that had one wants it back)
`$sf = `$l + '.seen'; `$known = @(if (Test-Path `$sf) { Get-Content `$sf })
`$now = @(`$all | Where-Object { `$_.Present -and `$_.Status -eq 'OK' -and (`$_.FriendlyName -match '$watch' -or `$_.InstanceId -match '$watch') } | ForEach-Object { VP `$_.InstanceId })
`$new = @(`$now | Where-Object { `$known -notcontains `$_ } | Sort-Object -Unique); if (`$new.Count) { Add-Content `$sf `$new; `$known += `$new }
`$seen = @{}; `$gone = @(`$gone | Where-Object { `$k = VP `$_.InstanceId; if (`$seen[`$k] -or (`$_.FriendlyName -notmatch 'touch screen' -and `$known -notcontains `$k)) { `$false } else { `$seen[`$k] = 1; `$true } })
if (-not `$bad.Count -and -not `$gone.Count) { return }
foreach (`$d in `$bad) { `$r = & pnputil.exe /remove-device "`$(`$d.InstanceId)" 2>&1; L ('removed failed device ' + `$d.FriendlyName + ' (' + `$d.InstanceId + '): ' + ((`$r | Out-String).Trim() -replace '\s+', ' ')) }
`$r = & pnputil.exe /scan-devices 2>&1; Start-Sleep 4
foreach (`$d in `$gone) { `$n = Get-PnpDevice -InstanceId `$d.InstanceId -ErrorAction SilentlyContinue; L ((`$d.FriendlyName) + ': ' + `$(if (`$n -and `$n.Present -and `$n.Status -eq 'OK') { 'back' } else { 'still missing - its USB cable or port?' })) }
if (`$bad.Count) { L ('hardware scanned: ' + ((`$r | Out-String).Trim() -replace '\s+', ' ')) }
# a device that stays broken (a bad cable) is tried every 2 minutes but logged only when something changes, or every 30 min
`$st = `$l + '.last'; `$key = (`$msgs -join '|') -replace '\(\w+&[^)]*\)', ''
`$old = if (Test-Path `$st) { Get-Item `$st } else { `$null }
if (-not `$old -or (Get-Content `$st -Raw).Trim() -ne `$key -or ((Get-Date) - `$old.LastWriteTime).TotalMinutes -ge 30) {
  foreach (`$m in `$msgs) { Add-Content `$l ('[' + (Get-Date -f 'yyyy-MM-dd HH:mm:ss') + '] ' + `$m) }; Set-Content `$st `$key }
"@
$enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
$svc = New-Object -ComObject Schedule.Service; $svc.Connect()
$def = $svc.NewTask(0)
$def.RegistrationInfo.Description = 'Removes failed USB devices and scans for hardware so touch screens, button lights and pads come back (ArcadeMaster).'
$def.Settings.ExecutionTimeLimit = 'PT2M'; $def.Settings.AllowDemandStart = $true; $def.Settings.DisallowStartIfOnBatteries = $false
$def.Settings.StopIfGoingOnBatteries = $false; $def.Settings.MultipleInstances = 2   # a run still going: skip the next
$def.Principal.UserId = 'S-1-5-18'; $def.Principal.LogonType = 5; $def.Principal.RunLevel = 1   # SYSTEM, highest
$boot = $def.Triggers.Create(8); $boot.Delay = 'PT1M'                                          # at start-up
$tick = $def.Triggers.Create(1); $tick.StartBoundary = (Get-Date).ToString("yyyy-MM-dd'T'HH:mm:ss")
$tick.Repetition.Interval = 'PT2M'                                                             # every 2 minutes, for ever
$act = $def.Actions.Create(0); $act.Path = 'powershell.exe'; $act.Arguments = "-NoProfile -WindowStyle Hidden -EncodedCommand $enc"
$folder = $svc.GetFolder('\')
# SDDL: SYSTEM and Administrators full; Authenticated Users read + run (AmPanel or a tool may start it at once)
[void]$folder.RegisterTaskDefinition($name, $def, 6, 'SYSTEM', $null, 5, 'D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;AU)')
Write-Host "task '$name' registered (SYSTEM; at start-up and every 2 minutes; any signed-in user may start it)"
if ($RunNow) { & schtasks.exe /run /tn $name | Out-Null; Start-Sleep 10; if (Test-Path $log) { Get-Content $log -Tail 6 } else { 'nothing to heal' } }
