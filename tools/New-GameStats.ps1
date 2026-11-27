<#
.SYNOPSIS
  "Played here" lines for the themes: how often and how long each game has been played on THIS cabinet, and when last.
  Read from <manifest>\playtime.json (kept by Record-GamePlay.ps1 at the end of every game) and written as a small text
  file per game, which a layout shows like the game's story:
    collections\<collection>\medium_artwork\am_stats\<item>.txt
        PLAYED HERE   14 times  -  2 h 10 min
        LAST PLAYED   27 Nov, 15:14
  A game that has never been played here has no file, so a layout shows nothing for it.
  Run for every game (after a pull, or once), or for one game with -Only (Record-GamePlay does that at each game's end).
  Only ever writes into medium_artwork\am_stats.
.EXAMPLE
  tools\New-GameStats.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE-coinops -ManifestDir D:\ArcadeMaster\manifest
  tools\New-GameStats.ps1 -RetroFE <root> -ManifestDir <manifest> -Only '_TeknoParrot:DirtyDrivin'
#>
param(
  [Parameter(Mandatory)][string]$RetroFE,
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [string]$Only                       # one playtime.json key: "_<collection>:<item>"
)
$ErrorActionPreference = 'Stop'
$ptFile = Join-Path $ManifestDir 'playtime.json'
if (-not (Test-Path -LiteralPath $ptFile)) { Write-Host 'game stats: no playtime.json yet (nothing has been played)'; return }
$games = (Get-Content -LiteralPath $ptFile -Raw | ConvertFrom-Json).games
$u8 = New-Object Text.UTF8Encoding($false)
function Format-Time([int]$s) { if ($s -ge 3600) { '{0} h {1:00} min' -f [int][Math]::Floor($s / 3600), [int][Math]::Floor(($s % 3600) / 60) } elseif ($s -ge 60) { '{0} min' -f [int][Math]::Floor($s / 60) } else { 'under a minute' } }
$n = 0
foreach ($p in $games.PSObject.Properties) {
  if ($Only -and $p.Name -ne $Only) { continue }
  $e = $p.Value; $col = [string]$e.collection; $item = [string]$e.item
  if (-not $col -or -not $item -or $item -match '[\\/:*?"<>|]') { continue }
  $ma = Join-Path $RetroFE "collections\$col\medium_artwork"
  if (-not (Test-Path -LiteralPath $ma)) { continue }          # a list that is gone, or a tool entry
  $plays = [int]$e.plays; if ($plays -le 0) { continue }
  $lines = @("PLAYED HERE   $plays time$(if ($plays -ne 1) { 's' })  -  $(Format-Time ([int]$e.seconds))")
  if ($e.last) { try { $lines += 'LAST PLAYED   ' + ([datetime]$e.last).ToString('d MMM, HH:mm', [Globalization.CultureInfo]::InvariantCulture) } catch { } }
  $dir = Join-Path $ma 'am_stats'; [void][IO.Directory]::CreateDirectory($dir)
  [IO.File]::WriteAllText((Join-Path $dir "$item.txt"), ($lines -join "`r`n"), $u8); $n++
}
if (-not $Only) { Write-Host "game stats: $n game(s) with a 'played here' line" }
