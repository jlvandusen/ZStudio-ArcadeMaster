// AmPanel - the "Which controller will you use?" screen, dressed in the cabinet's own theme.
//
// Everything is drawn by hand (one double-buffered surface, ~60 fps while it is up):
//   - the game's backdrop (am_backdrop / fanart / cover from the collection), softened, darkened and vignetted
//   - its logo (or the title in the theme's font), the question in the theme's accent colour
//   - glass tiles with drawn controller pictures; the highlight glides between them and breathes in the theme's colour
//   - a countdown bar (the last pick is taken by itself when it runs out), a fade-in, the theme's own move/select sounds
// The theme is read from the active RetroFE layout (settings.conf "layout"): its font and its fontColor accents, so the
// screen follows a theme change by itself. Without a layout it falls back to ArcadeMaster's colours.
// C# 5.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.IO;
using System.Text.RegularExpressions;
using System.Windows.Forms;

class ChooserTheme
{
    public FontFamily Family = new FontFamily("Segoe UI");
    public Color Accent = Color.FromArgb(0x2e, 0xc8, 0xff), Accent2 = Color.FromArgb(0xff, 0x2f, 0xa0), Warm = Color.FromArgb(0xff, 0xb0, 0x00), Dim = Color.FromArgb(0x8d, 0x95, 0xa3);
    public Image Backdrop, Logo;
    public string MoveSound, SelectSound;
    static PrivateFontCollection fonts;   // kept alive: GDI+ needs the collection while its fonts are used

    public static ChooserTheme Load(string retroFERoot, string collection, string item)
    {
        var t = new ChooserTheme();
        if (string.IsNullOrEmpty(retroFERoot)) return t;
        try
        {
            string layout = "ArcadeMaster", sc = Path.Combine(retroFERoot, "settings.conf");
            if (File.Exists(sc)) foreach (var l in File.ReadAllLines(sc)) { var m = Regex.Match(l, @"^\s*layout\s*=\s*(.+?)\s*$"); if (m.Success) layout = m.Groups[1].Value; }
            string dir = Path.Combine(retroFERoot, "layouts", layout), xml = Path.Combine(dir, "layout.xml");
            if (File.Exists(xml))
            {
                string x = File.ReadAllText(xml);
                var fm = Regex.Match(x, @"<layout[^>]*\sfont=""([^""]+)""");
                if (fm.Success)
                {
                    string ttf = Path.Combine(dir, fm.Groups[1].Value.Replace('/', '\\'));
                    if (File.Exists(ttf)) { fonts = new PrivateFontCollection(); fonts.AddFontFile(ttf); t.Family = fonts.Families[0]; }
                }
                // the layout's accent colours: its saturated fontColors, most used first
                var seen = new List<Color>();
                foreach (Match m in Regex.Matches(x, @"fontColor=""([0-9a-fA-F]{6})"""))
                {
                    var c = ColorTranslator.FromHtml("#" + m.Groups[1].Value);
                    if (c.GetSaturation() > 0.45f && c.GetBrightness() > 0.35f && !seen.Contains(c)) seen.Add(c);
                }
                if (seen.Count > 0) t.Accent = seen[0];
                if (seen.Count > 1) t.Warm = seen[1];
                if (seen.Count > 2) t.Accent2 = seen[2];
            }
            string snd = Path.Combine(dir, "sounds");
            if (File.Exists(Path.Combine(snd, "highlight.wav"))) t.MoveSound = Path.Combine(snd, "highlight.wav");
            if (File.Exists(Path.Combine(snd, "select.wav"))) t.SelectSound = Path.Combine(snd, "select.wav");
            if (!string.IsNullOrEmpty(collection) && !string.IsNullOrEmpty(item))
            {
                string art = Path.Combine(retroFERoot, "collections", collection, "medium_artwork");
                t.Backdrop = Art(art, item, "am_backdrop", "fanart", "cover", "screenshot");
                t.Logo = Art(art, item, "logo", "marquee");
            }
        }
        catch { }
        return t;
    }

