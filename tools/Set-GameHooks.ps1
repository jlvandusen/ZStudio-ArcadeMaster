<#
.SYNOPSIS
  Puts ArcadeMaster's start / end hooks (Record-GamePlay.ps1: play time, Most played, save backups) into every game
  launcher of a RetroFE frontend (launchers.windows\*.conf). Idempotent, so the boot runs it every time: launchers
  that New-RetroFECollections rewrote get their hooks back. Hooks run hidden (conhost --headless) and RetroFE does
  not wait for them.

  Left alone: the Tools launcher (AM_TOOLS), and a launcher whose pre / post hook is somebody else's (reported).
  The first change of each file keeps <file>.am-hooks-bak. -Remove takes ArcadeMaster's hook lines out again.
.EXAMPLE
  tools\Set-GameHooks.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE
  tools\Set-GameHooks.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE -Remove
#>
param(
  [Parameter(Mandatory)][string]$RetroFE,
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [switch]$Remove,
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
$dir = Join-Path $RetroFE 'launchers.windows'
if (-not (Test-Path $dir)) { throw "no launchers.windows in $RetroFE" }
$tag = '# ArcadeMaster game hooks (tools\Set-GameHooks.ps1)'
$conhost = Join-Path $env:WINDIR 'System32\conhost.exe'
$rec = Join-Path $PSScriptRoot 'Record-GamePlay.ps1'
function HookArgs([string]$ev) { "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$rec`" -Event $ev -Item `"%ITEM_NAME%`" -Collection `"%ITEM_COLLECTION_NAME%`" -RetroFE `"$RetroFE`" -ManifestDir `"$ManifestDir`"" }
$want = [ordered]@{ preexecutable = $conhost; prearguments = (HookArgs 'start'); postexecutable = $conhost; postarguments = (HookArgs 'end') }
$changed = 0; $ok = 0; $foreign = @()
foreach ($f in Get-ChildItem $dir -Filter *.conf -File) {
  if ($f.BaseName -eq 'AM_TOOLS') { continue }
  $lines = @(Get-Content -LiteralPath $f.FullName)
  $ours = @($lines | Where-Object { $_ -eq $tag }).Count -gt 0
  # drop our previous block (tag + the four keys that follow it)
  $kept = New-Object System.Collections.Generic.List[string]; $skip = 0
  foreach ($l in $lines) {
    if ($l -eq $tag) { $skip = 4; continue }
    if ($skip -gt 0 -and $l -match '^\s*(pre|post)(executable|arguments)\s*=') { $skip--; continue }
    $skip = 0; $kept.Add($l)
  }
  $other = @($kept | Where-Object { $_ -match '^\s*(pre|post)executable\s*=' })
  if ($other) { $foreign += $f.Name; continue }                      # somebody else's hook: not ours to replace
  if (-not $Remove) { $kept.Add($tag); foreach ($k in $want.Keys) { $kept.Add("$k = $($want[$k])") } }
  $newText = ($kept -join "`r`n") + "`r`n"
  $oldText = [IO.File]::ReadAllText($f.FullName)
  if ($newText -eq $oldText -or (-not $ours -and $Remove)) { $ok++; continue }
  $bak = "$($f.FullName).am-hooks-bak"
  # removing: the backup is the exact original when nothing else changed since (keeps its line endings to the byte)
  if ($Remove -and (Test-Path $bak) -and (([IO.File]::ReadAllText($bak) -replace "`r", '').TrimEnd() -eq ($newText -replace "`r", '').TrimEnd())) { Copy-Item -LiteralPath $bak $f.FullName -Force; $changed++; continue }
  if (-not (Test-Path $bak)) { Copy-Item -LiteralPath $f.FullName $bak }
  [IO.File]::WriteAllText($f.FullName, $newText, (New-Object Text.UTF8Encoding $false))   # no BOM: same bytes as ASCII for ASCII files
  $changed++
}
if (-not $Quiet -or $changed -or $foreign) {
  Write-Host ("game hooks {0}: {1} launcher(s) changed, {2} already right{3}" -f $(if ($Remove) { 'removed' } else { 'in place' }), $changed, $ok, $(if ($foreign) { "; left alone (own pre/post hook): $($foreign -join ', ')" } else { '' }))
}
