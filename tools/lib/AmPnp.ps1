# Fast list of present devices (Class, InstanceId, FriendlyName, Status), the fields the cabinet checks use from
# Get-PnpDevice -PresentOnly. Get-PnpDevice goes through WMI and costs ~0.6 s at every boot; the device-setup API it
# sits on (SetupDiGetClassDevs) returns the same list in a few hundredths of a second.
# Status: 'OK' when Windows reports no problem for it (as Get-PnpDevice does), else 'Error' - what the checks compare against.
# Any failure falls back to Get-PnpDevice, so a cabinet never loses its device checks.
# Dot-source, then: $all = Get-AmPnpDevices
. (Join-Path $PSScriptRoot 'AmTypeCache.ps1')

function Get-AmPnpDevices {
  try {
    Add-AmCachedType -ProbeType 'AmPnp' -Source @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class AmPnp {
  [StructLayout(LayoutKind.Sequential)] struct SP_DEVINFO_DATA { public int cbSize; public Guid ClassGuid; public uint DevInst; public IntPtr Reserved; }
  [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr SetupDiGetClassDevsW(IntPtr guid, string enumerator, IntPtr hwnd, uint flags);
  [DllImport("setupapi.dll", SetLastError = true)] static extern bool SetupDiEnumDeviceInfo(IntPtr set, uint index, ref SP_DEVINFO_DATA data);
  [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool SetupDiGetDeviceRegistryPropertyW(IntPtr set, ref SP_DEVINFO_DATA data, uint prop, out uint type, byte[] buf, uint size, out uint needed);
  [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool SetupDiGetDeviceInstanceIdW(IntPtr set, ref SP_DEVINFO_DATA data, StringBuilder id, int size, out int needed);
  [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
  [DllImport("cfgmgr32.dll")] static extern int CM_Get_DevNode_Status(out uint status, out uint problem, uint devInst, uint flags);
  const uint DIGCF_PRESENT = 2, DIGCF_ALLCLASSES = 4, SPDRP_DEVICEDESC = 0, SPDRP_CLASS = 7, SPDRP_FRIENDLYNAME = 12, DN_HAS_PROBLEM = 0x400;
  static string Prop(IntPtr set, ref SP_DEVINFO_DATA d, uint p) {
    var buf = new byte[1024]; uint type, need;
    if (!SetupDiGetDeviceRegistryPropertyW(set, ref d, p, out type, buf, (uint)buf.Length, out need)) return null;
    return Encoding.Unicode.GetString(buf, 0, (int)Math.Min(need, (uint)buf.Length)).TrimEnd('\0');
  }
  // rows: Class \t InstanceId \t FriendlyName \t Status
  public static List<string[]> List() {
    var rows = new List<string[]>();
    IntPtr set = SetupDiGetClassDevsW(IntPtr.Zero, null, IntPtr.Zero, DIGCF_PRESENT | DIGCF_ALLCLASSES);
    if (set == new IntPtr(-1)) throw new Exception("SetupDiGetClassDevs failed");
    try {
      var d = new SP_DEVINFO_DATA(); d.cbSize = Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
      for (uint i = 0; SetupDiEnumDeviceInfo(set, i, ref d); i++) {
        var id = new StringBuilder(512); int n; SetupDiGetDeviceInstanceIdW(set, ref d, id, id.Capacity, out n);
        string name = Prop(set, ref d, SPDRP_FRIENDLYNAME) ?? Prop(set, ref d, SPDRP_DEVICEDESC) ?? "";
        uint st, prob; string status = (CM_Get_DevNode_Status(out st, out prob, d.DevInst, 0) == 0 && prob == 0 && (st & DN_HAS_PROBLEM) == 0) ? "OK" : "Error";
        rows.Add(new[] { Prop(set, ref d, SPDRP_CLASS) ?? "", id.ToString(), name, status });
      }
    } finally { SetupDiDestroyDeviceInfoList(set); }
    return rows;
  }
}
'@
    foreach ($r in [AmPnp]::List()) { [pscustomobject]@{ Class = $r[0]; InstanceId = $r[1]; FriendlyName = $r[2]; Status = $r[3] } }
  } catch {
    @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Class = $_.Class; InstanceId = $_.InstanceId; FriendlyName = $_.FriendlyName; Status = [string]$_.Status } })
  }
}
