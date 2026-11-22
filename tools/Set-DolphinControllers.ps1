<#
.SYNOPSIS
  Keeps Dolphin (Wii / GameCube) matched to the controllers that are plugged in RIGHT NOW. Runs at boot
  (Start-ArcadeMaster) and from Tools > Detect Controllers.
    - Real Wii Remotes ("wands", Bluetooth or Mayflash DolphinBar): Wii Remote slots 1..N switch to Source = 2 (Real)
      and continuous scanning is enabled; unplug them and the slots go back to what they were (normally the
      emulated Wii Remote mapped to the wheel by WheelMap).
    - Balance Board: [BalanceBoard] Source = 2 while one is connected.
    - GameCube controller adapter (Wii U / Switch, 057E:0337): GC ports 2-4 become 'GC Adapter' (SIDevice 12);
      port 1 stays the wheel-mapped standard controller. Restored when the adapter is unplugged.
    - Stale devices: a profile bound to a controller that is not connected (e.g. 'DInput/0/... G920 ...' on a
      G29 cabinet) is re-pointed to the connected wheel / stick of the same kind.
  Original values are remembered in <User>\Config\ArcadeMaster-controllers.json so every change is reversible.
#>
param(
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [string[]]$DolphinUser,
  [string]$Targets
)
$ErrorActionPreference = 'Stop'
$cab = Get-Content (Join-Path $ManifestDir 'cabinet.json') -Raw | ConvertFrom-Json
$wii = $cab.capabilities.wii
if (-not $DolphinUser) {
  if (-not $Targets) { $Targets = Join-Path $PSScriptRoot "wheelmap\targets\$env:COMPUTERNAME.json"; if (-not (Test-Path $Targets)) { $Targets = Join-Path $PSScriptRoot 'wheelmap\targets\default.json' } }
  $tj = Get-Content $Targets -Raw | ConvertFrom-Json
  $DolphinUser = @($tj.dolphin | ForEach-Object { $_.user }) | Where-Object { $_ -and (Test-Path $_) }
}
$real = if ($wii) { [Math]::Min(4, [int]$wii.wiimotes) } else { 0 }
$board = $wii -and [int]$wii.balanceBoard -gt 0
$gcad = $wii -and [bool]$wii.gcAdapter
$present = @($cab.devices | Where-Object { $_.type -ne 'Nintendo' } | ForEach-Object { $_.name })
$wheelName = ($cab.devices | Where-Object { $_.role -eq 'wheel' -or $_.type -eq 'Driving' } | Select-Object -First 1).name
$stickName = ($cab.devices | Where-Object { $_.type -match 'Flight|Joystick' -and $_.role -notmatch 'wheel|handbrake' } | Select-Object -First 1).name

function Get-Ini([string]$p) { $l = New-Object Collections.Generic.List[string]; if (Test-Path $p) { foreach ($x in Get-Content $p) { $l.Add($x) } }; return , $l }   # , = return the List itself (not unrolled)
function Get-IniValue($lines, [string]$sec, [string]$key) {
  $in = $false; foreach ($l in $lines) { if ($l -match '^\s*\[(.+)\]') { $in = $Matches[1] -eq $sec; continue }; if ($in -and $l -match "^\s*$([regex]::Escape($key))\s*=\s*(.*)$") { return $Matches[1].Trim() } }; return $null
}
function Set-IniValue($lines, [string]$sec, [string]$key, [string]$val) {
  $in = $false; $secAt = -1; $end = $lines.Count
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*\[(.+)\]') { if ($in) { $end = $i; break }; $in = $Matches[1] -eq $sec; if ($in) { $secAt = $i }; continue }
    if ($in -and $lines[$i] -match "^\s*$([regex]::Escape($key))\s*=") { $lines[$i] = "$key = $val"; return }
  }
  if ($secAt -lt 0) { $lines.Add("[$sec]"); $lines.Add("$key = $val") } else { $lines.Insert($end, "$key = $val") }
}

