// AmPanel - Game Options: TAB on the selected game opens a menu for THAT game (James, 2026-11-26: "when selecting a game
// pressing a certain key will bring up menu to pick different mame version etc or even allow mapping buttons for that
// game"; TAB is the menu key on the 2P stand-up). docs/21: a module that moves into the frontend later; until then AmPanel
// shows it over the frontend with the same screen as the controller question.
//
//   EMULATOR      the launchers that can run this game (same emulator family and arguments as the collection's own
//                 launcher, program present), each with its real version (mame.exe -version, cached). The choice is
//                 RetroFE's own per-game launcher file: collections\<collection>\launchers\<item>.conf.
//   MAP BUTTONS   MAME: its per-game input menu (in the game, TAB > Input (this Machine) - MAME saves cfg\<game>.cfg);
//                 TeknoParrot: its window (the game's Controller Setup); Dolphin / Cemu: their controller settings.
//   BACK TO DEFAULT  the launcher file as it was before Game Options changed it (CORE's own choices, e.g. mrdo, come back).
//
// Only while the frontend is in front and no game runs; the key reaches nothing else then (RetroFE has no Tab binding).
// AmPanel.json "GameOptionsKey": "TAB" (default) | a Keys name | "none". Every change: <manifest>\game-options.json.
// C# 5.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

class GameOptions
{
    delegate IntPtr HookProc(int code, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, HookProc fn, IntPtr mod, uint thread);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int code, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    const int WH_KEYBOARD_LL = 13, WM_KEYDOWN = 0x0100;

    readonly string root, manifestDir, stateFile, versionFile;
    readonly Action<string> log;
    readonly int vk;
    readonly HookProc proc;
    IntPtr hook;
    volatile bool open;
    public volatile bool GameRunning;
    public Func<string> Selected;          // the highlighted item (AmPanel's state)
    public Func<string> SelectedSystem;    // its collection as the frontend sends it
    public Control Ui;                     // shows the menu on AmPanel's UI thread
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer();

    public GameOptions(string retroFERoot, string manifestDir, string key, Action<string> log)
    {
        root = retroFERoot; this.manifestDir = manifestDir; this.log = log ?? delegate { };
        stateFile = Path.Combine(manifestDir, "game-options.json");
        versionFile = Path.Combine(manifestDir, "emulator-versions.json");
        Keys k; vk = Enum.TryParse(key ?? "Tab", true, out k) ? (int)k : (int)Keys.Tab;
        proc = Hook;
        using (var p = Process.GetCurrentProcess()) using (var m = p.MainModule) hook = SetWindowsHookEx(WH_KEYBOARD_LL, proc, GetModuleHandle(m.ModuleName), 0);
        this.log("game options: " + (hook != IntPtr.Zero ? "on (key " + (Keys)vk + ")" : "keyboard hook failed"));
    }
    public void Close() { if (hook != IntPtr.Zero) UnhookWindowsHookEx(hook); hook = IntPtr.Zero; }

    IntPtr Hook(int code, IntPtr w, IntPtr l)
    {
        if (code >= 0 && (int)w == WM_KEYDOWN && Marshal.ReadInt32(l) == vk && !open && !GameRunning && FrontendInFront())
        {
            open = true;
            string item = Selected != null ? Selected() : null, sys = SelectedSystem != null ? SelectedSystem() : null;
            if (Ui != null && item != null) { Ui.BeginInvoke((MethodInvoker)delegate { try { Show(item, sys); } catch (Exception e) { log("game options: " + e.Message); } finally { open = false; } }); return (IntPtr)1; }
            open = false;
        }
        return CallNextHookEx(hook, code, w, l);
    }

    static bool FrontendInFront()
    {
        uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        try { using (var p = Process.GetProcessById((int)pid)) return p.ProcessName.Equals("retrofe", StringComparison.OrdinalIgnoreCase); } catch { return false; }
    }

