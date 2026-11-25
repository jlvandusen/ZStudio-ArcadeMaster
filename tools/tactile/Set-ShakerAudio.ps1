<#
.SYNOPSIS
  Bass shakers for every game without telemetry: the game's sound goes to the speakers AND to the shaker amplifier's
  USB sound card, through VoiceMeeter (installed on DESKTOP-RACE1: basic edition, virtual input "VoiceMeeter Input").
  The shaker amplifier's own low-pass (crossover) keeps only the rumble; VoicemeeterBUSGEQ15 on bus A2 can cut more.

    -Check (default)  what is there and what -Apply would do; changes nothing
    -Apply            start VoiceMeeter (minimised); A1 = the speakers (the current Windows default), A2 = the shaker card;
                      the VoiceMeeter input feeds A1 + A2; shaker strength = -Strength; Windows' default playback device
                      becomes "VoiceMeeter Input". The previous default is kept in <manifest>\tactile.json for -Off.
    -Off              Windows default back to the previous device; the shaker bus muted
  Windows changes honour AM_SYSTEM_DRYRUN=1 (prints what it would do). See docs\12-tactile.md.
.EXAMPLE
  tools\tactile\Set-ShakerAudio.ps1
  $env:AM_SYSTEM_DRYRUN = 1; tools\tactile\Set-ShakerAudio.ps1 -Apply
  tools\tactile\Set-ShakerAudio.ps1 -Apply -Strength 70 -Shaker 'USB Audio'
#>
param(
  [switch]$Apply,
  [switch]$Off,
  [int]$Strength = 70,                       # 0-100 -> shaker bus gain -60..0 dB (70 -> -18 dB)
  [string]$Shaker,                           # a piece of the shaker card's name (default: the only USB sound card)
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [string]$VoiceMeeterDir = 'C:\Program Files (x86)\VB\Voicemeeter'
)
$ErrorActionPreference = 'Stop'
$dry = [bool]$env:AM_SYSTEM_DRYRUN
$state = Join-Path $ManifestDir 'tactile.json'

if (-not ('AmShaker' -as [type])) {
  Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Collections.Generic;
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumerator { }
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface IMMDeviceEnumerator { int EnumAudioEndpoints(int flow, int mask, out IMMDeviceCollection c); int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice d); }
[Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface IMMDeviceCollection { int GetCount(out int n); int Item(int i, out IMMDevice d); }
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface IMMDevice { int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o); int OpenPropertyStore(int access, out IPropertyStore ps); int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id); }
[Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface IPropertyStore { int GetCount(out int n); int GetAt(int i, out PK k); int GetValue(ref PK k, out PV v); }
[StructLayout(LayoutKind.Sequential)] struct PK { public Guid f; public int p; }
[StructLayout(LayoutKind.Sequential)] struct PV { public short vt, r1, r2, r3; public IntPtr p; public IntPtr p2; }
// undocumented but long-stable Windows interface used by every "set default audio device" tool
[ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")] class CPolicyConfigClient { }
[Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface IPolicyConfig {
  int GetMixFormat(); int GetDeviceFormat(); int ResetDeviceFormat(); int SetDeviceFormat(); int GetProcessingPeriod(); int SetProcessingPeriod();
  int GetShareMode(); int SetShareMode(); int GetPropertyValue(); int SetPropertyValue();
  int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, int role); int SetEndpointVisibility(); }
public static class AmShaker {
  static string Name(IMMDevice d) { IPropertyStore ps; d.OpenPropertyStore(0, out ps); var k = new PK { f = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), p = 14 }; PV v; ps.GetValue(ref k, out v); return Marshal.PtrToStringUni(v.p); }
  public static string[] Default() { var e = (IMMDeviceEnumerator)new MMDeviceEnumerator(); IMMDevice d; if (e.GetDefaultAudioEndpoint(0, 1, out d) != 0) return new string[] { "", "" }; string id; d.GetId(out id); return new string[] { Name(d), id }; }
  public static List<string[]> Outputs() { var r = new List<string[]>(); var e = (IMMDeviceEnumerator)new MMDeviceEnumerator(); IMMDeviceCollection c; e.EnumAudioEndpoints(0, 1, out c); int n; c.GetCount(out n); for (int i = 0; i < n; i++) { IMMDevice d; c.Item(i, out d); string id; d.GetId(out id); r.Add(new string[] { Name(d), id }); } return r; }
  public static void SetDefault(string id) { var p = (IPolicyConfig)new CPolicyConfigClient(); for (int role = 0; role < 3; role++) Marshal.ThrowExceptionForHR(p.SetDefaultEndpoint(id, role)); }
  [DllImport(@"C:\Program Files (x86)\VB\Voicemeeter\VoicemeeterRemote64.dll")] public static extern int VBVMR_Login();
  [DllImport(@"C:\Program Files (x86)\VB\Voicemeeter\VoicemeeterRemote64.dll")] public static extern int VBVMR_Logout();
  [DllImport(@"C:\Program Files (x86)\VB\Voicemeeter\VoicemeeterRemote64.dll")] public static extern int VBVMR_RunVoicemeeter(int type);
  [DllImport(@"C:\Program Files (x86)\VB\Voicemeeter\VoicemeeterRemote64.dll")] public static extern int VBVMR_IsParametersDirty();
  [DllImport(@"C:\Program Files (x86)\VB\Voicemeeter\VoicemeeterRemote64.dll", CharSet = CharSet.Ansi)] public static extern int VBVMR_SetParameterFloat(string p, float v);
  [DllImport(@"C:\Program Files (x86)\VB\Voicemeeter\VoicemeeterRemote64.dll", CharSet = CharSet.Ansi)] public static extern int VBVMR_SetParameterStringA(string p, string v);
}
'@
}

