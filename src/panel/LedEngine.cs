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
        int[] use = rgb;
        if (use == null && !baseColor.TryGetValue(label, out use)) use = new[] { 0, 0, 0 };
        if (SetLabel(label, use)) Flush();
    }
    public int[] Color(string name) { int[] c; return name != null && palette.TryGetValue(name, out c) ? c : null; }

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

    public void Close() { if (open) { try { AllOff(); PacShutdown(); } catch { } open = false; } }

    // a game's colours: every control it lists lit in its colour, every other button off. Unknown game: attract white.
    public string LightGame(string rom)
    {
        if (!open) return "LED boards not open";
        foreach (var f in frame.Values) Array.Clear(f, 0, f.Length);
        baseColor.Clear();
        Dictionary<string, string> g;
        if (rom == null || !games.TryGetValue(rom, out g))
        {
            foreach (var label in pins.Keys) { SetLabel(label, new[] { 16, 16, 16 }); baseColor[label] = new[] { 16, 16, 16 }; }   // no colours known: soft white
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
        Flush();
        return lit + " controls lit for " + rom;
    }

    public void AllOff() { foreach (var f in frame.Values) Array.Clear(f, 0, f.Length); Flush(); }

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
