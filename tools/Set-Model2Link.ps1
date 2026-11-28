<#
.SYNOPSIS
  Model 2 linked play between two cabinets (docs/16 part 5, Daytona USA and the other Model 2 racers): switches the
  Model 2 emulator's network on towards another cabinet, or off again.
.DESCRIPTION
  The Model 2 emulator (m2emulator, ElSemi) links machines in a ring. The network is on while a file named
  m2network.ini sits next to EMULATOR.INI:
    [Network]
    RxPort=1978          the port this machine listens on
    NextIP=<other rig>   the next machine in the ring (with two rigs: the other one)
    NextPort=1978        the port the next machine listens on
  The other cabinet is looked up by NAME at every run, because the cabinets get their addresses from the router.
  Switched off, the file is renamed to m2network.ini.am-off (kept, never deleted). The DRIVE copy's own
  _m2network.ini (not read by the emulator) is left alone.
  Each game is then set once in its own test menu: one cabinet MASTER, the other SLAVE.
  Dry run unless -Apply.
.EXAMPLE
  .\Set-Model2Link.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE -Peer DESKTOP-RACE1          # what would change
  .\Set-Model2Link.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE -Peer DESKTOP-RACE1 -Apply
  .\Set-Model2Link.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE -Off -Apply                   # single play again
#>
param(
  [Parameter(Mandatory)][string]$RetroFE,
  [string]$Peer,
  [switch]$Off,
  [switch]$Apply,
  [int]$Port = 1978
)
$ErrorActionPreference = 'Stop'
$dir = Join-Path $RetroFE 'emulators\m2emulator'
if (-not (Test-Path -LiteralPath (Join-Path $dir 'EMULATOR.INI'))) { throw "no Model 2 emulator at $dir" }
$ini = Join-Path $dir 'm2network.ini'; $parked = "$ini.am-off"
if (-not $Off -and -not $Peer) { throw 'give -Peer <other cabinet name>, or -Off' }

if ($Off) {
  if (-not (Test-Path -LiteralPath $ini)) { Write-Host 'Model 2 link off (single play) - already off'; return }
  Write-Host "Model 2 link off (single play): m2network.ini -> m2network.ini.am-off$(if (-not $Apply) { ' - DRY RUN, -Apply to write' })"
  if ($Apply) { Move-Item -LiteralPath $ini $parked -Force }
  return
}

$addr = @([Net.Dns]::GetHostAddresses($Peer) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString }) | Select-Object -First 1
if (-not $addr) { throw "$Peer has no IPv4 address on the network right now" }
$want = "[Network]`r`nRxPort=$Port`r`nNextIP=$addr`r`nNextPort=$Port`r`n"
$cur = if (Test-Path -LiteralPath $ini) { [IO.File]::ReadAllText($ini) } else { '' }
$what = "Model 2 link towards $Peer ($addr), port $Port"
if ($cur -eq $want) { Write-Host "$what - already set"; return }
Write-Host "$what$(if (-not $Apply) { ' - DRY RUN, -Apply to write' })"
if ($cur) { ($cur.Trim() -split "`r?`n") | ForEach-Object { Write-Host "  was: $_" } } else { Write-Host '  (no m2network.ini yet: the network is off)' }
if ($Apply) { [IO.File]::WriteAllText($ini, $want, (New-Object Text.UTF8Encoding $false)) }