foreach ($u in $DolphinUser) {
  $cfg = Join-Path $u 'Config'; if (-not (Test-Path $cfg)) { continue }
  $stateFile = Join-Path $cfg 'ArcadeMaster-controllers.json'
  $state = if (Test-Path $stateFile) { Get-Content $stateFile -Raw | ConvertFrom-Json } else { [pscustomobject]@{ wiimoteSource = @{}; boardSource = $null; siDevice = @{} } }
  foreach ($p in 'wiimoteSource', 'siDevice') { if ($state.$p -isnot [hashtable]) { $h = @{}; if ($state.$p) { $state.$p.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value } }; $state.$p = $h } }
  $changes = @()

  # ---- WiimoteNew.ini
  $wf = Join-Path $cfg 'WiimoteNew.ini'; $w = Get-Ini $wf; $w0 = ($w -join "`n")
  for ($i = 1; $i -le 4; $i++) {
    $sec = "Wiimote$i"; $cur = Get-IniValue $w $sec 'Source'
    if ($i -le $real) {
      if ($cur -ne '2') { if (-not $state.wiimoteSource.ContainsKey($sec)) { $state.wiimoteSource[$sec] = $(if ($cur) { $cur } else { '1' }) }; Set-IniValue $w $sec 'Source' '2'; $changes += "$sec -> Real Wii Remote" }
    } elseif ($state.wiimoteSource.ContainsKey($sec)) {
      Set-IniValue $w $sec 'Source' $state.wiimoteSource[$sec]; $changes += "$sec -> restored Source $($state.wiimoteSource[$sec])"; $state.wiimoteSource.Remove($sec)
    }
  }
  $bcur = Get-IniValue $w 'BalanceBoard' 'Source'
  if ($board -and $bcur -ne '2') { if ($null -eq $state.boardSource) { $state.boardSource = $(if ($bcur) { $bcur } else { '0' }) }; Set-IniValue $w 'BalanceBoard' 'Source' '2'; $changes += 'Balance Board -> Real' }
  elseif (-not $board -and $null -ne $state.boardSource) { Set-IniValue $w 'BalanceBoard' 'Source' $state.boardSource; $changes += 'Balance Board restored'; $state.boardSource = $null }

  # ---- stale devices in the emulated-controller profiles (WiimoteNew / GCPadNew)
  $gf = Join-Path $cfg 'GCPadNew.ini'; $g = Get-Ini $gf
  foreach ($file in @($wf, $gf)) {
    $lines = $g; if ($file -eq $wf) { $lines = $w }
    if ($lines -isnot [Collections.Generic.List[string]]) { throw 'internal: ini list was unrolled' }
    $before = $lines -join "`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
      if ($lines[$i] -match '^(\s*Device\s*=\s*DInput/\d+/)(.+?)\s*$') {
        $prefix = $Matches[1]; $name = $Matches[2]
        if ($present -notcontains $name) {
          $repl = if ($name -match '(?i)wheel|racing|driving|G2\d\d|G9\d\d|T\d{3}|fanatec') { $wheelName } elseif ($name -match '(?i)stick|flight|hotas|throttle') { $stickName } else { $null }
          if ($repl) { $lines[$i] = $prefix + $repl; $changes += "$(Split-Path $file -Leaf): '$name' is not connected -> '$repl'" }
        }
      }
    }
    if ($file -ne $wf -and ($lines -join "`n") -ne $before) { Copy-Item $file "$file.am-bak" -ErrorAction SilentlyContinue; Set-Content $file $lines -Encoding ASCII }
  }
  if (($w -join "`n") -ne $w0) { if (-not (Test-Path "$wf.am-bak")) { Copy-Item $wf "$wf.am-bak" -ErrorAction SilentlyContinue }; Set-Content $wf $w -Encoding ASCII }

  # ---- Dolphin.ini: scanning for real Wii Remotes, GC adapter on ports 2-4
  $df = Join-Path $cfg 'Dolphin.ini'; $d = Get-Ini $df; $d0 = ($d -join "`n")
  $scan = $(if ($real -gt 0 -or $board) { 'True' } else { 'False' })
  if ((Get-IniValue $d 'Core' 'WiimoteContinuousScanning') -ne $scan) { Set-IniValue $d 'Core' 'WiimoteContinuousScanning' $scan; $changes += "continuous Wii Remote scanning = $scan" }
  if ($real -gt 0 -and (Get-IniValue $d 'BluetoothPassthrough' 'Enabled') -eq 'True') { $changes += 'WARNING: Bluetooth passthrough is on - real Wii Remotes paired in Windows are not seen; turn it off or use a DolphinBar' }
  for ($p = 1; $p -le 3; $p++) {
    $k = "SIDevice$p"; $cur = Get-IniValue $d 'Core' $k
    if ($gcad) { if ($cur -ne '12') { if (-not $state.siDevice.ContainsKey($k)) { $state.siDevice[$k] = $(if ($cur) { $cur } else { '6' }) }; Set-IniValue $d 'Core' $k '12'; $changes += "GC port $($p + 1) -> GameCube adapter" } }
    elseif ($state.siDevice.ContainsKey($k)) { Set-IniValue $d 'Core' $k $state.siDevice[$k]; $changes += "GC port $($p + 1) restored"; $state.siDevice.Remove($k) }
  }
  if (($d -join "`n") -ne $d0) { if (-not (Test-Path "$df.am-bak")) { Copy-Item $df "$df.am-bak" -ErrorAction SilentlyContinue }; Set-Content $df $d -Encoding ASCII }

  $state | ConvertTo-Json -Depth 4 | Set-Content $stateFile -Encoding UTF8
  Write-Host ("Dolphin {0}: real Wii Remotes {1}, balance board {2}, GC adapter {3}" -f $u, $real, $board, $gcad)
  if ($changes) { $changes | ForEach-Object { Write-Host "  $_" } } else { Write-Host '  no change' }
}
