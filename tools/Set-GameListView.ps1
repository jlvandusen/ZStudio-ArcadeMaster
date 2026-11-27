<#
.SYNOPSIS
  How the game lists look: the default (one game at a time, big video) or the Wall of Games (fifteen picture tiles, the
  chosen game playing in the middle). James, 2026-11-27: the default "is a great default"; "yes build wall of games".
  It is a view of the game lists only: the main menu, Tools and Settings keep the theme's own look.

  -View wall     puts layouts\AM-GameWall\gamelist.layout.xml in place as the list's own layout
                 (<frontend>\layouts\<layout>\collections\<List>\layout\layout.xml) for every game list of the cabinet
                 (Racing, Flight, Arcade, Lightgun ... - the merged lists that have *.sub files), copies the theme's
                 extra-screen layouts beside it so a second screen keeps showing what it showed, and makes the small
                 tiles the wall needs (tools\New-GameTiles.py; only missing ones).
  -View default  takes those files away again. Only files this tool wrote are removed (they carry its mark).
  A list that already has a layout of its own that is not ours is left alone and reported.
  With the frontend open, the open page is rebuilt at once (the cabinet link's "reload"); otherwise at the next start.
.EXAMPLE
  tools\Set-GameListView.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE-coinops -View wall
  tools\Set-GameListView.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE-coinops -View default
  tools\Set-GameListView.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE-coinops            # which view each list has
#>
param(
  [Parameter(Mandatory)][string]$RetroFE,
  [ValidateSet('', 'wall', 'default')][string]$View = '',
  [string[]]$Lists,                 # default: every collection that has *.sub files
  [switch]$NoTiles,                 # tests: do not draw tiles
  [int]$CommandPort = 47802
)
$ErrorActionPreference = 'Stop'
$mark = 'WALL OF GAMES - game list'
$src = Join-Path (Split-Path $PSScriptRoot) 'layouts\AM-GameWall\gamelist.layout.xml'
$sc = Join-Path $RetroFE 'settings.conf'
$layout = 'ArcadeMaster'; $m = Select-String -LiteralPath $sc -Pattern '^\s*layout\s*=\s*(\S.*?)\s*$' -ErrorAction SilentlyContinue | Select-Object -Last 1; if ($m) { $layout = $m.Matches[0].Groups[1].Value }
$lroot = Join-Path $RetroFE "layouts\$layout"
if (-not (Test-Path -LiteralPath $lroot)) { throw "no layout folder $lroot" }
# game lists = the merged lists (they have *.sub files), without the menus that are built the same way but hold tools
$notGames = 'Main', 'SETTINGS', 'Settings', 'Tools', 'Controller'
if (-not $Lists) { $Lists = @(Get-ChildItem -LiteralPath (Join-Path $RetroFE 'collections') -Directory | Where-Object { $notGames -notcontains $_.Name -and @(Get-ChildItem -LiteralPath $_.FullName -Filter *.sub -File -ErrorAction SilentlyContinue).Count } | ForEach-Object Name) }
function Test-Ours([string]$f) { (Test-Path -LiteralPath $f) -and ([IO.File]::ReadAllText($f) -match [regex]::Escape($mark)) }
$u8 = New-Object Text.UTF8Encoding($false)

if (-not $View) {
  foreach ($l in $Lists) { $f = Join-Path $lroot "collections\$l\layout\layout.xml"; Write-Host ("  {0,-22} {1}" -f $l, $(if (Test-Ours $f) { 'wall of games' } elseif (Test-Path -LiteralPath $f) { 'its own layout (not ours)' } else { 'default' })) }
  return
}
if ($View -eq 'wall' -and -not (Test-Path -LiteralPath $src)) { throw "the wall layout is not in the repo: $src" }

$changed = @(); $left = @()
foreach ($l in $Lists) {
  $dir = Join-Path $lroot "collections\$l\layout"; $f = Join-Path $dir 'layout.xml'
  if ((Test-Path -LiteralPath $f) -and -not (Test-Ours $f)) { $left += $l; continue }
  if ($View -eq 'wall') {
    [void][IO.Directory]::CreateDirectory($dir)
    $new = [IO.File]::ReadAllText($src)
    if (-not (Test-Path -LiteralPath $f) -or [IO.File]::ReadAllText($f) -cne $new) { [IO.File]::WriteAllText($f, $new, $u8); $changed += $l }
    # a list with its own layout folder shows only what is in that folder: the theme's extra-screen layouts
    # (layout - 1.xml ...) are copied beside it, with their picture paths pointed back at the theme's folder
    foreach ($x in Get-ChildItem -LiteralPath $lroot -Filter 'layout - *.xml' -File) {
      $t = [IO.File]::ReadAllText($x.FullName)
      $t = [regex]::Replace($t, '(\bsrc=")(?!\.\./|[A-Za-z]:|/)', '$1../../../')
      $t = "<!-- $mark : extra screen, copied from the theme by tools/Set-GameListView.ps1 -->`r`n" + $t
      $o = Join-Path $dir $x.Name
      if (-not (Test-Path -LiteralPath $o) -or (Test-Ours $o)) { [IO.File]::WriteAllText($o, $t, $u8) }
    }
  }
  else {
    $mine = @(Get-ChildItem -LiteralPath $dir -Filter 'layout*.xml' -File -ErrorAction SilentlyContinue | Where-Object { Test-Ours $_.FullName })
    if ($mine) { foreach ($x in $mine) { [IO.File]::Delete($x.FullName) }; $changed += $l }
    if ((Test-Path -LiteralPath $dir) -and -not @(Get-ChildItem -LiteralPath $dir -Force).Count) { [IO.Directory]::Delete($dir) }
  }
}
if ($View -eq 'wall' -and -not $NoTiles) {
  . (Join-Path $PSScriptRoot 'lib\AmPython.ps1'); $py = Find-AmPython
  if ($py) { $o = & $py (Join-Path $PSScriptRoot 'New-GameTiles.py') --retrofe $RetroFE 2>&1 | Out-String; Write-Host ("  " + (($o.Trim() -split "`r?`n") | Select-Object -Last 1)) }
  else { Write-Host '  no Python found: the tiles were not made, the wall shows the games by name until they are' }
}
# the open page is rebuilt from the files on disk (the frontend ignores this when it is not running)
try { $udp = New-Object Net.Sockets.UdpClient; $b = [Text.Encoding]::UTF8.GetBytes('reload'); [void]$udp.Send($b, $b.Length, '127.0.0.1', $CommandPort); $udp.Close() } catch { }
Write-Host ("game lists: {0} - {1}{2}" -f $(if ($View -eq 'wall') { 'WALL OF GAMES' } else { 'default view' }), $(if ($changed) { "changed: $($changed -join ', ')" } else { 'already so' }), $(if ($left) { "; left alone (own layout): $($left -join ', ')" } else { '' }))
