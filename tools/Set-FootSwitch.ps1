<#
.SYNOPSIS
  Reads or sets the keys of a PCsensor USB foot switch (USB 1A86:E026, the 2P stand-up's 3 pedals). Same protocol as
  the open-source "footswitch" tool (github.com/rgerganov/footswitch, src/footswitch.c): 8-byte reports on the
  device's second interface - start {01 80 08}, then per pedal a header {01 81 08 <n>} and its data
  {08 01 <modifiers> <HID key code>}; a query {01 82 08 <n>} answers with the pedal's data.
  James 2026-11-27: the pedals sent A / B / C, which are also player 2's button 1 and a Mini-PAC button; set them to
  keys nothing else uses (F13 / F14 / F15) and map those per game.
.EXAMPLE
  tools\Set-FootSwitch.ps1                            # read: what each pedal sends now
  tools\Set-FootSwitch.ps1 -Keys F13,F14,F15 -Apply   # set pedals 1-3 (the old keys are saved first)
#>
param(
  [string[]]$Keys,
  [switch]$Apply,
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest'
)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles; using System.Collections.Generic;
public static class AmFoot {
  [DllImport("hid.dll")] static extern void HidD_GetHidGuid(out Guid g);
  [DllImport("hid.dll")] static extern bool HidD_GetPreparsedData(SafeFileHandle h, out IntPtr d);
  [DllImport("hid.dll")] static extern bool HidD_FreePreparsedData(IntPtr d);
  [DllImport("hid.dll")] static extern int HidP_GetCaps(IntPtr d, out CAPS c);
  [StructLayout(LayoutKind.Sequential)] public struct CAPS { public short Usage, UsagePage, In, Out, Feat; [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)] public short[] R; public short a, b, c, d, e, f, g, h, i, j; }
  [DllImport("setupapi.dll")] static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr e, IntPtr w, int f);
  [DllImport("setupapi.dll")] static extern bool SetupDiEnumDeviceInterfaces(IntPtr s, IntPtr di, ref Guid g, int i, ref IFD d);
  [DllImport("setupapi.dll", CharSet = CharSet.Unicode)] static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr s, ref IFD d, IntPtr det, int size, out int req, IntPtr di);
  [StructLayout(LayoutKind.Sequential)] struct IFD { public int Size; public Guid C; public int F; public IntPtr R; }
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern SafeFileHandle CreateFile(string n, uint a, uint s, IntPtr sec, uint d, uint f, IntPtr t);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool WriteFile(SafeFileHandle h, byte[] b, int n, out int w, IntPtr o);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadFile(SafeFileHandle h, byte[] b, int n, out int r, IntPtr o);
  public static List<string> Paths() {
    Guid g; HidD_GetHidGuid(out g); var l = new List<string>(); IntPtr s = SetupDiGetClassDevs(ref g, IntPtr.Zero, IntPtr.Zero, 0x12);
    for (int i = 0; ; i++) { var d = new IFD { Size = Marshal.SizeOf(typeof(IFD)) }; if (!SetupDiEnumDeviceInterfaces(s, IntPtr.Zero, ref g, i, ref d)) break;
      int req; SetupDiGetDeviceInterfaceDetail(s, ref d, IntPtr.Zero, 0, out req, IntPtr.Zero); IntPtr b = Marshal.AllocHGlobal(req);
      Marshal.WriteInt32(b, IntPtr.Size == 8 ? 8 : 6); if (SetupDiGetDeviceInterfaceDetail(s, ref d, b, req, out req, IntPtr.Zero)) l.Add(Marshal.PtrToStringUni(b + 4)); Marshal.FreeHGlobal(b); }
    return l;
  }
  static SafeFileHandle h; static int outLen, inLen;
  public static string Open(string path) {
    h = CreateFile(path, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero); if (h.IsInvalid) return "cannot open (" + Marshal.GetLastWin32Error() + ")";
    IntPtr pd; if (HidD_GetPreparsedData(h, out pd)) { CAPS c; HidP_GetCaps(pd, out c); outLen = c.Out; inLen = c.In; HidD_FreePreparsedData(pd); }
    return "report sizes in " + inLen + " / out " + outLen;
  }
  // the 8 bytes the device expects, behind report id 0 (the interface has no numbered reports)
  public static bool Write(byte[] eight) { var b = new byte[Math.Max(outLen, 9)]; Array.Copy(eight, 0, b, 1, 8); int w; bool ok = WriteFile(h, b, b.Length, out w, IntPtr.Zero); System.Threading.Thread.Sleep(30); return ok; }
  public static byte[] Read() { var b = new byte[Math.Max(inLen, 9)]; int r; if (!ReadFile(h, b, b.Length, out r, IntPtr.Zero)) return null; var o = new byte[8]; Array.Copy(b, 1, o, 0, 8); return o; }
  public static void Close() { if (h != null) h.Dispose(); }
}
'@
$hidKey = @{ A = 0x04; B = 0x05; C = 0x06; F13 = 0x68; F14 = 0x69; F15 = 0x6A; F16 = 0x6B; F17 = 0x6C; F18 = 0x6D; F19 = 0x6E; F20 = 0x6F; F21 = 0x70; F22 = 0x71; F23 = 0x72; F24 = 0x73 }
foreach ($c in [char[]]'DEFGHIJKLMNOPQRSTUVWXYZ') { $hidKey["$c"] = 0x04 + ([int]$c - [int][char]'A') }
$byCode = @{}; foreach ($k in $hidKey.Keys) { $byCode[[int]$hidKey[$k]] = $k }

