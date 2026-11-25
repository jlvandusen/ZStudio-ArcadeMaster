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
# CreateHardLink, compiled once into a cached DLL (Add-Type compiling C# costs ~0.7 s at every boot; loading the DLL ~0)
$script:canLink = $false
try {
  if (-not ('AmNative.Link' -as [type])) {
    $dll = Join-Path $env:LOCALAPPDATA 'ArcadeMaster\AmNative.Link.v1.dll'
    if (-not (Test-Path $dll)) {
      New-Item -ItemType Directory -Force (Split-Path $dll) | Out-Null
      Add-Type -Namespace AmNative -Name Link -OutputAssembly $dll -MemberDefinition '[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool CreateHardLink(string lpFileName, string lpExistingFileName, IntPtr lpSecurityAttributes);'
    }
    Add-Type -Path $dll
  }
  $script:canLink = $true
} catch { Write-Warning "hard links unavailable, copying instead: $($_.Exception.Message)" }

$script:lowRes = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
if ($ManifestDir -and (Test-Path (Join-Path $ManifestDir 'lowres-art.txt'))) { foreach ($l in [IO.File]::ReadAllLines((Join-Path $ManifestDir 'lowres-art.txt'))) { if ($l) { [void]$script:lowRes.Add($l) } } }

# in-place Fisher-Yates shuffle: Sort-Object { $rng.Next() } on the library's thousands of pictures, once per menu, was
# most of the boot "Shuffle" time
# Only $k random picks are needed (a few slots, with room for repeats of one game), so only $k swaps are made.
function Get-Shuffled([object[]]$a, [int]$k = 48) {
  $a = [object[]]$a.Clone(); $n = $a.Count; if ($n -le 1) { return ,$a }
  $k = [Math]::Min($k, $n - 1)
  for ($i = $n - 1; $i -ge $n - $k; $i--) { $j = $rng.Next($i + 1); $t = $a[$i]; $a[$i] = $a[$j]; $a[$j] = $t }
  ,$a[($n - $k)..($n - 1)]
}
# a few pictures of DIFFERENT games (a game's fanart and its backdrop are both in the pool - never the same game twice)
function Select-Distinct([object[]]$a, [int]$n) {
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase); $out = New-Object System.Collections.Generic.List[string]
  foreach ($p in $a) { if ($seen.Add(([IO.Path]::GetFileNameWithoutExtension($p) -replace '-\d+$', ''))) { $out.Add($p); if ($out.Count -ge $n) { break } } }
  if ($out.Count -eq 0) { return ,@($a) }
  ,$out.ToArray()
}

# Game fanart of a collection, following merged sub-collections (<name>.sub) and Main's menu entries.
# Folder listings are cached for the run: the 22 menus share collections (Main includes Racing, which merges a dozen
# collections) and listing the same folders again for each was most of the boot "Shuffle" time. Only the disk reads are
# cached; the walk itself (and its loop guard) is unchanged.
$script:dirMemo = @{}
function Get-Listing([string]$dir, [string]$filter) {
  $k = "$dir|$filter"
  # [IO.DirectoryInfo]::GetFiles: the same FileInfo objects as Get-ChildItem, several times faster on big art folders
  if (-not $script:dirMemo.ContainsKey($k)) { $script:dirMemo[$k] = @(if ([IO.Directory]::Exists($dir)) { ([IO.DirectoryInfo]$dir).GetFiles($filter) }) }
  $script:dirMemo[$k]
}
# the game pictures of one collection folder (fanart + am_backdrop), as (full path, game name) pairs, read once per run.
# Plain loops, not Where-Object / ForEach-Object: with ~2,000 pictures walked again for each menu, the pipelines were
# most of the boot "Shuffle" time.
$script:artMemo = @{}
function Get-ArtOf([string]$dir) {
  if (-not $script:artMemo.ContainsKey($dir)) {
    $l = New-Object System.Collections.Generic.List[object]
    foreach ($k in 'fanart', 'am_backdrop') {
      foreach ($f in Get-Listing (Join-Path $dir "medium_artwork\$k") '*') {
        $e = $f.Extension.ToLowerInvariant()
        if (($e -eq '.jpg' -or $e -eq '.jpeg' -or $e -eq '.png') -and $f.BaseName -ne 'default') { $l.Add(@($f.FullName, $f.BaseName)) }
      }
    }
    $script:artMemo[$dir] = $l
  }
  $script:artMemo[$dir]
}
function Get-CollectionFanart([string]$col, [int]$depth = 0, [hashtable]$seen = @{}, [string[]]$only = $null, $acc = $null) {
  $top = $null -eq $acc
  if ($top) { $acc = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase) }
  if (-not $CollectionsDir -or $depth -gt 3) { return @() }
  if ($depth -gt 0 -and $col -in 'Tools', 'Settings', 'zzzShutdown') { return @() }   # tool tiles are not game art: only the Tools menu shows them
  $key = "$col|$($only -join ',')"; if ($seen.ContainsKey($key)) { return @() }; $seen[$key] = $true
  $dir = Join-Path $CollectionsDir $col
  $onlySet = $null
  if ($only) { $onlySet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase); foreach ($o in $only) { [void]$onlySet.Add($o) } }
  # fanart, and the 1920x1080 stills New-PreviewMedia.py takes from each game's own video (am_backdrop)
  foreach ($a in Get-ArtOf $dir) { if (-not $onlySet -or $onlySet.Contains($a[1])) { [void]$acc.Add($a[0]) } }
  # merged collections: a .sub that LISTS items means "only these games"; an empty .sub means "the whole collection"
  foreach ($sf in Get-Listing $dir '*.sub') {
    $list = @(foreach ($ln in [IO.File]::ReadAllLines($sf.FullName)) { $t = $ln.Trim(); if ($t) { $t } })
    [void](Get-CollectionFanart $sf.BaseName ($depth + 1) $seen ($(if ($list.Count) { $list } else { $null })) $acc)
  }
  $menus = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $menuTxt = Join-Path $dir 'menu.txt'
  if ([IO.File]::Exists($menuTxt)) { foreach ($ln in [IO.File]::ReadAllLines($menuTxt)) { $t = $ln.Trim(); if ($t) { [void]$menus.Add($t) } } }
  foreach ($f in Get-Listing (Join-Path $dir 'menu') '*') { [void]$menus.Add($f.BaseName) }
  foreach ($s in $menus) { [void](Get-CollectionFanart $s ($depth + 1) $seen $null $acc) }
  if ($top) { $r = New-Object string[] $acc.Count; $acc.CopyTo($r); [Array]::Sort($r, [StringComparer]::OrdinalIgnoreCase); return $r }   # callers wrap it in @()
  return @()
}

