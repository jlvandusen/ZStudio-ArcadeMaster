<#
.SYNOPSIS
  Are two cabinets set up the same? Our own programs and the settings that change how a cabinet behaves, side by side.
  James, 2026-11-28, at the racing rigs: "Why are both rigs different!?" and "need to ensure race2 is running same build
  always or vice versa". The emulators themselves are compared by tools\Compare-Emulators.ps1; this is the other half:
  the ArcadeMaster version, the frontend, AmPanel and how it ends games, the menu's settings and controls, the game
  list view, G HUB, and the link settings.

  -Inventory   writes what THIS cabinet has to Z:\ArcadeMaster\reports\cabinets\<PC>.json. Read-only on the cabinet.
  -Compare     reads every cabinet's file there and writes compare.md beside them: one table of the lines that differ.
               Lines that are meant to differ (the PC's name and address, the link's two ports) are listed apart.
  -Twin <PC>   with -Compare: only this cabinet against that one, and the exit code is 1 when something differs that
               should not (for a health check).
.EXAMPLE
  tools\Compare-Cabinets.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE-coinops -Inventory
  tools\Compare-Cabinets.ps1 -Compare
  tools\Compare-Cabinets.ps1 -Compare -Twin DESKTOP-RACE2
#>
param(
  [string]$RetroFE,
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [string]$Share = 'Z:\ArcadeMaster\reports\cabinets',
  [switch]$Inventory,
  [switch]$Compare,
  [string]$Twin
)
$ErrorActionPreference = 'Stop'
$u8 = New-Object Text.UTF8Encoding($false)
if (-not $Inventory -and -not $Compare) { throw 'give -Inventory (with -RetroFE) or -Compare' }
function Get-Hash16([string]$p) { if ($p -and (Test-Path -LiteralPath $p)) { (Get-FileHash -LiteralPath $p -Algorithm SHA1).Hash.Substring(0, 16) } else { '(missing)' } }
function Read-Conf([string]$p) {
  $h = [ordered]@{}
  if ($p -and (Test-Path -LiteralPath $p)) { foreach ($l in [IO.File]::ReadAllLines($p)) { if ($l -match '^\s*([A-Za-z0-9_.]+)\s*=\s*(.*?)\s*$') { $h[$Matches[1]] = $Matches[2] } elseif ($l -match '^\s*#\s*([A-Za-z0-9_.]+)\s*=') { if (-not $h.Contains($Matches[1])) { $h[$Matches[1]] = '(switched off)' } } } }
  return $h
}

if ($Inventory) {
  if (-not $RetroFE -or -not (Test-Path -LiteralPath $RetroFE)) { throw "no frontend folder: $RetroFE" }
  $repo = Split-Path $PSScriptRoot; $amRoot = Split-Path $ManifestDir
  $f = [ordered]@{}                                           # one flat list: "group | what" = value
  # --- ArcadeMaster itself
  try { $f['version | repo commit'] = (& git -C $repo rev-parse --short HEAD 2>$null); $f['version | repo branch'] = (& git -C $repo rev-parse --abbrev-ref HEAD 2>$null) } catch { }
  $f['version | frontend program'] = Get-Hash16 (Join-Path $RetroFE 'core\retrofe.exe')
  $f['version | AmPanel'] = Get-Hash16 (Join-Path $amRoot 'AmPanel.exe')
  $f['version | AmPanel exit rules'] = Get-Hash16 (Join-Path $amRoot 'exit-rules.json')
  $f['version | AmPanel panel rules'] = Get-Hash16 (Join-Path $amRoot 'panel-rules.json')
  # --- the menu's settings: everything that is not a path of this PC
  $pathy = 'baseItemPath|baseMediaPath|LEDBlinkyDirectory|collection|path|Path|log$'
  foreach ($file in 'settings.conf', 'settings8.conf') {
    $c = Read-Conf (Join-Path $RetroFE $file)
    foreach ($k in $c.Keys) { if ($k -match $pathy) { continue }; $f["$file | $k"] = [string]$c[$k] }
    if ($file -eq 'settings.conf') { $f['settings.conf | LEDBlinkyDirectory (game events to AmPanel)'] = $(if ($c.Contains('LEDBlinkyDirectory')) { if ($c['LEDBlinkyDirectory'] -eq '(switched off)') { '(switched off)' } elseif ($c['LEDBlinkyDirectory'] -match 'ampanel-shim') { 'AmPanel' } else { 'LEDBlinky' } } else { '(no line)' }) }
  }
  $c = Read-Conf (Join-Path $RetroFE 'controls.conf'); foreach ($k in $c.Keys) { $f["controls.conf | $k"] = [string]$c[$k] }
  # --- how the lists look, and the helpers
  try { $f['menu | game list view'] = (& (Join-Path $PSScriptRoot 'Set-GameListView.ps1') -RetroFE $RetroFE -Current | Select-Object -Last 1) } catch { }
  try { $cm = Get-Content (Join-Path $ManifestDir 'cabinet-mode.json') -Raw | ConvertFrom-Json; $f['menu | cabinet type'] = [string]$cm.effective } catch { }
  $f['wheel | G HUB version'] = $(try { (Get-Item "$env:ProgramFiles\LGHUB\lghub.exe").VersionInfo.ProductVersion } catch { '(not installed)' })
  $f['wheel | G HUB running'] = [string][bool](Get-Process lghub_agent -ErrorAction SilentlyContinue)
  # --- the link between the rigs
  $sm = Join-Path $RetroFE 'emulators\Supermodel\Config\Supermodel.ini'
  if (Test-Path -LiteralPath $sm) { $t = [IO.File]::ReadAllText($sm, [Text.Encoding]::GetEncoding(28591)); foreach ($k in 'Network', 'SimulateNet', 'PortIn', 'PortOut', 'AddressOut', 'InputSystem', 'ForceFeedback') { $m = [regex]::Match($t, "(?m)^\s*$k\s*=\s*(.*?)\s*$"); $f["Model 3 | $k"] = $(if ($m.Success) { $m.Groups[1].Value } else { '(no line)' }) } ; $f['Model 3 | force feedback plug-in'] = [string](Test-Path -LiteralPath (Join-Path $RetroFE 'emulators\Supermodel\opengl32.dll')) }
  $m2 = Read-Conf (Join-Path $RetroFE 'emulators\m2emulator\m2network.ini'); foreach ($k in 'RxPort', 'NextIP', 'NextPort') { $f["Model 2 | $k"] = $(if ($m2.Contains($k)) { [string]$m2[$k] } else { '(no file)' }) }
  foreach ($tp in 'TeknoParrot', 'TeknoParrotMulti') { $pd = Join-Path $RetroFE "emulators\$tp\ParrotData.xml"; if (Test-Path -LiteralPath $pd) { $m = [regex]::Match([IO.File]::ReadAllText($pd), '<CheckForUpdates>(\w+)</CheckForUpdates>'); $f["$tp | checks for updates by itself"] = $(if ($m.Success) { $m.Groups[1].Value } else { '(no line)' }) } }
  $out = [ordered]@{ host = $env:COMPUTERNAME; when = (Get-Date).ToString('s'); retrofe = $RetroFE; facts = $f }
  [void][IO.Directory]::CreateDirectory($Share)
  [IO.File]::WriteAllText((Join-Path $Share "$env:COMPUTERNAME.json"), ($out | ConvertTo-Json -Depth 4), $u8)
  Write-Host "cabinet inventory: $($f.Count) lines -> $(Join-Path $Share "$env:COMPUTERNAME.json")"
}

