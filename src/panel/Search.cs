// AmPanel - touch-screen game search (James 2026-11-26: "add a search and then click into and screen type lookup names
// for games").
//
//   GameLink      talks to RetroFE's cabinet link (patch 0017, settings.conf linkEvents = yes) on THIS PC only: listens on
//                 127.0.0.1:47801 for "hello <menu> ..." / "select ..." / "miss <item>", sends "goto <item>" to :47802
//   SearchIndex   <manifest>\search-index.json (tools/New-SearchIndex.py, from meta.db): title, item, collection, year
//   SearchButton  a small "SEARCH" pill on the touch screen while the menus are up (never takes the keyboard focus)
//   SearchScreen  the touch page: what you typed, up to 8 matches from the open menu (with their logos), an on-screen
//                 keyboard. Tap a match and the frontend jumps to it. Neither window takes the focus from RetroFE.
// C# 5.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Windows.Forms;

class GameLink
{
    public const int EventsPort = 47801, CommandsPort = 47802;
    // The cabinet link helper (tools\AmLink.ps1) needs the events port too, and only one program can have it. So AmPanel
    // also listens on RelayPort: the helper passes every event on to it, and "release" there makes AmPanel let go of
    // EventsPort (the helper asks when it starts after AmPanel). With no helper AmPanel keeps EventsPort as before.
    public const int RelayPort = 47803;
    public string Menu { get; private set; }          // the menu (collection) RetroFE has open
    public string Selected { get; private set; }
    public string SelectedCollection { get; private set; }   // the selected game's own collection (a merged list's items keep theirs)
    public string LastMiss { get; private set; }
    public DateTime LastHello { get; private set; }
    public bool Running { get; private set; }
    public event Action<string> Request;   // "search", ... from the frontend's theme buttons
    UdpClient rx, rxRelay;
    volatile bool released;
    readonly Action<string> log;

    public GameLink(Action<string> log) { this.log = log; }

    public bool Start()
    {
        Running = true; bool any = false;
        try { rxRelay = new UdpClient(new IPEndPoint(IPAddress.Loopback, RelayPort)); any = true; var c = rxRelay; new Thread(() => Loop(c, true)) { IsBackground = true, Name = "game link relay" }.Start(); }
        catch (Exception e) { log("search: relay port " + RelayPort + " is taken (" + e.Message + ")"); }
        try { rx = new UdpClient(new IPEndPoint(IPAddress.Loopback, EventsPort)); any = true; var c = rx; new Thread(() => Loop(c, false)) { IsBackground = true, Name = "game link" }.Start(); }
        catch (Exception e) { log("search: cabinet link port " + EventsPort + " is taken (" + e.Message + ") - events come through the cabinet link helper (port " + RelayPort + ")"); }
        if (!any) { Running = false; log("search: no port to hear the frontend on - search works, jumping does not"); }
        return any;
    }

    void Loop(UdpClient sock, bool relay)
    {
        var from = new IPEndPoint(IPAddress.Any, 0);
        while (Running)
        {
            try
            {
                string line = Encoding.UTF8.GetString(sock.Receive(ref from));
                if (relay && line == "release") { if (!released) { released = true; log("search: the cabinet link helper takes port " + EventsPort + "; events now come through it"); try { if (rx != null) rx.Close(); } catch { } } continue; }
                var p = line.Split('\t');
                if (p.Length >= 2 && p[0] == "hello") { Menu = p[1]; LastHello = DateTime.Now; }
                else if (p.Length >= 5 && p[0] == "select") { Menu = p[2]; Selected = p[4]; SelectedCollection = p.Length >= 6 && p[5] != "" ? p[5] : p[2]; }
                else if (p.Length >= 2 && p[0] == "miss") LastMiss = p[1];
                // a theme button asked AmPanel for something (touchAction="am:search" -> "request\tsearch", docs/22)
                else if (p.Length >= 2 && p[0] == "request" && Request != null) Request(p[1]);
            }
            catch { if (!Running || (!relay && released)) return; Thread.Sleep(200); }
        }
    }

    public bool Alive { get { return Running && (DateTime.Now - LastHello).TotalSeconds < 5; } }

    // open a list (patch 0028 "show <collection>"); the search then sends goto until the game is selected
    public void Show(string collection)
    {
        try { using (var tx = new UdpClient()) { var b = Encoding.UTF8.GetBytes("show\t" + collection); tx.Send(b, b.Length, new IPEndPoint(IPAddress.Loopback, CommandsPort)); } }
        catch (Exception e) { log("search: show failed: " + e.Message); }
    }

    public void Goto(string item)
    {
        LastMiss = null;
        try { using (var tx = new UdpClient()) { var b = Encoding.UTF8.GetBytes("goto\t" + item); tx.Send(b, b.Length, new IPEndPoint(IPAddress.Loopback, CommandsPort)); } }
        catch (Exception e) { log("search: goto failed: " + e.Message); }
    }