    static Image Art(string root, string item, params string[] kinds)
    {
        foreach (var k in kinds)
            foreach (var ext in new[] { ".png", ".jpg", ".jpeg" })
            {
                string p = Path.Combine(root, k, item + ext);
                if (File.Exists(p)) try { using (var s = File.OpenRead(p)) return new Bitmap(Image.FromStream(s)); } catch { }
            }
        return null;
    }
}

class ControllerChooser : Form
{
    readonly List<Dictionary<string, object>> choices;
    readonly ChooserTheme th;
    readonly string title, last;
    readonly Timer frame = new Timer { Interval = 15 };
    readonly System.Diagnostics.Stopwatch clock = System.Diagnostics.Stopwatch.StartNew();
    Bitmap bg;                 // backdrop already scaled, softened and darkened for this screen size
    int sel, totalMs, leftMs;
    float glide;               // the highlight's position, easing towards sel
    long lastMs, restSince;
    float hintA = 1;           // floating button hints: fade in once the highlight is at rest, out while it moves
    public string Picked { get; private set; }
    // the marquee / touch screen shows a copy (James: "allow marquee buttons on screen to work there"): both copies share
    // the highlight, a touch or press on either one picks for both. The copy never takes the keyboard focus.
    public ControllerChooser Peer;
    public bool Passive;
    // the same screen as a menu (Game Options): its own question and pick word; back, Tab and the time-out close it
    // without a pick (Picked stays null); no "best fit" tag, the current choice is tagged NOW
    public string Question = "WHICH CONTROLLER WILL YOU USE?";
    public string PickWord = "PLAY";
    public bool Menu;
    protected override bool ShowWithoutActivation { get { return Passive; } }
    void Select(int i) { if (i == sel) return; sel = i; if (Peer != null) Peer.sel = i; Play(th.MoveSound); }

    public ControllerChooser(string title, List<Dictionary<string, object>> choices, string last, int seconds) : this(title, choices, last, seconds, new ChooserTheme()) { }

    public ControllerChooser(string title, List<Dictionary<string, object>> choices, string last, int seconds, ChooserTheme theme)
    {
        this.choices = choices; this.title = title; this.last = last; th = theme;
        FormBorderStyle = FormBorderStyle.None; TopMost = true; ShowInTaskbar = false; KeyPreview = true;
        StartPosition = FormStartPosition.Manual; Bounds = Screen.PrimaryScreen.Bounds;
        BackColor = Color.Black; DoubleBuffered = true; Opacity = 0; Cursor = Cursors.Hand;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
        totalMs = leftMs = seconds * 1000;
        for (int i = 0; i < choices.Count; i++) if (Convert.ToString(choices[i]["id"]) == last) sel = i;
        glide = sel;
        KeyDown += OnKey;
        MouseClick += delegate (object s, MouseEventArgs e) { for (int i = 0; i < choices.Count; i++) if (TileRect(i).Contains(e.Location)) { sel = i; if (Peer != null) Peer.sel = i; Done(); } };
        MouseMove += delegate (object s, MouseEventArgs e) { for (int i = 0; i < choices.Count; i++) if (TileRect(i).Contains(e.Location)) Select(i); };
        frame.Tick += delegate {
            long now = clock.ElapsedMilliseconds; int dt = (int)(now - lastMs); lastMs = now;
            if (Opacity < 1) Opacity = Math.Min(1.0, now / 220.0);           // fade in
            glide += (sel - glide) * Math.Min(1f, dt / 70f);                  // ease the highlight
            if (Math.Abs(sel - glide) > 0.01f) restSince = now;
            float want = now - restSince > 280 ? 1f : 0f;
            hintA += (want - hintA) * Math.Min(1f, dt / (want > hintA ? 160f : 50f));
            leftMs -= dt; if (leftMs <= 0) { if (Menu) Cancel(); else Done(); }
            Invalidate();
        };
        Shown += delegate { if (!Passive) { TakeFocus(Handle); Activate(); BringToFront(); Focus(); } frame.Start(); };
        FormClosed += delegate { frame.Stop(); if (bg != null) bg.Dispose(); };
    }

