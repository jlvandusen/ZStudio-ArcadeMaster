<#
.SYNOPSIS
  Brings a cabinet's generated content level with every other cabinet: game stories (the history shown after the
  video), missing art (covers, logos, title cards), system tiles, system stories, the search index and main-menu
  logos. Start-ArcadeMaster runs it in the background after every boot, at low priority, at most once a day.

  James, 2026-11-27: "RACE1 shows history etc... and RACE2 doesnt", "there is missmatch on which version is running
  what". These steps used to be run by hand from the Tools menu or a session, so each cabinet had a different set
  (RACE1 253 stories, RACE2 none). Every step only fills in what is missing, so after the first run it is quick.
  Log: <ManifestDir>\content-refresh.log. -Force runs even if it ran today.
.EXAMPLE
  tools\Update-CabinetContent.ps1 -RetroFE R:\ArcadeMaster\frontend\LEGENDS-am -ManifestDir R:\ArcadeMaster\manifest
#>
param(
  [Parameter(Mandatory)][string]$RetroFE,
  [Parameter(Mandatory)][string]$ManifestDir,
  [switch]$Force
)
$ErrorActionPreference = 'Continue'
$log = Join-Path $ManifestDir 'content-refresh.log'
$stamp = Join-Path $ManifestDir 'content-refresh.stamp'
function Say([string]$m) { Add-Content $log ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $m) -Encoding UTF8 }
if (-not $Force -and (Test-Path $stamp) -and ((Get-Date) - (Get-Item $stamp).LastWriteTime).TotalHours -lt 20) { return }
$lock = Join-Path $ManifestDir 'content-refresh.lock'
if ((Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalHours -lt 6) { return }
Set-Content $lock $PID -Encoding ascii
try {
  try { (Get-Process -Id $PID).PriorityClass = 'BelowNormal' } catch { }
  . (Join-Path $PSScriptRoot 'lib\AmPython.ps1')
  $py = Find-AmPython
  if (-not $py) { Say 'skipped: no Python found'; return }
  $t = $PSScriptRoot
  $sw = [Diagnostics.Stopwatch]::StartNew()
  # name, script, its arguments (the stories tools take no --manifest)
  $steps = @(
    @('game stories', 'New-GameStories.py', @('--retrofe', $RetroFE, '--manifest', $ManifestDir)),
    @('art', 'Get-GameArt.py', @('--retrofe', $RetroFE, '--manifest', $ManifestDir)),
    @('system tiles', 'New-SystemTiles.py', @('--retrofe', $RetroFE, '--manifest', $ManifestDir)),
    @('system stories', 'New-SystemStories.py', @('--retrofe', $RetroFE)),
    @('menu logos', 'New-MenuLogos.py', @('--retrofe', $RetroFE)),
    @('search index', 'New-SearchIndex.py', @('--retrofe', $RetroFE, '--manifest', $ManifestDir))
  )
  foreach ($s in $steps) {
    $script = Join-Path $t $s[1]
    if (-not (Test-Path $script)) { continue }
    $one = [Diagnostics.Stopwatch]::StartNew()
    $out = & $py $script @($s[2]) 2>&1 | ForEach-Object { "$_" }
    $last = @($out | Where-Object { $_.Trim() } | Select-Object -Last 1)
    Say ("{0}: exit {1} in {2:N0} s - {3}" -f $s[0], $LASTEXITCODE, $one.Elapsed.TotalSeconds, ($last -join ''))
  }
  Set-Content $stamp (Get-Date).ToString('s') -Encoding ascii
  Say ("content refresh done in {0:N0} s" -f $sw.Elapsed.TotalSeconds)
} finally { Remove-Item $lock -Force -ErrorAction SilentlyContinue }