    public void Stop() { Running = false; try { if (rx != null) rx.Close(); } catch { } try { if (rxRelay != null) rxRelay.Close(); } catch { } }
}

// RetroFE reads the panel only through its main window ("RetroFE 0"). A tap on the touch screen activated "RetroFE 1"
// (the marquee / touch screen window) and the keys went there: the panel looked dead (2026-11-26). The extra windows
// are made non-activating (taps still reach them) and the focus is handed back to the main window if it lands there.
static class FrontendFocus
{
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] static extern IntPtr FindWindow(string cls, string title);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool AttachThreadInput(int a, int b, bool attach);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern int GetCurrentThreadId();
    const int GWL_EXSTYLE = -20, WS_EX_NOACTIVATE = 0x08000000;

    // the frontend's main window gets the keyboard back (after the keyboard search closes)
    public static void FocusMain()
    {
        IntPtr main = FindWindow(null, "RetroFE 0");
        if (main == IntPtr.Zero) return;
        IntPtr fg = GetForegroundWindow();
        int ft = GetWindowThreadProcessId(fg, IntPtr.Zero), me = GetCurrentThreadId();
        AttachThreadInput(me, ft, true); SetForegroundWindow(main); AttachThreadInput(me, ft, false);
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    // the frontend in front when it starts (James 2026-11-27: "when it opens it doesn't set it in the front, vscode is
    // in front"): Windows refuses the foreground to a program started from the background, so on "frontend start" this
    // waits for the main window, taps Alt (which lets us hand the foreground over) and brings it up - a few tries
    public static void BringFrontendForward(Action<string> log)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < 30000)
        {
            System.Threading.Thread.Sleep(1000);
            IntPtr main = FindWindow(null, "RetroFE 0");
            if (main == IntPtr.Zero) continue;
            if (GetForegroundWindow() == main) { log("focus: the frontend is in front"); return; }
            keybd_event(0x12, 0, 0, UIntPtr.Zero); keybd_event(0x12, 0, 2, UIntPtr.Zero);
            ShowWindow(main, 9 /* SW_RESTORE */); BringWindowToTop(main);
            IntPtr fg = GetForegroundWindow();
            int ft = GetWindowThreadProcessId(fg, IntPtr.Zero), me = GetCurrentThreadId();
            AttachThreadInput(me, ft, true); SetForegroundWindow(main); AttachThreadInput(me, ft, false);
        }
        log("focus: could not bring the frontend to the front");
    }

    public static string Guard()
    {
        IntPtr main = FindWindow(null, "RetroFE 0");
        if (main == IntPtr.Zero) return null;
        string fixedWin = null;
        for (int n = 1; n < 4; n++)
        {
            IntPtr w = FindWindow(null, "RetroFE " + n);
            if (w == IntPtr.Zero) continue;
            // NOT non-activating: a WS_EX_NOACTIVATE window got no touch at all (the touch bar died, 2026-11-26) - the
            // window keeps its normal style (an earlier build's flag is taken off) and only the focus is handed back
            int ex = GetWindowLong(w, GWL_EXSTYLE);
            if ((ex & WS_EX_NOACTIVATE) != 0) { SetWindowLong(w, GWL_EXSTYLE, ex & ~WS_EX_NOACTIVATE); fixedWin = "RetroFE " + n; }
            if (GetForegroundWindow() == w)
            {
                int fg = GetWindowThreadProcessId(w, IntPtr.Zero), me = GetCurrentThreadId();
                AttachThreadInput(me, fg, true); SetForegroundWindow(main); AttachThreadInput(me, fg, false);
                return "focus handed back from RetroFE " + n + " to the main window";
            }
        }
        return fixedWin != null ? fixedWin + " takes touches again (non-activating flag removed)" : null;
    }
}

// "Recently Played" on the main menu: the last 30 games from any system (James 2026-11-26, navigating many systems).
// RetroFE's merged-collection form: collections\Recently Played\<collection>.sub lists that collection's games, so each
// keeps its own art and launcher. Written at every game start; the frontend reads it when it next loads its menus.
static class RecentlyPlayed
{
    public const string Name = "Recently Played";
    const int Keep = 30;

