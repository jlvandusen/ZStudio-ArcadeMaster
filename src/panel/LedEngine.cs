// AmPanel step 2 - per-game button colours, driven by AmPanel itself (docs/13-panel-service.md).
//
// Reads LEDBlinky's documented files once:
//   LEDBlinkyInputMap.xml  <ledController id=N><port number=P label="P1B1" type="R|G|B|S"/>   (which pin is which)
//   Colors.ini             [rom] P1_BUTTON1=Red ...                                           (each game's colours)
//   Color-RGB.ini          [Colors] Red=48,0,0 ...                                            (names -> 0-48 intensities)
// and sets every LED of a board with ONE PacDrive SDK call (Pac64SetLEDIntensities, 96 values) per game change.
// Only used when AmPanel.json says "Lights": "own" - LEDBlinky must not be driving the same boards.
// C# 5.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Xml;

class LedEngine
{
    [DllImport("PacDrive32.dll", CallingConvention = CallingConvention.StdCall)] static extern int PacInitialize();
    [DllImport("PacDrive32.dll", CallingConvention = CallingConvention.StdCall)] static extern void PacShutdown();
    [DllImport("PacDrive32.dll", CallingConvention = CallingConvention.StdCall)] static extern int PacGetDeviceType(int id);
    [DllImport("PacDrive32.dll", CallingConvention = CallingConvention.StdCall)] static extern bool Pac64SetLEDIntensities(int id, byte[] data);
    [DllImport("PacDrive32.dll", CallingConvention = CallingConvention.StdCall)] static extern bool Pac64SetLEDFadeTime(int id, byte fadeTime);

    class Pin { public int Board; public int Port; public char Channel; }           // Board = InputMap controller id
    readonly Dictionary<string, List<Pin>> pins = new Dictionary<string, List<Pin>>(StringComparer.OrdinalIgnoreCase);   // "P1B1" -> its R/G/B pins
    readonly Dictionary<string, int[]> palette = new Dictionary<string, int[]>(StringComparer.OrdinalIgnoreCase);       // "Red" -> {48,0,0}
    readonly Dictionary<string, Dictionary<string, string>> games = new Dictionary<string, Dictionary<string, string>>(StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<int, int> boardToDevice = new Dictionary<int, int>();   // InputMap controller id -> PacDrive device index
    readonly Dictionary<int, byte[]> frame = new Dictionary<int, byte[]>();
    public int Boards { get { return boardToDevice.Count; } }
    public int Buttons { get { return pins.Count; } }
    public int Games { get { return games.Count; } }
    public string LastError;
    bool open;
    // each label's colour for the current game, so an output-driven override (a start lamp flashing) can fall back to it
    readonly Dictionary<string, int[]> baseColor = new Dictionary<string, int[]>(StringComparer.OrdinalIgnoreCase);
    public bool HasLabel(string label) { return pins.ContainsKey(label); }

    // step 10: a trigger lights one control in a colour (rgb, 0-48 scale), or puts its game colour back (rgb = null)
    public void Override(string label, int[] rgb)
    {
        if (!open) return;
        if (StopAnim()) RestoreBase();
        int[] use = rgb;
        if (use == null && !baseColor.TryGetValue(label, out use)) use = new[] { 0, 0, 0 };
        if (SetLabel(label, use)) Flush();
    }
    public int[] Color(string name) { int[] c; return name != null && palette.TryGetValue(name, out c) ? c : null; }

    // step 5: a held button glows - its game colour at full strength, or white when the game leaves it dark
    public void Glow(string label, bool held)
    {
        if (!open || !pins.ContainsKey(label)) return;
        if (StopAnim()) RestoreBase();   // any press ends the attract animation
        if (!held) { Override(label, null); return; }
        int[] b; baseColor.TryGetValue(label, out b);
        int mx = b == null ? 0 : Math.Max(b[0], Math.Max(b[1], b[2]));
        int[] g = mx <= 6 ? new[] { 48, 48, 48 } : new[] { b[0] * 48 / mx, b[1] * 48 / mx, b[2] * 48 / mx };
        if (SetLabel(label, g)) Flush();
    }

    // which button each key is (InputMap inputCodes, e.g. KEYCODE_LCONTROL|KEYCODE_CONTROL -> P1B1)
    public Dictionary<string, List<string>> KeyLabels()
    {
        var d = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        foreach (var kv in inputCodes)
            foreach (var code in kv.Value.Split('|'))
            {
                string k = code.Trim(); if (k.Length == 0) continue;
                List<string> l; if (!d.TryGetValue(k, out l)) { l = new List<string>(); d[k] = l; }
                if (!l.Contains(kv.Key)) l.Add(kv.Key);
            }
        return d;
    }
    readonly Dictionary<string, string> inputCodes = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

    public LedEngine(string ledBlinkyDir)
    {
        LoadInputMap(Path.Combine(ledBlinkyDir, "LEDBlinkyInputMap.xml"));
        LoadIni(Path.Combine(ledBlinkyDir, "Color-RGB.ini"), delegate (string sec, string k, string v) {
            if (!sec.Equals("Colors", StringComparison.OrdinalIgnoreCase)) return;
            var p = v.Split(',');
            if (p.Length == 3) palette[k] = new[] { ToInt(p[0]), ToInt(p[1]), ToInt(p[2]) };
        });
        LoadIni(Path.Combine(ledBlinkyDir, "Colors.ini"), delegate (string sec, string k, string v) {
            Dictionary<string, string> g;
            if (!games.TryGetValue(sec, out g)) { g = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase); games[sec] = g; }
            g[k] = v;
        });
    }

