<#
.SYNOPSIS
  Checks every emulator the menus use (<RetroFE>\emulators) against its newest official release, and updates the ones
  that can be updated safely (catalog\emulators.json says which and how). System Health shows the result; Tools >
  Emulator Updates shows it as tiles and offers each update.

  Check (default): installed version, newest version, what can be done; writes <ManifestDir>\emulator-versions.json.
  -Update <id>: download the official release (GitHub or the project's own server), check it (SHA-256 GitHub publishes,
  else the size it lists, else the archive's own test), unpack it beside the emulator, then copy it in:
    - files the catalog keeps (settings, saves, controller profiles, our wheel bindings, ROMs) are never overwritten;
    - every file that IS replaced is first copied to <emulator>\am-update-backup-<time>\ (copy it back to undo);
    - nothing is deleted; am-version.txt records the version.
  Refuses while that emulator is running. MAME is shown only (new MAME needs matching ROM sets), TeknoParrot uses its
  own updater, Model 2 has no newer release. AM_SYSTEM_DRYRUN=1: downloads and checks, then prints the copy plan only.
.EXAMPLE
  tools\Update-Emulators.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE-coinops
  tools\Update-Emulators.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE-coinops -Update supermodel
#>
param(
  [Parameter(Mandatory)][string]$RetroFE,
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [string]$Update,
  [string]$DownloadDir = 'D:\ArcadeMaster\_downloads\emulators',
  [string]$Catalog
)
$ErrorActionPreference = 'Stop'
if (-not $Catalog) { $Catalog = Join-Path (Split-Path $PSScriptRoot) 'catalog\emulators.json' }
$cat = (Get-Content -LiteralPath $Catalog -Raw | ConvertFrom-Json).emulators
$emuRoot = Join-Path $RetroFE 'emulators'
$ua = 'ArcadeMaster-cabinet'
$dry = $env:AM_SYSTEM_DRYRUN -eq '1'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-Json([string]$url) {
  $h = @{ 'User-Agent' = $ua; Accept = 'application/vnd.github+json' }
  Invoke-RestMethod -Uri $url -Headers $h -TimeoutSec 20
}
function Get-Installed($e, [string]$dir) {
  $vf = Join-Path $dir 'am-version.txt'
  if (Test-Path -LiteralPath $vf) { return (Get-Content -LiteralPath $vf -TotalCount 1).Trim() }
  $exe = Join-Path $dir $e.exe
  if (-not (Test-Path -LiteralPath $exe)) { return $null }
  if ($e.version.fileVersion) { $i = (Get-Item -LiteralPath $exe).VersionInfo; return (@($i.ProductVersion, $i.FileVersion) | Where-Object { $_ } | Select-Object -First 1) }
  if ($e.version.file) { if (Test-Path -LiteralPath (Join-Path $dir $e.version.file)) { return $e.version.ifFile }; return 'unknown' }
  if ($e.version.ascii) { $m = [regex]::Match([Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($exe)), $e.version.ascii); if ($m.Success) { return $m.Groups[1].Value } }
  return 'unknown'
}
function Get-Latest($e) {
  $l = $e.latest
  if ($l.none) { return @{ version = $null; why = $l.none } }
  if ($l.github) {
    $j = Get-Json "https://api.github.com/repos/$($l.github)/releases/latest"
    $v = [string]$j.tag_name
    if ($l.tagRx) { $m = [regex]::Match($v, $l.tagRx); if ($m.Success -and $l.tagFormat) { $v = $l.tagFormat -replace '\{1\}', $m.Groups[1].Value -replace '\{2\}', $m.Groups[2].Value } }
    $asset = $null; if ($e.asset) { $asset = @($j.assets | Where-Object { $_.name -match $e.asset }) | Select-Object -First 1 }
    return @{ version = ($v -replace '^v', ''); tag = $j.tag_name; date = $j.published_at; asset = $asset }
  }
  if ($l.githubTags) {
    $all = Get-Json "https://api.github.com/repos/$($l.githubTags)/tags?per_page=100"   # PowerShell 5.1 hands the array down as ONE object: unroll it
    $tags = @(@($all) | ForEach-Object { $_ } | ForEach-Object { [string]$_.name } | Where-Object { $_ -match $l.tagRx })
    $v = $tags | Sort-Object { [int]$_ } -Descending | Select-Object -First 1
    return @{ version = $v; tag = $v; url = ($e.download -replace '\{v\}', $v) }
  }
}
function Get-Norm([string]$v) { (($v -replace '^v', '') -replace '-git-[0-9a-f]+$', '').ToLower() }

# ---- check
$rows = @()
foreach ($e in $cat) {
  $dirs = @(Get-ChildItem -LiteralPath $emuRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $e.folder -and (Test-Path -LiteralPath (Join-Path $_.FullName $e.exe)) })
  foreach ($d in $dirs) {
    $inst = Get-Installed $e $d.FullName
    $lat = $null; $err = $null
    try { $lat = Get-Latest $e } catch { $err = $_.Exception.Message }
    $status = if ($err) { 'unknown' } elseif (-not $lat.version) { 'final' } elseif ((Get-Norm $inst) -eq (Get-Norm $lat.version)) { 'newest' } else { 'newer' }
    $rows += [pscustomobject][ordered]@{
      id = $e.id; name = $e.name; folder = $d.Name; path = $d.FullName; installed = $inst
      latest = $(if ($lat) { $lat.version } else { $null }); status = $status; action = $e.action
      note = $(if ($err) { "could not check: $err" } elseif ($lat -and $lat.why) { $lat.why } else { $e.note }); warn = $e.warn
    }
  }
}
New-Item -ItemType Directory -Force $ManifestDir | Out-Null
$out = @{ checked = (Get-Date -Format s); emulators = $rows }
[IO.File]::WriteAllText((Join-Path $ManifestDir 'emulator-versions.json'), ($out | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))

