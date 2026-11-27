<#
.SYNOPSIS
  Cabinet system switches - every one reversible (previous Windows values are saved under
  HKCU\Software\ArcadeMaster\Saved and restored when a switch is turned off).
    autoLogin       Windows signs in by itself (status from Winlogon). ON opens the Windows dialog
                    (Sysinternals Autologon if present, else netplwiz) - the password is typed there and
                    never stored by ArcadeMaster. OFF clears AutoAdminLogon (needs admin, asks UAC).
    autoStartArcade Start-ArcadeMaster.ps1 at logon (Startup shortcut, hidden console).
    quietStartup    stop OneDrive / Teams / Edge etc. auto-launching (keeps G HUB, JoyToKey, gun / DolphinBar tools).
    noOverlays      Xbox Game Bar capture overlay + Windows notification toasts off - nothing pops over a game.
    gameBezels      MAME bezel / overlay / backdrop artwork shown around games (mame.ini use_bezels ...).
    alwaysOn        display + sleep timeouts off on AC power.
.EXAMPLE
  Set-CabinetSystem.ps1 -List                     # current state, JSON
  Set-CabinetSystem.ps1 -Set quietStartup=on,noOverlays=on
#>
param(
  [switch]$List,
  [string[]]$Set,
  [string]$RetroFE = 'D:\ArcadeMaster\frontend\DRIVE-coinops',
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [switch]$NoUi          # never open Windows dialogs (scripts / tests)
)
$ErrorActionPreference = 'Stop'
$savedKey = 'HKCU:\Software\ArcadeMaster\Saved'
function Save-Value([string]$setting, [string]$name, $value) { $k = "$savedKey\$setting"; Confirm-Key $k; New-ItemProperty $k -Name $name -Value $(if ($null -eq $value) { '<none>' } else { "$value" }) -PropertyType String -Force | Out-Null }
# NEVER "New-Item -Force" on a registry key that exists: it recreates the key and wipes every value in it
function Confirm-Key([string]$k) { if (-not (Test-Path $k)) { New-Item $k -Force | Out-Null } }
function Get-Saved([string]$setting) { $k = "$savedKey\$setting"; if (Test-Path $k) { $p = Get-ItemProperty $k; $h = [ordered]@{}; foreach ($x in $p.PSObject.Properties) { if ($x.Name -notlike 'PS*') { $h[$x.Name] = $x.Value } }; return $h }; return $null }
function Clear-Saved([string]$setting) { Remove-Item "$savedKey\$setting" -Recurse -Force -ErrorAction SilentlyContinue }
function Get-Reg([string]$path, [string]$name) { (Get-ItemProperty $path -Name $name -ErrorAction SilentlyContinue).$name }
function Set-Reg([string]$path, [string]$name, $value, [string]$type = 'DWord') { Confirm-Key $path; New-ItemProperty $path -Name $name -Value $value -PropertyType $type -Force | Out-Null }
function Invoke-Elevated([string]$script) { $p = Start-Process powershell -Verb RunAs -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', $script -PassThru -Wait; return $p.ExitCode -eq 0 }
function Get-MameInis {
  $t = Join-Path $PSScriptRoot "wheelmap\targets\$env:COMPUTERNAME.json"; if (-not (Test-Path $t)) { $t = Join-Path $PSScriptRoot 'wheelmap\targets\default.json' }
  @((Get-Content $t -Raw | ConvertFrom-Json).mame | ForEach-Object { Join-Path $_.root 'mame.ini' } | Where-Object { Test-Path $_ })
}
$startup = [Environment]::GetFolderPath('Startup'); $lnk = Join-Path $startup 'ArcadeMaster.lnk'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$usbSub = '2a737441-1930-4402-8d77-b2bebba308a3'; $usbSuspend = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'   # USB settings > USB selective suspend
$keepRun ='(?i)lghub|logitech|joytokey|sinden|dolphinbar|mayflash|gun4ir|ultimarc|ledblinky|desk.?console|arcademaster|nvidia|realtek|audio'
$noisyRun = '(?i)onedrive|teams|msedge|edge|spotify|discord|steam|epic|skype|dropbox|googledrive|adobe|cortana|xbox'

$S = [ordered]@{
  autoLogin = @{ label = 'AUTO LOGIN'; detail = 'Windows signs in by itself after power-on'
    get = { (Get-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' 'AutoAdminLogon') -eq '1' }
    on = {
      if ($NoUi) { return 'needs the Windows dialog - run without -NoUi' }
      $al = @(Get-Command Autologon64.exe, Autologon.exe -ErrorAction SilentlyContinue | Select-Object -First 1)
      if ($al) { Start-Process $al[0].Source -Wait; return 'Autologon (Sysinternals) - password stored encrypted by Windows' }
      # Windows 11 hides the netplwiz checkbox unless passwordless sign-in is relaxed
      if ((Get-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device' 'DevicePasswordLessBuildVersion') -ne 0) { [void](Invoke-Elevated "New-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device' -Name DevicePasswordLessBuildVersion -Value 0 -PropertyType DWord -Force") }
      Start-Process netplwiz.exe -Wait; return 'untick "Users must enter a user name and password", then type the password in the Windows box'
    }
    off = { if (Invoke-Elevated "Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name AutoAdminLogon -Value '0'") { 'auto login off' } else { 'Windows did not allow the change (admin needed)' } }
  }
  autoStartArcade = @{ label = 'START ARCADE AT LOGON'; detail = 'Start-ArcadeMaster runs as soon as Windows signs in'
    get = { Test-Path $lnk }
    on = {
      $sh = New-Object -ComObject WScript.Shell; $l = $sh.CreateShortcut($lnk)
      $l.TargetPath = "$env:SystemRoot\System32\conhost.exe"
      $l.Arguments = "--headless $env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $PSScriptRoot 'Start-ArcadeMaster.ps1')`" -Root `"$RetroFE`" -ManifestDir `"$ManifestDir`""
      $l.WorkingDirectory = $PSScriptRoot; $l.Description = 'ArcadeMaster boot launcher'; $l.Save(); 'shortcut added to Startup'
    }
    off = { Remove-Item $lnk -Force -ErrorAction SilentlyContinue; 'shortcut removed' }
  }
  quietStartup = @{ label = 'QUIET STARTUP'; detail = 'OneDrive, Teams, Edge... stop launching with Windows (wheel / gun tools stay)'
    get = { $null -ne (Get-Saved 'quietStartup') }
    on = {
      $p = Get-ItemProperty $runKey -ErrorAction SilentlyContinue; $moved = @()
      foreach ($x in $p.PSObject.Properties) { if ($x.Name -like 'PS*') { continue }; if ($x.Name -match $noisyRun -and $x.Name -notmatch $keepRun -and "$($x.Value)" -notmatch $keepRun) { Save-Value 'quietStartup' $x.Name $x.Value; Remove-ItemProperty $runKey -Name $x.Name; $moved += $x.Name } }
      if (-not $moved) { Save-Value 'quietStartup' '_none' '' }
      "stopped: $(if ($moved) { $moved -join ', ' } else { 'nothing noisy found' })"
    }
    off = { $s = Get-Saved 'quietStartup'; $back = @(); if ($s) { foreach ($k in $s.Keys) { if ($k -ne '_none') { Set-Reg $runKey $k $s[$k] 'String'; $back += $k } } }; Clear-Saved 'quietStartup'; "restored: $(if ($back) { $back -join ', ' } else { 'nothing' })" }
  }
  noOverlays = @{ label = 'NO WINDOWS POP-UPS'; detail = 'Xbox Game Bar overlay and notification toasts stay away from games'
    get = { (Get-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled') -eq 0 -and (Get-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled') -eq 0 }
    on = {
      $vals = @(@('HKCU:\System\GameConfigStore', 'GameDVR_Enabled', 0), @('HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR', 'AppCaptureEnabled', 0),
                @('HKCU:\Software\Microsoft\GameBar', 'UseNexusForGameBarEnabled', 0), @('HKCU:\Software\Microsoft\GameBar', 'ShowStartupPanel', 0),
                @('HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications', 'ToastEnabled', 0))
      if (-not (Get-Saved 'noOverlays')) { foreach ($v in $vals) { Save-Value 'noOverlays' "$($v[0])|$($v[1])" (Get-Reg $v[0] $v[1]) } }
      foreach ($v in $vals) { Set-Reg $v[0] $v[1] $v[2] }; 'Game Bar overlay + toasts off'
    }
    off = { $s = Get-Saved 'noOverlays'; if ($s) { foreach ($k in $s.Keys) { $p, $n = $k -split '\|', 2; if ($s[$k] -eq '<none>') { Remove-ItemProperty $p -Name $n -ErrorAction SilentlyContinue } else { Set-Reg $p $n ([int]$s[$k]) } } }; Clear-Saved 'noOverlays'; 'previous Windows values restored' }
  }
  gameBezels = @{ label = 'GAME BEZELS / OVERLAYS'; detail = 'MAME shows bezel, overlay and backdrop artwork around the game'
    get = { $i = @(Get-MameInis); if (-not $i) { return $false }; $m = Select-String -Path $i[0] -Pattern '^use_bezels\s+(\d)' | Select-Object -First 1; if ($m) { $m.Matches[0].Groups[1].Value -eq '1' } else { $true } }   # MAME default is 1
    on = { $n = 0; foreach ($i in Get-MameInis) { $l = Get-Content $i; foreach ($k in 'use_backdrops', 'use_overlays', 'use_bezels', 'use_cpanels', 'use_marquees') { $hit = $false; $l = @($l | ForEach-Object { if ($_ -match "^$k\s") { $hit = $true; "{0,-26}1" -f $k } else { $_ } }); if (-not $hit) { $l += ("{0,-26}1" -f $k) } }; Set-Content $i $l -Encoding ASCII; $n++ }; "artwork on in $n MAME install(s)" }
    off = { $n = 0; foreach ($i in Get-MameInis) { $l = @(Get-Content $i | ForEach-Object { if ($_ -match '^(use_backdrops|use_overlays|use_bezels|use_cpanels|use_marquees)\s') { "{0,-26}0" -f $Matches[1] } else { $_ } }); Set-Content $i $l -Encoding ASCII; $n++ }; "artwork off in $n MAME install(s)" }
  }
  alwaysOn = @{ label = 'SCREEN ALWAYS ON'; detail = 'display never sleeps and the PC never suspends on mains power'
    get = { $v = (powercfg /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE | Select-String 'Current AC Power Setting Index:\s+0x([0-9a-f]+)').Matches[0].Groups[1].Value; $s = (powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE | Select-String 'Current AC Power Setting Index:\s+0x([0-9a-f]+)').Matches[0].Groups[1].Value; ([Convert]::ToInt32($v, 16) -eq 0) -and ([Convert]::ToInt32($s, 16) -eq 0) }
    on = {
      if (-not (Get-Saved 'alwaysOn')) { foreach ($q in @(@('SUB_VIDEO', 'VIDEOIDLE'), @('SUB_SLEEP', 'STANDBYIDLE'))) { $v = (powercfg /query SCHEME_CURRENT $q[0] $q[1] | Select-String 'Current AC Power Setting Index:\s+0x([0-9a-f]+)').Matches[0].Groups[1].Value; Save-Value 'alwaysOn' $q[1] ([Convert]::ToInt32($v, 16)) } }
      powercfg /change monitor-timeout-ac 0; powercfg /change standby-timeout-ac 0; 'display + sleep timeouts off'
    }
    off = { $s = Get-Saved 'alwaysOn'; if ($s) { powercfg /setacvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOIDLE $s['VIDEOIDLE']; powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE $s['STANDBYIDLE']; powercfg /setactive SCHEME_CURRENT }; Clear-Saved 'alwaysOn'; 'previous power timeouts restored' }
  }
  # USB devices never powered down: the 2P stand-up's Pixelcade marquee board (an idle USB serial device) dropped off
  # its hub and stayed dark until it was plugged in again (2026-11-27). USB selective suspend off in the power plan, and
  # "allow the computer to turn off this device to save power" off on every USB hub and device (that part needs admin).
  usbAlwaysOn = @{ label = 'USB ALWAYS ON'; detail = 'Windows never powers down USB devices (marquee, guns, encoders) to save energy'
    get = { $v = (powercfg /query SCHEME_CURRENT $usbSub $usbSuspend | Select-String 'Current AC Power Setting Index:\s+0x([0-9a-f]+)').Matches[0].Groups[1].Value; [Convert]::ToInt32($v, 16) -eq 0 }
    on = {
      if (-not (Get-Saved 'usbAlwaysOn')) {
        $q = powercfg /query SCHEME_CURRENT $usbSub $usbSuspend
        Save-Value 'usbAlwaysOn' 'ac' ([Convert]::ToInt32(($q | Select-String 'Current AC Power Setting Index:\s+0x([0-9a-f]+)').Matches[0].Groups[1].Value, 16))
        Save-Value 'usbAlwaysOn' 'dc' ([Convert]::ToInt32(($q | Select-String 'Current DC Power Setting Index:\s+0x([0-9a-f]+)').Matches[0].Groups[1].Value, 16))
      }
      powercfg /setacvalueindex SCHEME_CURRENT $usbSub $usbSuspend 0; powercfg /setdcvalueindex SCHEME_CURRENT $usbSub $usbSuspend 0; powercfg /setactive SCHEME_CURRENT
      $done = 0; $denied = 0; $saved = @()
      foreach ($d in @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue | Where-Object { $_.InstanceName -match '^USB' -and $_.Enable })) {
        try { Set-CimInstance -InputObject $d -Property @{ Enable = $false } -ErrorAction Stop; $saved += $d.InstanceName; $done++ } catch { $denied++ }
      }
      if ($saved) { $prev = @(Get-Saved 'usbAlwaysOn')['devices']; Save-Value 'usbAlwaysOn' 'devices' ((@($prev) + $saved | Where-Object { $_ }) -join '|') }
      "USB selective suspend off; $done USB device(s) no longer turned off to save power$(if ($denied) { "; $denied need admin - run again as administrator" })"
    }
    off = {
      $s = Get-Saved 'usbAlwaysOn'
      if ($s) {
        if ($null -ne $s['ac']) { powercfg /setacvalueindex SCHEME_CURRENT $usbSub $usbSuspend $s['ac'] }
        if ($null -ne $s['dc']) { powercfg /setdcvalueindex SCHEME_CURRENT $usbSub $usbSuspend $s['dc'] }
        powercfg /setactive SCHEME_CURRENT
        $names = @("$($s['devices'])" -split '\|' | Where-Object { $_ })
        foreach ($d in @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue | Where-Object { $names -contains $_.InstanceName })) { try { Set-CimInstance -InputObject $d -Property @{ Enable = $true } -ErrorAction Stop } catch { } }
      }
      Clear-Saved 'usbAlwaysOn'; 'USB power saving back as it was'
    }
  }
}

# AM_SYSTEM_DRYRUN=1: nothing touches Windows - switch states live in a temp file (UI tests, demos)
$dry = $env:AM_SYSTEM_DRYRUN -eq '1'; $dryFile = Join-Path $env:TEMP 'am-system-dryrun.json'
if ($dry) {
  $ds = @{}; if (Test-Path $dryFile) { (Get-Content $dryFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $ds[$_.Name] = [bool]$_.Value } }
  foreach ($k in @($S.Keys)) {
    if (-not $ds.ContainsKey($k)) { $ds[$k] = $false; try { $ds[$k] = [bool](& $S[$k].get) } catch { } }
    $id = $k; $S[$k].get = [scriptblock]::Create("`$ds['$id']"); $S[$k].on = [scriptblock]::Create("`$ds['$id'] = `$true; `$ds | ConvertTo-Json | Set-Content '$dryFile'; 'dry run - nothing changed'"); $S[$k].off = [scriptblock]::Create("`$ds['$id'] = `$false; `$ds | ConvertTo-Json | Set-Content '$dryFile'; 'dry run - nothing changed'")
  }
}
function Get-State { @(foreach ($k in $S.Keys) { $on = $false; try { $on = [bool](& $S[$k].get) } catch { }; [ordered]@{ id = $k; label = $S[$k].label; detail = $S[$k].detail; on = $on } }) }

$results = @()
foreach ($pair in $Set) {
  foreach ($p in ($pair -split ',')) {
    $k, $v = $p -split '=', 2; $k = $k.Trim(); if (-not $S.Contains($k)) { Write-Warning "unknown setting '$k' ($($S.Keys -join ', '))"; continue }
    $want = $(if ($v -match '^(toggle|)$') { -not [bool](& $S[$k].get) } else { $v -match '^(on|1|true|yes)$' })
    $msg = & $S[$k].$(if ($want) { 'on' } else { 'off' })
    $results += [ordered]@{ id = $k; on = [bool](& $S[$k].get); message = "$msg" }
    Write-Host ("{0,-16} -> {1}  ({2})" -f $k, $(if ($want) { 'ON' } else { 'OFF' }), $msg)
  }
}
if ($List -or -not $Set) { ConvertTo-Json @(Get-State) -Depth 4 }