    void OnKey(object s, KeyEventArgs e)
    {
        leftMs = Math.Max(leftMs, 4000); totalMs = Math.Max(totalMs, leftMs);   // someone is here: never time out under their hand
        int was = sel;
        // a menu: Esc, Backspace, Left Alt (panel button 2 = back) and Tab (the key that opened it) close it
        if (Menu && (e.KeyCode == Keys.Escape || e.KeyCode == Keys.Back || e.KeyCode == Keys.Tab || e.KeyCode == Keys.Menu || e.KeyCode == Keys.LMenu || e.Alt && e.KeyCode != Keys.ControlKey)) { e.Handled = true; Cancel(); return; }
        switch (e.KeyCode)
        {
            case Keys.Left: case Keys.Up: case Keys.NumPad4: case Keys.D: sel = (sel + choices.Count - 1) % choices.Count; break;
            case Keys.Right: case Keys.Down: case Keys.NumPad6: case Keys.G: sel = (sel + 1) % choices.Count; break;
            case Keys.ControlKey: case Keys.LControlKey: case Keys.Enter: case Keys.Space: case Keys.D1: case Keys.Escape: Done(); return;
        }
        if (sel != was) { Play(th.MoveSound); if (Peer != null) Peer.sel = sel; }
        e.Handled = true;
    }

    void Done()
    {
        if (Picked != null) return;
        Picked = Convert.ToString(choices[sel]["id"]);
        Play(th.SelectSound);
        frame.Stop(); Invalidate(); Update();
        if (Peer != null && Peer.Picked == null) { Peer.Picked = Picked; Peer.sel = sel; Peer.frame.Stop(); Peer.Invalidate(); Peer.Update(); }
        System.Threading.Thread.Sleep(160);   // the pick flashes before the game takes over
        if (Peer != null && !Peer.IsDisposed) Peer.Close();
        Close();
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    // Windows lets a program take the keyboard from the window in front only if it is allowed to. Opened by AmPanel itself
    // (Game Options on TAB) it was not: the menu showed, but the stick and Esc still went to the frontend behind it
    // (2026-11-27). Sharing the front window's input queue for a moment makes the switch allowed.
    static void TakeFocus(IntPtr me)
    {
        IntPtr fg = GetForegroundWindow(); if (fg == me) return;
        uint fgThread = GetWindowThreadProcessId(fg, IntPtr.Zero), mine = GetCurrentThreadId();
        bool attached = fgThread != 0 && fgThread != mine && AttachThreadInput(mine, fgThread, true);
        try { BringWindowToTop(me); SetForegroundWindow(me); }
        finally { if (attached) AttachThreadInput(mine, fgThread, false); }
    }

    void Cancel()
    {
        if (Picked != null) return;
        frame.Stop();
        if (Peer != null && !Peer.IsDisposed) Peer.Close();
        Close();
    }

    static void Play(string wav) { if (wav == null) return; try { new System.Media.SoundPlayer(wav).Play(); } catch { } }

    // ---------------------------------------------------------------- layout
    int TileW { get { return Math.Min(420, (Width - 200) / Math.Max(1, choices.Count) - 40); } }
    int TileH { get { return (int)(TileW * 0.78); } }
    Rectangle TileRect(int i)
    {
        int n = choices.Count, gap = 48, w = TileW, total = n * w + (n - 1) * gap;
        return new Rectangle((Width - total) / 2 + i * (w + gap), (int)(Height * 0.47), w, TileH);
    }

    // ---------------------------------------------------------------- drawing
    protected override void OnPaintBackground(PaintEventArgs e) { }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit; g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        float t = clock.ElapsedMilliseconds / 1000f;
        DrawBackdrop(g);

        // header: the logo, else the title
        float headY = Height * 0.12f;
        if (th.Logo != null)
        {
            float maxW = Width * 0.42f, maxH = Height * 0.2f, k = Math.Min(maxW / th.Logo.Width, maxH / th.Logo.Height);
            float w = th.Logo.Width * k, h = th.Logo.Height * k;
            g.DrawImage(th.Logo, (Width - w) / 2, headY + (maxH - h) / 2, w, h);
        }
        else
            using (var f = new Font(th.Family, Height * 0.06f, FontStyle.Bold, GraphicsUnit.Pixel)) Centered(g, (title ?? "").ToUpperInvariant(), f, Color.White, headY + Height * 0.05f, true);

        // the question, letter-spaced, in the theme's warm accent
        using (var f = new Font(th.Family, Height * 0.032f, FontStyle.Bold, GraphicsUnit.Pixel))
            Centered(g, Spaced(Question), f, th.Warm, Height * 0.33f, true);   // room for the floating PLAY button

        // tiles
        for (int i = 0; i < choices.Count; i++) DrawTile(g, i, t);

        // the gliding highlight: a glowing frame between tiles while it moves
        var a = TileRect((int)Math.Floor(glide)); var b = TileRect(Math.Min(choices.Count - 1, (int)Math.Floor(glide) + 1));
        float fr = glide - (float)Math.Floor(glide);
        var hr = new RectangleF(a.X + (b.X - a.X) * fr, a.Y, a.Width, a.Height);
        float pulse = 0.5f + 0.5f * (float)Math.Sin(t * 4.2);
        hr.Inflate(6 + 3 * pulse, 6 + 3 * pulse);
        for (int k = 5; k >= 1; k--)
            using (var p = new Pen(Color.FromArgb((int)(18 + 10 * pulse) * (6 - k) / 2, th.Accent), k * 5f)) using (var path = Round(hr, 26)) g.DrawPath(p, path);
        using (var p = new Pen(Color.FromArgb(240, th.Accent), 3.5f)) using (var path = Round(hr, 26)) g.DrawPath(p, path);
        if (hintA > 0.02f) DrawFloatingHints(g, TileRect(sel), t);

        // countdown bar + hint
        float bw = Width * 0.36f, bx = (Width - bw) / 2, by = Height * 0.88f, frac = Math.Max(0, Math.Min(1, leftMs / (float)totalMs));
        using (var p = Round(new RectangleF(bx, by, bw, 8), 4)) using (var br = new SolidBrush(Color.FromArgb(60, 255, 255, 255))) g.FillPath(br, p);
        if (frac > 0)
            using (var p = Round(new RectangleF(bx, by, Math.Max(8, bw * frac), 8), 4))
            using (var br = new LinearGradientBrush(new RectangleF(bx, by, bw, 8), th.Accent, th.Accent2, 0f)) g.FillPath(br, p);
        DrawHint(g, by + 34);
    }

