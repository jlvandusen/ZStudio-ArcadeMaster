<#
.SYNOPSIS
  Resolves "retrofe.exe+0xRVA" offsets from a RetroFE crash log to function / file:line using the
  PDB that sits next to the exe (Windows' own dbghelp.dll - no debugger install needed).
.EXAMPLE
  .\Resolve-CrashAddress.ps1 -Exe D:\ArcadeMaster\frontend\DRIVE-coinops\retrofe\retrofe.exe -Rva 0x17fea8,0x1728ad
#>
param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string[]]$Rva)
Add-Type @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class Dbg {
  [DllImport("dbghelp.dll", SetLastError=true, CharSet=CharSet.Ansi)] public static extern bool SymInitialize(IntPtr h, string path, bool invade);
  [DllImport("dbghelp.dll", SetLastError=true)] public static extern uint SymSetOptions(uint o);
  [DllImport("dbghelp.dll", SetLastError=true, CharSet=CharSet.Ansi)] public static extern ulong SymLoadModuleEx(IntPtr h, IntPtr f, string img, string mod, ulong b, uint sz, IntPtr d, uint fl);
  [DllImport("dbghelp.dll", SetLastError=true)] public static extern bool SymFromAddr(IntPtr h, ulong a, out ulong disp, IntPtr sym);
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Ansi)] public struct LINE64 { public uint Size; public IntPtr Key; public uint Line; public IntPtr File; public ulong Addr; }
  [DllImport("dbghelp.dll", SetLastError=true)] public static extern bool SymGetLineFromAddr64(IntPtr h, ulong a, out uint disp, ref LINE64 l);
  [StructLayout(LayoutKind.Sequential)] public struct INLINE { }
  [DllImport("dbghelp.dll", SetLastError=true)] public static extern uint SymAddrIncludeInlineTrace(IntPtr h, ulong a);
  [DllImport("dbghelp.dll", SetLastError=true)] public static extern bool SymQueryInlineTrace(IntPtr h, ulong start, uint ctx, ulong ret, ulong cur, out uint curCtx, out uint curIdx);
  [DllImport("dbghelp.dll", SetLastError=true)] public static extern bool SymFromInlineContext(IntPtr h, ulong a, uint ctx, out ulong disp, IntPtr sym);
  [DllImport("dbghelp.dll", SetLastError=true)] public static extern bool SymGetLineFromInlineContext(IntPtr h, ulong a, uint ctx, ulong modBase, out uint disp, ref LINE64 l);
  static string Name(IntPtr buf) { return Marshal.PtrToStringAnsi(new IntPtr(buf.ToInt64() + 84)); }
  public static string Resolve(string exe, ulong rva) {
    IntPtr h = new IntPtr(0x5151);
    SymSetOptions(0x2 | 0x10 | 0x4);   // UNDNAME | LOAD_LINES | DEFERRED_LOADS
    SymInitialize(h, System.IO.Path.GetDirectoryName(exe), false);
    ulong b = SymLoadModuleEx(h, IntPtr.Zero, exe, null, 0x140000000, 0, IntPtr.Zero, 0);
    if (b == 0) return "SymLoadModuleEx failed " + Marshal.GetLastWin32Error();
    ulong a = b + rva; var sb = new StringBuilder();
    IntPtr buf = Marshal.AllocHGlobal(88 + 512); Marshal.WriteInt32(buf, 88); Marshal.WriteInt32(buf, 80, 512);
    ulong d; uint ld; var ln = new LINE64(); ln.Size = (uint)Marshal.SizeOf(typeof(LINE64));
    if (SymFromAddr(h, a, out d, buf)) sb.Append(Name(buf) + "+0x" + d.ToString("x"));
    else sb.Append("[SymFromAddr err " + Marshal.GetLastWin32Error() + ", base 0x" + b.ToString("x") + "]");
    if (SymGetLineFromAddr64(h, a, out ld, ref ln)) sb.Append("  " + Marshal.PtrToStringAnsi(ln.File) + ":" + ln.Line);
    uint n = SymAddrIncludeInlineTrace(h, a);                     // inlined frames, innermost first
    if (n > 0) { uint ctx, idx; if (SymQueryInlineTrace(h, a, 0, a, a, out ctx, out idx)) {
      for (uint i = 0; i < n; i++) { var l2 = new LINE64(); l2.Size = ln.Size; uint dd; ulong d2;
        string nm = SymFromInlineContext(h, a, ctx + i, out d2, buf) ? Name(buf) : "?";
        string fl = SymGetLineFromInlineContext(h, a, ctx + i, b, out dd, ref l2) ? (Marshal.PtrToStringAnsi(l2.File) + ":" + l2.Line) : "";
        sb.Append("\n      inlined: " + nm + "  " + fl); } } }
    Marshal.FreeHGlobal(buf); return sb.ToString();
  }
}
'@
foreach ($r in ($Rva -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) { "{0}: {1}" -f $r, [Dbg]::Resolve((Resolve-Path $Exe).Path, [Convert]::ToUInt64($r.Replace('0x', ''), 16)) }
