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
# one PnP enumeration for every check below (each Get-PnpDevice call costs ~0.4 s at boot)
. (Join-Path $PSScriptRoot 'lib\AmPnp.ps1'); $allPnp = @(Get-AmPnpDevices)   # setup API: ~0.07 s instead of WMI's ~0.6 s (falls back to Get-PnpDevice)
# The DirectInput scan (WheelMap -Detect, 1.1 s on the pedestal's i3) only changes when the USB / HID devices do: it
# is kept with a key of every present USB / HID device (plug or unplug anything -> new key -> a fresh scan).
$diKeyText = (@($allPnp | Where-Object { $_.InstanceId -match '^(HID|USB)\\' } | ForEach-Object { "$($_.InstanceId)|$($_.Status)" } | Sort-Object) -join "`n") + "`n" + (Get-Item (Join-Path $PSScriptRoot 'wheelmap\WheelMap.ps1')).LastWriteTimeUtc.Ticks
$diKey = -join ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($diKeyText))[0..11] | ForEach-Object { $_.ToString('x2') })
$diCache = Join-Path (Split-Path $Out) 'directinput-scan.txt'
$cached = if (Test-Path $diCache) { [IO.File]::ReadAllText($diCache) } else { '' }
if ($cached.StartsWith("key=$diKey`n")) { $text = $cached.Substring("key=$diKey`n".Length) }
else {
  # in this PowerShell, not a new one (~0.35 s here, ~1.2 s on the pedestal's i3); same text either way
  $text = & (Join-Path $PSScriptRoot 'wheelmap\WheelMap.ps1') -Detect *>&1 | Out-String
  try { New-Item -ItemType Directory -Force (Split-Path $diCache) | Out-Null; [IO.File]::WriteAllText($diCache, "key=$diKey`n$text") } catch { }
}

# known lightgun / trackball vendors (USB VID[:PID])
# every light gun ArcadeMaster knows: tools/light-guns.json (shared with AmPanel's Guns.cs) - usb id or prefix -> kind
$gunIds = @{}
try { foreach ($g in (Get-Content (Join-Path $PSScriptRoot 'light-guns.json') -Raw | ConvertFrom-Json).guns) { $gunIds[$g.usb.ToUpper()] = $g.kind } } catch { }
if (-not $gunIds.Count) { $gunIds = @{ '16C0:0F38' = 'Sinden'; '16C0:0F39' = 'Sinden'; '16C0:0F01' = 'Sinden'; '16C0:0F02' = 'Sinden'; '2341:8042' = 'GUN4IR'; '2341:8043' = 'GUN4IR'; '2341:8044' = 'GUN4IR'; '2341:8045' = 'GUN4IR'; 'D209:16' = 'Ultimarc AimTrak' } }
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

