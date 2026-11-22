# Gen-Others.ps1 - Dolphin / Dolphin Triforce / Supermodel / MAME / Cemu / m2emulator / FFBPlugin generators

$script:VkNames = @{ 0x0D = 'RETURN'; 0x20 = 'SPACE'; 0x1B = 'ESCAPE'; 0x08 = 'BACKSPACE'; 0x09 = 'TAB'; 0x25 = 'LEFT'; 0x26 = 'UP'; 0x27 = 'RIGHT'; 0x28 = 'DOWN'
                     0xA0 = 'LEFTSHIFT'; 0xA1 = 'RIGHTSHIFT'; 0xA2 = 'LEFTCTRL'; 0xA3 = 'RIGHTCTRL'; 0xA4 = 'LEFTALT'; 0xA5 = 'RIGHTALT'
                     0x6B = 'ADD'; 0x6D = 'SUBTRACT'; 0x2D = 'INSERT'; 0x2E = 'DEL'; 0x24 = 'HOME'; 0x23 = 'END'; 0x21 = 'PGUP'; 0x22 = 'PGDN' }

function Get-WMVkName([int]$vk) {
    if ($vk -ge 0x41 -and $vk -le 0x5A) { return [string][char]$vk }
    if ($vk -ge 0x30 -and $vk -le 0x39) { return [string][char]$vk }
    if ($vk -ge 0x70 -and $vk -le 0x7B) { return 'F' + ($vk - 0x6F) }
    if ($vk -ge 0x60 -and $vk -le 0x69) { return 'KEYPAD' + ($vk - 0x60) }
    if ($script:VkNames.ContainsKey($vk)) { return $script:VkNames[$vk] }
    return $null
}

function Split-WMHalf([string]$c) {
    if ($c -match '^(.+?)([+-])$') { return @($Matches[1], $Matches[2]) }
    return @($c, $null)
}

function Get-WMPrimaryDevice($Prof) {
    foreach ($id in 'wheel', 'stick', 'gun1', 'pad', 'controller') { $d = Get-WMDevice $Prof $id; if ($d) { return $d } }
    foreach ($d in $Prof.devices) { if ($d.id -ne 'keyboard') { return $d } }
    return $null
}

function Get-WMDiDevices($Prof) { return @($Prof.devices | Where-Object { $_.id -ne 'keyboard' -and $_.id -notlike 'mouse*' }) }

# ------------------------------------------------------------------ Dolphin
$script:DolphinAxis = @{ 'X' = 'Axis X'; 'Y' = 'Axis Y'; 'Z' = 'Axis Z'; 'RotationX' = 'Axis Xr'; 'RotationY' = 'Axis Yr'; 'RotationZ' = 'Axis Zr'; 'Sliders0' = 'Slider 0'; 'Sliders1' = 'Slider 1' }
$script:DolphinHat = @{ 'Up' = 'N'; 'Right' = 'E'; 'Down' = 'S'; 'Left' = 'W' }

function Get-WMDolphinExpr($Prof, [string]$Entry, $Primary, [string]$Style, $Warn) {
    $parts = Split-WMHalf $Entry
    $b = Get-WMBinding $Prof $parts[0]
    if (-not $b) { return $null }
    $half = $parts[1]
    $dev = Get-WMDevice $Prof $b.device
    $name = $null
    switch ($b.type) {
        'axis' {
            $an = $script:DolphinAxis[$b.axis]
            if ($half) {
                $s = $half
                if ($b.Contains('invert') -and $b.invert) { $s = $(if ($s -eq '-') { '+' } else { '-' }) }
                if ($b.Contains('direction')) { $s = $b.direction }   # pedal used as a half: pressed side
                $name = "$an$s"
            } elseif ($b.Contains('direction')) {
                $press = $b.direction; $rest = $(if ($press -eq '-') { '+' } else { '-' })
                if (-not (Test-WMFullTravel $b)) { $name = "$an$press" }            # rests at centre: the pressed half is the whole travel
                elseif ($Style -eq 'surface') { $name = "$an$rest$press" }         # older builds: 'Axis Y+-'
                else { $name = "Full $an$press" }                                 # current builds: 'Full Axis Y-'
            } else { $name = "$an+" }
        }
        'button' { $name = "Button $($b.button)" }
        'pov'    { $name = "Hat $($b.pov) $($script:DolphinHat[$b.dir])" }
        default  { if ($Warn) { & $Warn "Dolphin: '$($b._control)' is a $($b.type) binding - not supported in a DInput profile, skipped" }; return $null }
    }
    if ($dev -and $Primary -and $dev.id -ne $Primary.id) { $name = "DInput/0/$($dev.productName):$name" }
    return "``$name``"
}

function New-WMDolphinBody($Prof, $Map, $Settings, $Primary, [string]$Style, [string]$Header, $Warn) {
    $sb = New-Object System.Text.StringBuilder
    if ($Header) { [void]$sb.AppendLine($Header) }
    [void]$sb.AppendLine("Device = DInput/0/$($Primary.productName)")
    foreach ($slot in $Map.Keys) {
        $exprs = @()
        foreach ($e in $Map[$slot]) { $x = Get-WMDolphinExpr $Prof $e $Primary $Style $Warn; if ($x -and $exprs -notcontains $x) { $exprs += $x } }
        if ($exprs) { [void]$sb.AppendLine("$slot = $($exprs -join '|')") }
    }
    if ($Settings) { foreach ($k in $Settings.Keys) { [void]$sb.AppendLine("$k = $($Settings[$k])") } }
    return $sb.ToString()
}

