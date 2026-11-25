// AmPanel - "Sticks & Guns": the graphical face of the UltraStik maps, the ServoStik restrictor and the light guns
// (replaces UltraMap, ServoStik test and a gun list in one window). Simple on the left: type a game, see the map its
// stick will get, drawn as the 9x9 grid the stick really uses; press a map to feel it on the sticks now, "Keep for this
// game" to make it this cabinet's pick. ServoStik: 4-way / 8-way now. Guns: what is plugged in.
// C# 5.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

class StickStudio : Form
{
    [DllImport("PacDrive32.dll", CallingConvention = CallingConvention.StdCall)] static extern int PacInitialize();
    [DllImport("PacDrive32.dll", CallingConvention = CallingConvention.StdCall)] static extern void PacShutdown();
    [DllImport("PacDrive32.dll", CallingConvention = CallingConvention.StdCall)] static extern bool PacSetServoStik4Way();
    [DllImport("PacDrive32.dll", CallingConvention = CallingConvention.StdCall)] static extern bool PacSetServoStik8Way();

    readonly Sticks sticks;
    readonly bool ownSticks;      // opened just for this window (the cabinet's sticks are LEDBlinky's): closed with it
    readonly object gate;
    readonly TextBox game = new TextBox { Width = 160 };
    readonly Label info = new Label { AutoSize = true, ForeColor = Color.Gainsboro, Padding = new Padding(8, 8, 0, 0) };
    readonly Label status = new Label { Dock = DockStyle.Bottom, Height = 26, ForeColor = Color.Silver, Padding = new Padding(8, 4, 0, 0), BackColor = Color.FromArgb(24, 26, 36) };
    readonly GridView grid = new GridView { Width = 380, Height = 380, Margin = new Padding(12) };
    readonly FlowLayoutPanel maps = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, Margin = new Padding(6, 12, 6, 6) };
    string shown;

    public StickStudio(Sticks running, string manifestDir, string ledBlinkyDir, object gate, string startGame, Action<string> log)
    {
        this.gate = gate;
        sticks = running;
        if (sticks == null) { sticks = new Sticks(manifestDir, ledBlinkyDir, log); ownSticks = true; }
        Text = "ArcadeMaster Panel - Sticks & Guns"; Width = 900; Height = 640; BackColor = Color.FromArgb(12, 13, 18); ForeColor = Color.White;

        var top = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 44, Padding = new Padding(8), BackColor = Color.FromArgb(24, 26, 36) };
        top.Controls.Add(new Label { Text = "Game (MAME name):", AutoSize = true, ForeColor = Color.Gainsboro, Padding = new Padding(0, 6, 0, 0) });
        game.Text = startGame ?? "";
        var show = Btn("Show"); show.Click += delegate { ShowGame(); };
        game.KeyDown += delegate (object s, KeyEventArgs e) { if (e.KeyCode == Keys.Enter) { ShowGame(); e.SuppressKeyPress = true; } };
        top.Controls.Add(game); top.Controls.Add(show); top.Controls.Add(info);

        var body = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.LeftToRight, WrapContents = false, AutoScroll = true };
        body.Controls.Add(grid);

        // the maps: press = load on the sticks now (and draw it)
        maps.Controls.Add(Head("ULTRASTIK MAPS  (" + sticks.Count + " stick" + (sticks.Count == 1 ? "" : "s") + ")"));
        var order = new List<string> { "joy8way", "joy4way", "joy2way", "vjoy2way", "joydiag", "analog" };
        var all = sticks.Maps();
        all.Sort(delegate (string a, string b) {
            int ia = order.IndexOf(a.ToLowerInvariant()), ib = order.IndexOf(b.ToLowerInvariant());
            if (ia < 0) ia = 99; if (ib < 0) ib = 99;
            return ia != ib ? ia.CompareTo(ib) : string.Compare(a, b, StringComparison.OrdinalIgnoreCase);
        });
        foreach (var m in all)
        {
            string name = m;
            var b = Btn(Nice(name)); b.Width = 190; b.TextAlign = ContentAlignment.MiddleLeft;
            b.Click += delegate { Draw(name); string r; lock (gate) r = sticks.Load(name, null, true); status.Text = "sticks: " + r; };
            maps.Controls.Add(b);
        }
        var keep = Btn("Keep for this game"); keep.Width = 190; keep.BackColor = Color.FromArgb(120, 200, 140);
        keep.Click += delegate {
            string rom = game.Text.Trim(); if (rom == "" || shown == null) { status.Text = "type a game and pick a map first"; return; }
            sticks.SetGameMap(rom, shown); status.Text = rom + " keeps " + shown + " on this cabinet (stick-maps-cabinet.json)"; ShowGame();
        };
        var undo = Btn("Back to MAME's choice"); undo.Width = 190;
        undo.Click += delegate { string rom = game.Text.Trim(); if (rom == "") return; sticks.SetGameMap(rom, null); status.Text = rom + ": back to the generated map"; ShowGame(); };
        maps.Controls.Add(keep); maps.Controls.Add(undo);
        body.Controls.Add(maps);

        // ServoStik and guns
        var side = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, Margin = new Padding(6, 12, 6, 6) };
        side.Controls.Add(Head("SERVOSTIK RESTRICTOR"));
        var four = Btn("4-way now"); four.Width = 190; four.Click += delegate { Servo(true); };
        var eight = Btn("8-way now"); eight.Width = 190; eight.Click += delegate { Servo(false); };
        side.Controls.Add(four); side.Controls.Add(eight);
        side.Controls.Add(new Label { Text = "The frontend switches it per game\n(4-way games: Pac-Man, Donkey Kong...)", AutoSize = true, ForeColor = Color.Gray, Margin = new Padding(3, 2, 3, 14) });
        side.Controls.Add(Head("LIGHT GUNS"));
        var guns = Guns.Find();
        if (guns.Count == 0) side.Controls.Add(new Label { Text = "none plugged in", AutoSize = true, ForeColor = Color.Gray });
        foreach (Dictionary<string, object> g in guns) side.Controls.Add(new Label { Text = g["kind"] + "  " + g["usb"] + "\n" + g["name"], AutoSize = true, ForeColor = Color.Gainsboro, Margin = new Padding(3, 2, 3, 8) });
        body.Controls.Add(side);

        Controls.Add(body); Controls.Add(status); Controls.Add(top);
        Load += delegate { ShowGame(); };
        FormClosed += delegate { if (ownSticks) sticks.Close(); };
    }

    void ShowGame()
    {
        string rom = game.Text.Trim();
        string m = sticks.MapFor(rom == "" ? null : rom);
        info.Text = rom == "" ? "menus: " + Nice(m) : rom + " gets " + Nice(m) + (sticks.IsCabinetPick(rom) ? "  (this cabinet's pick)" : "  (automatic: MAME's controls + overrides)");
        Draw(m);
    }

    void Draw(string map) { shown = map; grid.Cells = sticks.Grid(map); grid.Title = Nice(map); grid.Invalidate(); }

    void Servo(bool four)
    {
        try { PacInitialize(); bool ok = four ? PacSetServoStik4Way() : PacSetServoStik8Way(); PacShutdown(); status.Text = "ServoStik: " + (four ? "4-way" : "8-way") + (ok ? "" : " - not answered (is a ServoStik plugged in?)"); }
        catch (Exception e) { status.Text = "ServoStik: " + e.Message; }
    }

    static string Nice(string m)
    {
        switch ((m ?? "").ToLowerInvariant())
        {
            case "joy8way": return "8-way";
            case "joy4way": return "4-way";
            case "joy2way": return "2-way (left / right)";
            case "vjoy2way": return "2-way (up / down)";
            case "joydiag": return "diagonal (Q*bert)";
            case "analog": return "analog";
            default: return m;
        }
    }

    static Button Btn(string t) { return new Button { Text = t, AutoSize = false, Height = 34, Width = 90, ForeColor = Color.Black, BackColor = Color.Gainsboro, FlatStyle = FlatStyle.Flat, Margin = new Padding(3), Font = new Font("Segoe UI Semibold", 9.5f) }; }
    static Label Head(string t) { return new Label { Text = t, AutoSize = true, ForeColor = Color.FromArgb(255, 200, 80), Font = new Font("Segoe UI Semibold", 10f), Margin = new Padding(3, 0, 3, 6) }; }

    // the stick's 9x9 zones as the stick sees them: one colour per direction, an arrow in each cell, the gate drawn over
    class GridView : Control
    {
        public string[][] Cells; public string Title;
        public GridView() { DoubleBuffered = true; BackColor = Color.FromArgb(18, 20, 28); }

        static readonly Dictionary<string, Color> Col = new Dictionary<string, Color> {
            { "N", Color.FromArgb(70, 140, 255) }, { "S", Color.FromArgb(255, 150, 60) }, { "E", Color.FromArgb(90, 210, 120) }, { "W", Color.FromArgb(230, 80, 110) },
            { "NE", Color.FromArgb(80, 190, 200) }, { "NW", Color.FromArgb(160, 110, 240) }, { "SE", Color.FromArgb(190, 200, 70) }, { "SW", Color.FromArgb(240, 120, 70) } };
        static readonly Dictionary<string, string> Arrow = new Dictionary<string, string> {
            { "N", "↑" }, { "S", "↓" }, { "E", "→" }, { "W", "←" }, { "NE", "↗" }, { "NW", "↖" }, { "SE", "↘" }, { "SW", "↙" } };

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
            int top = 28, size = Math.Min(Width, Height - top) - 4, cell = size / 9, x0 = (Width - cell * 9) / 2;
            using (var f = new Font("Segoe UI Semibold", 11f)) g.DrawString(Title ?? "", f, Brushes.White, 4, 4);
            if (Cells == null) { g.DrawString("no map file", Font, Brushes.Gray, 8, top + 8); return; }
            using (var af = new Font("Segoe UI Symbol", cell * 0.42f, FontStyle.Bold))
            using (var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                for (int r = 0; r < 9; r++)
                    for (int c = 0; c < 9; c++)
                    {
                        string d = Cells[r][c].Trim().ToUpperInvariant();
                        var rc = new Rectangle(x0 + c * cell, top + r * cell, cell - 2, cell - 2);
                        Color col; string a;
                        if (d == "C") { col = Color.FromArgb(45, 48, 60); a = "•"; }
                        else if (d == "*") { col = Color.FromArgb(28, 30, 38); a = ""; }        // sticky: keeps the last direction
                        else if (d == "-") { col = Color.FromArgb(60 + c * 12, 60 + (8 - r) * 12, 120); a = ""; }   // analog: a smooth field
                        else { if (!Col.TryGetValue(d, out col)) col = Color.DimGray; if (!Arrow.TryGetValue(d, out a)) a = d; }
                        using (var b = new SolidBrush(col)) g.FillRectangle(b, rc);
                        if (a != "") g.DrawString(a, af, Brushes.Black, rc, fmt);
                    }
            using (var p = new Pen(Color.FromArgb(160, 255, 255, 255), 2)) g.DrawEllipse(p, x0, top, cell * 9 - 2, cell * 9 - 2);   // the stick's round travel
        }
    }
}
