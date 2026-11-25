<#
.SYNOPSIS
  Game of the Month: once a month, every merged menu (Racing, Flight, Arcade ...) gets a "gameofthemonth" playlist of
  up to -Count games, shown in the game list's filter bar as GAME OF THE MONTH (Left / Right).

  The pick is the same all month on a cabinet: it is seeded by the month and the menu, so it does not reshuffle at every
  boot. It prefers games that show well - a preview video (am_video or video) and a backdrop (fanart) - and skips the
  games featured in the last -AvoidMonths months (manifest\featured-history.json). Already-loved games (top of Most
  played, A10) are left out of the first slot, so the month leads with something people have not been playing.
  The boot runs it (cheap when the month has not changed); -Force picks again now.
.EXAMPLE
  tools\New-FeaturedPlaylist.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE
  tools\New-FeaturedPlaylist.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE -Force -Month 2026-12
#>
param(
  [Parameter(Mandatory)][string]$RetroFE,
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [int]$Count = 10,
  [int]$AvoidMonths = 3,
  [string]$Month = (Get-Date).ToString('yyyy-MM'),
  [switch]$Force
)
$ErrorActionPreference = 'Stop'
$u8 = New-Object Text.UTF8Encoding $false
$histFile = Join-Path $ManifestDir 'featured-history.json'
$hist = [ordered]@{}; if (Test-Path $histFile) { try { $h = Get-Content $histFile -Raw | ConvertFrom-Json; foreach ($p in $h.PSObject.Properties) { $hist[$p.Name] = $p.Value } } catch { } }
$cols = Join-Path $RetroFE 'collections'
$menus = @(Get-ChildItem $cols -Directory | Where-Object { @(Get-ChildItem $_.FullName -Filter *.sub -File -ErrorAction SilentlyContinue).Count })
$done = $hist[$Month]
# this month already picked, and every menu that got a pick still has its playlist (a rebuild can drop the folder)
if ($done -and -not $Force -and @($done.PSObject.Properties | Where-Object { -not (Test-Path (Join-Path $cols "$($_.Name)\playlists\gameofthemonth.txt")) }).Count -eq 0) { return }

# the months before this one, newest first (what to avoid)
$recent = @($hist.Keys | Where-Object { $_ -lt $Month } | Sort-Object -Descending | Select-Object -First $AvoidMonths)
$avoid = @{}; foreach ($m in $recent) { foreach ($menu in $hist[$m].PSObject.Properties) { foreach ($k in @($menu.Value)) { $avoid[$k] = $true } } }
$most = @{}; $pf = Join-Path $ManifestDir 'playtime.json'
if (Test-Path $pf) { try { $i = 0; foreach ($p in ((Get-Content $pf -Raw | ConvertFrom-Json).games.PSObject.Properties | Sort-Object { [int]$_.Value.seconds } -Descending | Select-Object -First 5)) { $most[$p.Name] = $true } } catch { } }

function Has-Media([string]$col, [string]$item, [string[]]$types) {
  foreach ($t in $types) { if (@(Get-ChildItem -LiteralPath (Join-Path $cols "$col\medium_artwork\$t") -Filter "$item.*" -File -ErrorAction SilentlyContinue).Count) { return $true } }
  $false
}
$picked = [ordered]@{}
foreach ($menu in $menus) {
  $cands = @()
  foreach ($s in Get-ChildItem $menu.FullName -Filter *.sub -File) {
    foreach ($l in Get-Content $s.FullName) {
      $item = $l.Trim(); if (-not $item) { continue }
      $key = "_$($s.BaseName):$item"
      $score = 0
      if (Has-Media $s.BaseName $item @('am_video', 'video')) { $score += 2 }
      if (Has-Media $s.BaseName $item @('fanart', 'am_backdrop')) { $score += 1 }
      if ($avoid.ContainsKey($key)) { $score -= 10 }
      # the same order all month: a hash of month + menu + game
      $sha = [Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes("$Month|$($menu.Name)|$key"))
      $cands += [pscustomobject]@{ key = $key; score = $score; tie = [BitConverter]::ToUInt32($sha, 0) }
    }
  }
  if (-not $cands) { continue }
  $sorted = @($cands | Sort-Object @{ e = 'score'; Descending = $true }, @{ e = 'tie'; Descending = $false })
  $pick = @($sorted | Select-Object -First $Count | ForEach-Object { $_.key })
  # lead with something that is not already a favourite
  $lead = @($pick | Where-Object { -not $most.ContainsKey($_) } | Select-Object -First 1)
  if ($lead) { $pick = @($lead) + @($pick | Where-Object { $_ -ne $lead[0] }) }
  $pl = Join-Path $menu.FullName 'playlists\gameofthemonth.txt'
  New-Item -ItemType Directory -Force (Split-Path $pl) | Out-Null
  [IO.File]::WriteAllLines($pl, [string[]]$pick, $u8)
  $picked[$menu.Name] = $pick
  Write-Host ("game of the month {0} - {1}: {2} games, leading with {3}" -f $Month, $menu.Name, $pick.Count, ($pick[0] -replace '^_[^:]+:', ''))
}
$hist[$Month] = $picked
[IO.File]::WriteAllText($histFile, ($hist | ConvertTo-Json -Depth 5), $u8)
