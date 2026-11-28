<#
.SYNOPSIS
  ArcadeMaster - install from the release zip. Unzip the release anywhere (for example C:\ArcadeMaster), then run:
    powershell -ExecutionPolicy Bypass -File C:\ArcadeMaster\Install.ps1 [-Startup]
  1. points ArcadeMaster at this folder (ArcadeMaster.config.json, the frontend's settings.conf)
  2. installs what the tools need if it is missing: Python 3.12 + Pillow, ffmpeg (winget; Windows may ask once)
  3. adds the Tools menu
  4. -Startup: ArcadeMaster starts when Windows does (a shortcut in the Startup folder)
  5. opens "Set up this PC": step 1 looks at the PC (nothing changes), step 2 sets it up after you say yes
  ArcadeMaster never ships or downloads ROMs, BIOS files, emulators or game art: it finds the ones on this PC.
  GPL-3.0: source and licence at https://github.com/jlvandusen/ZStudio-ArcadeMaster (frontend:
  https://github.com/jlvandusen/ZStudio-retrofe, based on RetroFE; thanks to the RetroFE and CoinOPS teams).
#>
param([switch]$Startup, [switch]$SkipPrerequisites, [switch]$NoWizard)   # -NoWizard: tests on a PC whose AmPanel is already running
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$repo = Join-Path $root 'repo'
$fe = Join-Path $root 'frontend\ArcadeMaster'
$manifest = Join-Path $root 'manifest'
function Say([string]$m) { Write-Host $m }
Say "ArcadeMaster install in $root"
if (-not (Test-Path (Join-Path $fe 'core\retrofe.exe'))) { throw "this does not look like an unpacked ArcadeMaster release ($fe\core\retrofe.exe missing)" }
New-Item -ItemType Directory -Force $manifest | Out-Null

# 1. this folder
$sc = Join-Path $fe 'settings.conf'
(Get-Content $sc -Raw).Replace('{ROOT}', $root) | Set-Content $sc -Encoding UTF8
$cfg = [ordered]@{
  RepoPath = $repo; RepoUrl = 'https://github.com/jlvandusen/ZStudio-ArcadeMaster.git'; Branch = 'main'
  RetroFERoot = $fe; ManifestDir = $manifest; AutoUpdate = $false; ReleaseUpdate = $true; CheckOnly = $false
  CabinetType = 'auto'; FollowHardware = $true; ShowAllModes = $false; CabinetTitle = ''; CabinetTagline = ''; SecondScreen = $true
}
$cfg | ConvertTo-Json | Set-Content (Join-Path $root 'ArcadeMaster.config.json') -Encoding UTF8
Say '  ok  ArcadeMaster.config.json and the frontend point at this folder'

# 2. what the tools need
if (-not $SkipPrerequisites) {
  & (Join-Path $repo 'tools\Install-Prerequisites.ps1') -Runtime -ToolsRoot (Join-Path $root '_tools') | ForEach-Object { Say "  $_" }
}

# 3. the Tools menu
try { & (Join-Path $repo 'tools\New-CabinetToolsCollection.ps1') -RetroFE $fe -ToolsDir (Join-Path $repo 'tools') -ManifestDir $manifest | Out-Null; Say '  ok  Tools menu' }
catch { Say "  note  Tools menu not made: $($_.Exception.Message)" }

# 4. start with Windows
if ($Startup) {
  $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'ArcadeMaster.lnk'
  $ws = New-Object -ComObject WScript.Shell; $s = $ws.CreateShortcut($lnk)
  $s.TargetPath = Join-Path $root 'ArcadeMaster.exe'; $s.WorkingDirectory = $root; $s.Save()
  Say "  ok  starts with Windows ($lnk)"
}

# 4b. the system helpers (GPU reset, USB self-heal ...): one admin prompt for all of them (tools\Install-SystemTasks.ps1)
try { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tools\Install-SystemTasks.ps1') -ManifestDir $manifest | ForEach-Object { Say "  $_" } }
catch { Say "  note  system helpers not installed: $($_.Exception.Message) - Set up this PC asks again" }

# 5. Set up this PC
Start-Process (Join-Path $root 'AmPanel.exe') -ArgumentList 'setup' -WorkingDirectory $root
Say ''
Say 'Done. "Set up this PC" is opening: press 1. CHECK THIS PC, read the report, then 2. SET IT UP.'
Say "Afterwards start ArcadeMaster with $root\ArcadeMaster.exe."
