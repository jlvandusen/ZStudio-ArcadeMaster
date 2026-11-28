<#
.SYNOPSIS
  Set how far the racing wheel turns from lock to lock (its rotation), without G HUB's window.
  A Logitech G29 turns 900 degrees. An arcade racer wants about 270 (a quarter turn each way is full lock); a
  simulator wants the full 900. This sends the wheel its own "set range" command straight over USB, the way Linux's
  wheel driver does, so nothing is changed in G HUB and G HUB can stay as it is.
  Proven on DESKTOP-RACE1, 2026-11-28 (G29, G HUB 2026.7 running): after -Degrees 270 the menu's wheel picture went to
  full lock at a quarter turn (James: "Yes it turned all the way"). The wheel itself puts no stop at the new limit.

  -Degrees <n>   40 to 900.
  -EndStops      also asks the wheel's motor to push back over the last few degrees of each side (a spring force on
                 the wheel's fourth force slot). NOT confirmed yet: a game's own force feedback may clear it.
  -NoEndStops    takes that force off again.
  The setting lasts until the wheel is unplugged, the PC restarts, or G HUB sends its own value again.
  Only for wheels that take the classic Logitech command (G25, G27, Driving Force GT, G29). A G920 / G923 does not.
.EXAMPLE
  tools\Set-WheelRange.ps1 -Degrees 270
  tools\Set-WheelRange.ps1 -Degrees 900 -NoEndStops
#>
param(
  [ValidateRange(40, 900)][int]$Degrees = 0,
  [switch]$EndStops,
  [switch]$NoEndStops,
  [string[]]$UsbIds = @('046D:C24F', '046D:C29B', '046D:C299', '046D:C29A')     # G29, G27, G25, Driving Force GT
)
$ErrorActionPreference = 'Stop'
if (-not $Degrees -and -not $EndStops -and -not $NoEndStops) { throw 'give -Degrees <40..900>, -EndStops or -NoEndStops' }
if (-not ('AmWheelRange' -as [type])) {
  Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles; using System.Collections.Generic;
public static class AmWheelRange {
  [StructLayout(LayoutKind.Sequential)] struct DID { public int cb; public Guid g; public int flags; public IntPtr r; }
  [StructLayout(LayoutKind.Sequential, Pack=1)] struct CAPS { public ushort Usage, UsagePage, In, Out, Feat; [MarshalAs(UnmanagedType.ByValArray, SizeConst=17)] public ushort[] res; public ushort a,b,c,d,e,f,g,h,i,j; }
  [DllImport("hid.dll")] static extern void HidD_GetHidGuid(out Guid g);
  [DllImport("hid.dll")] static extern bool HidD_GetPreparsedData(SafeFileHandle h, out IntPtr p);
  [DllImport("hid.dll")] static extern bool HidD_FreePreparsedData(IntPtr p);
  [DllImport("hid.dll")] static extern int HidP_GetCaps(IntPtr p, out CAPS c);
  [DllImport("setupapi.dll", SetLastError=true)] static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr e, IntPtr w, int f);
  [DllImport("setupapi.dll", SetLastError=true)] static extern bool SetupDiEnumDeviceInterfaces(IntPtr s, IntPtr d, ref Guid g, int i, ref DID did);
  [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Auto)] static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr s, ref DID did, IntPtr det, int sz, out int req, IntPtr dev);
  [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr s);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Auto)] static extern SafeFileHandle CreateFile(string n, uint acc, uint share, IntPtr sa, uint disp, uint fl, IntPtr t);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool WriteFile(SafeFileHandle h, byte[] b, int n, out int w, IntPtr o);
  // the wheel's joystick interface (generic desktop, joystick) and the length of its output report
  public static string Find(string vidpid, out int outLen) {
    outLen = 0; Guid g; HidD_GetHidGuid(out g); IntPtr s = SetupDiGetClassDevs(ref g, IntPtr.Zero, IntPtr.Zero, 0x12); string found = null;
    for (int i = 0; found == null; i++) { var did = new DID(); did.cb = Marshal.SizeOf(typeof(DID)); if (!SetupDiEnumDeviceInterfaces(s, IntPtr.Zero, ref g, i, ref did)) break;
      int req; SetupDiGetDeviceInterfaceDetail(s, ref did, IntPtr.Zero, 0, out req, IntPtr.Zero); IntPtr buf = Marshal.AllocHGlobal(req); Marshal.WriteInt32(buf, IntPtr.Size == 8 ? 8 : 6);
      if (SetupDiGetDeviceInterfaceDetail(s, ref did, buf, req, out req, IntPtr.Zero)) { string p = Marshal.PtrToStringAuto(new IntPtr(buf.ToInt64() + 4));
        if (p.ToLower().Contains(vidpid.ToLower())) { var h = CreateFile(p, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
          if (!h.IsInvalid) { IntPtr pp; if (HidD_GetPreparsedData(h, out pp)) { CAPS c; HidP_GetCaps(pp, out c); HidD_FreePreparsedData(pp); if (c.UsagePage == 1 && c.Usage == 4 && c.Out >= 8) { found = p; outLen = c.Out; } } h.Close(); } } }
      Marshal.FreeHGlobal(buf); }
    SetupDiDestroyDeviceInfoList(s); return found; }
  public static int Send(string path, int outLen, List<byte[]> cmds) {
    var h = CreateFile(path, 0x40000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero); if (h.IsInvalid) return -Marshal.GetLastWin32Error();
    int ok = 0; foreach (var c in cmds) { var b = new byte[outLen]; Array.Copy(c, 0, b, 1, c.Length); int w; if (WriteFile(h, b, b.Length, out w, IntPtr.Zero)) ok++; System.Threading.Thread.Sleep(60); }
    h.Close(); return ok; }
}
"@
}
$path = $null; $len = 0
foreach ($id in $UsbIds) { $v, $p = $id -split ':'; $path = [AmWheelRange]::Find("vid_$v&pid_$p", [ref]$len); if ($path) { break } }
if (-not $path) { Write-Host 'wheel rotation: no wheel that takes this command is plugged in - nothing sent'; return }
$cmds = New-Object 'Collections.Generic.List[byte[]]'
if ($Degrees) { $cmds.Add([byte[]](0xF8, 0x81, ($Degrees -band 0xFF), ($Degrees -shr 8), 0, 0, 0)) }           # extended command 81: set range
if ($EndStops) { $cmds.Add([byte[]](0x81, 0x01, 0x08, 0xF7, 0x77, 0x00, 0xFF)) }                                # slot 4, spring: free between 3% and 97% of the travel
if ($NoEndStops) { $cmds.Add([byte[]](0x83, 0, 0, 0, 0, 0, 0)) }                                                # slot 4: stop
$ok = [AmWheelRange]::Send($path, $len, $cmds)
if ($ok -lt 0) { Write-Host "wheel rotation: the wheel could not be opened (Windows error $(-$ok)) - nothing sent"; return }
$said = @(); if ($Degrees) { $said += "$Degrees degrees" }; if ($EndStops) { $said += 'end stops on' }; if ($NoEndStops) { $said += 'end stops off' }
Write-Host ("wheel rotation: {0} - {1} of {2} command(s) taken by the wheel" -f ($said -join ', '), $ok, $cmds.Count)