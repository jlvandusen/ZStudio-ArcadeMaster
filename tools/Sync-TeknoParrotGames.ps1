<#
.SYNOPSIS
  Shares TeknoParrot games between cabinets through the NAS (James, 2026-11-26: "race 2 had more teknoparrot games so need
  to copy them up to Z and then have race1 pull them").

  -Inventory   writes this cabinet's TeknoParrot games to Z:\ArcadeMaster\reports\games\<PC>-teknoparrot.json: every
               UserProfiles\*.xml of every install, its game folder and whether the game files are there, with size.
  -Publish     compares with another cabinet's inventory (-For <PC>) and copies each game this cabinet has and that one
               lacks to Z:\ArcadeMaster\library\teknoparrot\<profile>\ : game\ (the game folder), <profile>.xml (the
               TeknoParrot profile) and entry.json (where it goes, every file's size). An entry already there is skipped.
  -Pull        on the other cabinet: every library entry whose game this cabinet lacks is copied in - the game folder to
               the same place relative to the TeknoParrot install (the DRIVE layout is the same on every racing cabinet,
               so the profile's relative GamePath works unchanged) and the profile into UserProfiles. Never overwrites:
               an existing game folder or profile is left alone and reported. Every file is size-checked after copying.
               Then run Rebuild Game Menus (or New-RetroFECollections) so the games show in the menus.
  Dry run by default for -Publish / -Pull; -Apply copies.
.EXAMPLE
  tools\Sync-TeknoParrotGames.ps1 -Inventory
  tools\Sync-TeknoParrotGames.ps1 -Publish -For DESKTOP-RACE1 -Apply
  tools\Sync-TeknoParrotGames.ps1 -Pull -Apply
#>
param(
  [switch]$Inventory, [switch]$Publish, [switch]$Pull,
  [string]$For,
  [string[]]$Install = @('E:\DRIVE Collection\emulators\TeknoParrot', 'E:\DRIVE Collection\emulators\TeknoParrotMulti', 'D:\Emulators\TeknoParrot', 'D:\FLIGHT Collection\emulators\TeknoParrot'),
  [string]$Share = 'Z:\ArcadeMaster',
  [switch]$Apply
)
$ErrorActionPreference = 'Stop'
$invDir = Join-Path $Share 'reports\games'; $lib = Join-Path $Share 'library\teknoparrot'
$u8 = New-Object Text.UTF8Encoding $false
function Get-Games {
  foreach ($tp in $Install) {
    if (-not (Test-Path -LiteralPath (Join-Path $tp 'UserProfiles'))) { continue }
    foreach ($p in Get-ChildItem -LiteralPath (Join-Path $tp 'UserProfiles') -Filter *.xml -File) {
      $x = $null; try { [xml]$x = Get-Content -LiteralPath $p.FullName -Raw } catch { continue }
      $gp = "$($x.GameProfile.GamePath)"; if (-not $gp) { continue }
      $full = if ([IO.Path]::IsPathRooted($gp)) { $gp } else { [IO.Path]::GetFullPath((Join-Path $tp $gp)) }
      $ok = Test-Path -LiteralPath $full
      # the game folder: the folder under the collection's roms\ (or the exe's folder when it is elsewhere)
      $dir = Split-Path $full; $m = [regex]::Match($full, '(?i)^(.*\\roms\\[^\\]+)\\'); if ($m.Success) { $dir = $m.Groups[1].Value }
      [pscustomobject]@{ install = $tp; profile = $p.BaseName; profileFile = $p.FullName; game = "$($x.GameProfile.GameName)"; gamePath = $gp; exe = $full; dir = $dir; ok = $ok
        relDir = $(try { [IO.Path]::GetRelativePath($tp, $dir) } catch { $null }) }
    }
  }
}
function Get-Size([string]$d) { $s = Get-ChildItem -LiteralPath $d -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum; [pscustomobject]@{ bytes = [int64]$s.Sum; files = $s.Count } }

if ($Inventory) {
  $games = @(Get-Games)
  $rows = foreach ($g in $games) { $sz = if ($g.ok) { Get-Size $g.dir } else { $null }; [ordered]@{ install = Split-Path $g.install -Leaf; profile = $g.profile; game = $g.game; ok = $g.ok; relDir = $g.relDir; gb = $(if ($sz) { [math]::Round($sz.bytes / 1GB, 2) } else { 0 }); files = $(if ($sz) { $sz.files } else { 0 }) } }
  New-Item -ItemType Directory -Force $invDir | Out-Null
  $out = Join-Path $invDir "$env:COMPUTERNAME-teknoparrot.json"
  [IO.File]::WriteAllText($out, ([ordered]@{ machine = $env:COMPUTERNAME; written = (Get-Date).ToString('s'); games = @($rows) } | ConvertTo-Json -Depth 4), $u8)
  Write-Host ("inventory: {0} profiles, {1} with game files ({2:N1} GB) -> {3}" -f $games.Count, @($games | Where-Object ok).Count, (@($rows | ForEach-Object { $_.gb }) | Measure-Object -Sum).Sum, $out)
  return
}

if ($Publish) {
  if (-not $For) { throw '-Publish needs -For <cabinet> (whose inventory to compare with)' }
  $other = Join-Path $invDir "$For-teknoparrot.json"
  if (-not (Test-Path $other)) { throw "no inventory from $For yet ($other) - run Sync-TeknoParrotGames.ps1 -Inventory there" }
  $has = @{}; foreach ($g in (Get-Content $other -Raw | ConvertFrom-Json).games) { if ($g.ok) { $has[$g.profile.ToLower()] = $true } }
  $todo = @(Get-Games | Where-Object { $_.ok -and -not $has.ContainsKey($_.profile.ToLower()) -and $_.relDir })
  $total = 0
  foreach ($g in $todo) {
    $dst = Join-Path $lib $g.profile
    if (Test-Path (Join-Path $dst 'entry.json')) { Write-Host "  already in the library: $($g.profile)"; continue }
    $sz = Get-Size $g.dir; $total += $sz.bytes
    Write-Host ("  {0} {1} ({2}): {3:N2} GB, {4} files" -f $(if ($Apply) { 'PUBLISH' } else { 'WOULD PUBLISH' }), $g.profile, $g.game, ($sz.bytes / 1GB), $sz.files)
    if (-not $Apply) { continue }
    New-Item -ItemType Directory -Force $dst | Out-Null
    robocopy $g.dir (Join-Path $dst 'game') /E /COPY:DAT /R:2 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "copy of $($g.profile) failed (robocopy $LASTEXITCODE)" }
    Copy-Item -LiteralPath $g.profileFile (Join-Path $dst "$($g.profile).xml") -Force
    $files = @(Get-ChildItem -LiteralPath $g.dir -Recurse -File | ForEach-Object { [ordered]@{ path = $_.FullName.Substring($g.dir.Length).TrimStart('\'); bytes = $_.Length } })
    $entry = [ordered]@{ profile = $g.profile; game = $g.game; from = $env:COMPUTERNAME; published = (Get-Date).ToString('s'); install = (Split-Path $g.install -Leaf); relDir = $g.relDir; gamePath = $g.gamePath; files = $files }
    [IO.File]::WriteAllText((Join-Path $dst 'entry.json'), ($entry | ConvertTo-Json -Depth 4), $u8)   # written last: a half copy has no entry.json
  }
  Write-Host ("publish for {0}: {1} game(s), {2:N1} GB {3}" -f $For, $todo.Count, ($total / 1GB), $(if ($Apply) { 'copied to ' + $lib } else { '(dry run - add -Apply)' }))
  return
}

if ($Pull) {
  if (-not (Test-Path $lib)) { Write-Host "nothing in $lib"; return }
  $mine = @{}; foreach ($g in Get-Games) { if ($g.ok) { $mine[$g.profile.ToLower()] = $true } }
  $n = 0
  foreach ($e in Get-ChildItem $lib -Directory) {
    $ef = Join-Path $e.FullName 'entry.json'; if (-not (Test-Path $ef)) { continue }   # still being published
    $entry = Get-Content $ef -Raw | ConvertFrom-Json
    if ($mine.ContainsKey($entry.profile.ToLower())) { continue }
    $tp = @($Install | Where-Object { (Split-Path $_ -Leaf) -ieq $entry.install -and (Test-Path -LiteralPath $_) })[0]
    if (-not $tp) { Write-Host "  SKIP $($entry.profile): no '$($entry.install)' install on this cabinet"; continue }
    $dstDir = [IO.Path]::GetFullPath((Join-Path $tp $entry.relDir)); $dstXml = Join-Path $tp "UserProfiles\$($entry.profile).xml"
    if (Test-Path -LiteralPath $dstDir) { Write-Host "  SKIP $($entry.profile): $dstDir already exists (not overwritten)"; continue }
    if (Test-Path -LiteralPath $dstXml) { Write-Host "  NOTE $($entry.profile): profile exists, only the game folder is copied" }
    $gb = (@($entry.files | ForEach-Object { [int64]$_.bytes }) | Measure-Object -Sum).Sum / 1GB
    Write-Host ("  {0} {1} ({2}): {3:N2} GB -> {4}" -f $(if ($Apply) { 'PULL' } else { 'WOULD PULL' }), $entry.profile, $entry.game, $gb, $dstDir)
    $n++
    if (-not $Apply) { continue }
    robocopy (Join-Path $e.FullName 'game') $dstDir /E /COPY:DAT /R:2 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "copy of $($entry.profile) failed (robocopy $LASTEXITCODE)" }
    $bad = @($entry.files | Where-Object { $f = Join-Path $dstDir $_.path; -not (Test-Path -LiteralPath $f) -or (Get-Item -LiteralPath $f).Length -ne [int64]$_.bytes })
    if ($bad) { throw "$($entry.profile): $($bad.Count) file(s) missing or the wrong size after copying - check $dstDir" }
    if (-not (Test-Path -LiteralPath $dstXml)) { Copy-Item -LiteralPath (Join-Path $e.FullName "$($entry.profile).xml") $dstXml }
  }
  Write-Host ("pull: {0} game(s) {1}" -f $n, $(if ($Apply) { 'copied in - run Rebuild Game Menus so they show' } else { '(dry run - add -Apply)' }))
}