$vmExe = Join-Path $VoiceMeeterDir 'voicemeeter.exe'
$vmOk = (Test-Path $vmExe) -and (Test-Path (Join-Path $VoiceMeeterDir 'VoicemeeterRemote64.dll'))
$vmRunning = @(Get-Process voicemeeter -ErrorAction SilentlyContinue).Count -gt 0
$def = [AmShaker]::Default()
$outs = [AmShaker]::Outputs()
$vmIn = $outs | Where-Object { $_[0] -like 'VoiceMeeter Input*' } | Select-Object -First 1
# a shaker card: an active output that is not VoiceMeeter, a display (HDMI / DisplayPort audio) or the current speakers
$cands = @($outs | Where-Object { $_[0] -notmatch '(?i)voicemeeter|nvidia|amd high definition|intel.*display|hdmi|displayport' -and $_[0] -ne $def[0] })
if ($Shaker) { $cands = @($outs | Where-Object { $_[0] -like "*$Shaker*" }) }
$saved = if (Test-Path $state) { Get-Content $state -Raw | ConvertFrom-Json } else { $null }
$speakers = if ($def[0] -like 'VoiceMeeter Input*' -and $saved) { $saved.previousDefault } else { $def[0] }

Write-Host ("VoiceMeeter: {0}{1}" -f $(if ($vmOk) { "installed ($((Get-Item $vmExe).VersionInfo.ProductVersion))" } else { 'NOT installed' }), $(if ($vmRunning) { ', running' } else { '' }))
Write-Host "Windows plays through: $($def[0])"
Write-Host ("shaker sound card: {0}" -f $(if ($cands.Count -eq 1) { $cands[0][0] } elseif ($cands.Count) { "several - pick one with -Shaker: $(($cands | ForEach-Object { $_[0] }) -join ' | ')" } else { 'none plugged in yet' }))
if (-not $Apply -and -not $Off) {
  Write-Host "-Apply would: speakers (A1) = $speakers; shaker (A2) = $(if ($cands.Count -eq 1) { $cands[0][0] } else { '?' }); VoiceMeeter input -> A1 + A2; shaker strength $Strength% ($([Math]::Round(-60 + 0.6 * $Strength)) dB); Windows default -> VoiceMeeter Input"
  return
}

if ($Off) {
  if (-not $saved) { Write-Host 'nothing to undo (no tactile.json)'; return }
  if ($dry) { Write-Host "DRY RUN: Windows default -> $($saved.previousDefault); shaker bus muted"; return }
  $back = $outs | Where-Object { $_[0] -eq $saved.previousDefault } | Select-Object -First 1
  if ($back) { [AmShaker]::SetDefault($back[1]) }
  if ($vmRunning -and [AmShaker]::VBVMR_Login() -ge 0) { [void][AmShaker]::VBVMR_SetParameterFloat('Bus[1].Mute', 1); [void][AmShaker]::VBVMR_Logout() }
  $saved | Add-Member -Force -NotePropertyName on -NotePropertyValue $false; $saved | ConvertTo-Json | Set-Content $state -Encoding utf8
  Write-Host "shakers off: Windows plays through $($saved.previousDefault) again"
  return
}

# -Apply
if (-not $vmOk) { throw 'VoiceMeeter is not installed (https://vb-audio.com/Voicemeeter/ - basic edition is enough)' }
if (-not $vmIn) { throw 'no "VoiceMeeter Input" playback device - reinstall VoiceMeeter' }
if ($cands.Count -ne 1) { throw "no single shaker sound card found - plug it in, or name it with -Shaker" }
$gain = [Math]::Round(-60 + 0.6 * [Math]::Max(0, [Math]::Min(100, $Strength)), 1)
$plan = "A1 = $speakers; A2 = $($cands[0][0]) at $gain dB; VoiceMeeter input -> A1 + A2; Windows default -> $($vmIn[0])"
if ($dry) { Write-Host "DRY RUN: $plan"; return }
if (-not $vmRunning) { Start-Process $vmExe -WindowStyle Minimized; Start-Sleep 3 }
$r = [AmShaker]::VBVMR_Login(); if ($r -lt 0) { throw "VoiceMeeter remote login failed ($r)" }
try {
  $set = @{ 'Bus[0].device.wdm' = $speakers; 'Bus[1].device.wdm' = $cands[0][0] }
  foreach ($k in $set.Keys) { if ([AmShaker]::VBVMR_SetParameterStringA($k, $set[$k]) -ne 0) { throw "VoiceMeeter refused $k" } }
  foreach ($k in 'Strip[2].A1', 'Strip[2].A2') { [void][AmShaker]::VBVMR_SetParameterFloat($k, 1) }
  [void][AmShaker]::VBVMR_SetParameterFloat('Bus[1].Gain', [float]$gain); [void][AmShaker]::VBVMR_SetParameterFloat('Bus[1].Mute', 0)
} finally { [void][AmShaker]::VBVMR_Logout() }
New-Item -ItemType Directory -Force $ManifestDir | Out-Null
[ordered]@{ on = $true; previousDefault = $speakers; shaker = $cands[0][0]; strength = $Strength; set = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content $state -Encoding utf8
[AmShaker]::SetDefault($vmIn[1])
Write-Host "shakers on: $plan"