    // ---------------------------------------------------------------- the menu
    public void Show(string item, string system)
    {
        string coll = CollectionDir(system, item);
        if (coll == null) { log("game options: no collection for '" + system + "' (" + item + ")"); return; }
        string collName = Path.GetFileName(coll);
        string baseL = BaseLauncher(coll, collName), current = Override(coll, item) ?? baseL;
        var alts = Alternatives(baseL);
        var theme = ChooserTheme.Load(root, collName, item);
        string title = Speech.Title(item);
        while (true)
        {
            var menu = new List<Dictionary<string, object>>();
            if (alts.Count >= 2) menu.Add(Tile("emulator", "EMULATOR: " + Label(current), "joystick"));
            string mapWhat = MapKind(current);
            if (mapWhat != null) menu.Add(Tile("map", "MAP BUTTONS", "gamepad"));
            if (Changed(collName, item)) menu.Add(Tile("reset", "BACK TO DEFAULT", "mouse"));
            menu.Add(Tile("close", "CLOSE", "analog"));
            string pick = Ask(title, "GAME OPTIONS", menu, null, theme);
            if (pick == null || pick == "close") return;
            if (pick == "emulator")
            {
                var tiles = alts.Select(a => Tile(a, Label(a), "joystick")).ToList();
                string e = Ask(title, "WHICH EMULATOR FOR THIS GAME?", tiles, current, theme);
                if (e != null && e != current) { SetLauncher(coll, collName, item, e == baseL && !HadOriginal(collName, item) ? null : e); current = e; log("game options: " + collName + "/" + item + " -> " + e); }
            }
            else if (pick == "reset") { current = Reset(coll, collName, item) ?? baseL; log("game options: " + collName + "/" + item + " back to default (" + current + ")"); }
            else if (pick == "map") { MapButtons(mapWhat, current, title, theme); return; }
        }
    }

    static Dictionary<string, object> Tile(string id, string label, string icon) { return new Dictionary<string, object> { { "id", id }, { "label", label }, { "icon", icon } }; }

    string Ask(string title, string question, List<Dictionary<string, object>> tiles, string now, ChooserTheme theme)
    {
        using (var f = new ControllerChooser(title, tiles, now, 30, theme) { Menu = true, Question = question, PickWord = "OK" })
        {
            f.ShowDialog();
            return f.Picked;
        }
    }

    // ---------------------------------------------------------------- launchers
    // The frontend names the item's LAUNCHER ("arcade pc rh" for Friction in Arcade PC), which is the collection's name
    // only for some (MAME). The cabinet's game list (games.json ids "<collection>:<item>") knows the real collection.
    Dictionary<string, List<string>> itemColls;
    string CollectionDir(string system, string item)
    {
        string d = Path.Combine(root, "collections");
        if (!Directory.Exists(d)) return null;
        var dirs = Directory.GetDirectories(d);
        if (itemColls == null)
        {
            itemColls = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
            try
            {
                string gj = Path.Combine(manifestDir, "games.json");
                if (File.Exists(gj))
                    foreach (Match m in Regex.Matches(File.ReadAllText(gj), "\"id\"\\s*:\\s*\"([^\"\\\\:]+):((?:[^\"\\\\]|\\\\.)+)\""))
                    {
                        string it = Regex.Unescape(m.Groups[2].Value);
                        List<string> l; if (!itemColls.TryGetValue(it, out l)) itemColls[it] = l = new List<string>();
                        l.Add(m.Groups[1].Value);
                    }
            }
            catch (Exception e) { log("game options: games.json not read - " + e.Message); }
        }
        var cands = new List<string>();
        List<string> named; if (item != null && itemColls.TryGetValue(item, out named)) cands.AddRange(named);
        if (!string.IsNullOrEmpty(system)) cands.Add(system);
        // the collection whose name or launcher is what the frontend sent wins; else the game list's first
        string first = null;
        foreach (var c in cands)
        {
            string dir = dirs.FirstOrDefault(x => Path.GetFileName(x).Equals(c, StringComparison.OrdinalIgnoreCase));
            if (dir == null) continue;
            if (first == null) first = dir;
            if (system != null && (c.Equals(system, StringComparison.OrdinalIgnoreCase) || BaseLauncher(dir, Path.GetFileName(dir)).Equals(system, StringComparison.OrdinalIgnoreCase))) return dir;
        }
        return first;
    }

