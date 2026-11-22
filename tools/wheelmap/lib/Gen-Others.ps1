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

function Invoke-WMGenMame($Prof, $Targets, $Manifest) {
    $tpl = Get-WMTemplate 'mame'
    $rep = New-Object System.Collections.ArrayList
    $ref = $tpl.referenceLayout
    $wheel = Get-WMPrimaryDevice $Prof
    foreach ($t in @($Targets.mame)) {
        if (-not $t) { continue }
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
        # ctrlr file pinning JOYCODE_n to the profile devices + mame.ini 'ctrlr wheelmap'
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('<?xml version="1.0"?>')
        [void]$sb.AppendLine('<!-- generated by WheelMap: pins JOYCODE numbers to physical devices (by DirectInput instance GUID). Verify ids with: mame -v -->')
        [void]$sb.AppendLine('<mameconfig version="10">')
        [void]$sb.AppendLine('    <system name="default">')
        [void]$sb.AppendLine('        <input>')
        $i = 0
        foreach ($d in (Get-WMDiDevices $Prof)) { $i++; [void]$sb.AppendLine(("            <mapdevice device=""{0}"" controller=""JOYCODE_{1}"" /> <!-- {2} -->" -f $d.instanceGuid, $i, [Security.SecurityElement]::Escape($d.productName))) }
        [void]$sb.AppendLine('        </input>')
        [void]$sb.AppendLine('    </system>')
        [void]$sb.AppendLine('</mameconfig>')
        Add-WMStaged $Manifest (Join-Path $t.root 'ctrlr\wheelmap.cfg') $sb.ToString() 'mame' 'device pinning (mapdevice); MAME matches the device id by substring - if a device is not pinned, check the id printed by mame -v'
        $ini = Join-Path $t.root 'mame.ini'
        if (Test-Path -LiteralPath $ini) {
            $lines = Read-WMLines $ini
            $lines = $lines | ForEach-Object { if ($_ -match '^ctrlr\s') { 'ctrlr                     wheelmap' } else { $_ } }
            Add-WMStaged $Manifest $ini ($lines -join "`r`n") 'mame' "ctrlr = wheelmap"
        }
    }
    return $rep
}

# ------------------------------------------------------------------ Cemu
function Invoke-WMGenCemu($Prof, $Targets, $Manifest) {
    $tpl = Get-WMTemplate 'cemu'
    $rep = New-Object System.Collections.ArrayList
    $wheel = Get-WMPrimaryDevice $Prof
    foreach ($t in @($Targets.cemu)) {
        if (-not $t) { continue }
        $refXml = Get-ChildItem -LiteralPath $t.reference -Filter *.xml | Select-Object -First 1
        if (-not $refXml) { Add-WMWarning $Manifest "Cemu: no reference controller profile in $($t.reference)"; continue }
        $x = New-Object System.Xml.XmlDocument; $x.PreserveWhitespace = $true; $x.Load($refXml.FullName)
        $c = $x.SelectSingleNode('/emulated_controller/controller')
        $c.SelectSingleNode('api').InnerText = 'DirectInput'
        $c.SelectSingleNode('uuid').InnerText = $wheel.instanceGuid
        $c.SelectSingleNode('display_name').InnerText = $wheel.productName
        $x.SelectSingleNode('/emulated_controller/profile').InnerText = $Prof.name
        $axisOk = $true
        foreach ($k in $tpl.referenceAxes.Keys) {
            $b = Get-WMBinding $Prof $k
            if (-not $b -or $b.type -ne 'axis' -or $b.axis -ne $tpl.referenceAxes[$k] -or $b.device -ne $wheel.id) { $axisOk = $false }
        }
        if (-not $axisOk) { Add-WMWarning $Manifest 'Cemu: captured axis layout differs from the reference (wheel X, gas Y, brake Rz) - axis entries copied unchanged; re-map axes in Cemu input settings.' }
        $moved = @()
        foreach ($e in $c.SelectNodes('mappings/entry')) {
            $btn = [int]$e.button
            if ($btn -lt 32 -and $tpl.referenceButtons.Contains([string]$btn)) {
                $b = Get-WMBinding $Prof $tpl.referenceButtons[[string]$btn]
                if ($b -and $b.type -eq 'button' -and $b.device -eq $wheel.id -and [int]$b.button -ne $btn) { $e.SelectSingleNode('button').InnerText = [string]$b.button; $moved += "$btn->$($b.button)" }
            }
        }
        $live = Join-Path $t.root "controllerProfiles\$($Prof.name).xml"
        Add-WMStaged $Manifest $live $x.OuterXml 'cemu' ("uuid/display_name set to $($wheel.productName); buttons moved: $($moved -join ', ')")
        foreach ($ini in Get-ChildItem -LiteralPath $t.reference -Filter *.ini) {
            $lines = Read-WMLines (Join-Path $t.root "gameProfiles\$($ini.Name)")
            if (-not $lines.Count) { $lines = Read-WMLines $ini.FullName }
            $lines = Set-WMIniValue $lines 'Controller' 'controller1' $Prof.name
            $gid = $ini.BaseName
            $title = $(if ($tpl.games.Contains($gid)) { $tpl.games[$gid].title } else { $gid })
            Add-WMStaged $Manifest (Join-Path $t.root "gameProfiles\$($ini.Name)") ($lines -join "`r`n") 'cemu' "$title -> controller1 = $($Prof.name)"
        }
        [void]$rep.Add([pscustomobject]@{ profile = $live; axisLayoutMatchesReference = $axisOk; buttonsMoved = ($moved -join ', ') })
    }
    return $rep
}

# ------------------------------------------------------------------ m2emulator
function Invoke-WMGenM2($Prof, $Targets, $Manifest) {
    $tpl = Get-WMTemplate 'm2emulator'
    $rep = New-Object System.Collections.ArrayList
    $wheel = Get-WMPrimaryDevice $Prof
    foreach ($t in @($Targets.m2emulator)) {
        if (-not $t) { continue }
        $ini = Join-Path $t.root 'EMULATOR.INI'
        $lines = Read-WMLines $ini
        if (-not $lines.Count) { $lines = Read-WMLines (Join-Path $t.reference 'EMULATOR.INI') }
        $out = @(); $inInput = $false
        foreach ($l in $lines) {
            if ($l -match '^\s*\[(.+?)\]') { $inInput = ($Matches[1] -eq 'Input') }
            if ($inInput) { foreach ($k in $tpl.ini.Keys) { if ($l -match ('^(' + $k + ')=([^\t;]*)(.*)$')) { $l = "$($Matches[1])=$($tpl.ini[$k])$($Matches[3])" } } }
            $out += $l
        }
        Add-WMStaged $Manifest $ini ($out -join "`r`n") 'm2emulator' ('[Input] ' + (($tpl.ini.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '))
        $note = 'reference copy (binary, not re-mapped)'
        if ($wheel.enumIndex -ne 1) { $note += "; WARNING wheel is DirectInput #$($wheel.enumIndex), reference assumes #1 - re-bind in the emulator"; Add-WMWarning $Manifest "m2emulator: wheel is DirectInput device #$($wheel.enumIndex); reference .input files assume #1" }
        $games = @()
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $t.reference 'CFG') -Filter *.input -ErrorAction SilentlyContinue) {
            Add-WMStaged $Manifest (Join-Path $t.root "CFG\$($f.Name)") $null 'm2emulator' "$($f.BaseName): $note" -Bytes ([IO.File]::ReadAllBytes($f.FullName))
            $games += $f.BaseName
        }
        [void]$rep.Add([pscustomobject]@{ root = $t.root; games = ($games -join ','); note = $note })
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
