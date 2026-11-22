<#
.SYNOPSIS
  Materialises the per-collection theme slots for the ArcadeMaster layout.
  Reads layouts\ArcadeMaster\themes.json and writes
  <LayoutDir>\collections\<collection>\system_artwork\<slot>.png for every mapped collection
  (and any extra collection names passed with -Collections, which get the default theme).
#>
param(
  [string]$LayoutDir = (Join-Path $PSScriptRoot '..\layouts\ArcadeMaster'),
  [string[]]$Collections = @(),
  # optional RetroFE collections folder: every sub-folder found gets the default theme unless mapped
  [string]$CollectionsDir
)
$ErrorActionPreference = 'Stop'
$LayoutDir = (Resolve-Path $LayoutDir).Path
$cfg = Get-Content (Join-Path $LayoutDir 'themes.json') -Raw | ConvertFrom-Json
$map = @{}
foreach ($p in $cfg.collections.PSObject.Properties) { $map[$p.Name] = $p.Value }
if ($CollectionsDir -and (Test-Path $CollectionsDir)) { $Collections += (Get-ChildItem $CollectionsDir -Directory | Where-Object Name -ne '_common').Name }
foreach ($c in $Collections) { if (-not $map.ContainsKey($c)) { $map[$c] = $cfg.defaultTheme } }

foreach ($col in $map.Keys) {
  $themeName = $map[$col]
  $theme = $cfg.themes.$themeName
  if (-not $theme) { Write-Warning "collection '$col': unknown theme '$themeName'"; continue }
  $dst = Join-Path $LayoutDir "collections\$col\system_artwork"
  New-Item -ItemType Directory -Force $dst | Out-Null
  foreach ($slot in $theme.PSObject.Properties) {
    $src = Join-Path $LayoutDir "images\$($slot.Value)"
    if (-not (Test-Path $src)) { throw "missing art $src (run tools\New-LayoutArt.ps1)" }
    Copy-Item $src (Join-Path $dst "$($slot.Name).png") -Force
  }
  Write-Host ("{0,-20} -> {1}" -f $col, $themeName)
}