function Set-WMIniValue([string[]]$Lines, [string]$Section, [string]$Key, [string]$Value) {
    $out = New-Object System.Collections.ArrayList
    $inSec = $false; $done = $false; $secFound = $false
    foreach ($l in $Lines) {
        if ($l -match '^\s*\[(.+?)\]\s*$') {
            if ($inSec -and -not $done) { [void]$out.Add("$Key = $Value"); $done = $true }
            $inSec = ($Matches[1].Trim() -eq $Section); if ($inSec) { $secFound = $true }
        } elseif ($inSec -and $l -match ('^\s*' + [regex]::Escape($Key) + '\s*=')) {
            if (-not $done) { [void]$out.Add("$Key = $Value"); $done = $true }
            continue
        }
        [void]$out.Add($l)
    }
    if (-not $done) {
        if (-not $secFound) { if ($out.Count -and $out[$out.Count - 1] -ne '') { [void]$out.Add('') }; [void]$out.Add("[$Section]") }
        [void]$out.Add("$Key = $Value")
    }
    return , $out.ToArray()
}

function Read-WMLines([string]$Path) {
    if (Test-Path -LiteralPath $Path) { return , ([IO.File]::ReadAllText($Path) -split "\r?\n") }
    return , @()
}

function Invoke-WMGenDolphin($Prof, $Targets, $Manifest) {
    $tpl = Get-WMTemplate 'dolphin'
    $primary = Get-WMPrimaryDevice $Prof
    $warn = { param($m) Add-WMWarning $Manifest $m }
    $rep = New-Object System.Collections.ArrayList
    foreach ($t in @($Targets.dolphin)) {
        if (-not $t) { continue }
        $user = $t.user
        $style = $(if ($t.Contains('axisStyle')) { $t.axisStyle } else { 'fullaxis' })
        foreach ($kind in 'gcpad', 'wiimote') {
            $folder = $(if ($kind -eq 'gcpad') { 'GCPad' } else { 'Wiimote' })
            foreach ($key in $tpl[$kind].Keys) {
                $p = $tpl[$kind][$key]
                $profName = "$key $($Prof.name)"
                $body = New-WMDolphinBody $Prof $p.map $p.settings $primary $style '[Profile]' $warn
                Add-WMStaged $Manifest (Join-Path $user "Config\Profiles\$folder\$profName.ini") $body 'dolphin' "$($p.title): $($p.notes)"
                foreach ($gid in $p.games) {
                    $gs = Join-Path $user "GameSettings\$gid.ini"
                    $lines = Read-WMLines $gs
                    if ($kind -eq 'gcpad') { $lines = Set-WMIniValue $lines 'Controls' 'PadProfile1' $profName }
                    else { $lines = Set-WMIniValue $lines 'Controls' 'WiimoteProfile1' $profName }
                    Add-WMStaged $Manifest $gs (($lines -join "`r`n")) 'dolphin' "$gid -> $profName (PadType lines preserved)"
                }
                [void]$rep.Add([pscustomobject]@{ profile = $profName; games = ($p.games -join ','); title = $p.title })
            }
        }
    }
    foreach ($t in @($Targets.dolphinTriforce)) {
        if (-not $t) { continue }
        $p = $tpl.triforce[$t.game]
        if (-not $p) { Add-WMWarning $Manifest "Dolphin Triforce: no template for '$($t.game)'"; continue }
        $style = $(if ($t.Contains('axisStyle')) { $t.axisStyle } else { 'surface' })
        $settings = $(if ($p.Contains('settings')) { $p.settings } else { $null })
        $body = (New-WMDolphinBody $Prof $p.map $settings $primary $style '[GCPad1]' $warn).TrimEnd()
        # keep [GCPad2..4] (and anything else) from the live file
        $rest = @(); $skip = $false
        foreach ($l in (Read-WMLines $t.config)) {
            if ($l -match '^\s*\[(.+?)\]\s*$') { $skip = ($Matches[1] -eq 'GCPad1') }
            if (-not $skip) { $rest += $l }
        }
        $text = $body + "`r`n" + (($rest -join "`r`n").Trim()) + "`r`n"
        Add-WMStaged $Manifest $t.config $text 'dolphin-triforce' "$($t.game): $($p.notes)"
        [void]$rep.Add([pscustomobject]@{ profile = 'GCPad1'; games = $t.game; title = 'Triforce' })
    }
    return $rep
}

# ------------------------------------------------------------------ Supermodel
$script:SmAxis = @{ 'X' = 'XAXIS'; 'Y' = 'YAXIS'; 'Z' = 'ZAXIS'; 'RotationX' = 'RXAXIS'; 'RotationY' = 'RYAXIS'; 'RotationZ' = 'RZAXIS'; 'Sliders0' = 'SLIDER1'; 'Sliders1' = 'SLIDER2' }

