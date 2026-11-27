// AmPanel - drives the Pixelcade LED marquee board itself, over its USB serial port, so the Java listener (pixelweb)
// is no longer needed (James, day one: "consume and replace the pixelcade listener"; docs/21: one program).
//
// The board is a PIXEL (IOIO) board; the protocol is the open-source one in alinke/PIXEL (ioio-commons, IOIOProtocol /
// RgbLedMatrixImpl / IOIOImpl):
//   the board says hello on connect: 0x00 'I' 'O' 'I' 'O' hardware[8] bootloader[8] firmware[8]   (PIXL0025 IOIO0401 PIXL0010)
//   interface check: 0x02 "YTAI0002" -> 0x02 <bit 0 = supported>
//   matrix on: 0x1E <shifter chains | 0x10 for 16-row scan>  (ADAFRUIT_128x32 = 4 chains: 0x14); off: 0x1E 0x10
//   frame: 0x1F + 6144 bytes: 3 bit-planes of 2048 bytes; each byte = one bit of r,g,b for the pixel at y (bits 5..3)
//          and at y+16 (bits 2..0); plane k = bit k of each channel's top 3 bits (RgbLedMatrixImpl.convertAdafruit)
// Tested on the 2P stand-up's 128x32 board (2026-11-27). Only the 128x32 Adafruit kind (Pixelcade "matrix type 15").
//
// Art, as the listener finds it: <Pixelcade>\<folder>\<game>.gif / .png (folder from console.csv, e.g. arcade -> mame),
// then <Pixelcade>\console\<folder>.gif / .png, default-<folder>, default-marquee; else the title scrolls as text.
// A newer event replaces whatever is playing; a one-time item (text) goes back to the last held picture when done.
// C# 5.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.IO;
using System.IO.Ports;
using System.Linq;
using System.Threading;

class PixelDirect
{
    public const int W = 128, H = 32;
    readonly string dir, portName;
    readonly Action<string> log;
    SerialPort sp;
    readonly object gate = new object();
    readonly AutoResetEvent wake = new AutoResetEvent(false);
    List<Item> next;                 // the newest sequence, waiting for the player
    Item held;                       // the last held picture: shown again after one-time items
    Dictionary<string, string> folders;
    readonly Random rnd = new Random();
    public string Board, LastError;
    public int Frames;

    class Item { public List<byte[]> Frames = new List<byte[]>(); public List<int> Delays = new List<int>(); public int Loops; public string What; }   // Loops -1 = hold

    public PixelDirect(string pixelcadeDir, string port, Action<string> log)
    {
        dir = pixelcadeDir; portName = port; this.log = log ?? delegate { };
    }

    // the port named in <Pixelcade>\settings.ini (port=COM7)
    public static string PortFromSettings(string pixelcadeDir)
    {
        try
        {
            string ini = Path.Combine(pixelcadeDir ?? "", "settings.ini");
            if (File.Exists(ini)) foreach (var l in File.ReadAllLines(ini)) { var t = l.Trim(); if (t.StartsWith("port=", StringComparison.OrdinalIgnoreCase)) return t.Substring(5).Trim(); }
        }
        catch { }
        return null;
    }

    public bool Open()
    {
        try
        {
            sp = new SerialPort(portName, 115200) { DtrEnable = true, RtsEnable = true, ReadTimeout = 3000, WriteTimeout = 5000 };
            sp.Open();
            var hello = ReadExactly(29);
            if (hello == null || hello[0] != 0 || hello[1] != 'I' || hello[4] != 'O') { LastError = "no hello from the board on " + portName; Close(); return false; }
            Board = Txt(hello, 5, 8) + " / " + Txt(hello, 21, 8);
            sp.Write(new byte[] { 0x02, (byte)'Y', (byte)'T', (byte)'A', (byte)'I', (byte)'0', (byte)'0', (byte)'0', (byte)'2' }, 0, 9);
            int b; do { b = sp.ReadByte(); } while (b != 0x02);
            if ((sp.ReadByte() & 1) == 0) { LastError = "the board does not support interface YTAI0002"; Close(); return false; }
            sp.ReadTimeout = SerialPort.InfiniteTimeout;
            new Thread(Drain) { IsBackground = true, Name = "pixel-in" }.Start();
            sp.Write(new byte[] { 0x1E, 0x14 }, 0, 2);
            new Thread(Player) { IsBackground = true, Name = "pixel-out" }.Start();
            log("marquee: Pixelcade board " + Board + " on " + portName + ", driven by AmPanel (no listener)");
            return true;
        }
        catch (Exception e) { LastError = portName + ": " + e.Message; Close(); return false; }
    }

    public void Close()
    {
        try { if (sp != null && sp.IsOpen) { sp.Write(new byte[] { 0x1E, 0x10 }, 0, 2); sp.Close(); } } catch { }
        sp = null;
    }

