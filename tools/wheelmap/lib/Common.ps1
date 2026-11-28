# Common.ps1 - shared helpers for WheelMap (PowerShell 5.1)
Set-StrictMode -Version 1.0

$script:WMLib = $PSScriptRoot
$script:WMRoot = Split-Path -Parent $PSScriptRoot
$script:SysKeyboardGuid = '6f1d2b61-d5a0-11cf-bfc7-444553540000'

function Import-WMInput {
    if (-not ('WheelMap.DI' -as [type])) {
        . (Join-Path (Split-Path $script:WMRoot) 'lib\AmTypeCache.ps1')   # tools\lib - compiled once, cached DLL after
        Add-AmCachedType -Source ([IO.File]::ReadAllText((Join-Path $script:WMLib 'WheelMapInput.cs'))) -ProbeType 'WheelMap.DI'
    }
}

function ConvertTo-WMHashtable {
    # PS 5.1 ConvertFrom-Json has no -AsHashtable; convert recursively, preserving key order.
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-WMHashtable $p.Value }
        return $h
    }
    if ($InputObject -is [System.Collections.IList] -and -not ($InputObject -is [string])) {
        $a = New-Object System.Collections.ArrayList
        foreach ($i in $InputObject) { [void]$a.Add((ConvertTo-WMHashtable $i)) }
        return ,$a.ToArray()
    }
    return $InputObject
}

function Read-WMJson([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "JSON file not found: $Path" }
    $raw = [IO.File]::ReadAllText($Path)
    return ConvertTo-WMHashtable ($raw | ConvertFrom-Json)
}

function Write-WMJson($Object, [string]$Path) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json = $Object | ConvertTo-Json -Depth 30
    # PS 5.1 escapes < > ' & as \u003c etc. - harmless but ugly; undo the common ones.
    $json = $json -replace '\\u0027', "'" -replace '\\u003c', '<' -replace '\\u003e', '>' -replace '\\u0026', '&'
    [IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-WMText([string]$Path, [string]$Text, [switch]$Bom) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding([bool]$Bom)))
}

function Get-WMTemplate([string]$Name) {
    return Read-WMJson (Join-Path $script:WMRoot "templates\$Name.json")
}

function Get-WMTargets([string]$Path) {
    if (-not $Path) {
        $cand = Join-Path $script:WMRoot ("targets\{0}.json" -f $env:COMPUTERNAME)
        if (Test-Path -LiteralPath $cand) { $Path = $cand } else { $Path = Join-Path $script:WMRoot 'targets\default.json' }
    }
    $t = Read-WMJson $Path
    $t['_path'] = $Path
    return $t
}

# ------------------------------------------------------------------ devices
function Get-WMRegistryGuids {
    # DirectInput keeps per-VID/PID instance GUIDs here; used to cross-check enumeration.
    $k = 'HKCU:\System\CurrentControlSet\Control\MediaProperties\PrivateProperties\DirectInput'
    $out = @()
    if (-not (Test-Path $k)) { return $out }
    foreach ($c in (Get-ChildItem $k -Recurse -ErrorAction SilentlyContinue)) {
        try {
            $p = Get-ItemProperty -LiteralPath $c.PSPath -ErrorAction Stop
            if ($p.PSObject.Properties['GUID'] -and $p.GUID -is [byte[]] -and $p.GUID.Length -eq 16) {
                $rel = $c.Name -replace '^.*\\DirectInput\\', ''
                $out += [pscustomobject]@{ Key = $rel; Guid = ([guid]$p.GUID).ToString() }
            }
        } catch { }
    }
    return $out
}

function Get-WMRoleGuess($d) {
    $n = "$($d.ProductName) $($d.InstanceName)".ToLower()
    if ($n -match 'sinden|aimtrak|gun4ir|lightgun|light gun|guncon') { return 'gun' }
    if ($n -match 'handbrake|hand brake|e-brake') { return 'handbrake' }
    if ($n -match 'shifter') { return 'shifter' }
    if ($n -match 'pedal') { return 'pedals' }
    # flight controls by name: a HOTAS's throttle is often its own USB device, and PlayStation HOTAS sets can report as
    # a gamepad or plain joystick - the name is the only reliable clue
    if ($n -match 'throttle|twcs|quadrant') { return 'throttle' }
    if ($n -match 'hotas|flight ?stick|flight control|t\.?flight|t\.?16000|warthog|x-?5[256]|extreme 3d|yoke|flight') { return 'stick' }
    switch ($d.TypeName) {
        'Driving'      { return 'wheel' }
        'Flight'       { return 'stick' }
        'Gamepad'      { return 'pad' }
        'Supplemental' { return 'aux' }
        default        { return 'controller' }
    }
}

