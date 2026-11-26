// AmPanel - the "LOADING" screen between the menu and a slow game (James 2026-11-26: TeknoParrot games like Blade
// Strangers took long to appear and the frontend sat there under them - "there needs to be a front screen saying
// loading till the game is fully loaded").
//
// Shown at game start only when the game has not put up its own window within ShowAfterMs (MAME games, which come up at
// once, never see it). It is dressed like the controller question (the theme's font and colours, the game's backdrop
// and logo), never takes the keyboard focus, and closes by itself the moment a big window of another program (the game)
// is up, when the game stops, or after GiveUpMs.
// C# 5.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

class LoadingScreen : Form
{
    public const int ShowAfterMs = 1500, GiveUpMs = 120000;
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc fn, IntPtr l);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }

    // programs whose windows are never "the game": the frontend, this panel, the shell, the launchers' own small windows
    static readonly HashSet<string> NotTheGame = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
        "retrofe", "AmPanel", "LEDBlinky", "explorer", "TeknoParrotUi", "emulatorLauncher", "cmd", "conhost", "powershell",
        "wscript", "dwm", "ShellExperienceHost", "SearchHost", "StartMenuExperienceHost", "TextInputHost", "Code", "Claude",
        // TeknoParrot's loaders put up their own windows before the game is ready (Blade Strangers closed it early)
        "OpenParrotLoader", "OpenParrotLoader64", "OpenParrotKonamiLoader", "BudgieLoader", "ElfLdr2", "TeknoParrot", "ParrotLoader", "conhost" };
    public static Action<string> Log = delegate { };
    IntPtr candidate = IntPtr.Zero;

    readonly ChooserTheme th;
    readonly string title;
    readonly Timer frame = new Timer { Interval = 15 };
    readonly Stopwatch clock = Stopwatch.StartNew();
    readonly HashSet<IntPtr> before = new HashSet<IntPtr>();
    Bitmap bg;
    long lastCheck;

    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams
    {
        get { var cp = base.CreateParams; cp.ExStyle |= 0x08000000 /* WS_EX_NOACTIVATE */ | 0x80 /* WS_EX_TOOLWINDOW */; return cp; }
    }

    // the big windows up when the game was started (the frontend ...): anything new after that is the game
    public static HashSet<IntPtr> Snapshot() { return new HashSet<IntPtr>(BigWindows()); }
    public static bool NewWindowSince(HashSet<IntPtr> baseline) { foreach (var h in BigWindows()) if (!baseline.Contains(h)) return true; return false; }

    public LoadingScreen(string title, ChooserTheme theme, HashSet<IntPtr> baseline)
    {
        this.title = title; th = theme ?? new ChooserTheme();
        if (baseline != null) foreach (var h in baseline) before.Add(h);
        FormBorderStyle = FormBorderStyle.None; TopMost = true; ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual; Bounds = Screen.PrimaryScreen.Bounds;
        BackColor = Color.Black; DoubleBuffered = true; Opacity = 0;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
        frame.Tick += delegate {
            long now = clock.ElapsedMilliseconds;
            if (Opacity < 1) Opacity = Math.Min(1.0, now / 250.0);
            if (now - lastCheck > 500) { lastCheck = now; if (GameIsUp() || now > GiveUpMs) { Close(); return; } }
            Invalidate();
        };
        Shown += delegate { frame.Start(); };
        FormClosed += delegate { frame.Stop(); if (bg != null) bg.Dispose(); };
    }

    // a new, visible window of another program covering (nearly) a whole screen, still there on the next check: the
    // game is up. A window that comes and goes (a loader's splash) does not count.
    bool GameIsUp()
    {
        IntPtr found = IntPtr.Zero;
        foreach (var h in BigWindows(0.9)) if (!before.Contains(h) && h != Handle) { found = h; break; }
        if (found == IntPtr.Zero) { candidate = IntPtr.Zero; return false; }
        if (found != candidate) { candidate = found; return false; }
        int pid; GetWindowThreadProcessId(found, out pid);
        string name = "?"; try { using (var p = Process.GetProcessById(pid)) name = p.ProcessName; } catch { }
        Log("loading screen closed: " + name + " is up");
        return true;
    }

    static List<IntPtr> BigWindows() { return BigWindows(0.5); }
    static List<IntPtr> BigWindows(double cover)
    {
        var list = new List<IntPtr>();
        int me = Process.GetCurrentProcess().Id;
        EnumWindows(delegate (IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h) || IsIconic(h)) return true;
            RECT r; if (!GetWindowRect(h, out r)) return true;
            int w = r.R - r.L, hh = r.B - r.T;
            var scr = Screen.FromRectangle(new Rectangle(r.L, r.T, Math.Max(1, w), Math.Max(1, hh))).Bounds;
            if (w < scr.Width * cover || hh < scr.Height * cover) return true;
            int pid; GetWindowThreadProcessId(h, out pid);
            if (pid == me) return true;
            try { using (var p = Process.GetProcessById(pid)) if (NotTheGame.Contains(p.ProcessName)) return true; } catch { return true; }
            list.Add(h);
            return true;
        }, IntPtr.Zero);
        return list;
    }

    // ---- a game must open on the main screen (James 2026-11-26: Pac-Man Battle Royale opened on the touch screen -
    // Windows opens a new program on the screen of the last touch / click). At game start the pointer goes to the main
    // screen, and for a minute any big game window that lands on another screen is moved there at the same size.
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    public static void KeepGameOnMainScreen(HashSet<IntPtr> baseline, Func<bool> stillPlaying, Action<string> log)
    {
        var main = Screen.PrimaryScreen.Bounds;
        try { SetCursorPos(main.X + main.Width / 2, main.Y + main.Height / 2); } catch { }
        var moved = new HashSet<IntPtr>();
        var sw = Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < 60000 && stillPlaying())
        {
            try
            {
                foreach (var h in BigWindows(0.4))
                {
                    if (baseline.Contains(h) || moved.Contains(h)) continue;
                    RECT r; if (!GetWindowRect(h, out r)) continue;
                    var rect = new Rectangle(r.L, r.T, Math.Max(1, r.R - r.L), Math.Max(1, r.B - r.T));
                    var scr = Screen.FromRectangle(rect);
                    if (scr.Primary) continue;
                    // same place on the main screen, same size (a borderless full-screen game stays full screen)
                    int x = main.X + (rect.X - scr.Bounds.X), y = main.Y + (rect.Y - scr.Bounds.Y);
                    SetWindowPos(h, IntPtr.Zero, x, y, 0, 0, 0x0001 | 0x0004 | 0x0010 /* NOSIZE NOZORDER NOACTIVATE */);
                    moved.Add(h);
                    int pid; GetWindowThreadProcessId(h, out pid);
                    string name = "?"; try { using (var p = Process.GetProcessById(pid)) name = p.ProcessName; } catch { }
                    log("game window " + name + " opened on " + scr.DeviceName + " - moved to the main screen");
                }
            }
            catch { }
            System.Threading.Thread.Sleep(400);
        }
    }

    // the game's art: the first collection that has it (the frontend tells only the item name at game start)
    public static ChooserTheme ThemeFor(string retroFERoot, string item)
    {
        string coll = null;
        try
        {
            string cols = Path.Combine(retroFERoot ?? "", "collections");
            if (!string.IsNullOrEmpty(item) && Directory.Exists(cols))
                foreach (var d in Directory.GetDirectories(cols))
                {
                    string art = Path.Combine(d, "medium_artwork");
                    if (File.Exists(Path.Combine(art, "logo", item + ".png")) || File.Exists(Path.Combine(art, "am_backdrop", item + ".jpg")) || File.Exists(Path.Combine(art, "fanart", item + ".jpg")))
                    { coll = Path.GetFileName(d); break; }
                }
        }
        catch { }
        return ChooserTheme.Load(retroFERoot, coll, item);
    }

    protected override void OnPaintBackground(PaintEventArgs e) { }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit; g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        float t = clock.ElapsedMilliseconds / 1000f;
        if (bg == null || bg.Width != Width || bg.Height != Height)
        {
            if (bg != null) bg.Dispose();
            bg = new Bitmap(Math.Max(1, Width), Math.Max(1, Height));
            using (var bgG = Graphics.FromImage(bg))
            {
                bgG.Clear(Color.FromArgb(8, 9, 14));
                if (th.Backdrop != null)
                {
                    using (var small = new Bitmap(Math.Max(1, Width / 14), Math.Max(1, Height / 14)))
                    {
                        using (var sg = Graphics.FromImage(small))
                        {
                            float k = Math.Max(small.Width / (float)th.Backdrop.Width, small.Height / (float)th.Backdrop.Height);
                            sg.DrawImage(th.Backdrop, (small.Width - th.Backdrop.Width * k) / 2, (small.Height - th.Backdrop.Height * k) / 2, th.Backdrop.Width * k, th.Backdrop.Height * k);
                        }
                        bgG.InterpolationMode = InterpolationMode.HighQualityBicubic; bgG.PixelOffsetMode = PixelOffsetMode.Half;
                        bgG.DrawImage(small, new Rectangle(-8, -8, Width + 16, Height + 16));
                    }
                    using (var dark = new SolidBrush(Color.FromArgb(160, 6, 7, 12))) bgG.FillRectangle(dark, 0, 0, Width, Height);
                }
            }
        }
        g.DrawImageUnscaled(bg, 0, 0);

        // the game's logo (or its title), breathing gently
        float pulse = 1 + 0.015f * (float)Math.Sin(t * 2.2);
        if (th.Logo != null)
        {
            float maxW = Width * 0.46f * pulse, maxH = Height * 0.3f * pulse, k = Math.Min(maxW / th.Logo.Width, maxH / th.Logo.Height);
            float w = th.Logo.Width * k, h = th.Logo.Height * k;
            g.DrawImage(th.Logo, (Width - w) / 2, Height * 0.38f - h / 2, w, h);
        }
        else
            using (var f = new Font(th.Family, Height * 0.065f, FontStyle.Bold, GraphicsUnit.Pixel)) Centered(g, (title ?? "").ToUpperInvariant(), f, Color.White, Height * 0.33f);

        // LOADING, letter-spaced, with three dots that fill in turn
        using (var f = new Font(th.Family, Height * 0.034f, FontStyle.Bold, GraphicsUnit.Pixel))
        {
            int dots = (int)(t * 2.5) % 4;
            Centered(g, "L  O  A  D  I  N  G" + new string(' ', 2) + new string('.', dots) + new string(' ', 3 - dots), f, th.Warm, Height * 0.63f);
        }
        // a light sweeping along a thin bar (it doesn't know how long the game takes, so it never pretends to)
        float bw = Width * 0.32f, bx = (Width - bw) / 2, by = Height * 0.72f, sw = bw * 0.22f;
        float pos = (float)((Math.Sin(t * 1.9) + 1) / 2) * (bw - sw);
        using (var p = Round(new RectangleF(bx, by, bw, 6), 3)) using (var br = new SolidBrush(Color.FromArgb(55, 255, 255, 255))) g.FillPath(br, p);
        using (var p = Round(new RectangleF(bx + pos, by, sw, 6), 3)) using (var br = new LinearGradientBrush(new RectangleF(bx + pos - 1, by, sw + 2, 6), th.Accent, th.Accent2, 0f)) g.FillPath(br, p);
        using (var f = new Font(th.Family, Height * 0.019f, FontStyle.Bold, GraphicsUnit.Pixel))
            Centered(g, "HOLD  EXIT  TO  CANCEL", f, Color.FromArgb(150, th.Dim), Height * 0.77f);
    }

    void Centered(Graphics g, string s, Font f, Color c, float y)
    {
        var sz = g.MeasureString(s, f); float x = (Width - sz.Width) / 2;
        using (var sb = new SolidBrush(Color.FromArgb(150, 0, 0, 0))) g.DrawString(s, f, sb, x + 2, y + 3);
        using (var b = new SolidBrush(c)) g.DrawString(s, f, b, x, y);
    }

    static GraphicsPath Round(RectangleF r, int rad)
    {
        var p = new GraphicsPath(); float d = Math.Max(1, Math.Min(rad * 2, Math.Min(r.Width, r.Height)));
        p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure(); return p;
    }
}
