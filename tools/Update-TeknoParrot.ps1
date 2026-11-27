<#
.SYNOPSIS
  Brings a cabinet's TeknoParrot up to date: the UI, the core (TeknoParrot\), ElfLdr2, OpenParrot 32 / 64 - every part
  that is installed - from TeknoParrot's own GitHub releases (teknogods/TeknoParrot, teknogods/OpenParrot), the same
  files the TeknoParrot UI's updater fetches.

  - Only parts already installed are updated; nothing new is added.
  - Never touched: UserProfiles\ (the controller mappings), ParrotData.xml (the UI settings), game files.
  - Each file it replaces is copied first to <TeknoParrot>.am-prev\<time>\ (the folder before is removed, one level).
  - Downloads go to a cache on the NAS (Z:\ArcadeMaster\library\teknoparrot-updates), so every cabinet downloads a
    part once; a part whose release is unchanged since the last run is skipped (<TeknoParrot>\am-tp-versions.json).
  - Refuses while TeknoParrot or a game it runs is open.
  After the first update the new UI shows a one-time "Privacy Notice" (usage data) with an OK button: until somebody
  presses OK at the cabinet, every TeknoParrot game launch stops on it. That is the owner's choice - not clicked here.
  An old TeknoParrot (2024) cannot register current subscription keys ("Activation failed, bad code"): update first,
  then register (the key list is private, see the cabinet notes - never in this repo).
.EXAMPLE
  tools\Update-TeknoParrot.ps1 -Root 'E:\DRIVE Collection\emulators\TeknoParrot' -DryRun
  tools\Update-TeknoParrot.ps1 -Root 'E:\DRIVE Collection\emulators\TeknoParrot'
