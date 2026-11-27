<#
.SYNOPSIS
  Logitech G HUB's app off (or back on) on a cabinet - Logitech's drivers stay.

  What G HUB was doing, and who does it after -Off (DESKTOP-RACE2, 2026-11-26):
  - force feedback, Options / dial / PS buttons: Logitech's drivers (logi_joy_*), not the app. They stay installed and
    keep working with the app closed (SDL constant-force test: the wheel turned 49 degrees with lghub_agent stopped).
    Uninstalling G HUB removes the drivers too - that is what took them away on RACE1. So: never uninstall, only -Off.
  - key mappings (G24 dial press = Enter, G25 PS = Escape): AmPanel's pad keys (src\panel\PadKeys.cs), from
    <manifest>\padkeys.json, which this imports from G HUB's own settings first (tools\Import-GHubMappings.py).
  - 900 degrees, centre spring, damping: the wheel keeps its rotation; spring / damping are left to each game's FFB.

  -Off: imports the mappings, removes G HUB's logon start (HKCU Run "LGHUB", saved to <manifest>\ghub-off.json),
        closes lghub_system_tray / lghub_agent / lghub, sets the updater service to manual when it can (admin),
        restarts AmPanel (outside RetroFE's job) so the pad keys load. Warns when a mapped button is also bound in the
        menus (controls.conf joyButtonN) or in JoyToKey, where a press would then count twice.
  -On:  puts the logon start and the service back and starts G HUB; AmPanel's pad keys step aside by themselves.
  AM_SYSTEM_DRYRUN=1: says what it would do, changes nothing.
.EXAMPLE
  tools\Set-GHub.ps1 -ManifestDir D:\ArcadeMaster\manifest -RetroFE D:\ArcadeMaster\frontend\DRIVE -Show
  $env:AM_SYSTEM_DRYRUN = 1; tools\Set-GHub.ps1 -ManifestDir D:\ArcadeMaster\manifest -RetroFE D:\ArcadeMaster\frontend\DRIVE -Off
#>
param(
  [Parameter(Mandatory)][string]$ManifestDir,
  [string]$RetroFE,
  [switch]$Off,
  [switch]$On,
  [switch]$Show,
  [switch]$Force      # -Off on a G29 anyway (PS / Insert stop working)
)
$ErrorActionPreference = 'Stop'
$dry = $env:AM_SYSTEM_DRYRUN -eq '1'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$saved = Join-Path $ManifestDir 'ghub-off.json'
$amRoot = Split-Path $ManifestDir
$amExe = Join-Path $amRoot 'AmPanel.exe'
$trayExe = 'C:\Program Files\LGHUB\system_tray\lghub_system_tray.exe'
function Do-It([string]$what, [scriptblock]$act) { if ($dry) { Write-Host "  (dry run) would: $what" } else { & $act; Write-Host "  $what" } }
function Get-State {
  $run = (Get-ItemProperty $runKey -ErrorAction SilentlyContinue).LGHUB
  $svc = Get-Service LGHUBUpdaterService -ErrorAction SilentlyContinue
  [pscustomobject]@{
    installed = Test-Path $trayExe
    logonStart = [bool]$run; runValue = $run
    running = @(Get-Process lghub_agent, lghub_system_tray, lghub -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name -Unique)
    service = if ($svc) { "$($svc.Status), $($svc.StartType)" } else { 'none' }
    drivers = @(Get-CimInstance Win32_SystemDriver -Filter "Name LIKE 'logi_joy%'" | Where-Object State -eq 'Running').Count
    padkeys = Test-Path (Join-Path $ManifestDir 'padkeys.json')
  }
}
$s = Get-State
$summary = "G HUB: installed=$($s.installed), starts at logon=$($s.logonStart), running=[$($s.running -join ', ')], updater service=$($s.service); Logitech wheel drivers running: $($s.drivers); pad-key map: $(if ($s.padkeys) { 'yes' } else { 'none (G29 default in AmPanel)' })"
if ($Show -or (-not $Off -and -not $On)) { Write-Host $summary; return }
if (-not $s.installed) { Write-Host "$summary - G HUB is not installed here: nothing to switch"; return }

function Restart-AmPanel {
  if (-not (Test-Path $amExe)) { return }
  Get-Process AmPanel -ErrorAction SilentlyContinue | Where-Object { $_.Path -ieq $amExe } | Stop-Process -Force
  Start-Sleep -Milliseconds 500
  try { $r = ([wmiclass]'Win32_Process').Create("`"$amExe`" 1", $amRoot, $null); if ($r.ReturnValue -ne 0) { throw "WMI $($r.ReturnValue)" } } catch { Start-Process $amExe -ArgumentList '1' -WorkingDirectory $amRoot }
}
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($Off) {
  # A G29 sends PS and the red Insert / dial press ONLY while G HUB's app runs: with lghub_agent closed (drivers loaded)
  # neither appears as a joystick button nor on the two vendor channels - nothing at all, while Options and Share do
  # (RACE2 raw-HID test with James at the wheel, 2026-11-27). Pad keys cannot type a key for a button Windows never sees.
  $g29 = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_046D&PID_C24F' }).Count -gt 0
  if ($g29 -and -not $Force) {
    Write-Host "G HUB stays on: this cabinet has a Logitech G29, whose PS and Insert (dial press) buttons only work while G HUB's app runs (tested 2026-11-27). -Force switches it off anyway; leaving a game then needs another button (docs/06)."
    return
  }
  Write-Host "G HUB off$(if ($dry) { ' (dry run)' }):"
  if ($s.drivers -lt 1) { Write-Warning 'no Logitech wheel driver is running - force feedback and the Options / dial / PS buttons need it; check the wheel is plugged in' }
  # 1. the mappings first, so nothing is lost
  $py = (Get-Command python -ErrorAction SilentlyContinue).Source
  $imp = Join-Path $PSScriptRoot 'Import-GHubMappings.py'
  if ($py) { $o = & $py -I $imp --manifest $ManifestDir $(if ($dry) { '--show' }) 2>&1 | Out-String; Write-Host ($o.Trim() -replace '(?m)^', '  ') }
  else { Write-Warning 'python not found: G HUB mappings not imported - AmPanel uses its G29 default (dial press = Enter, PS = Escape)' }
  # 2. a mapped button that the menu or JoyToKey also reads would count twice in the menus
  $map = Join-Path $ManifestDir 'padkeys.json'
  $buttons = if (Test-Path $map) { @((Get-Content $map -Raw | ConvertFrom-Json).devices | ForEach-Object { $_.keys.button }) } else { @(23, 24) }
  if ($RetroFE) {
    $cc = Join-Path $RetroFE 'controls.conf'
    foreach ($b in $buttons) {
      if ((Test-Path $cc) -and (Select-String -LiteralPath $cc -Pattern "joyButton$b\b" -Quiet)) { Write-Host "  note: the menu also reads button $b (controls.conf joyButton$b) - fine: pad keys stay quiet while the menu is in front" }
      $jtk = Join-Path $RetroFE 'JoyToKey\Profile 1.cfg'
      if ((Test-Path $jtk) -and (Select-String -LiteralPath $jtk -Pattern "^Button$($b + 1)=1," -Quiet) -and (Test-Path $cc) -and (Select-String -LiteralPath $cc -Pattern "joyButton$b\b" -Quiet)) {
        Write-Warning "button $b is read by the menu (controls.conf) AND typed by JoyToKey (Button$($b + 1)): with G HUB off one menu press counts twice - remove one of them"
      }
    }
  }
  # 3. logon start, processes, service
  if ($s.logonStart) {
    Do-It "G HUB's logon start removed (saved to $saved)" {
      [ordered]@{ runValue = $s.runValue; service = $s.service; at = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content $saved -Encoding UTF8
      Remove-ItemProperty $runKey -Name LGHUB
    }
  }
  if ($s.running) { Do-It "closed $($s.running -join ', ')" { Get-Process lghub_system_tray, lghub_agent, lghub -ErrorAction SilentlyContinue | Stop-Process -Force } }
  if ($s.service -match 'Automatic') {
    if ($admin) { Do-It 'G HUB updater service set to manual and stopped' { Set-Service LGHUBUpdaterService -StartupType Manual; Stop-Service LGHUBUpdaterService -Force -ErrorAction SilentlyContinue } }
    else { Write-Host '  the G HUB updater service stays (needs admin to change; it only updates G HUB, it does not map keys)' }
  }
  Do-It 'AmPanel restarted - its pad keys now type the wheel keys in games' { Restart-AmPanel }
  Write-Host "  undo: tools\Set-GHub.ps1 -ManifestDir $ManifestDir -On"
}
elseif ($On) {
  Write-Host "G HUB on$(if ($dry) { ' (dry run)' }):"
  $old = if (Test-Path $saved) { Get-Content $saved -Raw | ConvertFrom-Json } else { $null }
  $val = if ($old -and $old.runValue) { $old.runValue } else { "`"$trayExe`" --minimized" }
  if (-not $s.logonStart) { Do-It 'logon start put back' { Set-ItemProperty $runKey -Name LGHUB -Value $val } }
  if ($admin -and $s.service -match 'Manual' -and $old -and "$($old.service)" -match 'Automatic') { Do-It 'G HUB updater service back to automatic' { Set-Service LGHUBUpdaterService -StartupType Automatic; Start-Service LGHUBUpdaterService -ErrorAction SilentlyContinue } }
  if (-not $s.running) { Do-It 'G HUB started' { $r = ([wmiclass]'Win32_Process').Create("`"$trayExe`" --minimized", (Split-Path $trayExe), $null) } }
  Write-Host '  AmPanel''s pad keys step aside by themselves while G HUB runs'
}
