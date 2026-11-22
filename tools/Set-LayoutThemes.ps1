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

# Game fanart of a collection, following merged sub-collections (<name>.sub) and Main's menu entries.
function Get-CollectionFanart([string]$col, [int]$depth = 0, [hashtable]$seen = @{}) {
  if (-not $CollectionsDir -or $depth -gt 3 -or $seen.ContainsKey($col)) { return @() }
  $seen[$col] = $true
  $dir = Join-Path $CollectionsDir $col
  $files = @(Get-ChildItem (Join-Path $dir 'medium_artwork\fanart') -File -ErrorAction SilentlyContinue |
             Where-Object { $_.Extension -match '^\.(jpe?g|png)$' -and $_.BaseName -ne 'default' } | ForEach-Object { $_.FullName })
  $subs = @(Get-ChildItem $dir -Filter *.sub -File -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
  $menuTxt = Join-Path $dir 'menu.txt'
  if (Test-Path $menuTxt) { $subs += @(Get-Content $menuTxt | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() }) }
  $subs += @(Get-ChildItem (Join-Path $dir 'menu') -File -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
  foreach ($s in $subs | Sort-Object -Unique) { $files += Get-CollectionFanart $s ($depth + 1) $seen }
  return @($files | Sort-Object -Unique)
}

# Backdrop pool: the collection's own game fanart first; the generated scenes only if it has none.
function Get-BgPool([string]$col, [string]$themeName) {
  $fan = @(Get-CollectionFanart $col)
  if ($fan.Count -gt 0) { return $fan }
  $key = if ($col -eq 'Main') { 'main' } else { $themeName }
  $pool = @($cfg.backgrounds.$key); if (-not $pool -or $pool -contains '*') { $pool = $allBg }
  return @($pool | ForEach-Object { Join-Path $LayoutDir ("images\" + ($_ -replace '/', '\')) })
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
    $src = $pool[($i - 1) % $pool.Count]
    if (-not (Test-Path -LiteralPath $src)) { throw "missing background $src" }
    Get-ChildItem $dst -Filter "am_bg$i.*" -ErrorAction SilentlyContinue | Remove-Item -Force   # slot may change extension
    Copy-Item -LiteralPath $src (Join-Path $dst ("am_bg$i" + [IO.Path]::GetExtension($src).ToLower())) -Force
  }
  Write-Host ("{0,-20} -> {1,-8} bg: {2}" -f $col, $themeName, (($pool | Select-Object -First $BgSlots | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) }) -join ', '))
}
