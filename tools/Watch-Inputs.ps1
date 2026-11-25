<#
.SYNOPSIS
  Shows what every control on the panel really sends: move a stick, press a button, and it prints the key (I-PAC)
  or the joystick, axis and button number (Ultra-Stik, flight stick, gamepad) - with MAME's name for it.
  Use it to map a cabinet whose LEDBlinky does not describe its controls, and to check a panel after rewiring.

  Reads only (GetAsyncKeyState + winmm joyGetPosEx); changes nothing.
.EXAMPLE
  tools\Watch-Inputs.ps1 -Seconds 30
  tools\Watch-Inputs.ps1 -Seconds 60 -Out R:\ArcadeMaster\manifest\input-capture.txt
#>
param([int]$Seconds = 30, [string]$Out)
$ErrorActionPreference = 'Stop'
if (-not ('AmInput.Native' -as [type])) {
  Add-Type -Namespace AmInput -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
[StructLayout(LayoutKind.Sequential)] public struct JOYINFOEX { public int dwSize, dwFlags, dwXpos, dwYpos, dwZpos, dwRpos, dwUpos, dwVpos, dwButtons, dwButtonNumber, dwPOV, dwReserved1, dwReserved2; }
[DllImport("winmm.dll")] public static extern int joyGetPosEx(int uJoyID, ref JOYINFOEX pji);
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct JOYCAPS { public short wMid, wPid; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szPname; public int wXmin, wXmax, wYmin, wYmax, wZmin, wZmax, wNumButtons, wPeriodMin, wPeriodMax, wRmin, wRmax, wUmin, wUmax, wVmin, wVmax, wCaps, wMaxAxes, wNumAxes, wMaxButtons; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szRegKey; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szOEMVxD; }
[DllImport("winmm.dll", CharSet = CharSet.Unicode)] public static extern int joyGetDevCaps(int uJoyID, ref JOYCAPS pjc, int cbjc);
'@
}
# MAME's KEYCODE_ names for the virtual keys an I-PAC sends
$vkName = @{ 0x25 = 'LEFT'; 0x26 = 'UP'; 0x27 = 'RIGHT'; 0x28 = 'DOWN'; 0xA2 = 'LCONTROL'; 0xA3 = 'RCONTROL'; 0xA4 = 'LALT'; 0xA5 = 'RALT'; 0xA0 = 'LSHIFT'; 0xA1 = 'RSHIFT'
  0x20 = 'SPACE'; 0x0D = 'ENTER'; 0x1B = 'ESC'; 0x09 = 'TAB'; 0xDB = 'OPENBRACE'; 0xDD = 'CLOSEBRACE'; 0xBB = 'EQUALS'; 0xBD = 'MINUS'; 0xBC = 'COMMA'; 0xBE = 'STOP'
  0xDC = 'BACKSLASH'; 0xBF = 'SLASH'; 0xBA = 'COLON'; 0xDE = 'QUOTE'; 0xC0 = 'TILDE'; 0x08 = 'BACKSPACE'; 0x21 = 'PGUP'; 0x22 = 'PGDN'; 0x24 = 'HOME'; 0x23 = 'END'; 0x2D = 'INSERT'; 0x2E = 'DEL' }
for ($i = 0; $i -lt 26; $i++) { $vkName[0x41 + $i] = [string][char](0x41 + $i) }
for ($i = 0; $i -lt 10; $i++) { $vkName[0x30 + $i] = "$i"; $vkName[0x60 + $i] = "${i}_PAD" }
for ($i = 1; $i -le 12; $i++) { $vkName[0x6F + $i] = "F$i" }
$skipVk = @(0x10, 0x11, 0x12)   # generic SHIFT/CTRL/ALT: the left/right ones are reported instead

$lines = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $t = '{0,6:N2}s  {1}' -f $clock.Elapsed.TotalSeconds, $s; Write-Host $t; $lines.Add($t) }
$clock = [Diagnostics.Stopwatch]::StartNew()