if ($Compare) {
  $invs = @(Get-ChildItem -LiteralPath $Share -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
  if ($Twin) { $invs = @($invs | Where-Object { $_.host -in $env:COMPUTERNAME, $Twin }) }
  if ($invs.Count -lt 2) { Write-Host "cabinet comparison: needs two cabinets' inventories in $Share (found $($invs.Count))"; if ($Twin) { exit 0 }; return }
  $hosts = @($invs | ForEach-Object host)
  # meant to differ from cabinet to cabinet
  $own = '^(Model 3 \| (PortIn|PortOut|AddressOut)|Model 2 \| NextIP|version \| repo branch|wheel \| G HUB running)$'
  $keys = @($invs | ForEach-Object { $_.facts.PSObject.Properties.Name } | Sort-Object -Unique)
  $diff = @(); $ownRows = @(); $same = 0
  foreach ($k in $keys) {
    $vals = @($invs | ForEach-Object { $p = $_.facts.PSObject.Properties[$k]; if ($p) { [string]$p.Value } else { '(not there)' } })
    if (@($vals | Select-Object -Unique).Count -le 1) { $same++; continue }
    $row = "| $k | " + ($vals -join ' | ') + ' |'
    if ($k -match $own) { $ownRows += $row } else { $diff += $row }
  }
  $md = @("# The cabinets side by side", '', "Made $((Get-Date).ToString('yyyy-MM-dd HH:mm')) by tools/Compare-Cabinets.ps1 from: " + (($invs | ForEach-Object { "$($_.host) ($($_.when))" }) -join ', ') + '.', '',
    "Our own programs and the settings that change how a cabinet behaves. $same line(s) are the same everywhere.", '')
  if ($diff) { $md += "## Different, and not meant to be ($($diff.Count))", '', ('| What | ' + ($hosts -join ' | ') + ' |'), ('|---|' + ('---|' * $hosts.Count)); $md += $diff; $md += '' } else { $md += '**Nothing differs that should not.**', '' }
  if ($ownRows) { $md += '## Different on purpose (each cabinet''s own)', '', ('| What | ' + ($hosts -join ' | ') + ' |'), ('|---|' + ('---|' * $hosts.Count)); $md += $ownRows }
  $name = $(if ($Twin) { "compare-$env:COMPUTERNAME-$Twin.md" } else { 'compare.md' })
  [IO.File]::WriteAllText((Join-Path $Share $name), ($md -join "`r`n"), $u8)
  Write-Host "cabinet comparison: $same the same, $($diff.Count) different that should not be, $($ownRows.Count) different on purpose - $(Join-Path $Share $name)"
  if ($Twin -and $diff.Count) { exit 1 }
}
