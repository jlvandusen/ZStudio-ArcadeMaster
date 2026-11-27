// AmPanel - "pad keys": wheel / joystick / flight-stick buttons that type a key, so Logitech G HUB's key mappings (and
// JoyToKey's in-game ones) are no longer needed (consolidation, 2026-11-26).
//
// What it replaces: on DESKTOP-RACE2, G HUB's default profile mapped the G29's G24 (button 23, the red dial press) to
// Enter and G25 (button 24, PS) to Escape - G HUB names keys by their USB code in the card id (...0128 = 0x28 Enter,
// ...0129 = 0x29 Escape). Force feedback is not G HUB's: it comes from Logitech's drivers (logi_joy_*), which stay, and
// works with G HUB's app closed (SDL constant-force test on RACE2, 2026-11-26).
//
// The map: <manifest>\padkeys.json (tools\Import-GHubMappings.py writes it from G HUB's settings), else a G29 default
// (button 23 = ENTER, button 24 = ESC):
//   { "devices": [ { "vid": "046D", "pid": "C24F", "name": "G29", "keys": [ { "button": 23, "key": "ENTER" } ] } ] }
// Buttons are counted from 0, as RetroFE's joyButtonN and DirectInput count them. Keys are named as in ReactiveKeys
// (ENTER, ESC, SPACE, A-Z, 0-9, F1-F12, UP/DOWN/LEFT/RIGHT, LCONTROL ...).
//
// It stays out of the way:
//   - while G HUB's agent runs (lghub_agent.exe) - G HUB types the keys then, and two programs must never both do it
//   - while RetroFE is the window in front - the menus read the wheel's buttons themselves (controls.conf joyButtonN),
//     so a key as well would select twice
//   - AmPanel.json "PadKeys": "off"
// Keys go out as scan codes (SendInput KEYEVENTF_SCANCODE): SDL and DirectInput games ignore virtual-key-only input.
// C# 5.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

