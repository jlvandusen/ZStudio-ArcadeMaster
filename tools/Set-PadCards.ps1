<#
.SYNOPSIS
  Show the right controls card on the console lists for the hand-held controller that is plugged in.
  A PS4 pad is plugged in: every console list (SNES, Genesis, N64 ...) shows that pad with the console's buttons on
  it. No pad: the control panel's cards are back. Which pad: the controller scan (tools\wheelmap, tools\pads\pads.json).
  Run at start and when a controller is plugged in or pulled. Only the lists' default card is changed
  (<collection>\medium_artwork\am_controls\default.png; the panel's card is kept beside it); a game's own card stays.
.EXAMPLE
  tools\Set-PadCards.ps1 -RetroFE D:\ArcadeMaster\frontend\LEGENDS-am            # from the pad that is plugged in
  tools\Set-PadCards.ps1 -RetroFE <frontend> -Family snes                        # as if an SNES-style pad were
  tools\Set-PadCards.ps1 -RetroFE <frontend> -Panel                              # the panel's cards back
#>
param(
  [Parameter(Mandatory)][string]$RetroFE,
  [string]$Family,                  # skip the scan: ps3 ps4 ps5 psx xbox n64 snes snespro nes genesis gamecube switch
  [switch]$Panel,
  [int]$CommandPort = 47802
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\AmPython.ps1'); $py = Find-AmPython
if (-not $py) { Write-Host 'pad cards: no Python found - nothing changed'; return }
$label = ''
if (-not $Panel -and -not $Family) {
  . (Join-Path $PSScriptRoot 'wheelmap\lib\Common.ps1')
  # the first hand-held pad in Windows' order is player 1's
  $pad = @((Get-WMDevices).directInput | Where-Object { $_.pad } | Select-Object -First 1)
  if ($pad) { $Family = $pad[0].pad.family; $label = $pad[0].productName } else { $Panel = $true }
}
$mark = Join-Path $RetroFE 'am-pad-cards.txt'      # what the lists show now, so a second run with the same pad is quick
$want = $(if ($Panel) { 'panel' } else { $Family })
if ((Test-Path -LiteralPath $mark) -and ([IO.File]::ReadAllText($mark).Trim() -eq $want)) { Write-Host "pad cards: already showing $want"; return }
$a = @((Join-Path $PSScriptRoot 'pads\New-PadCards.py'), '--retrofe', $RetroFE) + $(if ($Panel) { @('--panel') } else { @('--family', $Family) })
$o = & $py @a 2>&1 | Out-String
Write-Host (($o.Trim() -split "`r?`n") | Select-Object -Last 1) $(if ($label) { "($label)" })
if ($LASTEXITCODE -eq 0) { [IO.File]::WriteAllText($mark, $want) }
# the open page takes the new card at once (the frontend ignores this when it is not running)
try { $udp = New-Object Net.Sockets.UdpClient; $b = [Text.Encoding]::UTF8.GetBytes('reload'); [void]$udp.Send($b, $b.Length, '127.0.0.1', $CommandPort); $udp.Close() } catch { }