function Get-WMSupermodelCode($Prof, [string]$Control, [string]$PedalStyle, [bool]$Digital) {
    $b = Get-WMBinding $Prof $Control
    if (-not $b) { return $null }
    if ($b.type -eq 'key') { $n = Get-WMVkName $b.vk; if ($n) { return "KEY_$n" } else { return $null } }
    $dev = Get-WMDevice $Prof $b.device
    $j = "JOY$($dev.enumIndex)"
    switch ($b.type) {
        'axis' {
            $a = "$j`_$($script:SmAxis[$b.axis])"
            if ($b.Contains('direction')) {
                $useHalf = $Digital -or $PedalStyle -eq 'half' -or ($PedalStyle -eq 'auto' -and -not (Test-WMFullTravel $b))
                if ($useHalf) { return $a + $(if ($b.direction -eq '-') { '_NEG' } else { '_POS' }) }
                return $a + $(if ($b.direction -eq '-') { '_INV' } else { '' })
            }
            if ($b.Contains('invert') -and $b.invert) { return "$a`_INV" }
            return $a
        }
        'button' { return "$j`_BUTTON$([int]$b.button + 1)" }
        'pov'    { return "$j`_POV$([int]$b.pov + 1)_$($b.dir.ToUpper())" }
    }
    return $null
}

function Invoke-WMGenSupermodel($Prof, $Targets, $Manifest) {
    $tpl = Get-WMTemplate 'supermodel'
    $rep = New-Object System.Collections.ArrayList
    $analogKeys = @('InputSteering', 'InputAccelerator', 'InputBrake', 'InputAnalogJoyX', 'InputAnalogJoyY')
    foreach ($t in @($Targets.supermodel)) {
        if (-not $t) { continue }
        $lines = New-Object System.Collections.ArrayList; $lines.AddRange([string[]](Read-WMLines $t.ini))
        $gStart = -1; $gEnd = $lines.Count
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*\[\s*(.+?)\s*\]') { if ($Matches[1] -eq 'Global') { $gStart = $i } elseif ($gStart -ge 0 -and $gEnd -eq $lines.Count) { $gEnd = $i } }
        }
        if ($gStart -lt 0) { $lines.Insert(0, '[ Global ]'); $gStart = 0; $gEnd++ }
        $set = @()
        foreach ($k in $tpl.keys.Keys) {
            $code = Get-WMSupermodelCode $Prof $tpl.keys[$k] $tpl.pedalStyle (-not ($analogKeys -contains $k))
            if (-not $code) { continue }
            $val = "$k = `"$code`""
            $found = $false
            for ($i = $gStart; $i -lt $gEnd; $i++) {
                if ($lines[$i] -match ('^\s*' + $k + '\s*=')) { $lines[$i] = $val; $found = $true; break }
            }
            if (-not $found) { $lines.Insert($gEnd, $val); $gEnd++ }
            $set += "$k=$code"
        }
        foreach ($kv in @{ 'InputSystem' = 'dinput'; 'ForceFeedback' = '1' }.GetEnumerator()) {
            $found = $false
            for ($i = $gStart; $i -lt $gEnd; $i++) { if ($lines[$i] -match ('^\s*' + $kv.Key + '\s*=')) { $lines[$i] = "$($kv.Key)=$($kv.Value)"; $found = $true; break } }
            if (-not $found) { $lines.Insert($gEnd, "$($kv.Key)=$($kv.Value)"); $gEnd++ }
        }
        $wheel = Get-WMPrimaryDevice $Prof
        $note = "JOY$($wheel.enumIndex) = $($wheel.productName) (DirectInput enumeration order on this machine; the previous file used JOY2 for the wheel). pedalStyle=$($tpl.pedalStyle)"
        Add-WMStaged $Manifest $t.ini (($lines -join "`r`n")) 'supermodel' $note
        [void]$rep.Add([pscustomobject]@{ ini = $t.ini; set = ($set -join '; ') })
    }
    return $rep
}

# ------------------------------------------------------------------ MAME
$script:MameAxis = $script:SmAxis

function Get-WMMameIndex($Prof, [string]$DeviceId) {
    $list = Get-WMDiDevices $Prof
    for ($i = 0; $i -lt $list.Count; $i++) { if ($list[$i].id -eq $DeviceId) { return $i + 1 } }
    return 1
}

function Get-WMMameCode($Prof, [string]$Control, [bool]$Digital, [string]$RefSuffix, [string]$RefDir) {
    $b = Get-WMBinding $Prof $Control
    if (-not $b) { return $null }
    if ($b.type -eq 'key') { $n = Get-WMVkName $b.vk; if ($n) { return "KEYCODE_$($n -replace '^RETURN$','ENTER' -replace '^KEYPAD(\d)$','$1PAD')" } else { return $null } }
    $j = "JOYCODE_$(Get-WMMameIndex $Prof $b.device)"
    switch ($b.type) {
        'axis' {
            $a = "$j`_$($script:MameAxis[$b.axis])"
            if ($Digital) { return $a + $(if ($b.Contains('direction') -and $b.direction -eq '+') { '_POS_SWITCH' } else { '_NEG_SWITCH' }) }
            if ($RefSuffix -and $b.Contains('direction')) {
                # keep the reference half-axis form; flip it if this pedal moves the other way
                $s = $RefSuffix
                if ($RefDir -and $b.direction -ne $RefDir) { $s = $(if ($s -eq '_POS') { '_NEG' } else { '_POS' }) }
                return "$a$s"
            }
            return $a
        }
        'button' { return "$j`_BUTTON$([int]$b.button + 1)" }
        'pov'    { return "$j`_HAT$([int]$b.pov + 1)$($b.dir.ToUpper())" }
    }
    return $null
}

