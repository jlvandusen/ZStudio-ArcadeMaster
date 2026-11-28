<#
.SYNOPSIS
  Keeps MAME, Supermodel (Model 3), Model 2 and Cemu (Wii U) pointed at the right controllers after Windows renumbers
  them: a reboot, a USB port change or a controller unplugged and plugged back in can change a device's DirectInput id
  (instance GUID) and its place in the list (JOY1, JOY2...). TeknoParrot has Update-ControllerIds and Dolphin binds by
  name; this does the same job for the emulators that store an id or a number.

  How: <ManifestDir>\emulator-devices.json records the ids and numbers the configs were written with (seeded from the
  WheelMap profile the first time). Each run reads what is plugged in now, matches every device by maker and product
  id (USB VID / PID, then name, then the old id when there are two of the same), and swaps only those tokens:
    MAME     ctrlr\*.cfg, cfg\*.cfg    mapdevice device="<id>"              (the JOYCODE_n numbers stay pinned)
    Cemu     controllerProfiles\*.xml  <uuid><id></uuid>
    Supermodel  Config\Supermodel.ini  JOY<n>_...
    Model 2  CFG\*.input               device number inside each control code (keys untouched)
  A device that is not plugged in is left as it was. Every changed file is backed up first as <file>.ids-<time>.bak.
  Dry run by default; -Apply writes and updates emulator-devices.json. Runs at boot and on plug / unplug.
.EXAMPLE
  tools\Repair-EmulatorDevices.ps1                  # what would change
  tools\Repair-EmulatorDevices.ps1 -Apply
#>
param(
  [string]$RetroFE = 'D:\ArcadeMaster\frontend\DRIVE-coinops',
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [string]$WheelProfile,                 # WheelMap profile the configs were generated from (default: wheelmap\profiles\G29.json)
  [string[]]$Roots,                 # emulator folders to repair (default: <RetroFE>\emulators + this cabinet's WheelMap targets)
  [string]$ControllerFiles,         # tests: another catalog\controller-files.json
  [string]$ScanFile,               # Get-CabinetDevices' directinput-scan.txt, just refreshed (boot / hot-plug): no second scan
  [string]$LiveJson,                # tests: a JSON list of devices instead of reading DirectInput
  [switch]$Apply
)
$ErrorActionPreference = 'Stop'
$wm = Join-Path $PSScriptRoot 'wheelmap'
if (-not $WheelProfile) { $WheelProfile = Join-Path $wm 'profiles\G29.json' }
$stateFile = Join-Path $ManifestDir 'emulator-devices.json'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# ---- what the configs were written with
function Get-Pad($d) { [pscustomobject]@{ id = [string]$d.id; productName = [string]$d.productName; instanceGuid = ([string]$d.instanceGuid).ToLower(); enumIndex = [int]$d.enumIndex; vid = [string]$d.vid; pid = [string]$d.pid } }
$written = $null
if (Test-Path -LiteralPath $stateFile) { $written = @((Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json).devices | ForEach-Object { Get-Pad $_ }) }
elseif ((Test-Path -LiteralPath $WheelProfile) -and ($pj = Get-Content -LiteralPath $WheelProfile -Raw | ConvertFrom-Json) -and ($LiveJson -or "$($pj.machine)" -eq $env:COMPUTERNAME)) {
  # the profile was captured (and the configs generated) on THIS cabinet: it records what they were written with
  $written = @($pj.devices | Where-Object { $_.id -ne 'keyboard' -and $_.id -notlike 'mouse*' -and $_.instanceGuid } | ForEach-Object { Get-Pad $_ })
}
$firstRecord = -not $written   # another cabinet's profile, or none: take what is plugged in now as the starting point