    public static void Record(string retroFERoot, string manifestDir, string collection, string item, Action<string> log)
    {
        if (string.IsNullOrEmpty(collection) || string.IsNullOrEmpty(item) || collection == Name) return;
        try
        {
            string file = Path.Combine(manifestDir, "recently-played.txt");
            var list = new List<string>();
            if (File.Exists(file)) foreach (var l in File.ReadAllLines(file)) if (l.Contains("\t")) list.Add(l);
            string key = collection + "\t" + item;
            list.RemoveAll(l => string.Equals(l, key, StringComparison.OrdinalIgnoreCase));
            list.Insert(0, key);
            if (list.Count > Keep) list.RemoveRange(Keep, list.Count - Keep);
            File.WriteAllLines(file, list.ToArray());

            string col = Path.Combine(retroFERoot, "collections", Name);
            Directory.CreateDirectory(col);
            foreach (var old in Directory.GetFiles(col, "*.sub")) File.Delete(old);
            var bySub = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
            foreach (var l in list) { var p = l.Split('\t'); List<string> g; if (!bySub.TryGetValue(p[0], out g)) { g = new List<string>(); bySub[p[0]] = g; } g.Add(p[1]); }
            foreach (var kv in bySub) File.WriteAllLines(Path.Combine(col, kv.Key + ".sub"), kv.Value.ToArray());
            string sc = Path.Combine(col, "settings.conf");
            if (!File.Exists(sc)) File.WriteAllText(sc, "# ArcadeMaster: the last 30 games from any system (AmPanel, Search.cs RecentlyPlayed)\r\nlist.includeMissingItems = false\r\nlist.menuSort = yes\r\n");
            // on the main menu once (the menu tools keep am-extra-menu.txt entries across rebuilds)
            foreach (var fn in new[] { "am-extra-menu.txt", "menu.txt" })
            {
                string m = Path.Combine(retroFERoot, "collections", "Main", fn);
                var lines = File.Exists(m) ? new List<string>(File.ReadAllLines(m)) : new List<string>();
                if (lines.Exists(x => x.Trim() == Name)) continue;
                int at = lines.FindIndex(x => x.Trim() == "Arcades");
                lines.Insert(at >= 0 ? at + 1 : Math.Min(1, lines.Count), Name);
                File.WriteAllLines(m, lines.ToArray());
            }
        }
        catch (Exception e) { log("recently played: " + e.Message); }
    }
}

class SearchIndex
{
    public class Game { public string Item, Title, Collection, Year, Maker, Key; }
    public readonly List<Game> Games = new List<Game>();

    public SearchIndex(string file)
    {
        if (!File.Exists(file)) return;
        try
        {
            var ser = new System.Web.Script.Serialization.JavaScriptSerializer { MaxJsonLength = 64 * 1024 * 1024 };
            foreach (var o in ser.Deserialize<List<Dictionary<string, object>>>(File.ReadAllText(file)))
            {
                var g = new Game { Item = S(o, "n"), Title = S(o, "t"), Collection = S(o, "c"), Year = S(o, "y"), Maker = S(o, "m") };
                g.Key = Fold(g.Title + " " + g.Item);
                Games.Add(g);
            }
        }
        catch { }
    }

    static string S(Dictionary<string, object> o, string k) { object v; return o.TryGetValue(k, out v) && v != null ? Convert.ToString(v) : ""; }
    public static string Fold(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (char ch in s.ToLowerInvariant()) sb.Append(char.IsLetterOrDigit(ch) ? ch : ' ');
        return " " + sb.ToString() + " ";
    }

