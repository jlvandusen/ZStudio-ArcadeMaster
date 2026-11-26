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
    public string Menu { get; private set; }          // the menu (collection) RetroFE has open
    public string Selected { get; private set; }
    public string LastMiss { get; private set; }
    public DateTime LastHello { get; private set; }
    public bool Running { get; private set; }
    UdpClient rx;
    readonly Action<string> log;

    public GameLink(Action<string> log) { this.log = log; }

    public bool Start()
    {
        try
        {
            rx = new UdpClient(new IPEndPoint(IPAddress.Loopback, EventsPort));
            Running = true;
            new Thread(Loop) { IsBackground = true, Name = "game link" }.Start();
            return true;
        }
        catch (Exception e) { log("search: cabinet link port " + EventsPort + " is taken (" + e.Message + ") - search works, jumping does not"); return false; }
    }

    void Loop()
    {
        var from = new IPEndPoint(IPAddress.Any, 0);
        while (Running)
        {
            try
            {
                string line = Encoding.UTF8.GetString(rx.Receive(ref from));
                var p = line.Split('\t');
                if (p.Length >= 2 && p[0] == "hello") { Menu = p[1]; LastHello = DateTime.Now; }
                else if (p.Length >= 5 && p[0] == "select") { Menu = p[2]; Selected = p[4]; }
                else if (p.Length >= 2 && p[0] == "miss") LastMiss = p[1];
            }
            catch { if (!Running) return; Thread.Sleep(200); }
        }
    }

    public bool Alive { get { return Running && (DateTime.Now - LastHello).TotalSeconds < 5; } }

    public void Goto(string item)
    {
        LastMiss = null;
        try { using (var tx = new UdpClient()) { var b = Encoding.UTF8.GetBytes("goto\t" + item); tx.Send(b, b.Length, new IPEndPoint(IPAddress.Loopback, CommandsPort)); } }
        catch (Exception e) { log("search: goto failed: " + e.Message); }
    }

    public void Stop() { Running = false; try { rx.Close(); } catch { } }
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

    public static string Guard()
    {
        IntPtr main = FindWindow(null, "RetroFE 0");
        if (main == IntPtr.Zero) return null;
        string fixedWin = null;
        for (int n = 1; n < 4; n++)
        {
            IntPtr w = FindWindow(null, "RetroFE " + n);
            if (w == IntPtr.Zero) continue;
            int ex = GetWindowLong(w, GWL_EXSTYLE);
            if ((ex & WS_EX_NOACTIVATE) == 0) { SetWindowLong(w, GWL_EXSTYLE, ex | WS_EX_NOACTIVATE); fixedWin = "RetroFE " + n; }
            if (GetForegroundWindow() == w)
            {
                int fg = GetWindowThreadProcessId(w, IntPtr.Zero), me = GetCurrentThreadId();
                AttachThreadInput(me, fg, true); SetForegroundWindow(main); AttachThreadInput(me, fg, false);
                return "focus handed back from RetroFE " + n + " to the main window";
            }
        }
        return fixedWin != null ? fixedWin + " made non-activating" : null;
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

    // every word typed must be in the title (or item name); titles that start with it come first, then word starts
    public List<Game> Find(string query, string menu, int max)
    {
        var words = Fold(query).Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
        var hits = new List<KeyValuePair<int, Game>>();
        if (words.Length == 0) return new List<Game>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var g in Games)
        {
            if (!string.IsNullOrEmpty(menu) && !string.Equals(g.Collection, menu, StringComparison.OrdinalIgnoreCase)) continue;
            bool all = true; int score = 0;
            foreach (var w in words)
            {
                int at = g.Key.IndexOf(w, StringComparison.Ordinal);
                if (at < 0) { all = false; break; }
                score += at == 1 ? 0 : g.Key.IndexOf(" " + w, StringComparison.Ordinal) >= 0 ? 10 : 30;
            }
            if (!all || !seen.Add(g.Item)) continue;
            hits.Add(new KeyValuePair<int, Game>(score * 1000 + Math.Min(999, g.Title.Length), g));
        }
        hits.Sort((a, b) => a.Key.CompareTo(b.Key));
        var r = new List<Game>();
        for (int i = 0; i < hits.Count && i < max; i++) r.Add(hits[i].Value);
        return r;
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
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams
    {
        get { var cp = base.CreateParams; cp.ExStyle |= 0x08000000 /* WS_EX_NOACTIVATE */ | 0x80 /* WS_EX_TOOLWINDOW */ | 0x08 /* WS_EX_TOPMOST */; return cp; }
    }
    protected const int WM_MOUSEACTIVATE = 0x21, MA_NOACTIVATE = 3;
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    // RetroFE's own windows go on top when it (re)starts: put this one back above them, without taking the focus
    public void KeepOnTop() { if (IsHandleCreated && Visible) SetWindowPos(Handle, new IntPtr(-1) /* HWND_TOPMOST */, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010 /* NOSIZE NOMOVE NOACTIVATE */); }
    protected override void WndProc(ref Message m) { if (m.Msg == WM_MOUSEACTIVATE) { m.Result = (IntPtr)MA_NOACTIVATE; return; } base.WndProc(ref m); }
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
    static readonly string[][] Layout = {
        new[] { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" },
        new[] { "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P" },
        new[] { "A", "S", "D", "F", "G", "H", "J", "K", "L", "DEL" },
        new[] { "Z", "X", "C", "V", "B", "N", "M", "SPACE", "CLEAR", "CLOSE" } };

    public SearchScreen(SearchIndex index, GameLink link, ChooserTheme theme, string retroFERoot)
    {
        this.index = index; this.link = link; th = theme ?? new ChooserTheme(); this.retroFERoot = retroFERoot;
        FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true; StartPosition = FormStartPosition.Manual;
        Bounds = TouchScreen().Bounds; BackColor = Color.FromArgb(8, 9, 14); DoubleBuffered = true;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
        MouseDown += OnTap;
        frame.Tick += delegate { if ((DateTime.Now - lastTouch).TotalSeconds > 60) Close(); else Invalidate(); };   // nobody: it goes away
        Shown += delegate { frame.Start(); };
        FormClosed += delegate { frame.Stop(); foreach (var i in logos.Values) if (i != null) i.Dispose(); };
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
        bool scoped = index.HasMenu(menu);
        results = index.Find(query, scoped ? menu : null, 8);
        if (!scoped && query.Trim().Length > 0) note = "Open a game list first - these are from every list";
        Invalidate();
    }

    void Pick(SearchIndex.Game g)
    {
        if (link == null || !link.Alive) { note = "The frontend isn't answering (settings.conf linkEvents = yes?)"; Invalidate(); return; }
        // RetroFE only takes a goto while its menu stands still (attract, a scroll ... drop it): send again every 300 ms
        // until it reports the game selected, says "miss" (not in this menu), or 4 s pass
        link.Goto(g.Item);
        int tries = 0;
        var t = new System.Windows.Forms.Timer { Interval = 300 };
        t.Tick += delegate {
            tries++;
            if (link.LastMiss == g.Item) { t.Stop(); t.Dispose(); note = g.Title + " isn't in this list"; Invalidate(); return; }
            if (string.Equals(link.Selected, g.Item, StringComparison.OrdinalIgnoreCase)) { t.Stop(); t.Dispose(); Close(); return; }
            if (tries > 13) { t.Stop(); t.Dispose(); note = "The frontend is busy - tap it again"; Invalidate(); return; }
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
            var logo = Logo(results[i]); float tx = rr.X + rh * 0.3f;
            if (logo != null)
            {
                float lw = rh * 1.9f, lh = rh * 0.8f, k = Math.Min(lw / logo.Width, lh / logo.Height);
                g.DrawImage(logo, rr.X + rh * 0.2f + (lw - logo.Width * k) / 2, rr.Y + (rh - logo.Height * k) / 2, logo.Width * k, logo.Height * k);
                tx = rr.X + rh * 2.3f;
            }
            using (var f = new Font(th.Family, rh * 0.3f, FontStyle.Bold, GraphicsUnit.Pixel)) using (var fmt = new StringFormat { Trimming = StringTrimming.EllipsisCharacter, FormatFlags = StringFormatFlags.NoWrap })
                g.DrawString(results[i].Title, f, Brushes.White, new RectangleF(tx, rr.Y + rh * 0.14f, rr.Right - tx - rh * 0.2f, rh * 0.42f), fmt);
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
            var line = Layout[row]; float kw = (W - pad * 2 - (line.Length - 1) * pad * 0.4f) / line.Length;
            for (int i = 0; i < line.Length; i++)
            {
                var kr = new RectangleF(pad + i * (kw + pad * 0.4f), ky + row * kh, kw, kh - pad * 0.4f);
                keys.Add(new KeyValuePair<RectangleF, string>(kr, line[i]));
                bool hot = pressed == line[i] && (DateTime.Now - pressedAt).TotalMilliseconds < 160;
                Color fill = line[i] == "CLOSE" ? Color.FromArgb(70, 20, 30) : line[i].Length > 1 ? Color.FromArgb(30, 36, 56) : Color.FromArgb(22, 25, 36);
                using (var p = Round(kr, kr.Height * 0.2f)) using (var b = new SolidBrush(hot ? th.Accent : fill)) g.FillPath(b, p);
                using (var p = Round(kr, kr.Height * 0.2f)) using (var pen = new Pen(Color.FromArgb(70, 255, 255, 255), 1.5f)) g.DrawPath(pen, p);
                using (var f = new Font(th.Family, kr.Height * (line[i].Length > 1 ? 0.28f : 0.42f), FontStyle.Bold, GraphicsUnit.Pixel))
                using (var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                    g.DrawString(line[i], f, hot ? Brushes.Black : Brushes.White, kr, fmt);
            }
        }
    }
}
