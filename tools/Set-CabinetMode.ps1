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
$follow = (Get-Setting 'cabinetFollowHardware') -notmatch '^(no|false|0)$'
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

$state = [ordered]@{ at = (Get-Date).ToString('s'); configured = $eff.configured; effective = $eff.id; switched = $eff.switched; reason = $eff.reason; followHardware = $follow; theme = (Get-Setting 'layout'); actions = $actions }
$state | ConvertTo-Json | Set-Content (Join-Path $ManifestDir 'cabinet-mode.json') -Encoding UTF8
Write-Host ("cabinet mode: {0}{1} - {2}" -f $eff.id, $(if ($eff.switched) { " (configured: $($eff.configured))" } else { '' }), $eff.reason)
$actions | ForEach-Object { Write-Host "  $_" }
