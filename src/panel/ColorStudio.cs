// AmPanel step 11 (first tab) - "Lights & Colours": pick a colour for any button of any game, see it on the real panel
// at once, keep it as the cabinet's own override (<manifest>\led-colors.json). Simple on purpose: one game box, one
// button per row, click to change, Reset to go back to the game's original colours.
// C# 5.
using System;
using System.Drawing;
using System.Windows.Forms;

class ColorStudio : Form
{
    readonly LedEngine leds;
    readonly object gate;
    readonly TextBox game = new TextBox { Width = 180 };
    readonly FlowLayoutPanel list = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoScroll = true, FlowDirection = FlowDirection.TopDown, WrapContents = true, BackColor = Color.FromArgb(18, 20, 28) };
    readonly Label info = new Label { AutoSize = true, ForeColor = Color.Gainsboro, Padding = new Padding(8, 8, 0, 0) };

    public ColorStudio(LedEngine leds, object gate, string startGame)
    {
        this.leds = leds; this.gate = gate;
        Text = "ArcadeMaster Panel - Lights & Colours"; Width = 760; Height = 640; BackColor = Color.FromArgb(12, 13, 18); ForeColor = Color.White;
        var top = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 44, Padding = new Padding(8), BackColor = Color.FromArgb(24, 26, 36) };
        top.Controls.Add(new Label { Text = "Game (MAME name):", AutoSize = true, ForeColor = Color.Gainsboro, Padding = new Padding(0, 6, 0, 0) });
        game.Text = startGame ?? "";
        var load = new Button { Text = "Show", AutoSize = true, ForeColor = Color.Black };
        var reset = new Button { Text = "Reset game", AutoSize = true, ForeColor = Color.Black };
        load.Click += delegate { Reload(); };
        reset.Click += delegate { lock (gate) { leds.ResetGame(game.Text.Trim()); leds.LightGame(game.Text.Trim()); } Reload(); };
        game.KeyDown += delegate (object s, KeyEventArgs e) { if (e.KeyCode == Keys.Enter) { Reload(); e.SuppressKeyPress = true; } };
        top.Controls.Add(game); top.Controls.Add(load); top.Controls.Add(reset); top.Controls.Add(info);
        Controls.Add(list); Controls.Add(top);
        Load += delegate { Reload(); };
    }

    void Reload()
    {
        string rom = game.Text.Trim();
        list.SuspendLayout(); list.Controls.Clear();
        System.Collections.Generic.SortedDictionary<string, int[]> colors;
        lock (gate) { leds.LightGame(rom); colors = leds.GameColors(rom); }
        info.Text = (leds.KnowsGame(rom) ? "colours from Colors.ini" : "not in Colors.ini (soft white)") + (leds.HasOverrides(rom) ? " + this cabinet's changes" : "");
        foreach (var kv in colors)
        {
            string label = kv.Key; int[] c = kv.Value;
            var b = new Button { Text = label, Width = 168, Height = 36, FlatStyle = FlatStyle.Flat, Margin = new Padding(6), Font = new Font("Segoe UI Semibold", 10f) };
            Swatch(b, c);
            b.Click += delegate {
                using (var dlg = new ColorDialog { FullOpen = true, Color = ToColor(c) })
                {
                    if (dlg.ShowDialog(this) != DialogResult.OK) return;
                    var picked = new[] { dlg.Color.R * 48 / 255, dlg.Color.G * 48 / 255, dlg.Color.B * 48 / 255 };
                    lock (gate) { leds.SetGameColor(rom, label, picked); leds.LightGame(rom); }   // live on the panel, and the new base colour
                    c = picked; Swatch(b, c);
                    info.Text = "saved: " + label + " for " + rom;
                }
            };
            list.Controls.Add(b);
        }
        list.ResumeLayout();
    }

    static Color ToColor(int[] c) { return Color.FromArgb(Math.Min(255, c[0] * 255 / 48), Math.Min(255, c[1] * 255 / 48), Math.Min(255, c[2] * 255 / 48)); }
    static void Swatch(Button b, int[] c)
    {
        var col = ToColor(c); b.BackColor = col;
        b.ForeColor = (col.R * 299 + col.G * 587 + col.B * 114) / 1000 > 140 ? Color.Black : Color.White;
        b.FlatAppearance.BorderColor = Color.FromArgb(70, 76, 96);
    }
}