# every game picture in the build (fanart + am_backdrop of all collections), read once: the backdrop of a menu that
# has no game art of its own (MAME, Favorites, a console with no fanart yet)
$script:libraryArt = $null
function Get-LibraryArt {
  if ($null -eq $script:libraryArt) {
    $script:libraryArt = @(if ($CollectionsDir) { foreach ($d in [IO.Directory]::GetDirectories($CollectionsDir)) { foreach ($a in Get-ArtOf $d) { $a[0] } } })
  }
  $script:libraryArt
}

# game ids (= art file names) of one kind from the catalog, read once: racing | flight | lightgun
$script:familyIds = $null
function Get-FamilyIds([string]$fam) {
  if ($fam -notin 'racing', 'flight', 'lightgun') { return $null }
  if ($null -eq $script:familyIds) {
    $script:familyIds = @{}
    foreach ($f in 'racing', 'flight', 'lightgun') { $script:familyIds[$f] = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase) }
    $gj = if ($ManifestDir) { Join-Path $ManifestDir 'games.json' } else { $null }
    if ($gj -and (Test-Path $gj)) {
      # games.json is ~10 MB (seconds to parse): the three id lists are cached next to it, redone when it changes
      $cache = Join-Path $ManifestDir 'family-ids.json'; $stamp = [string](Get-Item $gj).LastWriteTimeUtc.Ticks
      $c = $null; if (Test-Path $cache) { try { $c = Get-Content $cache -Raw | ConvertFrom-Json } catch { } }
      if (-not $c -or $c.stamp -ne $stamp) {
        $lists = @{ racing = @(); flight = @(); lightgun = @() }
        foreach ($g in (Get-Content $gj -Raw | ConvertFrom-Json).games) {
          $k = if ($g.category -in 'racing', 'flight', 'lightgun') { $g.category } elseif ($g.genre -match '(?i)racing|driving') { 'racing' } elseif ($g.genre -match '(?i)flight|flying') { 'flight' } elseif ($g.genre -match '(?i)gun') { 'lightgun' } else { $null }
          if ($k) { $lists[$k] += [string]$g.id; if ($g.title) { $lists[$k] += [string]$g.title } }
        }
        $c = [pscustomobject]@{ stamp = $stamp; racing = $lists.racing; flight = $lists.flight; lightgun = $lists.lightgun }
        $c | ConvertTo-Json -Depth 3 -Compress | Set-Content $cache -Encoding UTF8
      }
      foreach ($f in 'racing', 'flight', 'lightgun') { foreach ($id in @($c.$f)) { if ($id) { [void]$script:familyIds[$f].Add($id) } } }
    }
  }
  $script:familyIds[$fam]
}

