<#
.SYNOPSIS
  Builds the ArcadeMaster release: one zip a new PC unpacks and installs (James 2026-11-27: an installer, ready-built,
  for Daniel Spies and the community; "share with community", GPL-3.0). Nothing is published: the zip and its .sha256
  land in <Out>. Publishing (a GitHub release) is a separate, asked-for step.

  ArcadeMaster-<version>-win64.zip
    ArcadeMaster\
      Install.ps1                release/Install.ps1 - run it once after unpacking
      README.txt, LICENSE        GPL-3.0; credits RetroFE and CoinOPS
      ArcadeMaster.exe, AmPanel.exe (+ its rule files), ampanel-shim\LEDBlinky.exe
      repo\                      the repository at this commit (tracked files only, git archive)
      frontend\ArcadeMaster\     tools/New-FrontendSkeleton.py: the prebuilt RetroFE fork + our layouts, nothing of CoinOPS
      manifest\                  empty
  Never ROMs, BIOS files, emulators or game art - those come from the user's own PC at setup.
.EXAMPLE
  tools\Build-Release.ps1 -RetroFERuntime R:\ArcadeMaster\build\retrofe-8bdc6a91b2\retrofe
#>
param(
  [string]$Version = ('0.1.' + (Get-Date -Format 'yyyyMMdd')),
  [string]$Out,
  [string]$RetroFERuntime          # a build's retrofe\ folder; found from retrofe\fork.txt's build key when not given
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
if (-not $Out) { $Out = Join-Path $repo 'dist\release' }
$git = (Get-Command git -ErrorAction SilentlyContinue).Source
if (-not $git) { $git = Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe' }
$py = (Get-Command python -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch 'WindowsApps' } | Select-Object -First 1).Source
if (-not $py) { $py = Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe", "$env:ProgramFiles\Python3*\python.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }

# only a clean main: what is released is exactly a commit
$dirty = @(& $git -C $repo status --porcelain)
if ($dirty.Count) { throw "the repository has uncommitted changes - commit them first (a release is one commit)" }
$commit = (& $git -C $repo rev-parse --short HEAD).Trim()

# the RetroFE build of the pinned fork commit (same key as Update-Cabinet.ps1)
if (-not $RetroFERuntime) {
  $parts = @(Get-Item (Join-Path $repo 'retrofe\fork.txt')) + @(Get-Item (Join-Path $repo 'retrofe\Build-RetroFE.ps1'))
  $sha = [Security.Cryptography.SHA1]::Create(); $all = New-Object IO.MemoryStream
  foreach ($p in $parts) { $b = [Text.Encoding]::UTF8.GetBytes($p.Name + "`n"); $all.Write($b, 0, $b.Length); $c = [IO.File]::ReadAllBytes($p.FullName); $all.Write($c, 0, $c.Length) }
  $key = (-join ($sha.ComputeHash($all.ToArray()) | ForEach-Object { $_.ToString('x2') })).Substring(0, 10)
  foreach ($d in (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3').DeviceID) {
    $cand = "$d\ArcadeMaster\build\retrofe-$key\retrofe"
    if (Test-Path (Join-Path $cand 'retrofe.exe')) { $RetroFERuntime = $cand; break }
  }
  if (-not $RetroFERuntime) { throw "no RetroFE build $key found (<drive>:\ArcadeMaster\build\retrofe-$key) - let Update-Cabinet build it, or pass -RetroFERuntime" }
}
Write-Host "release $Version from commit $commit, RetroFE $RetroFERuntime"

$name = "ArcadeMaster-$Version-win64"
$stageTop = Join-Path $Out $name
$stage = Join-Path $stageTop 'ArcadeMaster'
if (Test-Path $stageTop) { Remove-Item $stageTop -Recurse -Force }
New-Item -ItemType Directory -Force $stage | Out-Null

# programs, fresh from this commit
& (Join-Path $PSScriptRoot 'Build-AmPanel.ps1') | Out-Null
& (Join-Path $PSScriptRoot 'Build-Launcher.ps1') | Out-Null
$dist = Join-Path $repo 'dist'
foreach ($f in 'ArcadeMaster.exe', 'AmPanel.exe', 'ArcadeMaster.ico', 'panel-rules.json', 'light-guns.json', 'exit-rules.json') {
  if (Test-Path (Join-Path $dist $f)) { Copy-Item (Join-Path $dist $f) $stage }
}
New-Item -ItemType Directory -Force (Join-Path $stage 'ampanel-shim') | Out-Null
Copy-Item (Join-Path $dist 'AmPanel.exe') (Join-Path $stage 'ampanel-shim\LEDBlinky.exe')   # RetroFE's LEDBlinky calls land in AmPanel

# the repository at this commit (tracked files only)
$tar = Join-Path $Out "$name-repo.zip"
& $git -C $repo archive --format=zip -o $tar HEAD
Expand-Archive $tar (Join-Path $stage 'repo'); Remove-Item $tar

# the frontend: our RetroFE + layouts, nothing of CoinOPS
& $py (Join-Path $PSScriptRoot 'New-FrontendSkeleton.py') --dest (Join-Path $stage 'frontend\ArcadeMaster') --runtime $RetroFERuntime --root-path '{ROOT}'
if ($LASTEXITCODE) { throw 'frontend skeleton failed' }
New-Item -ItemType Directory -Force (Join-Path $stage 'manifest') | Out-Null

Copy-Item (Join-Path $repo 'release\Install.ps1') $stage
Copy-Item (Join-Path $repo 'LICENSE') $stage
@"
ArcadeMaster $Version (commit $commit) - an arcade cabinet frontend for Windows
=========================================================================

INSTALL
  1. Unzip this folder anywhere, for example C:\ArcadeMaster
  2. Right-click Install.ps1 > Run with PowerShell
     (or: powershell -ExecutionPolicy Bypass -File C:\ArcadeMaster\Install.ps1 -Startup   to start with Windows)
  3. "Set up this PC" opens. Press 1. CHECK THIS PC: it finds your emulators and games and tells you what it would do.
     Nothing changes. Then press 2. SET IT UP.
  4. Start ArcadeMaster.exe.

WHAT IT USES
  Your own emulators and games: RetroBat's (its folders are linked, RetroBat keeps working), RetroArch and the
  standalone emulators it finds on your drives. ArcadeMaster never ships or downloads ROMs, BIOS files, emulators or
  game art.

LICENCE
  GPL-3.0 (LICENSE). Source: https://github.com/jlvandusen/ZStudio-ArcadeMaster
  The frontend is our fork of RetroFE: https://github.com/jlvandusen/ZStudio-retrofe - thanks to the RetroFE and
  CoinOPS teams, whose work it builds on. Made by The Real Z Studios.
"@ | Set-Content (Join-Path $stage 'README.txt') -Encoding UTF8

$zip = Join-Path $Out "$name.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $stage -DestinationPath $zip -CompressionLevel Optimal
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
"$hash  $name.zip" | Set-Content "$zip.sha256" -Encoding ASCII
Remove-Item $stageTop -Recurse -Force
Write-Host ("built {0} ({1:N0} MB), sha256 {2}" -f $zip, ((Get-Item $zip).Length / 1MB), $hash)
