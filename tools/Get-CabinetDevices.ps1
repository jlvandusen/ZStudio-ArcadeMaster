<#
.SYNOPSIS
  Detects what this cabinet can physically do (wheel, pedals, clutch, handbrake, FFB, flight stick/HOTAS,
  gamepads, lightguns, trackball/spinner) and writes a capability file used by Build-Manifest to judge
  which games are playable here. Uses tools\wheelmap (DirectInput/XInput/RawInput) - read-only.
.OUTPUTS D:\ArcadeMaster\manifest\cabinet.json (default)
#>
param(
  [string]$Out = 'D:\ArcadeMaster\manifest\cabinet.json',
  [string]$History = 'D:\ArcadeMaster\manifest\device-history.json',   # every DirectInput GUID each physical device ever had
  [int]$Players = 0,                     # override: player stations (keyboard encoders like I-PAC can't be counted)
  [string[]]$Modes                       # override: racing, flight, standup, lightgun (default: derived from hardware)
)
$ErrorActionPreference = 'Stop'
$text = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'wheelmap\WheelMap.ps1') -Detect 2>&1 | Out-String

# known lightgun / trackball vendors (USB VID[:PID])
$gunIds = @{ '16C0:0F38' = 'Sinden'; '16C0:0F39' = 'Sinden'; '16C0:0F01' = 'Sinden'; '16C0:0F02' = 'Sinden'; '2341:8042' = 'Gun4IR'; '2341:8043' = 'Gun4IR'; '2341:8044' = 'Gun4IR'; '2341:8045' = 'Gun4IR'; 'D209:16' = 'Ultimarc AimTrak' }
$trackballVids = @{ 'D209' = 'Ultimarc (U-Trak/SpinTrak)'; '1241' = 'X-Arcade/Belkin' }

