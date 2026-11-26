<#
.SYNOPSIS
  Play time, "Most played" and save backups - run by RetroFE's launcher hooks around every game (Set-GameHooks.ps1
  puts them in launchers.windows\*.conf). Both hooks run hidden and RetroFE does not wait for them.

  -Event start   remembers which game started and when (manifest\play\current.json). Nothing else: the game is loading.
  -Event end     adds the session to manifest\playtime.json (plays, seconds, first / last played per game), writes a
                 "mostplayed" playlist (top 20, at least a minute played) into every menu collection that lists those
                 games, then backs up saves (tools\saves.json):
                   - each save set whose files changed since its last backup is zipped into
                     <dest>\<COMPUTERNAME>\<set>\slot-N.zip, N rotating 1..keep (old versions are overwritten, never
                     deleted: a delete on the NAS only moves the file to its recycle bin);
                   - TeknoParrot / PC games keep saves in their own folder: files written there during play are learned
                     per game (manifest\saves-learned.json) and backed up as set "game-<id>".
  "Recently played" is RetroFE's own lastplayed playlist (lastplayedSize, default 10). RetroFE reads playlists when a
  collection is built, so Most played shows the new order from the next start of the frontend.
.EXAMPLE
  tools\Record-GamePlay.ps1 -Event start -Item daytona -Collection MAME -RetroFE D:\ArcadeMaster\frontend\DRIVE
  tools\Record-GamePlay.ps1 -Event end   -Item daytona -Collection MAME -RetroFE D:\ArcadeMaster\frontend\DRIVE