#>
param(
  [Parameter(Mandatory)][string]$Root,
  [string]$Cache = 'Z:\ArcadeMaster\library\teknoparrot-updates',
  [switch]$DryRun,
  [switch]$Force
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (-not (Test-Path (Join-Path $Root 'TeknoParrotUi.exe'))) { throw "no TeknoParrotUi.exe in $Root" }
$Root = (Resolve-Path $Root).Path

# part: GitHub repo + release tag, where it goes, and how to tell it is installed
$parts = @(
  @{ name = 'UI';              repo = 'teknogods/TeknoParrot'; tag = 'TeknoParrotUi';      dir = '';                probe = 'TeknoParrotUi.exe' }
  @{ name = 'Core';            repo = 'teknogods/TeknoParrot'; tag = 'TeknoParrot';        dir = 'TeknoParrot';     probe = 'TeknoParrot\BudgieLoader.exe' }
  @{ name = 'ElfLdr2';         repo = 'teknogods/TeknoParrot'; tag = 'TeknoParrotElfLdr2'; dir = 'ElfLdr2';         probe = 'ElfLdr2\BudgieLoader.exe' }
  @{ name = 'OpenParrot 32';   repo = 'teknogods/OpenParrot';  tag = 'OpenParrotWin32';    dir = 'OpenParrotWin32'; probe = 'OpenParrotWin32\OpenParrotLoader.exe' }
  @{ name = 'OpenParrot 64';   repo = 'teknogods/OpenParrot';  tag = 'OpenParrotx64';      dir = 'OpenParrotx64';   probe = 'OpenParrotx64\OpenParrotLoader64.exe' }
)
$keep = @('^UserProfiles/', '^ParrotData\.xml$')                  # never written

$busy = @(Get-Process TeknoParrotUi, BudgieLoader, OpenParrotLoader, OpenParrotLoader64, OpenParrotKonamiLoader -ErrorAction SilentlyContinue)
if ($busy -and -not $DryRun) { throw "TeknoParrot is running ($(($busy.Name | Select-Object -Unique) -join ', ')): close the game first" }

$stampFile = Join-Path $Root 'am-tp-versions.json'
$stamp = @{}; if (Test-Path $stampFile) { (Get-Content $stampFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $stamp[$_.Name] = $_.Value } }
$cacheOk = $true; try { New-Item -ItemType Directory -Force $Cache | Out-Null } catch { $cacheOk = $false }
if (-not $cacheOk) { $Cache = Join-Path $env:TEMP 'teknoparrot-updates'; New-Item -ItemType Directory -Force $Cache | Out-Null }
$prev = $null; $changedParts = @(); $report = @()

foreach ($p in $parts) {
  if (-not (Test-Path (Join-Path $Root $p.probe))) { $report += "{0,-14} not installed - left out" -f $p.name; continue }
  $rel = Invoke-RestMethod "https://api.github.com/repos/$($p.repo)/releases/tags/$($p.tag)" -Headers @{ 'User-Agent' = 'ArcadeMaster-updater' }
  $asset = @($rel.assets | Where-Object { $_.name -like '*.zip' }) | Select-Object -First 1
  if (-not $asset) { $report += "{0,-14} no zip in release $($p.tag)" -f $p.name; continue }
  $ver = "$($asset.name) $($asset.updated_at) $($asset.size)"
  if (-not $Force -and $stamp[$p.name] -eq $ver) { $report += "{0,-14} up to date ({1}, {2})" -f $p.name, $asset.name, $asset.updated_at.ToString().Substring(0, 10); continue }

  $zip = Join-Path $Cache ("{0}_{1}_{2}.zip" -f $p.tag, ([datetime]$asset.updated_at).ToString('yyyyMMddHHmm'), $asset.size)
  if (-not (Test-Path $zip) -or (Get-Item $zip).Length -ne $asset.size) {
    if ($DryRun) { $report += "{0,-14} would download {1} ({2:N0} MB, {3})" -f $p.name, $asset.name, ($asset.size / 1MB), $asset.updated_at.ToString().Substring(0, 10); continue }
    Invoke-WebRequest $asset.browser_download_url -OutFile "$zip.part" -UseBasicParsing
    if ((Get-Item "$zip.part").Length -ne $asset.size) { throw "$($asset.name): download size does not match" }
    Move-Item "$zip.part" $zip -Force
  }
  $dest = if ($p.dir) { Join-Path $Root $p.dir } else { $Root }
  $z = [IO.Compression.ZipFile]::OpenRead($zip)
  try {
    $n = 0; $same = 0
    foreach ($e in $z.Entries) {
      if (-not $e.Name) { continue }                                # a folder entry
      $rel = $e.FullName
      if (@($keep | Where-Object { $rel -match $_ }).Count) { continue }
      $target = Join-Path $dest ($rel -replace '/', '\')
      if ((Test-Path $target) -and (Get-Item $target).Length -eq $e.Length -and (Get-Item $target).LastWriteTime -eq $e.LastWriteTime.LocalDateTime) { $same++; continue }
      $n++
      if ($DryRun) { continue }
      if (Test-Path $target) {
        if (-not $prev) {
          $base = "$Root.am-prev"; if (Test-Path $base) { Remove-Item $base -Recurse -Force }
          $prev = Join-Path $base (Get-Date -Format 'yyyyMMdd-HHmm'); New-Item -ItemType Directory -Force $prev | Out-Null
        }
        $bk = Join-Path $prev ($target.Substring($Root.Length).TrimStart('\')); New-Item -ItemType Directory -Force (Split-Path $bk) | Out-Null
        Copy-Item -LiteralPath $target $bk -Force
      }
      New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
      [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
    }
  } finally { $z.Dispose() }
  $report += "{0,-14} {1}: {2} file(s) {3}, {4} already the same ({5})" -f $p.name, $asset.name, $n, $(if ($DryRun) { 'would change' } else { 'updated' }), $same, $asset.updated_at.ToString().Substring(0, 10)
  if (-not $DryRun) { $stamp[$p.name] = $ver; $changedParts += $p.name }
}
if (-not $DryRun -and $changedParts) { $stamp | ConvertTo-Json | Set-Content $stampFile -Encoding UTF8 }
$ui = (Get-Item (Join-Path $Root 'TeknoParrotUi.exe')).VersionInfo.FileVersion
$report | ForEach-Object { Write-Host $_ }
Write-Host ("TeknoParrot UI {0}{1}{2}" -f $ui, $(if ($prev) { "; replaced files kept in $prev" } else { '' }), $(if (-not $cacheOk) { "; NAS cache not reachable, used $Cache" } else { '' }))