class PadKeys
{
    [StructLayout(LayoutKind.Sequential)] struct JOYINFOEX { public int dwSize, dwFlags, X, Y, Z, R, U, V, Buttons, ButtonNumber, POV, Reserved1, Reserved2; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct JOYCAPS
    {
        public ushort wMid, wPid; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szPname;
        public int wXmin, wXmax, wYmin, wYmax, wZmin, wZmax, wNumButtons, wPeriodMin, wPeriodMax, wRmin, wRmax, wUmin, wUmax, wVmin, wVmax, wCaps, wMaxAxes, wNumAxes, wMaxButtons;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szRegKey; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szOEMVxD;
    }
    [DllImport("winmm.dll")] static extern int joyGetPosEx(int id, ref JOYINFOEX info);
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)] static extern int joyGetDevCapsW(IntPtr id, ref JOYCAPS caps, int size);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint mapType);
    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit, Size = 40)] struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public KEYBDINPUT ki; }   // x86 and x64: union at 4/8 - see Send()

    class Map { public ushort Vid, Pid; public string Name; public Dictionary<int, int> Keys = new Dictionary<int, int>(); public int Joy = -1; public int Prev; public int Down; }   // Down: keys we pressed and have not released yet

    readonly List<Map> maps = new List<Map>();
    readonly Action<string> log;
    readonly string[] frontends;
    volatile bool stop;
    public string Status = "off";
    public int Sent;

    public PadKeys(string manifestDir, string[] frontendProcesses, Action<string> log)
    {
        this.log = log ?? delegate { };
        frontends = frontendProcesses ?? new[] { "retrofe" };
        Load(Path.Combine(manifestDir ?? ".", "padkeys.json"));
        if (maps.Count == 0) return;
        new Thread(Run) { IsBackground = true, Name = "padkeys" }.Start();
    }

    public void Stop() { stop = true; }

    void Load(string file)
    {
        try
        {
            if (File.Exists(file))
            {
                var js = new System.Web.Script.Serialization.JavaScriptSerializer();
                var root = js.Deserialize<Dictionary<string, object>>(File.ReadAllText(file));
                object devs; if (!root.TryGetValue("devices", out devs)) return;
                foreach (var d0 in (System.Collections.ArrayList)devs)
                {
                    var d = (Dictionary<string, object>)d0;
                    var m = new Map { Vid = Convert.ToUInt16(Convert.ToString(d["vid"]), 16), Pid = Convert.ToUInt16(Convert.ToString(d["pid"]), 16), Name = d.ContainsKey("name") ? Convert.ToString(d["name"]) : "" };
                    foreach (var k0 in (System.Collections.ArrayList)d["keys"])
                    {
                        var k = (Dictionary<string, object>)k0;
                        int vk = ReactiveKeys.VkOf(Convert.ToString(k["key"]));
                        if (vk != 0) m.Keys[Convert.ToInt32(k["button"])] = vk; else log("pad keys: unknown key '" + k["key"] + "' in " + file);
                    }
                    if (m.Keys.Count > 0) maps.Add(m);
                }
                log("pad keys: " + maps.Count + " device map(s) from " + file);
                return;
            }
        }
        catch (Exception e) { log("pad keys: " + file + " not read - " + e.Message); }
        // the G29 default: what G HUB's profile did on RACE2 (dial press = Enter, PS = Escape)
        var g29 = new Map { Vid = 0x046D, Pid = 0xC24F, Name = "G29" };
        g29.Keys[23] = 0x0D; g29.Keys[24] = 0x1B;
        maps.Add(g29);
    }

    void Find()
    {
        foreach (var m in maps) m.Joy = -1;
        for (int i = 0; i < 16; i++)
        {
            var c = new JOYCAPS();
            if (joyGetDevCapsW((IntPtr)i, ref c, Marshal.SizeOf(c)) != 0) continue;
            foreach (var m in maps) if (m.Joy < 0 && c.wMid == m.Vid && c.wPid == m.Pid) { m.Joy = i; break; }
        }
    }

    static bool Running(string name) { var p = Process.GetProcessesByName(name); foreach (var x in p) x.Dispose(); return p.Length > 0; }

    bool FrontendInFront()
    {
        try
        {
            uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid);
            using (var p = Process.GetProcessById((int)pid)) foreach (var f in frontends) if (string.Equals(p.ProcessName, f, StringComparison.OrdinalIgnoreCase)) return true;
        }
        catch { }
        return false;
    }

    void Run()
    {
        var find = Stopwatch.StartNew(); long lastFind = -100000, lastHub = -100000; bool hub = false, any = false;
        string lastStatus = null;
        while (!stop)
        {
            long t = find.ElapsedMilliseconds;
            if (t - lastFind > 5000) { Find(); lastFind = t; any = false; foreach (var m in maps) if (m.Joy >= 0) any = true; }
            if (t - lastHub > 2000) { hub = Running("lghub_agent"); lastHub = t; }
            string st = !any ? "no mapped device connected" : hub ? "G HUB is running - it types the keys" : "on";
            if (st != lastStatus) { Status = st; lastStatus = st; log("pad keys: " + st); }
            if (any)
            {
                bool front = FrontendInFront();
                foreach (var m in maps)
                {
                    if (m.Joy < 0) continue;
                    var s = new JOYINFOEX { dwSize = Marshal.SizeOf(typeof(JOYINFOEX)), dwFlags = 0x80 };   // JOY_RETURNBUTTONS
                    if (joyGetPosEx(m.Joy, ref s) != 0) { m.Joy = -1; continue; }
                    int changed = s.Buttons ^ m.Prev;
                    if (hub && m.Down != 0) { foreach (var kv in m.Keys) if ((m.Down & (1 << kv.Key)) != 0) Send(kv.Value, false); m.Down = 0; }   // G HUB came back: let go
                    if (changed != 0 && !hub)
                        foreach (var kv in m.Keys)
                        {
                            int bit = 1 << kv.Key; if ((changed & bit) == 0) continue;
                            bool down = (s.Buttons & bit) != 0;
                            // a press while the menu is in front is the menu's; a release goes out exactly when its press did,
                            // so no key is ever left held (pressed in a game, released after the menu came back)
                            if (down) { if (front) continue; Send(kv.Value, true); m.Down |= bit; }
                            else if ((m.Down & bit) != 0) { Send(kv.Value, false); m.Down &= ~bit; }
                        }
                    m.Prev = s.Buttons;
                }
            }
            Thread.Sleep(any ? 8 : 250);
        }
    }

    void Send(int vk, bool down)
    {
        ushort scan = (ushort)MapVirtualKey((uint)vk, 0);                  // MAPVK_VK_TO_VSC
        bool ext = vk >= 0x21 && vk <= 0x2E;                                 // page / arrows / insert / delete: extended keys
        var i = new INPUT { type = 1 };                                      // INPUT_KEYBOARD
        i.ki = new KEYBDINPUT { wVk = 0, wScan = scan, dwFlags = 0x0008 | (ext ? 0x0001u : 0) | (down ? 0 : 0x0002u) };
        var arr = new[] { i };
        int size = Marshal.SizeOf(typeof(INPUT));
        if (IntPtr.Size == 4)
        {
            // 32-bit (AmPanel is x86 for the PacDrive DLL): the union sits at offset 4 and INPUT is 28 bytes
            var b = new byte[28];
            BitConverter.GetBytes(1u).CopyTo(b, 0);
            BitConverter.GetBytes((ushort)0).CopyTo(b, 4); BitConverter.GetBytes(scan).CopyTo(b, 6);
            BitConverter.GetBytes(i.ki.dwFlags).CopyTo(b, 8);
            var h = GCHandle.Alloc(b, GCHandleType.Pinned);
            try { SendInput32(1, h.AddrOfPinnedObject(), 28); } finally { h.Free(); }
        }
        else SendInput(1, arr, size);
        if (down) Sent++;
    }

    [DllImport("user32.dll", EntryPoint = "SendInput", SetLastError = true)] static extern uint SendInput32(uint n, IntPtr inputs, int size);
}