    static string Conf(string file, string key)
    {
        if (!File.Exists(file)) return null;
        string v = null;
        foreach (var raw in File.ReadAllLines(file))
        {
            var m = Regex.Match(raw, @"^\s*" + Regex.Escape(key) + @"\s*=\s*(.*?)\s*$", RegexOptions.IgnoreCase);
            if (m.Success) v = m.Groups[1].Value;
        }
        return v;
    }

    string BaseLauncher(string coll, string collName)
    {
        string l = Conf(Path.Combine(coll, "settings.conf"), "launcher");
        if (string.IsNullOrEmpty(l) || l.IndexOf("%ITEM_COLLECTION_NAME%", StringComparison.OrdinalIgnoreCase) >= 0) l = collName;
        return l;
    }

    static string Override(string coll, string item)
    {
        string f = Path.Combine(coll, "launchers", item + ".conf");
        return File.Exists(f) ? File.ReadAllText(f).Trim() : null;
    }

    string LauncherFile(string name) { return Path.Combine(root, "launchers.windows", name + ".conf"); }

    string Exe(string launcher)
    {
        string e = Conf(LauncherFile(launcher), "executable");
        if (string.IsNullOrEmpty(e)) return null;
        e = e.Trim('"');
        return Path.IsPathRooted(e) ? e : Path.Combine(root, e);
    }

    // the same emulator family ("mame" from mame.exe / mame64.exe / mameNEW64.exe) with the same arguments, program present
    static string Family(string exe) { if (exe == null) return null; var m = Regex.Match(Path.GetFileNameWithoutExtension(exe).ToLowerInvariant(), "^[a-z]+"); return m.Success ? m.Value.Replace("new", "") : null; }

    List<string> Alternatives(string baseL)
    {
        var list = new List<string>();
        string bx = Exe(baseL), fam = Family(bx), args = Conf(LauncherFile(baseL), "arguments");
        if (bx == null || !File.Exists(bx)) { list.Add(baseL); return list; }
        list.Add(baseL);
        foreach (var f in Directory.GetFiles(Path.Combine(root, "launchers.windows"), "*.conf"))
        {
            string n = Path.GetFileNameWithoutExtension(f);
            if (n.Equals(baseL, StringComparison.OrdinalIgnoreCase) || n.StartsWith("AM_", StringComparison.OrdinalIgnoreCase)) continue;
            string x = Exe(n);
            if (x == null || !File.Exists(x) || Family(x) != fam) continue;
            if (!string.Equals(Conf(f, "arguments"), args, StringComparison.OrdinalIgnoreCase)) continue;
            list.Add(n);
        }
        return list.Take(5).ToList();   // the screen fits five tiles
    }

    string Label(string launcher)
    {
        string v = Version(Exe(launcher));
        return v != null ? Family(Exe(launcher)).ToUpperInvariant() + " " + v : launcher.ToUpperInvariant();
    }

    // "mame.exe -version" -> "0.196 (mame0196)" -> "0.196"; cached by path + date, so the menu opens at once
    string Version(string exe)
    {
        if (exe == null || !File.Exists(exe)) return null;
        var cache = ReadJson(versionFile);
        string key = exe.ToLowerInvariant() + "|" + File.GetLastWriteTimeUtc(exe).Ticks;
        object o; if (cache.TryGetValue(key, out o)) return Convert.ToString(o);
        string v = null;
        if (Family(exe) == "mame")
            try
            {
                var psi = new ProcessStartInfo(exe, "-version") { UseShellExecute = false, RedirectStandardOutput = true, CreateNoWindow = true, WorkingDirectory = Path.GetDirectoryName(exe) };
                using (var p = Process.Start(psi)) { string s = p.StandardOutput.ReadToEnd(); p.WaitForExit(4000); var m = Regex.Match(s, @"\d+\.\d+"); if (m.Success) v = m.Value; }
            }
            catch { }
        cache[key] = v; WriteJson(versionFile, cache);
        return v;
    }

