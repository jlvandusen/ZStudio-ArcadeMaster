<#
.SYNOPSIS
  Keeps a RELEASE install of ArcadeMaster current (James 2026-11-27: "how do we ensure new artwork and engine updates get
  pulled ... when it's installed"). Our own cabinets update through git (ArcadeMaster.exe AutoUpdate); a release install
  has no git, so ArcadeMaster.exe runs this at every start, before the frontend opens (nothing is in use then):
    1. asks GitHub for the newest release (github.com/<Repo>/releases/latest; no account needed)
    2. newer than <Root>\version.txt: downloads ArcadeMaster-<version>-win64.zip, checks its SHA-256
    3. swaps in what is ArcadeMaster's own:
         repo\ (tools, catalog, docs), frontend\<name>\core\ (the engine), our layouts (themes and their art),
         AmPanel.exe + its rule files + ampanel-shim\LEDBlinky.exe, README / LICENSE / Install.ps1;
         ArcadeMaster.exe is staged as ArcadeMaster.exe.new (it is running) and swapped in at the next start
       and never touches the user's own: manifest\, game lists (collections\), launchers.windows\, meta\,
       settings.conf, controls.conf, themes the user added
    4. the art drawn from the user's own games (system cards, hero menus, tiles, lights, search) is drawn again by the
       new tools: the content refresh is due at once (its stamp is removed)
  The replaced folders are kept until the new ones are in place; a failure puts the old ones back. Log:
  <manifest>\release-update.log.
.EXAMPLE
  tools\Update-Release.ps1 -Root C:\ArcadeMaster -ManifestDir C:\ArcadeMaster\manifest -Check
#>
param(
  [Parameter(Mandatory)][string]$Root,
  [string]$ManifestDir = (Join-Path $Root 'manifest'),
  [string]$Repo = 'jlvandusen/ZStudio-ArcadeMaster',
  [switch]$Check,                    # only tell what is available
  [string]$Zip                       # install this release zip (+ <zip>.sha256 next to it) instead of asking GitHub
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $ManifestDir 'release-update.log'
function Say([string]$m) { Write-Host $m; try { Add-Content $log ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $m) -Encoding UTF8 } catch { } }
if (Test-Path (Join-Path $Root 'repo\.git')) { Say 'a git install updates through git (ArcadeMaster.exe), not releases'; return }
# Windows PowerShell 5.1's Remove-Item -Recurse can follow a folder link (junction) and delete what it points to: the
# themes link their main-menu art to ArcadeMaster's (New-MenuHeroArt.py). Links go first, one by one, without following.
function Remove-Safely([string]$p) {
  if (-not (Test-Path -LiteralPath $p)) { return }
  Get-ChildItem -LiteralPath $p -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object { [IO.Directory]::Delete($_.FullName, $false) }
  Remove-Item -LiteralPath $p -Recurse -Force
}
$verFile = Join-Path $Root 'version.txt'
$have = if (Test-Path $verFile) { ((Get-Content $verFile -TotalCount 1) -split '\s+')[0] } else { '0' }

function VersionKey([string]$v) { (($v -split '[^0-9]+') | Where-Object { $_ } | ForEach-Object { '{0:D10}' -f [long]$_ }) -join '.' }
$work = Join-Path $Root '_update'
if ($Zip) {
  # an update from a file (a cabinet without internet: the zip and its .sha256 brought on a USB stick)
  if (-not (Test-Path $Zip) -or -not (Test-Path "$Zip.sha256")) { Say "need $Zip and $Zip.sha256"; return }
  $new = ((Split-Path $Zip -Leaf) -replace '^ArcadeMaster-', '' -replace '-win64\.zip$', '')
  $want = ((Get-Content "$Zip.sha256" -Raw) -split '\s+')[0].Trim().ToLower()
  if ((VersionKey $new) -le (VersionKey $have)) { Say "up to date ($have; the file is $new)"; return }
  if ($Check) { Say "update available from file: $have -> $new"; return }
  if (Test-Path $work) { Remove-Safely $work }
  New-Item -ItemType Directory -Force $work | Out-Null
  $zipFile = $Zip
}
else {
  # 1. the newest release
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  try { $rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'User-Agent' = 'ArcadeMaster-updater'; 'Accept' = 'application/vnd.github+json' } -TimeoutSec 20 }
  catch {
    if ("$($_.Exception.Message)" -match '404') { Say 'update check: no ArcadeMaster release published yet'; return }
    Say "update check: GitHub not reachable ($($_.Exception.Message))"; return
  }
  $zipAsset = $rel.assets | Where-Object { $_.name -like 'ArcadeMaster-*-win64.zip' } | Select-Object -First 1
  $shaAsset = $rel.assets | Where-Object { $_.name -like 'ArcadeMaster-*-win64.zip.sha256' } | Select-Object -First 1
  if (-not $zipAsset -or -not $shaAsset) { Say "update check: release $($rel.tag_name) has no ArcadeMaster zip + .sha256"; return }
  $new = ($zipAsset.name -replace '^ArcadeMaster-', '' -replace '-win64\.zip$', '')
  if ((VersionKey $new) -le (VersionKey $have)) { Say "up to date ($have)"; return }
  if ($Check) { Say "update available: $have -> $new ($($rel.html_url)); it installs the next time ArcadeMaster starts"; return }
  # 2. download
  if (Test-Path $work) { Remove-Safely $work }
  New-Item -ItemType Directory -Force $work | Out-Null
  $zipFile = Join-Path $work $zipAsset.name
  Say "downloading $($zipAsset.name) ($([math]::Round($zipAsset.size / 1MB)) MB) ..."
  & curl.exe -fsSL -o $zipFile $zipAsset.browser_download_url
  if ($LASTEXITCODE) { Say "download failed (curl $LASTEXITCODE) - staying on $have"; return }
  $want = ((Invoke-RestMethod $shaAsset.browser_download_url -Headers @{ 'User-Agent' = 'ArcadeMaster-updater' }) -split '\s+')[0].Trim().ToLower()
}
if (Get-Process retrofe -ErrorAction SilentlyContinue) { Say 'the frontend is open - the update installs at the next start'; return }
$got = (Get-FileHash $zipFile -Algorithm SHA256).Hash.ToLower()
if ($got -ne $want) { Say "checksum mismatch ($got vs $want) - update not installed"; Remove-Safely $work; return }
Expand-Archive $zipFile (Join-Path $work 'new')
$src = Join-Path $work 'new\ArcadeMaster'
if (-not (Test-Path (Join-Path $src 'repo\tools'))) { Say 'the zip is not an ArcadeMaster release - update not installed'; return }