$flightDevs = @($devices | Where-Object { $_.role -eq 'throttle' -or ($_.role -notmatch 'wheel|handbrake|pedals|throttle|gun' -and $_.type -ne 'Driving' -and $_.id -notmatch 'VID_D209' -and $_.name -notmatch '(?i)ultra-?stik|servostik|i-?pac|arcade|xin-?mo|zero delay|dragonrise' -and ($_.role -eq 'stick' -or $_.type -eq 'Flight' -or ($_.type -eq 'Joystick' -and @($_.axes).Count -ge 3) -or ($_.id -match 'VID_(044F|06A3|0738)' -and @($_.axes).Count -ge 2))) })
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
  # A flight stick: named as one (role 'stick' from WheelMap: HOTAS, T.Flight, X52/X56, Extreme 3D ...), or a DirectInput
  # Flight device, a Joystick with 3+ axes (a 2-axis "USB Joystick" is an arcade-panel encoder), or any 2+ axis non-wheel device from a flight-only maker (Thrustmaster 044F, Saitek/Logitech
  # flight 06A3, Mad Catz X56 0738) - PlayStation HOTAS sets can report as a joystick with no telling type.
  # Ultimarc (VID D209: UltraStik, ServoStik, encoders) and other arcade-panel sticks are NOT flight sticks.
  flightStick  = @($flightDevs | Where-Object { $_.role -ne 'throttle' }).Count -gt 0
  # a separate throttle (HOTAS throttle half, TWCS, throttle quadrant): flight controls, but not a stick on its own
  throttle     = @($devices | Where-Object { $_.role -eq 'throttle' }).Count -gt 0
  gamepads     = $xinput + @($devices | Where-Object { $_.type -eq 'Gamepad' -and $flightDevs -notcontains $_ }).Count
  lightguns    = $guns.Count
  lightgunModels = $guns
  trackball    = @($mice | Where-Object { $trackballVids.ContainsKey($_.Split(':')[0]) }).Count -gt 0
  keyboard     = $true
  mice         = $mice.Count
}
# keyboard encoders (Ultimarc I-PAC = VID D209 keyboard device) mean a stand-up control panel
$encoders = @($allPnp | Where-Object { $_.Class -eq 'Keyboard' } | Where-Object { $_.InstanceId -match 'VID_D209' })
$ultraStiks = @($devices | Where-Object { $_.id -match 'VID_D209&PID_05' -or $_.name -match '(?i)ultra-?stik' })
$cap['controlPanel'] = ($encoders.Count -gt 0) -or ($ultraStiks.Count -gt 0)
$cap['encoders'] = @($encoders | ForEach-Object { ([regex]::Match($_.InstanceId, 'VID_D209&PID_([0-9A-F]{4})')).Groups[1].Value } | Select-Object -Unique).Count   # distinct I-PAC boards
$cap['arcadeSticks'] = $ultraStiks.Count
# displays + touch digitizers (pedestal / marquee touchscreens become RetroFE screen 1)
Add-Type -AssemblyName System.Windows.Forms
# which graphics adapter drives each display: a USB display (DisplayLink / MCT / SiliconMotion / Fresco ...) is the
# pedestal's USB-connected second screen - Set-RetroFEScreens puts screen 1 there
# compiled once into %LOCALAPPDATA%\ArcadeMaster\typecache (lib\AmTypeCache.ps1): Add-Type compiled it at every boot
. (Join-Path $PSScriptRoot 'lib\AmTypeCache.ps1')
Add-AmCachedType -ProbeType 'AmDisp.Enum' -Source @"
namespace AmDisp { public static class Enum {
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public struct DISPLAY_DEVICE { public int cb; [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName; [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString; public int StateFlags; [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID; [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey; }
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern bool EnumDisplayDevices(string dev, uint i, ref DISPLAY_DEVICE dd, uint flags);
public static string Adapter(string name) { var d = new DISPLAY_DEVICE(); d.cb = System.Runtime.InteropServices.Marshal.SizeOf(d); for (uint i = 0; EnumDisplayDevices(null, i, ref d, 0); i++) { if (d.DeviceName == name) return d.DeviceString + "|" + d.DeviceID; d.cb = System.Runtime.InteropServices.Marshal.SizeOf(d); } return ""; }
} }
"@
$usbRx = '(?i)displaylink|usb display|usb graphics|usb mobile monitor|mct|trigger|siliconmotion|smi usb|fresco|VID_17E9|VID_0711|VID_090C|VID_1D5C'
$cap['displays'] = @([Windows.Forms.Screen]::AllScreens | ForEach-Object {
  $ad = [AmDisp.Enum]::Adapter($_.DeviceName); $adName = ($ad -split '\|')[0]
  [ordered]@{ name = $_.DeviceName; primary = $_.Primary; width = $_.Bounds.Width; height = $_.Bounds.Height; x = $_.Bounds.X; y = $_.Bounds.Y; adapter = $adName; usb = [bool]($ad -match $usbRx) } })
# USB display adapters seen by Windows even when no screen is active (driver missing / not powered)
$cap['usbDisplayAdapters'] = @($allPnp | Where-Object { $_.FriendlyName -match $usbRx -or $_.InstanceId -match 'VID_17E9|VID_0711|VID_1D5C' } | ForEach-Object { "$($_.FriendlyName) [$($_.Status)]" } | Select-Object -Unique)
$cap['touchScreens'] = @($allPnp | Where-Object { $_.FriendlyName -match '(?i)touch ?screen|touch digitizer' -and $_.Status -eq 'OK' }).Count
# USB touch boards that report as a MOUSE (no digitizer, no driver - e.g. ByQDtech 0483:5750 on the pedestal's HDMI
# touch panel). Windows cannot map them to a display, so the frontend routes them (patch 0003 per-screen touch).
$cap['touchControllers'] = @($allPnp | Where-Object { $_.FriendlyName -match '(?i)touch' -and $_.Status -eq 'OK' -and $_.InstanceId -match '^(USB|HID)\\VID_' } | ForEach-Object { $m = [regex]::Match($_.InstanceId, 'VID_([0-9A-F]{4})&PID_([0-9A-F]{4})'); "$($m.Groups[1].Value):$($m.Groups[2].Value) $($_.FriendlyName)" } | Select-Object -Unique)
# touch hardware that is present but NOT working (no / wrong driver) - shows why a touch screen is missing
$cap['touchProblems'] = @($allPnp | Where-Object { ($_.FriendlyName -match '(?i)touch|digitizer|egalax|ilitek|goodix|elo |eeti|weida|hid-compliant touch' -or $_.InstanceId -match 'VID_0EEF|VID_222A|VID_04E7|VID_2575|VID_27C6|VID_1FD2') -and $_.Status -ne 'OK' } | ForEach-Object { "$($_.FriendlyName) [$($_.Status)] $($_.InstanceId)" })
# joystick restrictors RetroFE can drive per game (joyways metadata): Ultimarc ServoStik (D209:1700); TOS GRS is probed by RetroFE itself
$cap['restrictor'] = @($allPnp | Where-Object { $_.InstanceId -match 'VID_D209&PID_170[0-9]' }).Count -gt 0
# Nintendo controllers - Bluetooth (HID ...VID&0002057E_PID&0306) or USB / Mayflash DolphinBar (VID_057E&PID_0306):
#   Wii Remote "wand" (RVL-CNT-01 0306, Plus/-TR 0330), Wii U Pro (0330 '-UC'), Balance Board (0306 'WBC'),
#   GameCube adapter for Wii U/Switch (0337), Joy-Con (2006/2007), Switch Pro (2009).
$pnp = @($allPnp | Where-Object { $_.InstanceId -match '057E[&_]PID[&_](0306|0330|0337|2006|2007|2009)' -and $_.Status -eq 'OK' })
$btNames = @($allPnp | Where-Object { $_.FriendlyName -match '(?i)RVL-|Nintendo|Pro Controller|Joy-Con' } | ForEach-Object { $_.FriendlyName })
$hidPid = @($pnp | Where-Object { $_.Class -eq 'HIDClass' } | ForEach-Object { ([regex]::Match($_.InstanceId, 'PID[&_]([0-9A-F]{4})')).Groups[1].Value })
$wiiUPro = @($btNames | Where-Object { $_ -match '(?i)RVL-CNT-01-UC' }).Count
$board = @($btNames | Where-Object { $_ -match '(?i)RVL-WBC' }).Count
# Mayflash DolphinBar (USB 057E:0306, a composite device with one interface per Wii Remote slot): Windows lists all
# 4 slots - each twice, as "USB Input Device" and "HID-compliant game controller" - whether or not a remote is synced.
# Those are slots, not remotes (the 2P stand-up counted 8 remotes with none connected, 2026-11-26).
$dbar = @($allPnp | Where-Object { $_.InstanceId -match '^USB\\VID_057E&PID_0306\\' -and $_.Status -eq 'OK' })
$dbarSlots = @($pnp | Where-Object { $_.InstanceId -match '^USB\\VID_057E&PID_0306&MI_0\d' } | ForEach-Object { ([regex]::Match($_.InstanceId, 'MI_0\d')).Value } | Sort-Object -Unique).Count
$btPid = @($pnp | Where-Object { $_.Class -eq 'HIDClass' -and $_.InstanceId -notmatch '^(HID|USB)\\VID_057E&PID_0306&MI_' } | ForEach-Object { ([regex]::Match($_.InstanceId, 'PID[&_]([0-9A-F]{4})')).Groups[1].Value })
$nintendo = [ordered]@{
  wiimotes     = [Math]::Max(0, @($btPid | Where-Object { $_ -in '0306', '0330' }).Count - $wiiUPro - $board)   # paired remotes (Bluetooth / Wii U Pro on USB)
  dolphinBarSlots = $(if ($dbar.Count) { [Math]::Max(4, $dbarSlots) * $dbar.Count } else { 0 })
  wiiUPro      = $wiiUPro
  balanceBoard = $board
  gcAdapter    = @($pnp | Where-Object { $_.InstanceId -match 'PID[&_]0337' }).Count -gt 0
  joycons      = @($hidPid | Where-Object { $_ -in '2006', '2007' }).Count
  switchPro    = @($hidPid | Where-Object { $_ -eq '2009' }).Count
  dolphinBar   = $dbar.Count -gt 0 -or @($allPnp | Where-Object { $_.FriendlyName -match '(?i)DolphinBar|Mayflash' }).Count -gt 0
}
$cap['wii'] = $nintendo
foreach ($k in 'wiimotes', 'wiiUPro', 'joycons', 'switchPro') { for ($n = 0; $n -lt [int]$nintendo[$k]; $n++) {
  $devices.Add([ordered]@{ joy = 0; name = @{ wiimotes = 'Wii Remote'; wiiUPro = 'Wii U Pro Controller'; joycons = 'Joy-Con'; switchPro = 'Switch Pro Controller' }[$k] + $(if ([int]$nintendo[$k] -gt 1) { " $($n + 1)" })
    id = 'VID_057E'; type = 'Nintendo'; role = @{ wiimotes = 'wiimote'; wiiUPro = 'gamepad'; joycons = 'gamepad'; switchPro = 'gamepad' }[$k]; ffb = $false; axes = @(); buttons = 0; hats = 0; guid = '' }) } }
if ($nintendo.gcAdapter) { $devices.Add([ordered]@{ joy = 0; name = 'GameCube controller adapter'; id = 'VID_057E&PID_0337'; type = 'Nintendo'; role = 'gcadapter'; ffb = $false; axes = @(); buttons = 0; hats = 0; guid = '' }) }
$cap['gamepads'] = [int]$cap.gamepads + [int]$nintendo.wiiUPro + [int]$nintendo.switchPro + [Math]::Floor([int]$nintendo.joycons / 2)
# incl. UltraStiks (panel sticks), not flight sticks, and not light guns: an AimTrak / Sinden / Gun4IR also shows up
# as a joystick ("ATRAK Device #1"), which made the 2P stand-up's two guns count as two more players
$gunVidPid = @($gunIds.Keys | ForEach-Object { 'VID_' + $_.Replace(':', '&PID_') })
$sticks = @($devices | Where-Object { $d = $_; $_.type -match 'Joystick|Gamepad' -and $_.role -notmatch 'wheel|handbrake' -and $flightDevs -notcontains $_ -and -not ($gunVidPid | Where-Object { $d.id -like "$_*" }) }).Count
# each I-PAC board serves 2 players (an I-PAC 4 / two I-PAC 2s = 4-player pedestal)
$cap['players'] = if ($Players -gt 0) { $Players } elseif ($cap.encoders -ge 2) { [Math]::Max(4, 2 * $cap.encoders) } else { [Math]::Max(1, [Math]::Max($sticks + $cap.gamepads, [Math]::Max($cap.lightguns, $(if ($cap.controlPanel) { 2 } else { 1 })))) }
# flight only with real flight controls (a stick): a wheel does not fly
$cap['modes'] = if ($Modes) { $Modes } else {
  @(if ($cap.wheel) { 'racing' }; if ($cap.flightStick) { 'flight' }; if ($cap.lightguns -gt 0) { 'lightgun' }; if ($cap.controlPanel -or $sticks -gt 0 -or $cap.gamepads -gt 0) { 'standup' })
}

# device-ID history: DirectInput instance GUIDs change when a device moves USB port / Windows re-enumerates.
# Keyed by VID/PID + name (+ order among identical devices) so profiles can be re-pointed later (Update-ControllerIds).
$hist = if (Test-Path $History) { Get-Content $History -Raw | ConvertFrom-Json } else { [pscustomobject]@{ devices = @() } }
$hlist = New-Object System.Collections.Generic.List[object]; foreach ($h in @($hist.devices)) { $hlist.Add($h) }
$seenKey = @{}
foreach ($d in $devices) {
  if ($d.type -eq 'Nintendo') { continue }   # no DirectInput GUID to track
  $base = "$($d.id)|$($d.name)"; $seenKey[$base] = [int]$seenKey[$base] + 1; $key = "$base|#$($seenKey[$base])"
  $h = $hlist | Where-Object { $_.key -eq $key } | Select-Object -First 1
  if (-not $h) { $h = [pscustomobject]@{ key = $key; id = $d.id; name = $d.name; type = $d.type; role = $d.role; guids = @(); firstSeen = (Get-Date).ToString('s'); lastSeen = $null }; $hlist.Add($h) }
  if (@($h.guids) -notcontains $d.guid) { $h.guids = @($h.guids) + $d.guid }
  $h.lastSeen = (Get-Date).ToString('s'); $h.type = $d.type; $h.role = $d.role
  $d['historyKey'] = $key
}
New-Item -ItemType Directory -Force (Split-Path $History) | Out-Null
[pscustomobject]@{ devices = $hlist } | ConvertTo-Json -Depth 5 | Set-Content $History -Encoding UTF8

# every mode this cabinet has ever had controls for (kept across scans): the menu builder builds those collections, and
# the boot (Set-CabinetMode) shows or hides each one by what is plugged in NOW - so a flight stick plugged in later
# brings Flight back without a rebuild. Modes from before this list existed: the wheel used to add 'flight' by itself,
# so an old cabinet.json's list is not trusted for flight.
$prevSeen = @(); if (Test-Path $Out) { try { $pc = (Get-Content $Out -Raw | ConvertFrom-Json).capabilities; if ($pc.modesSeen) { $prevSeen = @($pc.modesSeen) } } catch { } }
$cap['modesSeen'] = @(@($prevSeen) + @($cap.modes) | Where-Object { $_ } | Select-Object -Unique)
New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
[ordered]@{ machine = $env:COMPUTERNAME; detected = (Get-Date).ToString('s'); capabilities = $cap; devices = $devices; rawMice = $mice } |
  ConvertTo-Json -Depth 6 | Set-Content $Out -Encoding UTF8
Write-Host "cabinet capabilities -> $Out"
$cap.GetEnumerator() | ForEach-Object { $v = if ($_.Value -is [Collections.IDictionary]) { ($_.Value.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ' } elseif ($_.Key -eq 'displays') { "$(@($_.Value).Count): " + ((@($_.Value) | ForEach-Object { "$($_.width)x$($_.height)$(if ($_.primary) { '*' })" }) -join ', ') } else { $_.Value -join ',' }; Write-Host ("  {0,-15} {1}" -f $_.Key, $v) }
