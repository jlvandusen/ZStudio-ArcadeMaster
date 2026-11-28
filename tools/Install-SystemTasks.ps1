<#
.SYNOPSIS
  Every system-level part of ArcadeMaster (things only an administrator may set up) in one place, so an install asks
  Windows for admin rights ONCE (James 2026-11-28: "how do we apply this and other system level items as part of the
  installation"). Each item is a small installer of its own; this runs the ones that are missing or older than this
  copy of ArcadeMaster, and records what it did in <manifest>\system-tasks.json.
    gpureset  Install-GpuReset.ps1  "ArcadeMaster GPU Reset": the frontend watchdog resets a stuck graphics driver
    usbheal   Install-UsbHeal.ps1   "ArcadeMaster USB Heal": failed USB devices removed + hardware scanned (touch, lights)
  A new system-level item: write its Install-*.ps1 (SYSTEM task, the command stored in the task, any signed-in user may
  start it), add a line to $items, raise its version when its task changes. Install.ps1, "Set up this PC" and the
  health check (Repair-ArcadeHealth: "System helpers") then bring it to every PC - an update lands the new item, the
  health check says it is waiting, and the next "Set up this PC" (or this script) installs it with one admin prompt.
    -Check   which items are missing / out of date (no admin needed), JSON; exit 0 = all in place, 1 = some waiting
  Not elevated and not -Check: asks Windows once (UAC) and runs itself elevated.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\Install-SystemTasks.ps1 -ManifestDir R:\ArcadeMaster\manifest
#>
param([string]$ManifestDir = 'R:\ArcadeMaster\manifest', [switch]$Check, [switch]$Force)
$ErrorActionPreference = 'Stop'
$items = @(
  @{ id = 'gpureset'; task = 'ArcadeMaster GPU Reset'; script = 'Install-GpuReset.ps1'; version = 1 }
  @{ id = 'usbheal'; task = 'ArcadeMaster USB Heal'; script = 'Install-UsbHeal.ps1'; version = 1 }
)
$state = Join-Path $ManifestDir 'system-tasks.json'
$done = @{}; if (Test-Path $state) { try { (Get-Content $state -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $done[$_.Name] = [int]$_.Value } } catch { } }
# a task installed before this record existed counts as version 1
function Get-Recorded($it) { if ($done.ContainsKey($it.id)) { [int]$done[$it.id] } elseif (Get-ScheduledTask -TaskName $it.task -ErrorAction SilentlyContinue) { 1 } else { 0 } }
function Get-Waiting {
  @($items | Where-Object { $Force -or -not (Get-ScheduledTask -TaskName $_.task -ErrorAction SilentlyContinue) -or (Get-Recorded $_) -lt $_.version })
}
$waiting = Get-Waiting
if ($Check) {
  [ordered]@{ waiting = @($waiting | ForEach-Object { $_.id }); items = @($items | ForEach-Object { [ordered]@{ id = $_.id; task = $_.task; installed = [bool](Get-ScheduledTask -TaskName $_.task -ErrorAction SilentlyContinue); version = $_.version; recorded = (Get-Recorded $_) } }) } | ConvertTo-Json -Depth 4
  exit $(if ($waiting.Count) { 1 } else { 0 })
}
if (-not $waiting.Count) { Write-Host 'system helpers: all in place'; exit 0 }
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
  Write-Host ("system helpers: {0} - Windows asks once for admin rights" -f (($waiting | ForEach-Object { $_.task }) -join ', '))
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-ManifestDir', "`"$ManifestDir`"") + $(if ($Force) { @('-Force') } else { @() })
  try { $p = Start-Process powershell -Verb RunAs -ArgumentList $a -PassThru -Wait -WindowStyle Hidden } catch { Write-Host 'system helpers: not installed (admin rights refused) - "Set up this PC" asks again'; exit 1 }
  $done = @{}; if (Test-Path $state) { (Get-Content $state -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $done[$_.Name] = [int]$_.Value } }
  $left = Get-Waiting
  if ($left.Count) { Write-Host ("system helpers: still waiting: {0}" -f (($left | ForEach-Object { $_.task }) -join ', ')); exit 1 }
  Write-Host 'system helpers: all in place'; exit 0
}
foreach ($it in $waiting) {
  try {
    & (Join-Path $PSScriptRoot $it.script) -ManifestDir $ManifestDir | Out-Null
    if (Get-ScheduledTask -TaskName $it.task -ErrorAction SilentlyContinue) { $done[$it.id] = $it.version; Write-Host "  ok  $($it.task)" } else { Write-Host "  !!  $($it.task) not registered" }
  } catch { Write-Host "  !!  $($it.task): $($_.Exception.Message)" }
}
New-Item -ItemType Directory -Force $ManifestDir | Out-Null
$done | ConvertTo-Json | Set-Content $state -Encoding UTF8