$path = [AmFoot]::Paths() | Where-Object { $_ -match 'vid_1a86&pid_e026&mi_01' } | Select-Object -First 1
if (-not $path) { throw 'no PCsensor foot switch (USB 1A86:E026) found' }
Write-Host ("foot switch: " + [AmFoot]::Open($path))
try {
  $now = @()
  for ($i = 1; $i -le 3; $i++) {
    [void][AmFoot]::Write([byte[]](0x01, 0x82, 0x08, $i, 0, 0, 0, 0)); $r = [AmFoot]::Read()
    $txt = if (-not $r) { '(no answer)' } elseif ($r[1] -band 1) { $k = $byCode[[int]$r[3]]; if (-not $k) { '0x{0:X2}' -f $r[3] } else { $k } } else { 'type {0}' -f $r[1] }
    $now += $txt; Write-Host ("  pedal {0}: {1}   ({2})" -f $i, $txt, (($r | ForEach-Object { '{0:X2}' -f $_ }) -join ' '))
  }
  if ($Keys) {
    $Keys = @($Keys | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
    if ($Keys.Count -ne 3) { throw 'give three keys, one per pedal' }
    foreach ($k in $Keys) { if (-not $hidKey.ContainsKey($k.ToUpper())) { throw "unknown key $k" } }
    if (-not $Apply) { Write-Host "would set pedals 1-3 to $($Keys -join ', ') (add -Apply)"; return }
    $bak = Join-Path $ManifestDir 'footswitch-before.json'
    if (-not (Test-Path $bak)) { @{ pedals = $now; at = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content $bak -Encoding UTF8 }
    [void][AmFoot]::Write([byte[]](0x01, 0x80, 0x08, 0, 0, 0, 0, 0)); Start-Sleep -Milliseconds 1000
    for ($i = 1; $i -le 3; $i++) {
      [void][AmFoot]::Write([byte[]](0x01, 0x81, 0x08, $i, 0, 0, 0, 0))
      [void][AmFoot]::Write([byte[]](0x08, 0x01, 0x00, $hidKey[$Keys[$i - 1].ToUpper()], 0, 0, 0, 0))
    }
    Write-Host "set: pedals 1-3 = $($Keys -join ', ') (before: $($now -join ', '), saved in $bak)"
  }
} finally { [AmFoot]::Close() }