    void Drain() { var b = new byte[256]; try { while (sp != null && sp.IsOpen) sp.BaseStream.Read(b, 0, b.Length); } catch { } }   // the board reports things; never let them pile up

    // ---------------------------------------------------------------- what to show
    public void Game(string system, string game, string altText, bool hold) { Play(new List<Item> { GameItem(system, game, altText, hold ? -1 : -1) }); }
    // ---------------------------------------------------------------- game start: an intro, then the game's marquee held
    // James: "show a neat animation for loading and the game name somehow", then "make other types of intros like that..
    // easier bigger fonts .. the logo after and then animations is awesome". Every intro ends the same way: a flash that
    // cross-fades into the game's own marquee, which then plays (GIF) for the whole game. AmPanel.json "MarqueeIntro":
    // "random" (default) or one of sweep | punch | drop | warp | doors | slot | explode | neon | type.
    public string Intro = "random";
    static readonly string[] Intros = { "sweep", "punch", "drop", "warp", "doors", "slot", "explode", "neon", "type" };
    static readonly Color NeonA = Color.FromArgb(0, 229, 255), NeonB = Color.FromArgb(255, 45, 160);   // cyan -> magenta

    public void GameStart(string system, string game, string title, Color c)
    {
        var art = GameItem(system, game, game, -1);
        string file = FindArt(Folder(system), game) ?? FindArt("mame", game) ?? FrontendArt(system, game, "marquee") ?? FrontendArt(system, game, "logo");
        Bitmap first = null;
        try { if (file != null) using (var img = Image.FromFile(file)) { first = new Bitmap(W, H); using (var g = Graphics.FromImage(first)) { g.Clear(Color.Black); g.DrawImage(img, 0, 0, W, H); } } } catch { first = null; }
        string style = Intro;
        if (Array.IndexOf(Intros, style) < 0) lock (rnd) style = Intros[rnd.Next(Intros.Length)];
        Item intro;
        try { intro = IntroItem(style, ShortTitle(string.IsNullOrWhiteSpace(title) ? game : title), first); }
        catch (Exception e) { log("marquee: intro " + style + " failed - " + e.Message); intro = null; }
        if (first != null) first.Dispose();
        var seq = new List<Item>(); if (intro != null) seq.Add(intro); seq.Add(art);
        Play(seq);
    }

    // short enough for 128 x 32 LEDs: no "(USA)" / "(World 4 Players)" / "[!]", no subtitle after " - " or ": " when the rest is long
    public static string ShortTitle(string t)
    {
        t = System.Text.RegularExpressions.Regex.Replace(t ?? "", @"\s*[\(\[][^\)\]]*[\)\]]", "").Trim();
        foreach (var sep in new[] { " - ", ": " }) { int i = t.IndexOf(sep, StringComparison.Ordinal); if (i > 3 && t.Length > 18) t = t.Substring(0, i).Trim(); }
        if (t.EndsWith(", The", StringComparison.OrdinalIgnoreCase)) t = "The " + t.Substring(0, t.Length - 5);
        return t.ToUpperInvariant();
    }

    delegate void Scene(Graphics g, float t, Bitmap title);
    static Item IntroItem(string style, string title, Bitmap art)
    {
        var it = new Item { Loops = 1, What = "intro " + style + ": " + title };
        using (var tb = TitleBitmap(title, NeonA, NeonB))
        {
            int main = 80;   // the intro itself (25 ms frames = 2 s), then the shared 0.6 s flash into the marquee
            Scene scene;
            switch (style)
            {
                case "punch": scene = Punch; break;
                case "drop": scene = (g, t, b) => Drop(g, t, title); break;
                case "warp": scene = Warp; break;
                case "doors": scene = Doors; break;
                case "slot": scene = (g, t, b) => Slot(g, t, title); break;
                case "explode": scene = Explode; break;
                case "neon": scene = Neon; break;
                case "type": scene = (g, t, b) => Typewriter(g, t, title); break;
                default: scene = Sweep; break;
            }
            for (int f = 0; f < main; f++) it.Frames.Add(Render(g => scene(g, f / (float)(main - 1), tb)));
            for (int f = 0; f < 24; f++) { float t = f / 23f; it.Frames.Add(Render(g => FlashTo(g, t, tb, art))); }
            foreach (var x in it.Frames) it.Delays.Add(25);
        }
        return it;
    }

    static byte[] Render(Action<Graphics> draw)
    {
        using (var bmp = new Bitmap(W, H))
        {
            using (var g = Graphics.FromImage(bmp)) { g.Clear(Color.Black); g.SmoothingMode = SmoothingMode.AntiAlias; draw(g); }
            return Convert(bmp);
        }
    }

    static float Ease(float t) { t = Math.Max(0, Math.Min(1, t)); return 1 - (1 - t) * (1 - t) * (1 - t); }   // ease-out cubic