# ---- what is plugged in now
if ($LiveJson) { $live = @((Get-Content -LiteralPath $LiveJson -Raw | ConvertFrom-Json) | ForEach-Object { $p = Get-Pad $_; if ($null -ne $_.axes) { $p | Add-Member -NotePropertyName axes -NotePropertyValue ([int]$_.axes) -Force; $p | Add-Member -NotePropertyName buttons -NotePropertyValue ([int]$_.buttons) -Force }; $p }) }
elseif ($ScanFile -and (Test-Path -LiteralPath $ScanFile)) {
  # Get-CabinetDevices' DirectInput scan (refreshed by it whenever the USB devices change): JOYn, name, VID/PID, GUID
  $live = @(); $cur = $null
  foreach ($l in [IO.File]::ReadAllLines($ScanFile)) {
    if ($l -match '^\s{2}JOY(\d+)\s+(.+?)\s*$') { if ($cur) { $live += $cur }; $cur = [pscustomobject]@{ id = $Matches[2]; productName = $Matches[2]; instanceGuid = ''; enumIndex = [int]$Matches[1]; vid = ''; pid = '' } }
    elseif ($cur -and $l -match 'VID_([0-9A-F]{4})&PID_([0-9A-F]{4})') { if (-not $cur.vid) { $cur.vid = $Matches[1]; $cur.pid = $Matches[2] } }
    elseif ($cur -and $l -match 'instance GUID\s+([0-9a-fA-F-]{36})') { $cur.instanceGuid = $Matches[1].ToLower() }
    if ($cur -and $l -match 'axes=(\d+)\s+buttons=(\d+)') { $cur | Add-Member -NotePropertyName axes -NotePropertyValue ([int]$Matches[1]) -Force; $cur | Add-Member -NotePropertyName buttons -NotePropertyValue ([int]$Matches[2]) -Force }
  }
  if ($cur) { $live += $cur }
  $live = @($live | Where-Object { $_.instanceGuid })
}
else { . (Join-Path $wm 'lib\Common.ps1'); $live = @((Get-WMDevices).directInput | Where-Object { -not $_.error } | ForEach-Object { $p = Get-Pad $_; $p | Add-Member -NotePropertyName axes -NotePropertyValue ([int]$_.axisCount) -Force; $p | Add-Member -NotePropertyName buttons -NotePropertyValue ([int]$_.buttonCount) -Force; $p }) }   # with the counts, so the steering checks also run without a scan file
# ---- Model 3: is the game's steering on the wheel at all?
# A copied drive can come with Supermodel.ini written for another PC's controller order. RACE2's had every control on
# JOY2, which on RACE2 is the handbrake lever (one slider, no buttons): Start did nothing in Dirt Devils, and the first
# run here recorded that file as correct (2026-11-27). When InputSteering names a controller that is not there, or one
# that cannot be a wheel (no buttons, or fewer than two axes), and exactly one plugged-in controller can be (3+ axes and
# 10+ buttons), the two numbers are swapped in the whole file. Runs every time; needs the scan's axes / buttons counts.
$wheels = @($live | Where-Object { $null -ne $_.axes -and $_.axes -ge 3 -and $_.buttons -ge 10 })
if ($wheels.Count -eq 1) {
  $sr = @(); if ($Roots) { $sr = $Roots } else {
    $fe0 = Join-Path $RetroFE 'emulators'; if (Test-Path -LiteralPath $fe0) { $sr += @(Get-ChildItem -LiteralPath $fe0 -Directory | ForEach-Object FullName) }
    $tf0 = Join-Path $wm "targets\$env:COMPUTERNAME.json"; if (Test-Path -LiteralPath $tf0) { foreach ($e in @((Get-Content -LiteralPath $tf0 -Raw | ConvertFrom-Json).supermodel)) { if ($e.ini) { $sr += (Split-Path (Split-Path ([string]$e.ini))) } } }
  }
  foreach ($r0 in @($sr | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Sort-Object -Unique)) {
    $ini0 = Join-Path $r0 'Config\Supermodel.ini'; if (-not (Test-Path -LiteralPath $ini0)) { continue }
    $enc0 = [Text.Encoding]::GetEncoding(28591); $txt0 = [IO.File]::ReadAllText($ini0, $enc0); $sm = [regex]::Match($txt0, '(?m)^\s*InputSteering\s*=\s*"?JOY(\d+)_'); if (-not $sm.Success) { continue }
    $sj = [int]$sm.Groups[1].Value; $wj = [int]$wheels[0].enumIndex; if ($sj -eq $wj) { continue }
    $sd = @($live | Where-Object { $_.enumIndex -eq $sj })[0]
    if ($sd -and $null -ne $sd.axes -and $sd.buttons -gt 0 -and $sd.axes -ge 2) { continue }      # another real controller: somebody's choice, left alone
    $what = if ($sd) { "'$($sd.productName)' ($($sd.axes) axis, $($sd.buttons) buttons)" } else { 'a controller that is not plugged in' }
    Write-Host ("  {0} {1}: steering was on JOY{2}, {3} - JOY{2} and JOY{4} ('{5}') swapped in the whole file" -f $(if ($Apply) { 'FIXED' } else { 'WOULD FIX' }), $ini0, $sj, $what, $wj, $wheels[0].productName)
    if ($Apply) {
      Copy-Item -LiteralPath $ini0 "$ini0.wheel-$stamp.bak"
      $new0 = [regex]::Replace($txt0, '\bJOY(\d+)_', { param($m) $i = [int]$m.Groups[1].Value; if ($i -eq $sj) { "JOY${wj}_" } elseif ($i -eq $wj) { "JOY${sj}_" } else { $m.Value } })
      [IO.File]::WriteAllText($ini0, $new0, $enc0)   # byte for byte: the file is not always UTF-8
    }
  }
  # ---- Model 2: the same question for every game's CFG\<rom>.input (RACE2's Daytona USA, 2026-11-28: every wheel
  # control on joy 2, the handbrake lever; + / - did nothing in the test menu). A control is a 4-byte code; an axis
  # has FF on top and the controller's number in the second byte. The first axis of the file is the steering (or the
  # tank's first stick): when it sits on a controller that is not there or cannot be a wheel, that number and the
  # wheel's are swapped in every control of the file. Keys (codes under 0x100) have no controller and stay.
  foreach ($r0 in @($sr | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Sort-Object -Unique)) {
    foreach ($f2 in Get-ChildItem -LiteralPath (Join-Path $r0 'CFG') -Filter *.input -File -ErrorAction SilentlyContinue) {
      $b2 = [IO.File]::ReadAllBytes($f2.FullName); $words2 = [int]($b2.Length / 4) - 2; if ($words2 -lt 5) { continue }
      $sj = 0; for ($i = 0; $i -lt $words2; $i++) { $v = [BitConverter]::ToUInt32($b2, $i * 4); if (($v -shr 24) -eq 0xFF) { $sj = [int](($v -shr 8) -band 0xF); break } }
      $wj = [int]$wheels[0].enumIndex; if ($sj -eq 0 -or $sj -eq $wj) { continue }
      $sd = @($live | Where-Object { $_.enumIndex -eq $sj })[0]
      if ($sd -and $null -ne $sd.axes -and $sd.buttons -gt 0 -and $sd.axes -ge 2) { continue }    # another real controller: somebody's choice
      $what = if ($sd) { "'$($sd.productName)' ($($sd.axes) axis, $($sd.buttons) buttons)" } else { 'a controller that is not plugged in' }
      $out2 = [byte[]]$b2.Clone(); $n2 = 0
      for ($i = 0; $i -lt $words2; $i++) {
        $v = [BitConverter]::ToUInt32($b2, $i * 4); if ($v -lt 0x100) { continue }; $j = [int](($v -shr 8) -band 0xF)
        $nj = if ($j -eq $sj) { $wj } elseif ($j -eq $wj) { $sj } else { continue }
        [BitConverter]::GetBytes([uint32](($v -band 0xFFFFF0FF) -bor ([uint32]$nj -shl 8))).CopyTo($out2, $i * 4); $n2++
      }
      Write-Host ("  {0} {1}: steering was on joy {2}, {3} - joy {2} and joy {4} ('{5}') swapped in {6} control(s)" -f $(if ($Apply) { 'FIXED' } else { 'WOULD FIX' }), $f2.FullName, $sj, $what, $wj, $wheels[0].productName, $n2)
      if ($Apply) { Copy-Item -LiteralPath $f2.FullName "$($f2.FullName).wheel-$stamp.bak"; [IO.File]::WriteAllBytes($f2.FullName, $out2) }
    }
  }}
