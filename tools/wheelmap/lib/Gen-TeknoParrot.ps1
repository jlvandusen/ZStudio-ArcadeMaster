# Gen-TeknoParrot.ps1 - TeknoParrot UserProfile generator + profile seeding from existing UserProfiles
#
# TeknoParrot DirectInput binding schema (learned from v1.0.0.1919 / v894 UserProfiles on this machine):
#   <JoystickButtons><JoystickButtons>
#     <ButtonName>Gas</ButtonName>
#     <DirectInputButton>
#       <Button>4</Button>            SharpDX JoystickOffset: X0 Y4 Z8 Rx12 Ry16 Rz20 Sliders0 24 Sliders1 28
#                                      POV0..3 32..44, Buttons0..127 48..175 (keyboard: key code, keyboard GUID)
#       <IsAxis>true</IsAxis>
#       <IsAxisMinus>true</IsAxisMinus> the half/direction captured; pedals that rest high and go low = true
#       <IsFullAxis>false</IsFullAxis>
#       <PovDirection>0</PovDirection>  0 / 9000 / 18000 / 27000 for hat bindings
#       <IsReverseAxis>false</IsReverseAxis>
#       <JoystickGuid>instance guid</JoystickGuid>
#     </DirectInputButton>
#     <XInputButton>...</XInputButton>  (left untouched)
#     <InputMapping>Analog2</InputMapping><AnalogType>Gas</AnalogType>
#     <BindNameDi>Driving Y -</BindNameDi>  "<SharpDX DeviceType> <JoystickOffset>[ +|-| Up|Down|Left|Right]"
#     <BindNameXi>...</BindNameXi><BindName>Driving Y -</BindName>
#     <Hide...>
#   </JoystickButtons></JoystickButtons>

$script:TPElementOrder = @('ButtonName', 'DirectInputButton', 'XInputButton', 'RawInputButton', 'InputMapping', 'AnalogType', 'BindNameDi', 'BindNameXi', 'BindNameRi', 'BindName')

function Resolve-WMTPControl([string]$GameId, [string]$ButtonName, [string]$AnalogType, $Tpl) {
    if ($Tpl.games.Contains($GameId)) {
        $g = $Tpl.games[$GameId]
        if ($g.map -and $g.map.Contains($ButtonName)) { return @{ control = $g.map[$ButtonName]; source = 'game' } }
    }
    foreach ($r in $Tpl.rules) {
        if ($r.Contains('analogType') -and $r.analogType -ne $AnalogType) { continue }
        $m = [regex]::Match($ButtonName, $r.match, 'IgnoreCase')
        if ($m.Success) {
            $c = $r.control
            if ($c -and $c.Contains('$')) { for ($gi = $m.Groups.Count - 1; $gi -ge 1; $gi--) { $c = $c.Replace('$' + $gi, $m.Groups[$gi].Value) } }
            return @{ control = $c; source = 'rule' }
        }
    }
    return @{ control = $null; source = 'unmatched' }
}

function Get-WMLaunchBoxTPIds($Targets) {
    $ids = @()
    if (-not $Targets.Contains('launchbox')) { return $ids }
    foreach ($x in $Targets.launchbox.platformXml) {
        if (-not (Test-Path -LiteralPath $x)) { continue }
        [xml]$doc = [IO.File]::ReadAllText($x)
        foreach ($g in $doc.LaunchBox.Game) {
            if ($g.ApplicationPath -match 'TeknoParrot\\UserProfiles\\([^\\]+)\.xml$') { $ids += $Matches[1] }
        }
    }
    return @($ids | Select-Object -Unique)
}

function Set-WMXmlChild([System.Xml.XmlElement]$Parent, [string]$Name, [string]$Value) {
    $n = $Parent.SelectSingleNode($Name)
    if (-not $n) {
        $n = $Parent.OwnerDocument.CreateElement($Name)
        # keep TeknoParrot's element order (XmlSerializer tolerates any order, but diffs stay clean)
        $idx = [array]::IndexOf($script:TPElementOrder, $Name)
        $after = $null
        if ($idx -gt 0) { for ($j = $idx - 1; $j -ge 0 -and -not $after; $j--) { $after = $Parent.SelectSingleNode($script:TPElementOrder[$j]) } }
        if ($after) { [void]$Parent.InsertAfter($n, $after) } else { [void]$Parent.AppendChild($n) }
    }
    $n.InnerText = $Value
    return $n
}

