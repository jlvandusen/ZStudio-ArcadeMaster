# This machine's installs, so a tool works on any cabinet without being told where things are.
# The tools' parameter defaults are DESKTOP-RACE1's drive layout (E:\DRIVE Collection, D:\Emulators ...). When a caller
# does not pass the paths, these helpers find them here instead:
#   tools\wheelmap\targets\<COMPUTERNAME>.json   the cabinet's own emulator list (written once per cabinet, see docs/09)
#   <RetroFE root>\emulators\TeknoParrot*         installs that ship inside a frontend (CoinOPS builds)
#   the old defaults                               only the ones that exist on this machine
# Dot-source it: . (Join-Path $PSScriptRoot 'lib\AmMachine.ps1')

function Get-AmTargets {
  $t = Join-Path (Split-Path $PSScriptRoot) "wheelmap\targets\$env:COMPUTERNAME.json"
  if (-not (Test-Path $t)) { $t = Join-Path $PSScriptRoot "wheelmap\targets\$env:COMPUTERNAME.json" }   # dot-sourced from tools\ or tools\lib\
  if (Test-Path $t) { return (Get-Content $t -Raw | ConvertFrom-Json) }
  return $null
}

# TeknoParrot install folders on this machine, newest TeknoParrotUi.exe first, each once.
# -LocalOnly: only the installs inside -RetroFE (for tools that WRITE profiles at boot, so booting one frontend never
# edits another frontend's TeknoParrot).
function Get-AmTeknoParrotRoots([string]$RetroFE, [string[]]$Fallback = @(), [switch]$LocalOnly) {
  $roots = @(if (-not $LocalOnly) { $Fallback })
  $tg = Get-AmTargets; if ($tg -and -not $LocalOnly) { $roots += @($tg.teknoparrot | ForEach-Object { $_.root }) }
  if ($RetroFE) { $roots += @(Get-ChildItem (Join-Path $RetroFE 'emulators') -Directory -Filter 'TeknoParrot*' -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'UserProfiles') } | ForEach-Object FullName) }
  $seen = @{}
  @($roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Where-Object { $k = $_.TrimEnd('\').ToLower(); if ($seen[$k]) { $false } else { $seen[$k] = $true; $true } } | Sort-Object {
      $ui = Join-Path $_ 'TeknoParrotUi.exe'
      if (Test-Path -LiteralPath $ui) { try { [version](((Get-Item -LiteralPath $ui).VersionInfo.FileVersion) -replace '[^\d.].*$', '') } catch { [version]'0.0' } } else { [version]'0.0' } } -Descending)
}

# First existing mame.exe: the given one, else the cabinet's target list.
function Get-AmMame([string]$Preferred) {
  if ($Preferred -and (Test-Path -LiteralPath $Preferred)) { return $Preferred }
  $tg = Get-AmTargets
  if ($tg) { foreach ($m in @($tg.mame)) { foreach ($n in 'mame.exe', 'mame64.exe') { $p = Join-Path $m.root $n; if (Test-Path -LiteralPath $p) { return $p } } } }
  return $null
}
