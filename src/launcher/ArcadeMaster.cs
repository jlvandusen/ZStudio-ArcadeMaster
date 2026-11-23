// ArcadeMaster.exe - launcher, setup / installer and updater for ArcadeMaster cabinets (The Real Z Studios).
//   ArcadeMaster.exe            launch: (optional) update from GitHub, then run tools\Start-ArcadeMaster.ps1 hidden
//   ArcadeMaster.exe --setup    installer / configuration window (paths, frontend, cabinet, system switches, updates)
//   ArcadeMaster.exe --update   show what is new on GitHub and update
//   ArcadeMaster.exe --dry-run  launch mode, but only print what would happen
// Config: ArcadeMaster.config.json next to the exe. Build: tools\Build-Launcher.ps1
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace ArcadeMaster
{
    public class Config
    {
        public string RepoPath = @"D:\repos\personal\ZStudio-ArcadeMaster";
        public string RepoUrl = "https://github.com/jlvandusen/ZStudio-ArcadeMaster.git";
        public string Branch = "main";
        public string RetroFERoot = @"D:\ArcadeMaster\frontend\DRIVE-coinops";
        public string ManifestDir = @"D:\ArcadeMaster\manifest";
        public bool AutoUpdate = true;
        public bool CheckOnly = false;           // tell, but do not pull
        public string CabinetType = "auto";
        public bool FollowHardware = true;
        public bool ShowAllModes = false;
        public string CabinetTitle = "";
        public string CabinetTagline = "";
        public bool SecondScreen = false;

        static string FilePath { get { return Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "ArcadeMaster.config.json"); } }
        public static Config Load()
        {
            try { if (File.Exists(FilePath)) return new JavaScriptSerializer().Deserialize<Config>(File.ReadAllText(FilePath)); } catch { }
            return new Config();
        }
        public void Save()
        {
            var json = new JavaScriptSerializer().Serialize(this);
            File.WriteAllText(FilePath, Pretty(json), new UTF8Encoding(false));
        }
        static string Pretty(string j)   // minimal JSON indenter (keeps the file hand-editable)
        {
            var sb = new StringBuilder(); int ind = 0; bool str = false;
            for (int i = 0; i < j.Length; i++)
            {
                char c = j[i];
                if (c == '"' && (i == 0 || j[i - 1] != '\\')) str = !str;
                if (str) { sb.Append(c); continue; }
                if (c == '{' || c == '[') { sb.Append(c).Append('\n').Append(new string(' ', ++ind * 2)); }
                else if (c == '}' || c == ']') { sb.Append('\n').Append(new string(' ', --ind * 2)).Append(c); }
                else if (c == ',') { sb.Append(c).Append('\n').Append(new string(' ', ind * 2)); }
                else if (c == ':') sb.Append(": ");
                else sb.Append(c);
            }
            return sb.ToString();
        }
    }

    static class Run
    {
        public static string Git = FindGit();
        static string FindGit()
        {
            foreach (var p in new[] { @"C:\Program Files\Git\cmd\git.exe", @"C:\Program Files (x86)\Git\cmd\git.exe" }) if (File.Exists(p)) return p;
            return "git.exe";
        }
        public static string PowerShell { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe"); } }

        // run a process hidden, stream its output to the callback, return exit code
        public static int Exec(string exe, string args, string cwd, Action<string> output, IDictionary<string, string> env = null)
        {
            var psi = new ProcessStartInfo(exe, args) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = cwd ?? Environment.CurrentDirectory, StandardOutputEncoding = Encoding.UTF8 };
            if (env != null) foreach (var kv in env) psi.EnvironmentVariables[kv.Key] = kv.Value;
            try
            {
                using (var p = Process.Start(psi))
                {
                    p.OutputDataReceived += (s, e) => { if (e.Data != null && output != null) output(e.Data); };
                    p.ErrorDataReceived += (s, e) => { if (e.Data != null && output != null) output(e.Data); };
                    p.BeginOutputReadLine(); p.BeginErrorReadLine(); p.WaitForExit();
                    return p.ExitCode;
                }
            }
            catch (Exception ex) { if (output != null) output("ERROR: " + ex.Message); return -1; }
        }
        public static string Capture(string exe, string args, string cwd)
        {
            var sb = new StringBuilder(); Exec(exe, args, cwd, l => sb.AppendLine(l)); return sb.ToString().Trim();
        }
        public static int Tool(Config c, string script, string args, Action<string> output, IDictionary<string, string> env = null)
        {
            var path = Path.Combine(c.RepoPath, "tools", script);
            if (!File.Exists(path)) { output("missing " + path); return -1; }
            return Exec(PowerShell, "-NoProfile -ExecutionPolicy Bypass -File \"" + path + "\" " + args, c.RepoPath, output, env);
        }
    }

    // ---------------------------------------------------------------- updates (GitHub through git)
    public class UpdateInfo { public string Local, Remote; public int Behind, Ahead; public bool Dirty; public List<string> NewCommits = new List<string>(); public string Error; }
    static class Updater
    {
        public static UpdateInfo Check(Config c)
        {
            var u = new UpdateInfo();
            if (!Directory.Exists(Path.Combine(c.RepoPath, ".git"))) { u.Error = "no git repository at " + c.RepoPath; return u; }
            int code = Run.Exec(Run.Git, "-C \"" + c.RepoPath + "\" fetch -q origin " + c.Branch, null, null);
            if (code != 0) { u.Error = "could not reach GitHub (git fetch exit " + code + ")"; }
            u.Local = Run.Capture(Run.Git, "-C \"" + c.RepoPath + "\" rev-parse --short HEAD", null);
            u.Remote = Run.Capture(Run.Git, "-C \"" + c.RepoPath + "\" rev-parse --short origin/" + c.Branch, null);
            var counts = Run.Capture(Run.Git, "-C \"" + c.RepoPath + "\" rev-list --left-right --count HEAD...origin/" + c.Branch, null).Split(new[] { '\t', ' ' }, StringSplitOptions.RemoveEmptyEntries);
            if (counts.Length == 2) { int.TryParse(counts[0], out u.Ahead); int.TryParse(counts[1], out u.Behind); }
            u.Dirty = Run.Capture(Run.Git, "-C \"" + c.RepoPath + "\" status --porcelain --untracked-files=no", null).Length > 0;
            if (u.Behind > 0) u.NewCommits = Run.Capture(Run.Git, "-C \"" + c.RepoPath + "\" log --oneline HEAD..origin/" + c.Branch, null).Split('\n').Select(s => s.Trim()).Where(s => s.Length > 0).ToList();
            return u;
        }
        // fast-forward only: never merges, never touches local changes
        public static string Apply(Config c, UpdateInfo u, Action<string> log)
        {
            if (u.Behind == 0) return "up to date (" + u.Local + ")";
            if (u.Dirty) return "update available (" + u.Behind + " commit(s)) but the repo has local changes - not pulled";
            if (u.Ahead > 0) return "update available but local commits exist - not pulled (needs a merge)";
            int code = Run.Exec(Run.Git, "-C \"" + c.RepoPath + "\" merge --ff-only -q origin/" + c.Branch, null, log);
            if (code != 0) return "update failed (git exit " + code + ")";
            StageSelfUpdate(c, log);
            return "updated " + u.Local + " -> " + u.Remote + " (" + u.Behind + " commit(s))";
        }
        // the running exe cannot be overwritten: a newer build from the repo is staged as .new and swapped in at next start
        static void StageSelfUpdate(Config c, Action<string> log)
        {
            try
            {
                var me = Process.GetCurrentProcess().MainModule.FileName; var built = Path.Combine(c.RepoPath, @"dist\ArcadeMaster.exe");
                if (File.Exists(built) && !string.Equals(Path.GetFullPath(built), Path.GetFullPath(me), StringComparison.OrdinalIgnoreCase) && File.GetLastWriteTimeUtc(built) > File.GetLastWriteTimeUtc(me))
                { File.Copy(built, me + ".new", true); log("new ArcadeMaster.exe staged - used from the next start"); }
            }
            catch (Exception ex) { log("self-update staging skipped: " + ex.Message); }
        }
        public static void SwapInStagedExe()
        {
            try
            {
                var me = Process.GetCurrentProcess().MainModule.FileName;
                if (!File.Exists(me + ".new")) return;
                if (File.Exists(me + ".old")) File.Delete(me + ".old");
                File.Move(me, me + ".old");            // a running exe may be renamed
                File.Move(me + ".new", me);
            }
            catch { }
        }
    }

    static class Program
    {
        static string LogFile(Config c) { return Path.Combine(c.ManifestDir, "launcher.log"); }
        static void Log(Config c, string m) { try { Directory.CreateDirectory(c.ManifestDir); File.AppendAllText(LogFile(c), DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + m + Environment.NewLine); } catch { } }

        [STAThread]
        static int Main(string[] args)
        {
            var a = args.Select(x => x.ToLowerInvariant()).ToList();
            var c = Config.Load();
            if (a.Contains("--update")) { Application.EnableVisualStyles(); Application.Run(new UpdateForm(c)); return 0; }
            if (a.Contains("--setup") || a.Contains("--install") || (!File.Exists(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "ArcadeMaster.config.json")) && !a.Contains("--dry-run") && !a.Contains("--launch")))
            {
                Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new SetupForm(c)); return 0;
            }

            // ---- launch
            bool dry = a.Contains("--dry-run"); Action<string> say = m => { Log(c, m); if (dry) Console.WriteLine(m); };
            // one launch at a time: players press the icon again when nothing seems to happen. A second press brings
            // the running frontend (or the starting splash) to the front instead of starting a second boot.
            bool first;
            var only = new Mutex(true, @"Local\ArcadeMaster.Launch", out first);
            if (!dry && (!first || Splash.FrontendWindow(c.RetroFERoot) != IntPtr.Zero))
            {
                say(first ? "frontend already running - brought to the front" : "already starting - brought to the front");
                Splash.BringToFront(c.RetroFERoot);
                return 0;
            }
            Splash splash = dry ? null : Splash.Show(c);
            Updater.SwapInStagedExe();
            if (c.AutoUpdate && !a.Contains("--no-update"))
            {
                var u = Updater.Check(c);
                if (u.Error != null) say("update check: " + u.Error);
                else if (c.CheckOnly || dry) say(u.Behind > 0 ? "update available: " + u.Behind + " new commit(s) on GitHub (" + u.Local + " -> " + u.Remote + ")" : "up to date (" + u.Local + ")");
                else say(Updater.Apply(c, u, say));
            }
            var start = Path.Combine(c.RepoPath, @"tools\Start-ArcadeMaster.ps1");
            if (!File.Exists(start)) { say("missing " + start + " - run ArcadeMaster.exe --setup"); if (splash != null) splash.Fail("ArcadeMaster is not set up yet - run ArcadeMaster.exe --setup"); return 2; }
            string psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + start + "\" -Root \"" + c.RetroFERoot + "\" -ManifestDir \"" + c.ManifestDir + "\"";
            if (dry) { say("would run: powershell " + psArgs); return 0; }
            say("starting ArcadeMaster: " + c.RetroFERoot);
            if (splash != null) splash.Watch();
            int rc = Run.Exec(Run.PowerShell, psArgs, c.RepoPath, null);
            if (splash != null) splash.Close();
            GC.KeepAlive(only);
            return rc;
        }
    }

    // ---------------------------------------------------------------- start-up splash
    // Boot prep (devices, controllers, menus, health check) takes 30-60 s with no window of its own. The splash covers
    // the main screen from the first click, shows the current step from <RetroFE>\arcademaster-launcher.log, and goes
    // away when RetroFE's window appears (or the boot ends).
    public class Splash
    {
        [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
        [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
        [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] static extern IntPtr FindWindow(string cls, string title);
        const string Title = "ArcadeMaster - starting";

        Form form; Label step; Panel bar; int pos; readonly Config c; volatile bool closing; long logStart = -1;
        readonly ManualResetEvent ready = new ManualResetEvent(false);

        public static IntPtr FrontendWindow(string root)
        {
            try
            {
                foreach (var p in Process.GetProcessesByName("retrofe"))
                {
                    string path = null; try { path = p.MainModule.FileName; } catch { }
                    if (path != null && path.StartsWith(root, StringComparison.OrdinalIgnoreCase) && p.MainWindowHandle != IntPtr.Zero && IsWindowVisible(p.MainWindowHandle)) return p.MainWindowHandle;
                }
            }
            catch { }
            return IntPtr.Zero;
        }

        public static void BringToFront(string root)
        {
            var h = FrontendWindow(root);
            if (h == IntPtr.Zero) h = FindWindow(null, Title);
            if (h != IntPtr.Zero) { ShowWindow(h, 9); SetForegroundWindow(h); }
        }

        Splash(Config cfg) { c = cfg; }

        public static Splash Show(Config cfg)
        {
            var s = new Splash(cfg);
            var t = new Thread(s.UiThread) { IsBackground = true }; t.SetApartmentState(ApartmentState.STA); t.Start();
            s.ready.WaitOne(3000);
            return s;
        }

        void UiThread()
        {
            Application.EnableVisualStyles();
            var scr = Screen.PrimaryScreen.Bounds;
            form = new Form { Text = Title, FormBorderStyle = FormBorderStyle.None, StartPosition = FormStartPosition.Manual, Bounds = scr, BackColor = Ui.Bg, TopMost = true, ShowInTaskbar = true };
            try { form.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
            int cx = scr.Width / 2, cy = scr.Height / 2, u = Math.Max(1, scr.Height / 1080);
            Image logo = null;
            foreach (var f in new[] { Path.Combine(c.RetroFERoot, @"layouts\ArcadeMaster\images\studio_realz.png"), Path.Combine(c.RepoPath, @"layouts\ArcadeMaster\images\studio_realz.png") })
                if (File.Exists(f)) { try { logo = Image.FromFile(f); break; } catch { } }
            int ls = 260 * u;
            if (logo != null) form.Controls.Add(new PictureBox { Image = logo, SizeMode = PictureBoxSizeMode.Zoom, Bounds = new Rectangle(cx - ls / 2, cy - ls - 40 * u, ls, ls), BackColor = Color.Transparent });
            var title = new Label { Text = "ARCADEMASTER", ForeColor = Ui.Text, Font = Ui.F(64 * u, FontStyle.Bold, "Segoe UI Black"), AutoSize = false, TextAlign = ContentAlignment.MiddleCenter, Bounds = new Rectangle(0, cy - 10 * u, scr.Width, 90 * u) };
            step = new Label { Text = "Starting up...", ForeColor = Ui.Dim, Font = Ui.F(26 * u), AutoSize = false, TextAlign = ContentAlignment.MiddleCenter, Bounds = new Rectangle(0, cy + 190 * u, scr.Width, 44 * u) };
            var track = new Panel { BackColor = Ui.Panel, Bounds = new Rectangle(cx - 300 * u, cy + 160 * u, 600 * u, 8 * u) };
            bar = new Panel { BackColor = Ui.Magenta, Bounds = new Rectangle(0, 0, 140 * u, 8 * u) };
            track.Controls.Add(bar);
            var count = new Label { Text = "", ForeColor = Ui.Cyan, Font = Ui.F(30 * u, FontStyle.Bold), AutoSize = false, TextAlign = ContentAlignment.MiddleCenter, Bounds = new Rectangle(0, cy + 95 * u, scr.Width, 44 * u) };
            form.Controls.AddRange(new Control[] { title, count, track, step });
            ThreadPool.QueueUserWorkItem(_ =>
            {
                int systems; int games = CountGames(c.RetroFERoot, out systems);
                if (games > 0) OnUi(() => count.Text = games.ToString("N0") + " games  ·  " + systems + " systems");
            });
            var tick = new System.Windows.Forms.Timer { Interval = 33 };
            tick.Tick += (s, e) => { pos = (pos + 9 * u) % (track.Width + bar.Width); bar.Left = pos - bar.Width; };
            var poll = new System.Windows.Forms.Timer { Interval = 400 };
            var started = DateTime.Now;
            poll.Tick += (s, e) =>
            {
                string m = LastStep(); if (m != null) step.Text = m;
                // RetroFE's own window is up: hand the screen over
                if (FrontendWindow(c.RetroFERoot) != IntPtr.Zero || (DateTime.Now - started).TotalMinutes > 4) { poll.Stop(); tick.Stop(); form.Close(); }
            };
            form.Shown += (s, e) => { tick.Start(); poll.Start(); ready.Set(); form.Activate(); };
            form.FormClosed += (s, e) => { closing = true; ready.Set(); };
            Application.Run(form);
        }

        // Games the frontend will list: every real game collection (a launcher or list.path, no menu.txt; merged .sub
        // views are not counted twice), its include.txt, else the files in its list folder with the listed extensions.
        public static int CountGames(string root, out int systems)
        {
            systems = 0;
            // lists that read the same folder (LEGENDS' Arcades, ArcadesMini and Fight all list MAME's roms) count once
            var games = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var folders = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                foreach (var d in Directory.GetDirectories(Path.Combine(root, "collections")))
                {
                    var name = Path.GetFileName(d);
                    if (name.StartsWith("_") || name.StartsWith("zzz", StringComparison.OrdinalIgnoreCase) || name.Equals("Main", StringComparison.OrdinalIgnoreCase)) continue;
                    if (File.Exists(Path.Combine(d, "menu.txt"))) continue;
                    var conf = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                    var sc = Path.Combine(d, "settings.conf");
                    if (File.Exists(sc))
                        foreach (var raw in File.ReadAllLines(sc))
                        {
                            var l = raw.Trim(); int eq = l.IndexOf('=');
                            if (l.Length == 0 || l.StartsWith("#") || eq < 1) continue;
                            conf[l.Substring(0, eq).Trim()] = l.Substring(eq + 1).Trim();
                        }
                    var inc = Path.Combine(d, "include.txt");
                    if (!conf.ContainsKey("launcher") && !conf.ContainsKey("list.path") && !File.Exists(inc)) continue;
                    int before = games.Count; string folder;
                    if (File.Exists(inc))
                    {
                        folder = inc;
                        foreach (var x in File.ReadAllLines(inc)) if (x.Trim().Length > 0 && !x.Trim().StartsWith("#")) games.Add(name + "|" + x.Trim());
                    }
                    else
                    {
                        string lp; var dir = conf.TryGetValue("list.path", out lp) ? Path.Combine(root, lp.Replace("%ITEM_COLLECTION_NAME%", name)) : Path.Combine(d, "roms");
                        folder = Path.GetFullPath(dir).TrimEnd('\\');
                        string ex; var exts = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                        if (conf.TryGetValue("list.extensions", out ex)) foreach (var e in ex.Split(',')) if (e.Trim().Length > 0) exts.Add("." + e.Trim().TrimStart('.'));
                        if (Directory.Exists(dir))
                            foreach (var f in Directory.EnumerateFiles(dir)) if (exts.Count == 0 || exts.Contains(Path.GetExtension(f))) games.Add(Path.GetFullPath(f));
                    }
                    if (games.Count > before && folders.Add(folder)) systems++;
                }
            }
            catch { }
            return games.Count;
        }

        // the boot log is appended for every start: only show lines written since this launch
        public void Watch() { try { var f = new FileInfo(Path.Combine(c.RetroFERoot, "arcademaster-launcher.log")); logStart = f.Exists ? f.Length : 0; } catch { } }

        string LastStep()
        {
            try
            {
                var f = Path.Combine(c.RetroFERoot, "arcademaster-launcher.log");
                if (logStart < 0 || !File.Exists(f)) return null;
                using (var fs = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    if (fs.Length <= logStart) return null;
                    fs.Seek(logStart, SeekOrigin.Begin);
                    var lines = new StreamReader(fs).ReadToEnd().Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
                    if (lines.Length == 0) return null;
                    var l = lines[lines.Length - 1];
                    if (l.StartsWith("[") && l.IndexOf(']') > 0) l = l.Substring(l.IndexOf(']') + 1).Trim();
                    if (l.StartsWith("boot prep")) return "Starting the game menu...";
                    if (l.Contains("health:")) return "System check done";
                    if (l.StartsWith("WARN") || l.StartsWith("FIXED")) return "Checking the system...";
                    return l.Length > 90 ? l.Substring(0, 87) + "..." : l;
                }
            }
            catch { return null; }
        }

        void OnUi(Action a) { try { if (form != null && !closing && form.IsHandleCreated) form.BeginInvoke(a); } catch { } }
        public void Close() { OnUi(() => form.Close()); }
        public void Fail(string m) { OnUi(() => { step.Text = m; step.ForeColor = Ui.Amber; }); Thread.Sleep(6000); Close(); }
    }

    // ---------------------------------------------------------------- UI helpers
    static class Ui
    {
        public static readonly Color Bg = Color.FromArgb(14, 15, 22), Panel = Color.FromArgb(24, 26, 36), Text = Color.FromArgb(230, 233, 240), Dim = Color.FromArgb(154, 163, 178), Magenta = Color.FromArgb(255, 47, 160), Cyan = Color.FromArgb(46, 200, 255), Green = Color.FromArgb(61, 220, 132), Amber = Color.FromArgb(255, 176, 0);
        public static Font F(float px, FontStyle st = FontStyle.Regular, string fam = "Segoe UI") { return new Font(fam, px, st, GraphicsUnit.Pixel); }
        public static Label L(string t, float px = 15, Color? c = null, FontStyle st = FontStyle.Regular) { return new Label { Text = t, AutoSize = true, ForeColor = c ?? Text, Font = F(px, st), BackColor = Color.Transparent }; }
        public static Button B(string t, Color accent) { var b = new Button { Text = t, AutoSize = true, Padding = new Padding(10, 4, 10, 4), FlatStyle = FlatStyle.Flat, ForeColor = accent, BackColor = Panel, Font = F(15, FontStyle.Bold) }; b.FlatAppearance.BorderColor = accent; return b; }
        public static CheckBox C(string t, bool v) { return new CheckBox { Text = t, Checked = v, AutoSize = true, ForeColor = Text, Font = F(15), BackColor = Color.Transparent }; }
        public static TextBox T(string v, int w = 520) { return new TextBox { Text = v, Width = w, BackColor = Panel, ForeColor = Text, BorderStyle = BorderStyle.FixedSingle, Font = F(15) }; }
        public static FlowLayoutPanel Col() { return new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true, Dock = DockStyle.Fill, Padding = new Padding(18), BackColor = Bg }; }
        public static FlowLayoutPanel Row(params Control[] cs) { var r = new FlowLayoutPanel { FlowDirection = FlowDirection.LeftToRight, AutoSize = true, WrapContents = false, BackColor = Color.Transparent, Margin = new Padding(0, 2, 0, 2) }; r.Controls.AddRange(cs); return r; }
        public static Control Path(TextBox tb, bool folder = true)
        {
            var b = B("...", Dim); b.Click += (s, e) => { using (var d = new FolderBrowserDialog { SelectedPath = tb.Text }) if (d.ShowDialog() == DialogResult.OK) tb.Text = d.SelectedPath; };
            return Row(tb, b);
        }
    }

    // ---------------------------------------------------------------- setup / installer
    public class SetupForm : Form
    {
        readonly Config c;
        TextBox repo, url, retro, manifest, title, tagline, branch;
        CheckBox useCopy, installLayout, activeLayout, toolsMenu, rebuild, follow, showAll, second, autoUpdate, checkOnly;
        CheckBox sAutoStart, sQuiet, sNoPopups, sBezels, sAlwaysOn;
        ComboBox type; TextBox log; ProgressBar bar; Label status;
        Dictionary<string, bool> sysLoaded;   // Windows state as read - only switches the user CHANGES are applied

        public SetupForm(Config cfg)
        {
            c = cfg;
            Text = "ArcadeMaster Setup - The Real Z Studios"; Width = 1000; Height = 760; BackColor = Ui.Bg; ForeColor = Ui.Text; StartPosition = FormStartPosition.CenterScreen; Font = Ui.F(15);
            var head = new Panel { Dock = DockStyle.Top, Height = 78, BackColor = Ui.Bg };
            var h1 = Ui.L("ARCADEMASTER SETUP", 30, Ui.Cyan, FontStyle.Bold | FontStyle.Italic); h1.Location = new Point(18, 8); head.Controls.Add(h1);
            var h2 = Ui.L("install, configure and update this cabinet  -  " + Environment.MachineName, 14, Ui.Magenta); h2.Location = new Point(22, 50); head.Controls.Add(h2);
            var tabs = new TabControl { Dock = DockStyle.Fill, Font = Ui.F(15) };

            // Locations
            var p1 = Ui.Col();
            repo = Ui.T(c.RepoPath); url = Ui.T(c.RepoUrl); retro = Ui.T(c.RetroFERoot); manifest = Ui.T(c.ManifestDir);
            useCopy = Ui.C("Work on a COPY of this frontend (leaves the original untouched - recommended on a cabinet you already use)", false);
            var detect = Ui.B("Find frontends", Ui.Cyan); detect.Click += (s, e) => FindFrontends();
            p1.Controls.AddRange(new Control[] { Ui.L("ArcadeMaster repository (tools, layouts)", 15, Ui.Dim), Ui.Path(repo), Ui.L("GitHub URL (cloned when the folder is empty)", 15, Ui.Dim), url,
                Ui.L("RetroFE / CoinOPS frontend root (folder with layouts\\ and collections\\)", 15, Ui.Dim), Ui.Row(Ui.Path(retro), detect), useCopy,
                Ui.L("Manifest folder (catalog, cabinet, health, logs)", 15, Ui.Dim), Ui.Path(manifest) });
            tabs.TabPages.Add(Page("Locations", p1));

            // Frontend
            var p2 = Ui.Col();
            installLayout = Ui.C("Install / refresh the ArcadeMaster layout in the frontend", true);
            activeLayout = Ui.C("Make ArcadeMaster the active theme", true);
            toolsMenu = Ui.C("Add the Tools menu (wheel setup, health, themes, cabinet type, system settings ...)", true);
            rebuild = Ui.C("Detect controllers and rebuild the game menus (Racing / Flight / Arcade ...)", true);
            p2.Controls.AddRange(new Control[] { installLayout, activeLayout, toolsMenu, rebuild, Ui.L("Themes from CoinOPS / Core builds can be imported later with tools\\Import-RetroFETheme.ps1 and picked in Tools > Themes.", 13, Ui.Dim) });
            tabs.TabPages.Add(Page("Frontend", p2));

            // Cabinet
            var p3 = Ui.Col();
            type = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 300, BackColor = Ui.Panel, ForeColor = Ui.Text, Font = Ui.F(15) };
            type.Items.AddRange(new object[] { "auto", "racing", "flight", "simulation", "standup", "lightgun", "multicade", "pedestal", "racing+lightgun", "racing+flight", "standup+lightgun" });
            type.SelectedItem = type.Items.Contains(c.CabinetType) ? c.CabinetType : "auto";
            follow = Ui.C("Follow the hardware (a racing cab with a flight stick instead of the wheel becomes a flight cab)", c.FollowHardware);
            showAll = Ui.C("Always show every mode in the main menu (off = only what is plugged in)", c.ShowAllModes);
            second = Ui.C("Use the second screen (marquee / touch panel)", c.SecondScreen);
            title = Ui.T(c.CabinetTitle, 400); tagline = Ui.T(c.CabinetTagline, 400);
            p3.Controls.AddRange(new Control[] { Ui.L("Cabinet type (boot intro, menus, mode)", 15, Ui.Dim), type, follow, showAll, second, Ui.L("Custom intro title (optional)", 15, Ui.Dim), title, Ui.L("Custom tagline (optional)", 15, Ui.Dim), tagline });
            tabs.TabPages.Add(Page("Cabinet", p3));

            // System
            var p4 = Ui.Col();
            sAutoStart = Ui.C("Start ArcadeMaster at logon (this exe)", false); sQuiet = Ui.C("Quiet startup (OneDrive / Teams / Edge stop launching; wheel & gun tools stay)", false);
            sNoPopups = Ui.C("No Windows pop-ups (Game Bar overlay, notification toasts)", false); sBezels = Ui.C("Game bezels / overlays in MAME", true); sAlwaysOn = Ui.C("Screen always on (no display / sleep timeout on mains)", true);
            var al = Ui.B("Auto login ...", Ui.Amber); al.Click += (s, e) => Process.Start("netplwiz.exe");
            var refresh = Ui.B("Read current state", Ui.Cyan); refresh.Click += (s, e) => ReadSystem();
            p4.Controls.AddRange(new Control[] { Ui.L("Every switch is reversible - the previous Windows values are saved.", 13, Ui.Dim), sAutoStart, sQuiet, sNoPopups, sBezels, sAlwaysOn, Ui.Row(al, refresh), Ui.L("Auto login uses Windows' own dialog; the password is never stored by ArcadeMaster.", 13, Ui.Dim) });
            tabs.TabPages.Add(Page("System", p4));

            // Updates
            var p5 = Ui.Col();
            autoUpdate = Ui.C("Update from GitHub every time the cabinet starts (fast-forward only, never over local changes)", c.AutoUpdate);
            checkOnly = Ui.C("Only tell me (log) - do not pull automatically", c.CheckOnly);
            branch = Ui.T(c.Branch, 200);
            var chk = Ui.B("Check GitHub now", Ui.Green); chk.Click += (s, e) => { Save(); new UpdateForm(c).ShowDialog(this); };
            p5.Controls.AddRange(new Control[] { autoUpdate, checkOnly, Ui.L("Branch", 15, Ui.Dim), branch, chk });
            tabs.TabPages.Add(Page("Updates", p5));

            // bottom: log + apply
            var bottom = new Panel { Dock = DockStyle.Bottom, Height = 230, BackColor = Ui.Bg, Padding = new Padding(12) };
            log = new TextBox { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill, BackColor = Color.Black, ForeColor = Ui.Dim, Font = Ui.F(13, FontStyle.Regular, "Consolas"), BorderStyle = BorderStyle.None };
            var bar2 = new Panel { Dock = DockStyle.Bottom, Height = 52, BackColor = Ui.Bg };
            bar = new ProgressBar { Width = 420, Height = 18, Location = new Point(4, 18) };
            status = Ui.L("", 14, Ui.Dim); status.Location = new Point(440, 16);
            var apply = Ui.B("Install / Apply", Ui.Green); apply.Dock = DockStyle.Right; apply.AutoSize = false; apply.Width = 190; apply.Click += (s, e) => ApplyAll();
            bar2.Controls.AddRange(new Control[] { bar, status, apply });
            bottom.Controls.Add(log); bottom.Controls.Add(bar2);
            Controls.Add(tabs); Controls.Add(bottom); Controls.Add(head);
            Shown += (s, e) => ReadSystem();
        }
        TabPage Page(string t, Control body) { var p = new TabPage(t) { BackColor = Ui.Bg }; p.Controls.Add(body); return p; }
        void Say(string m) { if (InvokeRequired) { BeginInvoke(new Action<string>(Say), m); return; } log.AppendText(m + Environment.NewLine); }

        void FindFrontends()
        {
            var found = new List<string>();
            foreach (var d in DriveInfo.GetDrives().Where(x => x.DriveType == DriveType.Fixed && x.IsReady))
                foreach (var dir in SafeDirs(d.RootDirectory.FullName, 3))
                    if (File.Exists(Path.Combine(dir, @"retrofe\retrofe.exe")) || File.Exists(Path.Combine(dir, @"core\retrofe.exe")) || (File.Exists(Path.Combine(dir, "retrofe.exe")) && Directory.Exists(Path.Combine(dir, "layouts")))) found.Add(dir);
            if (found.Count == 0) { Say("no RetroFE / CoinOPS frontends found (3 folders deep)"); return; }
            Say("frontends found:"); foreach (var f in found) Say("  " + f);
            retro.Text = found[0];
        }
        static IEnumerable<string> SafeDirs(string root, int depth)
        {
            var q = new Queue<Tuple<string, int>>(); q.Enqueue(Tuple.Create(root, 0));
            while (q.Count > 0)
            {
                var t = q.Dequeue(); yield return t.Item1; if (t.Item2 >= depth) continue;
                string[] subs; try { subs = Directory.GetDirectories(t.Item1); } catch { continue; }
                foreach (var s in subs) { var n = Path.GetFileName(s).ToLowerInvariant(); if (n.StartsWith("$") || n == "windows" || n.StartsWith("program") || n == "users" || n == "roms" || n == "collections" || n == "emulators") continue; q.Enqueue(Tuple.Create(s, t.Item2 + 1)); }
            }
        }
        void ReadSystem()
        {
            var cfg = Snapshot();
            new Thread(() =>
            {
                var sb = new StringBuilder(); Run.Tool(cfg, "Set-CabinetSystem.ps1", "-List -RetroFE \"" + cfg.RetroFERoot + "\" -ManifestDir \"" + cfg.ManifestDir + "\"", l => sb.AppendLine(l));
                try
                {
                    var arr = new JavaScriptSerializer().Deserialize<List<Dictionary<string, object>>>(sb.ToString());
                    var on = arr.ToDictionary(d => (string)d["id"], d => (bool)d["on"]);
                    if (File.Exists(StartupLnk)) on["autoStartArcade"] = true;
                    BeginInvoke(new Action(() =>
                    {
                        if (on.ContainsKey("autoStartArcade")) sAutoStart.Checked = on["autoStartArcade"] || File.Exists(StartupLnk);
                        if (on.ContainsKey("quietStartup")) sQuiet.Checked = on["quietStartup"];
                        if (on.ContainsKey("noOverlays")) sNoPopups.Checked = on["noOverlays"];
                        if (on.ContainsKey("gameBezels")) sBezels.Checked = on["gameBezels"];
                        if (on.ContainsKey("alwaysOn")) sAlwaysOn.Checked = on["alwaysOn"];
                        sysLoaded = new Dictionary<string, bool> { { "autoStartArcade", sAutoStart.Checked }, { "quietStartup", sQuiet.Checked }, { "noOverlays", sNoPopups.Checked }, { "gameBezels", sBezels.Checked }, { "alwaysOn", sAlwaysOn.Checked } };
                        Say("system state read (auto login: " + (on.ContainsKey("autoLogin") && on["autoLogin"] ? "on" : "off") + ")");
                    }));
                }
                catch { Say("could not read the system state (repo not installed yet?)"); }
            }) { IsBackground = true }.Start();
        }
        static string StartupLnk { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "ArcadeMaster.lnk"); } }

        Config Snapshot()
        {
            return new Config
            {
                RepoPath = repo.Text.Trim(), RepoUrl = url.Text.Trim(), RetroFERoot = retro.Text.Trim(), ManifestDir = manifest.Text.Trim(), Branch = branch.Text.Trim(),
                AutoUpdate = autoUpdate.Checked, CheckOnly = checkOnly.Checked, CabinetType = (string)type.SelectedItem, FollowHardware = follow.Checked, ShowAllModes = showAll.Checked,
                CabinetTitle = title.Text.Trim(), CabinetTagline = tagline.Text.Trim(), SecondScreen = second.Checked
            };
        }
        void Save() { var s = Snapshot(); foreach (var f in typeof(Config).GetFields()) f.SetValue(c, f.GetValue(s)); c.Save(); }

        void ApplyAll()
        {
            Save(); var cfg = Snapshot(); bool copy = useCopy.Checked;
            bool doLayout = installLayout.Checked, doActive = activeLayout.Checked, doTools = toolsMenu.Checked, doRebuild = rebuild.Checked;
            var now = new Dictionary<string, bool> { { "autoStartArcade", sAutoStart.Checked }, { "quietStartup", sQuiet.Checked }, { "noOverlays", sNoPopups.Checked }, { "gameBezels", sBezels.Checked }, { "alwaysOn", sAlwaysOn.Checked } };
            var changed = sysLoaded == null ? null : now.Where(kv => sysLoaded.ContainsKey(kv.Key) && sysLoaded[kv.Key] != kv.Value).ToDictionary(kv => kv.Key, kv => kv.Value);
            Enabled = false; bar.Value = 0;
            new Thread(() =>
            {
                try
                {
                    var steps = new List<Tuple<string, Func<bool>>>();
                    steps.Add(Tuple.Create("repository", (Func<bool>)(() =>
                    {
                        if (Directory.Exists(Path.Combine(cfg.RepoPath, ".git"))) { var u = Updater.Check(cfg); Say(Updater.Apply(cfg, u, Say)); return true; }
                        Say("cloning " + cfg.RepoUrl + " -> " + cfg.RepoPath); return Run.Exec(Run.Git, "clone " + cfg.RepoUrl + " \"" + cfg.RepoPath + "\"", null, Say) == 0;
                    })));
                    if (copy) steps.Add(Tuple.Create("frontend copy", (Func<bool>)(() =>
                    {
                        var dst = cfg.RetroFERoot.TrimEnd('\\') + "-am";
                        if (Directory.Exists(dst)) { Say("copy exists: " + dst); }
                        else { Say("copying the frontend to " + dst + " (games and media are copied too - this can take a while)"); if (Run.Exec("robocopy.exe", "\"" + cfg.RetroFERoot + "\" \"" + dst + "\" /E /NFL /NDL /NJH /NP /R:1 /W:1", null, Say) >= 8) return false; }
                        cfg.RetroFERoot = dst; c.RetroFERoot = dst; c.Save(); BeginInvoke(new Action(() => retro.Text = dst)); return true;
                    })));
                    steps.Add(Tuple.Create("cabinet settings", (Func<bool>)(() => SettingsConf(cfg))));
                    if (doLayout) steps.Add(Tuple.Create("ArcadeMaster layout", (Func<bool>)(() =>
                    {
                        var src = Path.Combine(cfg.RepoPath, @"layouts\ArcadeMaster"); var dst = Path.Combine(cfg.RetroFERoot, @"layouts\ArcadeMaster");
                        return Run.Exec("robocopy.exe", "\"" + src + "\" \"" + dst + "\" /E /XO /NFL /NDL /NJH /NP /R:1 /W:1", null, Say) < 8;
                    })));
                    if (doRebuild) steps.Add(Tuple.Create("controllers + menus", (Func<bool>)(() =>
                    {
                        var cab = Path.Combine(cfg.ManifestDir, "cabinet.json"); var games = Path.Combine(cfg.ManifestDir, "games.json"); var hist = Path.Combine(cfg.ManifestDir, "device-history.json");
                        Run.Tool(cfg, "Get-CabinetDevices.ps1", "-Out \"" + cab + "\" -History \"" + hist + "\"", Say);
                        Run.Tool(cfg, "Build-Manifest.ps1", "-RetroFE \"" + cfg.RetroFERoot + "\" -Out \"" + games + "\"", Say);
                        Run.Tool(cfg, "Add-GameControls.ps1", "-Manifest \"" + games + "\" -Cabinet \"" + cab + "\"", Say);
                        return Run.Tool(cfg, "New-RetroFECollections.ps1", "-Manifest \"" + games + "\" -RetroFE \"" + cfg.RetroFERoot + "\" -Cabinet \"" + cab + "\" -RebuildDatabase", Say) == 0;
                    })));
                    if (doTools) steps.Add(Tuple.Create("Tools menu", (Func<bool>)(() => Run.Tool(cfg, "New-CabinetToolsCollection.ps1", "-RetroFE \"" + cfg.RetroFERoot + "\" -ManifestDir \"" + cfg.ManifestDir + "\"", Say) == 0)));
                    steps.Add(Tuple.Create("cabinet mode + intro", (Func<bool>)(() =>
                    {
                        Run.Tool(cfg, "Set-CabinetMode.ps1", "-RetroFE \"" + cfg.RetroFERoot + "\" -ManifestDir \"" + cfg.ManifestDir + "\"", Say);
                        return Run.Tool(cfg, "New-CabinetIntro.ps1", "-RetroFE \"" + cfg.RetroFERoot + "\" -ManifestDir \"" + cfg.ManifestDir + "\" -Layout " + (doActive ? "ArcadeMaster" : CurrentLayout(cfg)), Say) == 0;
                    })));
                    steps.Add(Tuple.Create("system switches", (Func<bool>)(() =>
                    {
                        // ArcadeMaster.exe itself is the logon program: the Startup shortcut points at this exe
                        if (changed == null) { Say("system state was not read - Windows switches left exactly as they are"); return true; }
                        if (changed.Count == 0) { Say("no system switch changed - Windows left as it is"); return true; }
                        var me = Process.GetCurrentProcess().MainModule.FileName;
                        var set = changed.Where(kv => kv.Key != "autoStartArcade").Select(kv => kv.Key + "=" + (kv.Value ? "on" : "off")).ToList();
                        if (set.Count > 0) Run.Tool(cfg, "Set-CabinetSystem.ps1", "-Set " + string.Join(",", set) + " -RetroFE \"" + cfg.RetroFERoot + "\" -ManifestDir \"" + cfg.ManifestDir + "\"", Say);
                        if (changed.ContainsKey("autoStartArcade")) {
                            if (changed["autoStartArcade"]) { CreateShortcut(StartupLnk, me, Path.GetDirectoryName(me)); Say("Startup: ArcadeMaster.lnk -> " + me); }
                            else if (File.Exists(StartupLnk)) { File.Delete(StartupLnk); Say("Startup shortcut removed"); } }
                        return true;
                    })));
                    steps.Add(Tuple.Create("health check", (Func<bool>)(() => Run.Tool(cfg, "Repair-ArcadeHealth.ps1", "-RetroFE \"" + cfg.RetroFERoot + "\" -ManifestDir \"" + cfg.ManifestDir + "\" -Snapshot", Say) == 0)));
                    for (int i = 0; i < steps.Count; i++)
                    {
                        var st = steps[i]; Status("step " + (i + 1) + "/" + steps.Count + ": " + st.Item1);
                        Say("==== " + st.Item1); bool ok = st.Item2();
                        if (!ok) { Say("!!! " + st.Item1 + " failed - stopping"); Status("stopped at " + st.Item1); return; }
                        int pct = (i + 1) * 100 / steps.Count; BeginInvoke(new Action(() => bar.Value = pct));
                    }
                    Status("done - start the cabinet with ArcadeMaster.exe"); Say("==== done");
                }
                catch (Exception ex) { Say("ERROR " + ex.Message); }
                finally { BeginInvoke(new Action(() => Enabled = true)); }
            }) { IsBackground = true }.Start();
        }
        static string Onoff(CheckBox b) { return b.Checked ? "on" : "off"; }
        void Status(string s) { BeginInvoke(new Action(() => status.Text = s)); }
        static string CurrentLayout(Config cfg)
        {
            var sc = Path.Combine(cfg.RetroFERoot, "settings.conf");
            if (File.Exists(sc)) foreach (var l in File.ReadAllLines(sc)) { var t = l.Trim(); if (t.StartsWith("layout") && t.Contains("=")) { var k = t.Substring(0, t.IndexOf('=')).Trim(); if (k == "layout") return t.Substring(t.IndexOf('=') + 1).Trim(); } }
            return "ArcadeMaster";
        }
        bool SettingsConf(Config cfg)
        {
            var sc = Path.Combine(cfg.RetroFERoot, "settings.conf");
            if (!File.Exists(sc)) { Say("no settings.conf in " + cfg.RetroFERoot); return false; }
            File.Copy(sc, sc + ".setup-bak", true);
            var lines = File.ReadAllLines(sc).ToList();
            Action<string, string> set = (k, v) =>
            {
                int i = lines.FindIndex(l => { var t = l.TrimStart(); return t.StartsWith(k) && t.Substring(k.Length).TrimStart().StartsWith("="); });
                if (i >= 0) lines[i] = k + " = " + v; else lines.Add(k + " = " + v);
                Say("  " + k + " = " + v);
            };
            set("cabinetType", cfg.CabinetType); set("cabinetFollowHardware", cfg.FollowHardware ? "yes" : "no"); set("cabinetShowAllModes", cfg.ShowAllModes ? "yes" : "no");
            if (cfg.CabinetTitle.Length > 0) set("cabinetTitle", cfg.CabinetTitle); if (cfg.CabinetTagline.Length > 0) set("cabinetTagline", cfg.CabinetTagline);
            set("numScreens", cfg.SecondScreen ? "2" : "1"); set("enterOnCollection", "no");
            if (installLayout.Checked && activeLayout.Checked) set("layout", "ArcadeMaster");
            File.WriteAllLines(sc, lines, new UTF8Encoding(false));
            return true;
        }
        static void CreateShortcut(string lnk, string target, string dir)
        {
            var t = Type.GetTypeFromProgID("WScript.Shell"); dynamic sh = Activator.CreateInstance(t);
            dynamic s = sh.CreateShortcut(lnk); s.TargetPath = target; s.WorkingDirectory = dir; s.Description = "ArcadeMaster cabinet"; s.Save();
        }
    }

    // ---------------------------------------------------------------- updates window
    public class UpdateForm : Form
    {
        readonly Config c; Label state; ListBox list; Button go;
        UpdateInfo info;
        public UpdateForm(Config cfg)
        {
            c = cfg; Text = "ArcadeMaster - updates"; Width = 760; Height = 520; BackColor = Ui.Bg; ForeColor = Ui.Text; StartPosition = FormStartPosition.CenterParent; Font = Ui.F(15);
            var p = Ui.Col();
            var h = Ui.L("UPDATES FROM GITHUB", 24, Ui.Cyan, FontStyle.Bold | FontStyle.Italic);
            state = Ui.L("checking ...", 16); list = new ListBox { Width = 690, Height = 280, BackColor = Ui.Panel, ForeColor = Ui.Text, BorderStyle = BorderStyle.None, Font = Ui.F(14, FontStyle.Regular, "Consolas") };
            go = Ui.B("Update now", Ui.Green); go.Enabled = false; go.Click += (s, e) => { go.Enabled = false; state.Text = "updating ..."; new Thread(() => { var r = Updater.Apply(c, info, l => { }); BeginInvoke(new Action(() => state.Text = r)); }) { IsBackground = true }.Start(); };
            p.Controls.AddRange(new Control[] { h, state, list, go }); Controls.Add(p);
            Shown += (s, e) => new Thread(() =>
            {
                info = Updater.Check(c);
                BeginInvoke(new Action(() =>
                {
                    if (info.Error != null && info.Local == "") { state.Text = info.Error; return; }
                    state.Text = info.Behind > 0 ? (info.Behind + " new commit(s): " + info.Local + " -> " + info.Remote + (info.Dirty ? "  (local changes - will not pull)" : "")) : "up to date (" + info.Local + ")" + (info.Error != null ? "  - " + info.Error : "");
                    foreach (var l in info.NewCommits) list.Items.Add(l);
                    go.Enabled = info.Behind > 0 && !info.Dirty && info.Ahead == 0;
                }));
            }) { IsBackground = true }.Start();
        }
    }
}