# Hand-held controllers by name: tools\pads\pads.json (PS3, PS4, N64, SNES-style, Genesis-style ... - James, 2026-11-27).
# Found by USB id first, else by the longest piece of the name Windows reports. $null = not a pad we know.
$script:WMPads = $null; $script:WMPs3Usb = $null
function Get-WMPad($d, [string]$Role) {
    if ($Role -notin 'pad', 'controller', 'aux') { return $null }      # wheels, sticks, guns are named elsewhere
    if ($null -eq $script:WMPads) {
        $pf = Join-Path (Split-Path $script:WMRoot) 'pads\pads.json'
        $script:WMPads = $(if (Test-Path -LiteralPath $pf) { Get-Content -LiteralPath $pf -Raw | ConvertFrom-Json } else { $false })
    }
    if (-not $script:WMPads) { return $null }
    $fam = $null; $model = $null
    $usb = ("{0}:{1}" -f $d.Vid, $d.Pid).ToUpper()
    $hit = @($script:WMPads.pads | Where-Object { $_.usb -eq $usb }) | Select-Object -First 1
    if ($hit) { $fam = $hit.family; $model = $hit.model }
    $n = "$($d.ProductName) $($d.InstanceName)"; $best = ''
    foreach ($r in $script:WMPads.names) { foreach ($m in $r.match) { if ($m.Length -gt $best.Length -and $n.IndexOf($m, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        # a pad's own name beats the USB id only when the id is unknown or says "Xbox" (a pad in X-input mode)
        if (-not $fam -or $fam -eq 'xbox') { $best = $m; $fam = $r.family; $model = $d.ProductName } } } }
    # A PS3 pad on Windows goes through a helper driver (ScpToolkit, DsHidMini in X-input mode) that shows it as an
    # Xbox 360 pad; the real pad (054C:0268) is still on the USB list. Seen on the pedestal, 2026-11-27.
    if ($fam -eq 'xbox' -and $best -eq '') {
        if ($null -eq $script:WMPs3Usb) { $script:WMPs3Usb = [bool]@(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_054C&PID_0268' }).Count }
        if ($script:WMPs3Usb) { $fam = 'ps3'; $model = 'PS3 controller (shown to Windows as an Xbox 360 pad by its driver)' }
    }
    if (-not $fam) { return $null }
    $F = $script:WMPads.families.$fam
    return [pscustomobject]@{ family = $fam; model = $model; label = $F.label; buttons = @($F.buttons); sticks = $F.sticks; like = @($F.like) }
}

function Get-WMDevices {
    <# Enumerates DirectInput game controllers (+objects), XInput slots and registry GUIDs. #>
    Import-WMInput
    $di = [WheelMap.DI]::Enumerate($true)
    $reg = Get-WMRegistryGuids
    $xi = @(0..3 | ForEach-Object { [WheelMap.XI]::Read($_) })
    $xiCount = @($xi | Where-Object { $_.Connected }).Count
    $devices = @()
    $nonXiPos = 0
    foreach ($d in $di) {
        $isXi = ($d.ProductName -match 'XBOX|XInput|Xbox 360|Xbox One') -or ($d.Vid -eq '045E')
        if (-not $isXi) { $nonXiPos++ }
        $regHit = @($reg | Where-Object { $_.Guid -eq $d.InstanceGuid.ToString() })
        $devices += [pscustomobject][ordered]@{
            enumIndex      = $d.EnumIndex
            productName    = $d.ProductName
            instanceName   = $d.InstanceName
            instanceGuid   = $d.InstanceGuid.ToString()
            productGuid    = $d.ProductGuid.ToString()
            vid            = $d.Vid
            pid            = $d.Pid
            diType         = $d.TypeName
            roleGuess      = (Get-WMRoleGuess $d)
            pad            = (Get-WMPad $d (Get-WMRoleGuess $d))
            forceFeedback  = $d.ForceFeedback
            axisCount      = $d.AxisCount
            buttonCount    = $d.ButtonCount
            povCount       = $d.PovCount
            # MAME winhybrid (default on Windows) numbers XInput pads first, then DirectInput-only devices.
            mameIndexGuess = $(if ($isXi) { $null } else { $xiCount + $nonXiPos })
            registryKey    = $(if ($regHit) { $regHit[0].Key } else { $null })
            objects        = @($d.Objects | Where-Object { $_.Kind -ne 'Button' } | ForEach-Object {
                                [pscustomobject][ordered]@{ kind = $_.Kind; offset = $_.Offset; offsetName = $_.OffsetName; name = $_.Name } })
            error          = $d.Error
        }
    }
    $raw = @()
    try {
        foreach ($s in [WheelMap.RawInput]::Devices()) {
            $p = $s -split '\|', 2
            if ($p[0] -ne 'mouse') { continue }
            $vp = $(if ($p[1] -match 'VID_([0-9A-F]{4}).PID_([0-9A-F]{4})') { "VID_$($Matches[1])&PID_$($Matches[2])" } else { $null })
            $raw += [pscustomobject]@{ type = $p[0]; path = $p[1]; vidPid = $vp
                                       gunGuess = [bool]($p[1] -match 'VID_16C0|VID_D209.PID_16|VID_2341|VID_1B4F|Sinden|AimTrak|Gun4IR') }
        }
    } catch { }
    return [pscustomobject]@{
        rawInputMice = $raw
        directInput = $devices
        xinput      = @($xi | ForEach-Object { [pscustomobject]@{ index = $_.Index; connected = $_.Connected } })
        registry    = $reg
    }
}

# ------------------------------------------------------------------ profile helpers
$script:AxisByOffset = @{ 0 = 'X'; 4 = 'Y'; 8 = 'Z'; 12 = 'RotationX'; 16 = 'RotationY'; 20 = 'RotationZ'; 24 = 'Sliders0'; 28 = 'Sliders1' }
$script:PovDir = @{ 'Up' = 0; 'Right' = 9000; 'Down' = 18000; 'Left' = 27000 }

function Get-WMBinding {
    <# Returns the profile binding for a logical control. Supports 'A|B' fallbacks. #>
    param($Prof, [string]$Control)
    if (-not $Control) { return $null }
    foreach ($c in ($Control -split '\|')) {
        if ($Prof.controls.Contains($c)) {
            $b = $Prof.controls[$c]
            if ($b -and $b['type'] -and $b['type'] -ne 'none') { $b['_control'] = $c; return $b }
        }
    }
    return $null
}

function Get-WMDevice($Prof, [string]$Id) {
    foreach ($d in $Prof.devices) { if ($d.id -eq $Id) { return $d } }
    return $null
}

function Test-WMFullTravel($b) {
    # Pedal-type axis whose travel spans (almost) the whole range, i.e. rest at one end (G29 pedals
    # usually rest at 65535 and press to 0). Half-travel axes rest near the centre (32767).
    if (-not $b -or $b.type -ne 'axis' -or -not $b.Contains('rest') -or -not $b.Contains('pressed')) { return $false }
    return ([Math]::Abs([double]$b.pressed - [double]$b.rest) -gt 45000)
}

function Get-WMBindingOffset($b) {
    switch ($b.type) {
        'axis'   { return [int]$b.offset }
        'button' { return 48 + [int]$b.button }
        'pov'    { return 32 + 4 * [int]$b.pov }
        default  { return $null }
    }
}

function Get-WMSdlGuid($dev, [string]$crcHex) {
    # SDL2 joystick GUID as used by FFBPlugin.ini DeviceGUID: bus(0003 LE) crc16(LE) vid(LE) 0000 pid(LE) 0000 version 0000 0000
    if (-not $dev.vid -or -not $dev.pid) { return $null }
    if (-not $crcHex) { $crcHex = '0000' }
    $le = { param($h) $h = $h.PadLeft(4, '0').ToLower(); $h.Substring(2, 2) + $h.Substring(0, 2) }
    return ('0300' + $crcHex.ToLower() + (& $le $dev.vid) + '0000' + (& $le $dev.pid) + '0000' + '0000' + '0000')
}

function New-WMManifest([string]$StageRoot, [string]$ProfileName) {
    return [ordered]@{
        schema    = 'wheelmap.manifest/1'
        profile   = $ProfileName
        generated = (Get-Date).ToString('s')
        machine   = $env:COMPUTERNAME
        stageRoot = $StageRoot
        files     = New-Object System.Collections.ArrayList
        warnings  = New-Object System.Collections.ArrayList
    }
}

function Get-WMStagePath([string]$StageRoot, [string]$LivePath) {
    # Mirror the live absolute path under the stage root: E:\x\y.xml -> <stage>\E\x\y.xml
    $full = [IO.Path]::GetFullPath($LivePath)
    $drive = $full.Substring(0, 1)
    return Join-Path $StageRoot ($drive + $full.Substring(2))
}

function Add-WMStaged($Manifest, [string]$LivePath, [string]$Content, [string]$Generator, [string]$Note, [switch]$Bom, [byte[]]$Bytes) {
    $stage = Get-WMStagePath $Manifest.stageRoot $LivePath
    if ($Bytes) {
        $dir = Split-Path -Parent $stage
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        [IO.File]::WriteAllBytes($stage, $Bytes)
    } else {
        Write-WMText -Path $stage -Text $Content -Bom:$Bom
    }
    $liveExists = Test-Path -LiteralPath $LivePath
    $same = $false
    if ($liveExists) {
        try { $same = (Get-FileHash -LiteralPath $LivePath -Algorithm SHA1).Hash -eq (Get-FileHash -LiteralPath $stage -Algorithm SHA1).Hash } catch { }
    }
    $liveHash = $(if ($liveExists) { (Get-FileHash -LiteralPath $LivePath -Algorithm SHA1).Hash } else { $null })
    [void]$Manifest.files.Add([ordered]@{ live = $LivePath; staged = $stage; generator = $Generator; liveExists = $liveExists; identical = $same; liveSha1AtGenerate = $liveHash; note = $Note })
}

function Add-WMWarning($Manifest, [string]$Text) {
    [void]$Manifest.warnings.Add($Text)
    Write-Warning $Text
}

function Test-WMPedalLayout($Prof) {
    <# Pedal convention (always): CLUTCH = left pedal, BRAKE = middle (left on a 2-pedal set), GAS = right pedal.
       Checks the profile against it using the names the driver gives each axis ("Accelerator", "Brake", "Clutch"...),
       and that no two pedals share an axis. Returns warning strings (empty = OK). #>
    $msgs = @(); $seen = @{}
    $rules = [ordered]@{ Clutch = 'accel|gas|throttle|brake'; Brake = 'accel|gas|throttle|clutch'; Gas = 'brake|clutch' }
    $live = @(); try { Import-WMInput; $live = @([WheelMap.DI]::Enumerate($true)) } catch { }
    foreach ($p in $rules.Keys) {
        $b = Get-WMBinding $Prof $p
        if (-not $b -or $b.type -ne 'axis') { continue }
        $key = "$($b.device)/$($b.axis)"
        if ($seen.ContainsKey($key)) { $msgs += "$p and $($seen[$key]) are both on $key - each pedal needs its own axis (clutch LEFT, brake MIDDLE, gas RIGHT)" } else { $seen[$key] = $p }
        $dev = Get-WMDevice $Prof $b.device
        $ld = @($live | Where-Object { $_.InstanceGuid.ToString() -eq $dev.instanceGuid -or $_.ProductName -eq $dev.productName }) | Select-Object -First 1
        if ($ld) {
            $obj = $ld.Objects | Where-Object { $_.Kind -eq 'Axis' -and $_.Offset -eq [int]$b.offset } | Select-Object -First 1
            if ($obj -and $obj.Name -match "(?i)$($rules[$p])") { $msgs += "$p is bound to the axis the driver calls '$($obj.Name)' - pedals should be clutch LEFT, brake MIDDLE, gas RIGHT (re-run Wheel Setup for the pedals)" }
        }
    }
    return $msgs
}