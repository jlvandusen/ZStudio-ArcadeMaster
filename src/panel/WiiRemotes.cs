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
    // which player each DolphinBar slot plays as in arcade games: 1-4, 0 = menus only (James 2026-11-27: "ask - you have a
    // wii controller, do you want to use it for p3 or p4 or p1, or not at all"). <manifest>\wii-players.json; AmPanel asks
    // when a remote connects (Connected) and calls SetPlayer with the answer.
    public Action<int> Connected;
    readonly int[] player = { 1, 2, 3, 4 };
    public int PlayerOf(int slot) { lock (player) return slot >= 1 && slot <= 4 ? player[slot - 1] : 0; }
    public void SetPlayer(int slot, int p)
    {
        if (slot < 1 || slot > 4) return;
        lock (player) player[slot - 1] = p;
        log("wii: slot " + slot + " remote " + (p == 0 ? "works the menus only" : "plays as P" + p + " in arcade games"));
        try { lock (player) File.WriteAllText(Path.Combine(manifestDir, "wii-players.json"), "{\"players\":[" + string.Join(",", player) + "]}"); } catch { }
    }
    void LoadPlayers()
    {
        try
        {
            string f = Path.Combine(manifestDir, "wii-players.json");
            if (!File.Exists(f)) return;
            var m = System.Text.RegularExpressions.Regex.Match(File.ReadAllText(f), @"\[\s*(\d)\s*,\s*(\d)\s*,\s*(\d)\s*,\s*(\d)\s*\]");
            if (m.Success) lock (player) for (int i = 0; i < 4; i++) player[i] = int.Parse(m.Groups[i + 1].Value);
        }
        catch { }
    }

    public WiiRemotes(string manifestDir, string toolsDir, Action<string> log)
    {
        this.manifestDir = manifestDir; this.toolsDir = toolsDir; this.log = log ?? delegate { };
        LoadPlayers();
        new Thread(Loop) { IsBackground = true, Name = "wii" }.Start();
    }

    void Loop()
    {
        string last = null;
        List<int> lastLive = null;
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
                            last = now; lastLive = live;
                            if (Changed != null) Changed();
                            if (Connected != null && last != null)
                                foreach (int sl in live) if (lastLive == null || !lastLive.Contains(sl)) Connected(sl);
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
            // Dolphin and Cemu set the remote up themselves (report mode, the nunchuk): while either runs AmPanel only
            // listens and never writes to the remote (James 2026-11-27: the nunchuk died in Donkey Kong Country Returns
            // while AmPanel re-set the report mode under Dolphin). When they close, the remote is set up again here.
            bool owned = EmulatorOwnsRemote();
            if (!owned) { StartExtension(h); Mode(h); }
            log("wii: slot " + slot + " remote drives the menus (sideways: d-pad moves, 2 / A select, 1 / B back, + / - letters, HOME options)"
                + "; in arcade games it plays as " + (PlayerOf(slot) == 0 ? "nobody (menus only)" : "P" + PlayerOf(slot)) + " (nunchuk stick or d-pad = stick, B A Z C 1 2 = buttons 1-6, + start, - coin)");
            var buf = new byte[len];
            var down = new HashSet<byte>();   // keys this remote holds down right now
            bool hadExt = false;
            while (true)
            {
                int n;
                if (!ReadFile(h, buf, len, out n, IntPtr.Zero) || n < 3) { foreach (var k in down) Key(k, false); return; }   // the remote went away
                byte id = buf[0];
                bool nowOwned = EmulatorOwnsRemote();
                if (nowOwned != owned)
                {
                    owned = nowOwned;
                    foreach (var k in down) Key(k, false); down.Clear();
                    if (!owned) { StartExtension(h); Mode(h); }   // Dolphin / Cemu closed: the menus get the remote back
                }
                if (owned) continue;
                if (id == 0x20)   // a status report (the slot poll, a nunchuk plugged / pulled) ends the report mode: set it up again
                {
                    bool ext = n > 3 && (buf[3] & 0x02) != 0;
                    if (ext && !hadExt) { StartExtension(h); log("wii: slot " + slot + " nunchuk plugged in"); }
                    hadExt = ext;
                    Mode(h);
                }
                if (id < 0x20 || id > 0x37) continue;
                int core = ((buf[1] & 0x1F) << 8) | (buf[2] & 0x9F);
                // nunchuk (report 0x32: 8 extension bytes after the buttons): stick X, stick Y, 3 accel bytes, then Z / C bits (0 = pressed)
                int sx = 128, sy = 128; bool nz = false, nc = false;
                if (id == 0x32 && n >= 9 && hadExt && !(buf[3] == 0xFF && buf[4] == 0xFF))
                {
                    sx = buf[3]; sy = buf[4]; nz = (buf[8] & 0x01) == 0; nc = (buf[8] & 0x02) == 0;
                }
                var want = new HashSet<byte>();
                string where = Where();
                if (where == "menus")
                {
                    foreach (var m in Map) if ((core & m[0]) != 0) want.Add((byte)m[1]);
                    if (sx < 128 - Dead) want.Add(0x25); if (sx > 128 + Dead) want.Add(0x27);
                    if (sy > 128 + Dead) want.Add(0x26); if (sy < 128 - Dead) want.Add(0x28);
                    if (nz) want.Add(0x0D); if (nc) want.Add(0x1B);
                }
                else if (where == "game")
                {
                    // James 2026-11-27: "auto mapping to mame and other legacy emulators when detected", "still use the
                    // arcade controllers so either or", "if there are 4 wii motes then we could actually create p3 and p4".
                    // The remote presses the same keys as that player's panel controls, so either works. Held the way James
                    // plays: the remote upright (B trigger, A under the thumb, d-pad), the nunchuk in the other hand (stick,
                    // C, Z). The stick is 8-way: past the dead zone on each axis.
                    var keys = PlayerKeys(PlayerOf(slot));   // the player this remote was given (0 = menus only: nothing)
                    bool up = (core & 0x0800) != 0 || sy > 128 + Dead, dn = (core & 0x0400) != 0 || sy < 128 - Dead;
                    bool lf = (core & 0x0100) != 0 || sx < 128 - Dead, rt = (core & 0x0200) != 0 || sx > 128 + Dead;
                    Add(want, keys, "UP", up); Add(want, keys, "DOWN", dn); Add(want, keys, "LEFT", lf); Add(want, keys, "RIGHT", rt);
                    Add(want, keys, "B1", (core & 0x0004) != 0);      // B (trigger)
                    Add(want, keys, "B2", (core & 0x0008) != 0);      // A
                    Add(want, keys, "B3", nz);                        // Z (nunchuk trigger)
                    Add(want, keys, "B4", nc);                        // C
                    Add(want, keys, "B5", (core & 0x0002) != 0);      // 1
                    Add(want, keys, "B6", (core & 0x0001) != 0);      // 2
                    Add(want, keys, "START", (core & 0x1000) != 0);   // +
                    Add(want, keys, "COIN", (core & 0x0010) != 0);    // -
                }
                foreach (var k in new List<byte>(down)) if (!want.Contains(k)) { Key(k, false); down.Remove(k); }
                foreach (var k in want) if (!down.Contains(k)) { Key(k, true); down.Add(k); }
            }
        }
    }

    static bool EmulatorOwnsRemote()
    {
        foreach (var n in new[] { "Dolphin", "DolphinWx", "Cemu" }) { var ps = Process.GetProcessesByName(n); bool any = ps.Length > 0; foreach (var p in ps) p.Dispose(); if (any) return true; }
        return false;
    }

    const int Dead = 40;   // nunchuk stick: centre 128, about 35..228 at the ends

    static void Add(HashSet<byte> want, Dictionary<string, byte> keys, string what, bool on)
    {
        byte vk; if (on && keys != null && keys.TryGetValue(what, out vk)) want.Add(vk);
    }

    // a nunchuk (or any extension) on the remote: switched on unencrypted (0x55 -> 0xA400F0, then 0x00 -> 0xA400FB)
    static void StartExtension(SafeFileHandle h)
    {
        foreach (var w in new[] { new byte[] { 0xF0, 0x55 }, new byte[] { 0xFB, 0x00 } })
        {
            var r = new byte[22]; r[0] = 0x16; r[1] = 0x04; r[2] = 0xA4; r[3] = 0x00; r[4] = w[0]; r[5] = 1; r[6] = w[1];
            int n; WriteFile(h, r, r.Length, out n, IntPtr.Zero);
            Thread.Sleep(50);
        }
    }

    // the keys player <slot> uses: this cabinet's panel (manifest\panel.json, from the button capture) for the players it
    // has, MAME's own player 3 / 4 keys for the rest (a 2-player panel has no P3 / P4). Read again after a minute.
    static readonly Dictionary<string, string>[] MameDefault = {
        null, null,
        new Dictionary<string, string> { { "UP", "I" }, { "DOWN", "K" }, { "LEFT", "J" }, { "RIGHT", "L" }, { "B1", "RCONTROL" }, { "B2", "RSHIFT" }, { "B3", "ENTER" }, { "START", "3" }, { "COIN", "7" } },
        new Dictionary<string, string> { { "UP", "8_PAD" }, { "DOWN", "2_PAD" }, { "LEFT", "4_PAD" }, { "RIGHT", "6_PAD" }, { "B1", "0_PAD" }, { "B2", "DEL_PAD" }, { "B3", "ENTER_PAD" }, { "START", "4" }, { "COIN", "8" } } };
    Dictionary<string, byte>[] playerKeys = new Dictionary<string, byte>[4];
    DateTime keysAt = DateTime.MinValue;
    Dictionary<string, byte> PlayerKeys(int slot)
    {
        if (slot < 1 || slot > 4) return null;
        if ((DateTime.Now - keysAt).TotalSeconds > 60)
        {
            keysAt = DateTime.Now;
            var all = new Dictionary<string, byte>[4];
            try
            {
                var js = new System.Web.Script.Serialization.JavaScriptSerializer();
                var panel = js.Deserialize<Dictionary<string, object>>(File.ReadAllText(Path.Combine(manifestDir, "panel.json")));
                var players = panel.ContainsKey("players") ? panel["players"] as System.Collections.ArrayList : null;
                for (int i = 0; players != null && i < players.Count && i < 4; i++)
                {
                    var pl = players[i] as Dictionary<string, object>; if (pl == null) continue;
                    var d = new Dictionary<string, byte>(StringComparer.OrdinalIgnoreCase);
                    var keys = pl.ContainsKey("keys") ? pl["keys"] as Dictionary<string, object> : null;
                    if (keys != null) foreach (var kv in keys)
                    {
                        var m = System.Text.RegularExpressions.Regex.Match(kv.Key, @"^P\d(B\d+|START|COIN)$");
                        int vk = ReactiveKeys.VkOf(Convert.ToString(kv.Value));
                        if (m.Success && vk > 0) d[m.Groups[1].Value] = (byte)vk;
                    }
                    var stick = pl.ContainsKey("stick") ? pl["stick"] as Dictionary<string, object> : null;
                    if (stick != null) foreach (var kv in stick) { int vk = ReactiveKeys.VkOf(Convert.ToString(kv.Value)); if (vk > 0) d[kv.Key.ToUpperInvariant()] = (byte)vk; }
                    if (d.Count > 0) all[i] = d;
                }
            }
            catch (Exception e) { log("wii: panel keys not read - " + e.Message); }
            for (int i = 0; i < 4; i++)
                if (all[i] == null && MameDefault[i] != null)
                {
                    var d = new Dictionary<string, byte>(StringComparer.OrdinalIgnoreCase);
                    foreach (var kv in MameDefault[i]) { int vk = ReactiveKeys.VkOf(kv.Value); if (vk > 0) d[kv.Key] = (byte)vk; }
                    all[i] = d;
                }
            playerKeys = all;
        }
        return playerKeys[slot - 1];
    }

    // "menus" (the frontend or AmPanel in front, no game), "game" (an arcade / legacy emulator in front; Dolphin and Cemu
    // read the remote themselves, so nothing is pressed while either runs), or "" (anything else: nothing is pressed)
    string Where()
    {
        if (Process.GetProcessesByName("Dolphin").Length > 0 || Process.GetProcessesByName("Cemu").Length > 0) return "";
        int pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        string name;
        try { using (var p = Process.GetProcessById(pid)) name = p.ProcessName; } catch { return ""; }
        bool ours = name.Equals("retrofe", StringComparison.OrdinalIgnoreCase) || pid == Process.GetCurrentProcess().Id;
        if (!GameRunning) return ours ? "menus" : "";
        if (ours || name.Equals("explorer", StringComparison.OrdinalIgnoreCase) || name.Equals("Code", StringComparison.OrdinalIgnoreCase)) return "";
        return "game";
    }

    static void Mode(SafeFileHandle h)
    {
        var r = new byte[22]; r[0] = 0x12; r[1] = 0x00; r[2] = 0x32;   // buttons + 8 extension bytes (the nunchuk), when they change
        int w; WriteFile(h, r, r.Length, out w, IntPtr.Zero);
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