    void DrawBackdrop(Graphics g)
    {
        if (bg == null || bg.Width != Width || bg.Height != Height)
        {
            if (bg != null) bg.Dispose();
            bg = new Bitmap(Math.Max(1, Width), Math.Max(1, Height));
            using (var bgG = Graphics.FromImage(bg))
            {
                bgG.Clear(Color.FromArgb(8, 9, 14));
                if (th.Backdrop != null)
                {
                    // soften: draw small, then stretch back up (a cheap, smooth blur)
                    using (var small = new Bitmap(Math.Max(1, Width / 14), Math.Max(1, Height / 14)))
                    {
                        using (var sg = Graphics.FromImage(small)) { sg.InterpolationMode = InterpolationMode.HighQualityBilinear; Cover(sg, th.Backdrop, small.Size); }
                        bgG.InterpolationMode = InterpolationMode.HighQualityBicubic; bgG.PixelOffsetMode = PixelOffsetMode.Half;
                        bgG.DrawImage(small, new Rectangle(-8, -8, Width + 16, Height + 16));
                    }
                    using (var dark = new SolidBrush(Color.FromArgb(150, 6, 7, 12))) bgG.FillRectangle(dark, 0, 0, Width, Height);
                }
                // theme glow from below + vignette
                using (var path = new GraphicsPath())
                {
                    path.AddEllipse(-Width * 0.2f, Height * 0.35f, Width * 1.4f, Height * 1.2f);
                    using (var pg = new PathGradientBrush(path) { CenterColor = Color.FromArgb(70, th.Accent), SurroundColors = new[] { Color.FromArgb(0, th.Accent) } }) bgG.FillPath(pg, path);
                }
                using (var path = new GraphicsPath())
                {
                    path.AddEllipse(-Width * 0.25f, -Height * 0.3f, Width * 1.5f, Height * 1.6f);
                    using (var pg = new PathGradientBrush(path) { CenterColor = Color.FromArgb(0, 0, 0, 0), SurroundColors = new[] { Color.FromArgb(235, 0, 0, 0) }, FocusScales = new PointF(0.55f, 0.5f) })
                        bgG.FillRectangle(pg, 0, 0, Width, Height);
                }
            }
        }
        g.DrawImageUnscaled(bg, 0, 0);
    }