$devices = New-Object System.Collections.Generic.List[object]
$blocks = [regex]::Matches($text, '(?ms)^\s+JOY(\d+)\s+(.+?)\r?\n(.*?)(?=^\s+JOY\d+\s|^RawInput|^XInput|\z)')
foreach ($b in $blocks) {
  $body = $b.Groups[3].Value
  $axes = @([regex]::Matches($body, "Axis\s+\S+\s+'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
  $devices.Add([ordered]@{
    joy = [int]$b.Groups[1].Value; name = $b.Groups[2].Value.Trim()
    id = ([regex]::Match($body, 'VID_([0-9A-F]{4})&PID_([0-9A-F]{4})')).Value
    type = ([regex]::Match($body, 'type=(\S+)')).Groups[1].Value
    role = ([regex]::Match($body, 'role-guess=(\S+)')).Groups[1].Value
    ffb = $body -match 'FFB=True'
    axes = $axes
    buttons = [int]([regex]::Match($body, 'buttons=(\d+)')).Groups[1].Value
    hats = [int]([regex]::Match($body, 'hats=(\d+)')).Groups[1].Value
    guid = ([regex]::Match($body, 'instance GUID\s+([0-9a-f-]{36})')).Groups[1].Value
  })
}
$mice = @([regex]::Matches($text, 'HID#VID_([0-9A-F]{4})&PID_([0-9A-F]{4})') | ForEach-Object { "$($_.Groups[1].Value):$($_.Groups[2].Value)" } | Sort-Object -Unique)
$xinput = if ($text -match 'XInput pads connected:\s*none') { 0 } else { ([regex]::Matches($text, '(?m)^\s+XInput\s*\d')).Count }

$guns = @($mice | ForEach-Object { $id = $_; $vid = $id.Split(':')[0]; $hit = $gunIds.Keys | Where-Object { $id -like "$_*" -or $_ -eq $id } | Select-Object -First 1; if ($hit) { $gunIds[$hit] } })
$wheel = @($devices | Where-Object { $_.role -eq 'wheel' -or $_.type -eq 'Driving' })
$allAxes = ($devices | ForEach-Object { $_.axes }) -join '|'
$cap = [ordered]@{
  wheel        = $wheel.Count -gt 0
  ffb          = @($wheel | Where-Object { $_.ffb }).Count -gt 0
  pedals       = $allAxes -match '(?i)accel|gas|brake'
  clutch       = ($wheel.Count -gt 0) -and ($allAxes -match "(?i)clutch|Y Axis")       # G29/G920: 3rd pedal reports as Sliders0 'Y Axis'
  handbrake    = @($devices | Where-Object { $_.role -eq 'handbrake' }).Count -gt 0
  shifterPaddles = $wheel.Count -gt 0                                                   # every supported wheel has paddles/sequential buttons
  hShifter     = $null                                                                  # G29 shifter shares the wheel's USB id: confirm with WheelMap -Capture
  flightStick  = @($devices | Where-Object { $_.type -match 'Flight|Joystick' -and $_.role -notmatch 'wheel|handbrake' }).Count -gt 0
  gamepads     = $xinput + @($devices | Where-Object { $_.type -eq 'Gamepad' }).Count
  lightguns    = $guns.Count
  lightgunModels = $guns
  trackball    = @($mice | Where-Object { $trackballVids.ContainsKey($_.Split(':')[0]) }).Count -gt 0
  keyboard     = $true
  mice         = $mice.Count
}
# keyboard encoders (Ultimarc I-PAC = VID D209 keyboard device) mean a stand-up control panel
$encoders = @(Get-PnpDevice -PresentOnly -Class Keyboard -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_D209' })
$cap['controlPanel'] = $encoders.Count -gt 0
# joystick restrictors RetroFE can drive per game (joyways metadata): Ultimarc ServoStik (D209:1700); TOS GRS is probed by RetroFE itself
$cap['restrictor'] = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_D209&PID_170[0-9]' }).Count -gt 0
$sticks = @($devices | Where-Object { $_.type -match 'Joystick|Gamepad' -and $_.role -notmatch 'wheel|handbrake' }).Count
$cap['players'] = if ($Players -gt 0) { $Players } else { [Math]::Max(1, [Math]::Max($sticks + $cap.gamepads, [Math]::Max($cap.lightguns, $(if ($cap.controlPanel) { 2 } else { 1 })))) }
$cap['modes'] = if ($Modes) { $Modes } else {
  @(if ($cap.wheel) { 'racing' }; if ($cap.flightStick -or $cap.wheel) { 'flight' }; if ($cap.lightguns -gt 0) { 'lightgun' }; if ($cap.controlPanel -or $sticks -gt 0 -or $cap.gamepads -gt 0) { 'standup' })
}

# device-ID history: DirectInput instance GUIDs change when a device moves USB port / Windows re-enumerates.
# Keyed by VID/PID + name (+ order among identical devices) so profiles can be re-pointed later (Update-ControllerIds).
$hist = if (Test-Path $History) { Get-Content $History -Raw | ConvertFrom-Json } else { [pscustomobject]@{ devices = @() } }
$hlist = New-Object System.Collections.Generic.List[object]; foreach ($h in @($hist.devices)) { $hlist.Add($h) }
$seenKey = @{}
foreach ($d in $devices) {
  $base = "$($d.id)|$($d.name)"; $seenKey[$base] = [int]$seenKey[$base] + 1; $key = "$base|#$($seenKey[$base])"
  $h = $hlist | Where-Object { $_.key -eq $key } | Select-Object -First 1
  if (-not $h) { $h = [pscustomobject]@{ key = $key; id = $d.id; name = $d.name; type = $d.type; role = $d.role; guids = @(); firstSeen = (Get-Date).ToString('s'); lastSeen = $null }; $hlist.Add($h) }
  if (@($h.guids) -notcontains $d.guid) { $h.guids = @($h.guids) + $d.guid }
  $h.lastSeen = (Get-Date).ToString('s'); $h.type = $d.type; $h.role = $d.role
  $d['historyKey'] = $key
}
New-Item -ItemType Directory -Force (Split-Path $History) | Out-Null
[pscustomobject]@{ devices = $hlist } | ConvertTo-Json -Depth 5 | Set-Content $History -Encoding UTF8

New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
[ordered]@{ machine = $env:COMPUTERNAME; detected = (Get-Date).ToString('s'); capabilities = $cap; devices = $devices; rawMice = $mice } |
  ConvertTo-Json -Depth 6 | Set-Content $Out -Encoding UTF8
Write-Host "cabinet capabilities -> $Out"
$cap.GetEnumerator() | ForEach-Object { Write-Host ("  {0,-15} {1}" -f $_.Key, ($_.Value -join ',')) }
