# Capture.ps1 - interactive capture wizard + live monitor (PowerShell 5.1)
# Detection rules:
#   axes      : largest deviation from a fresh baseline wins; pedals need >= 40% travel, bipolar axes
#               need >= 30% to BOTH sides. Rest value is re-read after release (G29 pedals report
#               32768 until first moved). Direction / inversion / observed min-max are recorded.
#   buttons   : a button not held in the baseline must read pressed in 2 polls >= 25 ms apart
#               (debounce), then we wait for release so it cannot leak into the next step.
#   hats      : only exact cardinal directions (0/9000/18000/27000) are accepted.
#   keyboard  : only with -Keyboard (encoders / gun button-to-key modes). Wizard keys are excluded.
# Wizard keys (console must have focus): S skip, R redo, B back, Q quit+save, Enter accept axis, M mouse-gun.

$script:WizardVKs = @(0x53, 0x52, 0x42, 0x51, 0x0D, 0x1B, 0x4D) # S R B Q Enter Esc M

function Open-WMDevices([string[]]$Filter) {
    Import-WMInput
    $list = [WheelMap.DI]::Enumerate($true)
    $open = @()
    foreach ($d in $list) {
        if ($Filter -and -not ($Filter | Where-Object { $d.ProductName -like "*$_*" -or $d.InstanceGuid.ToString() -eq $_ -or "$($d.Vid):$($d.Pid)" -eq $_ })) { continue }
        try {
            $dev = New-Object WheelMap.DIDevice $d.InstanceGuid
            $open += [pscustomobject]@{ Info = $d; Dev = $dev; Role = (Get-WMRoleGuess $d) }
        } catch { Write-Warning "Cannot open $($d.ProductName): $($_.Exception.Message)" }
    }
    # first reads acquire the devices; discard them
    foreach ($o in $open) { [void]$o.Dev.Read() }
    Start-Sleep -Milliseconds 60
    return $open
}

function Close-WMDevices($open) { foreach ($o in $open) { try { $o.Dev.Dispose() } catch { } } }

function Read-WMAll($open) { $r = @(); foreach ($o in $open) { $r += , $o.Dev.Read() }; return $r }

function Get-WMConsoleKey {
    # ArcadeMaster tool screen: on-screen buttons drop a key (S/R/B/Q/Enter) into AM_WIZ_KEYFILE
    $kf = $env:AM_WIZ_KEYFILE
    if ($kf -and (Test-Path -LiteralPath $kf)) {
        $k = ''; try { $k = (Get-Content -LiteralPath $kf -Raw).Trim(); Remove-Item -LiteralPath $kf -Force } catch { }
        if ($k) { return [pscustomobject]@{ Key = $k } }
    }
    try {
        if ([Console]::KeyAvailable) { return [Console]::ReadKey($true) }
    } catch { }
    return $null
}

# structured progress for the ArcadeMaster tool screen (only when it hosts us)
function Send-WMEvent([hashtable]$o) { if ($env:AM_VISUAL -eq '1') { [Console]::Out.WriteLine('@AM ' + (ConvertTo-Json $o -Compress -Depth 5)) } }

function Get-WMBaseline($open, [int]$ms = 250) {
    $n = 0; $sum = @(); $btn = @(); $pov = @()
    foreach ($o in $open) { $sum += , (New-Object double[] 8); $btn += , (New-Object bool[] 128); $pov += , (@(-1, -1, -1, -1)) }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) {
        $st = Read-WMAll $open
        for ($k = 0; $k -lt $open.Count; $k++) {
            for ($a = 0; $a -lt 8; $a++) { $sum[$k][$a] += $st[$k].Axes[$a] }
            for ($b = 0; $b -lt 128; $b++) { if ($st[$k].Buttons[$b] -ne 0) { $btn[$k][$b] = $true } }
            for ($p = 0; $p -lt 4; $p++) { $pov[$k][$p] = $st[$k].Povs[$p] }
        }
        $n++
        Start-Sleep -Milliseconds 10
    }
    $avg = @()
    for ($k = 0; $k -lt $open.Count; $k++) { $avg += , ($sum[$k] | ForEach-Object { [int]($_ / [Math]::Max(1, $n)) }) }
    return [pscustomobject]@{ Axes = $avg; Buttons = $btn; Povs = $pov; Keys = @([WheelMap.Keys]::Down()) }
}

