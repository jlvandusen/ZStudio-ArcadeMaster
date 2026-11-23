<#
.SYNOPSIS
  Builds the ArcadeMaster game catalog (games.json) from what is installed on this machine. Read-only.
  Sources, merged by game:
    - every TeknoParrot install: UserProfiles (what is set up) + Metadata\<id>.json (title/genre/year/platform/wheel rotation)
      The same profile in several installs (e.g. TeknoParrot + TeknoParrotMulti) = one game, several VARIANTS.
    - RetroFE collections (items, launcher, media) incl. meta\hyperlist\<collection>.xml genres
    - LaunchBox platform XML (Arcade Racing / Arcade Flight ...): links titles to TeknoParrot profiles + extra media
  Category (cabinet type): racing | flight | lightgun | arcade   (from TP genre, LaunchBox platform, hyperlist genre)
.OUTPUTS  <Out> (default D:\ArcadeMaster\manifest\games.json) + a summary on screen
#>
param(
  [string]$RetroFE = 'D:\ArcadeMaster\frontend\DRIVE-coinops',
  [object[]]$TeknoParrot = @(
    @{ Name = 'TeknoParrot';      Path = 'E:\DRIVE Collection\emulators\TeknoParrot';      Variant = 'standalone'; Collection = 'TeknoParrot' },
    @{ Name = 'TeknoParrotMulti'; Path = 'E:\DRIVE Collection\emulators\TeknoParrotMulti'; Variant = 'multicab';   Collection = 'TeknoParrotMulti' },
    @{ Name = 'TeknoParrotLB';    Path = 'D:\Emulators\TeknoParrot';                       Variant = 'launchbox';  Collection = $null }
  ),
  [string]$LaunchBox = 'D:\LaunchBox',
  [string[]]$LaunchBoxPlatforms = @('Arcade Racing', 'Arcade Flight'),
  [string]$Out = 'D:\ArcadeMaster\manifest\games.json',
  # category for frontend items that carry no genre at all (the DRIVE collection is a racing set)
  [string]$DefaultCategory = 'racing',
  # owner-curated tags (authoritative). Seeded with auto tags; entries with "auto": true may be re-derived.
  [string]$Tags = (Join-Path $PSScriptRoot '..\catalog\tags.json'),
  [switch]$NoSeedTags
)
$CabinetTypes = @('racing', 'flight', 'lightgun', 'standup')
$ErrorActionPreference = 'Stop'

