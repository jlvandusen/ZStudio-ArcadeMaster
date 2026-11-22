<#
.SYNOPSIS
  WheelMap - master input mapping for arcade cabinets (racing / flight / lightgun).

.DESCRIPTION
  1. -Detect     list attached DirectInput/XInput controllers, their axes and DirectInput instance GUIDs
  2. -Capture    interactive wizard ("turn wheel fully left", "press gas", ...) -> profiles\<Name>.json
  3. -Generate   build emulator configs from a profile + templates\*.json into the staging folder
  4. -Apply      copy staged files over the live configs. DRY RUN unless -Commit is also given;
                 with -Commit every live file is backed up first (<file>.wheelmap-<timestamp>.bak).
  Extras: -Seed (non-interactive starter profile), -Monitor (live input view), -ResolveTable (template review).

.EXAMPLE
  .\WheelMap.ps1 -Detect
  .\WheelMap.ps1 -Capture -Name G29                      # racing wizard, writes profiles\G29.json
  .\WheelMap.ps1 -Capture -Name G29 -Only Clutch,Handbrake   # redo a few steps of an existing profile
  .\WheelMap.ps1 -Capture -Name Sinden2P -CabinetType lightgun -Guns 2 -Keyboard
  .\WheelMap.ps1 -Generate -Name G29                     # -> D:\ArcadeMaster\_staging\inputmap\G29
  .\WheelMap.ps1 -Apply -Name G29                        # dry run: shows what would change
  .\WheelMap.ps1 -Apply -Name G29 -Commit                # back up + write live configs
