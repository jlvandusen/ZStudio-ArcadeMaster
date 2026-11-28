// AmPanel - "Set up this PC": the first-run wizard (docs/BACKLOG 1a; James 2026-11-27: "introduce the ampanel to a new
// environment and have it discover everything and emulators etc set it up and configure").
// It runs tools\Invoke-FirstRun.ps1 and shows its report live:
//   1. CHECK THIS PC - the dry run: what was found (emulators, games, RetroBat), the lists, launchers and links it would
//      make. Nothing changes.
//   2. SET IT UP     - the same with -Apply, after a yes. Links (not moves) by default, so another frontend keeps working;
//      "move instead of link" is a tick box.
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Windows.Forms;

class SetupWizard : Form
{
    readonly string tools, retroFE, manifest, importFolder;   // importFolder: "Import a folder..." (Import-Folder.py)
    readonly TextBox system = new TextBox();
    readonly TextBox log = new TextBox();
    readonly Button check = new Button(), apply = new Button(), close = new Button();
    readonly CheckBox move = new CheckBox(), rescan = new CheckBox();
    Process running;
    bool checkedOnce;

    public SetupWizard(string toolsDir, string retroFERoot, string manifestDir, string importFrom = null)
    {
        tools = toolsDir; retroFE = retroFERoot; manifest = manifestDir; importFolder = importFrom;
        Text = importFolder != null ? "ArcadeMaster - Import " + importFolder : "ArcadeMaster - Set up this PC"; Width = 1100; Height = 760; StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(14, 16, 28); ForeColor = Color.White; Font = new Font("Segoe UI", 10f);
        var head = new Label
        {
            Text = importFolder != null
                 ? "Takes in " + importFolder + ": an emulator, a system's games, or a folder of systems. It is LINKED into ArcadeMaster "
                   + "(not moved), then its lists, launchers, keys, art and lights are made.\r\nStep 1 only looks. Nothing changes until step 2. "
                   + "If it cannot tell the system, type it (snes, psx, megadrive ...) and check again."
                 : "Finds your emulators and games, makes a game list per system that runs its emulator directly, sets the "
                 + "panel's keys, lights and art. Another frontend's folders are LINKED, not moved: it keeps working.\r\n"
                 + "Step 1 only looks. Nothing changes until step 2.",
            Dock = DockStyle.Top, Height = 64, Padding = new Padding(14, 10, 14, 0), ForeColor = Color.FromArgb(200, 210, 230)
        };
        var bar = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 52, Padding = new Padding(10, 8, 10, 0) };
        Style(check, "1. CHECK THIS PC", Color.FromArgb(46, 200, 255)); Style(apply, "2. SET IT UP", Color.FromArgb(61, 220, 132));
        Style(close, "CLOSE", Color.FromArgb(120, 130, 150));
        apply.Enabled = false;
        rescan.Text = "scan the drives again"; rescan.Checked = !File.Exists(Path.Combine(manifest, "discovery.json")); rescan.AutoSize = true; rescan.Margin = new Padding(16, 10, 0, 0);
        move.Text = "move folders in instead of linking"; move.AutoSize = true; move.Margin = new Padding(16, 10, 0, 0);
        if (importFolder != null)
        {
            check.Text = "1. CHECK THE FOLDER"; apply.Text = "2. IMPORT IT"; rescan.Visible = false; rescan.Checked = false;
            move.Text = "move it in instead of linking";
            var sl = new Label { Text = "system:", AutoSize = true, Margin = new Padding(16, 12, 0, 0) };
            system.Width = 120; system.Margin = new Padding(4, 8, 0, 0);
            bar.Controls.AddRange(new Control[] { check, apply, close, move, sl, system });
        }
        else bar.Controls.AddRange(new Control[] { check, apply, close, rescan, move });
        log.Multiline = true; log.ReadOnly = true; log.ScrollBars = ScrollBars.Vertical; log.Dock = DockStyle.Fill; log.WordWrap = false;
        log.BackColor = Color.FromArgb(8, 9, 14); log.ForeColor = Color.FromArgb(220, 228, 240); log.Font = new Font("Consolas", 10f);
        Controls.Add(log); Controls.Add(bar); Controls.Add(head);
        check.Click += delegate { Run(false); };
        apply.Click += delegate {
            if (MessageBox.Show(this, "Set this PC up now?\r\n\r\nLists, launchers, emulator keys, " + (move.Checked ? "MOVED folders" : "folder links")
                + ", art and lights are written. It takes a few minutes. Safe to run again.", Text, MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes)
                Run(true);
        };
        close.Click += delegate { Close(); };
        FormClosing += delegate (object s, FormClosingEventArgs e) {
            if (running != null && !running.HasExited && MessageBox.Show(this, "Setup is still running. Stop it?", Text, MessageBoxButtons.YesNo) == DialogResult.No) e.Cancel = true;
            else if (running != null && !running.HasExited) try { running.Kill(); } catch { }
        };
    }

    static void Style(Button b, string text, Color c)
    {
        b.Text = text; b.AutoSize = true; b.Padding = new Padding(10, 4, 10, 4); b.FlatStyle = FlatStyle.Flat; b.ForeColor = c;
        b.FlatAppearance.BorderColor = c; b.Font = new Font("Segoe UI Semibold", 10.5f); b.Margin = new Padding(4, 0, 4, 0);
    }

    void Run(bool doApply)
    {
        if (running != null && !running.HasExited) return;
        string script = Path.Combine(tools, "Invoke-FirstRun.ps1");
        if (!File.Exists(script)) { Add("not found: " + script); return; }
        string args = "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\" -RetroFE \"" + retroFE + "\" -ManifestDir \"" + manifest + "\"";
        if (!rescan.Checked) args += " -SkipDiscovery";
        if (doApply) args += " -Apply";
        if (doApply && move.Checked) args += " -Move";
        if (importFolder != null)
        {
            args += " -ImportFolder \"" + importFolder + "\"";
            if (system.Text.Trim().Length > 0) args += " -ImportSystem \"" + system.Text.Trim() + "\"";
        }
        log.Clear(); Add(doApply ? "Setting this PC up ..." : "Checking this PC (nothing changes) ..." + (rescan.Checked ? " - the drive scan takes a few minutes" : ""));
        check.Enabled = apply.Enabled = false;
        var psi = new ProcessStartInfo("powershell.exe", args) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        running = new Process { StartInfo = psi, EnableRaisingEvents = true };
        running.OutputDataReceived += (s, e) => { if (e.Data != null) Add(e.Data); };
        running.ErrorDataReceived += (s, e) => { if (e.Data != null) Add("! " + e.Data); };
        running.Exited += delegate {
            BeginInvoke((MethodInvoker)delegate {
                if (!doApply) checkedOnce = true;
                Add(doApply ? "Done. Restart the frontend (or the PC) to see the new lists." : "Check finished. Nothing was changed. Press 2. SET IT UP to do it.");
                check.Enabled = true; apply.Enabled = checkedOnce; rescan.Checked = false;
            });
        };
        try { running.Start(); running.BeginOutputReadLine(); running.BeginErrorReadLine(); }
        catch (Exception e) { Add("could not start: " + e.Message); check.Enabled = true; }
    }

    void Add(string line)
    {
        if (InvokeRequired) { BeginInvoke((MethodInvoker)delegate { Add(line); }); return; }
        log.AppendText(line + "\r\n");
    }
}