if ($firstRecord) {
  if (-not $live) { Write-Host 'emulator controllers: nothing plugged in and no record yet - nothing to do'; return }
  Write-Host "emulator controllers: first run on this cabinet - recorded the $($live.Count) device(s) plugged in now; changes are fixed from the next run"
  if ($Apply) { New-Item -ItemType Directory -Force $ManifestDir | Out-Null; [IO.File]::WriteAllText($stateFile, (@{ updated = (Get-Date -Format s); devices = @($live | ForEach-Object { $_.id = $_.productName; $_ }) } | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false))) }
  return
}

# ---- match each written device to a live one
$used = @{}; $guidMap = @{}; $joyMap = @{}; $now = @(); $report = @()
foreach ($w in $written) {
  $c = @($live | Where-Object { -not $used.ContainsKey($_.instanceGuid) -and $_.vid -eq $w.vid -and $_.pid -eq $w.pid })
  if ($c.Count -gt 1) { $same = @($c | Where-Object { $_.instanceGuid -eq $w.instanceGuid }); if ($same) { $c = $same } else { $n = @($c | Where-Object { $_.productName -eq $w.productName }); if ($n) { $c = $n } } }
  if (-not $c) { $c = @($live | Where-Object { -not $used.ContainsKey($_.instanceGuid) -and $_.productName -eq $w.productName }) }
  if (-not $c) { $report += "$($w.productName): not plugged in - left as it was"; $now += $w; continue }
  $l = $c[0]; $used[$l.instanceGuid] = $true
  if ($l.instanceGuid -ne $w.instanceGuid) { $guidMap[$w.instanceGuid] = $l.instanceGuid; $report += "$($w.productName): id $($w.instanceGuid) -> $($l.instanceGuid)" }
  if ($l.enumIndex -ne $w.enumIndex) { $joyMap[$w.enumIndex] = $l.enumIndex; $report += "$($w.productName): JOY$($w.enumIndex) -> JOY$($l.enumIndex)" }
  $now += [pscustomobject]@{ id = $w.id; productName = $l.productName; instanceGuid = $l.instanceGuid; enumIndex = $l.enumIndex; vid = $l.vid; pid = $l.pid }
}
$report | ForEach-Object { Write-Host "  $_" }