# ---------------- this machine's own locations when the caller did not name them (Setup / Tools pass only -RetroFE / -Out).
# The defaults above are DESKTOP-RACE1's; another cabinet finds its installs instead of failing on a missing drive.
if (-not $PSBoundParameters.ContainsKey('TeknoParrot')) {
  $found = [ordered]@{}
  $tgt = Join-Path $PSScriptRoot "wheelmap\targets\$env:COMPUTERNAME.json"
  if (Test-Path $tgt) { foreach ($t in @((Get-Content $tgt -Raw | ConvertFrom-Json).teknoparrot)) { if ($t.root -and (Test-Path -LiteralPath $t.root)) { $found[$t.root.TrimEnd('\').ToLower()] = $t.root } } }
  foreach ($d in Get-ChildItem (Join-Path $RetroFE 'emulators') -Directory -Filter 'TeknoParrot*' -ErrorAction SilentlyContinue) { if (Test-Path (Join-Path $d.FullName 'UserProfiles')) { $found[$d.FullName.ToLower()] = $d.FullName } }
  foreach ($p in @($TeknoParrot | ForEach-Object { $_.Path })) { if (Test-Path -LiteralPath $p) { $found[$p.TrimEnd('\').ToLower()] = $p } }
  $cols = @(Get-ChildItem (Join-Path $RetroFE 'collections') -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)
  $TeknoParrot = @($found.Values | ForEach-Object {
    $leaf = Split-Path $_ -Leaf
    $variant = if ($leaf -match 'multi') { 'multicab' } elseif ($leaf -match 'light ?gun') { 'lightgun' } elseif ($_ -like "$RetroFE*") { 'standalone' } else { 'external' }
    # only an install INSIDE this frontend belongs to one of its collections: a RetroFE collection lists the profiles of
    # its own emulators\TeknoParrot*, so D:\Emulators\TeknoParrot or another frontend's copy with the same folder name
    # must not claim it (its games would be listed there and hidden, as missing). Outside installs get their own
    # AM_TP_* collection from New-RetroFECollections.
    $inside = $_.ToLower().StartsWith($RetroFE.TrimEnd('\').ToLower() + '\')
    $col = if ($inside) { $cols | Where-Object { $_ -eq $leaf -or ($variant -eq 'standalone' -and $_ -eq 'TeknoParrot') } | Select-Object -First 1 } else { $null }
    @{ Name = $leaf; Path = $_; Variant = $variant; Collection = $col } })
  Write-Host ("TeknoParrot installs found: {0}" -f (($TeknoParrot | ForEach-Object { "$($_.Path) [$($_.Variant)]" }) -join '; '))
}
$TeknoParrot = @($TeknoParrot | Where-Object { $_.Path -and (Test-Path -LiteralPath $_.Path) })   # a missing drive is skipped, not fatal
if ($LaunchBox -and -not (Test-Path -LiteralPath $LaunchBox)) { Write-Host "LaunchBox not found at $LaunchBox - skipped"; $LaunchBox = $null }
if (-not $PSBoundParameters.ContainsKey('DefaultCategory')) {
  # games with no genre follow the cabinet: a wheel cabinet is a racing set, a flight-stick one flight, anything else stand-up arcade
  $cabFile = Join-Path (Split-Path $Out) 'cabinet.json'
  if (Test-Path $cabFile) { $cap = (Get-Content $cabFile -Raw | ConvertFrom-Json).capabilities; $DefaultCategory = if ($cap.wheel) { 'racing' } elseif ($cap.flightStick) { 'flight' } else { 'standup' }; Write-Host "default category (from the cabinet's controls): $DefaultCategory" }
}

function Get-Category([string]$genre, [string]$platform) {
  $g = "$genre $platform".ToLower()
  if ($g -match 'flight|flying|aircraft|plane|air combat') { return 'flight' }
  if ($g -match 'racing|racer|driving|race\b') { return 'racing' }
  if ($g -match 'shooter|shooting|light ?gun|gun\b') { return 'lightgun' }
  if ($g.Trim()) { return 'standup' }
  return $null
}
function Find-Media([string]$col, [string]$item) {
  $m = [ordered]@{}
  foreach ($t in 'fanart', 'logo', 'video', 'artwork_front', 'artwork_3d', 'story') {
    $f = Get-ChildItem (Join-Path $RetroFE "collections\$col\medium_artwork\$t") -Filter "$item.*" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { $m[$t] = $f.FullName }
  }
  $m
}
function Resolve-GamePath([string]$tp, [string]$p) {
  if (-not $p) { return $null }
  $full = if ([IO.Path]::IsPathRooted($p)) { $p } else { [IO.Path]::GetFullPath((Join-Path $tp $p)) }
  # a broken relative GamePath (..\..\ above the drive root) collapses to the root: report it, don't fail the catalog
  if ($full -match '^([A-Za-z]:)?\\\.\.' -or -not [IO.Path]::GetDirectoryName($full)) { $script:brokenPaths += "$tp :: $p"; return $null }
  return $full
}
$script:brokenPaths = @()
function New-Game([string]$id) { [ordered]@{ id = $id; title = $id; year = $null; platform = $null; genre = $null; category = $null; tags = @(); wheelRotation = $null; variants = [ordered]@{}; media = [ordered]@{}; sources = @() } }

$games = [ordered]@{}

# metadata index across ALL installs (older installs lack Metadata\*.json); first install listed wins
$metaIndex = @{}
foreach ($tp in $TeknoParrot) {
  foreach ($mf in Get-ChildItem (Join-Path $tp.Path 'Metadata') -Filter *.json -File -ErrorAction SilentlyContinue) {
    if (-not $metaIndex.ContainsKey($mf.BaseName)) { $metaIndex[$mf.BaseName] = $mf.FullName }
  }
}

# ---------------- TeknoParrot installs
foreach ($tp in $TeknoParrot) {
  if (-not (Test-Path $tp.Path)) { continue }
  foreach ($up in Get-ChildItem (Join-Path $tp.Path 'UserProfiles') -Filter *.xml -File -ErrorAction SilentlyContinue) {
    $id = $up.BaseName
    $xml = $null; try { [xml]$xml = Get-Content $up.FullName -Raw } catch { continue }
    $gp = Resolve-GamePath $tp.Path ($xml.SelectSingleNode('//GamePath').InnerText)
    if (-not $games.Contains($id)) { $games[$id] = New-Game $id }
    $g = $games[$id]
    $metaFile = $metaIndex[$id]
    if ($metaFile -and $g.title -eq $id) {
      $meta = Get-Content $metaFile -Raw | ConvertFrom-Json
      $g.title = $meta.game_name; $g.genre = $meta.game_genre; $g.platform = $meta.platform
      if ($meta.release_year) { $g.year = $meta.release_year }
      if ($meta.wheel_rotation) { $g.wheelRotation = [int]$meta.wheel_rotation }
    }
    $vname = $tp.Variant; if ($g.variants.Contains($vname)) { $vname = "$vname-$($tp.Name)" }
    $g.variants[$vname] = [ordered]@{
      emulator = 'teknoparrot'; install = $tp.Path; profile = $id; gamePath = $gp
      gameDir = if ($gp) { [IO.Path]::GetDirectoryName($gp) } else { $null }
      ok = [bool]($gp -and (Test-Path -LiteralPath $gp)); retrofeCollection = $tp.Collection
    }
    if ($tp.Collection) {
      $g.sources += [ordered]@{ frontend = 'retrofe'; collection = $tp.Collection; item = $id }
      foreach ($kv in (Find-Media $tp.Collection $id).GetEnumerator()) { if (-not $g.media.Contains($kv.Key)) { $g.media[$kv.Key] = $kv.Value } }
    }
  }
}

# ---------------- RetroFE non-TeknoParrot collections (file-based items)
$tpCollections = @($TeknoParrot | ForEach-Object { $_.Collection } | Where-Object { $_ })
foreach ($col in Get-ChildItem (Join-Path $RetroFE 'collections') -Directory) {
  if ($col.Name -in $tpCollections -or $col.Name -in 'Main', 'GAMES', 'SETTINGS', 'Controller') { continue }
  if (Get-ChildItem $col.FullName -Filter 'ARCADEMASTER-*.txt' -File -ErrorAction SilentlyContinue) { continue }   # our own generated collections (views, Tools) are outputs, not sources
  $settings = Join-Path $col.FullName 'settings.conf'; if (-not (Test-Path $settings)) { continue }
  $conf = @{}; foreach ($line in Get-Content $settings) { if ($line -match '^\s*([^#=]+?)\s*=\s*(.*)$') { $conf[$Matches[1]] = $Matches[2].Trim() } }
  $listDir = if ($conf['list.path']) { Join-Path $RetroFE $conf['list.path'] } else { Join-Path $col.FullName 'roms' }
  $exts = @(($conf['list.extensions'] -split ',') | ForEach-Object { '.' + $_.Trim().TrimStart('.') } | Where-Object { $_ -ne '.' })
  $hyper = @{}
  $hl = Join-Path $RetroFE "meta\hyperlist\$($col.Name).xml"
  if (Test-Path $hl) { try { [xml]$h = Get-Content $hl -Raw; foreach ($gn in $h.menu.game) { $hyper[$gn.name] = $gn } } catch {} }
  foreach ($f in Get-ChildItem $listDir -File -ErrorAction SilentlyContinue | Where-Object { $exts -contains $_.Extension.ToLower() }) {
    $item = $f.BaseName; $id = "$($col.Name):$item"
    $g = New-Game $id; $hg = $hyper[$item]
    if ($hg) { $g.title = $hg.description; $g.year = $hg.year; $g.genre = $hg.genre; $g.platform = $col.Name } else { $g.title = $item; $g.platform = $col.Name }
    $g.variants['default'] = [ordered]@{ emulator = $conf['launcher']; file = $f.FullName; ok = $true; retrofeCollection = $col.Name }
    $g.sources += [ordered]@{ frontend = 'retrofe'; collection = $col.Name; item = $item }
    $g.media = Find-Media $col.Name $item
    $games[$id] = $g
  }
}

# ---------------- LaunchBox platforms: link to TP profiles, add category + extra media
foreach ($plat in @(if ($LaunchBox) { $LaunchBoxPlatforms })) {
  $px = Join-Path $LaunchBox "Data\Platforms\$plat.xml"; if (-not (Test-Path $px)) { continue }
  [xml]$lb = Get-Content $px -Raw
  foreach ($e in $lb.LaunchBox.Game) {
    $app = [string]$e.ApplicationPath; $title = [string]$e.Title
    $id = $null
    if ($app -match '(?i)UserProfiles\\([^\\]+)\.xml$') { $id = $Matches[1] }
    if (-not $id) { $id = "lb:$title" }
    if (-not $games.Contains($id)) {
      $games[$id] = New-Game $id; $games[$id].title = $title
      $full = if ([IO.Path]::IsPathRooted($app)) { $app } else { [IO.Path]::GetFullPath((Join-Path $LaunchBox $app)) }
      $games[$id].variants['launchbox'] = [ordered]@{ emulator = 'launchbox'; file = $full; ok = (Test-Path -LiteralPath $full) }
    }
    $g = $games[$id]
    if (-not $g.genre -and $e.Genre) { $g.genre = [string]$e.Genre }
    if (-not $g.year -and $e.ReleaseDate) { $g.year = ([string]$e.ReleaseDate).Substring(0, 4) }
    $g.sources += [ordered]@{ frontend = 'launchbox'; platform = $plat; title = $title; id = [string]$e.ID }
    # the owner's LaunchBox platform is a strong signal: flight always wins (TP files After Burner under "Shooter")
    if ($plat -match '(?i)flight') { $g.category = 'flight' }
    elseif ($plat -match '(?i)racing' -and -not $g.category) { $g.category = 'racing' }
    # LaunchBox art fills gaps (Fanart - Background > Screenshot - Gameplay; Clear Logo; video)
    $safe = ($title -replace '[\\/:*?"<>|'']', '_')
    $imgRoot = Join-Path $LaunchBox "Images\$plat"
    foreach ($pair in @(@('fanart', 'Fanart - Background'), @('fanart', 'Screenshot - Gameplay'), @('logo', 'Clear Logo'))) {
      if ($g.media.Contains($pair[0])) { continue }
      $hit = Get-ChildItem (Join-Path $imgRoot $pair[1]) -Recurse -File -Filter "$safe-0*" -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($hit) { $g.media[$pair[0]] = $hit.FullName }
    }
    if (-not $g.media.Contains('video')) {
      $v = Get-ChildItem (Join-Path $LaunchBox "Videos\$plat") -File -Filter "$safe*" -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($v) { $g.media['video'] = $v.FullName }
    }
  }
}

# ---------------- games that can't start: find moved files, give every other one a plain reason (lib\AmGameDoctor.ps1)
. (Join-Path $PSScriptRoot 'lib\AmGameDoctor.ps1')
$doctor = Invoke-AmGameDoctor $games.Values

# ---------------- categories + write
foreach ($g in $games.Values) {
  if (-not $g.category) {
    $known = $g.genre -and $g.genre -notmatch '^(NA|N/A|unknown)$'
    $g.category = if ($known) { Get-Category $g.genre '' } else { $null }
    if (-not $g.category) { $g.category = $DefaultCategory }
  }
}
# ---------------- owner tags: authoritative category + free tags; seed new games with their auto tag
$tagDoc = if (Test-Path $Tags) { Get-Content $Tags -Raw | ConvertFrom-Json } else { [pscustomobject]@{ _help = ''; games = [pscustomobject]@{} } }
$tagDoc._help = "Edit 'tags' per game. Cabinet types: racing, flight, lightgun, standup (shown as Arcade). Any other words are free tags (linked, kids, favorite...). Remove `"auto`": true once you have checked an entry; auto entries may be re-derived by Build-Manifest.ps1."
$seeded = 0
foreach ($g in $games.Values) {
  $e = $tagDoc.games.PSObject.Properties[$g.id]
  if ($e) {
    if ($e.Value.auto -and -not ($e.Value.tags -contains $g.category)) { $e.Value.tags = @($g.category) }   # auto entry: keep in sync
    $g.tags = @($e.Value.tags)
    $ct = @($e.Value.tags | Where-Object { $CabinetTypes -contains $_ })
    if ($ct) { $g.category = $ct[0] }                                                   # owner's tag wins
  } else {
    $g.tags = @($g.category)
    if (-not $NoSeedTags) { $tagDoc.games | Add-Member -NotePropertyName $g.id -NotePropertyValue ([pscustomobject]@{ title = $g.title; tags = @($g.category); auto = $true }); $seeded++ }
  }
}
if (-not $NoSeedTags) {
  New-Item -ItemType Directory -Force (Split-Path $Tags) | Out-Null
  $sorted = [ordered]@{}; foreach ($p in $tagDoc.games.PSObject.Properties | Sort-Object Name) { $sorted[$p.Name] = $p.Value }
  [ordered]@{ _help = $tagDoc._help; games = $sorted } | ConvertTo-Json -Depth 5 | Set-Content $Tags -Encoding UTF8
  if ($seeded) { Write-Host "tags: seeded $seeded new games into $Tags (edit, then remove ""auto"": true)" }
}

$list = @($games.Values | Sort-Object { $_.category }, { $_.title })
New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
[ordered]@{ generated = (Get-Date).ToString('s'); machine = $env:COMPUTERNAME; retrofe = $RetroFE; games = $list } |
  ConvertTo-Json -Depth 8 | Set-Content $Out -Encoding UTF8

$launchable = { param($g) @($g.variants.Values | Where-Object { $_.ok }).Count -gt 0 }
Write-Host ("{0} games -> {1}" -f $list.Count, $Out)
$list | Group-Object { $_['category'] } | ForEach-Object {
  $ok = @($_.Group | Where-Object { & $launchable $_ }).Count
  $fan = @($_.Group | Where-Object { $_.media.Contains('fanart') }).Count
  Write-Host ("  {0,-9} {1,3} games  {2,3} launchable  {3,3} with fanart  {4,3} multi-variant" -f $_.Name, $_.Count, $ok, $fan, @($_.Group | Where-Object { $_.variants.Count -gt 1 }).Count)
}
$cant = @($list | Where-Object { -not (& $launchable $_) })
if ($doctor.moved -or $cant) {
  Write-Host ("games that can't start: {0} (moved {1}, incomplete copy {2}, not installed {3}, never set up in TeknoParrot {4}, no path {5})" -f $cant.Count, $doctor.moved, $doctor.incomplete, $doctor['not-installed'], $doctor['not-set-up'], $doctor['no-path'])
  foreach ($g in $list) { foreach ($v in $g.variants.Values) { if ($v.problem) { Write-Host ("  {0,-34} {1,-13} {2}" -f $g.title, $v.problem, $v.why) } } }
}
# the same list in plain words beside the catalog (the System Health page points here)
$txt = @("Games that can't start on $env:COMPUTERNAME ($((Get-Date).ToString('yyyy-MM-dd HH:mm'))). Rebuilt with the catalog (Tools > Rebuild Game Menus).", '')
# games for this cabinet's modes first; the others (a shooter on a racing cabinet ...) would not be in its menus anyway
$cabModes = @(); $cabJson = Join-Path (Split-Path $Out) 'cabinet.json'
if (Test-Path $cabJson) { $cabModes = @((Get-Content $cabJson -Raw | ConvertFrom-Json).capabilities.modes) }
$mine = @($cant | Where-Object { -not $cabModes -or $cabModes -contains $_.category }); $other = @($cant | Where-Object { $mine -notcontains $_ })
foreach ($g in $mine | Sort-Object { $_.title }) { $txt += "$($g.title)"; foreach ($v in $g.variants.Values) { if ($v.why) { $txt += "    $($v.why)" } } }
if ($other) { $txt += ''; $txt += ("For other cabinet types (not in this cabinet's menus): " + (($other | Sort-Object { $_.title } | ForEach-Object { "$($_.title) [$($_.category)]" }) -join ', ')) }
$moved = @($list | Where-Object { @($_.variants.Values | Where-Object { $_.movedFrom }).Count })
if ($moved) { $txt += '', 'Found in a new place (they start again):'; foreach ($g in $moved) { foreach ($v in $g.variants.Values) { if ($v.movedFrom) { $txt += "    $($g.title): $($v.why)" } } } }
if (-not $cant -and -not $moved) { $txt += 'Every game in the catalog can start.' }
Set-Content (Join-Path (Split-Path $Out) 'games-cant-start.txt') $txt -Encoding UTF8
if ($script:brokenPaths) { Write-Host ("{0} TeknoParrot profile(s) with a GamePath above the drive root (fix with Repair-TPProfiles.ps1):" -f $script:brokenPaths.Count); $script:brokenPaths | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" } }