# joysticks Windows knows: joystick N here is MAME's JOYCODE_(N+1) when MAME uses the same order (DirectInput order
# can differ - check with MAME's own input screen if in doubt)
$joys = @()
for ($j = 0; $j -lt 16; $j++) {
  $caps = New-Object AmInput.Native+JOYCAPS
  if ([AmInput.Native]::joyGetDevCaps($j, [ref]$caps, [Runtime.InteropServices.Marshal]::SizeOf($caps)) -ne 0) { continue }
  $info = New-Object AmInput.Native+JOYINFOEX; $info.dwSize = [Runtime.InteropServices.Marshal]::SizeOf($info); $info.dwFlags = 0xFF
  if ([AmInput.Native]::joyGetPosEx($j, [ref]$info) -ne 0) { continue }
  $joys += @{ id = $j; name = $caps.szPname; buttons = $caps.wNumButtons; last = $info }
  Say ("joystick #{0} ({1}): {2} buttons" -f ($j + 1), $caps.szPname, $caps.wNumButtons)
}
Say "watching for $Seconds s: move every stick and press every button, one at a time"
$keyDown = @{}
$axisDir = @{}
while ($clock.Elapsed.TotalSeconds -lt $Seconds) {
  for ($vk = 1; $vk -lt 255; $vk++) {
    if ($skipVk -contains $vk) { continue }
    $down = ([AmInput.Native]::GetAsyncKeyState($vk) -band 0x8000) -ne 0
    if ($down -ne [bool]$keyDown[$vk]) {
      $keyDown[$vk] = $down
      $n = if ($vkName.ContainsKey($vk)) { $vkName[$vk] } else { 'VK_0x{0:X2}' -f $vk }
      if ($vk -in 1, 2, 4) { $n = @{ 1 = 'MOUSE1'; 2 = 'MOUSE2'; 4 = 'MOUSE3' }[$vk] }
      Say ("key  KEYCODE_{0,-12} {1}" -f $n, $(if ($down) { 'down' } else { 'up' }))
    }
  }
  foreach ($j in $joys) {
    $info = New-Object AmInput.Native+JOYINFOEX; $info.dwSize = [Runtime.InteropServices.Marshal]::SizeOf($info); $info.dwFlags = 0xFF
    if ([AmInput.Native]::joyGetPosEx($j.id, [ref]$info) -ne 0) { continue }
    $jn = $j.id + 1
    foreach ($ax in @(@('X', 'dwXpos'), @('Y', 'dwYpos'), @('Z', 'dwZpos'), @('RZ', 'dwRpos'), @('U', 'dwUpos'), @('V', 'dwVpos'))) {
      $v = $info.($ax[1]); $dir = if ($v -lt 16384) { 'NEG' } elseif ($v -gt 49151) { 'POS' } else { 'MID' }
      $k = "$jn$($ax[0])"
      if ($axisDir.ContainsKey($k) -and $axisDir[$k] -ne $dir) { Say ("joy  JOYCODE_{0}_{1}AXIS {2,-3} ({3})  [{4}]" -f $jn, $ax[0], $dir, $v, $j.name) }
      $axisDir[$k] = $dir
    }
    $changed = $info.dwButtons -bxor $j.last.dwButtons
    for ($b = 0; $b -lt 32; $b++) { if ($changed -band (1 -shl $b)) { Say ("joy  JOYCODE_{0}_BUTTON{1,-3} {2}  [{3}]" -f $jn, ($b + 1), $(if ($info.dwButtons -band (1 -shl $b)) { 'down' } else { 'up' }), $j.name) } }
    if ($info.dwPOV -ne $j.last.dwPOV) { Say ("joy  JOYCODE_{0} POV {1}  [{2}]" -f $jn, $info.dwPOV, $j.name) }
    $j.last = $info
  }
  Start-Sleep -Milliseconds 15
}
Say 'done'
if ($Out) { $lines | Set-Content $Out -Encoding UTF8; Write-Host "saved -> $Out" }