# MAME controller file (ctrlr\wheelmap.cfg, <system name="default">): wheel / pedals / flight stick / buttons for
# EVERY game, by input type. Per-game cfg files (tags known) still override it with full-travel pedals + reverse="yes".
# MAME sequences cannot reverse an axis, so a pedal here uses the half of its axis it travels into when pressed.
function Get-WMMameAnalog($Prof, [string]$Spec) {
    foreach ($c in ($Spec -split '\|')) {
        $b = Get-WMBinding $Prof $c
        if (-not $b -or $b.type -ne 'axis') { continue }
        $a = "JOYCODE_$(Get-WMMameIndex $Prof $b.device)_$($script:MameAxis[$b.axis])"
        if ($b.Contains('direction')) { return $a + $(if ($b.direction -eq '-') { '_NEG' } else { '_POS' }) }
        return $a
    }
    return $null
}
function Get-WMMameSeq($Prof, [string[]]$Specs) {
    $parts = @(); foreach ($s in $Specs) { foreach ($c in ($s -split '\|')) { $x = Get-WMMameCode $Prof $c $true $null $null; if ($x) { $parts += $x; break } } }
    if ($parts) { return ($parts | Select-Object -Unique) -join ' OR ' }
    return $null
}
function Invoke-WMGenMameDefaults($Prof, $t, $Manifest) {
    $analog = [ordered]@{
        P1_PADDLE = 'Steering'; P1_DIAL = 'Steering'; P1_POSITIONAL = 'Steering'
        P1_PEDAL = 'Gas|Throttle'; P1_PEDAL2 = 'Brake'; P1_PEDAL3 = 'Clutch'
        P1_AD_STICK_X = 'Roll|Steering'; P1_AD_STICK_Y = 'Pitch'; P1_AD_STICK_Z = 'Throttle|Gas'
    }
    $digital = [ordered]@{
        P1_BUTTON1 = @('GearUp', 'GearDown', 'Fire'); P1_BUTTON2 = @('ViewChange|Missile'); P1_BUTTON3 = @('Nitro|Special'); P1_BUTTON4 = @('View2|Action1')
        P1_JOYSTICK_UP = @('MenuUp'); P1_JOYSTICK_DOWN = @('MenuDown'); P1_JOYSTICK_LEFT = @('MenuLeft'); P1_JOYSTICK_RIGHT = @('MenuRight')
        START1 = @('Start'); COIN1 = @('Coin'); COIN2 = @('Coin2'); SERVICE1 = @('Service'); SERVICE = @('Test')
    }
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0"?>')
    [void]$sb.AppendLine("<!-- ArcadeMaster controller defaults for $($Prof.name) - generated by WheelMap; selected by mame.ini 'ctrlr wheelmap'; verify device ids with: mame -v -->")
    [void]$sb.AppendLine('<mameconfig version="10">'); [void]$sb.AppendLine('    <system name="default">'); [void]$sb.AppendLine('        <input>')
    # pin JOYCODE_n to the physical devices (DirectInput instance GUID; MAME matches by substring)
    $i = 0; foreach ($d in (Get-WMDiDevices $Prof)) { $i++; [void]$sb.AppendLine(("            <mapdevice device=""{0}"" controller=""JOYCODE_{1}"" /> <!-- {2} -->" -f $d.instanceGuid, $i, [Security.SecurityElement]::Escape($d.productName))) }
    $desc = @()
    foreach ($k in $analog.Keys) { $s = Get-WMMameAnalog $Prof $analog[$k]; if ($s) { [void]$sb.AppendLine("            <port type=`"$k`"><newseq type=`"standard`">$s</newseq></port>"); $desc += "$k=$s" } }
    foreach ($k in $digital.Keys) { $s = Get-WMMameSeq $Prof $digital[$k]; if ($s) { [void]$sb.AppendLine("            <port type=`"$k`"><newseq type=`"standard`">$s</newseq></port>"); $desc += "$k=$s" } }
    [void]$sb.AppendLine('        </input>'); [void]$sb.AppendLine('    </system>'); [void]$sb.AppendLine('</mameconfig>')
    Add-WMStaged $Manifest (Join-Path $t.root 'ctrlr\wheelmap.cfg') $sb.ToString() 'mame' ("defaults for every game: " + ($desc -join ' '))
    $ini = Join-Path $t.root 'mame.ini'; $lines = Read-WMLines $ini
    if ($lines.Count) {
        $hit = $false
        $lines = @($lines | ForEach-Object { if ($_ -match '^ctrlr\s') { $hit = $true; 'ctrlr                     wheelmap' } else { $_ } })
        if (-not $hit) { $lines += 'ctrlr                     wheelmap' }
        Add-WMStaged $Manifest $ini ($lines -join "`r`n") 'mame' 'ctrlr wheelmap'
    }
}
function Invoke-WMGenMame($Prof, $Targets, $Manifest) {
    $tpl = Get-WMTemplate 'mame'
    $rep = New-Object System.Collections.ArrayList
    $ref = $tpl.referenceLayout
    $wheel = Get-WMPrimaryDevice $Prof
    foreach ($t in @($Targets.mame)) {
        if (-not $t) { continue }
        Invoke-WMGenMameDefaults $Prof $t $Manifest
        $cfgDir = Join-Path $t.root 'cfg'
        foreach ($game in $tpl.games.Keys) {
            $live = Join-Path $cfgDir "$game.cfg"
            $base = $live
            if (-not (Test-Path -LiteralPath $base)) { $base = Join-Path $t.reference "$game.cfg" }
            if (-not (Test-Path -LiteralPath $base)) { continue }
            $xml = New-Object System.Xml.XmlDocument; $xml.PreserveWhitespace = $true; $xml.Load($base)
            $g = $tpl.games[$game]
            $changed = @(); $raw = New-Object System.Collections.ArrayList
            foreach ($port in $xml.SelectNodes("//system[@name='$game']/input/port")) {
                $type = $port.GetAttribute('type')
                $ctl = $null
                if ($g.Contains('ports') -and $g.ports.Contains($type)) { $ctl = $g.ports[$type] }
                elseif ($tpl.ports.Contains($type)) { $ctl = $tpl.ports[$type] }
                foreach ($ns in $port.SelectNodes('newseq')) {
                    $seqType = $ns.GetAttribute('type')
                    $old = $ns.InnerText.Trim()
                    if ($old -notmatch 'JOYCODE' -and -not ($ctl -and $seqType -eq 'standard')) { continue }
                    $isAnalogPort = ($type -match 'PADDLE|DIAL|PEDAL|AD_STICK|LIGHTGUN|POSITIONAL|TRACKBALL|MOUSE')
                    $new = $null
                    if ($ctl -and $seqType -eq 'standard') {
                        $suffix = $null; $refDir = $null
                        if ($old -match 'JOYCODE_\d+_(\w+?)(_POS|_NEG)?$') { $suffix = $Matches[2]; if ($ref.pedalDirection.Contains($Matches[1])) { $refDir = $ref.pedalDirection[$Matches[1]] } }
                        $new = Get-WMMameCode $Prof $ctl (-not $isAnalogPort) $suffix $refDir
                        if (-not $new) { continue }
                        # keep extra OR'ed keyboard alternatives from the original sequence
                        $kb = @([regex]::Matches($old, 'KEYCODE_\w+') | ForEach-Object { $_.Value })
                        if ($kb) { $new = (@($new) + $kb) -join ' OR ' }
                    } else {
                        $new = [regex]::Replace($old, 'JOYCODE_(\d+)_([A-Z0-9]+?)(_POS|_NEG)?(_SWITCH|_LEFT_SWITCH|_RIGHT_SWITCH|_UP_SWITCH|_DOWN_SWITCH)?(?=\s|$)', {
                                param($m)
                                $item = $m.Groups[2].Value; $half = $m.Groups[3].Value; $sw = $m.Groups[4].Value
                                if ($ref.codes.Contains($item)) {
                                    $c = Get-WMMameCode $Prof $ref.codes[$item] ([bool]$sw -or -not $isAnalogPort) $half $(if ($ref.pedalDirection.Contains($item)) { $ref.pedalDirection[$item] } else { $null })
                                    if ($c) { if ($sw -and $c -notmatch '_SWITCH$' -and $c -match '_(X|Y|Z|RX|RY|RZ)AXIS$|SLIDER\d$') { $c += $sw }; return $c }
                                }
                                [void]$raw.Add($item)
                                return "JOYCODE_$(Get-WMMameIndex $Prof $wheel.id)_$item$half$sw"
                            })
                    }
                    if ($new -ne $old) { $ns.InnerText = "`n                    $new`n                "; $changed += "$type=$new" }
                }
                # analog pedal direction: MAME 'reverse' attribute follows the reference when the form is a full axis
                if ($ctl -and $ctl -eq 'Steering') {
                    $b = Get-WMBinding $Prof 'Steering'
                    if ($b -and $b.Contains('invert') -and $b.invert) { $port.SetAttribute('reverse', 'yes') }
                }
            }
            $text = $xml.OuterXml
            Add-WMStaged $Manifest $live $text 'mame' ("$($g.title): " + $(if ($g.Contains('notes')) { $g.notes } else { '' }) + $(if (Test-Path -LiteralPath $live) { '' } else { ' (from reference set; live cfg missing)' }))
            [void]$rep.Add([pscustomobject]@{ game = $game; title = $g.title; changes = $changed.Count; rawButtonsKept = (($raw | Select-Object -Unique) -join ',') })
        }
    }
    return $rep
}

# ------------------------------------------------------------------ Cemu
function Get-WMCemuCode($Prof, [string]$Spec, $WheelId, $Warn) {
    foreach ($c in ($Spec -split '\|')) {
        $half = $null; if ($c -match '^(.+?)([+-])$') { $c = $Matches[1]; $half = $Matches[2] }
        $b = Get-WMBinding $Prof $c
        if (-not $b) { continue }
        if ($b.device -ne $WheelId) { if ($Warn) { & $Warn "Cemu: $c is on '$($b.device)' - a Cemu profile reads one DirectInput device, skipped" }; continue }
        switch ($b.type) {
            'button' { if ([int]$b.button -lt 32) { return [int]$b.button } }
            'pov'    { return 34 + @{ Up = 0; Down = 1; Left = 2; Right = 3 }[$b.dir] }
            'axis' {
                $pair = @{ 0 = @(38, 44); 4 = @(39, 45); 12 = @(40, 46); 16 = @(41, 47); 8 = @(42, 48); 20 = @(43, 49) }[[int]$b.offset]
                if (-not $pair) { if ($Warn) { & $Warn "Cemu: $c is on a slider axis ($($b.axis)) - Cemu's DirectInput API cannot read sliders" }; continue }
                if ($b.Contains('direction')) { $neg = ($b.direction -eq '-') }                     # pedal: the half it travels to
                else { $neg = ($half -eq '-'); if ($b.Contains('invert') -and $b.invert) { $neg = -not $neg } }
                return $(if ($neg) { $pair[1] } else { $pair[0] })
            }
        }
    }
    return $null
}

function Invoke-WMGenCemu($Prof, $Targets, $Manifest) {
    $tpl = Get-WMTemplate 'cemu'
    $rep = New-Object System.Collections.ArrayList
    $wheel = Get-WMPrimaryDevice $Prof
    $warn = { param($m) Add-WMWarning $Manifest $m }
    foreach ($t in @($Targets.cemu)) {
        if (-not $t) { continue }
        foreach ($gid in $tpl.games.Keys) {
            $g = $tpl.games[$gid]; $layout = $tpl.layouts[$g.layout]
            $profileName = $Prof.name
            $x = New-Object System.Xml.XmlDocument
            $root = $x.AppendChild($x.CreateElement('emulated_controller'))
            function Add-El($parent, [string]$n, [string]$v) { $el = $parent.AppendChild($x.CreateElement($n)); if ($null -ne $v) { $el.InnerText = $v }; return $el }
            [void](Add-El $root 'type' $tpl.controllerType); [void](Add-El $root 'profile' $profileName)
            $c = Add-El $root 'controller' $null
            [void](Add-El $c 'api' 'DirectInput'); [void](Add-El $c 'uuid' $wheel.instanceGuid); [void](Add-El $c 'display_name' $wheel.productName)
            foreach ($sec in @(@('axis', '0', '1'), @('rotation', '0.2', '1'), @('trigger', '0.2', '0.3'))) { $s = Add-El $c $sec[0] $null; [void](Add-El $s 'deadzone' $sec[1]); [void](Add-El $s 'range' $sec[2]) }
            $maps = Add-El $c 'mappings' $null; $desc = @()
            foreach ($slot in $layout.Keys) {
                $code = Get-WMCemuCode $Prof $layout[$slot] $wheel.id $warn
                if ($null -eq $code) { continue }
                $en = Add-El $maps 'entry' $null; [void](Add-El $en 'mapping' $slot); [void](Add-El $en 'button' ([string]$code)); $desc += "$slot=$code"
            }
            $live = Join-Path $t.root "controllerProfiles\$profileName.xml"
            Add-WMStaged $Manifest $live ('<?xml version="1.0" encoding="UTF-8"?>' + "`r`n" + $x.OuterXml) 'cemu' ("$($g.title) [$($g.layout)] $($wheel.productName): " + ($desc -join ' '))
            # game profile selects this controller profile
            $ini = Join-Path $t.root "gameProfiles\$gid.ini"
            $lines = Read-WMLines $ini
            if (-not $lines.Count -and $t.Contains('reference')) { $lines = Read-WMLines (Join-Path $t.reference "$gid.ini") }
            if (-not $lines.Count) { $lines = @('[Controller]') }
            $lines = Set-WMIniValue $lines 'Controller' 'controller1' $profileName
            Add-WMStaged $Manifest $ini ($lines -join "`r`n") 'cemu' "$($g.title) -> controller1 = $profileName"
            [void]$rep.Add([pscustomobject]@{ game = $g.title; profile = $live; mappings = $desc.Count })
        }
    }
    return $rep
}
# ------------------------------------------------------------------ Model 2 Emulator (ElSemi)
# DirectInput OBJECT enumeration index of an axis (what m2emulator numbers axes by), from the live device.
$script:WMAxisOrderCache = @{}
function Get-WMAxisObjectIndex($Prof, $dev, [int]$offset) {
    if (-not $dev) { return $null }
    $key = "$($dev.instanceGuid)|$($dev.productName)"
    if (-not $script:WMAxisOrderCache.ContainsKey($key)) {
        $order = $null
        try {
            Import-WMInput
            $live = @([WheelMap.DI]::Enumerate($true))
            $hit = @($live | Where-Object { $_.InstanceGuid.ToString() -eq $dev.instanceGuid }) + @($live | Where-Object { $_.ProductName -eq $dev.productName })
            if ($hit) { $order = @($hit[0].Objects | Where-Object { $_.Kind -eq 'Axis' } | ForEach-Object { $_.Offset }) }
        } catch { }
        if (-not $order -and $dev.Contains('axisOrder')) { $order = @($dev.axisOrder) }   # recorded at capture time
        $script:WMAxisOrderCache[$key] = $order
    }
    $order = $script:WMAxisOrderCache[$key]
    if ($order) { $i = [array]::IndexOf([int[]]$order, $offset); if ($i -ge 0) { return $i } }
    return $null
}

function Get-WMM2Code($Prof, [string]$Spec, [bool]$Analog, $Warn) {
    # Spec: 'Gas!' (analog) or 'GearUp' or 'Roll!|Steering!' (fallbacks)
    foreach ($c in ($Spec -split '\|')) {
        $wantAnalog = $c.EndsWith('!'); $name = $c.TrimEnd('!')
        $b = Get-WMBinding $Prof $name
        if (-not $b) { continue }
        $dev = Get-WMDevice $Prof $b.device
        $joy = $(if ($dev) { [int]$dev.enumIndex } else { 1 })
        if ($b.type -eq 'key') {
            if ($Analog) { continue }
            Add-Type -Namespace WM -Name Kb -MemberDefinition '[DllImport("user32.dll")] public static extern uint MapVirtualKey(uint c, uint t);' -ErrorAction SilentlyContinue
            $sc = [WM.Kb]::MapVirtualKey([uint32]$b.vk, 0); if ($sc) { return [uint32]$sc }
            continue
        }
        if ($Analog -or $wantAnalog) {
            if ($b.type -ne 'axis') { if ($Analog) { continue } else { continue } }
            $idx = Get-WMAxisObjectIndex $Prof $dev (Get-WMBindingOffset $b)
            if ($null -eq $idx) {
                $idx = @{ 0 = 0; 4 = 1; 8 = 2; 12 = 3; 16 = 4; 20 = 5; 24 = 6; 28 = 7 }[[int]$b.offset]
                if ($Warn) { & $Warn "m2emulator: $name - $($dev.productName) is not connected; axis index $idx assumes DIJOYSTATE order (re-generate with the wheel plugged in)" }
            }
            $inv = $(if ($b.Contains('direction')) { $b.direction -eq '-' } elseif ($b.Contains('invert')) { [bool]$b.invert } else { $false })
            return [uint32]([long]4278190080 -bor ($joy -shl 8) -bor $idx -bor $(if ($inv) { 0x1000 } else { 0 }))
        }
        switch ($b.type) {
            'button' { $n = [int]$b.button + 1; return [uint32](($joy -shl 8) -bor (($n -band 0xF) -shl 4) -bor (($n -shr 4) -shl 12)) }
            'pov'    { return [uint32](($joy -shl 8) -bor (0x0C + @{ Left = 0; Right = 1; Up = 2; Down = 3 }[$b.dir])) }
        }
    }
    return $null
}

function Invoke-WMGenM2($Prof, $Targets, $Manifest) {
    $tpl = Get-WMTemplate 'm2emulator'
    $rep = New-Object System.Collections.ArrayList
    $warn = { param($m) Add-WMWarning $Manifest $m }
    foreach ($t in @($Targets.m2emulator)) {
        if (-not $t) { continue }
        # EMULATOR.INI [Input]
        $ini = Join-Path $t.root 'EMULATOR.INI'
        $lines = Read-WMLines $ini
        if (-not $lines.Count -and $t.Contains('reference')) { $lines = Read-WMLines (Join-Path $t.reference 'EMULATOR.INI') }
        $out = @(); $inInput = $false
        foreach ($l in $lines) {
            if ($l -match '^\s*\[(.+?)\]') { $inInput = ($Matches[1] -eq 'Input') }
            if ($inInput) { foreach ($k in $tpl.ini.Keys) { if ($l -match ('^(' + $k + ')=([^\t;]*)(.*)$')) { $l = "$($Matches[1])=$($tpl.ini[$k])$($Matches[3])" } } }
            $out += $l
        }
        if ($out.Count) { Add-WMStaged $Manifest $ini ($out -join "`r`n") 'm2emulator' ('[Input] ' + (($tpl.ini.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')) }

        # every game we know + every game that already has a CFG file
        $cfgDir = Join-Path $t.root 'CFG'
        $roms = New-Object System.Collections.Generic.List[string]
        foreach ($g in $tpl.games.Keys) { $roms.Add($g) }
        foreach ($f in Get-ChildItem -LiteralPath $cfgDir -Filter *.input -ErrorAction SilentlyContinue) { if (-not $roms.Contains($f.BaseName)) { $roms.Add($f.BaseName) } }
        $made = @()
        foreach ($rom in $roms) {
            $live = Join-Path $cfgDir "$rom.input"
            $old = $null; if (Test-Path -LiteralPath $live) { $old = [IO.File]::ReadAllBytes($live) }
            $schemaName = $(if ($tpl.games.Contains($rom)) { $tpl.games[$rom] } else { $null })
            if (-not $schemaName -and $old) { $schemaName = @{ 18 = 'drive18'; 21 = 'rally21'; 24 = 'drive24' }[[int]($old.Length / 4) - 2] }
            if (-not $schemaName) { & $warn "m2emulator: $rom.input has an unknown layout ($($old.Length) bytes) - left unchanged"; continue }
            # only write games whose roms exist (or that already have a CFG) - no clutter for games not installed
            if (-not $old) {
                $romDirs = @($t.root) + @($lines | Where-Object { $_ -match '^\s*Dir\d+\s*=\s*(.+?)\s*$' } | ForEach-Object { $d = ($_ -replace '^\s*Dir\d+\s*=\s*', '').Trim(); if ([IO.Path]::IsPathRooted($d)) { $d } else { [IO.Path]::GetFullPath((Join-Path $t.root $d)) } })
                if ($t.Contains('roms')) { $romDirs += $t.roms }
                if (-not ($romDirs | Where-Object { Test-Path -LiteralPath (Join-Path $_ "$rom.zip") })) { continue }
            }
            $slots = @($tpl.schemas[$schemaName])
            $oldCodes = @(); if ($old) { for ($i = 0; $i + 3 -lt $old.Length; $i += 4) { $oldCodes += [BitConverter]::ToUInt32($old, $i) } }
            $seen = @{}; $codes = New-Object System.Collections.Generic.List[uint32]; $desc = @()
            for ($i = 0; $i -lt $slots.Count; $i++) {
                $slot = $slots[$i]; $first = -not $seen.ContainsKey($slot); $seen[$slot] = $true
                $spec = $(if ($tpl.slots.Contains($slot)) { $tpl.slots[$slot] } else { $null })
                $analog = $spec -and $spec.Contains('!') -and -not ($first -and @($slots | Where-Object { $_ -eq $slot }).Count -gt 1)
                $code = $null
                if ($spec) { $code = Get-WMM2Code $Prof $(if ($analog) { $spec } else { $spec -replace '!', '' }) $analog $warn }
                $src = 'profile'
                if ($null -eq $code -and $old -and $oldCodes.Count -gt $i) { $code = [uint32]$oldCodes[$i]; $src = 'kept' }
                if ($null -eq $code -and $tpl.keyDefaults.Contains($slot)) { $code = [uint32]$tpl.keyDefaults[$slot]; $src = 'key default' }
                if ($null -eq $code) { $code = [uint32]0; $src = 'unbound' }
                $codes.Add($code); $desc += ('{0}={1:X}{2}' -f $slot, $code, $(if ($src -ne 'profile') { " ($src)" } else { '' }))
            }
            $trailer = @($tpl.trailer); if ($oldCodes.Count -ge 2) { $trailer = @($oldCodes[-2], $oldCodes[-1]) }
            $ms = New-Object IO.MemoryStream
            foreach ($c in @($codes) + @($trailer)) { $bytes = [BitConverter]::GetBytes([uint32]$c); $ms.Write($bytes, 0, 4) }
            Add-WMStaged $Manifest $live $null 'm2emulator' ("$rom [$schemaName]: " + ($desc -join ', ')) -Bytes $ms.ToArray()
            $made += "$rom($schemaName)"
        }
        [void]$rep.Add([pscustomobject]@{ root = $t.root; games = ($made -join ','); note = 'generated from the profile (decoded .input format, DirectInput object-order axes)' })
    }
    return $rep
}
# ------------------------------------------------------------------ FFBPlugin (Boomslangnz) DeviceGUID
function Invoke-WMGenFFBPlugin($Prof, $Targets, $Manifest) {
    $rep = New-Object System.Collections.ArrayList
    $wheel = Get-WMPrimaryDevice $Prof
    if (-not $wheel -or -not $wheel.forceFeedback) { Add-WMWarning $Manifest 'FFBPlugin: primary device has no force feedback - skipped'; return $rep }
    $files = @()
    foreach ($r in @($Targets.ffbplugin)) {
        if (-not $r -or -not (Test-Path -LiteralPath $r.root)) { continue }
        $depth = $(if ($r.Contains('depth')) { [int]$r.depth } else { 3 })
        $files += @(Get-ChildItem -LiteralPath $r.root -Filter FFBPlugin.ini -Recurse -Depth $depth -ErrorAction SilentlyContinue)
    }
    # SDL GUID = bus/crc/vid/pid; keep the name-CRC that the existing files already use for this VID/PID.
    $vidLe = $wheel.vid.Substring(2, 2) + $wheel.vid.Substring(0, 2); $pidLe = $wheel.pid.Substring(2, 2) + $wheel.pid.Substring(0, 2)
    $pat = "^0300([0-9a-f]{4})$($vidLe.ToLower())0000$($pidLe.ToLower())0000"
    $crcs = @{}
    foreach ($f in $files) { $m = Select-String -LiteralPath $f.FullName -Pattern '^DeviceGUID=(\w+)' | Select-Object -First 1; if ($m) { $g = $m.Matches[0].Groups[1].Value.ToLower(); if ($g -match $pat) { $crcs[$Matches[1]] = 1 + [int]$crcs[$Matches[1]] } } }
    $crc = $null
    $nonZero = @($crcs.Keys | Where-Object { $_ -ne '0000' } | Sort-Object { - $crcs[$_] })
    if ($nonZero) { $crc = $nonZero[0] } elseif ($crcs.Count) { $crc = '0000' }
    if (-not $crc) { $crc = '0000'; Add-WMWarning $Manifest "FFBPlugin: no existing DeviceGUID for VID_$($wheel.vid)&PID_$($wheel.pid); using CRC 0000 - confirm with FFBPluginGUI.exe (it shows the SDL GUID)" }
    $guid = Get-WMSdlGuid $wheel $crc
    foreach ($f in $files) {
        $text = [IO.File]::ReadAllText($f.FullName)
        $new = [regex]::Replace($text, '(?m)^DeviceGUID=[^\r\n]*', "DeviceGUID=$guid")
        if ($new -ne $text) {
            Add-WMStaged $Manifest $f.FullName $new 'ffbplugin' "DeviceGUID -> $guid"
            [void]$rep.Add([pscustomobject]@{ file = $f.FullName; deviceGuid = $guid })
        }
    }
    if (-not $rep.Count) { Write-Host "  FFBPlugin: all $($files.Count) FFBPlugin.ini already use $guid" }
    return $rep
}