function Wait-WMAxis($open, $base, [string]$kind) {
    # Returns @{ k; axis; min; max; first; rest } or a keyword (skip/redo/back/quit/mouse).
    # Pedal  : done when travel >= ~40% AND the value has left the most recently reached extreme by
    #          >= 80% of the travel AND is stable for 300 ms -> that stable value is the rest position.
    # Bipolar: done when both sides moved >= ~30% from the start centre AND value is back within 15%
    #          of the middle and stable for 300 ms.
    $n = $open.Count
    $min = @(); $max = @(); $tMin = @(); $tMax = @(); $first = @{}
    for ($k = 0; $k -lt $n; $k++) {
        $min += , ([int[]]$base.Axes[$k].Clone()); $max += , ([int[]]$base.Axes[$k].Clone())
        $tMin += , (New-Object long[] 8); $tMax += , (New-Object long[] 8)
    }
    $need = $(if ($kind -eq 'axis-pedal') { 26000 } else { 19000 })
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $lastPrint = 0; $stableSince = 0; $lastV = $null; $forced = $false
    while ($true) {
        $key = Get-WMConsoleKey
        if ($key) {
            switch ($key.Key) {
                'S' { return 'skip' } 'R' { return 'redo' } 'B' { return 'back' } 'Q' { return 'quit' } 'M' { return 'mouse' }
                'Enter' { $forced = $true }
            }
        }
        $st = Read-WMAll $open
        $now = $sw.ElapsedMilliseconds
        $cand = $null; $candScore = -1
        for ($k = 0; $k -lt $n; $k++) {
            for ($a = 0; $a -lt 8; $a++) {
                $v = $st[$k].Axes[$a]; $b0 = $base.Axes[$k][$a]
                if ($v -lt $min[$k][$a] - 200) { $min[$k][$a] = $v; $tMin[$k][$a] = $now } elseif ($v -lt $min[$k][$a]) { $min[$k][$a] = $v }
                if ($v -gt $max[$k][$a] + 200) { $max[$k][$a] = $v; $tMax[$k][$a] = $now } elseif ($v -gt $max[$k][$a]) { $max[$k][$a] = $v }
                if (-not $first.ContainsKey("$k/$a") -and [Math]::Abs($v - $b0) -gt 12000) { $first["$k/$a"] = [Math]::Sign($v - $b0) }
                if ($kind -eq 'axis-pedal') { $score = $max[$k][$a] - $min[$k][$a] }
                else { $score = 2 * [Math]::Min($max[$k][$a] - $b0, $b0 - $min[$k][$a]) }
                if ($score -gt $candScore) { $candScore = $score; $cand = @{ k = $k; axis = $a } }
            }
        }
        $done = $false
        if ($cand) {
            $k = $cand.k; $a = $cand.axis; $v = $st[$k].Axes[$a]
            if ($null -ne $lastV -and [Math]::Abs($v - $lastV) -lt 1500) { if ($stableSince -eq 0) { $stableSince = $now } } else { $stableSince = 0 }
            $lastV = $v
            $stable = ($stableSince -gt 0 -and ($now - $stableSince) -ge 300)
            $range = $max[$k][$a] - $min[$k][$a]
            if ($kind -eq 'axis-pedal') {
                if ($candScore -ge $need) {
                    $pressedExt = $(if ($tMin[$k][$a] -ge $tMax[$k][$a]) { $min[$k][$a] } else { $max[$k][$a] })
                    if (([Math]::Abs($v - $pressedExt) -ge 0.8 * $range -and $stable) -or $forced) { $done = $true }
                }
            } else {
                if ($candScore -ge 2 * $need) {
                    $mid = $min[$k][$a] + $range / 2
                    if (([Math]::Abs($v - $mid) -lt 0.15 * $range -and $stable) -or $forced) { $done = $true }
                }
            }
            if ($now - $lastPrint -gt 200) {
                $lastPrint = $now
                $pn = $open[$k].Info.ProductName; if ($pn.Length -gt 28) { $pn = $pn.Substring(0, 28) }
                if ($env:AM_VISUAL -eq '1') { Send-WMEvent @{ type = 'wiz-axis'; device = $pn; axis = [WheelMap.DI]::AxisNames[$a]; value = $v; travel = $range; need = $(if ($kind -eq 'axis-pedal') { $need } else { 2 * $need }) } }
                else { Write-Host -NoNewline ("`r    strongest: {0,-28} {1,-10} value {2,5}  travel {3,5}      " -f $pn, [WheelMap.DI]::AxisNames[$a], $v, $range) }
            }
            if ($forced -and -not $done) { Write-Host ''; Write-Host '    not enough movement yet - keep going (S to skip)' -ForegroundColor DarkYellow; $forced = $false }
        }
        if ($done) {
            Write-Host ''
            $k = $cand.k; $a = $cand.axis
            return @{ k = $k; axis = $a; min = $min[$k][$a]; max = $max[$k][$a]; rest = $st[$k].Axes[$a]; base = $base.Axes[$k][$a]
                      first = $(if ($first.ContainsKey("$k/$a")) { $first["$k/$a"] } else { 0 }) }
        }
        Start-Sleep -Milliseconds 8
    }
}