function Get-WMTPBindName($dev, $b, [string]$control, [bool]$minus) {
    $type = $(if ($dev.diType) { $dev.diType } else { 'Joystick' })
    switch ($b.type) {
        'axis'   { return ('{0} {1} {2}' -f $type, $b.axis, $(if ($minus) { '-' } else { '+' })) }
        'button' { return ('{0} Buttons{1}' -f $type, $b.button) }
        'pov'    { return ('{0} PointOfViewControllers{1} {2}' -f $type, $b.pov, $b.dir) }
    }
    return $null
}

function Set-WMTPBinding([System.Xml.XmlElement]$Jb, $Prof, $b, [string]$control) {
    if (@('axis', 'button', 'pov') -notcontains $b.type) { return $false }
    $dev = Get-WMDevice $Prof $b.device
    if (-not $dev) { return $false }
    $isAxis = ($b.type -eq 'axis')
    $minus = $false; $reverse = $false; $full = $false
    if ($isAxis) {
        if ($b.Contains('direction')) {                                            # pedals / throttle / handbrake
            $minus = ($b.direction -eq '-')
            if (Test-WMFullTravel $b) { $full = $true; $reverse = $minus }        # rest at one end: whole range, reversed if it falls when pressed
        }
        elseif ($b.Contains('invert')) { $reverse = [bool]$b.invert }             # wheel / stick: full axis, optional reverse
    }
    $pov = 0
    if ($b.type -eq 'pov') { $pov = $script:PovDir[$b.dir] }
    $doc = $Jb.OwnerDocument
    $old = $Jb.SelectSingleNode('DirectInputButton')
    $di = $doc.CreateElement('DirectInputButton')
    foreach ($pair in @(
            @('Button', [string](Get-WMBindingOffset $b)),
            @('IsAxis', $isAxis.ToString().ToLower()),
            @('IsAxisMinus', $minus.ToString().ToLower()),
            @('IsFullAxis', $full.ToString().ToLower()),
            @('PovDirection', [string]$pov),
            @('IsReverseAxis', $reverse.ToString().ToLower()),
            @('JoystickGuid', $dev.instanceGuid))) {
        $e = $doc.CreateElement($pair[0]); $e.InnerText = $pair[1]; [void]$di.AppendChild($e)
    }
    if ($old) { [void]$Jb.ReplaceChild($di, $old) }
    else {
        $bn = $Jb.SelectSingleNode('ButtonName')
        if ($bn) { [void]$Jb.InsertAfter($di, $bn) } else { [void]$Jb.PrependChild($di) }
    }
    $name = Get-WMTPBindName $dev $b $control $minus
    [void](Set-WMXmlChild $Jb 'BindNameDi' $name)
    [void](Set-WMXmlChild $Jb 'BindName' $name)
    return $true
}

