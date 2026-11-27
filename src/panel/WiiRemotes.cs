// AmPanel - Wii Remotes through a Mayflash DolphinBar (USB 057E:0306): which of its 4 slots has a remote synced right
// now (James, 2026-11-26: "allow connecting wii remotes to ampanel as needed"). Windows lists all 4 slots whether or not
// a remote is there; asking each slot for a remote's status (Wii report 0x15) tells them apart: a slot with a remote
// takes the request, an empty one refuses it ("a device attached to the system is not functioning"). Tested on the 2P
// stand-up, 2026-11-27: one remote synced = slot 1 live, slots 2-4 empty.
//
// Every 5 s, only while no game runs and Dolphin is closed (never in the way of a game). When the live slots change:
// <manifest>\wii-remotes.json {"slots":[1], "at": ...}, the status line, and tools\Set-DolphinControllers.ps1 runs, so
// Dolphin's Wii Remote slots follow: Real where a remote is synced, the panel's emulated remote elsewhere.
// C# 5.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

class WiiRemotes
{
    [DllImport("hid.dll")] static extern void HidD_GetHidGuid(out Guid g);
    [DllImport("setupapi.dll", SetLastError = true)] static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr e, IntPtr w, int flags);
    [DllImport("setupapi.dll", SetLastError = true)] static extern bool SetupDiEnumDeviceInterfaces(IntPtr set, IntPtr di, ref Guid g, int i, ref SP_DEVICE_INTERFACE_DATA d);
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr set, ref SP_DEVICE_INTERFACE_DATA d, IntPtr detail, int size, out int req, IntPtr di);
    [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool WriteFile(SafeFileHandle h, byte[] buf, int n, out int written, IntPtr ov);
    [StructLayout(LayoutKind.Sequential)] struct SP_DEVICE_INTERFACE_DATA { public int Size; public Guid Class; public int Flags; public IntPtr Reserved; }

    readonly string manifestDir, toolsDir;
    readonly Action<string> log;
    public volatile bool GameRunning;
    public string Live = "";       // "1,3": the slots with a remote
    public int Slots;              // DolphinBar slots seen (4 per DolphinBar)
    public Action Changed;         // AmPanel updates its status line

    public WiiRemotes(string manifestDir, string toolsDir, Action<string> log)
    {
        this.manifestDir = manifestDir; this.toolsDir = toolsDir; this.log = log ?? delegate { };
        new Thread(Loop) { IsBackground = true, Name = "wii" }.Start();
    }

    void Loop()
    {
        string last = null;
        while (true)
        {
            try
            {
                if (!GameRunning && Process.GetProcessesByName("Dolphin").Length == 0 && Process.GetProcessesByName("DolphinWx").Length == 0)
                {
                    var paths = SlotPaths(); Slots = paths.Count;
                    if (paths.Count > 0)
                    {
                        var live = new List<int>();
                        for (int i = 0; i < paths.Count; i++) if (HasRemote(paths[i])) live.Add(i + 1);
                        string now = string.Join(",", live);
                        if (now != last)
                        {
                            Live = now;
                            log("wii: " + (live.Count == 0 ? "no remote synced" : "remote(s) synced in DolphinBar slot " + now) + " (" + paths.Count + " slots)");
                            Save(live);
                            if (last != null || live.Count > 0) Follow();   // Dolphin's slots follow (not on a quiet start with none)
                            last = now;
                            if (Changed != null) Changed();
                        }
                    }
                }
            }
            catch (Exception e) { log("wii: " + e.Message); }
            Thread.Sleep(5000);
        }
    }

    // the DolphinBar's slot interfaces (one HID interface per slot), in slot order
    static List<string> SlotPaths()
    {
        Guid hid; HidD_GetHidGuid(out hid);
        IntPtr set = SetupDiGetClassDevs(ref hid, IntPtr.Zero, IntPtr.Zero, 0x12);
        var paths = new List<string>();
        try
        {
            for (int i = 0; ; i++)
            {
                var d = new SP_DEVICE_INTERFACE_DATA { Size = Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA)) };
                if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref hid, i, ref d)) break;
                int req; SetupDiGetDeviceInterfaceDetail(set, ref d, IntPtr.Zero, 0, out req, IntPtr.Zero);
                IntPtr buf = Marshal.AllocHGlobal(req);
                try
                {
                    Marshal.WriteInt32(buf, IntPtr.Size == 8 ? 8 : 6);
                    if (SetupDiGetDeviceInterfaceDetail(set, ref d, buf, req, out req, IntPtr.Zero))
                    {
                        string p = Marshal.PtrToStringUni(buf + 4);
                        if (p.IndexOf("vid_057e&pid_0306&mi_", StringComparison.OrdinalIgnoreCase) >= 0) paths.Add(p);
                    }
                }
                finally { Marshal.FreeHGlobal(buf); }
            }
        }
        finally { SetupDiDestroyDeviceInfoList(set); }
        paths.Sort(StringComparer.OrdinalIgnoreCase);
        return paths;
    }

    // a remote's status request (0x15, rumble off): taken by a slot with a remote, refused by an empty one
    static bool HasRemote(string path)
    {
        using (var h = CreateFile(path, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero))
        {
            if (h.IsInvalid) return false;
            var req = new byte[22]; req[0] = 0x15;
            int w; return WriteFile(h, req, req.Length, out w, IntPtr.Zero) && w > 0;
        }
    }

    void Save(List<int> live)
    {
        try { File.WriteAllText(Path.Combine(manifestDir, "wii-remotes.json"), "{\"slots\":[" + string.Join(",", live) + "],\"at\":\"" + DateTime.Now.ToString("s") + "\"}"); }
        catch (Exception e) { log("wii: could not save - " + e.Message); }
    }

    void Follow()
    {
        string tool = toolsDir == null ? null : Path.Combine(toolsDir, "Set-DolphinControllers.ps1");
        if (tool == null || !File.Exists(tool)) return;
        try
        {
            Process.Start(new ProcessStartInfo("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + tool + "\" -ManifestDir \"" + manifestDir + "\"") { UseShellExecute = false, CreateNoWindow = true });
            log("wii: Dolphin's Wii Remote slots follow (Set-DolphinControllers)");
        }
        catch (Exception e) { log("wii: Dolphin not updated - " + e.Message); }
    }
}
