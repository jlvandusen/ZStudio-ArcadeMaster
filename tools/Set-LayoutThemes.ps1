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
  [string]$CollectionsDir,
  # deal a fresh random set of backgrounds into am_bg1..am_bgN (run at every boot for a new order)
  [switch]$Shuffle,
  [int]$BgSlots = 6,
  # only refresh background slots (fast path for boot)
  [switch]$BackgroundsOnly
)
$ErrorActionPreference = 'Stop'
$LayoutDir = (Resolve-Path $LayoutDir).Path
$cfg = Get-Content (Join-Path $LayoutDir 'themes.json') -Raw | ConvertFrom-Json
$map = @{}
foreach ($p in $cfg.collections.PSObject.Properties) { $map[$p.Name] = $p.Value }
if ($CollectionsDir -and (Test-Path $CollectionsDir)) { $Collections += (Get-ChildItem $CollectionsDir -Directory | Where-Object Name -ne '_common').Name }
foreach ($c in $Collections) { if (-not $map.ContainsKey($c)) { $map[$c] = $cfg.defaultTheme } }

$allBg = @($cfg.backgrounds.PSObject.Properties | Where-Object { $_.Name -notlike '_*' } | ForEach-Object { $_.Value } | Where-Object { $_ -ne '*' } | Sort-Object -Unique)
$rng = New-Object Random
function Get-BgPool([string]$col, [string]$themeName) {
  $key = if ($col -eq 'Main') { 'main' } else { $themeName }
  $pool = @($cfg.backgrounds.$key); if (-not $pool -or $pool -contains '*') { $pool = $allBg }
  return $pool
}

foreach ($col in $map.Keys) {
  $themeName = $map[$col]
  $theme = $cfg.themes.$themeName
  if (-not $theme) { Write-Warning "collection '$col': unknown theme '$themeName'"; continue }
  $dst = Join-Path $LayoutDir "collections\$col\system_artwork"
  New-Item -ItemType Directory -Force $dst | Out-Null
  if (-not $BackgroundsOnly) {
    foreach ($slot in $theme.PSObject.Properties) {
      $src = Join-Path $LayoutDir "images\$($slot.Value)"
      if (-not (Test-Path $src)) { throw "missing art $src (run tools\New-LayoutArt.ps1)" }
      Copy-Item $src (Join-Path $dst "$($slot.Name).png") -Force
    }
  }
  # rotating backdrop slots
  $pool = Get-BgPool $col $themeName
  if ($Shuffle) { $pool = @($pool | Sort-Object { $rng.Next() }) }
  for ($i = 1; $i -le $BgSlots; $i++) {
    $pick = $pool[($i - 1) % $pool.Count]
    $src = Join-Path $LayoutDir ("images\" + ($pick -replace '/', '\'))
    if (-not (Test-Path $src)) { throw "missing background $src (run tools\New-Backgrounds.ps1)" }
    Get-ChildItem $dst -Filter "am_bg$i.*" -ErrorAction SilentlyContinue | Remove-Item -Force   # slot may change extension
    Copy-Item $src (Join-Path $dst ("am_bg$i" + [IO.Path]::GetExtension($src))) -Force
  }
  Write-Host ("{0,-20} -> {1,-8} bg: {2}" -f $col, $themeName, (($pool | Select-Object -First $BgSlots | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) }) -join ', '))
}