#>
[CmdletBinding(DefaultParameterSetName = 'Detect')]
param(
    [Parameter(ParameterSetName = 'Detect')][switch]$Detect,
    [Parameter(ParameterSetName = 'Capture', Mandatory)][switch]$Capture,
    [Parameter(ParameterSetName = 'Seed', Mandatory)][switch]$Seed,
    [Parameter(ParameterSetName = 'Monitor', Mandatory)][switch]$Monitor,
    [Parameter(ParameterSetName = 'Generate', Mandatory)][switch]$Generate,
    [Parameter(ParameterSetName = 'Apply', Mandatory)][switch]$Apply,
    [Parameter(ParameterSetName = 'Resolve', Mandatory)][switch]$ResolveTable,

    [Parameter(ParameterSetName = 'Capture')][Parameter(ParameterSetName = 'Seed')]
    [Parameter(ParameterSetName = 'Generate')][Parameter(ParameterSetName = 'Apply')]
    [string]$Name = 'G29',

    [Parameter(ParameterSetName = 'Capture')][ValidateSet('racing', 'flight', 'lightgun')][string]$CabinetType = 'racing',
    [Parameter(ParameterSetName = 'Capture')][switch]$Keyboard,
    [Parameter(ParameterSetName = 'Capture')][int]$Guns = 1,
    [Parameter(ParameterSetName = 'Capture')][string[]]$Only,
    [Parameter(ParameterSetName = 'Capture')][Parameter(ParameterSetName = 'Monitor')][string[]]$Devices,
    [Parameter(ParameterSetName = 'Monitor')][int]$Seconds = 0,

    [Parameter(ParameterSetName = 'Generate')][Parameter(ParameterSetName = 'Apply')][Parameter(ParameterSetName = 'Seed')][Parameter(ParameterSetName = 'Resolve')]
    [string]$Targets,
    [Parameter(ParameterSetName = 'Generate')][Parameter(ParameterSetName = 'Apply')]
    [string]$StageDir = 'D:\ArcadeMaster\_staging\inputmap',
    [Parameter(ParameterSetName = 'Generate')][ValidateSet('teknoparrot', 'dolphin', 'supermodel', 'mame', 'cemu', 'm2emulator', 'ffbplugin')][string[]]$Emulators,
    [Parameter(ParameterSetName = 'Generate')][string[]]$Games,
    [Parameter(ParameterSetName = 'Generate')][switch]$NoRematch,

    [Parameter(ParameterSetName = 'Apply')][switch]$Commit,
    [Parameter(ParameterSetName = 'Apply')][switch]$Force,
    [Parameter(ParameterSetName = 'Detect')][switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\Capture.ps1')
. (Join-Path $PSScriptRoot 'lib\Gen-TeknoParrot.ps1')
. (Join-Path $PSScriptRoot 'lib\Gen-Others.ps1')

$profilePath = Join-Path $PSScriptRoot "profiles\$Name.json"

function Update-WMProfileDevices($prof) {
    # Profiles carry instance GUIDs from the machine they were captured on. Re-match by VID/PID
    # (then product name) against what is attached now so a profile moves between cabinets.
    $det = Get-WMDevices
    foreach ($d in $prof.devices) {
        if ($d.id -eq 'keyboard' -or $d.id -like 'mouse*') { continue }
        $hit = @($det.directInput | Where-Object { $_.instanceGuid -eq $d.instanceGuid })
        if (-not $hit) { $hit = @($det.directInput | Where-Object { $_.vid -and $_.vid -eq $d.vid -and $_.pid -eq $d.pid }) }
        if (-not $hit) { $hit = @($det.directInput | Where-Object { $_.productName -eq $d.productName }) }
        if ($hit.Count -ge 1) {
            $h = $hit[0]
            if ($h.instanceGuid -ne $d.instanceGuid) { Write-Warning "Device '$($d.id)': instance GUID re-matched $($d.instanceGuid) -> $($h.instanceGuid) (VID/PID match)" }
            $d.instanceGuid = $h.instanceGuid; $d.enumIndex = $h.enumIndex; $d.productName = $h.productName; $d.diType = $h.diType
            $d['mameIndexGuess'] = $h.mameIndexGuess
            if ($hit.Count -gt 1) { Write-Warning "Device '$($d.id)': $($hit.Count) identical devices attached - using enumeration #$($h.enumIndex). Re-capture to pin the right one." }
        } else {
            Write-Warning "Device '$($d.id)' ($($d.productName)) is not attached - generating with the stored GUID $($d.instanceGuid)."
        }
    }
}

switch ($PSCmdlet.ParameterSetName) {
    'Detect' {
        $det = Get-WMDevices
        if ($Json) { $det | ConvertTo-Json -Depth 6; break }
        Write-Host 'DirectInput game controllers (enumeration order = Supermodel/m2emulator JOYn):' -ForegroundColor Cyan
        foreach ($d in $det.directInput) {
            Write-Host ("  JOY{0}  {1}" -f $d.enumIndex, $d.productName) -ForegroundColor White
            Write-Host ("        VID_{0}&PID_{1}  type={2}  role-guess={3}  FFB={4}  axes={5} buttons={6} hats={7}" -f $d.vid, $d.pid, $d.diType, $d.roleGuess, $d.forceFeedback, $d.axisCount, $d.buttonCount, $d.povCount)
            Write-Host ("        instance GUID {0}   (TeknoParrot <JoystickGuid>, Cemu <uuid>)" -f $d.instanceGuid)
            Write-Host ("        registry      {0}" -f $(if ($d.registryKey) { $d.registryKey + '  (matches)' } else { 'no DirectInput calibration key found' }))
            Write-Host ("        MAME JOYCODE  {0} (guess; winhybrid numbers XInput pads first)" -f $d.mameIndexGuess)
            foreach ($o in $d.objects) { Write-Host ("          {0,-5} {1,-24} '{2}'" -f $o.kind, $o.offsetName, $o.name) -ForegroundColor DarkGray }
            if ($d.error) { Write-Host "        error: $($d.error)" -ForegroundColor Red }
        }
        Write-Host 'RawInput mice (mouse-mode light guns appear here):' -ForegroundColor Cyan
        foreach ($m in $det.rawInputMice) { Write-Host ("  {0}{1}" -f $m.path, $(if ($m.gunGuess) { '   <- looks like a light gun' } else { '' })) }
        $xc = @($det.xinput | Where-Object { $_.connected })
        Write-Host ("XInput pads connected: {0}" -f $(if ($xc) { ($xc | ForEach-Object { $_.index }) -join ', ' } else { 'none' })) -ForegroundColor Cyan
    }
    'Monitor' { Import-WMInput; Show-WMMonitor -Seconds $Seconds -DeviceFilter $Devices }
    'Capture' {
        $resume = $(if ($Only -and (Test-Path -LiteralPath $profilePath)) { $profilePath } else { $null })
        $prof = Invoke-WMCapture -Name $Name -CabinetType $CabinetType -OutFile $resume -DeviceFilter $Devices -Keyboard:$Keyboard -Guns $Guns -Only $Only
        Write-Host ''
        Write-Host 'Captured:' -ForegroundColor Cyan
        foreach ($k in $prof.controls.Keys) {
            $e = $prof.controls[$k]
            $desc = switch ($e.type) { 'axis' { "$($e.device) axis $($e.axis)$(if($e.Contains('direction')){$e.direction})" } 'button' { "$($e.device) button $($e.button)" } 'pov' { "$($e.device) hat$($e.pov) $($e.dir)" } 'key' { "key $($e.name)" } default { $e.type } }
            Write-Host ("  {0,-12} {1}" -f $k, $desc)
        }
        $ans = 'y'
        try { $ans = Read-Host "Save to $profilePath ? (Y/n)" } catch { }
        if ($ans -notmatch '^[nN]') {
            if (Test-Path -LiteralPath $profilePath) { Copy-Item -LiteralPath $profilePath -Destination ($profilePath + '.' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bak') }
            Write-WMJson $prof $profilePath
            Write-Host "Saved $profilePath" -ForegroundColor Green
        }
    }
    'Seed' {
        $tg = Get-WMTargets $Targets
        $tpRoot = $(if ($tg.Contains('teknoparrot') -and $tg.teknoparrot.Count) { $tg.teknoparrot[0].root } else { $null })
        $mameRef = $(if ($tg.Contains('mame') -and $tg.mame.Count -and $tg.mame[0].Contains('reference')) { $tg.mame[0].reference } else { $null })
        $prof = New-WMSeedProfile -Name $Name -TPRoot $tpRoot -MameReference $mameRef
        if (Test-Path -LiteralPath $profilePath) { throw "$profilePath exists - delete it or use -Capture to update it." }
        Write-WMJson $prof $profilePath
        Write-Host "Seed profile written: $profilePath (confirmed=false)" -ForegroundColor Yellow
    }
    'Resolve' {
        $tg = Get-WMTargets $Targets
        Get-WMTPResolvedTable $tg.teknoparrot[0].root
    }
    'Generate' {
        if (-not (Test-Path -LiteralPath $profilePath)) { throw "Profile not found: $profilePath (run -Capture or -Seed first)" }
        $prof = Read-WMJson $profilePath
        if (-not $prof.confirmed) { Write-Warning "Profile '$Name' is UNCONFIRMED (seeded, not captured). Output is for review only." }
        if (-not $NoRematch) { Update-WMProfileDevices $prof }
        $tg = Get-WMTargets $Targets
        $stage = Join-Path $StageDir $Name
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $stage | Out-Null
        $man = New-WMManifest $stage $Name
        $man['targets'] = $tg._path
        $man['profileConfirmed'] = [bool]$prof.confirmed
        $all = @('teknoparrot', 'dolphin', 'supermodel', 'mame', 'cemu', 'm2emulator', 'ffbplugin')
        $run = $(if ($Emulators) { $Emulators } else { $all })
        $reports = [ordered]@{}
        foreach ($e in $run) {
            if (-not $tg.Contains($e)) { continue }
            Write-Host "Generating $e ..." -ForegroundColor Cyan
            switch ($e) {
                'teknoparrot' { $reports[$e] = Invoke-WMGenTeknoParrot $prof $tg $man $Games }
                'dolphin'     { $reports[$e] = Invoke-WMGenDolphin $prof $tg $man }
                'supermodel'  { $reports[$e] = Invoke-WMGenSupermodel $prof $tg $man }
                'mame'        { $reports[$e] = Invoke-WMGenMame $prof $tg $man }
                'cemu'        { $reports[$e] = Invoke-WMGenCemu $prof $tg $man }
                'm2emulator'  { $reports[$e] = Invoke-WMGenM2 $prof $tg $man }
                'ffbplugin'   { $reports[$e] = Invoke-WMGenFFBPlugin $prof $tg $man }
            }
        }
        $man['reports'] = $reports
        Write-WMJson $man (Join-Path $stage 'manifest.json')
        Copy-Item -LiteralPath $profilePath -Destination (Join-Path $stage "$Name.profile.json")
        $changed = @($man.files | Where-Object { -not $_.identical }).Count
        Write-Host ("Staged {0} files ({1} differ from live, {2} new) in {3}" -f $man.files.Count, $changed, @($man.files | Where-Object { -not $_.liveExists }).Count, $stage) -ForegroundColor Green
        Write-Host "Review: $stage\manifest.json  (each entry: live path, staged path, notes)"
    }
    'Apply' {
        $stage = Join-Path $StageDir $Name
        $mp = Join-Path $stage 'manifest.json'
        if (-not (Test-Path -LiteralPath $mp)) { throw "No staged output at $stage - run -Generate first." }
        $man = Read-WMJson $mp
        if (-not $man.profileConfirmed) { Write-Warning 'Staged output was generated from an UNCONFIRMED profile.' }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $n = 0
        foreach ($f in $man.files) {
            if ($f.identical) { continue }
            # refuse to overwrite a live file that changed after -Generate (someone edited it in the emulator UI)
            $nowHash = $(if (Test-Path -LiteralPath $f.live) { (Get-FileHash -LiteralPath $f.live -Algorithm SHA1).Hash } else { $null })
            if ($f.Contains('liveSha1AtGenerate') -and $nowHash -ne $f.liveSha1AtGenerate -and -not $Force) {
                Write-Warning "live file changed since -Generate, skipped (re-run -Generate, or -Force): $($f.live)"; continue
            }
            $n++
            if (-not $Commit) { Write-Host ("[dry-run] {0} {1}" -f $(if ($f.liveExists) { 'replace' } else { 'create ' }), $f.live); continue }
            if (Test-Path -LiteralPath $f.live) {
                $bak = "$($f.live).wheelmap-$stamp.bak"
                Copy-Item -LiteralPath $f.live -Destination $bak
            } else {
                $dir = Split-Path -Parent $f.live
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            }
            Copy-Item -LiteralPath $f.staged -Destination $f.live -Force
            Write-Host "written $($f.live)" -ForegroundColor Green
        }
        if (-not $Commit) { Write-Host "$n file(s) would change. Re-run with -Commit to back up and write them." -ForegroundColor Yellow }
        else { Write-Host "$n file(s) written; backups end in .wheelmap-$stamp.bak" -ForegroundColor Green }
    }
}