    // 1. a CRT power-on line, then the title revealed by a bright sweep, a loading bar under it
    static void Sweep(Graphics g, float t, Bitmap title)
    {
        if (t < 0.22f)
        {
            float k = t / 0.22f, h = Math.Max(1, H * k * k);
            using (var br = new LinearGradientBrush(new RectangleF(0, 0, W, H), NeonA, NeonB, 0f)) g.FillRectangle(br, 0, H / 2f - h / 2, W, h);
            int core = Math.Max(1, (int)(h / 3)); using (var wb = new SolidBrush(Color.FromArgb((int)(255 * (1 - k * 0.6f)), 255, 255, 255))) g.FillRectangle(wb, 0, H / 2f - core / 2f, W, core);
            return;
        }
        float s = (t - 0.22f) / 0.78f, sweep = -20 + s * (W + 40);
        g.SetClip(new RectangleF(0, 0, Math.Max(0, sweep), H)); g.DrawImageUnscaled(title, 0, 0); g.ResetClip();
        for (int dx = -6; dx <= 6; dx++) using (var p = new Pen(Color.FromArgb((int)(200 * (1 - Math.Abs(dx) / 7f)), 255, 255, 255))) g.DrawLine(p, sweep + dx, 0, sweep + dx - 6, H);
        using (var br = new LinearGradientBrush(new Rectangle(0, H - 2, W, 2), NeonA, NeonB, 0f)) g.FillRectangle(br, 0, H - 2, Math.Max(1, (int)(W * Math.Min(1f, s * 1.05f))), 2);
    }

    // 2. the title flies in huge from the screen, lands with a shake and a flash
    static void Punch(Graphics g, float t, Bitmap title)
    {
        float land = 0.45f;
        if (t < land)
        {
            float k = Ease(t / land), scale = 4.5f - 3.5f * k;
            float w = W * scale, h = H * scale;
            g.InterpolationMode = InterpolationMode.NearestNeighbor;
            using (var ia = new ImageAttributes()) { ia.SetColorMatrix(new ColorMatrix { Matrix33 = 0.35f + 0.65f * k }); g.DrawImage(title, new Rectangle((int)((W - w) / 2), (int)((H - h) / 2), (int)w, (int)h), 0, 0, W, H, GraphicsUnit.Pixel, ia); }
            return;
        }
        float a = (t - land) / (1 - land);
        int shake = a < 0.25f ? (int)Math.Round(Math.Sin(a * 90) * 3 * (1 - a * 4)) : 0;
        g.DrawImageUnscaled(title, shake, 0);
        if (a < 0.15f) using (var wb = new SolidBrush(Color.FromArgb((int)(200 * (1 - a / 0.15f)), 255, 255, 255))) g.FillRectangle(wb, 0, 0, W, H);
        // two speed lines stream past under the landed title
        using (var p = new Pen(Color.FromArgb(90, NeonA))) { float x = (a * 900) % (W + 40) - 20; g.DrawLine(p, x, 2, x + 18, 2); g.DrawLine(p, W - x, H - 3, W - x - 18, H - 3); }
    }

    // 3. the letters fall in one by one and bounce into place
    static void Drop(Graphics g, float t, string title)
    {
        string[] lines; Font font = FitFont(g, title, out lines);
        using (font)
        using (var fill = new LinearGradientBrush(new Rectangle(0, 0, W, H), NeonA, NeonB, 0f))
        {
            int total = Math.Max(1, title.Replace(" ", "").Length), n = 0;
            float lh = font.Height, top = (H - lh * lines.Length) / 2f;
            g.TextRenderingHint = TextRenderingHint.SingleBitPerPixelGridFit;
            using (var fmt = StringFormat.GenericTypographic)
                for (int li = 0; li < lines.Length; li++)
                {
                    string line = lines[li];
                    float lw = g.MeasureString(line, font, W * 4, fmt).Width, x = (W - lw) / 2f, y0 = top + li * lh;
                    foreach (char ch in line)
                    {
                        string s = ch.ToString(); float cw = g.MeasureString(s, font, W, fmt).Width; if (ch == ' ') cw = font.Size * 0.3f;
                        if (ch != ' ')
                        {
                            float start = n / (float)total * 0.6f, k = Math.Max(0, Math.Min(1, (t - start) / 0.3f)); n++;
                            if (k > 0)
                            {
                                // fall from above, one small bounce
                                float drop = k < 0.7f ? (1 - Ease(k / 0.7f)) * -(H + 4) : (float)Math.Sin((k - 0.7f) / 0.3f * Math.PI) * -3;
                                g.DrawString(s, font, Brushes.Black, x + 1, y0 + drop + 1, fmt);
                                g.DrawString(s, font, fill, x, y0 + drop, fmt);
                            }
                        }
                        x += cw;
                    }
                }
        }
    }

