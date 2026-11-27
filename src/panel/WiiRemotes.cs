// AmPanel - Wii Remotes through a Mayflash DolphinBar (USB 057E:0306): which of its 4 slots has a remote synced right
// now (James, 2026-11-26: "allow connecting wii remotes to ampanel as needed"). Windows lists all 4 slots whether or not
// a remote is there; asking each slot for a remote's status (Wii report 0x15) tells them apart: a slot with a remote
// takes the request, an empty one refuses it ("a device attached to the system is not functioning"). Tested on the 2P
// stand-up, 2026-11-27: one remote synced = slot 1 live, slots 2-4 empty.
//
// Every 5 s, only while no game runs and Dolphin is closed (never in the way of a game). When the live slots change:
// <manifest>\wii-remotes.json {"slots":[1], "at": ...}, the status line, and tools\Set-DolphinControllers.ps1 runs, so
// Dolphin's Wii Remote slots follow: Real where a remote is synced, the panel's emulated remote elsewhere.
// A synced remote also works the menus (Read, below).
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
                        ReadRemotes(paths, live);
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

    // ---------------------------------------------------------------- the menus with a Wii Remote
    // (James 2026-11-27: "When connecting wii controller add its directions and 1 2 a and b to navigation within panel")
    // Each synced remote is read; its buttons press the frontend's menu keys (controls.conf), only while the frontend or
    // one of AmPanel's own screens is in front - never in a game, never while Dolphin runs (Dolphin has the remote then).
    // Held sideways like a NES pad (d-pad left, 1 / 2 right); the d-pad bits as the sideways grip reads them.
    //   d-pad = arrows   2 / A = select (Enter)   1 / B = back (Esc)   + / - = letter jump (X / Left Shift)   HOME = TAB
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadFile(SafeFileHandle h, byte[] buf, int n, out int read, IntPtr ov);
    [DllImport("hid.dll")] static extern bool HidD_GetPreparsedData(SafeFileHandle h, out IntPtr data);
    [DllImport("hid.dll")] static extern bool HidD_FreePreparsedData(IntPtr data);
    [DllImport("hid.dll")] static extern int HidP_GetCaps(IntPtr data, out HIDP_CAPS caps);
    [StructLayout(LayoutKind.Sequential)] struct HIDP_CAPS { public short Usage, UsagePage, InputReportByteLength, OutputReportByteLength, FeatureReportByteLength; [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)] public short[] Reserved; public short a, b, c, d, e, f, g, h, i, j; }
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint type);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
    readonly HashSet<string> reading = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

    // bit (byte 1 << 8 | byte 2 of a Wii input report) -> virtual key; sideways grip
    static readonly int[][] Map = {
        // tested sideways on the 2P stand-up (James 2026-11-27): the first guess had left / right and up / down crossed
        new[] { 0x0800, 0x26 },   // d-pad bit 0x08 -> UP
        new[] { 0x0400, 0x28 },   // d-pad bit 0x04 -> DOWN
        new[] { 0x0200, 0x25 },   // d-pad bit 0x02 -> LEFT
        new[] { 0x0100, 0x27 },   // d-pad bit 0x01 -> RIGHT
        new[] { 0x0001, 0x0D },   // 2           -> Enter (select)
        new[] { 0x0008, 0x0D },   // A           -> Enter
        new[] { 0x0002, 0x1B },   // 1           -> Esc (back)
        new[] { 0x0004, 0x1B },   // B           -> Esc
        new[] { 0x1000, 0x58 },   // +           -> X (letter up)
        new[] { 0x0010, 0xA0 },   // -           -> Left Shift (letter down)
        new[] { 0x0080, 0x09 },   // HOME        -> TAB (Game Options)
    };

    void ReadRemotes(List<string> paths, List<int> live)
    {
        foreach (int slot in live)
        {
            string path = paths[slot - 1];
            lock (reading) { if (!reading.Add(path)) continue; }
            int s = slot;
            new Thread(() => { try { Read(path, s); } catch (Exception e) { log("wii: slot " + s + " menus stopped - " + e.Message); } finally { lock (reading) reading.Remove(path); } }) { IsBackground = true, Name = "wii-menu" + slot }.Start();
        }
    }

    void Read(string path, int slot)
    {
        using (var h = CreateFile(path, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero))
        {
            if (h.IsInvalid) return;
            int len = 22; IntPtr pd;
            if (HidD_GetPreparsedData(h, out pd)) { HIDP_CAPS c; if (HidP_GetCaps(pd, out c) == 0x110000 && c.InputReportByteLength > 0) len = c.InputReportByteLength; HidD_FreePreparsedData(pd); }
            Mode(h);
            log("wii: slot " + slot + " remote drives the menus (sideways: d-pad moves, 2 / A select, 1 / B back, + / - letters, HOME options)");
            var buf = new byte[len]; int held = 0;
            while (true)
            {
                int n; if (!ReadFile(h, buf, len, out n, IntPtr.Zero) || n < 3) return;   // the remote went away
                byte id = buf[0];
                if (id == 0x20) Mode(h);                          // a status report (the slot poll) ends the report mode: ask again
                if (id < 0x20 || id > 0x37) continue;
                int now = ((buf[1] & 0x1F) << 8) | (buf[2] & 0x9F);
                if (now == held) continue;
                bool menus = InMenus();
                foreach (var m in Map)
                {
                    bool was = (held & m[0]) != 0, isNow = (now & m[0]) != 0;
                    if (was == isNow) continue;
                    if (isNow && !menus) continue;                // a press only counts in the menus; a release always goes out
                    Key((byte)m[1], isNow);
                }
                held = now;
            }
        }
    }

    static void Mode(SafeFileHandle h)
    {
        var r = new byte[22]; r[0] = 0x12; r[1] = 0x00; r[2] = 0x30;   // report buttons when they change
        int w; WriteFile(h, r, r.Length, out w, IntPtr.Zero);
    }

    bool InMenus()
    {
        if (GameRunning || Process.GetProcessesByName("Dolphin").Length > 0) return false;
        int pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        try { using (var p = Process.GetProcessById(pid)) return p.ProcessName.Equals("retrofe", StringComparison.OrdinalIgnoreCase) || p.Id == Process.GetCurrentProcess().Id; }
        catch { return false; }
    }

    static void Key(byte vk, bool down)
    {
        bool ext = vk >= 0x25 && vk <= 0x28;   // arrows are extended keys
        keybd_event(vk, (byte)MapVirtualKey(vk, 0), (ext ? 1u : 0u) | (down ? 0u : 2u), UIntPtr.Zero);
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