function Invoke-WMGenTeknoParrot($Prof, $Targets, $Manifest, [string[]]$Games) {
    $tpl = Get-WMTemplate 'teknoparrot'
    if ($Prof.cabinetType -eq 'lightgun') {
        # light-gun cabinets: gun rules first, racing rules as fallback (Test/Service/Coin...), gun game list
        $lg = Get-WMTemplate 'lightgun'
        $tpl.rules = @($lg.teknoparrot.rules) + @($tpl.rules)
        $g2 = [ordered]@{}
        foreach ($k in $lg.teknoparrot.games.Keys) { $g2[$k] = [ordered]@{ genre = 'Lightgun'; notes = $lg.teknoparrot.games[$k]; map = [ordered]@{} } }
        $tpl.games = $g2
    }
    $lbIds = Get-WMLaunchBoxTPIds $Targets
    $report = New-Object System.Collections.ArrayList
    foreach ($t in $Targets.teknoparrot) {
        $root = $t.root
        if (-not (Test-Path -LiteralPath $root)) { Add-WMWarning $Manifest "TeknoParrot root not found: $root"; continue }
        $userIds = @(Get-ChildItem -LiteralPath (Join-Path $root 'UserProfiles') -Filter *.xml -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
        foreach ($id in $tpl.games.Keys) {
            if ($Games -and $Games -notcontains $id) { continue }
            $up = Join-Path $root "UserProfiles\$id.xml"
            $gp = Join-Path $root "GameProfiles\$id.xml"
            $hasUser = $userIds -contains $id
            $inLb = $lbIds -contains $id
            if (-not $hasUser -and -not ($inLb -and (Test-Path -LiteralPath $gp))) { continue }
            if (-not $hasUser -and $t.Contains('onlyExisting') -and $t.onlyExisting) { continue }
            $base = $(if ($hasUser) { $up } else { $gp })
            $xml = New-Object System.Xml.XmlDocument
            $xml.PreserveWhitespace = $false
            $xml.Load($base)
            $bound = @(); $kept = @(); $missing = @(); $kbFix = 0
            foreach ($jb in $xml.SelectNodes('/GameProfile/JoystickButtons/JoystickButtons')) {
                $bnNode = $jb.SelectSingleNode('ButtonName'); if (-not $bnNode) { continue }
                $bn = $bnNode.InnerText
                $at = $(if ($jb.SelectSingleNode('AnalogType')) { $jb.SelectSingleNode('AnalogType').InnerText } else { 'None' })
                $hideDi = $jb.SelectSingleNode('HideWithDirectInput')
                $bindDi = $jb.SelectSingleNode('BindNameDi')
                # fix keyboard binds that an old GUID-replace script pointed at the wheel
                if ($bindDi -and $bindDi.InnerText -like 'Keyboard*') {
                    $g = $jb.SelectSingleNode('DirectInputButton/JoystickGuid')
                    if ($g -and $g.InnerText -ne $script:SysKeyboardGuid) { $g.InnerText = $script:SysKeyboardGuid; $kbFix++ }
                }
                if ($hideDi -and $hideDi.InnerText -eq 'true') { continue }
                $r = Resolve-WMTPControl $id $bn $at $tpl
                if (-not $r.control) { if ($bindDi) { $kept += $bn }; continue }
                $b = Get-WMBinding $Prof $r.control
                if (-not $b) { $missing += "$bn->$($r.control)"; continue }
                if (Set-WMTPBinding $jb $Prof $b $r.control) { $bound += "$bn=$($b._control)" } else { $missing += "$bn->$($r.control)" }
            }
            # Input API -> DirectInput (the profile is a DirectInput profile)
            foreach ($fi in $xml.SelectNodes('/GameProfile/ConfigValues/FieldInformation')) {
                if ($fi.FieldName -eq 'Input API' -and $fi.FieldValue -ne 'DirectInput') { $fi.FieldValue = 'DirectInput' }
            }
            $settings = New-Object System.Xml.XmlWriterSettings
            $settings.Indent = $true; $settings.IndentChars = '  '; $settings.NewLineChars = "`r`n"; $settings.Encoding = New-Object System.Text.UTF8Encoding($true)
            $ms = New-Object IO.MemoryStream
            $w = [System.Xml.XmlWriter]::Create($ms, $settings)
            $xml.Save($w); $w.Close()
            $bytes = $ms.ToArray()
            $live = $up
            $note = "bound: $($bound.Count); kept existing: $($kept -join ', ')"
            if ($missing) { $note += "; NOT in device profile: $($missing -join ', ')" }
            if ($kbFix) { $note += "; keyboard binds re-pointed to SysKeyboard GUID: $kbFix" }
            if (-not $hasUser) { $note += '; NEW UserProfile created from GameProfile - set the game executable path in TeknoParrotUI' }
            Add-WMStaged $Manifest $live $null 'teknoparrot' $note -Bytes $bytes
            $meta = $tpl.games[$id]
            [void]$report.Add([pscustomobject]@{ install = $t.name; game = $id; genre = $meta.genre; bound = $bound.Count; missing = ($missing -join '; '); keyboardGuidFixes = $kbFix; newProfile = (-not $hasUser) })
        }
    }
    return $report
}

function Get-WMTPResolvedTable([string]$Root) {
    # For docs/review: every template game -> every ButtonName -> logical control (from GameProfile, else UserProfile)
    $tpl = Get-WMTemplate 'teknoparrot'
    $rows = @()
    foreach ($id in $tpl.games.Keys) {
        $src = Join-Path $Root "GameProfiles\$id.xml"
        if (-not (Test-Path -LiteralPath $src)) { $src = Join-Path $Root "UserProfiles\$id.xml" }
        if (-not (Test-Path -LiteralPath $src)) { $rows += [pscustomobject]@{ game = $id; button = '(no GameProfile/UserProfile in this install)'; mapping = ''; analog = ''; control = ''; source = '' }; continue }
        [xml]$x = [IO.File]::ReadAllText($src)
        foreach ($jb in $x.GameProfile.JoystickButtons.JoystickButtons) {
            if ($jb.HideWithDirectInput -eq 'true') { continue }
            $r = Resolve-WMTPControl $id $jb.ButtonName $jb.AnalogType $tpl
            $rows += [pscustomobject]@{ game = $id; title = $x.GameProfile.GameNameInternal; button = $jb.ButtonName; mapping = $jb.InputMapping; analog = $jb.AnalogType; control = $r.control; source = $r.source }
        }
    }
    return $rows
}

function New-WMSeedProfile([string]$Name, [string]$TPRoot, [string]$MameReference) {
    <# Non-interactive example profile: devices from DirectInput, axes from HID object names,
       buttons/hat from the most common existing TeknoParrot bindings (+ START1/COIN1 of the
       previous owner's MAME set). Marked confirmed=false. #>
    $det = Get-WMDevices
    $prof = [ordered]@{
        schema = 'wheelmap.profile/1'; name = $Name; cabinetType = 'racing'; confirmed = $false
        source = 'WheelMap.ps1 -Seed (non-interactive: DirectInput object names + existing TeknoParrot bindings). RUN -Capture TO CONFIRM.'
        created = (Get-Date).ToString('s'); machine = $env:COMPUTERNAME
        devices = New-Object System.Collections.ArrayList; controls = [ordered]@{}; notes = New-Object System.Collections.ArrayList
    }
    $wheel = $null
    # read the idle state so pedal rest values are observed, not assumed
    $idle = @{}
    foreach ($d in $det.directInput) {
        try {
            $dv = New-Object WheelMap.DIDevice ([guid]$d.instanceGuid)
            [void]$dv.Read(); Start-Sleep -Milliseconds 150
            $sum = New-Object double[] 8
            for ($n = 0; $n -lt 10; $n++) { $s = $dv.Read(); for ($a = 0; $a -lt 8; $a++) { $sum[$a] += $s.Axes[$a] }; Start-Sleep -Milliseconds 20 }
            $idle[$d.instanceGuid] = @($sum | ForEach-Object { [int]($_ / 10) })
            $dv.Dispose()
        } catch { }
    }
    foreach ($d in $det.directInput) {
        $id = $d.roleGuess
        if (@($prof.devices | Where-Object { $_.id -eq $id }).Count) { $id = "$id$($d.enumIndex)" }
        $dev = [ordered]@{ id = $id; productName = $d.productName; instanceName = $d.instanceName; instanceGuid = $d.instanceGuid; productGuid = $d.productGuid
                           vid = $d.vid; pid = $d.pid; diType = $d.diType; enumIndex = $d.enumIndex; mameIndexGuess = $d.mameIndexGuess; forceFeedback = $d.forceFeedback }
        $dev['sdlGuid'] = Get-WMSdlGuid ([pscustomobject]$dev) $null
        [void]$prof.devices.Add($dev)
        if ($id -eq 'wheel' -and -not $wheel) { $wheel = $dev }
        foreach ($o in $d.objects | Where-Object { $_.kind -eq 'Axis' }) {
            $ctl = $null
            if ($o.name -match 'wheel|steer') { $ctl = 'Steering' }
            elseif ($o.name -match 'accel|gas|throttle') { $ctl = 'Gas' }
            elseif ($o.name -match 'brake' -and $id -ne 'handbrake') { $ctl = 'Brake' }
            elseif ($o.name -match 'clutch') { $ctl = 'Clutch' }
            elseif ($id -eq 'wheel' -and $d.vid -eq '046D' -and $o.offsetName -eq 'Sliders0') { $ctl = 'Clutch' }   # Logitech G29/G920: clutch reports as 'Y Axis' on slider 0
            elseif ($id -eq 'handbrake') { $ctl = 'Handbrake' }
            if (-not $ctl -or $prof.controls.Contains($ctl)) { continue }
            $e = [ordered]@{ device = $id; type = 'axis'; axis = $o.offsetName; offset = $o.offset }
            $now = $(if ($idle.ContainsKey($d.instanceGuid)) { $idle[$d.instanceGuid][$o.offset / 4] } else { $null })
            if ($ctl -eq 'Steering') { $e.invert = $false; $e.center = $(if ($null -ne $now) { $now } else { 32767 }) }
            elseif ($ctl -eq 'Handbrake') { $e.direction = '+'; $e.rest = $(if ($null -ne $now) { $now } else { 0 }); $e.pressed = 65535 }
            else { $e.direction = '-'; $e.rest = $(if ($null -ne $now) { $now } else { 65535 }); $e.pressed = 0 }
            $e.source = "seed: DirectInput object name '$($o.name)'" + $(if ($null -ne $now -and $ctl -ne 'Steering') { "; rest = idle reading $now (direction assumed)" } else { '' })
            $prof.controls[$ctl] = $e
        }
    }
    if ($wheel -and $TPRoot -and (Test-Path -LiteralPath (Join-Path $TPRoot 'UserProfiles'))) {
        $tpl = Get-WMTemplate 'teknoparrot'
        $tally = @{}
        $axisMinus = @{}
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $TPRoot 'UserProfiles') -Filter *.xml) {
            [xml]$x = [IO.File]::ReadAllText($f.FullName)
            foreach ($jb in $x.GameProfile.JoystickButtons.JoystickButtons) {
                $dib = $jb.DirectInputButton
                if (-not $dib -or $dib.JoystickGuid -ne $wheel.instanceGuid -or ($jb.BindNameDi -like 'Keyboard*') -or ($jb.BindNameDi -like 'Supplemental*')) { continue }
                $r = Resolve-WMTPControl $f.BaseName $jb.ButtonName $jb.AnalogType $tpl
                if (-not $r.control) { continue }
                $c = ($r.control -split '\|')[0]
                if ($dib.IsAxis -eq 'true') {
                    if (@('Gas', 'Brake') -contains $c) { $k = "$c/$($dib.IsAxisMinus)"; $axisMinus[$k] = 1 + [int]$axisMinus[$k] }
                    continue
                }
                $k = "$c|$($dib.Button)|$($dib.PovDirection)"
                $tally[$k] = 1 + [int]$tally[$k]
            }
        }
        # Extra evidence: the previous owner's MAME G29 set (START1/COIN1 are consistent across ~20 games).
        if ($MameReference -and (Test-Path -LiteralPath $MameReference)) {
            foreach ($cf in Get-ChildItem -LiteralPath $MameReference -Filter *.cfg) {
                $txt = [IO.File]::ReadAllText($cf.FullName)
                foreach ($pair in @(@('START1', 'Start'), @('COIN1', 'Coin'))) {
                    $mm = [regex]::Match($txt, 'type="' + $pair[0] + '"[^>]*>\s*<newseq type="standard">\s*JOYCODE_1_BUTTON(\d+)\s*<')
                    if ($mm.Success) { $k = "$($pair[1])|$(47 + [int]$mm.Groups[1].Value)|0"; $tally[$k] = 1 + [int]$tally[$k] }
                }
            }
        }
        # Greedy one-to-one assignment: strongest (control, physical input) pairs first, each physical
        # input used once. The existing profiles are not consistent with each other (e.g. Buttons11 is
        # Coin in some games and View Change in others), so conflicts are recorded in the notes.
        $pairs = foreach ($k in $tally.Keys) { $p = $k -split '\|'; [pscustomobject]@{ c = $p[0]; ofs = [int]$p[1]; pov = [int]$p[2]; n = $tally[$k] } }
        $pairs = @($pairs | Sort-Object -Property @{ Expression = 'n'; Descending = $true }, @{ Expression = 'c'; Descending = $false })
        $used = @{}; $conflicts = @()
        foreach ($v in $pairs) {
            $sig = "$($v.ofs)/$($v.pov)"
            if ($prof.controls.Contains($v.c)) { if ($prof.controls[$v.c].source -like 'seed: most common*' -and $v.n -gt 1) { $conflicts += "$($v.c) also bound to offset $($v.ofs)$(if($v.ofs -lt 48){" pov $($v.pov)"}) in $($v.n) game(s)" }; continue }
            if ($used.ContainsKey($sig)) { if ($v.n -gt 1) { $conflicts += "offset $($v.ofs)$(if($v.ofs -lt 48){" pov $($v.pov)"}) is $($used[$sig]) but also $($v.c) in $($v.n) game(s)" }; continue }
            if ($v.ofs -ge 48) { $e = [ordered]@{ device = $wheel.id; type = 'button'; button = $v.ofs - 48 } }
            elseif ($v.ofs -ge 32) { $e = [ordered]@{ device = $wheel.id; type = 'pov'; pov = ($v.ofs - 32) / 4; dir = @{ 0 = 'Up'; 9000 = 'Right'; 18000 = 'Down'; 27000 = 'Left' }[$v.pov] } }
            else { continue }
            $e.source = "seed: most common existing binding (TeknoParrot UserProfiles + MAME reference; $($v.n) game(s))"
            $used[$sig] = $v.c
            $prof.controls[$v.c] = $e
        }
        if ($conflicts) { [void]$prof.notes.Add('Existing TeknoParrot bindings disagree: ' + ($conflicts -join '; ')) }
        foreach ($c in 'Gas', 'Brake') {
            if ($prof.controls.Contains($c)) {
                $t = [int]$axisMinus["$c/true"]; $f2 = [int]$axisMinus["$c/false"]
                $prof.controls[$c].source += "; TeknoParrot IsAxisMinus true:$t false:$f2"
            }
        }
    }
    [void]$prof.notes.Add('UNCONFIRMED: generated without anyone touching the controls. Pedal rest values are idle readings (32768 = the wheel may not have reported yet) and press directions are assumed. Run: .\WheelMap.ps1 -Capture -Name ' + $Name)
    return $prof
}