# ---- emulator folders
if (-not $Roots) {
  $Roots = @()
  $fe = Join-Path $RetroFE 'emulators'; if (Test-Path -LiteralPath $fe) { $Roots += @(Get-ChildItem -LiteralPath $fe -Directory | ForEach-Object FullName) }
  $tf = Join-Path $wm "targets\$env:COMPUTERNAME.json"
  if (Test-Path -LiteralPath $tf) {
    $t = Get-Content -LiteralPath $tf -Raw | ConvertFrom-Json
    foreach ($k in 'mame', 'cemu', 'm2emulator') { foreach ($e in @($t.$k)) { if ($e.root) { $Roots += [string]$e.root } } }
    foreach ($e in @($t.supermodel)) { if ($e.ini) { $Roots += (Split-Path (Split-Path ([string]$e.ini))) } }
  }
  $Roots = @($Roots | Where-Object { Test-Path -LiteralPath $_ } | Sort-Object -Unique)
}

$changed = 0
function Save-File([string]$f, [byte[]]$bytes, [string]$why) {
  Write-Host ("  {0} {1} ({2})" -f $(if ($Apply) { 'FIXED' } else { 'WOULD FIX' }), $f, $why)
  if ($Apply) { Copy-Item -LiteralPath $f "$f.ids-$stamp.bak"; [IO.File]::WriteAllBytes($f, $bytes) }
  $script:changed++
}
$u8 = New-Object Text.UTF8Encoding($false)
function Edit-Text([string]$f, [scriptblock]$fix, [string]$why) {
  $raw = [IO.File]::ReadAllBytes($f); $bom = $raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF
  $txt = $u8.GetString($raw, $(if ($bom) { 3 } else { 0 }), $raw.Length - $(if ($bom) { 3 } else { 0 }))
  $new = & $fix $txt
  if ($new -ceq $txt) { return }
  $out = $u8.GetBytes($new); if ($bom) { $out = [byte[]](0xEF, 0xBB, 0xBF) + $out }
  Save-File $f $out $why
}
$guidRx = $null
if ($guidMap.Count) { $guidRx = New-Object Regex ('(?i)' + (($guidMap.Keys | ForEach-Object { [regex]::Escape($_) }) -join '|')) }
$swapGuid = { param($t) if (-not $guidRx) { return $t }; $guidRx.Replace($t, { param($m) $n = $guidMap[$m.Value.ToLower()]; if ($m.Value -cmatch '[A-F]') { $n.ToUpper() } else { $n } }) }
$swapJoy = { param($t) if (-not $joyMap.Count) { return $t }; [regex]::Replace($t, '\bJOY(\d+)_', { param($m) $i = [int]$m.Groups[1].Value; if ($joyMap.ContainsKey($i)) { "JOY$($joyMap[$i])_" } else { $m.Value } }) }