    static void Cover(Graphics g, Image img, Size s)
    {
        float k = Math.Max(s.Width / (float)img.Width, s.Height / (float)img.Height);
        float w = img.Width * k, h = img.Height * k;
        g.DrawImage(img, (s.Width - w) / 2, (s.Height - h) / 2, w, h);
    }

    void DrawTile(Graphics g, int i, float t)
    {
        var r = TileRect(i);
        bool on = i == sel;
        float lift = on ? 1f : 0f;
        using (var path = Round(r, 22))
        {
            // glass: a dark translucent fill, lighter at the top; the chosen tile carries the theme's colour
            using (var br = new LinearGradientBrush(r, Color.FromArgb(on ? 150 : 110, on ? Mix(th.Accent, Color.Black, 0.55f) : Color.FromArgb(30, 34, 48)), Color.FromArgb(on ? 200 : 170, 10, 12, 18), 90f))
                g.FillPath(br, path);
            using (var p = new Pen(Color.FromArgb(on ? 0 : 60, 255, 255, 255), 1.5f)) g.DrawPath(p, path);
            // the glass shine fades out by the middle: clipped to the tile, no edge of its own
            var shine = new Rectangle(r.X, r.Y, r.Width, r.Height / 2 + 1);
            var clip = g.Clip; g.SetClip(path, CombineMode.Intersect);
            using (var br = new LinearGradientBrush(shine, Color.FromArgb(on ? 40 : 22, 255, 255, 255), Color.FromArgb(0, 255, 255, 255), 90f)) g.FillRectangle(br, r.X, r.Y, r.Width, r.Height / 2);
            g.Clip = clip;
        }
        string id = Convert.ToString(choices[i]["id"]);
        var icon = new RectangleF(r.X + r.Width * 0.3f, r.Y + r.Height * 0.1f - lift * 4, r.Width * 0.4f, r.Height * 0.48f);
        DrawIcon(g, choices[i].ContainsKey("icon") ? Convert.ToString(choices[i]["icon"]) : id, icon, on ? Color.White : Color.FromArgb(200, 215, 225, 240), on ? th.Accent : th.Dim, t);
        using (var f = new Font(th.Family, Math.Max(14, r.Height * 0.085f), FontStyle.Bold, GraphicsUnit.Pixel))
        using (var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
        using (var br = new SolidBrush(on ? Color.White : Color.FromArgb(210, 225, 230, 240)))
            g.DrawString(Convert.ToString(choices[i]["label"]), f, br, new RectangleF(r.X + 12, r.Y + r.Height * 0.62f, r.Width - 24, r.Height * 0.2f), fmt);
        // a small tag: best fit / last time
        string tag = Menu ? (id == last ? "NOW" : null) : id == last ? "LAST TIME" : i == 0 ? "BEST FIT" : null;
        if (tag != null)
            using (var f = new Font(th.Family, Math.Max(11, r.Height * 0.052f), FontStyle.Bold, GraphicsUnit.Pixel))
            {
                var sz = g.MeasureString(Spaced(tag), f);
                var tr = new RectangleF(r.X + (r.Width - sz.Width - 22) / 2, r.Bottom - r.Height * 0.15f, sz.Width + 22, sz.Height + 4);
                using (var p = Round(tr, (int)(tr.Height / 2))) using (var br = new SolidBrush(Color.FromArgb(on ? 220 : 120, id == last ? th.Warm : th.Accent))) g.FillPath(br, p);
                using (var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                    g.DrawString(Spaced(tag), f, Brushes.Black, tr, fmt);
            }
    }

    // controller pictures, drawn (not font glyphs): they scale cleanly and take the theme's colour
    static void DrawIcon(Graphics g, string id, RectangleF r, Color ink, Color accent, float t)
    {
        float s = Math.Min(r.Width, r.Height), cx = r.X + r.Width / 2, cy = r.Y + r.Height / 2, lw = Math.Max(2.5f, s * 0.045f);
        using (var pen = new Pen(ink, lw) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
        using (var fill = new SolidBrush(accent))
        using (var inkB = new SolidBrush(ink))
            switch (id)
            {
                case "trackball":
                    {
                        var rim = new RectangleF(cx - s * 0.46f, cy - s * 0.2f, s * 0.92f, s * 0.5f);
                        g.DrawEllipse(pen, rim);
                        float br = s * 0.3f, by = cy - s * 0.12f;
                        using (var ball = new GraphicsPath())
                        {
                            ball.AddEllipse(cx - br, by - br, br * 2, br * 2);
                            using (var pg = new PathGradientBrush(ball) { CenterPoint = new PointF(cx - br * 0.35f, by - br * 0.4f), CenterColor = Color.White, SurroundColors = new[] { accent } }) g.FillPath(pg, ball);
                        }
                        break;
                    }
                case "joystick":
                case "analog":
                    {
                        var plate = new RectangleF(cx - s * 0.42f, cy + s * 0.16f, s * 0.84f, s * 0.22f);
                        g.DrawEllipse(pen, plate);
                        float tilt = id == "analog" ? (float)Math.Sin(t * 1.6) * s * 0.09f : 0;
                        var top = new PointF(cx + tilt, cy - s * 0.24f);
                        g.DrawLine(pen, new PointF(cx, cy + s * 0.27f), top);
                        float br = s * 0.15f;
                        g.FillEllipse(fill, top.X - br, top.Y - br, br * 2, br * 2);
                        g.DrawEllipse(pen, top.X - br, top.Y - br, br * 2, br * 2);
                        if (id == "analog")
                            using (var arc = new Pen(Color.FromArgb(170, accent), lw * 0.8f) { DashStyle = DashStyle.Dot }) g.DrawEllipse(arc, cx - s * 0.48f, cy - s * 0.46f, s * 0.96f, s * 0.96f);
                        else
                            for (int a = 0; a < 360; a += 45)   // the 8 directions, around the base in perspective
                            {
                                double rad = a * Math.PI / 180;
                                float ax = cx + (float)Math.Cos(rad) * s * 0.56f, ay = cy + s * 0.27f + (float)Math.Sin(rad) * s * 0.2f;
                                float dr = lw * (a == 90 || a == 270 ? 0 : 0.95f);   // front and back would sit on the shaft: skipped
                                if (dr > 0) g.FillEllipse(fill, ax - dr, ay - dr, dr * 2, dr * 2);
                            }
                        break;
                    }
                case "lightgun":
                    {
                        float rr = s * 0.4f;
                        g.DrawEllipse(pen, cx - rr, cy - rr, rr * 2, rr * 2);
                        g.DrawEllipse(pen, cx - rr * 0.45f, cy - rr * 0.45f, rr * 0.9f, rr * 0.9f);
                        g.DrawLine(pen, cx - rr * 1.2f, cy, cx - rr * 0.6f, cy); g.DrawLine(pen, cx + rr * 0.6f, cy, cx + rr * 1.2f, cy);
                        g.DrawLine(pen, cx, cy - rr * 1.2f, cx, cy - rr * 0.6f); g.DrawLine(pen, cx, cy + rr * 0.6f, cx, cy + rr * 1.2f);
                        g.FillEllipse(fill, cx - lw * 1.4f, cy - lw * 1.4f, lw * 2.8f, lw * 2.8f);
                        break;
                    }
                case "mouse":
                    {
                        var body = new RectangleF(cx - s * 0.24f, cy - s * 0.38f, s * 0.48f, s * 0.76f);
                        using (var p = Round(body, (int)(s * 0.24f))) g.DrawPath(pen, p);
                        g.DrawLine(pen, cx, body.Y, cx, cy - s * 0.08f);
                        g.FillEllipse(fill, cx - lw, cy - s * 0.27f, lw * 2, s * 0.12f);
                        break;
                    }
                case "wheel":
                    {
                        float rr = s * 0.42f;
                        g.DrawEllipse(pen, cx - rr, cy - rr, rr * 2, rr * 2);
                        g.FillEllipse(fill, cx - rr * 0.22f, cy - rr * 0.22f, rr * 0.44f, rr * 0.44f);
                        g.DrawLine(pen, cx - rr, cy, cx - rr * 0.22f, cy); g.DrawLine(pen, cx + rr * 0.22f, cy, cx + rr, cy); g.DrawLine(pen, cx, cy + rr * 0.22f, cx, cy + rr);
                        break;
                    }
                case "flightstick":
                    {
                        g.DrawEllipse(pen, cx - s * 0.38f, cy + s * 0.2f, s * 0.76f, s * 0.2f);
                        g.DrawLine(pen, cx, cy + s * 0.28f, cx - s * 0.04f, cy - s * 0.1f);
                        var grip = new RectangleF(cx - s * 0.14f, cy - s * 0.42f, s * 0.24f, s * 0.36f);
                        using (var p = Round(grip, (int)(s * 0.1f))) { g.FillPath(fill, p); g.DrawPath(pen, p); }
                        g.DrawLine(pen, cx - s * 0.16f, cy - s * 0.2f, cx - s * 0.24f, cy - s * 0.16f);   // the trigger
                        break;
                    }
                case "gamepad":
                    {
                        var body = new RectangleF(cx - s * 0.46f, cy - s * 0.2f, s * 0.92f, s * 0.44f);
                        using (var p = Round(body, (int)(s * 0.2f))) g.DrawPath(pen, p);
                        g.DrawLine(pen, cx - s * 0.3f, cy, cx - s * 0.14f, cy); g.DrawLine(pen, cx - s * 0.22f, cy - s * 0.08f, cx - s * 0.22f, cy + s * 0.08f);
                        g.FillEllipse(fill, cx + s * 0.16f, cy - s * 0.08f, s * 0.08f, s * 0.08f); g.FillEllipse(fill, cx + s * 0.26f, cy + s * 0.0f, s * 0.08f, s * 0.08f);
                        break;
                    }
                default:
                    g.DrawRectangle(pen, cx - s * 0.3f, cy - s * 0.3f, s * 0.6f, s * 0.6f);
                    break;
            }
    }

    // James: "show the button icons to press hovering floating above the choice ... and left and right stick ... when
    // moving don't show them till it comes to rest": a "1 PLAY" button bobbing above the chosen tile, stick arrows at
    // its sides (only where there is somewhere to go)
    void DrawFloatingHints(Graphics g, Rectangle r, float t)
    {
        int a = (int)(255 * Math.Min(1f, hintA));
        float bob = (float)Math.Sin(t * 3.2) * Height * 0.004f, rise = (1 - hintA) * Height * 0.012f;
        using (var f = new Font(th.Family, Height * 0.024f, FontStyle.Bold, GraphicsUnit.Pixel))
        {
            float btn = f.Height * 1.3f, tw = g.MeasureString(PickWord, f).Width;
            float pw = btn + 14 + tw + 26, ph = btn + 12, px = r.X + (r.Width - pw) / 2, py = r.Y - ph - Height * 0.022f + bob + rise;
            var pill = new RectangleF(px, py, pw, ph);
            using (var glow = new SolidBrush(Color.FromArgb(a / 5, th.Warm))) using (var gp = Round(new RectangleF(px - 5, py - 5, pw + 10, ph + 10), (int)(ph / 2) + 5)) g.FillPath(glow, gp);
            using (var bg = new SolidBrush(Color.FromArgb(a * 220 / 255, 10, 12, 20))) using (var pp = Round(pill, (int)(ph / 2))) g.FillPath(bg, pp);
            using (var pen = new Pen(Color.FromArgb(a, th.Warm), 2f)) using (var pp = Round(pill, (int)(ph / 2))) g.DrawPath(pen, pp);
            float bx = px + 7, by = py + 6;
            using (var path = new GraphicsPath())
            {
                path.AddEllipse(bx, by, btn, btn);
                using (var pg = new PathGradientBrush(path) { CenterPoint = new PointF(bx + btn * 0.38f, by + btn * 0.3f), CenterColor = Color.FromArgb(a, 255, 255, 255), SurroundColors = new[] { Color.FromArgb(a, th.Warm) } }) g.FillPath(pg, path);
            }
            using (var bf = new Font(th.Family, btn * 0.5f, FontStyle.Bold, GraphicsUnit.Pixel)) using (var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
            using (var ink = new SolidBrush(Color.FromArgb(a, 0, 0, 0))) g.DrawString("1", bf, ink, new RectangleF(bx, by, btn, btn), fmt);
            using (var tb = new SolidBrush(Color.FromArgb(a, 255, 255, 255))) using (var fmt = new StringFormat { LineAlignment = StringAlignment.Center })
                g.DrawString(PickWord, f, tb, new RectangleF(bx + btn + 12, py, tw + 10, ph), fmt);
        }
        // stick arrows either side, nudging outwards
        float s = Height * 0.022f, nudge = (float)(0.5 + 0.5 * Math.Sin(t * 4.0)) * s * 0.4f, cy = r.Y + r.Height / 2f;
        using (var br = new SolidBrush(Color.FromArgb(a * 220 / 255, th.Accent)))
        {
            if (sel > 0) { float x = r.X - Height * 0.03f - nudge; g.FillPolygon(br, new[] { new PointF(x - s, cy), new PointF(x, cy - s), new PointF(x, cy + s) }); }
            if (sel < choices.Count - 1) { float x = r.Right + Height * 0.03f + nudge; g.FillPolygon(br, new[] { new PointF(x + s, cy), new PointF(x, cy - s), new PointF(x, cy + s) }); }
        }
    }

    void DrawHint(Graphics g, float y)
    {
        using (var f = new Font(th.Family, Height * 0.022f, FontStyle.Bold, GraphicsUnit.Pixel))
        {
            string a = "STICK  TO CHOOSE", b = PickWord, c = string.Format("  -  {0}", Math.Max(0, (leftMs + 999) / 1000));
            float wa = g.MeasureString(a, f).Width, wb = g.MeasureString(b, f).Width, wc = g.MeasureString(c, f).Width, btn = f.Height * 1.25f;
            float total = wa + 40 + btn + 10 + wb + wc, x = (Width - total) / 2;
            using (var dim = new SolidBrush(Color.FromArgb(210, th.Dim))) g.DrawString(a, f, dim, x, y);
            x += wa + 40;
            // button 1, drawn as an arcade button in the theme's warm colour
            using (var path = new GraphicsPath())
            {
                path.AddEllipse(x, y - btn * 0.08f, btn, btn);
                using (var pg = new PathGradientBrush(path) { CenterPoint = new PointF(x + btn * 0.38f, y + btn * 0.3f), CenterColor = Color.White, SurroundColors = new[] { th.Warm } }) g.FillPath(pg, path);
            }
            using (var bf = new Font(th.Family, btn * 0.5f, FontStyle.Bold, GraphicsUnit.Pixel)) using (var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                g.DrawString("1", bf, Brushes.Black, new RectangleF(x, y - btn * 0.08f, btn, btn), fmt);
            x += btn + 10;
            g.DrawString(b, f, Brushes.White, x, y); x += wb;
            using (var dim = new SolidBrush(Color.FromArgb(160, th.Dim))) g.DrawString(c, f, dim, x, y);
        }
    }

    // ---------------------------------------------------------------- helpers
    void Centered(Graphics g, string s, Font f, Color c, float y, bool shadow)
    {
        var sz = g.MeasureString(s, f); float x = (Width - sz.Width) / 2;
        if (shadow) using (var sb = new SolidBrush(Color.FromArgb(150, 0, 0, 0))) g.DrawString(s, f, sb, x + 2, y + 3);
        using (var b = new SolidBrush(c)) g.DrawString(s, f, b, x, y);
    }

    static string Spaced(string s) { return string.Join(" ", s.ToCharArray()).Replace(" ", "  "); }

    static Color Mix(Color a, Color b, float k) { return Color.FromArgb((int)(a.R + (b.R - a.R) * k), (int)(a.G + (b.G - a.G) * k), (int)(a.B + (b.B - a.B) * k)); }

    static GraphicsPath Round(RectangleF r, int rad)
    {
        var p = new GraphicsPath(); float d = Math.Max(1, Math.Min(rad * 2, Math.Min(r.Width, r.Height)));
        p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure(); return p;
    }
}
