<#
.SYNOPSIS
  Lists the Ultimarc boards on this cabinet through Ultimarc's own PacDrive SDK (PacDrive32.dll, shipped with
  LEDBlinky): I-PAC Ultimate I/O LED boards, PacLED64, ServoStik restrictors, Nano-LED... and writes
  <manifest>\ultimarc.json. Read-only: it initialises the SDK, asks, and shuts it down; no light is changed.

  PacDrive32.dll is 32-bit, so this script re-runs itself in Windows' 32-bit PowerShell when started from a 64-bit one.
  This is the first step of ArcadeMaster's own LED engine (docs/BACKLOG.md, "LED engine"): our code drives the panel
  lights directly through the published SDK and LEDBlinky's documented config files (Colors.ini, LEDBlinkyInputMap.xml),
  instead of through LEDBlinky.exe.
.EXAMPLE
  tools\Get-UltimarcBoards.ps1 -RetroFE R:\ArcadeMaster\frontend\LEGENDS-am -ManifestDir R:\ArcadeMaster\manifest
#>
param(
  [Parameter(Mandatory)][string]$RetroFE,
  [string]$ManifestDir,
  [string]$Dll                     # default: <RetroFE>\LEDBlinky\PacDrive32.dll
)
$ErrorActionPreference = 'Stop'
if (-not $Dll) { $Dll = Join-Path $RetroFE 'LEDBlinky\PacDrive32.dll' }
if (-not (Test-Path $Dll)) { Write-Host "no PacDrive32.dll at $Dll - no Ultimarc SDK on this cabinet"; exit 0 }
if ([Environment]::Is64BitProcess) {
  $ps32 = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-RetroFE', $RetroFE, '-Dll', $Dll)
  if ($ManifestDir) { $a += @('-ManifestDir', $ManifestDir) }
  & $ps32 @a; exit $LASTEXITCODE
}
# PacDrive SDK device types (PacDrive SDK readme)
$types = @{ 0 = 'Unknown'; 1 = 'PacDrive'; 2 = 'U-HID'; 3 = 'PacLED64'; 4 = 'Nano-LED'; 5 = 'Blue-HID'; 6 = 'I-PAC Ultimate I/O'; 7 = 'ServoStik'; 8 = 'U-HID Nano' }
$leds = @{ 3 = 64; 4 = 60; 6 = 96 }        # LED outputs per board type
$esc = $Dll.Replace('\', '\\')
Add-Type -Namespace AmLed -Name Probe -MemberDefinition @"
[DllImport("$esc", CallingConvention = CallingConvention.StdCall)] public static extern int PacInitialize();
[DllImport("$esc", CallingConvention = CallingConvention.StdCall)] public static extern void PacShutdown();
[DllImport("$esc", CallingConvention = CallingConvention.StdCall)] public static extern int PacGetDeviceType(int id);
[DllImport("$esc", CallingConvention = CallingConvention.StdCall)] public static extern int PacGetVendorId(int id);
[DllImport("$esc", CallingConvention = CallingConvention.StdCall)] public static extern int PacGetProductId(int id);
[DllImport("$esc", CallingConvention = CallingConvention.StdCall)] public static extern int PacGetVersionNumber(int id);
"@
$n = [AmLed.Probe]::PacInitialize()
$boards = @(for ($i = 0; $i -lt $n; $i++) {
  $t = [AmLed.Probe]::PacGetDeviceType($i)
  [ordered]@{ index = $i; type = $t; kind = $(if ($types.ContainsKey($t)) { $types[$t] } else { "type $t" })
              usb = ('{0:X4}:{1:X4}' -f [AmLed.Probe]::PacGetVendorId($i), [AmLed.Probe]::PacGetProductId($i))
              firmware = [AmLed.Probe]::PacGetVersionNumber($i); leds = $(if ($leds.ContainsKey($t)) { $leds[$t] } else { 0 }) }
})
[AmLed.Probe]::PacShutdown()
foreach ($b in $boards) { Write-Host ("  #{0} {1,-20} {2}  firmware {3}  {4} LEDs" -f $b.index, $b.kind, $b.usb, $b.firmware, $b.leds) }
$ledBoards = 0; $ledTotal = 0; $servo = 0
foreach ($b in $boards) { if ($b.leds -gt 0) { $ledBoards++; $ledTotal += $b.leds }; if ($b.type -eq 7) { $servo++ } }
Write-Host ("Ultimarc: {0} board(s) - {1} LED board(s) ({2} LEDs), {3} ServoStik restrictor(s)" -f $boards.Count, $ledBoards, $ledTotal, $servo)
if ($ManifestDir) {
  New-Item -ItemType Directory -Force $ManifestDir | Out-Null
  [ordered]@{ at = (Get-Date).ToString('s'); sdk = $Dll; boards = $boards } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $ManifestDir 'ultimarc.json') -Encoding UTF8
}