if (-not $Update) {
  foreach ($r in $rows) {
    $what = switch ($r.status) {
      'newer' { switch ($r.action) { 'update' { 'UPDATE AVAILABLE (Tools > Emulator Updates)' } 'report' { 'newer exists - shown only' } 'own-updater' { 'use its own updater' } default { 'newer exists' } } }
      'newest' { 'newest' } 'final' { if ($r.action -eq 'own-updater') { 'checks itself - Tools > Emulator Updates opens its updater' } else { 'no newer release' } } default { 'could not check' }
    }
    Write-Host ("{0,-26} {1,-24} -> {2,-26} {3}" -f $r.name, $r.installed, $(if ($r.latest) { $r.latest } else { '-' }), $what)
  }
  $n = @($rows | Where-Object { $_.status -eq 'newer' -and $_.action -eq 'update' }).Count
  Write-Host "emulators: $(@($rows).Count) checked, $n can be updated"
  return
}

# ---- update one
$r = @($rows | Where-Object { $_.id -eq $Update }) | Select-Object -First 1
$e = @($cat | Where-Object { $_.id -eq $Update }) | Select-Object -First 1
if (-not $r) { throw "no emulator '$Update' in $emuRoot" }
if ($e.action -ne 'update') { Write-Host "$($e.name): $($r.note)"; return }
if ($r.status -eq 'newest') { Write-Host "$($e.name) is already the newest ($($r.installed))"; return }
$procName = [IO.Path]::GetFileNameWithoutExtension($e.exe)
if (Get-Process -Name $procName -ErrorAction SilentlyContinue) { throw "$($e.name) is running - close the game first" }
$lat = Get-Latest $e
$url = if ($lat.asset) { $lat.asset.browser_download_url } else { $lat.url }
if (-not $url) { throw "no download found for $($e.name) $($lat.version)" }
New-Item -ItemType Directory -Force $DownloadDir | Out-Null
$file = Join-Path $DownloadDir ([IO.Path]::GetFileName(([uri]$url).AbsolutePath))
if (-not (Test-Path -LiteralPath $file)) { Write-Host "downloading $url"; & curl.exe -sSL -A $ua -o "$file.part" $url; if ($LASTEXITCODE) { throw "download failed ($LASTEXITCODE)" }; Move-Item -LiteralPath "$file.part" $file -Force }
# check the download
$sz = (Get-Item -LiteralPath $file).Length
if ($lat.asset -and $lat.asset.digest -match '^sha256:([0-9a-f]{64})$') {
  if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLower() -ne $Matches[1]) { Remove-Item -LiteralPath $file; throw 'download does not match the SHA-256 GitHub publishes - removed' }
  Write-Host 'download checked: SHA-256 matches GitHub'
} elseif ($lat.asset) {
  if ($sz -ne [long]$lat.asset.size) { Remove-Item -LiteralPath $file; throw 'download size differs from GitHub - removed' }
  Write-Host 'download checked: size matches GitHub (this release publishes no SHA-256)'
}
$sevenZip = @('C:\Program Files\7-Zip\7z.exe', 'C:\Program Files (x86)\7-Zip\7z.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
$stage = Join-Path $env:TEMP ("am-emu-$($e.id)-" + (Get-Date -Format 'yyyyMMddHHmmss'))
New-Item -ItemType Directory -Force $stage | Out-Null
if ($file -match '\.zip$') { Add-Type -AssemblyName System.IO.Compression.FileSystem; [IO.Compression.ZipFile]::ExtractToDirectory($file, $stage) }
elseif ($file -match '\.7z$') {
  if (-not $sevenZip) { throw '7-Zip is needed to unpack this release' }
  & $sevenZip t $file | Out-Null; if ($LASTEXITCODE) { Remove-Item -LiteralPath $file; throw 'the archive failed its own test - removed' }
  Write-Host 'download checked: archive test passed'
  & $sevenZip x -y "-o$stage" $file | Out-Null; if ($LASTEXITCODE) { throw '7-Zip could not unpack it' }
} else { throw "unknown archive type: $file" }
$src = $stage; $top = @(Get-ChildItem -LiteralPath $stage); if ($top.Count -eq 1 -and $top[0].PSIsContainer) { $src = $top[0].FullName }
if (-not (Get-ChildItem -LiteralPath $src -Filter $e.exe -File)) { throw "the release has no $($e.exe) - not copied" }

$keep = @($e.keep | ForEach-Object { ($_ -replace '/', '\').TrimEnd('\').ToLower() })
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'; $bak = Join-Path $r.path "am-update-backup-$stamp"
$copied = 0; $kept = 0; $backed = 0
foreach ($f in Get-ChildItem -LiteralPath $src -Recurse -File) {
  $rel = $f.FullName.Substring($src.Length).TrimStart('\'); $rl = $rel.ToLower()
  if (@($keep | Where-Object { $rl -eq $_ -or $rl.StartsWith("$_\") }).Count) { $kept++; continue }
  $dst = Join-Path $r.path $rel
  if ($dry) { $copied++; continue }
  if (Test-Path -LiteralPath $dst) { $b = Join-Path $bak $rel; New-Item -ItemType Directory -Force (Split-Path $b) | Out-Null; Copy-Item -LiteralPath $dst $b; $backed++ }
  New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
  Copy-Item -LiteralPath $f.FullName $dst -Force; $copied++
}
Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
if ($dry) { Write-Host "DRY RUN: would copy $copied file(s) into $($r.path), keeping $kept of yours"; return }
Set-Content -LiteralPath (Join-Path $r.path 'am-version.txt') $lat.version -Encoding ascii
Write-Host "UPDATED $($e.name) $($r.installed) -> $($lat.version): $copied file(s) copied, $kept kept (settings / saves), $backed old file(s) in $bak"
if ($e.warn) { Write-Host $e.warn }
