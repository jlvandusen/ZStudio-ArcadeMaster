<#
.SYNOPSIS
  How the game lists look. The default (one game at a time, big video) stays the default; the others are views of the
  same lists, built from the theme mock-ups James picked from (2026-11-27):
    wall      WALL OF GAMES  fifteen picture tiles, the chosen game playing in the middle   (layouts\AM-GameWall)
    pitwall   PIT WALL       the chosen game's preview fills the screen, the list is a timing tower down the left
    split     SPLIT SCREEN   the game playing on the left, the list as a strip down the middle, on the right what the
                             game is and how often it has been played on this cabinet         (layouts\AM-Split)
                                                                                             (layouts\AM-PitWall)
  A view changes the game lists only: the main menu, Tools and Settings keep the theme's own look.

  -View <name>   puts that view's gamelist.layout.xml in place as the list's own layout
                 (<frontend>\layouts\<layout>\collections\<List>\layout\layout.xml) for every game list of the cabinet
                 (Racing, Flight, Arcade, the all-games list ... - the merged lists that have *.sub files), copies the
                 view's own pictures to <layout>\images\am-views, copies the theme's extra-screen layouts beside it so
                 a second screen keeps showing what it showed, and makes the small tiles a view needs
                 (tools\New-GameTiles.py; only missing ones).
  -View default  takes those files away again. Only files this tool wrote are removed (they carry its mark).
  A list that already has a layout of its own that is not ours is left alone and reported.
  With the frontend open, the open page is rebuilt at once (the cabinet link's "reload"); otherwise at the next start.
.EXAMPLE
  tools\Set-GameListView.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE-coinops -View wall
  tools\Set-GameListView.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE-coinops -View pitwall
  tools\Set-GameListView.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE-coinops -View default
  tools\Set-GameListView.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE-coinops            # which view each list has
#>
param(
  [Parameter(Mandatory)][string]$RetroFE,
  [string]$View = '',
  [string[]]$Lists,                 # default: every collection that has *.sub files, without the tool menus
  [switch]$NoTiles,                 # tests: do not draw tiles
  [switch]$Current,                 # print only the name of the view the cabinet's lists have (default / wall / ...)
  [int]$CommandPort = 47802
)
$ErrorActionPreference = 'Stop'
# view name -> its folder in the repo's layouts, and whether it shows the small tiles
$views = [ordered]@{ wall = @{ dir = 'AM-GameWall'; tiles = $true; label = 'WALL OF GAMES' }; pitwall = @{ dir = 'AM-PitWall'; tiles = $false; label = 'PIT WALL' }; split = @{ dir = 'AM-Split'; tiles = $false; label = 'SPLIT SCREEN' } }
if ($View -and $View -ne 'default' -and -not $views.Contains($View)) { throw "unknown view '$View' (default, $($views.Keys -join ', '))" }
$markRx = 'ArcadeMaster game list view: (\w+)|WALL OF GAMES - game list'      # the second form: files written before views had names
$sc = Join-Path $RetroFE 'settings.conf'
$layout = 'ArcadeMaster'; $m = Select-String -LiteralPath $sc -Pattern '^\s*layout\s*=\s*(\S.*?)\s*$' -ErrorAction SilentlyContinue | Select-Object -Last 1; if ($m) { $layout = $m.Matches[0].Groups[1].Value }
$lroot = Join-Path $RetroFE "layouts\$layout"
if (-not (Test-Path -LiteralPath $lroot)) { throw "no layout folder $lroot" }
# game lists = the merged lists (they have *.sub files), without the menus that are built the same way but hold tools
$notGames = 'Main', 'SETTINGS', 'Settings', 'Tools', 'Controller'
if (-not $Lists) { $Lists = @(Get-ChildItem -LiteralPath (Join-Path $RetroFE 'collections') -Directory | Where-Object { $notGames -notcontains $_.Name -and @(Get-ChildItem -LiteralPath $_.FullName -Filter *.sub -File -ErrorAction SilentlyContinue).Count } | ForEach-Object Name) }
function Get-ViewOf([string]$f) {      # '' = no file, a view name = ours, '?' = somebody else's layout
  if (-not (Test-Path -LiteralPath $f)) { return '' }
  $mm = [regex]::Match([IO.File]::ReadAllText($f), $markRx); if (-not $mm.Success) { return '?' }
  if ($mm.Groups[1].Success) { return $mm.Groups[1].Value } else { return 'wall' }
}
$u8 = New-Object Text.UTF8Encoding($false)

if ($Current) {
  $v = @($Lists | ForEach-Object { Get-ViewOf (Join-Path $lroot "collections\$_\layout\layout.xml") } | Where-Object { $_ -and $_ -ne '?' } | Select-Object -Unique)
  Write-Output $(if ($v.Count -eq 1) { $v[0] } elseif ($v.Count) { 'mixed' } else { 'default' }); return
}
if (-not $View) {
  foreach ($l in $Lists) { $v = Get-ViewOf (Join-Path $lroot "collections\$l\layout\layout.xml"); Write-Host ("  {0,-22} {1}" -f $l, $(if ($v -eq '?') { 'its own layout (not ours)' } elseif ($v) { $views[$v].label.ToLower() } else { 'default' })) }
  return
}
$src = $null
if ($View -ne 'default') {
  $vdir = Join-Path (Split-Path $PSScriptRoot) "layouts\$($views[$View].dir)"; $src = Join-Path $vdir 'gamelist.layout.xml'
  if (-not (Test-Path -LiteralPath $src)) { throw "the view's layout is not in the repo: $src" }
  # the view's own pictures, shared by every list that uses it
  $vimg = Join-Path $vdir 'images'
  if (Test-Path -LiteralPath $vimg) { $dst = Join-Path $lroot 'images\am-views'; [void][IO.Directory]::CreateDirectory($dst); foreach ($p in Get-ChildItem -LiteralPath $vimg -File) { Copy-Item -LiteralPath $p.FullName (Join-Path $dst $p.Name) -Force } }
}

$changed = @(); $left = @()
foreach ($l in $Lists) {
  $dir = Join-Path $lroot "collections\$l\layout"; $f = Join-Path $dir 'layout.xml'
  if ((Get-ViewOf $f) -eq '?') { $left += $l; continue }
  if ($View -ne 'default') {
    [void][IO.Directory]::CreateDirectory($dir)
    $new = [IO.File]::ReadAllText($src)
    if (-not (Test-Path -LiteralPath $f) -or [IO.File]::ReadAllText($f) -cne $new) { [IO.File]::WriteAllText($f, $new, $u8); $changed += $l }
    # a list with its own layout folder shows only what is in that folder: the theme's extra-screen layouts
    # (layout - 1.xml ...) are copied beside it, with their picture paths pointed back at the theme's folder
    foreach ($x in Get-ChildItem -LiteralPath $lroot -Filter 'layout - *.xml' -File) {
      $t = [IO.File]::ReadAllText($x.FullName)
      $t = [regex]::Replace($t, '(\bsrc=")(?!\.\./|[A-Za-z]:|/)', '$1../../../')
      $t = "<!-- ArcadeMaster game list view: $View - extra screen, copied from the theme by tools/Set-GameListView.ps1 -->`r`n" + $t
      $o = Join-Path $dir $x.Name
      if ((Get-ViewOf $o) -ne '?') { [IO.File]::WriteAllText($o, $t, $u8) }
    }
  }
  else {
    $mine = @(Get-ChildItem -LiteralPath $dir -Filter 'layout*.xml' -File -ErrorAction SilentlyContinue | Where-Object { (Get-ViewOf $_.FullName) -notin '', '?' })
    if ($mine) { foreach ($x in $mine) { [IO.File]::Delete($x.FullName) }; $changed += $l }
    if ((Test-Path -LiteralPath $dir) -and -not @(Get-ChildItem -LiteralPath $dir -Force).Count) { [IO.Directory]::Delete($dir) }
  }
}
if ($View -ne 'default' -and $views[$View].tiles -and -not $NoTiles) {
  . (Join-Path $PSScriptRoot 'lib\AmPython.ps1'); $py = Find-AmPython
  if ($py) { $o = & $py (Join-Path $PSScriptRoot 'New-GameTiles.py') --retrofe $RetroFE 2>&1 | Out-String; Write-Host ("  " + (($o.Trim() -split "`r?`n") | Select-Object -Last 1)) }
  else { Write-Host '  no Python found: the tiles were not made, the wall shows the games by name until they are' }
}
# the open page is rebuilt from the files on disk (the frontend ignores this when it is not running)
try { $udp = New-Object Net.Sockets.UdpClient; $b = [Text.Encoding]::UTF8.GetBytes('reload'); [void]$udp.Send($b, $b.Length, '127.0.0.1', $CommandPort); $udp.Close() } catch { }
Write-Host ("game lists: {0} - {1}{2}" -f $(if ($View -eq 'default') { 'default view' } else { $views[$View].label }), $(if ($changed) { "changed: $($changed -join ', ')" } else { 'already so' }), $(if ($left) { "; left alone (own layout): $($left -join ', ')" } else { '' }))
