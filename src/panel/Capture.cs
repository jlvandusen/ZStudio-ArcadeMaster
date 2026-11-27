// AmPanel - Control Capture: a guided Panel Test that knows WHICH DEVICE sent each press (James, 2026-11-26: "I want a
// capture tool built into the ampanel" ... "pick what you feel is button1 through whatever"). The old Panel Test
// (Watch-Inputs.ps1) saw key codes only: on the 2P stand-up the Mini-PAC and the keyboard both send Space / Shift /
// letters, and typing mixed into the capture.
//
//   keyboards, mice   Windows raw input (WM_INPUT, RIDEV_INPUTSINK): every event carries its device; the device's USB id
//                     names it (D209:0440 Mini-PAC, D209:16xx AimTrak, ...)
//   joysticks / pads  winmm joyGetPosEx, polled; joyGetDevCaps gives the USB id
//   guided            "PRESS P1 BUTTON 1" ... each step takes the next NEW input; 10 s with nothing = skipped. The
//                     keyboard's Esc (a keyboard that is not the panel) stops and saves; F2 skips a step.
//   saved             <manifest>\panel.json (players' keys, as New-PanelControlsArt.py reads them; hand-made entries kept;
//                     the old file kept as panel.json.bak-<time>), <manifest>\input-capture.json (every step: input +
//                     device). Then the controls cards and filters are redrawn (New-PanelControlsArt.py).
// Opened by the pipe {"cmd":"capture"} (Tools > Panel Test). docs/21: a hardware module that moves into the frontend later.
// C# 5.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows.Forms;

