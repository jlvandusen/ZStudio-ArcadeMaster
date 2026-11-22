<#
  Offline test of the capture detection logic (Wait-WMAxis / Wait-WMDigital) with scripted fake
  devices - no hardware or key presses needed. Run: powershell -File dev\Test-CaptureLogic.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\Common.ps1')
. (Join-Path $root 'lib\Capture.ps1')
Import-WMInput

function New-FakeDevice([string]$Name, [scriptblock]$Script) {
    # $Script receives the poll number and returns @{ axes = int[8]; buttons = int[]; pov = int }
    $info = New-Object WheelMap.DIDeviceInfo
    $info.ProductName = $Name; $info.InstanceGuid = [guid]::NewGuid(); $info.TypeName = 'Driving'; $info.EnumIndex = 1
    $dev = [pscustomobject]@{ n = 0; script = $Script }
    $dev | Add-Member -MemberType ScriptMethod -Name Read -Value {
        $this.n++
        $r = & $this.script $this.n
        $s = New-Object WheelMap.JoyState
        $s.Ok = $true
        for ($i = 0; $i -lt 8; $i++) { $s.Axes[$i] = $r.axes[$i] }
        for ($i = 0; $i -lt 4; $i++) { $s.Povs[$i] = -1 }
        if ($r.Contains('pov')) { $s.Povs[0] = $r.pov }
        if ($r.Contains('buttons')) { foreach ($b in $r.buttons) { $s.Buttons[$b] = 128 } }
        return $s
    }
    return [pscustomobject]@{ Info = $info; Dev = $dev; Role = 'wheel' }
}

$fail = 0
function Assert($cond, $msg) { if ($cond) { Write-Host "PASS $msg" -ForegroundColor Green } else { Write-Host "FAIL $msg" -ForegroundColor Red; $script:fail++ } }

# --- G29-like pedal that reports 32768 until first moved, then rests at 65535 and presses to 0 (gas = Y)
$pedal = New-FakeDevice 'FakeWheel' {
    param($n)
    $y = 32768
    if ($n -gt 40) { $y = 65535 }
    if ($n -gt 60 -and $n -le 120) { $y = [Math]::Max(0, 65535 - ($n - 60) * 3000) }   # press down to 0
    if ($n -gt 120) { $y = [Math]::Min(65535, ($n - 120) * 4000) }                      # release back up
    if ($n -gt 140) { $y = 65535 }
    @{ axes = @(32768, $y, 0, 0, 0, (30000 + ($n % 3) * 50), 32768, 0) }                  # Rz jitters a little
}
$open = @($pedal)
$base = Get-WMBaseline $open 50
$r = Wait-WMAxis $open $base 'axis-pedal'
Assert ($r.axis -eq 1) "pedal: picked axis Y (got $($r.axis))"
Assert ($r.rest -gt 60000) "pedal: rest re-read after release is high (got $($r.rest))"
$pressed = $(if ([Math]::Abs($r.max - $r.rest) -gt [Math]::Abs($r.rest - $r.min)) { $r.max } else { $r.min })
Assert ($pressed -lt 5000) "pedal: pressed extreme is low (got $pressed) -> direction '-'"

# --- steering: start centred, go left (low) then right (high), back to centre
$wheel = New-FakeDevice 'FakeWheel' {
    param($n)
    $x = 32768
    if ($n -gt 20 -and $n -le 60) { $x = [Math]::Max(0, 32768 - ($n - 20) * 2000) }
    if ($n -gt 60 -and $n -le 120) { $x = [Math]::Min(65535, ($n - 60) * 2000) }
    if ($n -gt 120) { $x = 32900 }
    @{ axes = @($x, 65535, 0, 0, 0, 65535, 65535, 0) }
}
$open = @($wheel)
$base = Get-WMBaseline $open 50
$r = Wait-WMAxis $open $base 'axis-bipolar'
Assert ($r.axis -eq 0) "steering: picked axis X (got $($r.axis))"
Assert ($r.first -lt 0) "steering: LEFT first gave low values -> invert=false (first=$($r.first))"
Assert (($r.max - $r.min) -gt 60000) "steering: full range observed ($($r.min)..$($r.max))"

# --- inverted steering (left = high)
$inv = New-FakeDevice 'FakeWheel' {
    param($n)
    $x = 32768
    if ($n -gt 20 -and $n -le 60) { $x = [Math]::Min(65535, 32768 + ($n - 20) * 2000) }
    if ($n -gt 60 -and $n -le 120) { $x = [Math]::Max(0, 65535 - ($n - 60) * 2000) }
    if ($n -gt 120) { $x = 32768 }
    @{ axes = @($x, 65535, 0, 0, 0, 65535, 65535, 0) }
}
$open = @($inv)
$base = Get-WMBaseline $open 50
$r = Wait-WMAxis $open $base 'axis-bipolar'
Assert ($r.first -gt 0) "steering inverted: first deviation positive -> invert=true"

# --- button debounce: a 1-poll glitch on button 7 must be ignored, a real press of button 4 accepted;
#     button 9 is held during the baseline and must be ignored
$btn = New-FakeDevice 'FakeWheel' {
    param($n)
    $b = @(9)
    if ($n -eq 30) { $b += 7 }
    if ($n -ge 50 -and $n -le 70) { $b += 4 }
    @{ axes = @(32768, 65535, 0, 0, 0, 65535, 65535, 0); buttons = $b }
}
$open = @($btn)
$base = Get-WMBaseline $open 50
$r = Wait-WMDigital $open $base
Assert ($r.type -eq 'button' -and $r.button -eq 4) "button: glitch ignored, held button ignored, got button $($r.button)"

# --- hat: diagonal ignored, cardinal accepted
$hat = New-FakeDevice 'FakeWheel' {
    param($n)
    $p = -1
    if ($n -ge 20 -and $n -lt 40) { $p = 4500 }
    if ($n -ge 40 -and $n -lt 60) { $p = 18000 }
    @{ axes = @(32768, 65535, 0, 0, 0, 65535, 65535, 0); pov = $p }
}
$open = @($hat)
$base = Get-WMBaseline $open 50
$r = Wait-WMDigital $open $base
Assert ($r.type -eq 'pov' -and $r.dir -eq 'Down') "hat: diagonal ignored, got $($r.dir)"

# --- two devices: the handbrake on device 2 must win over noise on device 1
$noisy = New-FakeDevice 'FakeWheel' { param($n) @{ axes = @((32768 + ($n % 5) * 300), 65535, 0, 0, 0, 65535, 65535, 0) } }
$hb = New-FakeDevice 'handbrake' {
    param($n)
    $s = 0
    if ($n -gt 30 -and $n -le 60) { $s = [Math]::Min(65535, ($n - 30) * 4000) }
    if ($n -gt 60 -and $n -le 80) { $s = [Math]::Max(0, 65535 - ($n - 60) * 5000) }
    @{ axes = @(0, 0, 0, 0, 0, 0, $s, 0) }
}
$open = @($noisy, $hb)
$base = Get-WMBaseline $open 50
$r = Wait-WMAxis $open $base 'axis-pedal'
Assert ($r.k -eq 1 -and $r.axis -eq 6) "multi-device: handbrake slider on device 2 detected (k=$($r.k) axis=$($r.axis))"

if ($fail) { Write-Host "$fail test(s) failed" -ForegroundColor Red; exit 1 } else { Write-Host 'all capture-logic tests passed' -ForegroundColor Green }
