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
  [int]$MaxCrashes = 5, [int]$CrashWindowSec = 60,
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [int]$WaitForWheelSec = 30,          # USB wheels often finish enumerating after logon
  [switch]$NoDeviceCheck
)
$ErrorActionPreference = 'Stop'
$exe = Join-Path $Root 'retrofe\retrofe.exe'
if (-not (Test-Path $exe)) { throw "RetroFE not found: $exe" }
$log = Join-Path $Root 'arcademaster-launcher.log'
function Write-Log($m) { Add-Content $log ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $m) }

function Invoke-Tool([string]$name, [string[]]$toolArgs) {
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $name) @toolArgs 2>&1 | Out-String
  if ($LASTEXITCODE) { Write-Log "$name failed ($LASTEXITCODE): $($out.Trim())" }
  return $out
}

# ---------- controllers: wait for the wheel, refresh capabilities, re-point profiles if device IDs moved
if (-not $NoDeviceCheck) {
  try {
    $cabFile = Join-Path $ManifestDir 'cabinet.json'
    $prev = if (Test-Path $cabFile) { (Get-Content $cabFile -Raw | ConvertFrom-Json).capabilities } else { $null }
    $deadline = (Get-Date).AddSeconds($WaitForWheelSec)
    do {
      Invoke-Tool 'Get-CabinetDevices.ps1' @('-Out', $cabFile, '-History', (Join-Path $ManifestDir 'device-history.json')) | Out-Null
      $now = (Get-Content $cabFile -Raw | ConvertFrom-Json).capabilities
      if ($now.wheel -or -not ($prev -and $prev.wheel)) { break }
      Write-Log 'wheel not detected yet - waiting'; Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)
    if ($prev -and $prev.wheel -and -not $now.wheel) { Write-Log "WARNING: racing wheel not detected after $WaitForWheelSec s - wheel games will not respond until it is plugged in" }
    # Dolphin follows what is plugged in: real Wii Remotes / Balance Board / GC adapter, stale device names
    $dol = Invoke-Tool 'Set-DolphinControllers.ps1' @('-ManifestDir', $ManifestDir); if ($dol -match '->') { Write-Log ('dolphin: ' + (($dol -split "`r?`n" | Where-Object { $_ -match '->' } | ForEach-Object { $_.Trim() }) -join '; ')) }
    $ids = Invoke-Tool 'Update-ControllerIds.ps1' @('-Cabinet', $cabFile, '-History', (Join-Path $ManifestDir 'device-history.json'), '-Apply')
    if ($ids -match 'APPLIED: (\d+)' -and [int]$Matches[1] -gt 0) { Write-Log "controller IDs changed - re-pointed $($Matches[1]) profile files" }
    $modesNow = (@($now.modes) | Sort-Object) -join ','; $modesFile = Join-Path $ManifestDir 'last-modes.txt'
    $modesLast = if (Test-Path $modesFile) { (Get-Content $modesFile -Raw).Trim() } else { '' }
    if ($modesNow -ne $modesLast) {
      Write-Log "cabinet modes changed ('$modesLast' -> '$modesNow') - regenerating menus"
      Invoke-Tool 'New-RetroFECollections.ps1' @('-RetroFE', $Root, '-Cabinet', $cabFile, '-Manifest', (Join-Path $ManifestDir 'games.json'), '-RebuildDatabase') | Out-Null
      Set-Content $modesFile $modesNow
    }
  } catch { Write-Log "device check failed: $($_.Exception.Message)" }   # never block boot on diagnostics
}

if (-not $NoShuffle) {
  try {
    & (Join-Path $PSScriptRoot 'Set-LayoutThemes.ps1') -LayoutDir (Join-Path $Root "layouts\$Layout") -CollectionsDir (Join-Path $Root 'collections') -Shuffle -BackgroundsOnly | Out-Null
    Write-Log 'backgrounds shuffled'
  } catch { Write-Log "shuffle failed: $($_.Exception.Message)" }   # never block boot on cosmetics
}