function Wait-WMDigital($open, $base, [switch]$Keyboard, [switch]$AllowAxis) {
    $pending = @{}
    while ($true) {
        $key = Get-WMConsoleKey
        if ($key) {
            switch ($key.Key) { 'S' { return 'skip' } 'R' { return 'redo' } 'B' { return 'back' } 'Q' { return 'quit' } }
        }
        $st = Read-WMAll $open
        $now = [Environment]::TickCount
        for ($k = 0; $k -lt $open.Count; $k++) {
            for ($b = 0; $b -lt 128; $b++) {
                if ($st[$k].Buttons[$b] -ne 0 -and -not $base.Buttons[$k][$b]) {
                    $id = "b$k/$b"
                    if (-not $pending.ContainsKey($id)) { $pending[$id] = $now }
                    elseif ($now - $pending[$id] -ge 25) {
                        # wait for release (max 3 s)
                        $t0 = [Environment]::TickCount
                        while ([Environment]::TickCount - $t0 -lt 3000) { $s2 = $open[$k].Dev.Read(); if ($s2.Buttons[$b] -eq 0) { break }; Start-Sleep -Milliseconds 10 }
                        return @{ type = 'button'; k = $k; button = $b }
                    }
                } elseif ($pending.ContainsKey("b$k/$b")) { $pending.Remove("b$k/$b") }
            }
            # only the hats the device says it has: a handbrake with no hat (DESKTOP-RACE2's "handbrake", 0 POVs) reported a
            # changing POV value while its lever moved, and Wheel Setup recorded the handbrake as "hat 0 Up"
            for ($p = 0; $p -lt [Math]::Min(4, [int]$open[$k].Info.PovCount); $p++) {
                $v = $st[$k].Povs[$p]
                if ($v -ne $base.Povs[$k][$p] -and @(0, 9000, 18000, 27000) -contains $v) {
                    $id = "p$k/$p/$v"
                    if (-not $pending.ContainsKey($id)) { $pending[$id] = $now }
                    elseif ($now - $pending[$id] -ge 25) {
                        $t0 = [Environment]::TickCount
                        while ([Environment]::TickCount - $t0 -lt 3000) { $s2 = $open[$k].Dev.Read(); if ($s2.Povs[$p] -ne $v) { break }; Start-Sleep -Milliseconds 10 }
                        $dir = @{ 0 = 'Up'; 9000 = 'Right'; 18000 = 'Down'; 27000 = 'Left' }[$v]
                        return @{ type = 'pov'; k = $k; pov = $p; dir = $dir }
                    }
                }
            }
            if ($AllowAxis) {
                for ($a = 0; $a -lt 8; $a++) {
                    if ([Math]::Abs($st[$k].Axes[$a] - $base.Axes[$k][$a]) -gt 26000) { return @{ type = 'axis-instead'; k = $k; axis = $a } }
                }
            }
        }
        if ($Keyboard) {
            $down = @([WheelMap.Keys]::Down() | Where-Object { $base.Keys -notcontains $_ -and $script:WizardVKs -notcontains $_ })
            if ($down.Count -gt 0) {
                $vk = $down[0]
                $t0 = [Environment]::TickCount
                while ([Environment]::TickCount - $t0 -lt 3000 -and ([WheelMap.Keys]::Down() -contains $vk)) { Start-Sleep -Milliseconds 10 }
                return @{ type = 'key'; vk = $vk; name = ([System.Windows.Forms.Keys]$vk).ToString() }
            }
        }
        Start-Sleep -Milliseconds 8
    }
}

