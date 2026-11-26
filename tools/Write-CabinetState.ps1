<#
.SYNOPSIS
  Writes what THIS cabinet actually runs to the NAS - Z:\ArcadeMaster\reports\state\<COMPUTERNAME>.json - so the
  cabinets can be compared side by side (tools\Compare-Cabinets.ps1). The code is the same everywhere (every cabinet
  pulls main every 15 minutes); what differs is what got installed, built, generated and switched on. Read-only on the
  cabinet; runs at every boot and after every automatic update, and takes about a second.
.EXAMPLE
  tools\Write-CabinetState.ps1 -Root D:\ArcadeMaster\frontend\DRIVE
#>
param(
  [Parameter(Mandatory)][string]$Root,
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [string]$Out = 'Z:\ArcadeMaster\reports\state'
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
function J([string]$p) { if (Test-Path -LiteralPath $p) { try { Get-Content -LiteralPath $p -Raw | ConvertFrom-Json } catch { $null } } }
function Setting([string]$k) { $m = Select-String -Path (Join-Path $Root 'settings.conf') -Pattern "^\s*$([regex]::Escape($k))\s*=\s*(.*)$" -ErrorAction SilentlyContinue | Select-Object -Last 1; if ($m) { $m.Matches[0].Groups[1].Value.Trim() } else { '(default)' } }
# a glob on a drive this cabinet doesn't have (no D: on the pedestal) is 0 - PowerShell 5.1 can't even bind -File there
function Count([string]$glob) { $root = [IO.Path]::GetPathRoot($glob); if ($root -and -not (Test-Path -LiteralPath $root)) { return 0 }; @(Get-ChildItem $glob -File -ErrorAction SilentlyContinue).Count }

# git is not on PATH everywhere (the pedestal's scheduled task): find it the way Update-Cabinet does
$gitCmd = (Get-Command git -ErrorAction SilentlyContinue).Source
foreach ($g in 'C:\Program Files\Git\cmd\git.exe', (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe')) { if (-not $gitCmd -and (Test-Path $g)) { $gitCmd = $g } }
function git { if ($gitCmd) { & $gitCmd @args } }
$s = [ordered]@{ machine = $env:COMPUTERNAME; written = (Get-Date).ToString('s'); root = $Root }
# code and builds
$s.commit = "$(git -C $repo rev-parse --short HEAD 2>$null)".Trim()
$s.branch = "$(git -C $repo rev-parse --abbrev-ref HEAD 2>$null)".Trim()
$s.localEdits = @(git -C $repo status --porcelain --untracked-files=no 2>$null).Count
$bt = @((Join-Path $Root 'retrofe\am-build.txt'), (Join-Path $Root 'core\am-build.txt') | Where-Object { Test-Path $_ })[0]   # CoinOPS builds keep RetroFE in core\
if (-not $bt) { $bt = Join-Path $Root 'retrofe\am-build.txt' }
$s.retrofeBuild = if (Test-Path $bt) { ((Get-Content $bt | Where-Object { $_ -like 'key=*' }) -replace '^key=', '') } else { 'no am-build.txt' }
$exe = @((Join-Path $Root 'retrofe\retrofe.exe'), (Join-Path $Root 'core\retrofe.exe') | Where-Object { Test-Path $_ })[0]
$s.retrofeExe = $exe
$s.retrofePatched = if ($exe) { [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($exe)).Contains('liveButton') } else { $false }
$t = Get-ScheduledTask -TaskName 'ArcadeMaster Update' -ErrorAction SilentlyContinue
$s.autoUpdate = if ($t) { $i = Get-ScheduledTaskInfo $t; "$($t.State), last $($i.LastRunTime.ToString('s')) result $($i.LastTaskResult)" } else { 'not scheduled' }
$s.launcher = Test-Path 'D:\ArcadeMaster\ArcadeMaster.exe'
$s.startAtLogon = Test-Path (Join-Path ([Environment]::GetFolderPath('Startup')) 'ArcadeMaster.lnk')
# frontend and layout
$s.layout = Setting 'layout'
$lx = Join-Path $Root 'layouts\ArcadeMaster\layout.xml'; $rx = Join-Path $repo 'layouts\ArcadeMaster\layout.xml'
$s.gameListLayoutIsMain = (Test-Path $lx) -and (Test-Path $rx) -and ((Get-FileHash $lx).Hash -eq (Get-FileHash $rx).Hash)
$s.cabinetType = Setting 'cabinetType'
$cm = J (Join-Path $ManifestDir 'cabinet-mode.json'); $s.cabinetModeNow = if ($cm) { $cm.effective } else { $null }
$menu = Join-Path $Root 'collections\Main\menu.txt'; $s.mainMenu = if (Test-Path $menu) { @(Get-Content $menu | Where-Object { $_.Trim() }) -join ', ' } else { '' }
$th = J (Join-Path $ManifestDir 'themes.json'); $s.themes = if ($th) { @($th.themes | ForEach-Object { $_.name }) + @($th.PSObject.Properties | Where-Object { $_.Name -ne 'themes' -and $_.Value.name } | ForEach-Object { $_.Value.name }) | Select-Object -Unique } else { @() }
# hardware
$cab = J (Join-Path $ManifestDir 'cabinet.json')
if ($cab) { $k = $cab.capabilities; $s.hardware = [ordered]@{ wheel = $k.wheel; ffb = $k.ffb; flightStick = $k.flightStick; throttle = $k.throttle; lightguns = $k.lightguns; controlPanel = $k.controlPanel; players = $k.players; modes = @($k.modes); modesSeen = @($k.modesSeen); displays = @($k.displays).Count; touch = $k.touchScreens } }
$gd = J (Join-Path $ManifestDir 'gpu-driver.json')
$s.gpu = if ($gd) { @($gd.cards | ForEach-Object { "$($_.card) $($_.installed)$(if ($_.newer) { " (newer: $($_.latest))" })" }) } else { @(Get-CimInstance Win32_VideoController | ForEach-Object { "$($_.Name) $($_.DriverVersion)" }) }
# generated content
$cols = Join-Path $Root 'collections'
$s.games = [ordered]@{}; foreach ($m in 'Racing', 'Flight', 'Arcade', 'Lightgun') { $d = Join-Path $cols $m; if (Test-Path $d) { $n = 0; Get-ChildItem $d -Filter *.sub -File | ForEach-Object { $n += @(Get-Content $_.FullName | Where-Object { $_.Trim() }).Count }; $s.games[$m] = $n } }
$s.previewVideos = Count (Join-Path $cols '*\medium_artwork\am_video\*.mp4')
$s.backdrops = Count (Join-Path $cols '*\medium_artwork\am_backdrop\*.jpg')
$s.menuClips = Count 'D:\ArcadeMaster\media\clips\*\*.mp4'
$s.stories = Count (Join-Path $cols '*\medium_artwork\am_story\*')
$s.playlists = @(Get-ChildItem (Join-Path $cols '*\playlists\*.txt') -File -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName } | Select-Object -Unique | Sort-Object)
$s.tools = @(Get-ChildItem (Join-Path $cols 'Tools\roms\*.bat') -File -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName -replace '^\d+[a-z]?\s+', '' })
# features switched on
$hooked = @(Select-String -Path (Join-Path $Root 'launchers.windows\*.conf') -Pattern 'ArcadeMaster game hooks' -List -ErrorAction SilentlyContinue).Count
$s.features = [ordered]@{
  playTimeHooks     = "$hooked launcher(s)"
  playtimeGames     = $(($pt = J (Join-Path $ManifestDir 'playtime.json')) | Out-Null; if ($pt) { @($pt.games.PSObject.Properties).Count } else { 0 })
  saveBackups       = (Test-Path (Join-Path 'Z:\ArcadeMaster\saves' $env:COMPUTERNAME))
  gameOfTheMonth    = (Test-Path (Join-Path $ManifestDir 'featured-history.json'))
  ffmpeg            = [bool](Get-Command ffmpeg -ErrorAction SilentlyContinue) -or @(Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Gyan.FFmpeg*", 'D:\ArcadeMaster\_tools\ffmpeg' -Recurse -Filter ffmpeg.exe -ErrorAction SilentlyContinue).Count -gt 0
  amPanel           = (Setting 'arcadeMasterPanel') -ne '(default)'
  playlistKeys      = [bool](Select-String -Path (Join-Path $Root 'controls.conf') -Pattern '^\s*nextPlaylist\s*=' -Quiet -ErrorAction SilentlyContinue)
  vsync             = Setting 'vsync'
  hardwareVideo     = Setting 'HardwareVideoAccel'
  renderer          = Setting 'SDLRenderDriver'
}
# last health check
$hl = Join-Path $Root 'arcademaster-launcher.log'
$s.health = if (Test-Path $hl) { (Select-String -Path $hl -Pattern 'health: .*' | Select-Object -Last 1).Matches.Value } else { $null }
$s.healthWarnings = if (Test-Path $hl) { @((Select-String -Path $hl -Pattern 'WARN\s+(\w+)\s+' -AllMatches | Select-Object -Last 3 | ForEach-Object { $_.Matches | ForEach-Object { $_.Groups[1].Value } }) | Select-Object -Unique) } else { @() }

if (-not (Test-Path (Split-Path $Out))) { Write-Warning "$(Split-Path $Out) not reachable - state not written"; return }
New-Item -ItemType Directory -Force $Out | Out-Null
$f = Join-Path $Out "$env:COMPUTERNAME.json"
[IO.File]::WriteAllText($f, ($s | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
Write-Host "cabinet state -> $f"
