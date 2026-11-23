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
  [switch]$BackgroundsOnly,
  # manifest folder: its cabinet-mode.json decides what "auto" (and unmapped collections) look like
  [string]$ManifestDir,
  # force the cabinet style instead (racing | flight | lightgun | arcade)
  [string]$CabinetTheme
)
$ErrorActionPreference = 'Stop'
$LayoutDir = (Resolve-Path $LayoutDir).Path
$cfg = Get-Content (Join-Path $LayoutDir 'themes.json') -Raw | ConvertFrom-Json

# a style is usable when all its slot images exist (a cabinet that has not run New-LayoutArt for a new style keeps working)
function Test-Theme([string]$t) { $th = $cfg.themes.$t; if (-not $th) { return $false }; foreach ($s in $th.PSObject.Properties) { if (-not (Test-Path (Join-Path $LayoutDir "images\$($s.Value)"))) { return $false } }; return $true }
# the cabinet's own style: its effective mode (Set-CabinetMode -> cabinet-mode.json). Wheel cabinets look racing,
# flight cabinets flight, gun cabinets lightgun, everything else (pedestal, stand-up, multicade) arcade.
if (-not $CabinetTheme -and $ManifestDir) {
  $mf = Join-Path $ManifestDir 'cabinet-mode.json'
  if (Test-Path $mf) {
    $mode = (((Get-Content $mf -Raw | ConvertFrom-Json).effective) -split '\+')[0]
    $CabinetTheme = @{ racing = 'racing'; simulation = 'racing'; flight = 'flight'; lightgun = 'lightgun'; standup = 'arcade'; multicade = 'arcade'; pedestal = 'arcade' }[$mode]
  }
}
if (-not $CabinetTheme) { $CabinetTheme = $cfg.defaultTheme }
if (-not (Test-Theme $CabinetTheme)) { Write-Warning "style '$CabinetTheme' has no art yet (run tools\New-LayoutArt.ps1) - using '$($cfg.defaultTheme)'"; $CabinetTheme = $cfg.defaultTheme }
# the boot path refreshes only backdrops; when the cabinet's style changed (a wheel plugged in, a new cabinet type),
# copy the slot art as well, once
$styleFile = if ($ManifestDir) { Join-Path $ManifestDir 'layout-style.txt' } else { $null }
# the cabinet's real wheel (New-RealWheelArt: G HUB's picture of the detected wheel) replaces the drawn one in its slot
$realWheel = Join-Path $LayoutDir 'images\racing_wheel_real.png'
# skins (New-ThemeSkins): the look chosen for each family in Tools > Themes, manifest\skins.json { "racing": "racing-rally",
# "flight": "random" }. "random" deals a different skin of that family at every start. Collections themed "racing" or
# "flight" (and "auto" on such a cabinet) get the chosen skin; every skin uses the same slots, so it costs nothing extra.
$skinOf = @{}
$skinFile = if ($ManifestDir) { Join-Path $ManifestDir 'skins.json' } else { $null }
if ($skinFile -and (Test-Path $skinFile) -and $cfg.PSObject.Properties['skins']) {
  $pick = Get-Content $skinFile -Raw | ConvertFrom-Json
  foreach ($fam in $cfg.skins.PSObject.Properties.Name) {
    $want = [string]$pick.$fam; if (-not $want -or $want -eq $fam) { continue }
    $all = @($cfg.skins.$fam.PSObject.Properties.Name | Where-Object { Test-Theme $_ })
    if ($want -eq 'random') { if ($all.Count) { $skinOf[$fam] = $all[(New-Object Random).Next(0, $all.Count)] } }
    elseif ($all -contains $want) { $skinOf[$fam] = $want }
  }
}
function Resolve-Skin([string]$t) { if ($skinOf.ContainsKey($t)) { $skinOf[$t] } else { $t } }
$styleKey = (Resolve-Skin $CabinetTheme) + $(if ($skinOf.Count) { '|' + (($skinOf.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ',') } else { '' }) + $(if (Test-Path $realWheel) { "+realwheel2:$((Get-Item $realWheel).LastWriteTimeUtc.Ticks)" } else { '+slots2' })   # bump the number when the slot set changes: every cabinet refreshes once
if ($skinOf.Count) { Write-Host ("skins: " + (($skinOf.GetEnumerator() | ForEach-Object { "$($_.Name) -> $($_.Value)" }) -join ', ')) }
if ($BackgroundsOnly -and $styleFile) {
  $last = if (Test-Path $styleFile) { (Get-Content $styleFile -Raw).Trim() } else { '' }
  if ($last -ne $styleKey) { Write-Host "cabinet style '$last' -> '$styleKey': refreshing the slot art"; $BackgroundsOnly = $false }
}

$map = @{}
foreach ($p in $cfg.collections.PSObject.Properties) { $map[$p.Name] = if ($p.Value -eq 'auto') { $CabinetTheme } else { $p.Value } }
if ($CollectionsDir -and (Test-Path $CollectionsDir)) { $Collections += (Get-ChildItem $CollectionsDir -Directory | Where-Object Name -ne '_common').Name }
foreach ($c in $Collections) { if (-not $map.ContainsKey($c)) { $map[$c] = $CabinetTheme } }

# backdrop lists may use wildcards (bg/arcade_*.jpg)
function Expand-Bg([object[]]$list) {
  @($list | ForEach-Object {
    if ($_ -ne '*' -and $_ -match '[*?]') {
      $rel = $_ -replace '/', '\'; $dirRel = Split-Path $rel
      Get-ChildItem (Join-Path $LayoutDir "images\$dirRel") -Filter (Split-Path $rel -Leaf) -File -ErrorAction SilentlyContinue | ForEach-Object { "$dirRel\$($_.Name)" }
    } else { $_ } })
}
foreach ($p in @($cfg.backgrounds.PSObject.Properties | Where-Object { $_.Name -notlike '_*' })) { $p.Value = @(Expand-Bg $p.Value) }
$allBg = @($cfg.backgrounds.PSObject.Properties | Where-Object { $_.Name -notlike '_*' } | ForEach-Object { $_.Value } | Where-Object { $_ -ne '*' } | Sort-Object -Unique)
$rng = New-Object Random

# Game fanart of a collection, following merged sub-collections (<name>.sub) and Main's menu entries.
function Get-CollectionFanart([string]$col, [int]$depth = 0, [hashtable]$seen = @{}, [string[]]$only = $null) {
  if (-not $CollectionsDir -or $depth -gt 3) { return @() }
  $key = "$col|$($only -join ',')"; if ($seen.ContainsKey($key)) { return @() }; $seen[$key] = $true
  $dir = Join-Path $CollectionsDir $col
  $files = @(Get-ChildItem (Join-Path $dir 'medium_artwork\fanart') -File -ErrorAction SilentlyContinue |
             Where-Object { $_.Extension -match '^\.(jpe?g|png)$' -and $_.BaseName -ne 'default' -and (-not $only -or $only -contains $_.BaseName) } |
             ForEach-Object { $_.FullName })
  # merged collections: a .sub that LISTS items means "only these games"; an empty .sub means "the whole collection"
  foreach ($sf in Get-ChildItem $dir -Filter *.sub -File -ErrorAction SilentlyContinue) {
    $list = @(Get-Content $sf.FullName | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $files += Get-CollectionFanart $sf.BaseName ($depth + 1) $seen ($(if ($list.Count) { $list } else { $null }))
  }
  $menus = @()
  $menuTxt = Join-Path $dir 'menu.txt'
  if (Test-Path $menuTxt) { $menus += @(Get-Content $menuTxt | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() }) }
  $menus += @(Get-ChildItem (Join-Path $dir 'menu') -File -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
  foreach ($s in $menus | Sort-Object -Unique) { $files += Get-CollectionFanart $s ($depth + 1) $seen }
  return @($files | Sort-Object -Unique)
}

# Backdrop pool: the collection's own game fanart first; the generated scenes only if it has none.
function Get-BgPool([string]$col, [string]$themeName) {
  $fan = @(Get-CollectionFanart $col)
  if ($fan.Count -gt 0) { return $fan }
  $key = if ($col -eq 'Main') { 'main' } else { ($themeName -split '-')[0] }   # a skin (racing-rally) uses its family's scenes
  $pool = @($cfg.backgrounds.$key); if ($pool -contains '*') { $pool = @($cfg.backgrounds.$CabinetTheme) }   # main menu: the cabinet's own scenes
  if (-not $pool -or $pool -contains '*') { $pool = $allBg }
  return @($pool | ForEach-Object { Join-Path $LayoutDir ("images\" + ($_ -replace '/', '\')) })
}

foreach ($col in $map.Keys) {
  $themeName = Resolve-Skin $map[$col]
  if (-not (Test-Theme $themeName)) { $themeName = Resolve-Skin $CabinetTheme }
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
    # the real wheel has its own element (am_realwheel: no decorative swing, turns only with the wheel, straight up at
    # centre). Every racing skin shows it when the cabinet has one, and its decorative am_spinner is left empty.
    $useReal = $themeName -like 'racing*' -and (Test-Path $realWheel)
    Copy-Item $(if ($useReal) { $realWheel } else { Join-Path $LayoutDir 'images\blank.png' }) (Join-Path $dst 'am_realwheel.png') -Force
    if ($useReal) { Copy-Item (Join-Path $LayoutDir 'images\blank.png') (Join-Path $dst 'am_spinner.png') -Force }
  }
  # rotating backdrop slots
  $pool = @(Get-BgPool $col $themeName)   # @(): a one-fanart collection would otherwise unroll to a string
  if ($Shuffle) { $pool = @($pool | Sort-Object { $rng.Next() }) }
  for ($i = 1; $i -le $BgSlots; $i++) {
    $src = $pool[($i - 1) % $pool.Count]
    if (-not (Test-Path -LiteralPath $src)) { throw "missing background $src" }
    Get-ChildItem $dst -Filter "am_bg$i.*" -ErrorAction SilentlyContinue | Remove-Item -Force   # slot may change extension
    Copy-Item -LiteralPath $src (Join-Path $dst ("am_bg$i" + [IO.Path]::GetExtension($src).ToLower())) -Force
  }
  Write-Host ("{0,-20} -> {1,-8} bg: {2}" -f $col, $themeName, (($pool | Select-Object -First $BgSlots | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) }) -join ', '))
}
if ($styleFile -and -not $BackgroundsOnly) { Set-Content $styleFile $styleKey -Encoding ascii }