function Get-WMDeviceEntry($prof, $o, [string]$preferredId) {
    foreach ($d in $prof.devices) { if ($d.instanceGuid -eq $o.Info.InstanceGuid.ToString()) { return $d.id } }
    $id = $(if ($preferredId -and $preferredId -ne 'any') { $preferredId } else { $o.Role })
    $base = $id; $n = 2
    while (@($prof.devices | Where-Object { $_.id -eq $id }).Count -gt 0) { $id = "$base$n"; $n++ }
    $info = $o.Info
    $dev = [ordered]@{
        id = $id; productName = $info.ProductName; instanceName = $info.InstanceName
        instanceGuid = $info.InstanceGuid.ToString(); productGuid = $info.ProductGuid.ToString()
        vid = $info.Vid; pid = $info.Pid; diType = $info.TypeName; enumIndex = $info.EnumIndex
        forceFeedback = $info.ForceFeedback
    }
    $dev['sdlGuid'] = Get-WMSdlGuid ([pscustomobject]$dev) $null
    [void]$prof.devices.Add($dev)
    return $id
}

function Invoke-WMCapture {
    param([string]$Name, [string]$CabinetType = 'racing', [string]$OutFile, [string[]]$DeviceFilter, [switch]$Keyboard, [int]$Guns = 1, [string[]]$Only)
    Import-WMInput
    if ($Keyboard) { Add-Type -AssemblyName System.Windows.Forms }
    $catalog = Get-WMTemplate 'controls'
    $steps = @($catalog.wizards[$CabinetType])
    if (-not $steps) { throw "Unknown cabinet type '$CabinetType' (racing|flight|lightgun)" }
    if ($CabinetType -eq 'lightgun' -and $Guns -gt 1) {
        $extra = @()
        for ($g = 2; $g -le $Guns; $g++) {
            foreach ($s in $steps) { if ($s.device -eq 'gun1') { $c = [ordered]@{}; foreach ($k in $s.Keys) { $c[$k] = $s[$k] }; $c.device = "gun$g"; $c.control = "P$g.$($s.control)"; $c.prompt = $s.prompt -replace 'GUN 1', "GUN $g"; $extra += $c } }
        }
        $steps += $extra
    }
    if ($Only) { $steps = @($steps | Where-Object { $Only -contains $_.control }) }

    $open = @(Open-WMDevices $DeviceFilter)
    if ($open.Count -eq 0 -and -not $Keyboard) { throw 'No DirectInput game controllers found (use -Keyboard for keyboard encoders).' }
    Write-Host ''
    Write-Host 'Devices in this capture:' -ForegroundColor Cyan
    foreach ($o in $open) { Write-Host ("  #{0} {1}  [{2}, guessed role: {3}]  {4}" -f $o.Info.EnumIndex, $o.Info.ProductName, $o.Info.TypeName, $o.Role, $o.Info.InstanceGuid) }
    Send-WMEvent @{ type = 'wiz-devices'; devices = @($open | ForEach-Object { @{ name = $_.Info.ProductName; role = "$($_.Role)" } }) }
    Write-Host ''
    Write-Host 'Keys: S = skip   R = redo   B = back   Q = quit and save   Enter = accept axis now' -ForegroundColor DarkGray
    Write-Host 'Keep THIS window focused for the wizard keys; the devices are read in the background.' -ForegroundColor DarkGray

    $prof = [ordered]@{
        schema = 'wheelmap.profile/1'; name = $Name; cabinetType = $CabinetType; confirmed = $true
        source = 'WheelMap.ps1 -Capture'; created = (Get-Date).ToString('s'); machine = $env:COMPUTERNAME
        devices = New-Object System.Collections.ArrayList; controls = [ordered]@{}; notes = New-Object System.Collections.ArrayList
    }
    if ($OutFile -and (Test-Path -LiteralPath $OutFile)) {
        # resume / partial re-capture: keep everything not re-captured
        $old = Read-WMJson $OutFile
        foreach ($d in $old.devices) { [void]$prof.devices.Add($d) }
        foreach ($k in $old.controls.Keys) { $prof.controls[$k] = $old.controls[$k] }
        if ($old.Contains('notes')) { foreach ($n in $old.notes) { [void]$prof.notes.Add($n) } }
        Write-Host "Loaded existing profile $OutFile - captured steps will overwrite its entries." -ForegroundColor DarkGray
    }

    $i = 0; $skipGroup = $null
    try {
        while ($i -lt $steps.Count) {
            $s = $steps[$i]
            $kind = $catalog.controls[($s.control -replace '^P\d+\.', '')].kind
            if ($skipGroup -and $s.Contains('group') -and $s.group -eq $skipGroup) { $i++; continue }
            # a step with "auto" in controls.json is not asked: it is set by itself (racing: Select = Enter, Exit = Esc, which
            # G HUB sends for the red Enter / PS button - James 2026-11-26: "Ps should be set auto for exit, Select ... for enter")
            if ($s.Contains('auto') -and $s.auto) {
                $a = $s.auto
                if (-not ($prof.devices | Where-Object { $_.id -eq 'keyboard' })) { [void]$prof.devices.Add([ordered]@{ id = 'keyboard'; productName = 'Keyboard'; instanceGuid = $script:SysKeyboardGuid; diType = 'Keyboard' }) }
                $prof.controls[$s.control] = [ordered]@{ device = 'keyboard'; type = 'key'; vk = [int]$a.vk; name = "$($a.name)"; source = 'auto' }
                Write-Host ''; Write-Host ("[{0}/{1}] {2}  set by itself: KEY {3}" -f ($i + 1), $steps.Count, $s.control, $a.name) -ForegroundColor Green
                Send-WMEvent @{ type = 'wiz-result'; control = $s.control; value = "KEY $($a.name) (auto)"; ok = $true }
                $i++; continue
            }
            Write-Host ''
            Write-Host ("[{0}/{1}] {2}" -f ($i + 1), $steps.Count, $s.control) -ForegroundColor Yellow -NoNewline
            Write-Host ("  {0}" -f $s.prompt)
            if ($s.Contains('hint')) { Write-Host ("        suggestion: {0}" -f $s.hint) -ForegroundColor DarkGray }
            Send-WMEvent @{ type = 'wiz-step'; index = $i + 1; total = $steps.Count; control = $s.control; prompt = $s.prompt; hint = $(if ($s.Contains('hint')) { $s.hint } else { '' }); kind = "$kind" }
            Start-Sleep -Milliseconds 400
            $base = Get-WMBaseline $open
            $res = $null
            if ($kind -like 'axis*' -or $kind -eq 'aim') {
                $axKind = $(if ($kind -eq 'aim') { 'axis-bipolar' } elseif ($kind -like 'axis-pedal*') { 'axis-pedal' } else { 'axis-bipolar' })
                if ($kind -eq 'axis-pedal|digital') {
                    Write-Host '        (pull the analog handbrake, or press the handbrake button)' -ForegroundColor DarkGray
                    $res = Wait-WMDigital $open $base -Keyboard:$Keyboard -AllowAxis
                    if ($res -is [hashtable] -and $res.type -eq 'axis-instead') { $res = Wait-WMAxis $open $base 'axis-pedal' }
                } else {
                    $res = Wait-WMAxis $open $base $axKind
                }
            } else {
                $res = Wait-WMDigital $open $base -Keyboard:$Keyboard
            }
            # NB: no 'switch' here - continue/break inside a PowerShell switch only affect the switch.
            if ($res -is [string]) {
                if ($res -eq 'skip') {
                    Write-Host '    skipped'; $prof.controls[$s.control] = [ordered]@{ type = 'none' }
                    Send-WMEvent @{ type = 'wiz-result'; control = $s.control; value = 'SKIPPED'; ok = $false }
                    if ($s.Contains('group')) { $skipGroup = $s.group }
                    $i++; continue
                }
                if ($res -eq 'redo') { continue }
                if ($res -eq 'back') { if ($i -gt 0) { $i-- }; $skipGroup = $null; continue }
                if ($res -eq 'mouse') {
                    $prof.controls[$s.control] = [ordered]@{ device = $s.device; type = 'mouse'; axis = $(if ($s.control -like '*AimY') { 'Y' } else { 'X' }); note = 'mouse-mode gun: bind via RawInput/multi-mouse in the emulator' }
                    Write-Host '    recorded as mouse-mode gun'; $i++; continue
                }
                Write-Host '    quitting - saving what was captured'
                break
            }
            $o = $open[$res.k]
            $devId = Get-WMDeviceEntry $prof $o $s.device
            if ($res.Contains('axis') -and -not $res.Contains('type')) {
                $ofs = 4 * $res.axis
                $entry = [ordered]@{ device = $devId; type = 'axis'; axis = [WheelMap.DI]::AxisNames[$res.axis]; offset = $ofs; min = $res.min; max = $res.max }
                if ($kind -like 'axis-pedal*') {
                    $rest = $res.rest
                    $pressed = $(if ([Math]::Abs($res.max - $rest) -gt [Math]::Abs($rest - $res.min)) { $res.max } else { $res.min })
                    $entry.direction = $(if ($pressed -gt $rest) { '+' } else { '-' })
                    $entry.rest = $rest; $entry.pressed = $pressed
                    $entry.full = ([Math]::Abs($pressed - $rest) -gt 45000)
                    Write-Host ("    -> {0} {1}{2}  rest {3} pressed {4}" -f $o.Info.ProductName, $entry.axis, $entry.direction, $rest, $pressed) -ForegroundColor Green
                } else {
                    # prompt says LEFT (or FORWARD / TOP) first: first deviation sign tells us if that end is low or high
                    $entry.invert = ($res.first -gt 0)
                    $entry.center = $res.rest
                    Write-Host ("    -> {0} {1}  range {2}..{3}  invert={4}" -f $o.Info.ProductName, $entry.axis, $res.min, $res.max, $entry.invert) -ForegroundColor Green
                    if (($res.max - $res.min) -lt 50000) { Write-Host '    note: less than ~75% of the range was used - turn to full lock next time for an accurate range' -ForegroundColor DarkYellow }
                }
            } elseif ($res.type -eq 'button') {
                $entry = [ordered]@{ device = $devId; type = 'button'; button = $res.button }
                Write-Host ("    -> {0} button {1} (DirectInput index, 0-based)" -f $o.Info.ProductName, $res.button) -ForegroundColor Green
            } elseif ($res.type -eq 'pov') {
                $entry = [ordered]@{ device = $devId; type = 'pov'; pov = $res.pov; dir = $res.dir }
                Write-Host ("    -> {0} hat {1} {2}" -f $o.Info.ProductName, $res.pov, $res.dir) -ForegroundColor Green
            } elseif ($res.type -eq 'key') {
                if (-not ($prof.devices | Where-Object { $_.id -eq 'keyboard' })) { [void]$prof.devices.Add([ordered]@{ id = 'keyboard'; productName = 'Keyboard'; instanceGuid = $script:SysKeyboardGuid; diType = 'Keyboard' }) }
                $entry = [ordered]@{ device = 'keyboard'; type = 'key'; vk = $res.vk; name = $res.name }
                Write-Host ("    -> key {0} (VK 0x{1:X2})" -f $res.name, $res.vk) -ForegroundColor Green
            }
            # duplicate warning
            foreach ($k in @($prof.controls.Keys)) {
                $e = $prof.controls[$k]
                if ($k -ne $s.control -and $e.Contains('device') -and $e.device -eq $entry.device -and $e.type -eq $entry.type -and
                    (($e.type -eq 'button' -and $e.button -eq $entry.button) -or ($e.type -eq 'axis' -and $e.axis -eq $entry.axis) -or ($e.type -eq 'pov' -and $e.pov -eq $entry.pov -and $e.dir -eq $entry.dir))) {
                    Write-Host ("    warning: same input is already bound to {0} (R = redo if unintended)" -f $k) -ForegroundColor DarkYellow
                }
            }
            $prof.controls[$s.control] = $entry
            $what = switch ($entry.type) { 'axis' { "$($entry.axis)$(if ($entry.Contains('direction')) { $entry.direction })" } 'button' { "BUTTON $($entry.button)" } 'pov' { "HAT $($entry.dir)" } 'key' { "KEY $($entry.name)" } default { $entry.type } }
            Send-WMEvent @{ type = 'wiz-result'; control = $s.control; value = "$what"; ok = $true }
            $i++
        }
    } finally {
        Close-WMDevices $open
    }
    $missing = @($steps | Where-Object { $_.Contains('required') -and $_.required -and -not $prof.controls.Contains($_.control) } | ForEach-Object { $_.control })
    if ($missing) { [void]$prof.notes.Add("required controls not captured: $($missing -join ', ')"); Write-Warning "Not captured: $($missing -join ', ')" }
    return $prof
}

