// AmPanel - "Which controller will you use?" at game start (James 2026-11-25).
//
// <manifest>\controller-choices.json (tools\New-ControllerChoices.py: only games where THIS cabinet offers two or more
// controllers, best first) says what to offer. The question is a full-screen, top-most screen driven from the panel:
// stick / arrows move, button 1 (Left Ctrl) / Enter / Space picks, Esc keeps the highlighted one. The last pick for each
// game is highlighted and is taken by itself after a few seconds, so an unattended or attract launch never waits.
// Picks are kept in <manifest>\controller-picks.json.
// C# 5.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Windows.Forms;
using System.Web.Script.Serialization;

class ControllerChoices
{
    readonly string choicesFile, picksFile;
    Dictionary<string, Dictionary<string, object>> games = new Dictionary<string, Dictionary<string, object>>(StringComparer.OrdinalIgnoreCase);
    Dictionary<string, string> byItem = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);   // "pacman" -> "Arcades:pacman"
    Dictionary<string, string> picks = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    DateTime loadedAt;

    public ControllerChoices(string manifestDir)
    {
        choicesFile = Path.Combine(manifestDir, "controller-choices.json");
        picksFile = Path.Combine(manifestDir, "controller-picks.json");
        Reload();
    }

    // reloaded when the file changes: the hot-plug refresh rewrites it when controllers come and go
    void Reload()
    {
        var ser = new JavaScriptSerializer { MaxJsonLength = 32 * 1024 * 1024 };
        games.Clear(); byItem.Clear();
        try
        {
            if (File.Exists(choicesFile))
            {
                loadedAt = File.GetLastWriteTimeUtc(choicesFile);
                var root = ser.Deserialize<Dictionary<string, object>>(File.ReadAllText(choicesFile));
                var g = root.ContainsKey("games") ? root["games"] as Dictionary<string, object> : null;
                if (g != null) foreach (var kv in g)
                    {
                        var d = kv.Value as Dictionary<string, object>; if (d == null) continue;
                        games[kv.Key] = d;
                        int c = kv.Key.LastIndexOf(':'); string item = c >= 0 ? kv.Key.Substring(c + 1) : kv.Key;
                        if (!byItem.ContainsKey(item)) byItem[item] = kv.Key;
                    }
            }
            if (File.Exists(picksFile))
            {
                var p = ser.Deserialize<Dictionary<string, object>>(File.ReadAllText(picksFile));
                picks = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                foreach (var kv in p) picks[kv.Key] = Convert.ToString(kv.Value);
            }
        }
        catch { }
    }

    public int Count { get { return games.Count; } }

    // the game's entry: "<collection>:<item>" first, then the item alone
    public string Find(string item, string collection)
    {
        if (File.Exists(choicesFile) && File.GetLastWriteTimeUtc(choicesFile) != loadedAt) Reload();
        if (string.IsNullOrEmpty(item)) return null;
        if (collection != null && games.ContainsKey(collection + ":" + item)) return collection + ":" + item;
        if (games.ContainsKey(item)) return item;
        string id; return byItem.TryGetValue(item, out id) ? id : null;
    }

    public List<Dictionary<string, object>> Choices(string id)
    {
        var l = new List<Dictionary<string, object>>();
        Dictionary<string, object> g;
        if (id == null || !games.TryGetValue(id, out g)) return l;
        var a = g.ContainsKey("choices") ? g["choices"] as System.Collections.ArrayList : null;
        if (a != null) foreach (var o in a) { var d = o as Dictionary<string, object>; if (d != null) l.Add(d); }
        return l;
    }

    public string Title(string id) { Dictionary<string, object> g; return id != null && games.TryGetValue(id, out g) && g.ContainsKey("title") ? Convert.ToString(g["title"]) : id; }
    public string LastPick(string id) { string p; return id != null && picks.TryGetValue(id, out p) ? p : null; }

    public void SavePick(string id, string choice)
    {
        picks[id] = choice;
        try { File.WriteAllText(picksFile, new JavaScriptSerializer().Serialize(picks), new System.Text.UTF8Encoding(false)); } catch { }
    }
}

class ControllerChooser : Form
{
    readonly List<Dictionary<string, object>> choices;
    readonly List<Panel> tiles = new List<Panel>();
    readonly Label countdown = new Label { AutoSize = true, ForeColor = Color.FromArgb(150, 150, 170), Font = new Font("Segoe UI", 16f) };
    readonly Timer tick = new Timer { Interval = 100 };
    int sel, msLeft;
    public string Picked { get; private set; }