    // ---------------------------------------------------------------- per-game choice, remembered so it can be undone
    bool HadOriginal(string collName, string item) { object o; var s = ReadJson(stateFile); return s.TryGetValue(collName + "/" + item, out o) && o is Dictionary<string, object> && ((Dictionary<string, object>)o)["original"] != null; }
    bool Changed(string collName, string item) { return ReadJson(stateFile).ContainsKey(collName + "/" + item); }

    void SetLauncher(string coll, string collName, string item, string launcher)
    {
        var s = ReadJson(stateFile); string k = collName + "/" + item;
        if (!s.ContainsKey(k)) s[k] = new Dictionary<string, object> { { "original", Override(coll, item) } };   // what was there first
        ((Dictionary<string, object>)s[k])["chosen"] = launcher;
        ((Dictionary<string, object>)s[k])["at"] = DateTime.Now.ToString("s");
        WriteJson(stateFile, s);
        string dir = Path.Combine(coll, "launchers"), f = Path.Combine(dir, item + ".conf");
        if (launcher == null) { if (File.Exists(f)) File.Delete(f); return; }
        Directory.CreateDirectory(dir);
        File.WriteAllText(f, launcher);
    }

    string Reset(string coll, string collName, string item)
    {
        var s = ReadJson(stateFile); string k = collName + "/" + item; object o;
        string orig = s.TryGetValue(k, out o) && o is Dictionary<string, object> ? Convert.ToString(((Dictionary<string, object>)o)["original"]) : null;
        if (string.IsNullOrEmpty(orig)) orig = null;
        string f = Path.Combine(coll, "launchers", item + ".conf");
        if (orig == null) { if (File.Exists(f)) File.Delete(f); }
        else { Directory.CreateDirectory(Path.GetDirectoryName(f)); File.WriteAllText(f, orig); }
        s.Remove(k); WriteJson(stateFile, s);
        return orig;
    }

    // ---------------------------------------------------------------- button mapping, in each emulator's own screen
    string MapKind(string launcher)
    {
        string x = Exe(launcher); if (x == null) return null;
        string n = Path.GetFileName(x).ToLowerInvariant();
        if (Family(x) == "mame") return "mame";
        if (n.StartsWith("teknoparrot")) return "teknoparrot";
        if (n.StartsWith("dolphin")) return "dolphin";
        if (n.StartsWith("cemu")) return "cemu";
        return null;
    }

    void MapButtons(string kind, string launcher, string title, ChooserTheme theme)
    {
        if (kind == "mame")
        {
            // MAME keeps a game's own buttons in cfg\<game>.cfg, set from its menu while the game runs
            Ask(title, "START THE GAME, PRESS TAB: INPUT (THIS MACHINE)", new List<Dictionary<string, object>> { Tile("ok", "GOT IT", "joystick") }, null, theme);
            return;
        }
        string exe = Exe(launcher);
        try
        {
            log("game options: map buttons -> " + exe);
            var p = Process.Start(new ProcessStartInfo(exe) { WorkingDirectory = Path.GetDirectoryName(exe), UseShellExecute = true });
            // in front of the frontend (RetroFE is full screen): wait for its window, then show it
            if (p != null) new Thread(() => { for (int i = 0; i < 40; i++) { Thread.Sleep(250); try { p.Refresh(); if (p.MainWindowHandle != IntPtr.Zero) { ShowWindow(p.MainWindowHandle, 9); SetForegroundWindow(p.MainWindowHandle); return; } } catch { return; } } }) { IsBackground = true }.Start();
        }
        catch (Exception e) { log("game options: could not open " + exe + " - " + e.Message); }
    }

    // ---------------------------------------------------------------- json
    static Dictionary<string, object> ReadJson(string f)
    {
        try { if (File.Exists(f)) return Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(f)) ?? new Dictionary<string, object>(); } catch { }
        return new Dictionary<string, object>();
    }
    static void WriteJson(string f, Dictionary<string, object> d) { try { File.WriteAllText(f, Json.Serialize(d)); } catch { } }
}