function Show-WMMonitor([int]$Seconds = 10, [string[]]$DeviceFilter) {
    $open = @(Open-WMDevices $DeviceFilter)
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($Seconds -le 0 -or $sw.Elapsed.TotalSeconds -lt $Seconds) {
            $st = Read-WMAll $open
            $parts = @()
            for ($k = 0; $k -lt $open.Count; $k++) {
                $s = $st[$k]
                $ax = @(); for ($a = 0; $a -lt 8; $a++) { if ($s.Axes[$a] -ne 0) { $ax += ('{0}={1}' -f [WheelMap.DI]::AxisNames[$a], $s.Axes[$a]) } }
                $bt = @(0..127 | Where-Object { $s.Buttons[$_] -ne 0 })
                $pv = @(0..3 | Where-Object { $s.Povs[$_] -ge 0 } | ForEach-Object { "POV$_=$($s.Povs[$_])" })
                $parts += ('#{0} {1} | btn[{2}] {3}' -f $open[$k].Info.EnumIndex, ($ax -join ' '), ($bt -join ','), ($pv -join ' '))
            }
            Write-Host ("`r" + ($parts -join '  ||  ').PadRight(150)) -NoNewline
            if (Get-WMConsoleKey) { break }
            Start-Sleep -Milliseconds 100
        }
        Write-Host ''
    } finally { Close-WMDevices $open }
}