# boot intro: render the cabinet-type title card (settings.conf cabinetType, auto = detected hardware)
# cabinet mode follows the hardware (racing stays racing with a wheel; flight stick instead -> flight cab ...)
try { $mode = Invoke-Tool 'Set-CabinetMode.ps1' @('-RetroFE', $Root, '-ManifestDir', $ManifestDir); Write-Log (($mode -split "`r?`n" | Where-Object { $_.Trim() }) -join ' | ') } catch { Write-Log "cabinet mode failed: $($_.Exception.Message)" }
$active = ((Select-String -Path (Join-Path $Root 'settings.conf') -Pattern '^\s*layout\s*=\s*(.+)$' | Select-Object -Last 1).Matches[0].Groups[1].Value).Trim()
try { Invoke-Tool 'New-CabinetIntro.ps1' @('-RetroFE', $Root, '-ManifestDir', $ManifestDir, '-Layout', $active) | Out-Null } catch { Write-Log "intro failed: $($_.Exception.Message)" }

# Tools list art shows live state (devices, switches, game counts, backdrops) - refresh it every boot
if (Test-Path (Join-Path $Root 'collections\Tools\ARCADEMASTER-TOOLS.txt')) {
  try { Invoke-Tool 'New-ToolsArt.ps1' @('-RetroFE', $Root, '-ManifestDir', $ManifestDir, '-NoFanart') | Out-Null } catch { Write-Log "tools art failed: $($_.Exception.Message)" }
}

$jtk = Join-Path $Root 'JoyToKey\JoyToKey.exe'
if ((Test-Path $jtk) -and -not (Get-Process JoyToKey -ErrorAction SilentlyContinue)) { Start-Process $jtk -WorkingDirectory (Split-Path $jtk) -WindowStyle Minimized; Write-Log 'JoyToKey started' }

# self-healing: check (and conservatively repair) the install before every boot
try { $h = Invoke-Tool 'Repair-ArcadeHealth.ps1' @('-RetroFE', $Root, '-ManifestDir', $ManifestDir); Write-Log ((($h -split "`r?`n") | Where-Object { $_ -match 'FIXED|WARN|health:' } | ForEach-Object { $_.Trim() }) -join ' | ') } catch { Write-Log "health check failed: $($_.Exception.Message)" }

$crashes = New-Object System.Collections.Generic.List[datetime]
$snapshotDone = $false; $lkgRestored = $false
while ($true) {
  Write-Log 'starting RetroFE'
  $p = Start-Process $exe -WorkingDirectory (Split-Path $exe) -PassThru
  # stable for 3 minutes -> remember this configuration as last-known-good (once per boot)
  if (-not $snapshotDone -and -not $p.WaitForExit(180000)) {
    try { Invoke-Tool 'Repair-ArcadeHealth.ps1' @('-RetroFE', $Root, '-ManifestDir', $ManifestDir, '-Snapshot', '-NoFix') | Out-Null; Write-Log 'stable 3 min - last-known-good configs saved' } catch { }
    $snapshotDone = $true
  }
  $p.WaitForExit()
  $code = $p.ExitCode
  $crashed = ($code -ne 0) -or (Select-String -Path (Join-Path $Root 'log.txt') -Pattern 'FATAL CRASH' -Quiet -ErrorAction SilentlyContinue)
  if (-not $crashed) { Write-Log "RetroFE exited cleanly ($code)"; break }
  $now = Get-Date; $crashes.Add($now); $recent = @($crashes | Where-Object { ($now - $_).TotalSeconds -le $CrashWindowSec })
  $keep = Join-Path $Root ("crash-{0:yyyyMMdd-HHmmss}" -f $now); New-Item -ItemType Directory $keep | Out-Null
  foreach ($f in 'log.txt', 'retrofe_crash.dmp') { $src = Join-Path $Root $f; if (Test-Path $src) { Copy-Item $src $keep } }
  Write-Log "RetroFE crashed (exit $code) - evidence in $keep"
  # crash loop: put the last-known-good configs back once and try again before giving up
  if ($recent.Count -ge 3 -and -not $lkgRestored) {
    $lkgRestored = $true; $crashes.Clear()
    $r = Invoke-Tool 'Repair-ArcadeHealth.ps1' @('-RetroFE', $Root, '-ManifestDir', $ManifestDir, '-RestoreLkg'); Write-Log "crash loop - $($r.Trim())"
    continue
  }
  if ($recent.Count -ge $MaxCrashes) { Write-Log "$MaxCrashes crashes in $CrashWindowSec s - giving up"; break }
  Start-Sleep -Seconds 2
}