# Backdrop pool: the collection's own game art first, then game art from the whole library. The generated scenes only
# on a build with no game art at all (James 2026-11-22: "something related to each game as the background", no retro look).
function Get-BgPool([string]$col, [string]$themeName) {
  $fan = @(Get-CollectionFanart $col)
  if ($fan.Count -gt 0) { return $fan }
  $lib = @(Get-LibraryArt)
  # a racing / flight / light-gun menu shows games of its own kind (the catalog's category or genre)
  $fam = ($themeName -split '-')[0]
  $ids = Get-FamilyIds $fam
  if ($ids -and $ids.Count) {
    $own = @(foreach ($p in $lib) { if ($ids.Contains([IO.Path]::GetFileNameWithoutExtension($p))) { $p } })
    if ($own.Count) { return $own }
  }
  if ($lib.Count -gt 0) { return $lib }
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
  # pictures too small or portrait-shaped to fill the screen (Find-LowResArt.py, at Rebuild Game Menus): left out
  # whenever the menu still has enough others
  if ($script:lowRes.Count) {
    $good = @(foreach ($p in $pool) { if (-not $script:lowRes.Contains($p)) { $p } })
    if ($good.Count -ge [Math]::Min($BgSlots, $pool.Count)) { $pool = $good }
  }
  if ($Shuffle) { $pool = Get-Shuffled $pool }
  $pool = Select-Distinct $pool $BgSlots
  # the menu's current slot files, listed once (not once per slot): a slot may change extension, so its old file goes
  $oldSlots = ([IO.DirectoryInfo]$dst).GetFiles('am_bg*.*')
  for ($i = 1; $i -le $BgSlots; $i++) {
    $src = $pool[($i - 1) % $pool.Count]
    if (-not [IO.File]::Exists($src)) { throw "missing background $src" }
    foreach ($old in $oldSlots) { if ($old.Name.StartsWith("am_bg$i.", [StringComparison]::OrdinalIgnoreCase)) { $old.Delete() } }
    # a hard link on the same drive: fanart can be several MB, and copying ~270 of them every boot cost seconds. The slot
    # is deleted above before it is linked again, so nothing ever writes through the link into the game's own art.
    $slotFile = Join-Path $dst ("am_bg$i" + [IO.Path]::GetExtension($src).ToLower())
    if (-not ($script:canLink -and [AmNative.Link]::CreateHardLink($slotFile, $src, [IntPtr]::Zero))) { [IO.File]::Copy($src, $slotFile, $true) }
  }
  Write-Host ("{0,-20} -> {1,-8} bg: {2}" -f $col, $themeName, (($pool | Select-Object -First $BgSlots | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) }) -join ', '))
}

# --- main-menu entries that are not collections (EXIT: collections\Main\roms\EXIT.bat). RetroFE looks for their
# backdrops as the Main menu's own item art (layouts\<layout>\collections\Main\medium_artwork\am_bgN\EXIT.*), which
# nothing wrote, so the Exit page was plain black. They get the main menu's game-art pool, dealt like the others.
$mainRoms = Join-Path (Split-Path (Split-Path $LayoutDir)) 'collections\Main\roms'
if ($CollectionsDir) { $mainRoms = Join-Path $CollectionsDir 'Main\roms' }
foreach ($entry in @(Get-ChildItem $mainRoms -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.bat', '.cmd', '.exe', '.lnk' } | ForEach-Object { $_.BaseName } | Sort-Object -Unique)) {
  $pool = @(Get-BgPool 'Main' (Resolve-Skin $CabinetTheme))
  if ($script:lowRes.Count) { $good = @(foreach ($p in $pool) { if (-not $script:lowRes.Contains($p)) { $p } }); if ($good.Count -ge [Math]::Min($BgSlots, $pool.Count)) { $pool = $good } }
  if (-not $pool.Count) { continue }
  if ($Shuffle) { $pool = Get-Shuffled $pool }
  $pool = Select-Distinct $pool $BgSlots
  for ($i = 1; $i -le $BgSlots; $i++) {
    $src = $pool[($i - 1) % $pool.Count]; if (-not [IO.File]::Exists($src)) { continue }
    $dir = Join-Path $LayoutDir "collections\Main\medium_artwork\am_bg$i"; New-Item -ItemType Directory -Force $dir | Out-Null
    Get-ChildItem $dir -Filter "$entry.*" -File -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -eq $entry } | ForEach-Object { $_.Delete() }   # unlink first: never write through into game art
    $slotFile = Join-Path $dir ($entry + [IO.Path]::GetExtension($src).ToLower())
    if (-not ($script:canLink -and [AmNative.Link]::CreateHardLink($slotFile, $src, [IntPtr]::Zero))) { [IO.File]::Copy($src, $slotFile, $true) }
  }
  Write-Host ("{0,-20} -> main-menu entry bg: {1}" -f $entry, (($pool | Select-Object -First $BgSlots | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) }) -join ', '))
}
if ($styleFile -and -not $BackgroundsOnly) { Set-Content $styleFile $styleKey -Encoding ascii }
