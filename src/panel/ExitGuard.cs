// AmPanel - the universal "end game" key (James 2026-11-25: Esc ends any game; "many emulators don't have a quick way
// to end them... replace these scripts I use to detect and close their running sessions"; "C64 and Amiga want to
// sometimes expose keyboard keys for the game").
//
// Only armed between game start and game stop. The exit key (Esc, AmPanel.json "ExitKey") always reaches the game too.
// What happens next comes from exit-rules.json (next to AmPanel; a cabinet's <manifest>\exit-rules.json wins), matched
// on the foreground game's process name or window class - the first rules are James's CabinetLauncher AutoHotkey list:
//   close: self  - the emulator ends itself on Esc (MAME, RetroArch): just wait 'grace' ms, then make sure
//          altf4 - Alt+F4 to its window (RPCS3, PCSX2, Dolphin, Qt emulators)
//          close - WM_CLOSE to its windows (Cemu, WinUAE, xemu, ePSXe)
//          kill  - end it at once (TeknoParrot loaders)
//   hold:  ms the key must be HELD before anything happens - computers (C64 VICE, Amiga) use Esc in their games, so a
//          tap stays a key press for the game and only a long hold ends it
// Unlisted: wait 1500 ms, then WM_CLOSE. In every case whatever is still running 3 s later is ended - the whole process
// chain up to what the frontend started (emulatorLauncher, TeknoParrotUi, cmd .bat ...). Never the frontend, AmPanel,
// Explorer or system processes.
// C# 5.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Management;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