    // the SDK, and which device index each InputMap LED controller is: LED boards in SDK order (I-PAC Ultimate I/O,
    // PacLED64, Nano-LED) are controllers 1, 2, ... - the order LEDBlinky's input map generator numbers them in
    public bool Open()
    {
        try
        {
            int n = PacInitialize(), next = 1;
            for (int i = 0; i < n; i++)
            {
                int t = PacGetDeviceType(i);
                if (t == 3 || t == 4 || t == 6) { boardToDevice[next] = i; frame[next] = new byte[96]; Pac64SetLEDFadeTime(i, 0); next++; }
            }
            open = boardToDevice.Count > 0;
            if (!open) LastError = "no LED boards found";
            return open;
        }
        catch (Exception e) { LastError = e.Message; return false; }
    }

    public void Close() { if (open) { try { StopAnim(); AllOff(); PacShutdown(); } catch { } open = false; } }

    // ---------------------------------------------------------------- step 6: attract animations
    // One animation thread at a time; every other write first stops it (StopAnim) so there is a single writer.
    System.Threading.Thread anim;
    volatile bool animRun;
    public string Animation { get; private set; }

    public string Animate(string kind)
    {
        bool was = StopAnim();
        if (string.IsNullOrEmpty(kind) || kind == "stop") { if (was) RestoreBase(); return "animation stopped"; }
        if (!open) return "LED boards not open";
        if (kind != "breathe" && kind != "chase") return "unknown animation '" + kind + "' (breathe, chase, stop)";
        var labels = new List<string>(pins.Keys); labels.Sort(StringComparer.OrdinalIgnoreCase);
        animRun = true; Animation = kind;
        anim = new System.Threading.Thread(delegate () { AnimLoop(kind, labels); }) { IsBackground = true, Name = "led-anim" };
        anim.Start();
        return kind + " on " + labels.Count + " buttons";
    }

    bool StopAnim()
    {
        var t = anim; if (t == null) return false;
        animRun = false; t.Join(500); anim = null; Animation = null;
        return true;
    }

    void RestoreBase()
    {
        foreach (var f in frame.Values) Array.Clear(f, 0, f.Length);
        foreach (var kv in baseColor) SetLabel(kv.Key, kv.Value);
        Flush();
    }

