// AmPanel - UltraStik 360 maps per game (LEDBlinky command 13, and automatic on every game start).
//
// Ultimarc's UltraStik32.dll (next to LEDBlinky, 32-bit): UltraStik_Initialize() -> count,
// UltraStik_LoadMapFile(id, "x.um") writes a 9x9 direction grid to a stick. The calls were checked against the DLL
// (stdcall, ret 8 = two arguments), not guessed.
// Which map a game wants comes from <manifest>\stick-maps.json, written by tools\New-StickMaps.py from MAME's own
// control data (4-way, 2-way, vertical 2-way, analog) plus tools\stick-maps-overrides.json (Q*bert diagonal, ...).
// Map files: <manifest>\ultrastik\*.um (ArcadeMaster's own set), then LEDBlinky's jdr\UltraStik.
// A stick is only written when its map really changes: no USB traffic on a scroll, none during play.
// C# 5.
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

class Sticks
{
    [DllImport("UltraStik32.dll", CallingConvention = CallingConvention.StdCall)] static extern int UltraStik_Initialize();
    [DllImport("UltraStik32.dll", CallingConvention = CallingConvention.StdCall)] static extern void UltraStik_Shutdown();
    [DllImport("UltraStik32.dll", CallingConvention = CallingConvention.StdCall, CharSet = CharSet.Ansi)] static extern int UltraStik_LoadMapFile(int id, string file);
    [DllImport("UltraStik32.dll", CallingConvention = CallingConvention.StdCall)] static extern int UltraStik_GetProductId(int id);

    readonly string[] mapDirs;
    readonly string mapsFile;
    Dictionary<string, string> games = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    string defaultMap = "Joy8Way";
    public int Count { get; private set; }
    public string Current { get; private set; }     // the map every stick holds now (null = unknown, e.g. after start)
    public string LastError { get; private set; }
    readonly Action<string> log;

    public Sticks(string manifestDir, string ledBlinkyDir, Action<string> log)
    {
        this.log = log;
        mapsFile = Path.Combine(manifestDir, "stick-maps.json");
        var d = new List<string> { Path.Combine(manifestDir, "ultrastik") };
        if (ledBlinkyDir != null) d.Add(Path.Combine(ledBlinkyDir, @"jdr\UltraStik"));
        mapDirs = d.ToArray();
        Reload();
        try { Count = UltraStik_Initialize(); }
        catch (Exception e) { LastError = "UltraStik32.dll: " + e.Message; Count = 0; }
        log("sticks: " + Count + " UltraStik(s)" + (LastError != null ? " - " + LastError : "") + ", " + games.Count + " games with their own map, default " + defaultMap);
    }

    // stick-maps.json (generated) then stick-maps-cabinet.json (this cabinet's own picks from the Sticks window; the
    // generator never touches it, so a pick survives every Rebuild Menus)
    string LocalFile { get { return Path.Combine(Path.GetDirectoryName(mapsFile), "stick-maps-cabinet.json"); } }
    Dictionary<string, string> local = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

    public void Reload()
    {
        games = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        local = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var file in new[] { mapsFile, LocalFile })
        {
            if (!File.Exists(file)) continue;
            try
            {
                var ser = new System.Web.Script.Serialization.JavaScriptSerializer { MaxJsonLength = 16 * 1024 * 1024 };
                var root = ser.Deserialize<Dictionary<string, object>>(File.ReadAllText(file));
                if (file == mapsFile && root.ContainsKey("default")) defaultMap = Convert.ToString(root["default"]);
                var g = root.ContainsKey("games") ? root["games"] as Dictionary<string, object> : null;
                if (g != null) foreach (var kv in g) { games[kv.Key] = Convert.ToString(kv.Value); if (file != mapsFile) local[kv.Key] = Convert.ToString(kv.Value); }
            }
            catch (Exception e) { LastError = Path.GetFileName(file) + ": " + e.Message; }
        }
    }

    public bool IsCabinetPick(string rom) { return rom != null && local.ContainsKey(rom); }

    // the Sticks window: keep a map for one game on this cabinet (null = back to the generated one)
    public void SetGameMap(string rom, string map)
    {
        if (string.IsNullOrEmpty(rom)) return;
        if (map == null) local.Remove(rom); else local[rom] = map;
        var sb = new System.Text.StringBuilder("{\"games\":{");
        bool first = true;
        foreach (var kv in local) { sb.Append(first ? "" : ",").Append('"').Append(kv.Key.Replace("\"", "")).Append("\":\"").Append(kv.Value.Replace("\"", "")).Append('"'); first = false; }
        sb.Append("}}\n");
        File.WriteAllText(LocalFile, sb.ToString(), new System.Text.UTF8Encoding(false));
        Reload();
    }

    // a map's 9x9 grid (row 1 = stick pushed fully up), for drawing; null when the file is missing
    public string[][] Grid(string map)
    {
        string file = Find(map); if (file == null) return null;
        var g = new string[9][];
        foreach (var line in File.ReadAllLines(file))
        {
            if (!line.StartsWith("MapRow", StringComparison.OrdinalIgnoreCase)) continue;
            int eq = line.IndexOf('='), n;
            if (eq < 0 || !int.TryParse(line.Substring(6, eq - 6), out n) || n < 1 || n > 9) continue;
            var cells = line.Substring(eq + 1).Split(',');
            if (cells.Length == 9) g[n - 1] = cells;
        }
        foreach (var r in g) if (r == null) return null;
        return g;
    }

    public string MapFor(string rom)
    {
        string m; return rom != null && games.TryGetValue(rom, out m) ? m : defaultMap;
    }

    string Find(string map)
    {
        if (map.IndexOf('\\') >= 0 || map.IndexOf('/') >= 0) return File.Exists(map) ? map : null;
        string name = map.EndsWith(".um", StringComparison.OrdinalIgnoreCase) ? map : map + ".um";
        foreach (var d in mapDirs) { string p = Path.Combine(d, name); if (File.Exists(p)) return p; }
        return null;
    }

    // a map name ("Joy4Way"), a .um path, or null = this game's map
    public string Load(string map, string rom, bool force)
    {
        if (Count == 0) return "no UltraStik found";
        if (string.IsNullOrEmpty(map)) map = MapFor(rom);
        string file = Find(map);
        if (file == null) return "no map file '" + map + "' (looked in " + string.Join("; ", mapDirs) + ")";
        string key = Path.GetFileNameWithoutExtension(file);
        if (!force && string.Equals(key, Current, StringComparison.OrdinalIgnoreCase)) return key + " (already loaded)";
        int ok = 0;
        var sw = System.Diagnostics.Stopwatch.StartNew();
        for (int i = 0; i < Count; i++) if (UltraStik_LoadMapFile(i, file) != 0) ok++;
        Current = ok == Count ? key : null;
        string r = key + " -> " + ok + " of " + Count + " stick(s), " + sw.ElapsedMilliseconds + " ms" + (rom != null ? " for " + rom : "");
        log("sticks: " + r);
        return r;
    }

    public List<string> Maps()
    {
        var l = new List<string>();
        foreach (var d in mapDirs) if (Directory.Exists(d)) foreach (var f in Directory.GetFiles(d, "*.um")) { string n = Path.GetFileNameWithoutExtension(f); if (!l.Contains(n)) l.Add(n); }
        l.Sort(StringComparer.OrdinalIgnoreCase);
        return l;
    }

    public void Close() { try { if (Count > 0) UltraStik_Shutdown(); } catch { } }
}