class CaptureForm : Form
{
    // ---------------------------------------------------------------- raw input
    [DllImport("user32.dll")] static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] devs, uint n, uint size);
    [DllImport("user32.dll")] static extern uint GetRawInputData(IntPtr h, uint cmd, IntPtr data, ref uint size, uint headerSize);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint GetRawInputDeviceInfo(IntPtr dev, uint cmd, StringBuilder data, ref uint size);
    [StructLayout(LayoutKind.Sequential)] struct RAWINPUTDEVICE { public ushort Page, Usage; public uint Flags; public IntPtr Target; }
    const uint RID_INPUT = 0x10000003, RIDI_DEVICENAME = 0x20000007, RIDEV_INPUTSINK = 0x100;
    const int WM_INPUT = 0x00FF;

    [DllImport("winmm.dll")] static extern int joyGetPosEx(int id, ref JOYINFOEX info);
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)] static extern int joyGetDevCaps(int id, ref JOYCAPS caps, int size);
    [StructLayout(LayoutKind.Sequential)] struct JOYINFOEX { public int Size, Flags, X, Y, Z, R, U, V, Buttons, ButtonNumber, POV, Reserved1, Reserved2; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct JOYCAPS
    {
        public ushort Mid, Pid; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Name;
        public int Xmin, Xmax, Ymin, Ymax, Zmin, Zmax, NumButtons, PeriodMin, PeriodMax, Rmin, Rmax, Umin, Umax, Vmin, Vmax, Caps, MaxAxes, NumAxes, MaxButtons;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string RegKey; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string OemVxD;
    }

    class Step { public string Id, Prompt, Kind; public Step(string id, string prompt, string kind) { Id = id; Prompt = prompt; Kind = kind; } }   // Kind: key | move | any
    class Hit { public string Step, Input, Key, Device, Usb; }

    readonly string manifestDir, toolsDir;
    readonly Action<string> log;
    readonly List<Step> steps = new List<Step>();
    readonly List<Hit> hits = new List<Hit>();
    readonly HashSet<string> used = new HashSet<string>();
    readonly Dictionary<IntPtr, string> devName = new Dictionary<IntPtr, string>();
    readonly Dictionary<IntPtr, int[]> moved = new Dictionary<IntPtr, int[]>();   // per mouse: |dx|, |dy| this step
    readonly Timer poll = new Timer { Interval = 15 };
    readonly Stopwatch stepClock = Stopwatch.StartNew();
    readonly int[] joyButtons = new int[16]; readonly int[,] joyAxes = new int[16, 2];
    int at; string flash, flashDevice; long flashAt = -9999;
    public bool Saved;

    public CaptureForm(string manifestDir, string toolsDir, int buttons, Action<string> log)
    {
        this.manifestDir = manifestDir; this.toolsDir = toolsDir; this.log = log ?? delegate { };
        foreach (var p in new[] { 1, 2 })
        {
            foreach (var d in new[] { "UP", "DOWN", "LEFT", "RIGHT" }) steps.Add(new Step("P" + p + d, "PLAYER " + p + " STICK " + d, "key"));
            for (int b = 1; b <= buttons; b++) steps.Add(new Step("P" + p + "B" + b, "PLAYER " + p + " BUTTON " + b, "key"));
            steps.Add(new Step("P" + p + "START", "PLAYER " + p + " START", "key"));
            steps.Add(new Step("P" + p + "COIN", "PLAYER " + p + " COIN", "key"));
        }
        steps.Add(new Step("TRACKBALL", "ROLL THE TRACKBALL", "move"));
        steps.Add(new Step("SPINNER", "TURN THE SPINNER", "move"));
        steps.Add(new Step("TRON_TRIGGER", "TRON STICK: TRIGGER", "key"));
        steps.Add(new Step("TRON_TOP", "TRON STICK: TOP BUTTON", "key"));
        steps.Add(new Step("GUN1_TRIGGER", "GUN 1: PULL THE TRIGGER", "key"));
        steps.Add(new Step("GUN2_TRIGGER", "GUN 2: PULL THE TRIGGER", "key"));
        steps.Add(new Step("PEDAL1", "FOOT SWITCH 1", "key"));
        steps.Add(new Step("PEDAL2", "FOOT SWITCH 2", "key"));
        steps.Add(new Step("EXTRA1", "ANY OTHER BUTTON (OR WAIT)", "key"));
        steps.Add(new Step("EXTRA2", "ANY OTHER BUTTON (OR WAIT)", "key"));

        Text = "ArcadeMaster - Panel Test"; FormBorderStyle = FormBorderStyle.None; TopMost = true; ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual; Bounds = Screen.PrimaryScreen.Bounds; BackColor = Color.FromArgb(8, 9, 14); DoubleBuffered = true; KeyPreview = true;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
        poll.Tick += delegate { PollJoysticks(); if (stepClock.ElapsedMilliseconds > 10000) Next(null); Invalidate(); };
        Shown += delegate { RegisterRaw(); for (int i = 0; i < 16; i++) ReadJoy(i, true); poll.Start(); ControllerChooser.TakeFocus(Handle); Activate(); };
        FormClosed += delegate { poll.Stop(); };
        KeyDown += (s, e) => e.Handled = true;   // raw input does the work; keys never reach anything behind
    }

    void RegisterRaw()
    {
        var d = new[] { new RAWINPUTDEVICE { Page = 1, Usage = 6, Flags = RIDEV_INPUTSINK, Target = Handle }, new RAWINPUTDEVICE { Page = 1, Usage = 2, Flags = RIDEV_INPUTSINK, Target = Handle } };
        if (!RegisterRawInputDevices(d, (uint)d.Length, (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE)))) log("capture: raw input not available");
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_INPUT) try { OnRaw(m.LParam); } catch (Exception e) { log("capture: " + e.Message); }
        base.WndProc(ref m);
    }

    void OnRaw(IntPtr h)
    {
        uint size = 0, hs = (uint)(IntPtr.Size * 2 + 8);
        GetRawInputData(h, RID_INPUT, IntPtr.Zero, ref size, hs);
        IntPtr buf = Marshal.AllocHGlobal((int)size);
        try
        {
            if (GetRawInputData(h, RID_INPUT, buf, ref size, hs) != size) return;
            int type = Marshal.ReadInt32(buf); IntPtr dev = Marshal.ReadIntPtr(buf, 8);
            IntPtr body = buf + (int)hs;
            string name = Name(dev), usb = Usb(name), label = DeviceLabel(usb, type == 1 ? "keyboard" : "mouse");
            if (type == 1)   // keyboard: MakeCode, Flags, Reserved, VKey, Message, ExtraInformation
            {
                ushort make = (ushort)Marshal.ReadInt16(body, 0), flags = (ushort)Marshal.ReadInt16(body, 2), vkey = (ushort)Marshal.ReadInt16(body, 6);
                bool up = (flags & 1) != 0, e0 = (flags & 2) != 0;
                if (up || vkey == 0xFF) return;
                string key = KeyName(vkey, make, e0);
                bool isPanel = usb != null && usb.StartsWith("D209:", StringComparison.OrdinalIgnoreCase);
                // the keyboard (not the panel): Esc stops and saves, F2 skips a step
                if (!isPanel && key == "ESC") { Finish(); return; }
                if (!isPanel && key == "F2") { Next(null); return; }
                Take("key " + key, key, label, usb, "key");
            }
            else if (type == 0)   // mouse: Flags(2) pad(2) ButtonFlags(2) ButtonData(2) RawButtons(4) LastX(4) LastY(4)
            {
                ushort mflags = (ushort)Marshal.ReadInt16(body, 0), bflags = (ushort)Marshal.ReadInt16(body, 4);
                int dx = Marshal.ReadInt32(body, 12), dy = Marshal.ReadInt32(body, 16);
                int btn = (bflags & 1) != 0 ? 1 : (bflags & 4) != 0 ? 2 : (bflags & 0x10) != 0 ? 3 : (bflags & 0x40) != 0 ? 4 : (bflags & 0x100) != 0 ? 5 : 0;
                if (btn > 0) { Take("mouse button " + btn, "MOUSE" + btn, label, usb, "key"); return; }
                if ((mflags & 1) != 0) return;   // absolute positions (a light gun aiming): not a trackball or spinner
                int[] a; if (!moved.TryGetValue(dev, out a)) moved[dev] = a = new int[2];
                a[0] += Math.Abs(dx); a[1] += Math.Abs(dy);
                if (a[0] + a[1] > 400) { string axes = a[1] * 4 < a[0] ? "X" : a[0] * 4 < a[1] ? "Y" : "X+Y"; moved.Clear(); Take("mouse moves " + axes, "MOUSE " + axes, label, usb, "move"); }
            }
        }
        finally { Marshal.FreeHGlobal(buf); }
    }

    string Name(IntPtr dev)
    {
        string n; if (devName.TryGetValue(dev, out n)) return n;
        uint size = 0; GetRawInputDeviceInfo(dev, RIDI_DEVICENAME, null, ref size);
        var sb = new StringBuilder((int)size + 1); GetRawInputDeviceInfo(dev, RIDI_DEVICENAME, sb, ref size);
        return devName[dev] = sb.ToString();
    }
    static string Usb(string devicePath) { var m = Regex.Match(devicePath ?? "", "VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})"); return m.Success ? (m.Groups[1].Value + ":" + m.Groups[2].Value).ToUpperInvariant() : null; }

    // what this cabinet's devices are called (USB ids seen on the cabinets; anything else by its id)
    static string DeviceLabel(string usb, string kind)
    {
        if (usb == null) return kind;
        if (usb == "D209:0440") return "Ultimarc Mini-PAC";
        if (usb.StartsWith("D209:04")) return "Ultimarc I-PAC";
        if (usb.StartsWith("D209:16")) return "Ultimarc AimTrak " + (usb == "D209:1601" ? "1" : usb == "D209:1602" ? "2" : usb.Substring(5));
        if (usb.StartsWith("D209:15")) return "Ultimarc mouse interface (" + usb + ")";
        if (usb.StartsWith("D209:")) return "Ultimarc " + usb;
        if (usb == "16C0:05E1") return "Xinmotek controller";
        if (usb == "1A86:E026") return "USB encoder 1A86:E026";
        if (usb.StartsWith("057E:")) return "Nintendo " + usb;
        if (usb.StartsWith("413C:")) return "Dell " + kind;
        if (usb.StartsWith("068E:")) return "CH Products " + usb;
        return kind + " " + usb;
    }

    // MAME's key names (what panel.json uses: LCONTROL, LALT, SPACE, LSHIFT, Z ...)
    static string KeyName(int vk, int make, bool e0)
    {
        if (vk == 0x11) return e0 ? "RCONTROL" : "LCONTROL";
        if (vk == 0x12) return e0 ? "RALT" : "LALT";
        if (vk == 0x10) return make == 0x36 ? "RSHIFT" : "LSHIFT";
        if (vk >= 0x41 && vk <= 0x5A) return ((char)vk).ToString();
        if (vk >= 0x30 && vk <= 0x39) return ((char)vk).ToString();
        if (vk >= 0x70 && vk <= 0x7B) return "F" + (vk - 0x6F);
        if (vk >= 0x60 && vk <= 0x69) return "KEYPAD" + (vk - 0x60);
        switch (vk)
        {
            case 0x20: return "SPACE"; case 0x0D: return e0 ? "ENTER_PAD" : "ENTER"; case 0x1B: return "ESC"; case 0x09: return "TAB"; case 0x08: return "BACKSPACE";
            case 0x26: return "UP"; case 0x28: return "DOWN"; case 0x25: return "LEFT"; case 0x27: return "RIGHT";
            case 0x2D: return "INSERT"; case 0x2E: return "DEL"; case 0x24: return "HOME"; case 0x23: return "END"; case 0x21: return "PGUP"; case 0x22: return "PGDN";
            case 0xBA: return "COLON"; case 0xBB: return "EQUALS"; case 0xBC: return "COMMA"; case 0xBD: return "MINUS"; case 0xBE: return "STOP"; case 0xBF: return "SLASH";
            case 0xC0: return "TILDE"; case 0xDB: return "OPENBRACE"; case 0xDC: return "BACKSLASH"; case 0xDD: return "CLOSEBRACE"; case 0xDE: return "QUOTE";
        }
        return "VK" + vk.ToString("X2");
    }

    // ---------------------------------------------------------------- joysticks
    void PollJoysticks() { for (int i = 0; i < 16; i++) ReadJoy(i, false); }
    void ReadJoy(int id, bool baseline)
    {
        var j = new JOYINFOEX { Size = Marshal.SizeOf(typeof(JOYINFOEX)), Flags = 0xFF };
        if (joyGetPosEx(id, ref j) != 0) return;
        if (baseline) { joyButtons[id] = j.Buttons; joyAxes[id, 0] = j.X; joyAxes[id, 1] = j.Y; return; }
        int newly = j.Buttons & ~joyButtons[id]; joyButtons[id] = j.Buttons;
        string usb = null, label = "joystick " + (id + 1);
        if (newly != 0 || Math.Abs(j.X - joyAxes[id, 0]) > 20000 || Math.Abs(j.Y - joyAxes[id, 1]) > 20000)
        {
            var c = new JOYCAPS(); if (joyGetDevCaps(id, ref c, Marshal.SizeOf(typeof(JOYCAPS))) == 0) { usb = c.Mid.ToString("X4") + ":" + c.Pid.ToString("X4"); label = DeviceLabel(usb, "joystick") + " (joystick " + (id + 1) + ")"; }
        }
        for (int b = 0; b < 32; b++) if ((newly & (1 << b)) != 0) { Take("joystick " + (id + 1) + " button " + (b + 1), "JOY" + (id + 1) + "_BUTTON" + (b + 1), label, usb, "key"); return; }
        foreach (var ax in new[] { 0, 1 })
        {
            int v = ax == 0 ? j.X : j.Y, rest = joyAxes[id, ax];
            if (Math.Abs(v - rest) > 20000) { joyAxes[id, ax] = v; Take("joystick " + (id + 1) + " " + (ax == 0 ? "X" : "Y") + (v > rest ? "+" : "-"), "JOY" + (id + 1) + "_" + (ax == 0 ? "X" : "Y") + (v > rest ? "+" : "-"), label, usb, "key"); return; }
            if (Math.Abs(v - 32767) < 8000) joyAxes[id, ax] = v;   // back near the centre: ready for the next push
        }
    }

    // ---------------------------------------------------------------- steps
    void Take(string what, string key, string device, string usb, string kind)
    {
        flash = what; flashDevice = device; flashAt = Environment.TickCount;
        if (at >= steps.Count) return;
        var s = steps[at];
        if (s.Kind == "move" && kind != "move") return;            // the trackball step waits for movement
        if (s.Kind == "key" && kind == "move") return;             // a key step ignores a mouse sliding
        string sig = key + "|" + usb;
        if (used.Contains(sig)) { flash = what + "  (ALREADY TAKEN)"; return; }
        used.Add(sig);
        hits.Add(new Hit { Step = s.Id, Input = what, Key = key, Device = device, Usb = usb });
        log("capture: " + s.Id + " = " + what + " from " + device);
        Next(s.Id);
    }

    void Next(string took)
    {
        if (took == null && at < steps.Count) log("capture: " + steps[at].Id + " skipped");
        at++; stepClock.Restart(); moved.Clear();
        if (at >= steps.Count) Finish();
    }

    void Finish()
    {
        if (Saved) return;
        poll.Stop();
        if (hits.Count == 0) { log("capture: nothing pressed - panel.json left as it was"); Close(); return; }
        try { Save(); Saved = true; } catch (Exception e) { log("capture: not saved - " + e.Message); }
        Close();
    }

    // ---------------------------------------------------------------- saving
    void Save()
    {
        var js = new JavaScriptSerializer();
        string pj = Path.Combine(manifestDir, "panel.json");
        Dictionary<string, object> panel = new Dictionary<string, object>();
        if (File.Exists(pj)) { try { panel = js.Deserialize<Dictionary<string, object>>(File.ReadAllText(pj)) ?? panel; } catch { } File.Copy(pj, pj + ".bak-" + DateTime.Now.ToString("yyyyMMdd-HHmmss"), true); }
        Func<string, Hit> hit = id => hits.FirstOrDefault(x => x.Step == id);
        var players = new List<object>();
        foreach (var p in new[] { 1, 2 })
        {
            var keys = new Dictionary<string, object>(); int nb = 0;
            for (int b = 1; b <= 16; b++) { var hb = hit("P" + p + "B" + b); if (hb == null) continue; keys["P" + p + "B" + b] = hb.Key; nb = b; }
            foreach (var x in new[] { "START", "COIN" }) { var hx = hit("P" + p + x); if (hx != null) keys["P" + p + x] = hx.Key; }
            var stick = new Dictionary<string, object>();
            foreach (var d in new[] { "UP", "DOWN", "LEFT", "RIGHT" }) { var hd = hit("P" + p + d); if (hd != null) stick[d] = hd.Key; }
            if (nb == 0 && stick.Count == 0) continue;
            players.Add(new Dictionary<string, object> {
                { "position", "P" + p }, { "buttons", nb }, { "rows", nb > 3 ? 2 : 1 }, { "cols", nb > 3 ? (nb + 1) / 2 : nb },
                { "start", keys.ContainsKey("P" + p + "START") }, { "coin", keys.ContainsKey("P" + p + "COIN") }, { "keys", keys }, { "stick", stick }, { "pos", new Dictionary<string, object>() } });
        }
        if (players.Count > 0) panel["players"] = players;
        var tb = hit("TRACKBALL"); if (tb != null) panel["trackball"] = new Dictionary<string, object> { { "name", "Trackball" }, { "buttons", 0 }, { "keys", new Dictionary<string, object>() }, { "device", tb.Device }, { "usb", tb.Usb } };
        var sp = hit("SPINNER"); if (sp != null) panel["spinner"] = new Dictionary<string, object> { { "name", "Spinner" }, { "buttons", 0 }, { "keys", new Dictionary<string, object>() }, { "device", sp.Device }, { "usb", sp.Usb } };
        var tt = hit("TRON_TRIGGER"); var tp = hit("TRON_TOP");
        if (tt != null || tp != null) panel["tronStick"] = new Dictionary<string, object> { { "trigger", tt != null ? tt.Key : null }, { "top", tp != null ? tp.Key : null }, { "device", (tt ?? tp).Device } };
        var pedals = hits.Where(x => x.Step.StartsWith("PEDAL")).Select(x => (object)new Dictionary<string, object> { { "key", x.Key }, { "device", x.Device } }).ToList();
        if (pedals.Count > 0) panel["pedals"] = pedals;
        var extras = hits.Where(x => x.Step.StartsWith("EXTRA")).Select(x => (object)new Dictionary<string, object> { { "key", x.Key }, { "device", x.Device } }).ToList();
        if (extras.Count > 0) panel["extras"] = extras;
        panel["source"] = "AmPanel Panel Test (control capture), " + DateTime.Now.ToString("s");
        File.WriteAllText(pj, js.Serialize(panel));
        File.WriteAllText(Path.Combine(manifestDir, "input-capture.json"), js.Serialize(hits.Select(x => new Dictionary<string, object> { { "step", x.Step }, { "input", x.Input }, { "key", x.Key }, { "device", x.Device }, { "usb", x.Usb } }).ToList()));
        log("capture: saved " + hits.Count + " control(s) to " + pj);
        RedrawCards();
    }

    // the controls cards and filters follow the new panel (New-PanelControlsArt.py), in the background
    void RedrawCards()
    {
        try
        {
            string py = new[] { @"C:\Program Files\Python312\python.exe", Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Programs\Python\Python312\python.exe") }.FirstOrDefault(File.Exists);
            string tool = toolsDir == null ? null : Path.Combine(toolsDir, "New-PanelControlsArt.py");
            string cfg = Path.Combine(Path.GetDirectoryName(manifestDir.TrimEnd('\\')) ?? manifestDir, "ArcadeMaster.config.json"), root = null;
            if (File.Exists(cfg)) { var m = Regex.Match(File.ReadAllText(cfg), "\"RetroFERoot\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""); if (m.Success) root = Regex.Unescape(m.Groups[1].Value); }
            if (py == null || tool == null || !File.Exists(tool) || root == null) { log("capture: controls cards not redrawn (python / tool / frontend root not found)"); return; }
            Process.Start(new ProcessStartInfo(py, "\"" + tool + "\" --retrofe \"" + root + "\" --manifest \"" + manifestDir + "\"") { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Path.GetDirectoryName(toolsDir) });
            log("capture: redrawing the controls cards and filters");
        }
        catch (Exception e) { log("capture: cards not redrawn - " + e.Message); }
    }

    // ---------------------------------------------------------------- drawing
    protected override void OnPaintBackground(PaintEventArgs e) { }
    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        g.Clear(Color.FromArgb(8, 9, 14));
        Color cyan = Color.FromArgb(0, 229, 255), mag = Color.FromArgb(255, 45, 160), dim = Color.FromArgb(150, 160, 180);
        using (var f = new Font("Segoe UI", Height * 0.03f, FontStyle.Bold, GraphicsUnit.Pixel)) Center(g, "PANEL TEST  -  " + Math.Min(at + 1, steps.Count) + " / " + steps.Count, f, dim, Height * 0.08f);
        if (at < steps.Count)
        {
            using (var f = new Font("Segoe UI", Height * 0.08f, FontStyle.Bold, GraphicsUnit.Pixel))
            using (var br = new LinearGradientBrush(new Rectangle(0, 0, Width, Height), cyan, mag, 0f))
            {
                var sz = g.MeasureString(steps[at].Prompt, f); g.DrawString(steps[at].Prompt, f, br, (Width - sz.Width) / 2, Height * 0.3f);
            }
            float left = Math.Max(0, 1 - stepClock.ElapsedMilliseconds / 10000f);
            using (var br = new SolidBrush(Color.FromArgb(60, 255, 255, 255))) g.FillRectangle(br, Width * 0.3f, Height * 0.48f, Width * 0.4f, 8);
            using (var br = new LinearGradientBrush(new RectangleF(Width * 0.3f, 0, Width * 0.4f, 8), cyan, mag, 0f)) g.FillRectangle(br, Width * 0.3f, Height * 0.48f, Math.Max(1, Width * 0.4f * left), 8);
        }
        if (flash != null && Environment.TickCount - flashAt < 2500)
            using (var f = new Font("Segoe UI", Height * 0.035f, FontStyle.Bold, GraphicsUnit.Pixel)) { Center(g, flash.ToUpperInvariant(), f, Color.White, Height * 0.56f); Center(g, "FROM " + (flashDevice ?? "?").ToUpperInvariant(), f, cyan, Height * 0.61f); }
        // what is taken so far
        using (var f = new Font("Consolas", Height * 0.018f, FontStyle.Regular, GraphicsUnit.Pixel))
        {
            int n = 0; float x0 = Width * 0.08f, y0 = Height * 0.7f, colW = Width * 0.28f, rowH = f.Height * 1.15f; int perCol = (int)((Height * 0.26f) / rowH);
            foreach (var h in hits.Skip(Math.Max(0, hits.Count - perCol * 3)))
            {
                using (var br = new SolidBrush(dim)) g.DrawString(h.Step.PadRight(13) + h.Key + "  " + h.Device, f, br, x0 + (n / perCol) * colW, y0 + (n % perCol) * rowH);
                n++;
            }
        }
        using (var f = new Font("Segoe UI", Height * 0.02f, FontStyle.Bold, GraphicsUnit.Pixel)) Center(g, "PRESS IT, OR WAIT 10 S TO SKIP   -   KEYBOARD: F2 SKIP, ESC SAVE AND CLOSE", f, dim, Height * 0.95f);
    }
    void Center(Graphics g, string s, Font f, Color c, float y) { var sz = g.MeasureString(s, f); using (var br = new SolidBrush(c)) g.DrawString(s, f, br, (Width - sz.Width) / 2, y); }
}