    void AnimLoop(string kind, List<string> labels)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        while (animRun)
        {
            double t = sw.Elapsed.TotalSeconds;
            foreach (var f in frame.Values) Array.Clear(f, 0, f.Length);
            for (int i = 0; i < labels.Count; i++)
            {
                int[] rgb;
                if (kind == "breathe")
                {
                    // the game's own colours pulsing (soft white where the game has none), 2.5 s per breath
                    int[] b; if (!baseColor.TryGetValue(labels[i], out b)) b = new[] { 24, 24, 24 };
                    double k = 0.15 + 0.85 * (0.5 + 0.5 * Math.Sin(2 * Math.PI * t / 2.5));
                    rgb = new[] { (int)(b[0] * k), (int)(b[1] * k), (int)(b[2] * k) };
                }
                else
                {
                    // a rainbow running across the panel, one hue step per button
                    double h = (i * 0.06 + t * 0.35) % 1.0;
                    rgb = Hue(h);
                }
                SetLabel(labels[i], rgb);
            }
            Flush();
            System.Threading.Thread.Sleep(33);   // ~30 frames a second: one SDK call per board per frame
        }
    }

    static int[] Hue(double h)
    {
        double r = Math.Abs(h * 6 - 3) - 1, g = 2 - Math.Abs(h * 6 - 2), b = 2 - Math.Abs(h * 6 - 4);
        return new[] { (int)(48 * Clamp(r)), (int)(48 * Clamp(g)), (int)(48 * Clamp(b)) };
    }
    static double Clamp(double v) { return v < 0 ? 0 : v > 1 ? 1 : v; }

    // a game's colours: every control it lists lit in its colour, every other button off. Unknown game: attract white.
    public string LightGame(string rom)
    {
        if (!open) return "LED boards not open";
        StopAnim();
        foreach (var f in frame.Values) Array.Clear(f, 0, f.Length);
        baseColor.Clear();
        Dictionary<string, string> g;
        if (rom == null || !games.TryGetValue(rom, out g))
        {
            foreach (var label in pins.Keys) { SetLabel(label, new[] { 16, 16, 16 }); baseColor[label] = new[] { 16, 16, 16 }; }   // no colours known: soft white
            ApplyOverrides(rom);
            Flush();
            return "no colours for '" + rom + "' - all buttons soft white";
        }
        int lit = 0;
        foreach (var kv in g)
        {
            string label = ToLabel(kv.Key);
            int[] rgb;
            if (label == null || !palette.TryGetValue(kv.Value, out rgb)) continue;
            if (SetLabel(label, rgb)) { lit++; baseColor[label] = rgb; }
        }
        lit += ApplyOverrides(rom);
        Flush();
        return lit + " controls lit for " + rom;
    }

    // ---------------------------------------------------------------- step 11: the cabinet's own colours
    // <manifest>\led-colors.json { "sf2": { "P1B1": [48,0,0] }, "*": { "P1START": [48,48,48] } } - a game's own entry
    // beats "*", both beat Colors.ini. Colors.ini itself is never edited, so "reset" always works.
    public string OverridesFile;
    Dictionary<string, Dictionary<string, int[]>> overrides = new Dictionary<string, Dictionary<string, int[]>>(StringComparer.OrdinalIgnoreCase);

    public void LoadOverrides(string file)
    {
        OverridesFile = file;
        overrides = new Dictionary<string, Dictionary<string, int[]>>(StringComparer.OrdinalIgnoreCase);
        if (file == null || !File.Exists(file)) return;
        try
        {
            var root = new System.Web.Script.Serialization.JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(file));
            foreach (var g in root)
            {
                var d = g.Value as Dictionary<string, object>; if (d == null) continue;
                var m = new Dictionary<string, int[]>(StringComparer.OrdinalIgnoreCase);
                foreach (var kv in d)
                {
                    var a = kv.Value as System.Collections.ArrayList;
                    if (a != null && a.Count == 3) m[kv.Key] = new[] { Convert.ToInt32(a[0]), Convert.ToInt32(a[1]), Convert.ToInt32(a[2]) };
                    else { int[] c; if (kv.Value != null && palette.TryGetValue(Convert.ToString(kv.Value), out c)) m[kv.Key] = c; }
                }
                overrides[g.Key] = m;
            }
        }
        catch (Exception e) { LastError = "led-colors.json: " + e.Message; }
    }

    int ApplyOverrides(string rom)
    {
        int n = 0;
        foreach (var key in new[] { "*", rom })
        {
            Dictionary<string, int[]> m; if (key == null || !overrides.TryGetValue(key, out m)) continue;
            foreach (var kv in m) if (SetLabel(kv.Key, kv.Value)) { baseColor[kv.Key] = kv.Value; n++; }
        }
        return n;
    }

    public void SetGameColor(string rom, string label, int[] rgb)   // rgb null = remove this override
    {
        Dictionary<string, int[]> m;
        if (!overrides.TryGetValue(rom, out m)) { m = new Dictionary<string, int[]>(StringComparer.OrdinalIgnoreCase); overrides[rom] = m; }
        if (rgb == null) m.Remove(label); else m[label] = rgb;
        if (m.Count == 0) overrides.Remove(rom);
        SaveOverrides();
    }
    public void ResetGame(string rom) { overrides.Remove(rom); SaveOverrides(); }
    public bool HasOverrides(string rom) { return overrides.ContainsKey(rom); }

    void SaveOverrides()
    {
        if (OverridesFile == null) return;
        var sb = new System.Text.StringBuilder("{\n");
        bool firstG = true;
        foreach (var g in overrides)
        {
            sb.Append(firstG ? "" : ",\n").Append("  \"").Append(g.Key.Replace("\"", "")).Append("\": {");
            bool first = true;
            foreach (var kv in g.Value) { sb.Append(first ? " " : ", ").Append('"').Append(kv.Key.Replace("\"", "")).Append("\": [").Append(kv.Value[0]).Append(',').Append(kv.Value[1]).Append(',').Append(kv.Value[2]).Append(']'); first = false; }
            sb.Append(" }"); firstG = false;
        }
        sb.Append("\n}\n");
        File.WriteAllText(OverridesFile, sb.ToString(), new System.Text.UTF8Encoding(false));
    }

    // what the colour screen shows: every mapped button with its colour for this game (after overrides)
    public SortedDictionary<string, int[]> GameColors(string rom)
    {
        var d = new SortedDictionary<string, int[]>(StringComparer.OrdinalIgnoreCase);
        foreach (var label in pins.Keys) d[label] = new[] { 0, 0, 0 };
        Dictionary<string, string> g;
        if (rom != null && games.TryGetValue(rom, out g))
            foreach (var kv in g) { string l = ToLabel(kv.Key); int[] c; if (l != null && d.ContainsKey(l) && palette.TryGetValue(kv.Value, out c)) d[l] = c; }
        foreach (var key in new[] { "*", rom })
        {
            Dictionary<string, int[]> m; if (key == null || !overrides.TryGetValue(key, out m)) continue;
            foreach (var kv in m) if (d.ContainsKey(kv.Key)) d[kv.Key] = kv.Value;
        }
        return d;
    }
    public bool KnowsGame(string rom) { return rom != null && games.ContainsKey(rom); }
    public List<string> Labels { get { var l = new List<string>(pins.Keys); l.Sort(StringComparer.OrdinalIgnoreCase); return l; } }
    public List<string> ColorNames { get { var l = new List<string>(palette.Keys); l.Sort(StringComparer.OrdinalIgnoreCase); return l; } }

    public void AllOff() { StopAnim(); foreach (var f in frame.Values) Array.Clear(f, 0, f.Length); Flush(); }

    // ---------------------------------------------------------------- LEDBlinky command 14: set LED ports
    // "14 port,intensity[,port,intensity...]". A port is a plain number (board 1, port 1-96; 97+ runs on into board 2,
    // the numbering LEDBlinky uses), "board:port", or a button label (P1B1: every channel of that button). Intensity is
    // LEDBlinky's 0-48, or a colour name from Color-RGB.ini for a label. The rest of the panel is left as it is.
    public string SetPorts(string spec)
    {
        if (!open) return "LED boards not open";
        if (string.IsNullOrEmpty(spec)) return "no ports given (14 port,intensity,...)";
        StopAnim();
        var p = spec.Split(new[] { ',', ' ' }, StringSplitOptions.RemoveEmptyEntries);
        int set = 0; var bad = new List<string>();
        for (int i = 0; i + 1 < p.Length; i += 2)
        {
            string port = p[i].Trim(), val = p[i + 1].Trim();
            int v; int[] rgb = null;
            if (!int.TryParse(val, out v)) { if (!palette.TryGetValue(val, out rgb)) { bad.Add(port + "=" + val); continue; } v = Math.Max(rgb[0], Math.Max(rgb[1], rgb[2])); }
            v = Math.Max(0, Math.Min(48, v));
            if (pins.ContainsKey(port)) { if (SetLabel(port, rgb ?? new[] { v, v, v })) set++; continue; }
            int board = 1, n;
            int c = port.IndexOf(':');
            if (c > 0) { if (!int.TryParse(port.Substring(0, c), out board) || !int.TryParse(port.Substring(c + 1), out n)) { bad.Add(port); continue; } }
            else if (!int.TryParse(port, out n)) { bad.Add(port); continue; }
            while (n > 96) { n -= 96; board++; }
            byte[] f;
            if (n < 1 || !frame.TryGetValue(board, out f)) { bad.Add(port); continue; }
            f[n - 1] = (byte)(v * 255 / 48); set++;
        }
        Flush();
        return set + " port(s) set" + (bad.Count > 0 ? ", not understood: " + string.Join(" ", bad) : "");
    }

    // ---------------------------------------------------------------- LEDBlinky 16 / 17: game paused
    // the game's colours at a quarter while paused, back at full on unpause (a pause you can see from across the room)
    public string Dim(bool on)
    {
        if (!open) return "LED boards not open";
        StopAnim();
        foreach (var f in frame.Values) Array.Clear(f, 0, f.Length);
        foreach (var kv in baseColor) SetLabel(kv.Key, on ? new[] { kv.Value[0] / 4, kv.Value[1] / 4, kv.Value[2] / 4 } : kv.Value);
        Flush();
        return on ? "paused: dimmed to 25%" : "unpaused: full colour";
    }

    // ---------------------------------------------------------------- helpers
    bool SetLabel(string label, int[] rgb)
    {
        List<Pin> list;
        if (!pins.TryGetValue(label, out list)) return false;
        foreach (var p in list)
        {
            byte[] f; if (!frame.TryGetValue(p.Board, out f) || p.Port < 1 || p.Port > f.Length) continue;
            int v = p.Channel == 'R' ? rgb[0] : p.Channel == 'G' ? rgb[1] : p.Channel == 'B' ? rgb[2] : Math.Max(rgb[0], Math.Max(rgb[1], rgb[2]));
            f[p.Port - 1] = (byte)Math.Min(255, v * 255 / 48);   // LEDBlinky's 0-48 scale -> the board's 0-255
        }
        return true;
    }

    void Flush()
    {
        foreach (var kv in frame) { int dev; if (boardToDevice.TryGetValue(kv.Key, out dev)) Pac64SetLEDIntensities(dev, kv.Value); }
    }

    // Colors.ini key -> InputMap label: P1_BUTTON1 -> P1B1, P1_START -> P1START, P1_COIN -> P1COIN, P1_JOYSTICK -> P1JOY...
    static string ToLabel(string key)
    {
        string k = key.ToUpperInvariant();
        if (k.Length > 3 && k[0] == 'P' && char.IsDigit(k[1]) && k[2] == '_')
        {
            string p = k.Substring(0, 2), rest = k.Substring(3);
            if (rest.StartsWith("BUTTON")) return p + "B" + rest.Substring(6);
            if (rest == "START" || rest == "COIN") return p + rest;
            if (rest.StartsWith("JOYSTICK")) return p + "JOY";
            return p + rest;
        }
        return k;   // CONTROLS_SPINNER, TRACKBALL... as LEDBlinky labels them
    }

    void LoadInputMap(string path)
    {
        if (!File.Exists(path)) { LastError = "no " + path; return; }
        var doc = new XmlDocument(); doc.Load(path);
        foreach (XmlElement c in doc.SelectNodes("//ledController"))
        {
            int board = ToInt(c.GetAttribute("id"));
            foreach (XmlElement p in c.SelectNodes("port"))
            {
                string label = p.GetAttribute("label"), type = p.GetAttribute("type");
                if (string.IsNullOrEmpty(label)) continue;
                string ic = p.GetAttribute("inputCodes"); if (!string.IsNullOrEmpty(ic)) inputCodes[label] = ic;
                List<Pin> list;
                if (!pins.TryGetValue(label, out list)) { list = new List<Pin>(); pins[label] = list; }
                list.Add(new Pin { Board = board, Port = ToInt(p.GetAttribute("number")), Channel = string.IsNullOrEmpty(type) ? 'S' : char.ToUpperInvariant(type[0]) });
            }
        }
    }

    static void LoadIni(string path, Action<string, string, string> each)
    {
        if (!File.Exists(path)) return;
        string sec = "";
        foreach (var raw in File.ReadLines(path))
        {
            string l = raw.Trim();
            if (l.Length == 0 || l[0] == ';' || l[0] == '#') continue;
            if (l[0] == '[' && l.EndsWith("]")) { sec = l.Substring(1, l.Length - 2).Trim(); continue; }
            int eq = l.IndexOf('='); if (eq <= 0) continue;
            each(sec, l.Substring(0, eq).Trim(), l.Substring(eq + 1).Trim());
        }
    }

    static int ToInt(string s) { int v; return int.TryParse((s ?? "").Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out v) ? v : 0; }
}