# 3. swap (nothing is running: ArcadeMaster.exe calls this before the frontend starts; AmPanel is stopped here and
#    started again by Start-ArcadeMaster)
if (Get-Process retrofe -ErrorAction SilentlyContinue) { Say 'the frontend is open - the update installs at the next start'; return }
Get-Process AmPanel, LEDBlinky -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase) } | Stop-Process -Force
Start-Sleep 1
$feName = (Get-ChildItem (Join-Path $Root 'frontend') -Directory | Select-Object -First 1).Name
$old = Join-Path $work 'old'
New-Item -ItemType Directory -Force $old | Out-Null
$swaps = @(@{ rel = 'repo' }, @{ rel = "frontend\$feName\core"; from = 'frontend\ArcadeMaster\core' })
foreach ($l in Get-ChildItem (Join-Path $src 'frontend\ArcadeMaster\layouts') -Directory) { $swaps += @{ rel = "frontend\$feName\layouts\$($l.Name)"; from = "frontend\ArcadeMaster\layouts\$($l.Name)" } }
$done = @()
try {
  foreach ($s in $swaps) {
    $dst = Join-Path $Root $s.rel; $from = Join-Path $src $(if ($s.from) { $s.from } else { $s.rel })
    if (-not (Test-Path $from)) { continue }
    $keep = Join-Path $old ($s.rel -replace '[\\/]', '_')
    if (Test-Path $dst) { Move-Item $dst $keep }
    Move-Item $from $dst
    $done += @{ dst = $dst; keep = $keep }
  }
  foreach ($f in 'AmPanel.exe', 'panel-rules.json', 'light-guns.json', 'exit-rules.json', 'ArcadeMaster.ico', 'README.txt', 'LICENSE', 'Install.ps1', 'USER-GUIDE.md') {
    if (Test-Path (Join-Path $src $f)) { Copy-Item (Join-Path $src $f) (Join-Path $Root $f) -Force }
  }
  if (Test-Path (Join-Path $src 'ampanel-shim\LEDBlinky.exe')) { New-Item -ItemType Directory -Force (Join-Path $Root 'ampanel-shim') | Out-Null; Copy-Item (Join-Path $src 'ampanel-shim\LEDBlinky.exe') (Join-Path $Root 'ampanel-shim\LEDBlinky.exe') -Force }
  Copy-Item (Join-Path $src 'ArcadeMaster.exe') (Join-Path $Root 'ArcadeMaster.exe.new') -Force   # swapped in at the next start
  Copy-Item (Join-Path $src 'version.txt') $verFile -Force
}
catch {
  Say "update failed ($($_.Exception.Message)) - putting the previous version back"
  foreach ($d in $done) { if (Test-Path $d.dst) { Remove-Safely $d.dst }; if (Test-Path $d.keep) { Move-Item $d.keep $d.dst } }
  return
}
# 4. the art drawn from this PC's games: due at once with the new tools
Remove-Item (Join-Path $ManifestDir 'content-refresh.stamp') -ErrorAction SilentlyContinue
try { Remove-Safely $work } catch { }
Say "updated $have -> $new (engine, tools, themes, AmPanel; your lists and settings kept); the art is redrawn at this start"