    // 4. a starfield rushes outward; the title fades in from the centre
    static void Warp(Graphics g, float t, Bitmap title)
    {
        var r = new Random(7);
        float speed = 0.2f + 2.5f * t;
        for (int i = 0; i < 70; i++)
        {
            double ang = r.NextDouble() * Math.PI * 2; float d0 = (float)r.NextDouble();
            float d = (d0 + t * speed) % 1f, len = 2 + d * 10 * speed;
            float cx = W / 2f, cy = H / 2f, x1 = cx + (float)Math.Cos(ang) * d * 70, y1 = cy + (float)Math.Sin(ang) * d * 24;
            float x2 = cx + (float)Math.Cos(ang) * (d * 70 + len), y2 = cy + (float)Math.Sin(ang) * (d * 24 + len * 0.35f);
            using (var p = new Pen(Color.FromArgb((int)(80 + 175 * d), i % 3 == 0 ? NeonB : i % 3 == 1 ? NeonA : Color.White))) g.DrawLine(p, x1, y1, x2, y2);
        }
        if (t > 0.45f)
        {
            float k = Ease((t - 0.45f) / 0.45f), s = 0.3f + 0.7f * k;
            using (var ia = new ImageAttributes()) { ia.SetColorMatrix(new ColorMatrix { Matrix33 = k }); g.DrawImage(title, new Rectangle((int)(W * (1 - s) / 2), (int)(H * (1 - s) / 2), (int)(W * s), (int)(H * s)), 0, 0, W, H, GraphicsUnit.Pixel, ia); }
        }
    }

    // 5. two neon doors slide apart and reveal the title
    static void Doors(Graphics g, float t, Bitmap title)
    {
        g.DrawImageUnscaled(title, 0, 0);
        float k = t < 0.25f ? 0 : Ease((t - 0.25f) / 0.6f), half = W / 2f * (1 - k);
        using (var br = new LinearGradientBrush(new RectangleF(0, 0, W, H), Color.FromArgb(20, 30, 60), Color.FromArgb(50, 10, 40), 90f))
        {
            g.FillRectangle(br, 0, 0, half, H); g.FillRectangle(br, W - half, 0, half, H);
        }
        using (var pa = new Pen(NeonA, 2)) using (var pb = new Pen(NeonB, 2)) { g.DrawLine(pa, half - 1, 0, half - 1, H); g.DrawLine(pb, W - half, 0, W - half, H); }
        if (t < 0.25f) { int a = (int)(255 * (0.5 + 0.5 * Math.Sin(t * 60))); using (var p = new Pen(Color.FromArgb(a, 255, 255, 255))) g.DrawLine(p, W / 2f, 4, W / 2f, H - 4); }   // the seam glows before they open
    }

    // draws the title letter by letter (each letter's text and x from the same font and layout as the others)
    delegate void LetterFn(Graphics g, Font font, Brush fill, string letter, float x, float y, int index, int total);
    static void Letters(Graphics g, string title, LetterFn each)
    {
        string[] lines; var font = FitFont(g, title, out lines);
        using (font)
        using (var fill = new LinearGradientBrush(new Rectangle(0, 0, W, H), NeonA, NeonB, 0f))
        using (var fmt = StringFormat.GenericTypographic)
        {
            g.TextRenderingHint = TextRenderingHint.SingleBitPerPixelGridFit;
            int total = Math.Max(1, title.Replace(" ", "").Length), n = 0;
            float lh = font.Height, top = (H - lh * lines.Length) / 2f;
            for (int li = 0; li < lines.Length; li++)
            {
                string line = lines[li];
                float lw = g.MeasureString(line, font, W * 4, fmt).Width, x = (W - lw) / 2f, y = top + li * lh;
                foreach (char ch in line)
                {
                    string s = ch.ToString(); float cw = ch == ' ' ? font.Size * 0.3f : g.MeasureString(s, font, W, fmt).Width;
                    if (ch != ' ') each(g, font, fill, s, x, y, n++, total);
                    x += cw;
                }
            }
        }
    }

    // 6. slot machine: every letter spins through the alphabet and stops on its own, left to right
    static void Slot(Graphics g, float t, string title)
    {
        Letters(g, title, (gg, font, fill, s, x, y, i, total) =>
        {
            float stop = 0.25f + 0.6f * i / total;
            if (t >= stop) { gg.DrawString(s, font, Brushes.Black, x + 1, y + 1, StringFormat.GenericTypographic); gg.DrawString(s, font, fill, x, y, StringFormat.GenericTypographic); return; }
            const string reel = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
            float roll = t * 60 + i * 7; int k = (int)roll % reel.Length; float off = (roll - (int)roll) * font.Height;
            var clip = gg.Clip; gg.SetClip(new RectangleF(x - 1, y, font.Size, font.Height));
            using (var dim = new SolidBrush(Color.FromArgb(150, 255, 255, 255)))
            {
                gg.DrawString(reel[k].ToString(), font, dim, x, y - off, StringFormat.GenericTypographic);
                gg.DrawString(reel[(k + 1) % reel.Length].ToString(), font, dim, x, y - off + font.Height, StringFormat.GenericTypographic);
            }
            gg.Clip = clip;
        });
    }

