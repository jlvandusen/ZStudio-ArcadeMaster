<#
.SYNOPSIS
  Makes the arcade flight games (After Burner Climax, MachStorm, Star Wars Battle Pod) playable on a racing cabinet
  with no flight stick: wheel = bank / turn, right / left paddle = nose up / down, gas pedal = throttle, brake pedal = air
  brake, face buttons = guns / missiles, the wheel's start button = Start. Only TeknoParrot controls with NOTHING bound are
  filled in; a cabinet with a real stick keeps its own bindings.
  The bindings are copied from a driving game that already works on this wheel in the same TeknoParrot (Daytona3 by
  default): same device, same axes and buttons, so nothing is guessed. Dry run by default; -Apply backs up each profile
  to <profile>.am-flight-<time>.bak first.
.EXAMPLE
  tools\Set-FlightOnWheel.ps1
  tools\Set-FlightOnWheel.ps1 -Apply
#>
param(
  [string[]]$TeknoParrot = @('D:\Emulators\TeknoParrot', 'E:\DRIVE Collection\emulators\TeknoParrot'),
  [string]$Template = 'Daytona3',
  [switch]$Apply
)
$ErrorActionPreference = 'Stop'
# flight control (TeknoParrot ButtonName) -> the template's control that has the right wheel binding
$map = [ordered]@{
  'Joystick Analog X' = 'Wheel Axis'; 'Analog X' = 'Wheel Axis'
  'Joystick Analog Y Up' = 'Shift Up'; 'Analog Y Up' = 'Shift Up'; 'Joystick Analog Y Down' = 'Shift Down'; 'Analog Y Down' = 'Shift Down'
  'Throttle Lever' = 'Gas'; 'Throttle' = 'Gas'; 'Throttle Brake' = 'Brake'
  'Gun Trigger' = 'View Change 1'; 'Machine Gun' = 'View Change 1'; 'Weapon Trigger' = 'View Change 1'
  'Missile Trigger' = 'View Change 2'; 'Missile' = 'View Change 2'; 'Weapon Button' = 'View Change 2'
  'Climax Switch' = 'View Change 3'; 'Enter Switch' = 'View Change 3'; 'View Change' = 'View Change 4'
  'Start' = 'Start'; 'Coin 1' = 'View Change 4'; 'Service/Coin' = 'View Change 4'
}
$games = 'abc', 'MS', 'StarWars'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
foreach ($tp in $TeknoParrot) {
  $up = Join-Path $tp 'UserProfiles'
  $tf = Join-Path $up "$Template.xml"
  if (-not (Test-Path -LiteralPath $tf)) { continue }
  $tx = [xml][IO.File]::ReadAllText($tf)
  $tmpl = @{}; foreach ($n in $tx.SelectNodes('//JoystickButtons')) { if ($n.BindNameDi -and $n.DirectInputButton) { $tmpl[[string]$n.ButtonName] = $n } }
  if (-not $tmpl.ContainsKey('Wheel Axis')) { Write-Host "$tf has no wheel binding - skipped"; continue }
  foreach ($g in $games) {
    $f = Join-Path $up "$g.xml"; if (-not (Test-Path -LiteralPath $f)) { continue }
    $x = [xml][IO.File]::ReadAllText($f)
    $done = @()
    foreach ($n in $x.SelectNodes('//JoystickButtons')) {
      $name = [string]$n.ButtonName
      if (-not $map.Contains($name) -or "$($n.BindNameDi)$($n.BindName)".Trim()) { continue }   # unknown, or already bound
      $t = $tmpl[$map[$name]]; if (-not $t) { continue }
      $di = $x.ImportNode($t.DirectInputButton, $true)
      if ($n.DirectInputButton) { [void]$n.ReplaceChild($di, $n.DirectInputButton) } else { [void]$n.AppendChild($di) }
      foreach ($tag in 'BindNameDi', 'BindName') {
        $e = $n.SelectSingleNode($tag); if (-not $e) { $e = $x.CreateElement($tag); [void]$n.AppendChild($e) }
        $e.InnerText = [string]$t.$tag
      }
      $done += "$name <- $($t.BindNameDi)"
    }
    if (-not $done) { Write-Host "$g ($tp): nothing to add (already bound)"; continue }
    Write-Host ("{0} {1} ({2}): {3}" -f $(if ($Apply) { 'BOUND' } else { 'WOULD BIND' }), $g, $tp, ($done -join '; '))
    if ($Apply) {
      Copy-Item -LiteralPath $f "$f.am-flight-$stamp.bak"
      $s = New-Object Xml.XmlWriterSettings; $s.Indent = $true; $s.Encoding = New-Object Text.UTF8Encoding($false)
      $w = [Xml.XmlWriter]::Create($f, $s); $x.Save($w); $w.Close()
    }
  }
}