foreach ($r in $Roots) {
  if ($guidMap.Count) {
    foreach ($sub in 'ctrlr', 'cfg') { foreach ($f in Get-ChildItem -LiteralPath (Join-Path $r $sub) -Filter *.cfg -File -ErrorAction SilentlyContinue) { Edit-Text $f.FullName $swapGuid 'MAME device id' } }
    foreach ($f in Get-ChildItem -LiteralPath (Join-Path $r 'controllerProfiles') -Filter *.xml -File -ErrorAction SilentlyContinue) { Edit-Text $f.FullName $swapGuid 'Cemu device id' }
  }
  if ($joyMap.Count) {
    $ini = Join-Path $r 'Config\Supermodel.ini'; if (Test-Path -LiteralPath $ini) { Edit-Text $ini $swapJoy 'Supermodel JOY number' }
    foreach ($f in Get-ChildItem -LiteralPath (Join-Path $r 'CFG') -Filter *.input -File -ErrorAction SilentlyContinue) {
      $b = [IO.File]::ReadAllBytes($f.FullName); $out = [byte[]]$b.Clone(); $n = 0
      $words = [int]($b.Length / 4) - 2          # the last two words are not controls (see WheelMap Gen-Others, m2emulator)
      for ($i = 0; $i -lt $words; $i++) {
        $v = [BitConverter]::ToUInt32($b, $i * 4); $joy = [int](($v -shr 8) -band 0xF)
        if ($joy -eq 0 -or -not $joyMap.ContainsKey($joy) -or $v -lt 0x100) { continue }   # keys (scan codes) have no device number
        $v = [uint32](($v -band 0xFFFFF0FF) -bor ([uint32]$joyMap[$joy] -shl 8)); [BitConverter]::GetBytes($v).CopyTo($out, $i * 4); $n++
      }
      if ($n) { Save-File $f.FullName $out "Model 2: $n control(s) moved to the new device number" }
    }
  }
}
# PC games that store a device's GUID in their own settings (catalog\controller-files.json: Assetto Corsa Competizione ...)
if ($guidMap.Count) {
  $cf = Join-Path (Split-Path $PSScriptRoot) 'catalog\controller-files.json'
  if ($ControllerFiles) { $cf = $ControllerFiles }
  if (Test-Path -LiteralPath $cf) {
    foreach ($g in (Get-Content -LiteralPath $cf -Raw | ConvertFrom-Json).files) {
      $p = [Environment]::ExpandEnvironmentVariables([string]$g.path)
      if (Test-Path -LiteralPath $p) { Edit-Text $p $swapGuid "$($g.game) device id" }
    }
  }
}

if (-not $guidMap.Count -and -not $joyMap.Count) { Write-Host "emulator controllers: unchanged ($(@($now).Count) device(s) where the configs expect them)" }
else { Write-Host ("emulator controllers: {0} file(s) {1} in {2} folder(s)" -f $changed, $(if ($Apply) { 'fixed' } else { 'to fix (dry run)' }), $Roots.Count) }
if ($Apply -and ($guidMap.Count -or $joyMap.Count -or -not (Test-Path -LiteralPath $stateFile))) {
  New-Item -ItemType Directory -Force $ManifestDir | Out-Null
  [IO.File]::WriteAllText($stateFile, (@{ updated = (Get-Date -Format s); devices = @($now) } | ConvertTo-Json -Depth 4), $u8)
}