    // 7. pixel explosion run backwards: coloured pixels fly in from everywhere and settle into the title
    static void Explode(Graphics g, float t, Bitmap title)
    {
        var rnd = new Random(11);
        float k = Ease(Math.Min(1f, t / 0.8f));
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++)
            {
                var c = title.GetPixel(x, y);
                if (c.R + c.G + c.B < 60) continue;
                double ang = rnd.NextDouble() * Math.PI * 2, dist = 40 + rnd.NextDouble() * 120;
                float px = x + (float)(Math.Cos(ang) * dist * (1 - k)), py = y + (float)(Math.Sin(ang) * dist * 0.4 * (1 - k));
                using (var br = new SolidBrush(k < 1 ? Color.FromArgb(255, Math.Min(255, c.R + (int)(120 * (1 - k))), c.G, Math.Min(255, c.B + (int)(80 * (1 - k)))) : c)) g.FillRectangle(br, px, py, 1, 1);
            }
        if (t > 0.8f) { float a = (t - 0.8f) / 0.2f; using (var ia = new ImageAttributes()) { ia.SetColorMatrix(new ColorMatrix { Matrix33 = a }); g.DrawImage(title, new Rectangle(0, 0, W, H), 0, 0, W, H, GraphicsUnit.Pixel, ia); } }
    }

    // 8. a neon sign switching on: dark tubes, flicker, a dim hum, then full glow
    static void Neon(Graphics g, float t, Bitmap title)
    {
        float[] steps = { 0.08f, 0, 0.6f, 0.05f, 0, 0.9f, 0.3f, 0.95f, 0.4f, 1, 1, 1, 1, 1, 1, 1 };
        float level = t < 0.15f ? 0.08f : steps[Math.Min(steps.Length - 1, (int)((t - 0.15f) / 0.85f * steps.Length * 1.4f))];
        using (var ia = new ImageAttributes())
        {
            ia.SetColorMatrix(new ColorMatrix { Matrix33 = Math.Max(0.06f, level) });
            g.DrawImage(title, new Rectangle(0, 0, W, H), 0, 0, W, H, GraphicsUnit.Pixel, ia);
            if (level >= 0.9f)   // the glow: the title once more, a pixel up and down, faint
            {
                ia.SetColorMatrix(new ColorMatrix { Matrix33 = 0.25f });
                g.DrawImage(title, new Rectangle(0, -1, W, H), 0, 0, W, H, GraphicsUnit.Pixel, ia);
                g.DrawImage(title, new Rectangle(0, 1, W, H), 0, 0, W, H, GraphicsUnit.Pixel, ia);
            }
        }
    }

    // 9. typewriter: letters appear one at a time behind a blinking cursor
    static void Typewriter(Graphics g, float t, string title)
    {
        float shownUpTo = Math.Min(1f, t / 0.75f);
        float cursorX = -1, cursorY = 0, cursorH = 0;
        Letters(g, title, (gg, font, fill, s, x, y, i, total) =>
        {
            if (i / (float)total > shownUpTo) return;
            gg.DrawString(s, font, Brushes.Black, x + 1, y + 1, StringFormat.GenericTypographic);
            gg.DrawString(s, font, fill, x, y, StringFormat.GenericTypographic);
            cursorX = x + gg.MeasureString(s, font, W, StringFormat.GenericTypographic).Width + 1; cursorY = y + 2; cursorH = font.Height - 4;
        });
        if ((int)(t * 8) % 2 == 0) using (var br = new SolidBrush(Color.White)) g.FillRectangle(br, cursorX < 0 ? 4 : cursorX, cursorX < 0 ? 6 : cursorY, 3, cursorH > 0 ? cursorH : H - 12);
    }

    // shared ending: a white flash that cross-fades into the game's marquee
    static void FlashTo(Graphics g, float t, Bitmap title, Bitmap art)
    {
        g.DrawImageUnscaled(title, 0, 0);
        if (art != null) using (var ia = new ImageAttributes()) { ia.SetColorMatrix(new ColorMatrix { Matrix33 = Math.Min(1f, t * 1.4f) }); g.DrawImage(art, new Rectangle(0, 0, W, H), 0, 0, W, H, GraphicsUnit.Pixel, ia); }
        int white = (int)(230 * Math.Max(0, 1 - t * 2.5f));
        if (white > 0) using (var wb = new SolidBrush(Color.FromArgb(white, 255, 255, 255))) g.FillRectangle(wb, 0, 0, W, H);
    }

    // the heaviest font the PC has: Impact, then Arial Black, then Arial Bold
    static string family;
    static string Family()
    {
        if (family != null) return family;
        using (var fonts = new InstalledFontCollection())
            foreach (var want in new[] { "Impact", "Arial Black", "Arial" })
                if (fonts.Families.Any(f => f.Name.Equals(want, StringComparison.OrdinalIgnoreCase))) return family = want;
        return family = "Arial";
    }

    // as big as fits: one line up to 30 px, else two lines split at the space nearest the middle
    static Font FitFont(Graphics g, string text, out string[] lines)
    {
        var style = Family() == "Arial" ? FontStyle.Bold : FontStyle.Regular;
        lines = new[] { text };
        for (int size = 30; size >= 10; size--)
        {
            var f = new Font(Family(), size, style, GraphicsUnit.Pixel);
            if (g.MeasureString(text, f, W * 4, StringFormat.GenericTypographic).Width <= W - 4 && f.Height <= H + 2) return f;
            f.Dispose();
        }
        int mid = text.Length / 2, cut = -1;
        for (int d = 0; d < mid && cut < 0; d++) { if (mid + d < text.Length && text[mid + d] == ' ') cut = mid + d; else if (text[mid - d] == ' ') cut = mid - d; }
        if (cut > 0) lines = new[] { text.Substring(0, cut).Trim(), text.Substring(cut + 1).Trim() };
        for (int size = 17; size >= 7; size--)
        {
            var f = new Font(Family(), size, style, GraphicsUnit.Pixel);
            string[] ls = lines;
            if (ls.All(l => g.MeasureString(l, f, W * 4, StringFormat.GenericTypographic).Width <= W - 2) && f.Height * ls.Length <= H + 2) return f;
            f.Dispose();
        }
        return new Font(Family(), 7, style, GraphicsUnit.Pixel);
    }

    // the title, as big as fits, cyan -> magenta with a dark outline, crisp on the LEDs
    static Bitmap TitleBitmap(string text, Color a, Color b)
    {
        var bmp = new Bitmap(W, H);
        using (var g = Graphics.FromImage(bmp))
        {
            g.Clear(Color.Black); g.TextRenderingHint = TextRenderingHint.SingleBitPerPixelGridFit;
            string[] lines; var font = FitFont(g, text, out lines);
            using (font)
            using (var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
            using (var fill = new LinearGradientBrush(new Rectangle(0, 0, W, H), a, b, 0f))
            {
                float lh = Math.Min(font.Height, H / (float)lines.Length + 2), top = (H - lh * lines.Length) / 2f;
                for (int i = 0; i < lines.Length; i++)
                {
                    var r = new RectangleF(-4, top + i * lh, W + 8, lh);
                    foreach (var o in new[] { new PointF(-1, 0), new PointF(1, 0), new PointF(0, -1), new PointF(0, 1) })
                        g.DrawString(lines[i], font, Brushes.Black, new RectangleF(r.X + o.X, r.Y + o.Y, r.Width, r.Height), fmt);
                    g.DrawString(lines[i], font, fill, r, fmt);
                }
            }
        }
        return bmp;
    }
    public void Console(string system, string altText) { Play(new List<Item> { ConsoleItem(system, altText) }); }
    public void Text(string text, Color c) { var t = TextItem(text, c, 1); if (t != null) Play(new List<Item> { t }); }
    public void RandomAnimation()
    {
        var all = new List<string>();
        foreach (var d in new[] { Path.Combine(dir, "animations"), Path.Combine(dir, "animations", "gifsource") })
            if (Directory.Exists(d)) all.AddRange(Directory.GetFiles(d, "*.gif"));
        if (all.Count == 0) return;
        string f; lock (rnd) f = all[rnd.Next(all.Count)];
        var it = FileItem(f, -1); if (it != null) Play(new List<Item> { it });
    }
    public void Black() { Play(new List<Item> { Solid(Color.Black, -1) }); }

    void Play(List<Item> seq) { lock (gate) next = seq; wake.Set(); }

    // ---------------------------------------------------------------- art
    string Folder(string system)
    {
        if (folders == null)
        {
            folders = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            try { foreach (var l in File.ReadAllLines(Path.Combine(dir, "console.csv"))) { var p = l.Split(','); if (p.Length >= 2 && p[0].Trim().Length > 0 && !folders.ContainsKey(p[0].Trim())) folders[p[0].Trim()] = p[1].Trim(); } } catch { }
        }
        if (string.IsNullOrEmpty(system)) return "mame";
        string s = system.Trim(), m;
        if (folders.TryGetValue(s, out m) || folders.TryGetValue(s.Replace(' ', '_'), out m) || folders.TryGetValue(s.Replace(' ', '-'), out m)) return m;
        foreach (var c in new[] { s, s.Replace(' ', '_') }) if (Directory.Exists(Path.Combine(dir, c))) return c;
        return s.Equals("main", StringComparison.OrdinalIgnoreCase) ? "mame" : s.Replace(' ', '_').ToLowerInvariant();
    }

    string FindArt(string folder, string name)
    {
        if (string.IsNullOrEmpty(name)) return null;
        string d = Path.Combine(dir, folder);
        if (!Directory.Exists(d)) return null;
        var gifs = new List<string>();
        foreach (var f in new[] { name + ".gif" }) if (File.Exists(Path.Combine(d, f))) gifs.Add(Path.Combine(d, f));
        try { gifs.AddRange(Directory.GetFiles(d, name + "_??.gif")); } catch { }   // pacman_01.gif ...: one at random, like the listener
        if (gifs.Count > 0) lock (rnd) return gifs[rnd.Next(gifs.Count)];
        string png = Path.Combine(d, name + ".png");
        return File.Exists(png) ? png : null;
    }

    Item GameItem(string system, string game, string altText, int loops)
    {
        string folder = Folder(system);
        string f = FindArt(folder, game) ?? FindArt("mame", game);
        if (f != null) { var it = FileItem(f, loops); if (it != null) return it; }
        // the frontend's own art for the game when the Pixelcade folders have none (James 2026-11-27, Pokken Tournament:
        // "ugly scrolling marquee - needs to be the logo"): its marquee picture, else its logo fitted to the LEDs
        f = FrontendArt(system, game, "marquee");
        if (f != null) { var it = FileItem(f, loops); if (it != null) return it; }
        f = FrontendArt(system, game, "logo");
        if (f != null) { var it = FileItem(f, loops, true); if (it != null) return it; }
        return ConsoleItem(system, altText ?? game);
    }

    // <RetroFE>\collections\<system>\medium_artwork\<kind>\<game>.png / .jpg / .gif (the frontend names the list it
    // started the game from; a list of another name is looked up in the game list, games.json, by item name)
    public string RetroFERoot;
    string FrontendArt(string system, string game, string kind)
    {
        if (string.IsNullOrEmpty(RetroFERoot) || string.IsNullOrEmpty(game) || string.IsNullOrEmpty(system)) return null;
        foreach (var ext in new[] { ".png", ".jpg", ".gif" })
        {
            string p = Path.Combine(RetroFERoot, "collections", system, "medium_artwork", kind, game + ext);
            if (File.Exists(p)) return p;
        }
        return null;
    }

    Item ConsoleItem(string system, string altText)
    {
        string folder = Folder(system);
        string f = FindArt("console", folder) ?? FindArt("console", "default-" + folder) ?? (altText == null ? FindArt("console", "default-marquee") : null);
        if (f != null) { var it = FileItem(f, -1); if (it != null) return it; }
        var t = TextItem(altText ?? folder.ToUpperInvariant(), Color.White, -1);
        if (t != null) return t;
        f = FindArt("console", "default-marquee");
        return (f != null ? FileItem(f, -1) : null) ?? Solid(Color.Black, -1);
    }

    Item FileItem(string file, int loops) { return FileItem(file, loops, false); }
    // fit: the whole picture, aspect kept, centred on black (a logo); else stretched to the 128 x 32 LEDs (a marquee)
    Item FileItem(string file, int loops, bool fit)
    {
        try
        {
            using (var img = Image.FromFile(file))
            {
                var it = new Item { Loops = loops, What = Path.GetFileName(file) };
                int n = 1; FrameDimension fd = null;
                try { fd = new FrameDimension(img.FrameDimensionsList[0]); n = img.GetFrameCount(fd); } catch { n = 1; }
                byte[] delays = null;
                try { delays = img.GetPropertyItem(0x5100).Value; } catch { }
                for (int i = 0; i < n && i < 600; i++)
                {
                    if (n > 1) img.SelectActiveFrame(fd, i);
                    using (var bmp = new Bitmap(W, H))
                    {
                        using (var g = Graphics.FromImage(bmp)) { g.InterpolationMode = img.Width == W && img.Height == H ? InterpolationMode.NearestNeighbor : InterpolationMode.HighQualityBicubic; g.Clear(Color.Black);
                            if (fit) { float k = Math.Min((float)W / img.Width, (float)H / img.Height); float w = img.Width * k, h = img.Height * k; g.DrawImage(img, (W - w) / 2, (H - h) / 2, w, h); }
                            else g.DrawImage(img, 0, 0, W, H); }
                        it.Frames.Add(Convert(bmp));
                    }
                    int ms = delays != null && delays.Length >= i * 4 + 4 ? BitConverter.ToInt32(delays, i * 4) * 10 : 0;
                    it.Delays.Add(n > 1 ? Math.Max(20, ms) : 1000);
                }
                return it;
            }
        }
        catch (Exception e) { log("marquee: could not read " + file + " - " + e.Message); return null; }
    }

    // text scrolls in from the right and out on the left, once (loops 1) or forever (-1)
    static Item TextItem(string text, Color c, int loops)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var it = new Item { Loops = loops, What = "text: " + text };
        using (var f = new Font("Arial", 20, FontStyle.Bold, GraphicsUnit.Pixel))
        using (var probe = new Bitmap(1, 1))
        using (var pg = Graphics.FromImage(probe))
        {
            int tw = (int)Math.Ceiling(pg.MeasureString(text, f).Width);
            for (int x = W; x > -tw; x -= 2)
                using (var bmp = new Bitmap(W, H))
                {
                    using (var g = Graphics.FromImage(bmp)) { g.Clear(Color.Black); g.TextRenderingHint = TextRenderingHint.SingleBitPerPixelGridFit; using (var br = new SolidBrush(c)) g.DrawString(text, f, br, x, 4); }
                    it.Frames.Add(Convert(bmp)); it.Delays.Add(30);
                }
        }
        return it;
    }

    static Item Solid(Color c, int loops)
    {
        using (var bmp = new Bitmap(W, H)) { using (var g = Graphics.FromImage(bmp)) g.Clear(c); var it = new Item { Loops = loops, What = "solid" }; it.Frames.Add(Convert(bmp)); it.Delays.Add(1000); return it; }
    }

    // ---------------------------------------------------------------- player
    void Player()
    {
        List<Item> seq = null; int idx = 0, frame = 0, loop = 0;
        while (sp != null)
        {
            List<Item> n; lock (gate) { n = next; next = null; }
            if (n != null && n.Count > 0) { seq = n; idx = 0; frame = 0; loop = 0; }
            if (seq == null || idx >= seq.Count) { wake.WaitOne(500); continue; }
            var it = seq[idx];
            if (it.Loops < 0) held = it;
            if (!Send(it.Frames[frame])) { Thread.Sleep(1000); continue; }
            int delay = it.Delays[frame];
            if (++frame >= it.Frames.Count)
            {
                frame = 0;
                if (it.Loops >= 0 && ++loop >= Math.Max(1, it.Loops))
                {
                    loop = 0; idx++;
                    // a one-time item at the end goes back to the last held picture
                    if (idx >= seq.Count && held != null && it != held) { seq = new List<Item> { held }; idx = 0; }
                }
                else if (it.Loops < 0 && it.Frames.Count == 1) { wake.WaitOne(1000); continue; }   // a still picture: nothing to refresh
            }
            wake.WaitOne(delay);
        }
    }

    bool Send(byte[] frame)
    {
        try
        {
            var msg = new byte[frame.Length + 1]; msg[0] = 0x1F; Buffer.BlockCopy(frame, 0, msg, 1, frame.Length);
            sp.Write(msg, 0, msg.Length); Frames++;
            return true;
        }
        catch (Exception e) { LastError = "write failed: " + e.Message; return false; }
    }

    // RgbLedMatrixImpl.convertAdafruit(rgb565, 128, numLogicalRows 16)
    static byte[] Convert(Bitmap bmp)
    {
        var rgb = new int[W * H];
        var data = bmp.LockBits(new Rectangle(0, 0, W, H), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try { System.Runtime.InteropServices.Marshal.Copy(data.Scan0, rgb, 0, W * H); } finally { bmp.UnlockBits(data); }
        const int pairOffset = 16, numLogicalRows = 16, subframeSize = W * H / 2;
        var dest = new byte[subframeSize * 3];
        int logicalRowLengthPerMatrix = 32 * 32 / 2 / numLogicalRows, dotPairsPerLogicalRow = W * H / numLogicalRows / 2, widthInMatrices = W / 32, totalMatrices = W * H / 1024;
        for (int x = 0; x < W; ++x)
            for (int y = 0; y < pairOffset; ++y)
            {
                int c0 = Rgb565(rgb[y * W + x]), c1 = Rgb565(rgb[(y + pairOffset) * W + x]);
                int r0 = (c0 >> 13) & 7, g0 = (c0 >> 8) & 7, b0 = (c0 >> 2) & 7, r1 = (c1 >> 13) & 7, g1 = (c1 >> 8) & 7, b1 = (c1 >> 2) & 7;
                int matrixNumber = totalMatrices - ((y / 32 + 1) * widthInMatrices) + x / 32;
                int index = (y % numLogicalRows) * dotPairsPerLogicalRow + matrixNumber * logicalRowLengthPerMatrix + x % logicalRowLengthPerMatrix;
                for (int sub = 0; sub < 3; ++sub)
                {
                    dest[sub * subframeSize + index] = (byte)((r0 & 1) << 5 | (g0 & 1) << 4 | (b0 & 1) << 3 | (r1 & 1) << 2 | (g1 & 1) << 1 | (b1 & 1));
                    r0 >>= 1; g0 >>= 1; b0 >>= 1; r1 >>= 1; g1 >>= 1; b1 >>= 1;
                }
            }
        return dest;
    }
    static int Rgb565(int argb) { int r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF; return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3); }

    byte[] ReadExactly(int n)
    {
        var b = new byte[n]; int got = 0;
        try { while (got < n) got += sp.Read(b, got, n - got); } catch (TimeoutException) { return null; }
        return b;
    }
    static string Txt(byte[] b, int o, int n) { var s = new char[n]; for (int i = 0; i < n; i++) s[i] = b[o + i] >= 32 && b[o + i] < 127 ? (char)b[o + i] : '.'; return new string(s).Trim(); }
}