class ExitGuard
{
    delegate IntPtr HookProc(int code, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, HookProc fn, IntPtr mod, uint thread);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int code, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc fn, IntPtr l);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, int flags, IntPtr extra);
    const int WH_KEYBOARD_LL = 13, WM_KEYDOWN = 0x0100, WM_SYSKEYDOWN = 0x0104, WM_CLOSE = 0x0010, KEYUP = 2;

    class Rule { public string Exe, Class, Emulator, Close = "close"; public int Grace = 1500, Hold; }
    // the launcher the frontend started the game with (LEDBlinky's emulator argument: "am_rb_c64", "amiga", "mame"):
    // a C64 or Amiga game inside RetroArch is just "retroarch" by exe, so its hold comes from here
    public volatile string Emulator;

    static readonly HashSet<string> Never = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
        "retrofe", "AmPanel", "explorer", "LEDBlinky", "dwm", "csrss", "winlogon", "svchost", "System", "Idle",
        "ArcadeMaster", "powershell", "pwsh", "conhost", "RustDesk", "Code", "claude" };
    readonly HookProc proc;
    readonly IntPtr hook;
    readonly int exitVk;
    readonly int defaultGrace;
    readonly string frontend;
    readonly Action<string> log;
    readonly List<Rule> rules = new List<Rule>();
    public volatile bool GameRunning;
    int busy;

    public ExitGuard(int exitVk, int graceMs, string frontendProcess, string[] ruleFiles, Action<string> log)
    {
        this.exitVk = exitVk; defaultGrace = graceMs; frontend = frontendProcess; this.log = log;
        foreach (var f in ruleFiles) LoadRules(f);
        proc = Hook;
        using (var p = Process.GetCurrentProcess()) using (var m = p.MainModule) hook = SetWindowsHookEx(WH_KEYBOARD_LL, proc, GetModuleHandle(m.ModuleName), 0);
        log("exit guard: " + (hook != IntPtr.Zero ? "on" : "NOT installed") + " (key vk 0x" + exitVk.ToString("X2") + ", " + rules.Count + " emulator rules)");
    }

    void LoadRules(string file)
    {
        if (file == null || !File.Exists(file)) return;
        try
        {
            var root = new System.Web.Script.Serialization.JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(file));
            var list = root.ContainsKey("rules") ? root["rules"] as System.Collections.ArrayList : null;
            if (list == null) return;
            foreach (Dictionary<string, object> r in list)
                rules.Add(new Rule {
                    Exe = r.ContainsKey("exe") ? Convert.ToString(r["exe"]) : null, Class = r.ContainsKey("class") ? Convert.ToString(r["class"]) : null,
                    Emulator = r.ContainsKey("emulator") ? Convert.ToString(r["emulator"]) : null,
                    Close = r.ContainsKey("close") ? Convert.ToString(r["close"]).ToLowerInvariant() : "close",
                    Grace = r.ContainsKey("grace") ? Convert.ToInt32(r["grace"]) : defaultGrace, Hold = r.ContainsKey("hold") ? Convert.ToInt32(r["hold"]) : 0 });
        }
        catch (Exception e) { log("exit guard: " + Path.GetFileName(file) + ": " + e.Message); }
    }

    Rule Match(string exe, string cls)
    {
        // the launcher's rule first (a system: c64, amiga), then the emulator's (exe / window class)
        Rule sys = null, emu = null;
        string em = Emulator;
        foreach (var r in rules)
        {
            if (sys == null && r.Emulator != null && em != null && r.Emulator.Equals(em, StringComparison.OrdinalIgnoreCase)) sys = r;
            if (emu == null && ((r.Exe != null && r.Exe.Equals(exe, StringComparison.OrdinalIgnoreCase)) || (r.Class != null && r.Class.Equals(cls, StringComparison.Ordinal)))) emu = r;
        }
        if (sys == null) return emu ?? new Rule { Grace = defaultGrace };
        if (emu == null) return sys;
        // both: how to close comes from the emulator, the hold from the system
        return new Rule { Close = emu.Close, Grace = emu.Grace, Hold = Math.Max(sys.Hold, emu.Hold) };
    }

    IntPtr Hook(int code, IntPtr w, IntPtr l)
    {
        if (code >= 0 && GameRunning && ((int)w == WM_KEYDOWN || (int)w == WM_SYSKEYDOWN) && Marshal.ReadInt32(l) == exitVk && Interlocked.CompareExchange(ref busy, 1, 0) == 0)
        {
            IntPtr fg = GetForegroundWindow();
            ThreadPool.QueueUserWorkItem(delegate { try { EndGame(fg, true); } catch (Exception e) { log("exit guard: " + e.Message); } finally { Interlocked.Exchange(ref busy, 0); } });
        }
        return CallNextHookEx(hook, code, w, l);   // the key always reaches the game too
    }

    // the exit key, now (pipe "endgame", Stream Deck, tests): no hold, no key needed
    public string EndNow() { return EndGame(GetForegroundWindow(), false); }

    string EndGame(IntPtr fg, bool fromKey)
    {
        uint upid; GetWindowThreadProcessId(fg, out upid); int fgPid = (int)upid;
        string exe = Name(fgPid);
        var sb = new StringBuilder(256); GetClassName(fg, sb, sb.Capacity); string cls = sb.ToString();
        // Not the game in front, but a game IS running: an emulator's console (TeknoParrot's loader opens one in Windows
        // Terminal), the menu itself, or a helper took the front, and the exit key went nowhere. RACE2, 2026-11-28: SWDC's
        // loader console sat in front for 14 minutes and Esc did nothing; RACE1: a windowed Daytona behind the menu
        // "won't quit". The game the frontend started is ended then, the same way as if it were in front.
        bool swapped = false;
        if (exe == null || Never.Contains(exe) || Consoles.Contains(exe))
        {
            int g = FrontendGame();
            if (g == 0) return "not a game in front (" + exe + ")";
            log("exit guard: " + (exe ?? "nothing") + " is in front, not the game - ending the game the frontend started (" + Name(g) + ")");
            fgPid = g; exe = Name(g); cls = ""; swapped = true;
            if (exe == null) return "not a game in front";
        }
        var rule = Match(exe, cls);
        if (swapped && rule.Close == "altf4") rule = new Rule { Close = "close", Grace = rule.Grace, Hold = rule.Hold };   // Alt+F4 would go to the window in front, which is not the game
        if (fromKey && rule.Hold > 0)
        {
            // a computer (C64, Amiga): Esc is a key in its games - only a long hold ends it
            var sw = Stopwatch.StartNew();
            while (sw.ElapsedMilliseconds < rule.Hold) { if ((GetAsyncKeyState(exitVk) & 0x8000) == 0) return "tap (kept for the game)"; Thread.Sleep(40); }
        }
        if (rule.Close == "self" || rule.Grace > 0) { Thread.Sleep(rule.Grace); if (Name(fgPid) == null) { log("exit guard: " + exe + " closed itself"); return exe + " closed itself"; } }

        var parents = ParentMap();
        int root = fgPid, steps = 0, p;
        while (parents.TryGetValue(root, out p) && steps++ < 12)
        {
            string pn = Name(p);
            if (pn == null || pn.Equals(frontend, StringComparison.OrdinalIgnoreCase) || Never.Contains(pn)) break;   // root = the frontend's child
            root = p;
        }
        var tree = Tree(root, parents);
        int asked = 0;
        if (rule.Close == "altf4")
        {
            SetForegroundWindow(fg); Thread.Sleep(50);
            keybd_event(0x12, 0, 0, IntPtr.Zero); keybd_event(0x73, 0, 0, IntPtr.Zero); keybd_event(0x73, 0, KEYUP, IntPtr.Zero); keybd_event(0x12, 0, KEYUP, IntPtr.Zero);
            asked = 1;
        }
        else if (rule.Close != "kill")
        {
            EnumWindows(delegate (IntPtr h, IntPtr x) {
                uint wp; GetWindowThreadProcessId(h, out wp);
                if (tree.Contains((int)wp) && IsWindowVisible(h)) { PostMessage(h, WM_CLOSE, IntPtr.Zero, IntPtr.Zero); asked++; }
                return true;
            }, IntPtr.Zero);
        }
        if (rule.Close != "kill") for (int i = 0; i < 30 && AnyAlive(tree); i++) Thread.Sleep(100);
        int killed = 0;
        foreach (var id in tree) { try { using (var pr = Process.GetProcessById(id)) { if (!pr.HasExited && !Never.Contains(pr.ProcessName)) { pr.Kill(); killed++; } } } catch { } }
        string r = "ended " + exe + " by " + rule.Close + (rule.Hold > 0 ? " (held " + rule.Hold + " ms)" : "") + ": " + tree.Count + " process(es), " + asked + " asked, " + killed + " ended after 3 s";
        log("exit guard: " + r);
        return r;
    }

    // windows that are never the game itself but can sit in front of one
    static readonly HashSet<string> Consoles = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "WindowsTerminal", "OpenConsole", "cmd" };

    // the program the frontend started for the running game: its first child that is not one of our own helpers
    int FrontendGame()
    {
        var parents = ParentMap();
        var fe = new HashSet<int>();
        foreach (var p in Process.GetProcessesByName(frontend)) { fe.Add(p.Id); p.Dispose(); }
        foreach (var kv in parents)
        {
            if (!fe.Contains(kv.Value)) continue;
            string n = Name(kv.Key);
            if (n != null && !Never.Contains(n) && !Consoles.Contains(n)) return kv.Key;
        }
        return 0;
    }
    static string Name(int pid) { try { using (var p = Process.GetProcessById(pid)) return p.HasExited ? null : p.ProcessName; } catch { return null; } }

    static Dictionary<int, int> ParentMap()
    {
        var d = new Dictionary<int, int>();
        using (var s = new ManagementObjectSearcher("SELECT ProcessId, ParentProcessId FROM Win32_Process"))
            foreach (ManagementObject o in s.Get()) d[Convert.ToInt32(o["ProcessId"])] = Convert.ToInt32(o["ParentProcessId"]);
        return d;
    }

    static HashSet<int> Tree(int root, Dictionary<int, int> parents)
    {
        var t = new HashSet<int> { root };
        bool grew = true;
        while (grew) { grew = false; foreach (var kv in parents) if (!t.Contains(kv.Key) && t.Contains(kv.Value) && kv.Key != kv.Value) { t.Add(kv.Key); grew = true; } }
        return t;
    }

    static bool AnyAlive(HashSet<int> pids) { foreach (var id in pids) if (Name(id) != null) return true; return false; }

    public void Stop() { if (hook != IntPtr.Zero) UnhookWindowsHookEx(hook); }
}
