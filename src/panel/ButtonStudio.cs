// AmPanel - "Buttons": learn which light is which button (replaces LEDBlinky's input-map wizard, GenLEDBlinkyInputMap).
//
// Walks every LED board three ports at a time (one RGB button): those ports light white, everything else goes dark.
// Press the panel button that lit up - its key names the button through the input map's key codes (KEYCODE_LCONTROL ->
// P1B1) - or pick the name from the list. "Nothing lit" skips a group that has no LED wired. Save writes
// <manifest>\LEDBlinkyInputMap-learned.xml in LEDBlinky's own format; AmPanel uses it instead of LEDBlinky's map from
// its next start. Groups you did not walk keep what the old map said.
// C# 5.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

class ButtonStudio : Form
{
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);

    readonly LedEngine leds;
    readonly object gate;
    readonly string outFile;
    readonly List<KeyValuePair<int, int>> groups = new List<KeyValuePair<int, int>>();   // (board, first port)
    readonly Dictionary<string, string> learned = new Dictionary<string, string>();       // "board:first" -> label ("" = nothing lit)
    readonly Dictionary<int, List<string>> vkLabels = new Dictionary<int, List<string>>();
    readonly Dictionary<int, SortedDictionary<int, KeyValuePair<string, char>>> before;
    int at;

    readonly Label where = new Label { AutoSize = true, ForeColor = Color.FromArgb(255, 200, 80), Font = new Font("Segoe UI Semibold", 20f), Margin = new Padding(12, 16, 12, 4) };
    readonly Label ask = new Label { AutoSize = true, ForeColor = Color.White, Font = new Font("Segoe UI", 14f), Margin = new Padding(12, 4, 12, 4) };
    readonly Label was = new Label { AutoSize = true, ForeColor = Color.Silver, Font = new Font("Segoe UI", 11f), Margin = new Padding(12, 2, 12, 12) };
    readonly ComboBox pick = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 220, Font = new Font("Segoe UI", 12f) };
    readonly Label progress = new Label { AutoSize = true, ForeColor = Color.Gray, Margin = new Padding(12, 12, 12, 4) };

    public ButtonStudio(LedEngine leds, object gate, string manifestDir, Action whenClosed)
    {
        FormClosed += delegate { if (whenClosed != null) whenClosed(); };
        this.leds = leds; this.gate = gate;
        outFile = Path.Combine(manifestDir, "LEDBlinkyInputMap-learned.xml");
        Text = "ArcadeMaster Panel - Buttons (which light is which)"; Width = 980; Height = 470; BackColor = Color.FromArgb(12, 13, 18); ForeColor = Color.White; KeyPreview = true;
        before = leds.PortTable();
        foreach (var b in leds.BoardIds) for (int p = 1; p <= 96; p += 3) groups.Add(new KeyValuePair<int, int>(b, p));
        foreach (var kv in leds.KeyLabels())
        {
            int vk = ReactiveKeys.VkOf(kv.Key); if (vk == 0) continue;
            List<string> l; if (!vkLabels.TryGetValue(vk, out l)) { l = new List<string>(); vkLabels[vk] = l; }
            foreach (var lab in kv.Value) if (!l.Contains(lab)) l.Add(lab);
        }
        pick.Items.Add("(choose the button)"); foreach (var l in leds.Labels) pick.Items.Add(l);

        var flow = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false };
        flow.Controls.Add(where); flow.Controls.Add(ask); flow.Controls.Add(was);
        var row = new FlowLayoutPanel { AutoSize = true, Margin = new Padding(8, 0, 8, 0) };
        var use = Btn("This one"); use.Click += delegate { if (pick.SelectedIndex > 0) Record(Convert.ToString(pick.SelectedItem)); };
        var none = Btn("Nothing lit"); none.Click += delegate { Record(""); };
        var back = Btn("Back"); back.Click += delegate { if (at > 0) { at--; Show(); } };
        var skip = Btn("Skip"); skip.Click += delegate { Next(); };
        row.Controls.Add(pick); row.Controls.Add(use); row.Controls.Add(none); row.Controls.Add(back); row.Controls.Add(skip);
        flow.Controls.Add(row);
        flow.Controls.Add(progress);
        var save = Btn("Save"); save.Width = 160; save.BackColor = Color.FromArgb(120, 200, 140); save.Margin = new Padding(12, 8, 12, 8);
        save.Click += delegate { progress.Text = Save(); };
        flow.Controls.Add(save);
        AcceptButton = save;   // Enter saves (Enter is not a panel button)
        Controls.Add(flow);
        KeyDown += OnKey;
        Load += delegate { Show(); };
    }

    new void Show()
    {
        if (at >= groups.Count) { where.Text = "All " + groups.Count + " groups done"; ask.Text = "Press Save to keep it."; was.Text = ""; lock (gate) leds.AllOff(); UpdateProgress(); return; }
        var g = groups[at];
        where.Text = "Board " + g.Key + ", ports " + g.Value + "-" + (g.Value + 2);
        ask.Text = "Press the panel button that is lit now (or pick it below).";
        string old = leds.LabelAt(g.Key, g.Value), mine;
        was.Text = "Input map says: " + (old ?? "nothing") + (learned.TryGetValue(g.Key + ":" + g.Value, out mine) ? "     you said: " + (mine == "" ? "nothing lit" : mine) : "");
        pick.SelectedIndex = 0;
        lock (gate) leds.LightRaw(g.Key, g.Value, 3, 48);
        UpdateProgress();
    }

    void UpdateProgress() { progress.Text = learned.Count + " of " + groups.Count + " groups learned"; }

    void Record(string label)
    {
        if (at >= groups.Count) return;
        var g = groups[at];
        learned[g.Key + ":" + g.Value] = label;
        Next();
    }

    void Next() { if (at < groups.Count) at++; Show(); }

    void OnKey(object s, KeyEventArgs e)
    {
        if (ActiveControl == pick && pick.DroppedDown) return;
        int vk = (int)e.KeyCode;
        if (vk == 0x11) vk = GetAsyncKeyState(0xA3) < 0 ? 0xA3 : 0xA2;          // which Ctrl
        else if (vk == 0x10) vk = GetAsyncKeyState(0xA1) < 0 ? 0xA1 : 0xA0;     // which Shift
        else if (vk == 0x12) vk = GetAsyncKeyState(0xA5) < 0 ? 0xA5 : 0xA4;     // which Alt
        List<string> labs;
        if (!vkLabels.TryGetValue(vk, out labs) || labs.Count == 0) { progress.Text = "that key (" + e.KeyCode + ") is not a panel button in the input map"; return; }
        // a key shared by two buttons: the one not learned yet
        string label = labs[0];
        foreach (var l in labs) if (!learned.ContainsValue(l)) { label = l; break; }
        e.Handled = true; e.SuppressKeyPress = true;
        Record(label);
    }

    string Save()
    {
        try
        {
            // start from the current map, replace every learned group
            var table = new Dictionary<int, SortedDictionary<int, KeyValuePair<string, char>>>();
            foreach (var b in before) table[b.Key] = new SortedDictionary<int, KeyValuePair<string, char>>(b.Value);
            foreach (var kv in learned)
            {
                var parts = kv.Key.Split(':'); int board = int.Parse(parts[0]), first = int.Parse(parts[1]);
                SortedDictionary<int, KeyValuePair<string, char>> t;
                if (!table.TryGetValue(board, out t)) { t = new SortedDictionary<int, KeyValuePair<string, char>>(); table[board] = t; }
                for (int i = 0; i < 3; i++) t.Remove(first + i);
                if (kv.Value != "") { t[first] = new KeyValuePair<string, char>(kv.Value, 'R'); t[first + 1] = new KeyValuePair<string, char>(kv.Value, 'G'); t[first + 2] = new KeyValuePair<string, char>(kv.Value, 'B'); }
            }
            var sb = new StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n<dat>\r\n  <meta>\r\n    <description name=\"Used by LEDBlinky for LED Input Map Data.\"/>\r\n");
            sb.Append("    <generatedBy name=\"ArcadeMaster AmPanel (Buttons window)\"/>\r\n    <date name=\"").Append(DateTime.Now.ToString("s")).Append("\"/>\r\n  </meta>\r\n");
            var boards = new List<int>(table.Keys); boards.Sort();
            var kinds = BoardKinds(leds.InputMapUsed);
            foreach (var b in boards)
            {
                // each board keeps the type / name the map it replaces gave it (a PacLED64 or a Nano-LED was saved as an
                // I-PAC Ultimate I/O before); a board that map did not have is taken for an Ultimate I/O, as LEDBlinky does
                KeyValuePair<string, string> k;
                if (!kinds.TryGetValue(b, out k)) k = new KeyValuePair<string, string>("6", "iPACUltimateIO");
                sb.Append("  <ledController type=\"").Append(Esc(k.Key)).Append("\" id=\"").Append(b).Append("\" name=\"").Append(Esc(k.Value)).Append("\">\r\n");
                foreach (var p in table[b])
                    sb.Append("    <port number=\"").Append(p.Key).Append("\" label=\"").Append(Esc(p.Value.Key)).Append("\" type=\"").Append(p.Value.Value == 'S' ? "S" : p.Value.Value.ToString())
                      .Append("\" inputCodes=\"").Append(Esc(leds.InputCodesOf(p.Value.Key))).Append("\"/>\r\n");
                sb.Append("  </ledController>\r\n");
            }
            sb.Append("</dat>\r\n");
            File.WriteAllText(outFile, sb.ToString(), new UTF8Encoding(false));
            return "saved " + learned.Count + " group(s) -> " + outFile + " (used from AmPanel's next start)";
        }
        catch (Exception e) { return "save failed: " + e.Message; }
    }

    // <ledController type="6" id="1" name="iPACUltimateIO"> of the input map in use: id -> (type, name)
    static Dictionary<int, KeyValuePair<string, string>> BoardKinds(string mapFile)
    {
        var d = new Dictionary<int, KeyValuePair<string, string>>();
        try
        {
            if (string.IsNullOrEmpty(mapFile) || !File.Exists(mapFile)) return d;
            foreach (System.Text.RegularExpressions.Match m in System.Text.RegularExpressions.Regex.Matches(File.ReadAllText(mapFile), "<ledController\\b[^>]*>", System.Text.RegularExpressions.RegexOptions.IgnoreCase))
            {
                string tag = m.Value;
                var id = System.Text.RegularExpressions.Regex.Match(tag, "\\bid\\s*=\\s*\"(\\d+)\"", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                var ty = System.Text.RegularExpressions.Regex.Match(tag, "\\btype\\s*=\\s*\"([^\"]*)\"", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                var nm = System.Text.RegularExpressions.Regex.Match(tag, "\\bname\\s*=\\s*\"([^\"]*)\"", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                if (id.Success && ty.Success) d[int.Parse(id.Groups[1].Value)] = new KeyValuePair<string, string>(ty.Groups[1].Value, nm.Success ? nm.Groups[1].Value : "");
            }
        }
        catch { }
        return d;
    }

    static string Esc(string s) { return (s ?? "").Replace("&", "&amp;").Replace("\"", "&quot;").Replace("<", "&lt;"); }
    static Button Btn(string t) { return new Button { Text = t, Height = 34, Width = 110, ForeColor = Color.Black, BackColor = Color.Gainsboro, FlatStyle = FlatStyle.Flat, Margin = new Padding(4), Font = new Font("Segoe UI Semibold", 9.5f) }; }
}
