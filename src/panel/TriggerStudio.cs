// AmPanel step 11 (Triggers tab) - every output a game sends, live, and what it does on this cabinet.
//
// Rows: the outputs learned for the game (<manifest>\outputs\<game>.json) plus any arriving live, with the live value
// (refreshed 5x a second while the game runs - press things and watch which lamp moves) and the rule it follows now.
// Pick a row, choose an action (light a button in a colour / ignore / recoil / rumble, or "default" to drop this
// cabinet's rule) and Save: the rule goes to <manifest>\panel-rules.json for this game and is live at once.
// C# 5.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Web.Script.Serialization;
using System.Windows.Forms;

class TriggerStudio : Form
{
    readonly OutputListener outputs;
    readonly Func<TriggerRules> getRules;
    readonly Action reloadRules;
    readonly string manifestDir;
    readonly TextBox game = new TextBox { Width = 160 };
    readonly ListView view = new ListView { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, HideSelection = false, BackColor = Color.FromArgb(18, 20, 28), ForeColor = Color.Gainsboro, Font = new Font("Segoe UI", 10f) };
    readonly ComboBox action = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 110 };
    readonly ComboBox target = new ComboBox { Width = 120 };
    readonly ComboBox color = new ComboBox { Width = 110 };
    readonly Label status = new Label { AutoSize = true, ForeColor = Color.Gainsboro, Padding = new Padding(0, 6, 0, 0) };
    readonly Timer live = new Timer { Interval = 200 };
    readonly Dictionary<string, ListViewItem> rows = new Dictionary<string, ListViewItem>(StringComparer.OrdinalIgnoreCase);

    public TriggerStudio(OutputListener outputs, Func<TriggerRules> getRules, Action reloadRules, string manifestDir, string startGame, List<string> labels, List<string> colors)
    {
        this.outputs = outputs; this.getRules = getRules; this.reloadRules = reloadRules; this.manifestDir = manifestDir;
        Text = "ArcadeMaster Panel - Triggers (game outputs -> what they do)"; Width = 900; Height = 620; BackColor = Color.FromArgb(12, 13, 18); ForeColor = Color.White;
        view.Columns.Add("Output", 260); view.Columns.Add("Live", 70); view.Columns.Add("Changes", 80); view.Columns.Add("Does now", 420);
        var top = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 44, Padding = new Padding(8), BackColor = Color.FromArgb(24, 26, 36) };
        top.Controls.Add(new Label { Text = "Game:", AutoSize = true, ForeColor = Color.Gainsboro, Padding = new Padding(0, 6, 0, 0) });
        game.Text = startGame ?? "";
        var show = new Button { Text = "Show", AutoSize = true, ForeColor = Color.Black }; show.Click += delegate { Reload(); };
        top.Controls.Add(game); top.Controls.Add(show);
        var bottom = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 46, Padding = new Padding(8), BackColor = Color.FromArgb(24, 26, 36) };
        action.Items.AddRange(new object[] { "led", "ignore", "recoil", "rumble", "default" }); action.SelectedIndex = 0;
        foreach (var l in labels) target.Items.Add(l);
        foreach (var p in new[] { "P1", "P2", "P3", "P4" }) target.Items.Add(p);
        foreach (var c in colors) color.Items.Add(c); color.Text = "White";
        var save = new Button { Text = "Save rule for this game", AutoSize = true, ForeColor = Color.Black };
        save.Click += delegate { Save(); };
        foreach (Control c in new Control[] { new Label { Text = "Do:", AutoSize = true, Padding = new Padding(0, 6, 0, 0) }, action, new Label { Text = "Target:", AutoSize = true, Padding = new Padding(0, 6, 0, 0) }, target, new Label { Text = "Colour:", AutoSize = true, Padding = new Padding(0, 6, 0, 0) }, color, save, status }) bottom.Controls.Add(c);
        Controls.Add(view); Controls.Add(bottom); Controls.Add(top);
        live.Tick += delegate { Refresh_(); };
        Load += delegate { Reload(); live.Start(); };
        FormClosed += delegate { live.Stop(); };
    }

    void Reload()
    {
        view.Items.Clear(); rows.Clear();
        string g = game.Text.Trim();
        // learned before
        string f = Path.Combine(manifestDir, "outputs", string.Join("_", g.Split(Path.GetInvalidFileNameChars())) + ".json");
        if (File.Exists(f))
        {
            try
            {
                var root = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(f));
                var outs = root.ContainsKey("outputs") ? root["outputs"] as Dictionary<string, object> : null;
                if (outs != null) foreach (var kv in outs) { var d = kv.Value as Dictionary<string, object>; Row(kv.Key, d != null && d.ContainsKey("last") ? Convert.ToString(d["last"]) : "", d != null && d.ContainsKey("changes") ? Convert.ToString(d["changes"]) : ""); }
            }
            catch { }
        }
        Refresh_();
        status.Text = rows.Count == 0 ? "no outputs known for '" + g + "' yet - run the game once" : rows.Count + " output(s)";
    }

    ListViewItem Row(string name, string value, string changes)
    {
        ListViewItem it;
        if (!rows.TryGetValue(name, out it))
        {
            it = new ListViewItem(new[] { name, value, changes, "" }); rows[name] = it; view.Items.Add(it);
        }
        it.SubItems[3].Text = getRules() != null ? getRules().Describe(name, game.Text.Trim()) : "-";
        return it;
    }

    void Refresh_()
    {
        if (outputs == null) return;
        foreach (var kv in outputs.Snapshot())
        {
            var it = Row(kv.Key, "", "");
            string v = Convert.ToString(kv.Value);
            if (it.SubItems[1].Text != v) { it.SubItems[1].Text = v; it.BackColor = v != "0" ? Color.FromArgb(40, 70, 40) : view.BackColor; }   // lit outputs stand out
        }
    }

    void Save()
    {
        if (view.SelectedItems.Count == 0) { status.Text = "pick an output first"; return; }
        string output = view.SelectedItems[0].Text, g = game.Text.Trim(), a = Convert.ToString(action.SelectedItem);
        if (a == "led" && string.IsNullOrEmpty(target.Text)) { status.Text = "pick the button to light"; return; }
        try
        {
            TriggerRules.SaveCabinetRule(Path.Combine(manifestDir, "panel-rules.json"), output, g, a, target.Text, color.Text);
            reloadRules();
            foreach (ListViewItem it in view.Items) it.SubItems[3].Text = getRules().Describe(it.Text, g);
            status.Text = "saved: " + output + " -> " + a + (a == "led" ? " " + target.Text + " " + color.Text : "");
        }
        catch (Exception e) { status.Text = "not saved: " + e.Message; }
    }
}
