<#
.SYNOPSIS
  Read-only check of every TeknoParrot game profile's wheel, pedal, paddle and gear bindings against the cabinet's
  Logitech G29 (DirectInput): steering X, gas Y, brake RotationZ, clutch Slider 0 (pedals: clutch LEFT, brake MIDDLE,
  gas RIGHT), right paddle = button 4 = shift up, left paddle = button 5 = shift down, H-shifter gears 1-6 = buttons
  12-17, reverse = button 18. Changes nothing; fixing is WheelMap's job (tools\wheelmap\WheelMap.ps1 -Apply).

  For each profile it lists:
    WRONG    a control bound to another G29 axis or button than the one above (gas on the brake pedal, paddles swapped)
    MISSING  steering, gas or brake not bound at all (the game can't be driven)
    KEYS     a driving control bound to the keyboard only
  Games that don't use a control (no clutch, no gears) are fine: only controls the profile lists are checked.
.EXAMPLE
  tools\Test-WheelBindings.ps1
  tools\Test-WheelBindings.ps1 -TeknoParrot 'E:\DRIVE Collection\emulators\TeknoParrot' -Csv D:\ArcadeMaster\manifest\wheel-bindings.csv
#>
param(
  [string[]]$TeknoParrot = @('D:\Emulators\TeknoParrot', 'E:\DRIVE Collection\emulators\TeknoParrot', 'E:\DRIVE Collection\emulators\TeknoParrotMulti'),
  [string]$Csv
)
$ErrorActionPreference = 'Stop'

# what each control should be bound to (BindNameDi without its "Driving " prefix); a pattern, since TeknoParrot writes
# the direction (+ / -) after the axis
$want = [ordered]@{
  'Steering'   = @{ match = '^(wheel axis|steering( wheel)?( axis)?|wheel|handle)$'; bind = '^X( [+-])?$'; text = 'X axis (wheel)'; must = $true }
  'Gas'        = @{ match = '^(gas|accelerat(e|or|ion)( pedal)?|throttle)$'; bind = '^Y( [+-])?$'; text = 'Y axis (gas, right pedal)'; must = $true }
  'Brake'      = @{ match = '^brake( pedal)?$'; bind = '^RotationZ( [+-])?$'; text = 'RotationZ (brake, middle pedal)'; must = $true }
  'Clutch'     = @{ match = '^clutch( pedal)?$'; bind = '^Sliders? ?0?( [+-])?$'; text = 'Slider 0 (clutch, left pedal)'; must = $false }
  'Shift Up'   = @{ match = '^(shift|gear)[ -]?up$'; bind = '^Buttons4$'; text = 'button 4 (right paddle)'; must = $false }
  'Shift Down' = @{ match = '^(shift|gear)[ -]?down$'; bind = '^Buttons5$'; text = 'button 5 (left paddle)'; must = $false }
}
for ($i = 1; $i -le 6; $i++) { $want["Gear $i"] = @{ match = "^(gear|shift(er)?) ?$i$"; bind = "^Buttons$(11 + $i)$"; text = "button $(11 + $i) (shifter $i)"; must = $false } }
# 4-speed games (Daytona) may put gears 3 and 4 on the shifter's far right (5 / 6), like the arcade's H pattern
$want['Gear 3'].bind = '^Buttons(14|16)$'; $want['Gear 4'].bind = '^Buttons(15|17)$'
$want['Gear 3'].text = 'button 14 or 16 (shifter 3, or 5 for a 4-speed)'; $want['Gear 4'].text = 'button 15 or 17 (shifter 4, or 6 for a 4-speed)'
$want['Reverse'] = @{ match = '^(gear )?(reverse|r)( gear)?$'; bind = '^Buttons18$'; text = 'button 18 (shifter R)'; must = $false }

$rows = New-Object System.Collections.Generic.List[object]
$profiles = 0
foreach ($tp in $TeknoParrot | Select-Object -Unique) {
  $dir = Join-Path $tp 'UserProfiles'
  if (-not (Test-Path -LiteralPath $dir)) { continue }
  foreach ($f in Get-ChildItem -LiteralPath $dir -Filter *.xml -File) {
    try { $x = [xml][IO.File]::ReadAllText($f.FullName) } catch { $rows.Add([pscustomobject]@{ Profile = $f.FullName; Game = $f.BaseName; Control = '-'; Status = 'UNREADABLE'; Bound = ''; Should = '' }); continue }
    $btns = @($x.SelectNodes('//JoystickButtons') | Where-Object { $_.ButtonName })
    $names = @($btns | ForEach-Object { $_.ButtonName.Trim().ToLower() })
    if (-not @($names | Where-Object { $_ -match $want['Steering'].match }).Count) { continue }   # not a driving game
    $profiles++
    foreach ($ctl in $want.Keys) {
      $w = $want[$ctl]
      $hits = @($btns | Where-Object { $_.ButtonName.Trim().ToLower() -match $w.match })
      if (-not $hits.Count) { continue }                                       # the game has no such control
      $b = $hits[0]
      $di = ([string]$b.BindNameDi).Trim() -replace '^Driving\s+', ''
      $kb = [string]$b.BindName
      $status = if ($di) { if ($di -match $w.bind -and ([string]$b.BindNameDi) -match '^Driving') { 'ok' } else { 'WRONG' } }
                elseif ($kb -and $kb -notmatch '^\s*$') { 'KEYS' }
                elseif ($w.must) { 'MISSING' } else { 'ok' }                    # an optional control left free is fine
      $rows.Add([pscustomobject]@{ Profile = $f.FullName; Game = $f.BaseName; Control = $ctl; Status = $status; Bound = $(if ($b.BindNameDi) { [string]$b.BindNameDi } else { $kb }); Should = $w.text })
    }
  }
}

$bad = @($rows | Where-Object Status -ne 'ok')
Write-Host ("{0} driving game profiles, {1} controls checked: {2} ok, {3} to look at" -f $profiles, $rows.Count, ($rows.Count - $bad.Count), $bad.Count)
foreach ($grp in $bad | Group-Object Profile) {
  Write-Host ("  {0}" -f $grp.Name)
  foreach ($r in $grp.Group) { Write-Host ("    {0,-8} {1,-11} bound to '{2}', should be {3}" -f $r.Status, $r.Control, $r.Bound, $r.Should) }
}
if ($Csv) { $rows | Export-Csv -NoTypeInformation -Encoding UTF8 $Csv; Write-Host "all rows: $Csv" }

# ---- what TeknoParrot's own, current definition of each game has that this cabinet's profile does not
# TeknoParrot ships GameProfiles\<game>.xml and keeps the cabinet's bindings in UserProfiles\<game>.xml. A TeknoParrot
# update can add a control to the first that the second never gets: Dirty Drivin' gained "Crank Forward" (it fires the
# guns), and both racing rigs had no button for it (James, 2026-11-27: "machine guns not working"). It can also move a
# game to another loader (OpenParrot -> TeknoParrot), which changed how Dirty Drivin' ran on one rig only. Both are
# listed here; they are information, not counted as faults above, because a control can be left out on purpose.
$notes = New-Object System.Collections.Generic.List[string]
foreach ($tp in $TeknoParrot | Select-Object -Unique) {
  $ud = Join-Path $tp 'UserProfiles'; $gd = Join-Path $tp 'GameProfiles'
  if (-not (Test-Path -LiteralPath $ud) -or -not (Test-Path -LiteralPath $gd)) { continue }
  foreach ($f in Get-ChildItem -LiteralPath $ud -Filter *.xml -File) {
    $gf = Join-Path $gd $f.Name; if (-not (Test-Path -LiteralPath $gf)) { continue }
    try { $u = [xml][IO.File]::ReadAllText($f.FullName); $g = [xml][IO.File]::ReadAllText($gf) } catch { continue }
    $un = @($u.SelectNodes('//JoystickButtons') | Where-Object { $_.ButtonName } | ForEach-Object { $_.ButtonName.Trim().ToLower() })
    if (-not @($un | Where-Object { $_ -match $want['Steering'].match }).Count) { continue }   # driving games only
    $new = @($g.SelectNodes('//JoystickButtons') | Where-Object { $_.ButtonName -and $un -notcontains $_.ButtonName.Trim().ToLower() } | ForEach-Object { $_.ButtonName.Trim() } |
             Where-Object { $_ -notmatch '(?i)^(wheel|steering|gas|brake|accelerat\w*|throttle|handle)\b.*\b(left|right|up|down|\+|-)$' })   # keyboard halves of an axis
    $ul = "$($u.GameProfile.EmulatorType)"; $gl = "$($g.GameProfile.EmulatorType)"
    $bits = @()
    if ($new) { $bits += "controls this cabinet's profile lacks: $($new -join ', ')" }
    if ($ul -and $gl -and $ul -ne $gl) { $bits += "loader here is $ul, TeknoParrot's current one is $gl" }
    if ($bits) { $notes.Add(("  {0,-18} {1}" -f $f.BaseName, ($bits -join '; '))) }
  }
}
if ($notes.Count) {
  Write-Host ("{0} game(s) differ from TeknoParrot's current definition (for information):" -f $notes.Count)
  $notes | ForEach-Object { Write-Host $_ }
}
