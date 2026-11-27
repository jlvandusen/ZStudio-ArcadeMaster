// AmPanel - light guns work the menus (James 2026-11-27: "Same with guns that may have directionals and primary and
// secondary buttons"). A gun reaches Windows as a mouse (the trigger is a click) and often a game controller too (side
// buttons, a d-pad on GUN4IR / OpenFIRE / Sinden builds). Windows raw input tells which device sent each event; only
// devices tools\light-guns.json knows as guns count (Guns.Kind), so the trackball, spinner and panel keyboard are left
// alone. While the frontend or one of AmPanel's own screens is in front - never in a game:
//   trigger (left button) = select (Enter)      right button / controller button 2 = back (Esc)
//   controller button 1 = select                d-pad / hat = arrows      controller buttons 3 / 4 = letter jump (X / Left Shift)
// Only a gun WITH a d-pad / hat is used (James 2026-11-27: "it should listen to anything that has directionals - if the
// light gun doesn't have it don't use it for input"): a trigger-only gun is left out entirely, trigger included.
// A gun that sends keyboard keys needs nothing: the frontend reads those itself.
// C# 5.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Windows.Forms;

class GunMenus : NativeWindow
{
    [DllImport("user32.dll")] static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] devs, uint n, uint size);
    [DllImport("user32.dll")] static extern uint GetRawInputData(IntPtr h, uint cmd, IntPtr data, ref uint size, uint headerSize);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint GetRawInputDeviceInfo(IntPtr dev, uint cmd, IntPtr data, ref uint size);
    [DllImport("hid.dll")] static extern int HidP_GetUsages(int type, ushort page, ushort link, [Out] ushort[] usages, ref uint len, IntPtr pd, IntPtr report, uint reportLen);
    [DllImport("hid.dll")] static extern int HidP_GetUsageValue(int type, ushort page, ushort link, ushort usage, out uint value, IntPtr pd, IntPtr report, uint reportLen);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint type);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
    [StructLayout(LayoutKind.Sequential)] struct RAWINPUTDEVICE { public ushort Page, Usage; public uint Flags; public IntPtr Target; }
    const uint RID_INPUT = 0x10000003, RIDI_DEVICENAME = 0x20000007, RIDI_PREPARSEDDATA = 0x20000005, RIDEV_INPUTSINK = 0x100;
    const int WM_INPUT = 0x00FF, HIDP_STATUS_SUCCESS = 0x110000;

    readonly Action<string> log;
    public Func<bool> GameRunning = () => false;
    readonly Dictionary<IntPtr, string> kind = new Dictionary<IntPtr, string>();        // device -> gun kind, or "" = not a gun
    readonly Dictionary<IntPtr, IntPtr> preparsed = new Dictionary<IntPtr, IntPtr>();
    readonly Dictionary<IntPtr, HashSet<byte>> held = new Dictionary<IntPtr, HashSet<byte>>();
    readonly HashSet<string> told = new HashSet<string>();

    public GunMenus(Action<string> log)
    {
        this.log = log ?? delegate { };
        CreateHandle(new CreateParams());
        var d = new[] {
            new RAWINPUTDEVICE { Page = 1, Usage = 2, Flags = RIDEV_INPUTSINK, Target = Handle },   // mice (the trigger)
            new RAWINPUTDEVICE { Page = 1, Usage = 4, Flags = RIDEV_INPUTSINK, Target = Handle },   // joysticks
            new RAWINPUTDEVICE { Page = 1, Usage = 5, Flags = RIDEV_INPUTSINK, Target = Handle } }; // game pads
        if (!RegisterRawInputDevices(d, (uint)d.Length, (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE)))) log("guns: raw input not available - guns do not work the menus");
        else log("guns: a light gun with a d-pad works the menus (trigger, buttons, d-pad)");
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_INPUT) try { OnInput(m.LParam); } catch { }
        base.WndProc(ref m);
    }

    string KindOf(IntPtr dev)
    {
        string k;
        if (kind.TryGetValue(dev, out k)) return k;
        uint size = 0; GetRawInputDeviceInfo(dev, RIDI_DEVICENAME, IntPtr.Zero, ref size);
        string name = "";
        if (size > 0) { IntPtr b = Marshal.AllocHGlobal((int)size * 2); try { GetRawInputDeviceInfo(dev, RIDI_DEVICENAME, b, ref size); name = Marshal.PtrToStringUni(b); } finally { Marshal.FreeHGlobal(b); } }
        var mm = Regex.Match(name, @"VID_([0-9A-F]{4})&PID_([0-9A-F]{4})", RegexOptions.IgnoreCase);
        string usb = mm.Success ? (mm.Groups[1].Value + ":" + mm.Groups[2].Value).ToUpperInvariant() : null;
        k = usb != null ? (Guns.Kind(usb, name) ?? "") : "";
        if (k != "" && !HasDpad(usb)) { log("guns: " + k + " (" + usb + ") has no d-pad - not used in the menus"); k = ""; }
        kind[dev] = k;
        return k;
    }

    // a hat switch (HID usage 0x39) on any of this gun's interfaces: the gun has directions
    [DllImport("user32.dll")] static extern uint GetRawInputDeviceList([Out] RAWINPUTDEVICELIST[] list, ref uint n, uint size);
    [StructLayout(LayoutKind.Sequential)] struct RAWINPUTDEVICELIST { public IntPtr Device; public uint Type; }
    [DllImport("hid.dll")] static extern int HidP_GetSpecificValueCaps(int type, ushort page, ushort link, ushort usage, [Out] byte[] caps, ref ushort len, IntPtr pd);
    bool HasDpad(string usb)
    {
        uint n = 0, sz = (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICELIST));
        GetRawInputDeviceList(null, ref n, sz);
        var list = new RAWINPUTDEVICELIST[n];
        if (n == 0 || GetRawInputDeviceList(list, ref n, sz) == unchecked((uint)-1)) return false;
        foreach (var d in list)
        {
            if (d.Type != 2) continue;   // HID (not mouse / keyboard)
            uint size = 0; GetRawInputDeviceInfo(d.Device, RIDI_DEVICENAME, IntPtr.Zero, ref size);
            if (size == 0) continue;
            string name; IntPtr b = Marshal.AllocHGlobal((int)size * 2);
            try { GetRawInputDeviceInfo(d.Device, RIDI_DEVICENAME, b, ref size); name = Marshal.PtrToStringUni(b); } finally { Marshal.FreeHGlobal(b); }
            if (name.IndexOf("VID_" + usb.Substring(0, 4) + "&PID_" + usb.Substring(5), StringComparison.OrdinalIgnoreCase) < 0) continue;
            IntPtr pd = Preparsed(d.Device); if (pd == IntPtr.Zero) continue;
            var caps = new byte[72 * 4]; ushort len = 4;
            if (HidP_GetSpecificValueCaps(0, 1, 0, 0x39, caps, ref len, pd) == HIDP_STATUS_SUCCESS && len > 0) return true;
        }
        return false;
    }

    void OnInput(IntPtr h)
    {
        uint hs = (uint)(IntPtr.Size == 8 ? 24 : 16), size = 0;
        GetRawInputData(h, RID_INPUT, IntPtr.Zero, ref size, hs);
        if (size == 0) return;
        IntPtr buf = Marshal.AllocHGlobal((int)size);
        try
        {
            if (GetRawInputData(h, RID_INPUT, buf, ref size, hs) != size) return;
            int type = Marshal.ReadInt32(buf);
            IntPtr dev = Marshal.ReadIntPtr(buf, 8);
            string k = KindOf(dev);
            if (k == "") return;
            if (told.Add(k + dev)) log("guns: " + k + " seen - it works the menus");
            IntPtr data = buf + (int)hs;
            if (type == 0)   // mouse: the trigger and the other buttons
            {
                ushort flags = (ushort)Marshal.ReadInt16(data, 4);   // usButtonFlags
                if ((flags & 0x0001) != 0) Press(dev, 0x0D, true);   // left down  -> Enter
                if ((flags & 0x0002) != 0) Press(dev, 0x0D, false);
                if ((flags & 0x0004) != 0) Press(dev, 0x1B, true);   // right down -> Esc
                if ((flags & 0x0008) != 0) Press(dev, 0x1B, false);
            }
            else if (type == 2)   // a game controller report: buttons and hat
            {
                int each = Marshal.ReadInt32(data), count = Marshal.ReadInt32(data, 4);
                IntPtr pd = Preparsed(dev); if (pd == IntPtr.Zero || count < 1) return;
                IntPtr rep = data + 8;   // the last report is the newest
                rep += each * (count - 1);
                var now = new HashSet<byte>();
                var us = new ushort[32]; uint n = (uint)us.Length;
                if (HidP_GetUsages(0, 9, 0, us, ref n, pd, rep, (uint)each) == HIDP_STATUS_SUCCESS)
                    for (int i = 0; i < n; i++)
                        switch (us[i]) { case 1: now.Add(0x0D); break; case 2: now.Add(0x1B); break; case 3: now.Add(0x58); break; case 4: now.Add(0xA0); break; }
                uint hat;
                if (HidP_GetUsageValue(0, 1, 0, 0x39, out hat, pd, rep, (uint)each) == HIDP_STATUS_SUCCESS && hat <= 7)
                {
                    if (hat == 7 || hat == 0 || hat == 1) now.Add(0x26);
                    if (hat >= 1 && hat <= 3) now.Add(0x27);
                    if (hat >= 3 && hat <= 5) now.Add(0x28);
                    if (hat >= 5 && hat <= 7) now.Add(0x25);
                }
                HashSet<byte> was; if (!held.TryGetValue(dev, out was)) was = new HashSet<byte>();
                foreach (var v in was) if (!now.Contains(v)) Key(v, false);
                bool menus = InMenus();
                foreach (var v in now) if (!was.Contains(v) && menus) Key(v, true);
                if (!menus) now.IntersectWith(was);   // a press outside the menus is not remembered as held
                held[dev] = now;
            }
        }
        finally { Marshal.FreeHGlobal(buf); }
    }

    IntPtr Preparsed(IntPtr dev)
    {
        IntPtr pd;
        if (preparsed.TryGetValue(dev, out pd)) return pd;
        uint size = 0; GetRawInputDeviceInfo(dev, RIDI_PREPARSEDDATA, IntPtr.Zero, ref size);
        pd = IntPtr.Zero;
        if (size > 0) { pd = Marshal.AllocHGlobal((int)size); if (GetRawInputDeviceInfo(dev, RIDI_PREPARSEDDATA, pd, ref size) == unchecked((uint)-1)) { Marshal.FreeHGlobal(pd); pd = IntPtr.Zero; } }
        preparsed[dev] = pd;   // kept for AmPanel's life: a few hundred bytes per gun
        return pd;
    }

    readonly HashSet<string> mouseHeld = new HashSet<string>();
    void Press(IntPtr dev, byte vk, bool down)
    {
        string id = dev.ToString() + ":" + vk;
        if (down) { if (!InMenus()) return; mouseHeld.Add(id); Key(vk, true); }
        else if (mouseHeld.Remove(id)) Key(vk, false);
    }

    bool InMenus()
    {
        if (GameRunning()) return false;
        int pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        try { using (var p = Process.GetProcessById(pid)) return p.ProcessName.Equals("retrofe", StringComparison.OrdinalIgnoreCase) || p.Id == Process.GetCurrentProcess().Id; }
        catch { return false; }
    }

    static void Key(byte vk, bool down)
    {
        bool ext = vk >= 0x25 && vk <= 0x28;
        keybd_event(vk, (byte)MapVirtualKey(vk, 0), (ext ? 1u : 0u) | (down ? 0u : 2u), UIntPtr.Zero);
    }
}