    public ControllerChooser(string title, List<Dictionary<string, object>> choices, string last, int seconds)
    {
        this.choices = choices;
        FormBorderStyle = FormBorderStyle.None; WindowState = FormWindowState.Maximized; TopMost = true; ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual; Bounds = Screen.PrimaryScreen.Bounds;
        BackColor = Color.FromArgb(10, 11, 16); KeyPreview = true; msLeft = seconds * 1000;
        for (int i = 0; i < choices.Count; i++) if (Convert.ToString(choices[i]["id"]) == last) sel = i;

        var head = new Label { Text = title ?? "", AutoSize = true, ForeColor = Color.White, Font = new Font("Segoe UI Semibold", 34f) };
        var ask = new Label { Text = "Which controller will you use?", AutoSize = true, ForeColor = Color.FromArgb(255, 200, 80), Font = new Font("Segoe UI", 22f) };
        Controls.Add(head); Controls.Add(ask); Controls.Add(countdown);

        for (int i = 0; i < choices.Count; i++)
        {
            int idx = i;
            var p = new Panel { Width = 380, Height = 220, BackColor = Color.FromArgb(28, 30, 42), Cursor = Cursors.Hand };
            var t = new Label { Text = Glyph(Convert.ToString(choices[i]["id"])), Dock = DockStyle.Top, Height = 110, TextAlign = ContentAlignment.MiddleCenter, ForeColor = Color.White, Font = new Font("Segoe UI Symbol", 48f) };
            var l = new Label { Text = Convert.ToString(choices[i]["label"]), Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter, ForeColor = Color.Gainsboro, Font = new Font("Segoe UI Semibold", 17f) };
            p.Controls.Add(l); p.Controls.Add(t);
            EventHandler pick = delegate { sel = idx; Done(); };
            p.Click += pick; t.Click += pick; l.Click += pick;
            tiles.Add(p); Controls.Add(p);
        }
        Layout += delegate {
            int w = Width, h = Height, n = tiles.Count, gap = 40, total = n * 380 + (n - 1) * gap, x = (w - total) / 2, y = h / 2 - 90;
            head.Location = new Point((w - head.Width) / 2, y - 220); ask.Location = new Point((w - ask.Width) / 2, y - 130);
            for (int i = 0; i < n; i++) tiles[i].Location = new Point(x + i * (380 + gap), y);
            countdown.Location = new Point((w - countdown.Width) / 2, y + 270);
        };
        KeyDown += OnKey;
        tick.Tick += delegate { msLeft -= tick.Interval; Paint(); if (msLeft <= 0) Done(); };
        Shown += delegate { Activate(); Paint(); tick.Start(); };
        FormClosed += delegate { tick.Stop(); };
    }

    void OnKey(object s, KeyEventArgs e)
    {
        msLeft = Math.Max(msLeft, 4000);   // someone is there: never time out under their hand
        switch (e.KeyCode)
        {
            case Keys.Left: case Keys.Up: case Keys.NumPad4: case Keys.D: sel = (sel + tiles.Count - 1) % tiles.Count; break;
            case Keys.Right: case Keys.Down: case Keys.NumPad6: case Keys.G: sel = (sel + 1) % tiles.Count; break;
            case Keys.ControlKey: case Keys.LControlKey: case Keys.Enter: case Keys.Space: case Keys.D1: case Keys.Escape: Done(); return;
        }
        Paint(); e.Handled = true;
    }

    new void Paint()
    {
        for (int i = 0; i < tiles.Count; i++)
        {
            bool on = i == sel;
            tiles[i].BackColor = on ? Color.FromArgb(40, 120, 220) : Color.FromArgb(28, 30, 42);
            tiles[i].Padding = on ? new Padding(0) : new Padding(6);
        }
        countdown.Text = "Stick to choose, button 1 to play  -  " + Math.Max(0, (msLeft + 999) / 1000) + " s";
    }

    void Done() { if (Picked != null) return; Picked = Convert.ToString(choices[sel]["id"]); Close(); }

    static string Glyph(string id)
    {
        switch (id)
        {
            case "trackball": return "●";        // a ball
            case "joystick": return "✚";         // a stick's cross
            case "analog": return "◎";           // a ring: any angle
            case "lightgun": return "⌖";         // crosshair
            case "mouse": return "⇱";
            case "wheel": return "☸";
            case "flightstick": return "✈";
            case "gamepad": return "⊞";
            default: return "▢";
        }
    }
}
