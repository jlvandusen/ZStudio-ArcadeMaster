<#
.SYNOPSIS
  Boot-time cabinet mode: the configured type follows the hardware that is plugged in.
    settings.conf  cabinetType = racing           what this cabinet normally is (auto = from the hardware)
                   cabinetFollowHardware = yes    (default) racing stays racing while a wheel is connected;
                                                  wheel gone + flight stick connected -> flight cab, etc.
                   cabinetTheme.racing = ArcadeMaster     optional theme (layout) per mode
                   cabinetTheme.flight = CO-DRIVE
  Applies the effective mode: switches the layout when the mode has its own theme, moves the mode's collection
  (Racing / Flight / Lightgun / Arcade) to the top of the main menu so the cabinet opens on it, and records
  the decision in <ManifestDir>\cabinet-mode.json. The boot intro (New-CabinetIntro) shows the effective type.
#>
param(
  [string]$RetroFE = 'D:\ArcadeMaster\frontend\DRIVE-coinops',
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\CabinetTypes.ps1')
$sc = Join-Path $RetroFE 'settings.conf'
function Get-Setting([string]$key) { $m = Select-String -Path $sc -Pattern "^\s*$([regex]::Escape($key))\s*=\s*(.*)$" -ErrorAction SilentlyContinue | Select-Object -Last 1; if ($m) { $m.Matches[0].Groups[1].Value.Trim() } }
function Set-Setting([string]$key, [string]$value) {
  $lines = [Collections.Generic.List[string]](Get-Content $sc); $done = $false
  for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match "^\s*$([regex]::Escape($key))\s*=") { $lines[$i] = "$key = $value"; $done = $true } }
  if (-not $done) { $lines.Add("$key = $value") }; Set-Content $sc $lines -Encoding ascii
}
$cab = $null; $cf = Join-Path $ManifestDir 'cabinet.json'; if (Test-Path $cf) { $cab = Get-Content $cf -Raw | ConvertFrom-Json }
$follow = "$(Get-Setting 'cabinetFollowHardware')" -notmatch '^(no|false|0)$'   # "$()": a missing line must read as yes, not an empty array
$eff = Get-AmEffectiveCabinetType (Get-Setting 'cabinetType') $cab $follow
$primary = ($eff.id -split '\+')[0]
$actions = @()

# theme for this mode
$theme = Get-Setting "cabinetTheme.$primary"; if (-not $theme) { $theme = Get-Setting "cabinetTheme.$($eff.id)" }
if ($theme) {
  if (Test-Path (Join-Path $RetroFE "layouts\$theme\layout.xml")) { if ((Get-Setting 'layout') -ne $theme) { Set-Setting 'layout' $theme; $actions += "theme -> $theme" } }
  else { $actions += "WARNING: cabinetTheme.$primary = $theme is not installed - theme unchanged" }
}

# only the modes whose controls are plugged in appear in the main menu (cabinetShowAllModes = yes shows all).
# The full list is kept in <ManifestDir>\main-menu-full.txt so hidden entries come back when their controller does.
$mt0 = Join-Path $RetroFE 'collections\Main\menu.txt'; $fullFile = Join-Path $ManifestDir 'main-menu-full.txt'
if (Test-Path $mt0) {
  $cur = @(Get-Content $mt0 | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
  $saved = @(); if (Test-Path $fullFile) { $saved = @(Get-Content $fullFile | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() }) }
  $full = @($saved | Where-Object { Test-Path (Join-Path $RetroFE "collections\$_") }); foreach ($c in $cur) { if ($full -notcontains $c) { $full += $c } }
  # retired entries: SETTINGS was the old DRIVE controller switcher - picking G29 / G920 / Xbox there copied old
  # emulator configs over the WheelMap ones (gas on the clutch again). Tools replaces it. Its files are kept.
  $full = @($full | Where-Object { $_ -notin 'SETTINGS' })
  # the maker menus (Nintendo, Sega ...: Import-RetroBatSystems.py, marked am-retrobat.txt) replace the build's own system
  # lists on the main menu; an old CONSOLES kept in the saved list came back at every start (2P stand-up, 2026-11-28)
  $makers = @(Get-ChildItem (Join-Path $RetroFE 'collections') -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'am-retrobat.txt') })
  if ($makers) { $full = @($full | Where-Object { $_ -notin 'CONSOLES', 'HANDHELDS', 'COMPUTERS' }) }
  if ($full -contains 'Tools') { $full = @($full | Where-Object { $_ -ne 'Tools' }) + @('Tools') }   # Tools stays last
  Set-Content $fullFile $full -Encoding ascii
  $showAll = (Get-Setting 'cabinetShowAllModes') -match '^(yes|true|1)$'
  $modeCols = Get-AmAllModeCollections; $want = Get-AmModeCollectionsFor $eff.id
  $visible = @($full | Where-Object { $showAll -or $modeCols -notcontains $_ -or $want -contains $_ })
  if (($visible -join '|') -ne ($cur -join '|')) {
    Set-Content $mt0 $visible -Encoding ascii
    $hidden = @($full | Where-Object { $visible -notcontains $_ })
    $actions += "main menu: $($visible -join ', ')$(if ($hidden) { "  (hidden until their controls are plugged in: $($hidden -join ', '))" })"
  }
}

