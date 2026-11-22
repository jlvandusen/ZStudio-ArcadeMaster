<#
.SYNOPSIS
  Re-points controller bindings after DirectInput device IDs change (USB port moved, Windows re-enumerated,
  device swapped). Dry run by default; -Apply backs up every changed file to <file>.ids-<timestamp>.bak.

  For each TeknoParrot binding (<JoystickGuid> + <BindNameDi>, e.g. "Driving Buttons11", "Supplemental Slider"):
    1. Keyboard binds          -> SysKeyboard GUID (fixed). Repairs the old UpdateGuid script's damage.
    2. GUID currently present and its device type matches the bind's type prefix -> unchanged
    3. GUID seen before (device-history.json) for a device that is present now -> that device's current GUID
    4. otherwise: exactly one present device of the bind's type (Driving/Supplemental/Joystick/Gamepad/Flight)
       -> that device's GUID
    5. ambiguous or no matching device -> left alone, reported
  Run Get-CabinetDevices.ps1 first (it refreshes cabinet.json + device-history.json).
#>
param(
  [string]$Cabinet = 'D:\ArcadeMaster\manifest\cabinet.json',
  [string]$History = 'D:\ArcadeMaster\manifest\device-history.json',
  [string[]]$TeknoParrot = @('E:\DRIVE Collection\emulators\TeknoParrot', 'E:\DRIVE Collection\emulators\TeknoParrotMulti', 'D:\Emulators\TeknoParrot'),
  [string]$RetroFE,                  # the frontend being booted: when given, only ITS TeknoParrot install(s) are re-pointed
  [switch]$Apply
)
$ErrorActionPreference = 'Stop'
if (-not $PSBoundParameters.ContainsKey('TeknoParrot')) {
  . (Join-Path $PSScriptRoot 'lib\AmMachine.ps1')
  # default list = DESKTOP-RACE1's; elsewhere only what exists. With -RetroFE only that frontend's own install(s),
  # so booting a test copy never rewrites the live frontend's profiles.
  # DESKTOP-RACE1 keeps exactly its list (it exists there); other cabinets get only the booted frontend's own install(s)
  $TeknoParrot = @(@($TeknoParrot | Where-Object { Test-Path -LiteralPath $_ }) + @(if ($RetroFE) { Get-AmTeknoParrotRoots -RetroFE $RetroFE -LocalOnly }) | Select-Object -Unique)
}
$SysKeyboard = '6f1d2b61-d5a0-11cf-bfc7-444553540000'
$SysMouse = '6f1d2b60-d5a0-11cf-bfc7-444553540000'
$cab = Get-Content $Cabinet -Raw | ConvertFrom-Json
$present = @($cab.devices)
$hist = if (Test-Path $History) { @((Get-Content $History -Raw | ConvertFrom-Json).devices) } else { @() }

$byGuid = @{}; foreach ($d in $present) { $byGuid[$d.guid.ToLower()] = $d }
# old GUID -> currently present device, via history (same physical device key)
$oldToNow = @{}
foreach ($h in $hist) {
  $now = $present | Where-Object { $_.historyKey -eq $h.key } | Select-Object -First 1
  if ($now) { foreach ($g in @($h.guids)) { if ($g -and $g.ToLower() -ne $now.guid.ToLower()) { $oldToNow[$g.ToLower()] = $now } } }
}
function Get-BindType([string]$bindName) {
  if ($bindName -match '^(?i)keyboard') { return 'Keyboard' }
  if ($bindName -match '^(?i)(Driving|Supplemental|Joystick|Gamepad|Flight|FirstPerson|Device)') { return $Matches[1] }
  return $null
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$summary = @{}; $unresolved = @{}; $filesChanged = 0; $bindsChanged = 0
foreach ($tp in $TeknoParrot) {
  foreach ($f in Get-ChildItem (Join-Path $tp 'UserProfiles') -Filter *.xml -File -ErrorAction SilentlyContinue) {
    $text = [IO.File]::ReadAllText($f.FullName); $changed = 0
    $new = [regex]::Replace($text, '(?s)<JoystickButtons>(?:(?!</JoystickButtons>).)*?<JoystickGuid>([0-9a-fA-F-]{36})</JoystickGuid>(?:(?!</JoystickButtons>).)*?</JoystickButtons>', {
        param($mt)
        $block = $mt.Value; $old = $mt.Groups[1].Value.ToLower()
        $bindName = ([regex]::Match($block, '<BindNameDi>([^<]*)</BindNameDi>')).Groups[1].Value
        $type = Get-BindType $bindName
        $target = $null; $why = $null
        if ($type -eq 'Keyboard') { if ($old -ne $SysKeyboard) { $target = $SysKeyboard; $why = 'keyboard bind -> SysKeyboard' } }
        elseif ($old -eq $SysKeyboard -or $old -eq $SysMouse) { }                          # system devices never move
        elseif ($byGuid.ContainsKey($old) -and (-not $type -or $byGuid[$old].type -eq $type)) { }   # already correct
        elseif ($oldToNow.ContainsKey($old)) { $target = $oldToNow[$old].guid; $why = "history: $($oldToNow[$old].name)" }
        elseif ($type) {
          $cands = @($present | Where-Object { $_.type -eq $type })
          if ($cands.Count -eq 1) { $target = $cands[0].guid; $why = "only present $type device: $($cands[0].name)" }
          else { $script:unresolved["$old ($type) - $($cands.Count) candidates"] = [int]$script:unresolved["$old ($type) - $($cands.Count) candidates"] + 1 }
        }
        else { $script:unresolved["$old (no type in '$bindName')"] = [int]$script:unresolved["$old (no type in '$bindName')"] + 1 }
        if ($target -and $target.ToLower() -ne $old) {
          $script:summary["$old -> $($target.ToLower())  [$why]"] = [int]$script:summary["$old -> $($target.ToLower())  [$why]"] + 1
          $script:changedHere++
          return $block -replace [regex]::Escape($mt.Groups[1].Value), $target
        }
        return $block
      })
    if ($new -ne $text) {
      $filesChanged++; $bindsChanged += ([regex]::Matches($text, '<JoystickGuid>').Count - 0)
      if ($Apply) { Copy-Item $f.FullName "$($f.FullName).ids-$stamp.bak"; [IO.File]::WriteAllText($f.FullName, $new, (New-Object Text.UTF8Encoding($false))) }
    }
  }
}
Write-Host ("{0}: {1} profile files would change" -f $(if ($Apply) { 'APPLIED' } else { 'DRY RUN' }), $filesChanged)
$summary.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { Write-Host ("  {0,4} x {1}" -f $_.Value, $_.Key) }
if ($unresolved.Count) { Write-Host 'left alone (device not connected / ambiguous):'; $unresolved.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { Write-Host ("  {0,4} x {1}" -f $_.Value, $_.Key) } }
if (-not $Apply -and $filesChanged) { Write-Host 're-run with -Apply to write (backups: <file>.ids-<timestamp>.bak)' }
