<#
.SYNOPSIS
  ArcadeMaster boot launcher (replaces DRIVE.exe):
    1. deals a new random set/order of horizon backgrounds (Set-LayoutThemes -Shuffle -BackgroundsOnly)
    2. starts input helpers (JoyToKey if present)
    3. runs RetroFE and restarts it if it crashes (our build exits instead of showing a modal dialog)
  A clean exit of RetroFE (menu Exit / quit key) ends the launcher. Five crashes within 60 s also stop it,
  so a broken config can't loop forever.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File Start-ArcadeMaster.ps1 -Root D:\ArcadeMaster\frontend\DRIVE-coinops
#>
param(
  [Parameter(Mandatory)][string]$Root,                    # RetroFE root (contains retrofe\retrofe.exe, layouts\, collections\)
  [string]$Layout = 'ArcadeMaster',
  [switch]$NoShuffle,
  [int]$MaxCrashes = 5, [int]$CrashWindowSec = 60
)
$ErrorActionPreference = 'Stop'
$exe = Join-Path $Root 'retrofe\retrofe.exe'
if (-not (Test-Path $exe)) { throw "RetroFE not found: $exe" }
$log = Join-Path $Root 'arcademaster-launcher.log'
function Write-Log($m) { Add-Content $log ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $m) }

if (-not $NoShuffle) {
  try {
    & (Join-Path $PSScriptRoot 'Set-LayoutThemes.ps1') -LayoutDir (Join-Path $Root "layouts\$Layout") -CollectionsDir (Join-Path $Root 'collections') -Shuffle -BackgroundsOnly | Out-Null
    Write-Log 'backgrounds shuffled'
  } catch { Write-Log "shuffle failed: $($_.Exception.Message)" }   # never block boot on cosmetics
}

$jtk = Join-Path $Root 'JoyToKey\JoyToKey.exe'
if ((Test-Path $jtk) -and -not (Get-Process JoyToKey -ErrorAction SilentlyContinue)) { Start-Process $jtk -WorkingDirectory (Split-Path $jtk) -WindowStyle Minimized; Write-Log 'JoyToKey started' }

$crashes = New-Object System.Collections.Generic.List[datetime]
while ($true) {
  Write-Log 'starting RetroFE'
  $p = Start-Process $exe -WorkingDirectory (Split-Path $exe) -PassThru
  $p.WaitForExit()
  $code = $p.ExitCode
  $crashed = ($code -ne 0) -or (Select-String -Path (Join-Path $Root 'log.txt') -Pattern 'FATAL CRASH' -Quiet -ErrorAction SilentlyContinue)
  if (-not $crashed) { Write-Log "RetroFE exited cleanly ($code)"; break }
  $now = Get-Date; $crashes.Add($now); $recent = @($crashes | Where-Object { ($now - $_).TotalSeconds -le $CrashWindowSec })
  $keep = Join-Path $Root ("crash-{0:yyyyMMdd-HHmmss}" -f $now); New-Item -ItemType Directory $keep | Out-Null
  foreach ($f in 'log.txt', 'retrofe_crash.dmp') { $src = Join-Path $Root $f; if (Test-Path $src) { Copy-Item $src $keep } }
  Write-Log "RetroFE crashed (exit $code) - evidence in $keep"
  if ($recent.Count -ge $MaxCrashes) { Write-Log "$MaxCrashes crashes in $CrashWindowSec s - giving up"; break }
  Start-Sleep -Seconds 2
}