    // collections the search may open: real lists in collections\ (settings.conf), not the subsets that repeat another
    // list's games (ArcadesMini, Fight ...) - null = every collection in the index
    public HashSet<string> Openable;
    static readonly HashSet<string> Subsets = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "ArcadesMini", "Fight", "Arcade", "Main", "Classic Systems" };
    public void LoadOpenable(string retroFERoot)
    {
        try
        {
            string cols = Path.Combine(retroFERoot ?? "", "collections");
            if (!Directory.Exists(cols)) return;
            var s = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var d in Directory.GetDirectories(cols))
            {
                string n = Path.GetFileName(d);
                if (!Subsets.Contains(n) && File.Exists(Path.Combine(d, "settings.conf"))) s.Add(n);
            }
            Openable = s;
        }
        catch { }
    }

    // every word typed must be in the title (or item name); titles that start with it come first, then word starts.
    // Search across all systems (James 2026-11-26): the open menu's games first, then every other system's, each game
    // once per system.
    public List<Game> Find(string query, string menu, int max)
    {
        var words = Fold(query).Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
        var hits = new List<KeyValuePair<int, Game>>();
        if (words.Length == 0) return new List<Game>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var g in Games)
        {
            bool here = !string.IsNullOrEmpty(menu) && string.Equals(g.Collection, menu, StringComparison.OrdinalIgnoreCase);
            if (!here && Openable != null && !Openable.Contains(g.Collection)) continue;
            // the original first (James 2026-11-27: "Donkey Kong ... loaded c64 version"): arcade, then consoles, home
            // computers last, for equally good matches
            bool all = true; int score = (here ? 0 : 5) + Tier(g.Collection) * 2;
            foreach (var w in words)
            {
                int at = g.Key.IndexOf(w, StringComparison.Ordinal);
                if (at < 0) { all = false; break; }
                score += at == 1 ? 0 : g.Key.IndexOf(" " + w, StringComparison.Ordinal) >= 0 ? 10 : 30;
            }
            if (!all || !seen.Add(g.Collection + "|" + g.Title)) continue;
            hits.Add(new KeyValuePair<int, Game>(score * 1000 + Math.Min(999, g.Title.Length), g));
        }
        hits.Sort((a, b) => a.Key.CompareTo(b.Key));
        var r = new List<Game>();
        for (int i = 0; i < hits.Count && i < max; i++) r.Add(hits[i].Value);
        return r;
    }

    // 0 = arcade, 1 = console / handheld, 2 = home computer (by collection name)
    static readonly System.Text.RegularExpressions.Regex ArcadeRx = new System.Text.RegularExpressions.Regex(
        @"^(MAME|Final Burn|Arcades|ArcadesMini|Fight|Atomiswave|Naomi|Model \d|TeknoParrot|Neo Geo$|Laser Disc|AM_TP)", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
    static readonly System.Text.RegularExpressions.Regex ComputerRx = new System.Text.RegularExpressions.Regex(
        @"^(Commodore|ZX Spectrum|Amstrad|MSX|Atari 800|Amiga(?! CD32)|Ports|PC Gamer|Apple|DOS)", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
    public static int Tier(string collection)
    {
        if (string.IsNullOrEmpty(collection)) return 1;
        if (ArcadeRx.IsMatch(collection)) return 0;
        if (ComputerRx.IsMatch(collection)) return 2;
        return 1;
    }
    // the system as a player reads it: "Commodore 64 (RetroBat)" -> "COMMODORE 64"
    public static string SystemLabel(string collection)
    {
        string s = (collection ?? "").Replace("(RetroBat)", "").Trim();
        if (s.StartsWith("AM_TP", StringComparison.OrdinalIgnoreCase)) s = "TeknoParrot";
        if (string.Equals(s, "Arcades", StringComparison.OrdinalIgnoreCase) || string.Equals(s, "MAME", StringComparison.OrdinalIgnoreCase) || string.Equals(s, "Final Burn", StringComparison.OrdinalIgnoreCase)) s = "Arcade";
        return s.ToUpperInvariant();
    }

    public bool HasMenu(string menu)
    {
        if (string.IsNullOrEmpty(menu)) return false;
        foreach (var g in Games) if (string.Equals(g.Collection, menu, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }
}

// windows that never take the keyboard focus from the frontend (taps still reach them)
class NoFocusForm : Form
{
    // keyboard mode (search opened from a keyboard hotkey): the window takes the focus so typing reaches it
    protected bool TakesFocus;
    protected override bool ShowWithoutActivation { get { return !TakesFocus; } }
    protected override CreateParams CreateParams
    {
        get { var cp = base.CreateParams; cp.ExStyle |= (TakesFocus ? 0 : 0x08000000 /* WS_EX_NOACTIVATE */) | 0x80 /* WS_EX_TOOLWINDOW */ | 0x08 /* WS_EX_TOPMOST */; return cp; }
    }
    protected const int WM_MOUSEACTIVATE = 0x21, MA_NOACTIVATE = 3;
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    // RetroFE's own windows go on top when it (re)starts: put this one back above them, without taking the focus
    public void KeepOnTop() { if (IsHandleCreated && Visible) SetWindowPos(Handle, new IntPtr(-1) /* HWND_TOPMOST */, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010 /* NOSIZE NOMOVE NOACTIVATE */); }
    protected override void WndProc(ref Message m) { if (m.Msg == WM_MOUSEACTIVATE && !TakesFocus) { m.Result = (IntPtr)MA_NOACTIVATE; return; } base.WndProc(ref m); }
    public static Screen TouchScreen()
    {
        foreach (var s in Screen.AllScreens) if (!s.Primary) return s;
        return Screen.PrimaryScreen;
    }
    protected static GraphicsPath Round(RectangleF r, float rad)
    {
        var p = new GraphicsPath(); float d = Math.Max(1, Math.Min(rad * 2, Math.Min(r.Width, r.Height)));
        p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure(); return p;
    }
}

class SearchButton : NoFocusForm
{
    readonly ChooserTheme th;
    public event Action Tapped;
    public SearchButton(ChooserTheme theme)
    {
        th = theme ?? new ChooserTheme();
        FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true; StartPosition = FormStartPosition.Manual;
        var s = TouchScreen().Bounds; int w = Math.Max(220, s.Width / 7), h = Math.Max(70, s.Height / 12);
        Bounds = new Rectangle(s.Right - w - s.Width / 40, s.Y + s.Height / 30, w, h);
        BackColor = Color.FromArgb(1, 2, 3); TransparencyKey = BackColor; DoubleBuffered = true; Cursor = Cursors.Hand;
        MouseDown += delegate { if (Tapped != null) Tapped(); };
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        var r = new RectangleF(3, 3, Width - 6, Height - 6);
        using (var p = Round(r, r.Height / 2)) using (var b = new SolidBrush(Color.FromArgb(10, 12, 20))) g.FillPath(b, p);
        using (var p = Round(r, r.Height / 2)) using (var pen = new Pen(th.Accent, 3)) g.DrawPath(pen, p);
        float cx = r.X + r.Height * 0.55f, cy = r.Y + r.Height / 2, rr = r.Height * 0.2f;   // a drawn magnifier
        using (var pen = new Pen(th.Accent, Math.Max(3, r.Height * 0.07f)) { StartCap = LineCap.Round, EndCap = LineCap.Round })
        { g.DrawEllipse(pen, cx - rr, cy - rr - rr * 0.2f, rr * 2, rr * 2); g.DrawLine(pen, cx + rr * 0.7f, cy + rr * 0.5f, cx + rr * 1.5f, cy + rr * 1.3f); }
        using (var f = new Font(th.Family, r.Height * 0.36f, FontStyle.Bold, GraphicsUnit.Pixel)) using (var fmt = new StringFormat { LineAlignment = StringAlignment.Center })
            g.DrawString("SEARCH", f, Brushes.White, new RectangleF(r.X + r.Height * 1.05f, r.Y, r.Width, r.Height), fmt);
    }
}

class SearchScreen : NoFocusForm
{
    readonly SearchIndex index;
    readonly GameLink link;
    readonly ChooserTheme th;
    readonly string retroFERoot;
    string query = "", note;
    List<SearchIndex.Game> results = new List<SearchIndex.Game>();
    readonly List<KeyValuePair<RectangleF, string>> keys = new List<KeyValuePair<RectangleF, string>>();
    readonly List<KeyValuePair<RectangleF, SearchIndex.Game>> rows = new List<KeyValuePair<RectangleF, SearchIndex.Game>>();
    readonly Dictionary<string, Image> logos = new Dictionary<string, Image>(StringComparer.OrdinalIgnoreCase);
    string pressed; DateTime pressedAt;
    readonly System.Windows.Forms.Timer frame = new System.Windows.Forms.Timer { Interval = 40 };
    DateTime lastTouch = DateTime.Now;
    // SHIFT swaps the number row for the symbols game names use (James 2026-11-26: "need to shift to get - + etc")
    static readonly string[] Symbols = { "-", "+", "&", "'", ":", ".", "!", "?", "/", "#" };
    bool shift;
    static readonly string[][] Layout = {
        new[] { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" },
        new[] { "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P" },
        new[] { "A", "S", "D", "F", "G", "H", "J", "K", "L", "DEL" },
        new[] { "SHIFT", "Z", "X", "C", "V", "B", "N", "M", "SPACE", "CLEAR", "CLOSE" } };
    string KeyAt(int row, int i) { return shift && row == 0 ? Symbols[i] : Layout[row][i]; }

    // the highlighted result (keyboard: Up / Down move it, Enter jumps to it)
    int sel;

    public SearchScreen(SearchIndex index, GameLink link, ChooserTheme theme, string retroFERoot) : this(index, link, theme, retroFERoot, false) { }

    // keyboard: opened from a keyboard hotkey (the 2-player cabinet has a keyboard and no touch screen) - the page takes
    // the focus, typing goes into it, and the focus goes back to the frontend when it closes
    // panel: opened from the panel (Game Options > SEARCH on a one-screen cabinet, James 2026-11-27: "need a way to open
    // search on the same screen if there is no touch"). The stick moves a highlight over the on-screen keyboard and down
    // into the results; button 1 (Left Ctrl) presses it, button 2 (Left Alt) deletes (closes when empty), Tab / Esc close.
    // Letter keys are ignored: a keyboard-wired panel sends letters for player 2 (A, S, Q, W ...).
    readonly bool panel;
    int cr = 1, cc;          // the highlighted key (row, column); starts on Q
    bool inResults;          // the highlight is in the results, not the keyboard
    public SearchScreen(SearchIndex index, GameLink link, ChooserTheme theme, string retroFERoot, bool keyboard, bool panel) : this(index, link, theme, retroFERoot, keyboard || panel)
    {
        this.panel = panel;
        if (panel) Shown += delegate { ControllerChooser.TakeFocus(Handle); };   // opened by AmPanel itself: Windows needs the help
    }

    public SearchScreen(SearchIndex index, GameLink link, ChooserTheme theme, string retroFERoot, bool keyboard)
    {
        TakesFocus = keyboard; KeyPreview = true;
        KeyDown += OnKey;
        if (keyboard)
        {
            Shown += delegate { Activate(); Focus(); };
            FormClosed += delegate { FrontendFocus.FocusMain(); };
        }
        this.index = index; this.link = link; th = theme ?? new ChooserTheme(); this.retroFERoot = retroFERoot;
        FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true; StartPosition = FormStartPosition.Manual;
        Bounds = TouchScreen().Bounds; BackColor = Color.FromArgb(8, 9, 14); DoubleBuffered = true;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
        MouseDown += OnTap;
        frame.Tick += delegate { if ((DateTime.Now - lastTouch).TotalSeconds > 60) Close(); else Invalidate(); };   // nobody: it goes away
        Shown += delegate { frame.Start(); };
        FormClosed += delegate { frame.Stop(); foreach (var i in logos.Values) if (i != null) i.Dispose(); };
    }

    void OnKey(object s, KeyEventArgs e)
    {
        lastTouch = DateTime.Now;
        var k = e.KeyCode;
        if (panel) { OnPanelKey(e); e.Handled = true; e.SuppressKeyPress = true; return; }
        if (k == Keys.Escape) { Close(); }
        else if (k == Keys.Back) Press("DEL");
        else if (k == Keys.Space) Press("SPACE");
        else if (k == Keys.Down) { if (results.Count > 0) sel = Math.Min(results.Count - 1, sel + 1); Invalidate(); }
        else if (k == Keys.Up) { sel = Math.Max(0, sel - 1); Invalidate(); }
        else if (k == Keys.Right) { if (results.Count > 0) sel = Math.Min(results.Count - 1, sel + 2); Invalidate(); }
        else if (k == Keys.Left) { sel = Math.Max(0, sel - 2); Invalidate(); }
        else if (k == Keys.Enter) { if (sel < results.Count) Pick(results[sel]); }
        else if (k >= Keys.A && k <= Keys.Z) Press(((char)('A' + (k - Keys.A))).ToString());
        else if (k >= Keys.D0 && k <= Keys.D9 && !e.Shift) Press(((char)('0' + (k - Keys.D0))).ToString());
        else if (k >= Keys.NumPad0 && k <= Keys.NumPad9) Press(((char)('0' + (k - Keys.NumPad0))).ToString());
        else if (k == Keys.OemMinus || k == Keys.Subtract) Press("-");
        else if (k == Keys.Oemplus || k == Keys.Add) Press(e.Shift || k == Keys.Add ? "+" : "=");
        else if (k == Keys.OemPeriod) Press(".");
        else if (k == Keys.OemQuotes) Press("'");
        else if (k == Keys.D7 && e.Shift) Press("&");
        else if (k == Keys.Oem1 && e.Shift) Press(":");
        else return;
        e.Handled = true; e.SuppressKeyPress = true;
    }

    void OnPanelKey(KeyEventArgs e)
    {
        var k = e.KeyCode;
        if (k == Keys.Escape || k == Keys.Tab) { Close(); return; }
        if (k == Keys.Menu || k == Keys.LMenu || k == Keys.Back) { if (query.Length == 0) Close(); else Press("DEL"); return; }   // button 2
        bool fire = k == Keys.ControlKey || k == Keys.LControlKey || k == Keys.Enter || k == Keys.D1;                              // button 1, Start
        if (inResults)
        {
            if (fire) { if (sel < results.Count) Pick(results[sel]); return; }
            if (k == Keys.Up) { if (sel < 2) inResults = false; else sel -= 2; }
            else if (k == Keys.Down) sel = Math.Min(results.Count - 1, sel + 2);
            else if (k == Keys.Left) sel = Math.Max(0, sel - 1);
            else if (k == Keys.Right) sel = Math.Min(results.Count - 1, sel + 1);
            Invalidate(); return;
        }
        if (fire) { Press(KeyAt(cr, cc)); return; }
        if (k == Keys.Up) cr = Math.Max(0, cr - 1);
        else if (k == Keys.Down) { if (cr == Layout.Length - 1) { if (results.Count > 0) { inResults = true; sel = 0; } } else cr++; }
        else if (k == Keys.Left) cc = (cc + Layout[cr].Length - 1) % Layout[cr].Length;
        else if (k == Keys.Right) cc = (cc + 1) % Layout[cr].Length;
        cc = Math.Min(cc, Layout[cr].Length - 1);
        Invalidate();
    }

    void OnTap(object s, MouseEventArgs e)
    {
        lastTouch = DateTime.Now;
        foreach (var k in keys) if (k.Key.Contains(e.Location)) { Press(k.Value); return; }
        foreach (var r in rows) if (r.Key.Contains(e.Location)) { Pick(r.Value); return; }
    }

    void Press(string k)
    {
        pressed = k; pressedAt = DateTime.Now;
        if (k == "CLOSE") { Close(); return; }
        if (k == "SHIFT") { shift = !shift; Invalidate(); return; }
        if (k == "DEL") { if (query.Length > 0) query = query.Substring(0, query.Length - 1); }
        else if (k == "CLEAR") query = "";
        else if (k == "SPACE") { if (query.Length > 0 && !query.EndsWith(" ")) query += " "; }
        else if (query.Length < 30) query += k;
        Refresh_();
    }

    void Refresh_()
    {
        note = null;
        string menu = link != null ? link.Menu : null;
        results = index.Find(query, menu, 8); sel = 0;   // the open list first, then every other system
        Invalidate();
    }

    void Pick(SearchIndex.Game g)
    {
        if (link == null || !link.Alive) { note = "The frontend isn't answering (settings.conf linkEvents = yes?)"; Invalidate(); return; }
        // RetroFE only takes a goto while its menu stands still (attract, a scroll ... drop it): send again every 300 ms
        // until it reports the game selected, says "miss" (not in this menu), or 4 s pass
        // in another system: open its list first (patch 0028), then the gotos land once it is open
        bool elsewhere = !string.Equals(link.Menu, g.Collection, StringComparison.OrdinalIgnoreCase);
        if (elsewhere) link.Show(g.Collection); else link.Goto(g.Item);
        int tries = 0;
        var t = new System.Windows.Forms.Timer { Interval = 300 };
        t.Tick += delegate {
            tries++;
            if (link.LastMiss == g.Item) { t.Stop(); t.Dispose(); note = g.Title + " isn't in this list"; Invalidate(); return; }
            if (string.Equals(link.Selected, g.Item, StringComparison.OrdinalIgnoreCase)) { t.Stop(); t.Dispose(); Close(); return; }
            if (tries > (elsewhere ? 27 : 13)) { t.Stop(); t.Dispose(); note = "The frontend is busy - tap it again"; Invalidate(); return; }
            if (elsewhere && !string.Equals(link.Menu, g.Collection, StringComparison.OrdinalIgnoreCase)) { if (tries % 5 == 0) link.Show(g.Collection); return; }
            link.Goto(g.Item);
        };
        t.Start();
    }

    Image Logo(SearchIndex.Game g)
    {
        string key = g.Collection + "|" + g.Item; Image im;
        if (logos.TryGetValue(key, out im)) return im;
        im = null;
        try
        {
            foreach (var kind in new[] { "logo", "marquee" })
            {
                string p = Path.Combine(retroFERoot ?? "", "collections", g.Collection, "medium_artwork", kind, g.Item + ".png");
                if (File.Exists(p)) { using (var fs = File.OpenRead(p)) im = new Bitmap(Image.FromStream(fs)); break; }
            }
        }
        catch { }
        logos[key] = im;
        return im;
    }

    protected override void OnPaintBackground(PaintEventArgs e) { }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit; g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.Clear(Color.FromArgb(8, 9, 14));
        float W = Width, H = Height, pad = W * 0.02f;
        // the query
        var qr = new RectangleF(pad, H * 0.03f, W - pad * 2, H * 0.1f);
        using (var p = Round(qr, qr.Height / 2)) using (var b = new SolidBrush(Color.FromArgb(22, 25, 36))) g.FillPath(b, p);
        using (var p = Round(qr, qr.Height / 2)) using (var pen = new Pen(th.Accent, 3)) g.DrawPath(pen, p);
        bool blink = DateTime.Now.Millisecond < 500;
        using (var f = new Font(th.Family, qr.Height * 0.5f, FontStyle.Bold, GraphicsUnit.Pixel)) using (var fmt = new StringFormat { LineAlignment = StringAlignment.Center })
        {
            string shown = query.Length > 0 ? query + (blink ? "_" : " ") : "TYPE A GAME'S NAME";
            using (var b = new SolidBrush(query.Length > 0 ? Color.White : th.Dim)) g.DrawString(shown, f, b, new RectangleF(qr.X + qr.Height * 0.5f, qr.Y, qr.Width, qr.Height), fmt);
        }
        string menu = link != null ? link.Menu : null;
        using (var f = new Font(th.Family, H * 0.024f, FontStyle.Bold, GraphicsUnit.Pixel)) using (var fmt = new StringFormat { Alignment = StringAlignment.Far, LineAlignment = StringAlignment.Center })
        using (var b = new SolidBrush(th.Dim))
            g.DrawString(note ?? (index.HasMenu(menu) ? "IN  " + menu.ToUpperInvariant() : ""), f, b, new RectangleF(qr.X, qr.Y, qr.Width - qr.Height * 0.5f, qr.Height), fmt);

        // results: two columns of four, logo + title + year / maker
        rows.Clear();
        float ry = H * 0.16f, rh = H * 0.088f, cw = (W - pad * 3) / 2;
        for (int i = 0; i < results.Count; i++)
        {
            var rr = new RectangleF(pad + (i % 2) * (cw + pad), ry + (i / 2) * (rh + H * 0.012f), cw, rh);
            rows.Add(new KeyValuePair<RectangleF, SearchIndex.Game>(rr, results[i]));
            using (var p = Round(rr, rh * 0.25f)) using (var b = new SolidBrush(Color.FromArgb(28, 32, 46))) g.FillPath(b, p);
            if (TakesFocus && i == sel && (!panel || inResults)) using (var p = Round(rr, rh * 0.25f)) using (var pen = new Pen(th.Accent, 3)) g.DrawPath(pen, p);   // keyboard: the row Enter jumps to
            var logo = Logo(results[i]); float tx = rr.X + rh * 0.3f;
            if (logo != null)
            {
                float lw = rh * 1.9f, lh = rh * 0.8f, k = Math.Min(lw / logo.Width, lh / logo.Height);
                g.DrawImage(logo, rr.X + rh * 0.2f + (lw - logo.Width * k) / 2, rr.Y + (rh - logo.Height * k) / 2, logo.Width * k, logo.Height * k);
                tx = rr.X + rh * 2.3f;
            }
            // the system as a coloured badge on the right of the row (James 2026-11-27: it "didn't show me which system"):
            // arcade magenta, console blue, home computer amber
            string sys = SearchIndex.SystemLabel(results[i].Collection);
            float badgeW = 0;
            using (var bf = new Font(th.Family, rh * 0.24f, FontStyle.Bold, GraphicsUnit.Pixel))
            {
                var sz = g.MeasureString(sys, bf);
                badgeW = Math.Min(sz.Width + rh * 0.4f, rr.Width * 0.42f);
                var br = new RectangleF(rr.Right - badgeW - rh * 0.15f, rr.Y + rh * 0.12f, badgeW, rh * 0.38f);
                int tier = SearchIndex.Tier(results[i].Collection);
                Color c = tier == 0 ? Color.FromArgb(255, 47, 160) : tier == 2 ? Color.FromArgb(255, 176, 0) : Color.FromArgb(46, 200, 255);
                using (var p = Round(br, br.Height * 0.5f)) using (var b = new SolidBrush(c)) g.FillPath(b, p);
                using (var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center, Trimming = StringTrimming.EllipsisCharacter, FormatFlags = StringFormatFlags.NoWrap })
                    g.DrawString(sys, bf, Brushes.Black, br, fmt);
            }
            using (var f = new Font(th.Family, rh * 0.3f, FontStyle.Bold, GraphicsUnit.Pixel)) using (var fmt = new StringFormat { Trimming = StringTrimming.EllipsisCharacter, FormatFlags = StringFormatFlags.NoWrap })
                g.DrawString(results[i].Title, f, Brushes.White, new RectangleF(tx, rr.Y + rh * 0.14f, Math.Max(10, rr.Right - tx - badgeW - rh * 0.4f), rh * 0.42f), fmt);
            using (var f = new Font(th.Family, rh * 0.22f, FontStyle.Regular, GraphicsUnit.Pixel)) using (var b = new SolidBrush(th.Dim))
                g.DrawString((results[i].Year + "   " + results[i].Maker).Trim(), f, b, tx, rr.Y + rh * 0.58f);
        }
        if (results.Count == 0 && query.Trim().Length > 0)
            using (var f = new Font(th.Family, H * 0.03f, FontStyle.Bold, GraphicsUnit.Pixel)) using (var b = new SolidBrush(th.Dim)) g.DrawString("NO GAME BY THAT NAME HERE", f, b, pad, ry);

        // the keyboard
        keys.Clear();
        float ky = H * 0.58f, kh = (H * 0.4f - pad) / Layout.Length;
        for (int row = 0; row < Layout.Length; row++)
        {
            var line = new string[Layout[row].Length]; for (int q = 0; q < line.Length; q++) line[q] = KeyAt(row, q);   // SHIFT: symbols in the number row
            float kw = (W - pad * 2 - (line.Length - 1) * pad * 0.4f) / line.Length;
            for (int i = 0; i < line.Length; i++)
            {
                var kr = new RectangleF(pad + i * (kw + pad * 0.4f), ky + row * kh, kw, kh - pad * 0.4f);
                keys.Add(new KeyValuePair<RectangleF, string>(kr, line[i]));
                bool hot = pressed == line[i] && (DateTime.Now - pressedAt).TotalMilliseconds < 160;
                Color fill = line[i] == "CLOSE" ? Color.FromArgb(70, 20, 30) : line[i] == "SHIFT" && shift ? Color.FromArgb(Math.Min(255, th.Accent.R / 2), Math.Min(255, th.Accent.G / 2), Math.Min(255, th.Accent.B / 2)) : line[i].Length > 1 ? Color.FromArgb(30, 36, 56) : Color.FromArgb(22, 25, 36);
                using (var p = Round(kr, kr.Height * 0.2f)) using (var b = new SolidBrush(hot ? th.Accent : fill)) g.FillPath(b, p);
                using (var p = Round(kr, kr.Height * 0.2f)) using (var pen = new Pen(Color.FromArgb(70, 255, 255, 255), 1.5f)) g.DrawPath(pen, p);
                if (panel && !inResults && row == cr && i == cc)   // the stick's highlight
                    using (var p = Round(kr, kr.Height * 0.2f)) using (var pen = new Pen(th.Accent, 4)) g.DrawPath(pen, p);
                using (var f = new Font(th.Family, kr.Height * (line[i].Length > 1 ? 0.28f : 0.42f), FontStyle.Bold, GraphicsUnit.Pixel))
                using (var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                    g.DrawString(line[i], f, hot ? Brushes.Black : Brushes.White, kr, fmt);
            }
        }
    }
}