#>
param(
  [Parameter(Mandatory)][Alias('Event')][ValidateSet('start', 'end')][string]$Phase,   # -Event in the launcher hooks ($Event itself is a PowerShell automatic variable)
  [Parameter(Mandatory)][string]$Item,
  [string]$Collection = '',
  [Parameter(Mandatory)][string]$RetroFE,
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [string]$Dest,                     # default: saves.json "dest"
  [switch]$NoBackup
)
$ErrorActionPreference = 'Stop'
$playDir = Join-Path $ManifestDir 'play'; New-Item -ItemType Directory -Force $playDir | Out-Null
$logFile = Join-Path $playDir 'play.log'
function Write-PlayLog([string]$s) { try { Add-Content $logFile ("[{0}] {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $s) -Encoding UTF8 } catch { } }
$u8 = New-Object Text.UTF8Encoding $false
function Save-Json($obj, [string]$path) { $tmp = "$path.tmp"; [IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json -Depth 8), $u8); Move-Item $tmp $path -Force }
$cur = Join-Path $playDir 'current.json'
$key = "_$($Collection):$Item"

# JoyToKey (CoinOPS builds run it for the menus) is closed while a game runs and started again after: the games read
# the wheel themselves, and JoyToKey's keys on top of them double the inputs (James, 2026-11-26: "close it when playing
# these as the wheel shows as a keyboard control already")
$jtkFile = Join-Path $playDir 'joytokey-paused.txt'
if ($Phase -eq 'start') {
  $jtk = @(Get-Process JoyToKey -ErrorAction SilentlyContinue)
  if ($jtk) { try { Set-Content $jtkFile $jtk[0].Path; $jtk | Stop-Process -Force; Write-PlayLog "JoyToKey closed for the game ($($jtk[0].Path))" } catch { } }
  # the mouse pointer is hidden while the game runs (Set-GameCursor -Hide; the end hook and the boot show it again)
  try { & (Join-Path $PSScriptRoot 'Set-GameCursor.ps1') -Hide | Out-Null } catch { }
  Save-Json ([ordered]@{ key = $key; item = $Item; collection = $Collection; start = (Get-Date).ToString('o') }) $cur
  Write-PlayLog "start $key"
  return
}

# ------------------------------------------------------------------ end: the mouse pointer back
try { & (Join-Path $PSScriptRoot 'Set-GameCursor.ps1') -Show | Out-Null } catch { }
# ------------------------------------------------------------------ end: JoyToKey back for the menus
if (Test-Path $jtkFile) {
  $jp = "$(Get-Content $jtkFile -Raw)".Trim(); Remove-Item $jtkFile -ErrorAction SilentlyContinue
  if ($jp -and (Test-Path $jp) -and -not (Get-Process JoyToKey -ErrorAction SilentlyContinue)) { try { Start-Process $jp -WorkingDirectory (Split-Path $jp) -WindowStyle Minimized; Write-PlayLog 'JoyToKey started again (menus)' } catch { } }
}
# ------------------------------------------------------------------ end: play time
$now = Get-Date
$start = $null
if (Test-Path $cur) { try { $c = Get-Content $cur -Raw | ConvertFrom-Json; if ($c.key -eq $key) { $start = [datetime]$c.start } } catch { } }
$secs = if ($start) { [int][Math]::Min(12 * 3600, [Math]::Max(0, ($now - $start).TotalSeconds)) } else { 0 }   # no start seen: counts the play, not the time
$ptFile = Join-Path $ManifestDir 'playtime.json'
$pt = [ordered]@{}
if (Test-Path $ptFile) { try { $o = Get-Content $ptFile -Raw | ConvertFrom-Json; foreach ($p in $o.games.PSObject.Properties) { $pt[$p.Name] = $p.Value } } catch { } }
$e = $pt[$key]
if (-not $e) { $e = [pscustomobject]@{ item = $Item; collection = $Collection; plays = 0; seconds = 0; first = $now.ToString('s'); last = $null }; $pt[$key] = $e }
$e.plays = [int]$e.plays + 1; $e.seconds = [int]$e.seconds + $secs; $e.last = $now.ToString('s')
Save-Json ([ordered]@{ updated = $now.ToString('s'); games = $pt }) $ptFile
Remove-Item $cur -ErrorAction SilentlyContinue
Write-PlayLog ("end {0}: {1} s (total {2} plays, {3} min)" -f $key, $secs, $e.plays, [int]($e.seconds / 60))

# ------------------------------------------------------------------ Most played playlists
# every collection that lists games from .sub files (Racing, Flight, Lightgun, Arcade ...) gets the games it holds
try {
  $ranked = @($pt.GetEnumerator() | Where-Object { [int]$_.Value.seconds -ge 60 } | Sort-Object { [int]$_.Value.seconds } -Descending)
  foreach ($col in Get-ChildItem (Join-Path $RetroFE 'collections') -Directory) {
    $subs = @(Get-ChildItem $col.FullName -Filter *.sub -File -ErrorAction SilentlyContinue)
    if (-not $subs) { continue }
    $members = @{}
    foreach ($s in $subs) { foreach ($l in Get-Content $s.FullName) { if ($l.Trim()) { $members["_$($s.BaseName):$($l.Trim())"] = $true } } }
    $top = @($ranked | Where-Object { $members.ContainsKey($_.Key) } | Select-Object -First 20 | ForEach-Object { $_.Key })
    $pl = Join-Path $col.FullName 'playlists\mostplayed.txt'
    if ($top) { New-Item -ItemType Directory -Force (Split-Path $pl) | Out-Null; [IO.File]::WriteAllLines($pl, [string[]]$top, $u8) }
  }
} catch { Write-PlayLog "most played: $($_.Exception.Message)" }

if ($NoBackup) { return }

# ------------------------------------------------------------------ save backups
try {
  $cfg = Get-Content (Join-Path $PSScriptRoot 'saves.json') -Raw | ConvertFrom-Json
  if (-not $Dest) { $Dest = $cfg.dest }
  $keep = [Math]::Max(1, [int]$cfg.keep)
  $base = Join-Path $Dest $env:COMPUTERNAME
  # the NAS share must be there (Z:\ArcadeMaster); the saves folder itself is made on the first backup
  if (-not (Test-Path (Split-Path $Dest))) { Write-PlayLog "saves: $(Split-Path $Dest) not reachable - skipped"; return }
  $stFile = Join-Path $ManifestDir 'saves-state.json'
  $state = @{}; if (Test-Path $stFile) { try { $so = Get-Content $stFile -Raw | ConvertFrom-Json; foreach ($p in $so.PSObject.Properties) { $state[$p.Name] = $p.Value } } catch { } }
  Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

  # one set = a list of files (full paths) zipped with paths relative to $root
  function Backup-Set([string]$name, [string]$root, [IO.FileInfo[]]$files) {
    if (-not $files) { return }
    $fp = "$($files.Count)|$(($files | Measure-Object Length -Sum).Sum)|$(($files | ForEach-Object { $_.LastWriteTimeUtc.Ticks } | Measure-Object -Maximum).Maximum)"
    $st = $state[$name]
    if ($st -and $st.fingerprint -eq $fp) { return }
    $slot = if ($st) { ([int]$st.slot % $keep) + 1 } else { 1 }
    $dir = Join-Path $base ($name -replace '[\\/:*?"<>|]', '_'); New-Item -ItemType Directory -Force $dir | Out-Null
    $tmp = Join-Path $env:TEMP ("am-save-" + [guid]::NewGuid().ToString('N') + '.zip')
    $zip = [IO.Compression.ZipFile]::Open($tmp, 'Create')
    try {
      foreach ($f in $files) {
        $rel = if ($f.FullName.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $f.FullName.Substring($root.Length).TrimStart('\') } else { $f.FullName -replace ':', '' }
        try { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $rel, 'Optimal') } catch { }   # a file the game still holds open is skipped
      }
    } finally { $zip.Dispose() }
    Copy-Item $tmp (Join-Path $dir "slot-$slot.zip") -Force; Remove-Item $tmp -ErrorAction SilentlyContinue
    $idx = Join-Path $dir 'index.json'
    $slots = [ordered]@{}; if (Test-Path $idx) { try { $io = Get-Content $idx -Raw | ConvertFrom-Json; foreach ($p in $io.slots.PSObject.Properties) { $slots[$p.Name] = $p.Value } } catch { } }
    $slots["slot-$slot"] = [ordered]@{ time = (Get-Date).ToString('s'); afterGame = $key; files = $files.Count; root = $root }
    Save-Json ([ordered]@{ set = $name; machine = $env:COMPUTERNAME; keep = $keep; slots = $slots }) $idx
    $state[$name] = [pscustomobject]@{ fingerprint = $fp; slot = $slot; time = (Get-Date).ToString('s') }
    $script:backedUp += "$name (slot $slot, $($files.Count) files)"
  }
  $script:backedUp = @()

  foreach ($s in $cfg.sets) {
    $files = @()
    foreach ($rp in $s.paths) {
      foreach ($dir in @(Resolve-Path -Path (Join-Path $RetroFE $rp) -ErrorAction SilentlyContinue)) {
        $files += @(Get-ChildItem -LiteralPath $dir.ProviderPath -Recurse -File -ErrorAction SilentlyContinue)
      }
    }
    Backup-Set $s.name $RetroFE $files
  }

  # learned saves: what this game wrote in its own folder while it ran (TeknoParrot, PC games)
  if ($start) {
    $gameDir = $null
    $gj = Join-Path $ManifestDir 'games.json'
    if (Test-Path $gj) {
      $games = (Get-Content $gj -Raw | ConvertFrom-Json).games
      $g = @($games | Where-Object { @($_.sources | Where-Object { $_.collection -eq $Collection -and $_.item -eq $Item }).Count -or @($_.variants.PSObject.Properties | Where-Object { $_.Value.profile -eq $Item }).Count }) | Select-Object -First 1
      if ($g) { $gameDir = @($g.variants.PSObject.Properties | Where-Object { $_.Value.gameDir -and (Test-Path -LiteralPath $_.Value.gameDir) } | ForEach-Object { $_.Value.gameDir })[0] }
    }
    $lf = Join-Path $ManifestDir 'saves-learned.json'
    $learned = @{}; if (Test-Path $lf) { try { $lo = Get-Content $lf -Raw | ConvertFrom-Json; foreach ($p in $lo.PSObject.Properties) { $learned[$p.Name] = @($p.Value) } } catch { } }
    if ($gameDir) {
      $max = [int64]$cfg.learnMaxMB * 1MB; $skip = @($cfg.learnSkipExt)
      $since = $start.AddSeconds(-5)
      $new = @(Get-ChildItem -LiteralPath $gameDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $since -and $_.Length -le $max -and $skip -notcontains $_.Extension.ToLower() } | ForEach-Object { $_.FullName })
      if ($new) { $learned[$key] = @(@($learned[$key]) + $new | Where-Object { $_ } | Select-Object -Unique); Save-Json $learned $lf }
    }
    $mine = @(@($learned[$key]) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | ForEach-Object { Get-Item -LiteralPath $_ })
    if ($mine -and $gameDir) { Backup-Set ("game-" + ($Item -replace '[\\/:*?"<>|]', '_')) $gameDir $mine }
  }

  Save-Json $state $stFile
  Write-PlayLog ("saves: " + $(if ($script:backedUp) { $script:backedUp -join '; ' } else { 'nothing changed' }))
} catch { Write-PlayLog "saves failed: $($_.Exception.Message)" }