# open on the mode's collection: move it to the top of the main menu
$col = Get-AmTypeCollection $eff.id
$mt = Join-Path $RetroFE 'collections\Main\menu.txt'
if ($col -and (Test-Path $mt) -and (Test-Path (Join-Path $RetroFE "collections\$col"))) {
  $menu = @(Get-Content $mt | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
  if ($menu -contains $col -and $menu[0] -ne $col) { Set-Content $mt (@($col) + @($menu | Where-Object { $_ -ne $col })) -Encoding ascii; $actions += "main menu opens on $col" }
}

# the frontend's settings for this kind of cabinet (docs/21 phase 3): catalog\frontend-settings\common.conf, then one
# file per part of the type (racing+flight -> racing.conf, flight.conf), written to <RetroFE>\settings8.conf. RetroFE
# reads settings1-15.conf on top of settings.conf. A key the cabinet's own settings files set is left out, so a choice
# made on the cabinet (Cabinet Settings, a test) always wins over the type's default. cabinetTypeEffective tells the
# frontend and its layouts what this cabinet is today.
$profDir = Join-Path (Split-Path $PSScriptRoot) 'catalog\frontend-settings'
if (Test-Path $profDir) {
  $p8 = Join-Path $RetroFE 'settings8.conf'; $mark = '# made at every start by tools\Set-CabinetMode.ps1'
  $ours = -not (Test-Path $p8) -or ([IO.File]::ReadAllText($p8)).StartsWith($mark)
  # the cabinet's own keys: settings.conf and any other numbered settings file (CoinOPS builds ship settings5.conf ...)
  $own = @{}
  foreach ($f in @(Get-ChildItem $RetroFE -File -Filter 'settings*.conf' | Where-Object { $_.Name -match '^settings\d*\.conf$' -and $_.Name -ne 'settings8.conf' })) {
    foreach ($l in (Get-Content $f.FullName -ErrorAction SilentlyContinue)) { if ($l -match '^\s*([^#=\s][^=]*?)\s*=') { $own[$Matches[1].Trim().ToLower()] = $true } }
  }
  $prof = [ordered]@{}; $from = @()
  foreach ($part in @('common') + @($eff.id -split '\+')) {
    $f = Join-Path $profDir "$part.conf"; if (-not (Test-Path $f)) { continue }; $from += "$part.conf"
    foreach ($l in (Get-Content $f)) { if ($l -match '^\s*([^#=\s][^=]*?)\s*=\s*(.*)$') { $prof[$Matches[1].Trim()] = $Matches[2].Trim() } }
  }
  $prof['cabinetTypeEffective'] = $eff.id
  $out = @("$mark from catalog\frontend-settings ($($from -join ', ')) for a $($eff.id) cabinet.",
    '# Do not edit here: change the catalog file (every cabinet of the type), or set the key in settings.conf (this cabinet only).')
  $skipped = @()
  foreach ($k in $prof.Keys) { if ($own.ContainsKey($k.ToLower()) -and $k -ne 'cabinetTypeEffective') { $skipped += $k; continue }; $out += "$k = $($prof[$k])" }
  $old = if (Test-Path $p8) { [IO.File]::ReadAllText($p8) } else { '' }
  $new = ($out -join "`r`n") + "`r`n"
  if (-not $ours) { $actions += "WARNING: $p8 is not ours (a CoinOPS file?) - left alone, no type settings applied" }
  elseif ($new -ne $old) { [IO.File]::WriteAllText($p8, $new, (New-Object Text.UTF8Encoding $false)); $actions += "frontend settings for $($eff.id): settings8.conf from $($from -join ', ')$(if ($skipped) { " (this cabinet's own: $($skipped -join ', '))" })" }
}

$state = [ordered]@{ at = (Get-Date).ToString('s'); configured = $eff.configured; effective = $eff.id; switched = $eff.switched; reason = $eff.reason; followHardware = $follow; theme = (Get-Setting 'layout'); actions = $actions }
$state | ConvertTo-Json | Set-Content (Join-Path $ManifestDir 'cabinet-mode.json') -Encoding UTF8
Write-Host ("cabinet mode: {0}{1} - {2}" -f $eff.id, $(if ($eff.switched) { " (configured: $($eff.configured))" } else { '' }), $eff.reason)
$actions | ForEach-Object { Write-Host "  $_" }
