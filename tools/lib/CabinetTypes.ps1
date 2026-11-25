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
  elseif ($wheel) { $parts += 'racing'; if ($stick) { $parts += 'flight' } }
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

# ---------------------------------------------------------------- hardware-following cabinet mode
# What each type needs physically. A configured type whose hardware is present stays; one whose hardware is gone is
# dropped and the cabinet follows what IS plugged in (a flight stick instead of the wheel -> flight cab).
$script:AmTypeNeeds = @{
  racing = { param($k) [bool]$k.wheel }
  simulation = { param($k) [bool]$k.wheel }
  flight = { param($k) [bool]$k.flightStick }
  lightgun = { param($k) [int]$k.lightguns -gt 0 }
  standup = { param($k) $true }; multicade = { param($k) $true }; pedestal = { param($k) $true }
}
# -> @{ id; configured; switched; reason }
function Get-AmEffectiveCabinetType([string]$setting, $cab, [bool]$follow = $true) {
  $configured = if (-not $setting) { 'auto' } else { $setting.ToLower() -replace '\s', '' }
  if ($configured -eq 'auto' -or -not $cab) { $id = Get-AmAutoCabinetType $cab; return @{ id = $id; configured = $configured; switched = $false; reason = 'auto: detected hardware' } }
  if (-not $follow) { return @{ id = $configured; configured = $configured; switched = $false; reason = 'fixed (cabinetFollowHardware = no)' } }
  $k = $cab.capabilities
  $parts = @($configured -split '\+' | Where-Object { $script:AmCabinetTypes.Contains($_) })
  $keep = @($parts | Where-Object { & $script:AmTypeNeeds[$_] $k })
  $missing = @($parts | Where-Object { $keep -notcontains $_ })
  if (-not $missing) { return @{ id = ($parts -join '+'); configured = $configured; switched = $false; reason = 'configured type - its controls are connected' } }
  $id = if ($keep) { $keep -join '+' } else { Get-AmAutoCabinetType $cab }
  return @{ id = $id; configured = $configured; switched = $true; reason = "$($missing -join ' + ') controls not connected -> $id (from what is plugged in)" }
}
# collection that should open first for a type (first one that exists)
function Get-AmTypeCollection([string]$id) { @{ racing = 'Racing'; simulation = 'Racing'; flight = 'Flight'; lightgun = 'Lightgun'; standup = 'Arcade'; multicade = 'GAMES'; pedestal = 'Arcade' }[($id -split '\+')[0]] }
# main-menu collections that belong to each mode (everything else in the menu - Settings, Tools, GAMES... - always stays)
$script:AmModeCollections = @{ racing = @('Racing'); simulation = @('Racing', 'Flight'); flight = @('Flight'); lightgun = @('Lightgun'); standup = @('Arcade'); pedestal = @('Arcade'); multicade = @('Racing', 'Flight', 'Lightgun', 'Arcade') }
function Get-AmModeCollectionsFor([string]$id) { @($id -split '\+' | ForEach-Object { $script:AmModeCollections[$_] } | Select-Object -Unique) }
function Get-AmAllModeCollections { @($script:AmModeCollections.Values | ForEach-Object { $_ } | Select-Object -Unique) }
# The boot intro card (New-CabinetIntro.ps1) for a frontend: which cabinet type, title, tagline, icons and colours, plus
# a key that changes whenever anything that shapes the card changes (the settings, the hardware, the drawing scripts).
# Start-ArcadeMaster compares the key with the one the last render wrote into intro.txt and skips the render (a whole
# PowerShell start + the C# drawing helpers, ~2 s) when nothing changed.
function Get-AmIntroSpec([string]$RetroFE, [string]$ManifestDir, [string]$Type) {
  $get = { param($k) $m = Select-String -Path (Join-Path $RetroFE 'settings.conf') -Pattern "^\s*$([regex]::Escape($k))\s*=\s*(.*)$" -ErrorAction SilentlyContinue | Select-Object -Last 1; if ($m) { $m.Matches[0].Groups[1].Value.Trim() } }
  $cab = $null; $cf = Join-Path $ManifestDir 'cabinet.json'; if (Test-Path $cf) { $cab = Get-Content $cf -Raw | ConvertFrom-Json }
  $setting = if ($Type) { $Type } else { & $get 'cabinetType' }
  $follow = (& $get 'cabinetFollowHardware') -notmatch '^(no|false|0)$'
  $eff = if ($Type) { @{ id = $Type; switched = $false } } else { Get-AmEffectiveCabinetType $setting $cab $follow }
  # a custom title belongs to the configured type - not shown when the cabinet switched to another mode
  $ct = Resolve-AmCabinetType $eff.id $cab $(if ($eff.switched) { '' } else { & $get 'cabinetTitle' }) $(if ($eff.switched) { '' } else { & $get 'cabinetTagline' })
  if ($eff.switched) { $ct.auto = $false }
  $sha = [Security.Cryptography.SHA1]::Create()
  $code = foreach ($f in @((Join-Path $PSScriptRoot 'AmVisual.ps1'), (Join-Path (Split-Path $PSScriptRoot) 'New-CabinetIntro.ps1'))) { if (Test-Path $f) { [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($f))) } }
  $key = (@($ct.id, $setting, $ct.title, $ct.tagline, ($ct.icons -join ','), $ct.color, $ct.color2, @($ct.parts).Count) + $code) -join '|'
  @{ ct = $ct; setting = $setting; key = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key))).Replace('-', '') }
}

# true when the intro images in $OutDir were drawn for this exact spec (intro.txt key=, every image present)
function Test-AmIntroCurrent([string]$OutDir, $spec) {
  $txt = Join-Path $OutDir 'intro.txt'
  if (-not (Test-Path $txt)) { return $false }
  foreach ($n in 'intro_glow.png', 'intro_icons.png', 'intro_title.png', 'intro_line.png', 'intro_tagline.png') { if (-not (Test-Path (Join-Path $OutDir $n))) { return $false } }
  [bool](Select-String -Path $txt -Pattern "^key=$($spec.key)$" -Quiet)
}