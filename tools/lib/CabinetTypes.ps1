<#
  ArcadeMaster cabinet types - what this machine IS, shown in the boot intro and the Tools menu.
  Set in RetroFE settings.conf:   cabinetType = auto | racing | flight | simulation | standup | lightgun | multicade | pedestal
  Combine with '+' for hybrid cabinets, e.g.  cabinetType = racing+lightgun  (wheel + handbrake + gun shooters).
  Optional:  cabinetTitle = <custom title>   cabinetTagline = <custom tagline>
  'auto' derives the type from manifest\cabinet.json (tools/Get-CabinetDevices.ps1).
#>
$script:AmCabinetTypes = [ordered]@{
  racing     = @{ title = 'RACING CABINET';      short = 'RACING';     icons = @('wheel', 'pedals');            color = 'ff2fa0'; verb = 'DRIVE';  tagline = 'START YOUR ENGINES' }
  flight     = @{ title = 'FLIGHT CABINET';      short = 'FLIGHT';     icons = @('plane', 'joystick');          color = '2ec8ff'; verb = 'FLY';    tagline = 'CLEARED FOR TAKEOFF' }
  simulation = @{ title = 'SIMULATION CABINET';  short = 'SIMULATION'; icons = @('wheel', 'shifter', 'pedals'); color = 'ffb000'; verb = 'SIMULATE'; tagline = 'FULL CONTROL' }
  standup    = @{ title = 'STAND-UP ARCADE';     short = 'STAND-UP';   icons = @('cabinet', 'buttons');         color = '2ec8ff'; verb = 'PLAY';   tagline = 'INSERT COIN' }
  lightgun   = @{ title = 'LIGHT GUN ARCADE';    short = 'LIGHT GUN';  icons = @('gun', 'crosshair');           color = 'ff5a5a'; verb = 'AIM - FIRE'; tagline = 'LOCK AND LOAD' }
  multicade  = @{ title = 'MULTICADE';           short = 'MULTICADE';  icons = @('buttons', 'trackball', 'gun'); color = '7b5cff'; verb = 'PLAY'; tagline = 'EVERY GAME - ONE CABINET' }
  pedestal   = @{ title = '4-PLAYER PEDESTAL';   short = '4-PLAYER';   icons = @('gamepad', 'buttons');         color = '3ddc84'; verb = 'TEAM UP'; tagline = 'PLAYERS 1 TO 4 READY' }
}

# what 'auto' means on this cabinet
function Get-AmAutoCabinetType($cab) {
  if (-not $cab) { return 'standup' }
  $k = $cab.capabilities; $parts = @()
  $wheel = [bool]$k.wheel; $gun = [int]$k.lightguns -gt 0; $stick = [bool]$k.flightStick
  if ($wheel -and ($k.hShifter -or $k.clutch) -and $stick) { $parts += 'simulation' }
  elseif ($wheel) { $parts += 'racing' }
  elseif ($stick) { $parts += 'flight' }
  if ($gun) { $parts += 'lightgun' }
  if (-not $parts) { $parts += $(if ([int]$k.players -ge 3) { 'pedestal' } elseif ($k.trackball) { 'multicade' } else { 'standup' }) }
  return ($parts -join '+')
}

# -> @{ id; parts; title; tagline; color; color2; icons }
function Resolve-AmCabinetType([string]$setting, $cab, [string]$customTitle, [string]$customTagline) {
  $id = if (-not $setting -or $setting -eq 'auto') { Get-AmAutoCabinetType $cab } else { $setting.ToLower() -replace '\s', '' }
  $parts = @($id -split '\+' | Where-Object { $script:AmCabinetTypes.Contains($_) })
  if (-not $parts) { $parts = @('standup') }
  $defs = @($parts | ForEach-Object { $script:AmCabinetTypes[$_] })
  if ($parts.Count -eq 1) { $title = $defs[0].title; $tag = $defs[0].tagline }
  else { $title = (($defs | ForEach-Object { $_.short }) -join ' + ') + ' CABINET'; $tag = ($defs | ForEach-Object { $_.verb }) -join ' - ' }
  # icons: union, at most 4; hybrid racing shows the handbrake when the cabinet really has one
  $icons = New-Object Collections.Generic.List[string]
  foreach ($d in $defs) { foreach ($i in $d.icons) { if (-not $icons.Contains($i)) { $icons.Add($i) } } }
  if ($parts -contains 'racing' -and $cab -and $cab.capabilities.handbrake -and $parts.Count -gt 1) { $icons.Remove('pedals') | Out-Null; $icons.Insert(1, 'handbrake') }
  if ($parts.Count -gt 1) { $icons = @($icons | Where-Object { $_ -ne 'crosshair' }) }
  return @{
    id = ($parts -join '+'); parts = $parts; auto = (-not $setting -or $setting -eq 'auto')
    title = $(if ($customTitle) { $customTitle.ToUpper() } else { $title }); tagline = $(if ($customTagline) { $customTagline.ToUpper() } else { $tag })
    color = $defs[0].color; color2 = $(if ($defs.Count -gt 1) { $defs[1].color } else { $defs[0].color }); icons = @($icons | Select-Object -First 4)
  }
}

# choices offered by the Tools picker (singles + the common hybrids)
function Get-AmCabinetChoices {
  @('auto') + @($script:AmCabinetTypes.Keys) + @('racing+lightgun', 'racing+flight', 'standup+lightgun')
}
