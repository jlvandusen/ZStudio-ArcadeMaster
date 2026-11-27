<#
.SYNOPSIS
  Menu music for the frontend: off, or one of a few styles built from the music already on this cabinet's drives.
  James, 2026-11-27: "Music too rave music etc or choices in the panel menu too". Tools > Menu Music cycles the styles.

  Styles (each is a playlist, <ManifestDir>\music\<style>.m3u, pointing at the files where they are - nothing copied):
    rave        electronic / NCS releases (NoCopyrightSounds) and remixes
    synthwave   cyberpunk / dark synth (the CoinOPS LEGENDS 3 set)
    80s         the 80s pop set the CoinOPS builds carry
    computer    C64 / Amiga game-music remixes (Computer Classics)
    mix         everything above
    off         no menu music
  RetroFE's own music player plays it (settings.conf musicPlayer.*): shuffled, looping, at menu volume, never in a game.
  The music folders found are remembered in <ManifestDir>\music\catalog.json (rescanned after 7 days or with -Rescan).
.EXAMPLE
  tools\Set-MenuMusic.ps1 -RetroFE R:\ArcadeMaster\frontend\LEGENDS-am -ManifestDir R:\ArcadeMaster\manifest -Style rave
  tools\Set-MenuMusic.ps1 ... -Style next      # the next style after the current one (Tools > Menu Music)
#>
param(
  [Parameter(Mandatory)][string]$RetroFE,
  [Parameter(Mandatory)][string]$ManifestDir,
  [ValidateSet('off', 'rave', 'synthwave', '80s', 'computer', 'mix', 'next', 'show')][string]$Style = 'show',
  [int]$Volume = 55,
  [switch]$Rescan
)
$ErrorActionPreference = 'Stop'
$order = @('off', 'rave', 'synthwave', '80s', 'computer', 'mix')
$sc = Join-Path $RetroFE 'settings.conf'
$musicDir = Join-Path $ManifestDir 'music'
New-Item -ItemType Directory -Force $musicDir | Out-Null
function Get-Conf([string]$k) { $m = Select-String -Path $sc -Pattern "^\s*$([regex]::Escape($k))\s*=\s*(.*)$" -ErrorAction SilentlyContinue | Select-Object -Last 1; if ($m) { $m.Matches[0].Groups[1].Value.Trim() } }
function Set-Conf([string]$k, [string]$v) {
  $l = [Collections.Generic.List[string]](Get-Content $sc); $done = $false
  for ($i = 0; $i -lt $l.Count; $i++) { if ($l[$i] -match "^\s*$([regex]::Escape($k))\s*=") { $l[$i] = "$k = $v"; $done = $true } }
  if (-not $done) { $l.Add("$k = $v") }
  # the frontend can hold the file for a moment: a few tries
  for ($t = 0; $t -lt 10; $t++) { try { Set-Content $sc $l -Encoding ascii -ErrorAction Stop; return } catch { Start-Sleep -Milliseconds 300 } }
  throw "settings.conf stayed locked: $k not set"
}
$stateFile = Join-Path $musicDir 'style.txt'
$current = if (Test-Path $stateFile) { (Get-Content $stateFile -Raw).Trim() } else { 'off' }
if ($Style -eq 'show') { Write-Host "menu music: $current"; return }
if ($Style -eq 'next') { $Style = $order[($order.IndexOf($current) + 1) % $order.Count] }

# the tracks on this cabinet: every folder named music (or bgm / soundtrack) up to 3 levels under each fixed drive
$catalog = Join-Path $musicDir 'catalog.json'
$tracks = $null
if (-not $Rescan -and (Test-Path $catalog) -and ((Get-Date) - (Get-Item $catalog).LastWriteTime).TotalDays -lt 7) { $tracks = Get-Content $catalog -Raw | ConvertFrom-Json }
if (-not $tracks) {
  $found = New-Object Collections.Generic.List[object]
  $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  # local fixed drives only: the NAS (Z:) holds whole drive backups, thousands of unrelated songs (2026-11-27)
  foreach ($d in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { $_.DeviceID + '\' }) {
    $dirs = Get-ChildItem $d -Directory -Recurse -Depth 3 -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(music|bgm|soundtrack)$' -and $_.FullName -notmatch '\\(Windows|Program Files|\$Recycle)' }
    foreach ($dir in $dirs) {
      foreach ($f in Get-ChildItem $dir.FullName -File -Recurse -Include *.mp3, *.ogg, *.flac -ErrorAction SilentlyContinue) {
        if (-not $seen.Add($f.Name)) { continue }   # the same song in several builds: once
        $n = $f.BaseName; $p = $f.FullName
        $kind = if ($n -match 'NCS|Remix|Alan Walker|Egzod|Electro|Dubstep|House|Trance|Techno|EDM|Rave|Drum ?(&|and) ?Bass') { 'rave' }
                elseif ($p -match 'Computer Classics') { 'computer' }
                elseif ($p -match 'LEGENDS 3 Vertical' -or $n -match 'Cyber|Synth|Dystop|Neon|Outrun|Chill|Dark|Night ?Drive') { 'synthwave' }
                else { '80s' }
        $found.Add([pscustomobject]@{ path = $p; kind = $kind })
      }
    }
  }
  $tracks = $found.ToArray()
  $tracks | ConvertTo-Json -Depth 3 | Set-Content $catalog -Encoding UTF8
}

if ($Style -eq 'off') {
  Set-Conf 'musicPlayer.enabled' 'no'
  Set-Content $stateFile 'off' -Encoding ascii
  Write-Host 'menu music: OFF'
  return
}
$pick = @($tracks | Where-Object { $Style -eq 'mix' -or $_.kind -eq $Style } | ForEach-Object { $_.path } | Where-Object { Test-Path -LiteralPath $_ })
if (-not $pick.Count) { Write-Host "menu music: no $Style tracks on this cabinet - left as $current"; return }
$m3u = Join-Path $musicDir "$Style.m3u"
Set-Content $m3u (@('#EXTM3U') + $pick) -Encoding UTF8
Set-Conf 'musicPlayer.enabled' 'yes'
Set-Conf 'musicPlayer.m3uplaylist' $m3u
Set-Conf 'musicPlayer.autostart' 'yes'
Set-Conf 'musicPlayer.shuffle' 'yes'
Set-Conf 'musicPlayer.loop' 'yes'
Set-Conf 'musicPlayer.volume' "$Volume"
Set-Conf 'musicPlayer.playInGame' 'no'
Set-Content $stateFile $Style -Encoding ascii
Write-Host ("menu music: {0} ({1} tracks)" -f $Style.ToUpper(), $pick.Count)
