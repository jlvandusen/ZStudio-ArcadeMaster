<#
.SYNOPSIS
  Generates genre collections (Racing / Flight / Lightgun / Arcade) + the main menu for RetroFE from games.json.
  Nothing existing is edited: new collections are merged views (.sub files) over the existing per-emulator
  collections, so every game keeps its own launcher, artwork and emulator config.
    - games whose usable variant lives in an existing RetroFE collection -> <Category>\<SourceCollection>.sub
    - TeknoParrot games that only exist in another TeknoParrot install (e.g. LaunchBox's) -> a generated
      collection per install (include.txt + launcher + media copied in RetroFE naming)
    - Main\menu.txt = categories (+ Tools); a previous menu.txt is backed up
  Generated folders carry ARCADEMASTER-GENERATED.txt; re-running regenerates them, -Remove deletes them.
#>
param(
  [string]$Manifest = 'D:\ArcadeMaster\manifest\games.json',
  [string]$RetroFE = 'D:\ArcadeMaster\frontend\DRIVE-coinops',
  [string[]]$Order = @('racing', 'flight', 'lightgun', 'standup'),
  [string]$Cabinet = 'D:\ArcadeMaster\manifest\cabinet.json',
  [string[]]$Modes,                              # cabinet modes to show (default: cabinet.json capabilities.modes); racing/flight/lightgun/standup
  [switch]$RebuildDatabase,                      # write players/ctrltype/buttons/joyways metadata and rebuild RetroFE's meta.db
  [string[]]$ExtraMenu = @('Tools'),   # SETTINGS (old DRIVE controller switcher) retired - it overwrote the wheel mappings          # existing collections to keep on the main menu
  [switch]$IncludeMultiVariants = $true,         # list e.g. Daytona 3 multicab as its own entry
  [switch]$IncludeUnsupported,                   # also list games this cabinet cannot play (fit.level = unsupported)
  [switch]$Remove
)
$ErrorActionPreference = 'Stop'
$cols = Join-Path $RetroFE 'collections'
$marker = 'ARCADEMASTER-GENERATED.txt'
$names = @{ racing = 'Racing'; flight = 'Flight'; lightgun = 'Lightgun'; standup = 'Arcade' }
# platforms / source lists that are home consoles or computers, never the Arcade list (zzzShutdown = CoinOPS scripts)
$homeSystems = '(?i)^(Amiga|Amiga CD32|Commodore|C64|Atari (ST|800|5200|7800|2600|Jaguar|Lynx)|Super Nintendo|SNES|Nintendo|NES|Famicom|Game ?Boy|GameCube|Wii|Genesis|Mega ?Drive|Master System|Saturn|Dreamcast|Sega CD|32X|Game Gear|Playstation|PSP|PS[1-5]|Xbox|PC Gamer|PC Engine|TurboGrafx|Neo Geo (CD|Pocket)|3DO|MSX|ZX|Amstrad|DOS|zzzShutdown)\b'
# whole arcade-board lists that are not in games.json (made by Import-RetroBatSystems.py ...) go into Arcade as a full
# merge (an empty .sub = every game of that list): the standalone arcade emulators - Model 2, Model 3, Naomi, Atomiswave,
# FinalBurn, Neo Geo (James 2026-11-28: "It should have teknoparrot and standalone arcade games system and system3
# emulators too")
$arcadeBoardLists = @('Model 2', 'Model 3', 'Naomi (RetroBat)', 'Atomiswave', 'Final Burn', 'Neo Geo')
# (TeknoParrot comes in game by game from games.json, so its racing / gun games stay out of Arcade)

# --- clean previous generation
# only the launchers of collections made here (AM_PC, AM_TP_*): AM_TOOLS belongs to New-CabinetToolsCollection, and
# deleting every AM_*.conf broke the Tools menu after each Rebuild Game Menus
# The art other tools make (medium_artwork\am_*: stories, preview videos, backdrops, controls cards) is set aside and put
# back once the collection is made again below: this runs at every boot, and deleting them left the PC and extra
# TeknoParrot games without a story until the next Rebuild Game Menus.
$storyKeep = Join-Path $RetroFE 'am-story-keep'
$listKeep = Join-Path $RetroFE 'am-lists-keep'   # not cleared here: lists of a menu not made this time wait for the next rebuild
if (Test-Path -LiteralPath $storyKeep) { Remove-Item -LiteralPath $storyKeep -Recurse -Force }
$ownLaunchers = @(foreach ($d in Get-ChildItem $cols -Directory) {
  if (-not (Test-Path (Join-Path $d.FullName $marker))) { continue }
  $l = Select-String -LiteralPath (Join-Path $d.FullName 'settings.conf') -Pattern '^\s*launcher\s*=\s*(AM_\S+)\s*$' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($l) { $l.Matches[0].Groups[1].Value }
  # every art folder other tools make here (am_story, am_video previews, am_backdrop, am_controls cards ...): set aside
  if (-not $Remove) {
    foreach ($st in Get-ChildItem -LiteralPath (Join-Path $d.FullName 'medium_artwork') -Directory -Filter 'am_*' -ErrorAction SilentlyContinue) {
      $to = Join-Path $storyKeep "$($d.Name)\$($st.Name)"; New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null; Move-Item -LiteralPath $st.FullName $to
    }
  }
  # the players' lists (playlists\: favourites, last played, series, Most played) are kept too and put back at the end,
  # even with -Remove: favourites must never be lost to a rebuild
  $pl = Join-Path $d.FullName 'playlists'
  if (Test-Path -LiteralPath $pl) { $to = Join-Path $listKeep $d.Name; New-Item -ItemType Directory -Force $to | Out-Null; foreach ($f in Get-ChildItem -LiteralPath $pl -File) { Copy-Item -LiteralPath $f.FullName (Join-Path $to $f.Name) -Force } }
  Remove-Item $d.FullName -Recurse -Force
})
foreach ($l in $ownLaunchers) { Remove-Item (Join-Path $RetroFE "launchers.windows\$l.conf") -Force -ErrorAction SilentlyContinue }
$menuTxt = Join-Path $cols 'Main\menu.txt'
if ($Remove) {
  if (Test-Path "$menuTxt.am-backup") { Move-Item "$menuTxt.am-backup" $menuTxt -Force } elseif (Test-Path $menuTxt) { Remove-Item $menuTxt }
  Write-Host 'generated collections removed'; return
}

$m = Get-Content $Manifest -Raw | ConvertFrom-Json
# every mode the cabinet has ever had controls for (modesSeen): the boot hides the ones not plugged in right now
if (-not $Modes -and (Test-Path $Cabinet)) { $cc = (Get-Content $Cabinet -Raw | ConvertFrom-Json).capabilities; $Modes = @(if ($cc.modesSeen) { $cc.modesSeen } else { $cc.modes }) }
if (-not $Modes) { $Modes = $Order }
Write-Host ("cabinet modes: " + ($Modes -join ', '))
function New-Collection([string]$name, [string]$settings) {
  $dir = Join-Path $cols $name; New-Item -ItemType Directory -Force $dir | Out-Null
  Set-Content (Join-Path $dir $marker) "generated by tools/New-RetroFECollections.ps1 from $Manifest - do not edit, re-run the tool" -Encoding ascii
  Set-Content (Join-Path $dir 'settings.conf') $settings -Encoding ascii
  $dir
}
function Get-VariantOrder($g) {
  # preferred order: standalone (primary TeknoParrot), default (file-based collections), others; launchbox last
  $vs = @($g.variants.PSObject.Properties | Where-Object { $_.Value.ok })
  $vs | Sort-Object { switch ($_.Name) { 'standalone' { 0 } 'default' { 1 } 'launchbox' { 9 } default { 5 } } }
}

$subs = @{}          # category -> sourceCollection -> [items]
$extraTP = @{}       # install path -> @{ items; media }
$pcGames = New-Object System.Collections.Generic.List[object]   # native Windows exes (LaunchBox-only PC titles)
$metaItems = @{}     # sourceCollection -> item -> game (for players/ctrltype/buttons/joyways metadata)
$skipped = New-Object System.Collections.Generic.List[string]
foreach ($g in $m.games) {
  if ($g.hidden) { $skipped.Add("$($g.id) - hidden duplicate of $($g.alternativeOf)"); continue }
  if ($g.fit -and $g.fit.level -eq 'unsupported' -and -not $IncludeUnsupported) { $skipped.Add("$($g.id) - not playable on this cabinet: $(($g.fit.notes) -join '; ')"); continue }
  $cat = $g.category; if ($cat -eq 'arcade' -or -not $names.ContainsKey($cat)) { $cat = 'standup' }
  if ($Modes -notcontains $cat) { $skipped.Add("$($g.id) [$cat] - not a mode of this cabinet"); continue }
  # Arcade is arcade games only: MAME / FinalBurn sets, TeknoParrot and the arcade boards. A home console or computer game
  # with no category of its own stays in its system's menu (James 2026-11-28 on the pedestal: "I am in arcade and it has
  # Amiga games in here").
  if ($cat -eq 'standup' -and ("$($g.platform)" -match $homeSystems -or @($g.sources | Where-Object { "$($_.collection)" -match $homeSystems }).Count)) { $skipped.Add("$($g.id) [$cat] - home system ($($g.platform)): in its own menu, not in Arcade"); continue }
  $picked = @()
  foreach ($v in Get-VariantOrder $g) {
    if ($v.Value.retrofeCollection) { $picked += , @($v.Value.retrofeCollection, $v.Value.profile, $v.Name) }
    elseif ($v.Value.emulator -eq 'teknoparrot' -and $picked.Count -eq 0) { $picked += , @("TP:$($v.Value.install)", $v.Value.profile, $v.Name) }
    if (-not $IncludeMultiVariants -and $picked.Count) { break }
  }
  if (-not $picked) {
    $file = $null; foreach ($v in $g.variants.PSObject.Properties) { if ($v.Value.retrofeCollection) { $file = $v } }
    if ($g.sources | Where-Object { $_.frontend -eq 'retrofe' }) {
      $src = @($g.sources | Where-Object { $_.frontend -eq 'retrofe' })[0]; $picked = , @($src.collection, $src.item, 'default')
    }
  }
  if (-not $picked) {
    $exeVar = @($g.variants.PSObject.Properties | Where-Object { $_.Value.ok -and "$($_.Value.file)" -match '(?i)\.exe$' })[0]
    if ($exeVar) {
      $item = ($g.title -replace '[\\/:*?"<>|]', '').Trim()
      $pcGames.Add([pscustomobject]@{ Item = $item; Exe = $exeVar.Value.file; Game = $g })
      $picked = , @('AM_PC', $item, 'exe')
    }
  }
  if (-not $picked) { $skipped.Add("$($g.id) [$cat] - no launchable variant"); continue }
  foreach ($p in $picked) {
    $srcCol = $p[0]; $item = $p[1]
    if (-not $item) { $item = @($g.sources | Where-Object { $_.collection -eq $srcCol })[0].item }
    if ($srcCol -like 'TP:*') {
      $inst = $srcCol.Substring(3)
      if (-not $extraTP.ContainsKey($inst)) { $extraTP[$inst] = @{ Items = New-Object System.Collections.Generic.List[string]; Games = @() } }
      $extraTP[$inst].Items.Add($item); $extraTP[$inst].Games += $g
      $srcCol = 'AM_TP_' + (($inst -replace '^[A-Za-z]:\\', '') -replace '[^A-Za-z0-9]+', '_').Trim('_')
    }
    if (-not $subs.ContainsKey($cat)) { $subs[$cat] = @{} }
    if (-not $subs[$cat].ContainsKey($srcCol)) { $subs[$cat][$srcCol] = New-Object System.Collections.Generic.List[string] }
    if (-not $subs[$cat][$srcCol].Contains($item)) { $subs[$cat][$srcCol].Add($item) }
    if (-not $metaItems.ContainsKey($srcCol)) { $metaItems[$srcCol] = @{} }; $metaItems[$srcCol][$item] = $g
  }
}

# --- borrowed art: RetroFE finds art by the item's own name (medium_artwork\fanart\scudau.png). A clone whose art the
# catalog borrowed from its family (Build-Manifest: scudau -> scud) gets a hard link under its own name - same file, no
# extra space (a copy when linking fails). Only missing files are added, never replaced; every one is listed in
# medium_artwork\ARCADEMASTER-borrowed-art.txt so it can be removed again.
$borrowed = 0
foreach ($srcCol in @($metaItems.Keys)) {
  foreach ($item in @($metaItems[$srcCol].Keys)) {
    $g = $metaItems[$srcCol][$item]
    foreach ($t in @($g.media.PSObject.Properties)) {
      $src = [string]$t.Value
      if (-not $src -or [IO.Path]::GetFileNameWithoutExtension($src) -eq $item -or -not (Test-Path -LiteralPath $src)) { continue }
      if ($src -notlike (Join-Path $cols "$srcCol\medium_artwork\*")) { continue }   # only art from the same collection
      if ($t.Name -match '^am_controls|^am_hint$') { continue }   # controls cards are drawn per game: never borrowed
      $dst = Join-Path $cols ("$srcCol\medium_artwork\$($t.Name)\$item" + [IO.Path]::GetExtension($src).ToLower())
      if (Test-Path -LiteralPath $dst) { continue }
      if (@(Get-ChildItem (Split-Path $dst) -Filter "$item.*" -File -ErrorAction SilentlyContinue).Count) { continue }   # has its own art in another format
      try { New-Item -ItemType HardLink -Path $dst -Target $src -ErrorAction Stop | Out-Null } catch { Copy-Item -LiteralPath $src $dst }
      Add-Content (Join-Path $cols "$srcCol\medium_artwork\ARCADEMASTER-borrowed-art.txt") $dst -Encoding UTF8
      $borrowed++
    }
  }
}
if ($borrowed) { Write-Host "art: $borrowed file(s) linked for game versions that had none of their own (list: medium_artwork\ARCADEMASTER-borrowed-art.txt)" }

# --- extra TeknoParrot installs as their own (hidden) source collections
foreach ($inst in $extraTP.Keys) {
  $colName = 'AM_TP_' + (($inst -replace '^[A-Za-z]:\\', '') -replace '[^A-Za-z0-9]+', '_').Trim('_')
  $dir = New-Collection $colName @"
# TeknoParrot install $inst (games set up only there)
list.path = $inst\UserProfiles
list.extensions = xml
list.includeMissingItems = false
list.menuSort = yes
launcher = $colName
metadata.type = %ITEM_COLLECTION_NAME%
"@
  Set-Content (Join-Path $dir 'include.txt') ($extraTP[$inst].Items | Sort-Object -Unique) -Encoding ascii
  Set-Content (Join-Path $RetroFE "launchers.windows\$colName.conf") "executable = $inst\TeknoParrotUi.exe`r`narguments = --profile=`"%ITEM_FILENAME%`"" -Encoding ascii
  foreach ($g in $extraTP[$inst].Games) {
    $item = @($g.variants.PSObject.Properties | Where-Object { $_.Value.install -eq $inst })[0].Value.profile
    foreach ($t in $g.media.PSObject.Properties) {
      $td = Join-Path $dir "medium_artwork\$($t.Name)"; New-Item -ItemType Directory -Force $td | Out-Null
      if (Test-Path -LiteralPath $t.Value) { Copy-Item -LiteralPath $t.Value (Join-Path $td ($item + [IO.Path]::GetExtension($t.Value).ToLower())) -Force }
    }
  }
  Write-Host ("source collection {0}: {1} games from {2}" -f $colName, $extraTP[$inst].Items.Count, $inst)
}

# --- native Windows games: one .bat per game (cd to the game folder, run, wait)
if ($pcGames.Count) {
  $dir = New-Collection 'AM_PC' "# native Windows games (generated .bat per game)`r`nlist.extensions = bat`r`nlist.includeMissingItems = false`r`nlist.menuSort = yes`r`nlauncher = AM_PC`r`nmetadata.type = %ITEM_COLLECTION_NAME%`r`n"
  $roms = Join-Path $dir 'roms'; New-Item -ItemType Directory -Force $roms | Out-Null
  foreach ($p in $pcGames) {
    $exeDir = Split-Path $p.Exe; $exeName = Split-Path $p.Exe -Leaf
    Set-Content (Join-Path $roms "$($p.Item).bat") "@echo off`r`ncd /d `"$exeDir`"`r`nstart `"`" /wait `"$exeName`"`r`n" -Encoding ascii
    foreach ($t in $p.Game.media.PSObject.Properties) {
      $td = Join-Path $dir "medium_artwork\$($t.Name)"; New-Item -ItemType Directory -Force $td | Out-Null
      if (Test-Path -LiteralPath $t.Value) { Copy-Item -LiteralPath $t.Value (Join-Path $td ($p.Item + [IO.Path]::GetExtension($t.Value).ToLower())) -Force }
    }
  }
  Set-Content (Join-Path $RetroFE 'launchers.windows\AM_PC.conf') "executable = C:\Windows\System32\cmd.exe`r`narguments = /c `"%ITEM_FILEPATH%`"" -Encoding ascii
  Write-Host ("source collection AM_PC: {0} native Windows games" -f $pcGames.Count)
}

# --- art aliases (catalog\art-aliases.json): the same game listed under another name in another list (Daytona3Single
# in AM_TP_Emulators_TeknoParrot is TeknoParrot's Daytona3) borrows that list's art and video: hard links for the art
# types it has none of, never replacing its own, every one listed for removal. No stories (hand-written in
# tools\game-stories.json). Runs after AM_PC / AM_TP_* are rebuilt above: they are deleted and remade on every run, so
# links made earlier would be lost. Large files that can't be linked (another drive) are skipped rather than copied.
$aliased = 0
$aliasFile = Join-Path $PSScriptRoot '..\catalog\art-aliases.json'
if (Test-Path $aliasFile) {
  $aliases = (Get-Content $aliasFile -Raw | ConvertFrom-Json).aliases
  # single files: { "<collection>/<item>": { "<art type>": "<file>" } } - e.g. a PC game's own intro movie as its video
  $files = (Get-Content $aliasFile -Raw | ConvertFrom-Json).files
  # clips: a game's own movie made into a menu video by tools\New-GameClips.ps1 (D:\ArcadeMaster\media\clips\<collection>\<item>.mp4), used as its video
  # [IO.Path]::Combine, not Join-Path: Windows PowerShell 5.1 throws on a cabinet without a D: drive (the pedestal)
  $clipCfg = (Get-Content $aliasFile -Raw | ConvertFrom-Json).clips
  if ($clipCfg) { $fx = [ordered]@{}; if ($files) { foreach ($q in $files.PSObject.Properties) { $fx[$q.Name] = $q.Value } }; foreach ($q in $clipCfg.PSObject.Properties) { $cf = [IO.Path]::Combine('D:\ArcadeMaster\media\clips', (($q.Name -replace '/', '\') + '.mp4')); if (-not $fx.Contains($q.Name) -and (Test-Path -LiteralPath $cf)) { $fx[$q.Name] = [pscustomobject]@{ video = $cf } } }; $files = [pscustomobject]$fx }
  foreach ($a in @(if ($files) { $files.PSObject.Properties })) {
    $dstCol, $dstItem = $a.Name -split '/', 2
    if (-not (Test-Path -LiteralPath (Join-Path $cols $dstCol))) { continue }
    foreach ($t in @($a.Value.PSObject.Properties)) {
      $src = [string]$t.Value; if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }
      $dir = Join-Path $cols "$dstCol\medium_artwork\$($t.Name)"
      if (@(Get-ChildItem -LiteralPath $dir -Filter "$dstItem.*" -File -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -eq $dstItem }).Count) { continue }   # has its own
      New-Item -ItemType Directory -Force $dir | Out-Null
      $dst = Join-Path $dir ($dstItem + [IO.Path]::GetExtension($src).ToLower())
      try { New-Item -ItemType HardLink -Path $dst -Target $src -ErrorAction Stop | Out-Null } catch { Write-Host "art: $dstCol/$dstItem $($t.Name) not linked ($($_.Exception.Message.Split("`n")[0]))"; continue }
      Add-Content (Join-Path $cols "$dstCol\medium_artwork\ARCADEMASTER-borrowed-art.txt") $dst -Encoding UTF8
      $aliased++
    }
  }
  foreach ($a in @($aliases.PSObject.Properties)) {
    $dstCol, $dstItem = $a.Name -split '/', 2; $srcCol, $srcItem = ([string]$a.Value) -split '/', 2
    $dstArt = Join-Path $cols "$dstCol\medium_artwork"; $srcArt = Join-Path $cols "$srcCol\medium_artwork"
    if (-not (Test-Path -LiteralPath (Join-Path $cols $dstCol)) -or -not (Test-Path -LiteralPath $srcArt)) { continue }
    foreach ($typeDir in Get-ChildItem -LiteralPath $srcArt -Directory) {
      if ($typeDir.Name -match '^(am_)?story$|^am_controls|^am_hint$') { continue }   # controls cards are drawn per game: never borrowed
      $src = Get-ChildItem -LiteralPath $typeDir.FullName -Filter "$srcItem.*" -File -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -eq $srcItem } | Select-Object -First 1
      if (-not $src) { continue }
      $dir = Join-Path $dstArt $typeDir.Name
      if (@(Get-ChildItem -LiteralPath $dir -Filter "$dstItem.*" -File -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -eq $dstItem }).Count) { continue }   # has its own
      New-Item -ItemType Directory -Force $dir | Out-Null
      $dst = Join-Path $dir ($dstItem + $src.Extension.ToLower())
      try { New-Item -ItemType HardLink -Path $dst -Target $src.FullName -ErrorAction Stop | Out-Null }
      catch { if ($src.Length -gt 20MB) { Write-Host "art: $dstCol/$dstItem $($typeDir.Name) not linked ($($_.Exception.Message.Split("`n")[0]))"; continue }; Copy-Item -LiteralPath $src.FullName $dst }
      Add-Content (Join-Path $dstArt 'ARCADEMASTER-borrowed-art.txt') $dst -Encoding UTF8
      $aliased++
    }
  }
}
if ($aliased) { Write-Host "art: $aliased file(s) linked from the same game in another list (catalog\art-aliases.json)" }

# --- the stories set aside above go back into the collections that were made again (a collection no longer made
# loses them, like the rest of its generated files)
if (Test-Path -LiteralPath $storyKeep) {
  $kept = 0
  foreach ($k in Get-ChildItem -LiteralPath $storyKeep -Directory) {
    $art = Join-Path $cols "$($k.Name)\medium_artwork"
    if (-not (Test-Path -LiteralPath (Join-Path $cols $k.Name))) { continue }
    foreach ($typeDir in Get-ChildItem -LiteralPath $k.FullName -Directory) {
      $dst = Join-Path $art $typeDir.Name; New-Item -ItemType Directory -Force $dst | Out-Null
      # files the rebuild made again (e.g. linked by art-aliases) win; everything else comes back
      foreach ($f in Get-ChildItem -LiteralPath $typeDir.FullName -File) { if (-not (Test-Path -LiteralPath (Join-Path $dst $f.Name))) { Move-Item -LiteralPath $f.FullName $dst; $kept++ } }
    }
  }
  Remove-Item -LiteralPath $storyKeep -Recurse -Force -ErrorAction SilentlyContinue
  if ($kept) { Write-Host "art: $kept file(s) kept for the rebuilt PC / TeknoParrot lists (stories, previews, backdrops, controls cards)" }
}

# --- category collections (merged .sub views)
# one entry per game in a category: CoinOPS builds list the same games in several collections (Arcades, ArcadesMini,
# Fight: 719 each on the pedestal - every game three times, the subset copies without art; James 2026-11-26 "a lot of
# duplicate games ... a lot of arcade without the logos"). A game kept in several sources stays in the one with the
# most logos; backup folders (*.am-bak*) never count as a source.
$logoCount = @{}
function Get-LogoCount([string]$col) {
  if (-not $logoCount.ContainsKey($col)) { $d = Join-Path $cols "$col\medium_artwork\logo"; $logoCount[$col] = if (Test-Path $d) { @(Get-ChildItem $d -File -ErrorAction SilentlyContinue).Count } else { 0 } }
  $logoCount[$col]
}
foreach ($cat in @($subs.Keys)) {
  foreach ($src in @($subs[$cat].Keys)) { if ($src -match '\.am-bak' -or $src -eq 'zzzShutdown') { $subs[$cat].Remove($src) } }   # zzzShutdown = CoinOPS settings scripts, not games
  $ranked = @($subs[$cat].Keys | Sort-Object { - (Get-LogoCount $_) })
  $taken = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $dropped = 0
  foreach ($src in $ranked) {
    $keep = New-Object System.Collections.Generic.List[string]
    foreach ($it in $subs[$cat][$src]) { if ($taken.Add($it)) { $keep.Add($it) } else { $dropped++ } }
    if ($keep.Count) { $subs[$cat][$src] = $keep } else { $subs[$cat].Remove($src) }
  }
  if ($dropped) { Write-Host ("{0}: {1} duplicate entr(ies) left out (kept in the source with the most art)" -f $cat, $dropped) }
}
$menu = New-Object System.Collections.Generic.List[string]
foreach ($cat in $Order) {
  if (-not $subs.ContainsKey($cat)) { continue }
  $name = $names[$cat]
  $dir = New-Collection $name "# merged $cat collection (items come from the .sub files)`r`nlist.menuSort = yes`r`n"
  $n = 0
  foreach ($src in $subs[$cat].Keys) { Set-Content (Join-Path $dir "$src.sub") ($subs[$cat][$src] | Sort-Object) -Encoding ascii; $n += $subs[$cat][$src].Count }
  if ($cat -eq 'standup') {
    foreach ($b in $arcadeBoardLists) {
      if ($subs[$cat].ContainsKey($b) -or -not (Test-Path -LiteralPath (Join-Path $cols "$b\settings.conf"))) { continue }
      Set-Content -LiteralPath (Join-Path $dir "$b.sub") '' -Encoding ascii -NoNewline   # empty = the whole list
      $subs[$cat][$b] = @('(all)')
    }
  }
  $menu.Add($name)
  Write-Host ("{0,-9} {1,3} entries from {2}" -f $name, $n, (($subs[$cat].Keys | Sort-Object) -join ', '))
}
foreach ($e in $ExtraMenu) { if (Test-Path (Join-Path $cols $e)) { $menu.Add($e) } }
# entries other tools add (Import-RetroBatSystems.py: "Classic Systems"), one per line, kept across rebuilds
$extraFile = Join-Path $cols 'Main\am-extra-menu.txt'
$extras = @()
if (Test-Path $extraFile) { foreach ($e in Get-Content $extraFile) { $e = $e.Trim(); if ($e -and (Test-Path (Join-Path $cols $e)) -and $menu -notcontains $e) { $menu.Add($e); $extras += $e } } }

if ((Test-Path $menuTxt) -and -not (Test-Path "$menuTxt.am-backup")) { Copy-Item $menuTxt "$menuTxt.am-backup" }
# A CoinOPS build (LEGENDS, CORE ...) has no Main menu: its library starts at settings.conf firstCollection (e.g. Arcades).
# Keep that whole library one press away from the ArcadeMaster main menu, and start the frontend at Main so Back from the
# library returns to the menu (started inside the library, Back has nowhere to go). The library's name is remembered in
# Main\am-library.txt because firstCollection says Main after the first run.
$settingsConf = Join-Path $RetroFE 'settings.conf'
$libFile = Join-Path (Split-Path $menuTxt) 'am-library.txt'
$fcLine = Select-String -Path $settingsConf -Pattern '^\s*firstCollection\s*=\s*(.+)$' -ErrorAction SilentlyContinue | Select-Object -Last 1
$fc = if ($fcLine) { $fcLine.Matches[0].Groups[1].Value.Trim() } else { '' }
$own = if (Test-Path $libFile) { (Get-Content $libFile -Raw).Trim() } elseif ($fc -ne 'Main') { $fc } else { '' }
if ($own -and (Test-Path (Join-Path $cols $own))) {
  if ($menu -notcontains $own) { $menu.Add($own); Write-Host "kept the build's own library in the main menu: $own" }
} else { $own = '' }
New-Item -ItemType Directory -Force (Split-Path $menuTxt) | Out-Null
# one order whatever ran last: the categories (Arcade ...), the build's own library (Arcades), the makers other tools add
# (Nintendo, Sega ...), Tools at the end
$ordered = New-Object System.Collections.Generic.List[string]
foreach ($m in $menu) { if ($m -ne 'Tools' -and $m -ne $own -and $extras -notcontains $m) { $ordered.Add($m) } }
if ($own) { $ordered.Add($own) }
foreach ($m in $extras) { $ordered.Add($m) }
if ($menu -contains 'Tools') { $ordered.Add('Tools') }
$menu = $ordered
Set-Content $menuTxt $menu -Encoding ascii
if ($own) { Set-Content $libFile $own -Encoding ascii }
Write-Host ("Main menu: " + ($menu -join ' | '))
if ($own -and $fc -eq $own) {
  if (-not (Test-Path "$settingsConf.am-firstcollection")) { Copy-Item $settingsConf "$settingsConf.am-firstcollection" }
  $raw = [IO.File]::ReadAllText($settingsConf)
  [IO.File]::WriteAllText($settingsConf, ($raw -replace '(?m)^(\s*firstCollection\s*=\s*).+?(\r?)$', '${1}Main$2'))
  # CoinOPS builds set it again in settings5.conf (read after settings.conf) and autochanger\settings.conf: those won, the
  # frontend opened inside the library with no main menu behind it and Back did nothing (pedestal, 2026-11-26)
  foreach ($extra in @(Get-ChildItem $RetroFE -File -Filter 'settings*.conf') + @(Get-Item (Join-Path $RetroFE 'autochanger\settings.conf') -ErrorAction SilentlyContinue)) {
    if (-not $extra -or $extra.FullName -eq $settingsConf) { continue }
    $x = [IO.File]::ReadAllText($extra.FullName)
    if ($x -match '(?m)^\s*firstCollection\s*=\s*(?!Main\s*$)') {
      if (-not (Test-Path "$($extra.FullName).am-firstcollection")) { Copy-Item $extra.FullName "$($extra.FullName).am-firstcollection" }
      [IO.File]::WriteAllText($extra.FullName, ($x -replace '(?m)^(\s*firstCollection\s*=\s*).+?(\r?)$', '${1}Main$2'))
    }
  }
  Write-Host "frontend now starts at Main (was $own), so Back returns to the menu"
}
if ($skipped.Count) { Write-Host "not listed ($($skipped.Count)):"; $skipped | ForEach-Object { Write-Host "  $_" } }

# --- game metadata for RetroFE: players / ctrltype / buttons / joyways (drives the ServoStik/GRS restrictor per game)
if ($RebuildDatabase) {
  $hl = Join-Path $RetroFE 'meta\hyperlist'; New-Item -ItemType Directory -Force $hl | Out-Null
  foreach ($src in $metaItems.Keys) {
    $path = Join-Path $hl "$src.xml"
    if ((Test-Path $path) -and -not (Test-Path "$path.am-backup")) { Copy-Item $path "$path.am-backup" }
    $doc = New-Object Xml.XmlDocument
    if (Test-Path $path) {
      $raw = [IO.File]::ReadAllText($path)
      try { $doc.LoadXml($raw) } catch { $doc.LoadXml(($raw -replace '&(?!(amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);)', '&amp;')) }   # RetroFE's parser tolerates bare "&"; .NET does not
    } else { $doc.LoadXml("<?xml version=`"1.0`"?><menu><header><listname>$src</listname></header></menu>") }
    $menuNode = $doc.SelectSingleNode('/menu')
    foreach ($item in $metaItems[$src].Keys) {
      $g = $metaItems[$src][$item]; $c = $g.controls
      $node = $menuNode.SelectSingleNode("game[@name=`"$($item -replace '"', '')`"]")
      if (-not $node) {
        $node = $doc.CreateElement('game'); $node.SetAttribute('name', $item); [void]$menuNode.AppendChild($node)
        foreach ($kv in @(@('description', $g.title), @('year', $g.year), @('genre', $g.genre))) { if ($kv[1]) { $e = $doc.CreateElement($kv[0]); $e.InnerText = [string]$kv[1]; [void]$node.AppendChild($e) } }
      }
      # placeholders only (empty, "NA", the raw set name such as "scudau") get the catalog's name / year - a real name
      # someone wrote stays as it is
      foreach ($kv in @(@('description', $g.title), @('year', $g.year), @('genre', $g.genre))) {
        $new = [string]$kv[1]; if (-not $new -or $new -eq 'NA' -or $new -eq $item) { continue }
        $e = $node.SelectSingleNode($kv[0]); $cur = if ($e) { $e.InnerText.Trim() } else { '' }
        if ($cur -in '', 'NA', $item) { if (-not $e) { $e = $doc.CreateElement($kv[0]); [void]$node.AppendChild($e) }; $e.InnerText = $new }
      }
      $vals = [ordered]@{ players = $c.players; ctrltype = $c.ctrltype; buttons = $c.buttons; joyways = $c.ways }
      foreach ($k in $vals.Keys) {
        if ($null -eq $vals[$k] -or "$($vals[$k])" -eq '' -or "$($vals[$k])" -eq '0') { continue }
        $e = $node.SelectSingleNode($k); if (-not $e) { $e = $doc.CreateElement($k); [void]$node.AppendChild($e) }
        $e.InnerText = [string]$vals[$k]
      }
    }
    $doc.Save($path)
  }
  Write-Host ("metadata written for {0} collections -> rebuilding meta.db" -f $metaItems.Count)
  . (Join-Path $PSScriptRoot 'lib\RetroFEPaths.ps1'); $exe = Get-AmRetroFEExe $RetroFE   # retrofe\, core\ (CoinOPS) or the root
  if ($exe) { $p = Start-Process $exe -ArgumentList '-rebuilddatabase' -WorkingDirectory (Split-Path $exe) -PassThru -WindowStyle Hidden; if (-not $p.WaitForExit(120000)) { $p.Kill(); Write-Warning 'meta.db rebuild timed out' } else { Write-Host "meta.db rebuilt (exit $($p.ExitCode))" } }
}

# --- the players' lists set aside above go back (a list the rebuild made again wins)
if (Test-Path -LiteralPath $listKeep) {
  $back = 0
  foreach ($k in Get-ChildItem -LiteralPath $listKeep -Directory) {
    $col = Join-Path $cols $k.Name; if (-not (Test-Path -LiteralPath $col)) { continue }   # menu not made this time: kept for later
    $pl = Join-Path $col 'playlists'; New-Item -ItemType Directory -Force $pl | Out-Null
    foreach ($f in Get-ChildItem -LiteralPath $k.FullName -File) { if (-not (Test-Path -LiteralPath (Join-Path $pl $f.Name))) { Copy-Item -LiteralPath $f.FullName $pl; $back++ } }
    Remove-Item -LiteralPath $k.FullName -Recurse -Force
  }
  if ($back) { Write-Host "playlists: $back file(s) kept through the rebuild (favourites, last played, series)" }
}

# the launchers rewritten above lose ArcadeMaster's start / end hooks (play time, Most played, save backups): put them back
try { & (Join-Path $PSScriptRoot 'Set-GameHooks.ps1') -RetroFE $RetroFE -ManifestDir (Split-Path $Manifest) -Quiet } catch { Write-Warning "game hooks: $($_.Exception.Message)" }
