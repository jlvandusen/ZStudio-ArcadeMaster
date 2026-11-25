<#
.SYNOPSIS
  Racing series as playlists: Daytona, Sega Rally, Initial D, Wangan Midnight ... (catalog\series.json). Writes
  collections\<Menu>\playlists\<Series>.txt for the games of that menu whose title matches, one "_<collection>:<item>"
  line each, and sets settings.conf "cyclePlaylist = all,<series>,..." so the wheel's button 3 (P) steps through them
  and button 2 (O) back (controls.conf nextCyclePlaylist / prevCyclePlaylist, added when missing).
  Favourites, as CoinOPS does them: the wheel's Options button (10, F) marks or unmarks the selected game
  (togglePlaylist; RetroFE saves the list as playlists/favorites.txt), Share (11, V) jumps to the Favourites list
  (favPlaylist), and "favorites" is second in the cycle (skipped by RetroFE while nothing is marked).
  Every version of a game stays: a playlist only groups. Only playlists it made itself are replaced or removed (listed
  in playlists\ARCADEMASTER-SERIES.txt); playlists from other tools or the original build are never touched.
.EXAMPLE
  tools\New-SeriesPlaylists.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE-coinops
  tools\New-SeriesPlaylists.ps1 -RetroFE <root> -WhatIf      # show the series and their games, write nothing
#>
param(
  [Parameter(Mandatory)][string]$RetroFE,
  [string[]]$Menu = @('Racing'),
  [string]$Series,                           # default: catalog\series.json in this repo
  [int]$MinGames = 2,
  [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
if (-not $Series) { $Series = Join-Path (Split-Path $PSScriptRoot) 'catalog\series.json' }
$cols = Join-Path $RetroFE 'collections'
$cfg = Get-Content $Series -Raw | ConvertFrom-Json

# titles RetroFE shows: meta\hyperlist\<collection>.xml <description>, else the item name
$titles = @{}
foreach ($x in Get-ChildItem (Join-Path $RetroFE 'meta\hyperlist') -Filter *.xml -File -ErrorAction SilentlyContinue) {
  try { $doc = New-Object Xml.XmlDocument; $doc.LoadXml(([IO.File]::ReadAllText($x.FullName) -replace '&(?!(amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);)', '&amp;')) } catch { continue }
  foreach ($g in $doc.SelectNodes('/menu/game')) { $titles["$($x.BaseName)|$($g.GetAttribute('name'))".ToLower()] = [string]$g.description }
}

$allNames = New-Object System.Collections.Generic.List[string]
foreach ($m in $Menu) {
  $mdir = Join-Path $cols $m
  if (-not (Test-Path $mdir)) { Write-Host "no menu $m"; continue }
  # the menu's games: every <collection>.sub file lists items of that collection, hidden ones (exclude.txt) left out
  $games = foreach ($sub in Get-ChildItem $mdir -Filter *.sub -File) {
    $col = $sub.BaseName
    $hidden = @{}; foreach ($h in @(Get-Content (Join-Path $cols "$col\exclude.txt") -ErrorAction SilentlyContinue)) { if ($h.Trim()) { $hidden[$h.Trim().ToLower()] = 1 } }
    foreach ($it in Get-Content $sub.FullName | Where-Object { $_.Trim() }) {
      $it = $it.Trim(); if ($hidden.ContainsKey($it.ToLower())) { continue }
      $t = $titles["$col|$it".ToLower()]; if (-not $t) { $t = $it }
      [pscustomobject]@{ col = $col; item = $it; title = $t }
    }
  }
  $pdir = Join-Path $mdir 'playlists'; $own = Join-Path $pdir 'ARCADEMASTER-SERIES.txt'
  $made = New-Object System.Collections.Generic.List[string]
  foreach ($s in $cfg.series) {
    $hits = @($games | Where-Object { $g = $_; @($s.match | Where-Object { $g.title -match $_ -or $g.item -match $_ }).Count })
    if ($hits.Count -lt $MinGames) { continue }
    $made.Add($s.name)
    Write-Host ("{0,-20} {1,2} games: {2}" -f $s.name, $hits.Count, (($hits | ForEach-Object { $_.title }) -join ', '))
    if (-not $WhatIf) {
      New-Item -ItemType Directory -Force $pdir | Out-Null
      Set-Content (Join-Path $pdir "$($s.name).txt") ($hits | ForEach-Object { "_$($_.col):$($_.item)" }) -Encoding ascii
    }
  }
  if (-not $WhatIf) {
    # remove only series playlists this tool made earlier and no longer makes
    foreach ($old in @(Get-Content $own -ErrorAction SilentlyContinue)) { if ($old -and -not $made.Contains($old)) { Remove-Item (Join-Path $pdir "$old.txt") -ErrorAction SilentlyContinue } }
    if ($made.Count) { Set-Content $own $made -Encoding ascii } elseif (Test-Path $own) { Remove-Item $own }
  }
  foreach ($n in $made) { if (-not $allNames.Contains($n)) { $allNames.Add($n) } }
}
if ($WhatIf) { return }

# settings.conf: the playlists the button cycles through (all first); controls.conf: the buttons, when missing
$sc = Join-Path $RetroFE 'settings.conf'
# the cabinet-wide lists stay in the cycle: Game of the Month (New-FeaturedPlaylist), Most played (Record-GamePlay),
# RetroFE's own Last played and Favorites - a cyclePlaylist line names every playlist that can be reached
$line = 'cyclePlaylist = ' + ((@('all', 'gameofthemonth', 'mostplayed', 'lastplayed', 'favorites') + $allNames) -join ',')
$lines = [System.Collections.Generic.List[string]](Get-Content $sc); $done = $false
for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*cyclePlaylist\s*=') { $lines[$i] = $line; $done = $true } }
if (-not $done) { $lines.Add($line) }; Set-Content $sc $lines -Encoding ascii
$cc = Join-Path $RetroFE 'controls.conf'
if (Test-Path $cc) {
  $c = @(Get-Content $cc)
  $add = @()
  if (-not ($c -match '^\s*nextCyclePlaylist\s*=')) { $add += 'nextCyclePlaylist = P,joyButton3' }
  if (-not ($c -match '^\s*prevCyclePlaylist\s*=')) { $add += 'prevCyclePlaylist = O,joyButton2' }
  if (-not ($c -match '^\s*togglePlaylist\s*=')) { $add += 'togglePlaylist = F,joyButton10' }   # Options: mark / unmark a favourite
  if (-not ($c -match '^\s*favPlaylist\s*=')) { $add += 'favPlaylist = V,joyButton11' }         # Share: the Favourites list
  if ($add) { if (([IO.File]::ReadAllText($cc)) -notmatch "\n$") { Add-Content $cc '' -Encoding ascii }   # the file may not end with a line break: a new line would run into the last one
    Add-Content $cc $add -Encoding ascii; Write-Host "controls.conf: $($add -join '; ')" }
}
Write-Host "settings.conf: $line"
