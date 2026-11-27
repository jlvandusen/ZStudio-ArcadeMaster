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
    public void GameStart(string system, string game, string nowPlaying, Color c)
    {
        var seq = new List<Item>();
        var t = TextItem(nowPlaying, c, 1); if (t != null) seq.Add(t);
        seq.Add(GameItem(system, game, game, -1));
        Play(seq);
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
        return ConsoleItem(system, altText ?? game);
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

    Item FileItem(string file, int loops)
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
                        using (var g = Graphics.FromImage(bmp)) { g.InterpolationMode = img.Width == W && img.Height == H ? InterpolationMode.NearestNeighbor : InterpolationMode.HighQualityBicubic; g.Clear(Color.Black); g.DrawImage(img, 0, 0, W, H); }
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
