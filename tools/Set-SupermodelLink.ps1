<#
.SYNOPSIS
  Model 3 linked play between two cabinets (docs/16 part 5): switches Supermodel's network link on towards another
  cabinet, or off again.
.DESCRIPTION
  Supermodel links two machines through its net board ([ Global ] in Config\Supermodel.ini):
    Network = 1, SimulateNet = 1, PortIn, PortOut, AddressOut = the other machine.
  Each side's PortOut must be the other side's PortIn. The two cabinets work out who is who from their names: the name
  that sorts first listens on 1970 and sends to 1971, the other the other way round, so neither needs to ask.
  The other cabinet is looked up by NAME at every run: the cabinets get their addresses from the router (DHCP), so an
  address written into the file once would go stale.
  Both cabinets must run the same Supermodel build, and each game must be set to linked play in its own test menu.
  Dry run unless -Apply. The file is backed up once (Supermodel.ini.am-bak) before the first change.
.EXAMPLE
  .\Set-SupermodelLink.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE -Peer DESKTOP-RACE1           # what would change
  .\Set-SupermodelLink.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE -Peer DESKTOP-RACE1 -Apply
  .\Set-SupermodelLink.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE -Off -Apply                    # single play again
#>
param(
  [Parameter(Mandatory)][string]$RetroFE,
  [string]$Peer,
  [switch]$Off,
  [switch]$Apply,
  [int]$BasePort = 1970
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\AmSettings.ps1')
$ini = Join-Path $RetroFE 'emulators\Supermodel\Config\Supermodel.ini'
if (-not (Test-Path -LiteralPath $ini)) { throw "no Supermodel config at $ini" }
if (-not $Off -and -not $Peer) { throw 'give -Peer <other cabinet name>, or -Off' }

$want = [ordered]@{}
if ($Off) { $want['Network'] = '0' }
else {
  $me = $env:COMPUTERNAME
  $addr = @([Net.Dns]::GetHostAddresses($Peer) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString }) | Select-Object -First 1
  if (-not $addr) { throw "$Peer has no IPv4 address on the network right now" }
  $first = @($me, $Peer) | Sort-Object | Select-Object -First 1
  $in = if ($first -eq $me) { $BasePort } else { $BasePort + 1 }
  $out = if ($first -eq $me) { $BasePort + 1 } else { $BasePort }
  $want['Network'] = '1'; $want['SimulateNet'] = '1'; $want['PortIn'] = "$in"; $want['PortOut'] = "$out"; $want['AddressOut'] = "`"$addr`""
}

$changes = @()
foreach ($k in $want.Keys) {
  $cur = Get-AmConf $ini $k
  if ($cur -ne $want[$k]) { $changes += "$k`: $cur -> $($want[$k])"; if ($Apply) { [void](Set-AmConf $ini $k $want[$k]) } }
}
$what = if ($Off) { 'Supermodel link off (single play)' } else { "Supermodel link towards $Peer ($addr), in $($want['PortIn']) / out $($want['PortOut'])" }
if (-not $changes) { Write-Host "$what - already set" }
else { Write-Host "$what$(if (-not $Apply) { ' - DRY RUN, -Apply to write' })"; $changes | ForEach-Object { Write-Host "  $_" } }
