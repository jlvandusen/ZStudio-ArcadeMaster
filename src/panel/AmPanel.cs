// AmPanel - ArcadeMaster's panel service (docs/13-panel-service.md), step 1.
//
//   AmPanel.exe [LEDBlinky-style arguments]       e.g.  AmPanel.exe 9 "bzone" "mame"
//
// One instance lives in the system tray. Any further start hands its arguments to it over
// \\.\pipe\ArcadeMaster.Panel and exits at once (LEDBlinky works the same way: "only one instance will remain").
// It understands LEDBlinky's documented command line (LEDBlinky Readme.txt), keeps the frontend's state in
// <manifest>\panel-state.json, answers {"cmd":"status"} on the pipe, and - in this step - passes every command on to
// LEDBlinky.exe (shadow mode), so the lights keep working exactly as before while AmPanel takes over feature by feature.
//
// Built from published interfaces only: LEDBlinky's documented command line and Ultimarc's PacDrive SDK
// (PacDrive32.dll, 32-bit - this exe is x86). Step 1 only READS the boards; no LED or restrictor is changed.
// C# 5 (the .NET Framework's own csc builds it on any cabinet).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

static class AmPanel
{
    const string PipeName = "ArcadeMaster.Panel";
    const string MutexName = "Local\\ArcadeMaster.Panel";

    // ---------------------------------------------------------------- Ultimarc PacDrive SDK (read-only in step 1)
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool SetDllDirectory(string path);
    [DllImport("PacDrive32.dll", CallingConvention = CallingConvention.StdCall)] static extern int PacInitialize();
    [DllImport("PacDrive32.dll", CallingConvention = CallingConvention.StdCall)] static extern void PacShutdown();
    [DllImport("PacDrive32.dll", CallingConvention = CallingConvention.StdCall)] static extern int PacGetDeviceType(int id);
    [DllImport("PacDrive32.dll", CallingConvention = CallingConvention.StdCall)] static extern int PacGetVendorId(int id);
    [DllImport("PacDrive32.dll", CallingConvention = CallingConvention.StdCall)] static extern int PacGetProductId(int id);

    static readonly string[] DeviceKinds = { "Unknown", "PacDrive", "U-HID", "PacLED64", "Nano-LED", "Blue-HID", "I-PAC Ultimate I/O", "ServoStik", "U-HID Nano" };

    // ---------------------------------------------------------------- state
    static readonly object Gate = new object();
    static readonly Dictionary<string, object> State = new Dictionary<string, object>();
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    static string manifestDir, ledBlinkyDir, logFile;
    static bool passThrough = true;    // AmPanel.json "PassThrough": false = do not hand commands to LEDBlinky.exe (tests)
    static LedEngine leds;             // AmPanel.json "Lights": "own" = AmPanel drives the button LEDs (step 2), not LEDBlinky
    static OutputListener outputs;     // step 9: MAME-protocol emulator outputs (always on: it only listens)
    static TriggerRules rules;         // step 10: output -> activity
    static ReactiveKeys glow;          // step 5: held buttons glow ("Reactive": false turns it off)
    static DeviceWatcher devices;      // hot-plug: a controller plugged in / pulled updates the cabinet (Update-Controllers.ps1)
    static Sticks sticks;              // UltraStik maps per game: AmPanel.json "Sticks": "own" (default: on when Lights = own)
    static bool sticksOwn;
    static string speech = "off";         // AmPanel.json "Speech": off | start
    static ExitGuard exitGuard;           // Esc ends any game (AmPanel.json "ExitKey": "ESC" | "none", "ExitGraceMs")
    static string exitKey = "ESC";
    static int exitGraceMs = 1500;
    static string gameStartAnimation, gamePauseAnimation;   // AmPanel.json defaults (.lwax name or "random"); per-game files win
    static ControllerChoices choicesDb;   // "which controller will you use?" (controller-choices.json)
    static Control ui;                    // created on the tray thread: pipe threads show windows through it
    static string toolsDir, retroFERoot;
    static bool reactive = true;
    static string attractAnimation = "chase";   // step 6: AmPanel.json "AttractAnimation": chase | breathe
    static Marquee marquee;               // AmPanel.json "Marquee": "pixelcade" = AmPanel drives the Pixelcade LED marquee, not LEDBlinky
    static PadKeys padKeys;               // wheel / stick buttons that type keys in games - G HUB's key mappings (PadKeys.cs); "PadKeys": "off"
    static bool padKeysOff;
    static NotifyIcon tray;
    static volatile bool quitting;

    [STAThread]
    static int Main(string[] args)
    {
        // AmPanel.exe --snapshot-sticks <rom> <png>: draw the Sticks & Guns window off-screen to a picture (docs, tests)
        if (args.Length == 3 && args[0] == "--snapshot-sticks")
        {
            LoadConfig();
            using (var f = new StickStudio(null, manifestDir, ledBlinkyDir, Gate, args[1], delegate { }) { StartPosition = FormStartPosition.Manual, Location = new System.Drawing.Point(-20000, -20000), ShowInTaskbar = false })
            {
                f.Show(); Application.DoEvents();
                using (var bmp = new System.Drawing.Bitmap(f.Width, f.Height)) { f.DrawToBitmap(bmp, new System.Drawing.Rectangle(0, 0, f.Width, f.Height)); bmp.Save(args[2]); }
                f.Close();
            }
            return 0;
        }
        // AmPanel.exe choose <item> [collection]: asked by the frontend right before a game starts, and WAITS for the
        // answer. Prints the choice id (empty = no question for this game); exit code 0 = answered / nothing to ask.
        if (args.Length >= 2 && args[0] == "choose")
        {
            try
            {
                using (var c = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut))
                {
                    c.Connect(1500);
                    var w = new StreamWriter(c, new UTF8Encoding(false)) { AutoFlush = true };
                    var req = new Dictionary<string, object> { { "cmd", "choose" }, { "game", args[1] } };
                    if (args.Length > 2) req["collection"] = args[2];
                    w.WriteLine(Json.Serialize(req));
                    var rep = Json.Deserialize<Dictionary<string, object>>(new StreamReader(c, Encoding.UTF8).ReadLine() ?? "{}");
                    Console.WriteLine(rep.ContainsKey("choice") ? Convert.ToString(rep["choice"]) : "");
                    if (rep.ContainsKey("stickMap")) Console.WriteLine("stickMap=" + rep["stickMap"]);
                    return 0;
                }
            }
            catch { return 0; }   // no AmPanel: the game simply starts
        }
        // AmPanel.exe --snapshot-choose <item> <png>: the controller question drawn off-screen (docs, tests)
        if (args.Length == 3 && args[0] == "--snapshot-choose")
        {
            LoadConfig();
            var db = new ControllerChoices(manifestDir); string id = db.Find(args[1], null);
            string sc = id != null && id.IndexOf(':') > 0 ? id.Substring(0, id.IndexOf(':')) : null;
            using (var f = new ControllerChooser(db.Title(id), db.Choices(id), db.LastPick(id), 8, ChooserTheme.Load(retroFERoot, sc, args[1])))
            {
                f.TopMost = false; f.Bounds = new System.Drawing.Rectangle(-20000, -20000, 1920, 1080);
                f.Show(); Application.DoEvents();
                using (var bmp = new System.Drawing.Bitmap(f.Width, f.Height)) { f.DrawToBitmap(bmp, new System.Drawing.Rectangle(0, 0, f.Width, f.Height)); bmp.Save(args[2]); }
            }
            return 0;
        }
        bool created;
        using (var mutex = new Mutex(true, MutexName, out created))
        {
            if (!created) return Forward(args) ? 0 : 1;   // the running AmPanel handles it
            // The LEDBlinky.exe shim (ampanel-shim\) must never become the long-running AmPanel: RetroFE WAITS for every
            // LEDBlinky call, so a shim that stays up freezes the frontend on a black screen (DESKTOP-RACE2 2026-11-26,
            // after a Tools page had taken the real AmPanel down with it). No AmPanel running: start the real one (one
            // folder up) outside RetroFE's job through WMI, hand it this command, and exit.
            string self = Path.GetFileName(Application.ExecutablePath);
            string real = Path.Combine(Path.GetDirectoryName(AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\')) ?? "", "AmPanel.exe");
            if (self.Equals("LEDBlinky.exe", StringComparison.OrdinalIgnoreCase) && File.Exists(real))
            {
                mutex.ReleaseMutex(); mutex.Close();   // closed, not just released: an open handle keeps the named mutex alive and
                                                       // the real AmPanel would think it is already running and quit
                try
                {
                    using (var wmi = new System.Management.ManagementClass("Win32_Process"))
                        wmi.InvokeMethod("Create", new object[] { "\"" + real + "\" 1", Path.GetDirectoryName(real), null, null });
                }
                catch { try { Process.Start(new ProcessStartInfo(real, "1") { WorkingDirectory = Path.GetDirectoryName(real), UseShellExecute = false }); } catch { } }
                var wait = Stopwatch.StartNew();   // at most ~4 s in all: RetroFE is waiting on this call
                while (wait.ElapsedMilliseconds < 4000) { System.Threading.Thread.Sleep(250); if (Forward(args)) return 0; }
                return 0;
            }
            LoadConfig();
            Log("AmPanel started (" + string.Join(" ", args) + ")");
            lock (Gate)
            {
                State["service"] = "AmPanel";
                State["version"] = 1;
                State["mode"] = leds != null ? "own" : "shadow";   // shadow: LEDBlinky still drives the lights
                State["startedAt"] = DateTime.Now.ToString("s");
                State["boards"] = ReadBoards();
                if (leds != null)
                {
                    bool ok = leds.Open();
                    State["lights"] = ok ? string.Format("own: {0} LED board(s), {1} buttons mapped, colours for {2} games", leds.Boards, leds.Buttons, leds.Games)
                                         : "own, but LED boards not opened: " + leds.LastError;
                    if (!ok) leds = null;
                    else { var le = leds; StickStudio.ServoHook = delegate(bool four) { return le.Servo(four); }; }
                }
                if (sticksOwn)
                {
                    sticks = new Sticks(manifestDir, ledBlinkyDir, Log);
                    State["sticks"] = sticks.Count + " UltraStik(s)" + (sticks.LastError != null ? " - " + sticks.LastError : "");
                    if (sticks.Count == 0) { sticks.Close(); sticks = null; }
                }
                State["ledBlinkyRunning"] = Process.GetProcessesByName("LEDBlinky").Length > 0;
                State["guns"] = Guns.Find();   // step 7: light guns plugged in (AimTrak / Sinden / Gun4IR)
            }
            Handle(args, false);
            new Thread(PipeServer) { IsBackground = true, Name = "pipe" }.Start();
            RunTray();
            quitting = true;
            if (leds != null) leds.Close();
            if (sticks != null) sticks.Close();
            Log("AmPanel stopped");
            return 0;
        }
    }

    // ---------------------------------------------------------------- config: <exe dir>\AmPanel.json, else the cabinet's
    static void LoadConfig()
    {
        string exeDir = AppDomain.CurrentDomain.BaseDirectory;
        // next to the exe, else one folder up: the LEDBlinky.exe shim (ampanel-shim\) shares the installed AmPanel's config
        var cfg = ReadJson(Path.Combine(exeDir, "AmPanel.json")) ?? ReadJson(Path.Combine(Path.GetDirectoryName(exeDir.TrimEnd('\\')) ?? exeDir, "AmPanel.json"));
        manifestDir = Str(cfg, "ManifestDir");
        ledBlinkyDir = Str(cfg, "LEDBlinkyDir");
        if (Str(cfg, "PassThrough") != null) passThrough = Convert.ToBoolean(cfg["PassThrough"]);
        if (Str(cfg, "TraceOutputs") != null) OutputListener.Trace = Convert.ToBoolean(cfg["TraceOutputs"]);
        if (Str(cfg, "Reactive") != null) reactive = Convert.ToBoolean(cfg["Reactive"]);
        if (Str(cfg, "AttractAnimation") != null) attractAnimation = Str(cfg, "AttractAnimation").ToLowerInvariant();
        if (Str(cfg, "Speech") != null) speech = Str(cfg, "Speech").ToLowerInvariant();
        if (Str(cfg, "ExitKey") != null) exitKey = Str(cfg, "ExitKey");
        if (Str(cfg, "ExitGraceMs") != null) exitGraceMs = Convert.ToInt32(cfg["ExitGraceMs"]);
        gameStartAnimation = Str(cfg, "GameStartAnimation"); gamePauseAnimation = Str(cfg, "GamePauseAnimation");
        // AmPanel.json "LoadingScreen": "off" - no LOADING screen over a starting game (James 2026-11-26 on DESKTOP-RACE2:
        // Batman went windowed; anything on top of an exclusive-fullscreen game while it starts is a risk)
        loadingOff = string.Equals(Str(cfg, "LoadingScreen"), "off", StringComparison.OrdinalIgnoreCase);
        padKeysOff = string.Equals(Str(cfg, "PadKeys"), "off", StringComparison.OrdinalIgnoreCase);
        if (manifestDir == null)
        {
            // the launcher's config (ArcadeMaster.config.json) next to this exe or one folder up
            foreach (var p in new[] { Path.Combine(exeDir, "ArcadeMaster.config.json"), Path.Combine(Path.GetDirectoryName(exeDir.TrimEnd('\\')) ?? exeDir, "ArcadeMaster.config.json") })
            {
                var lc = ReadJson(p);
                if (lc == null) continue;
                manifestDir = Str(lc, "ManifestDir");
                string root = Str(lc, "RetroFERoot");
                if (ledBlinkyDir == null && root != null) ledBlinkyDir = Path.Combine(root, "LEDBlinky");
                break;
            }
        }
        // the repo's tools and the frontend root (hot-plug refresh) always come from the launcher's config
        foreach (var p in new[] { Path.Combine(exeDir, "ArcadeMaster.config.json"), Path.Combine(Path.GetDirectoryName(exeDir.TrimEnd('\\')) ?? exeDir, "ArcadeMaster.config.json") })
        {
            var lc = ReadJson(p); if (lc == null) continue;
            if (Str(lc, "RepoPath") != null) toolsDir = Path.Combine(Str(lc, "RepoPath"), "tools");
            retroFERoot = Str(lc, "RetroFERoot");
            break;
        }
        if (manifestDir == null) manifestDir = Path.Combine(exeDir, "manifest");
        Directory.CreateDirectory(manifestDir);
        logFile = Path.Combine(manifestDir, "ampanel.log");
        Speech.Init(manifestDir);
        if (ledBlinkyDir != null && Directory.Exists(ledBlinkyDir)) SetDllDirectory(ledBlinkyDir);   // PacDrive32.dll lives there
        if (string.Equals(Str(cfg, "Lights"), "own", StringComparison.OrdinalIgnoreCase) && ledBlinkyDir != null) {
            LedEngine.LearnedMap = Path.Combine(manifestDir, "LEDBlinkyInputMap-learned.xml");   // the Buttons window's map wins
            leds = new LedEngine(ledBlinkyDir);
            leds.LoadOverrides(Path.Combine(manifestDir, "led-colors.json"));   // this cabinet's own colours (step 11)
            leds.LoadAuto(Path.Combine(manifestDir, "led-colors-auto.json"));    // games Colors.ini doesn't know (New-LedColorsAuto.py)
            Log("lights: generated colours for " + leds.AutoGames + " games" + (leds.LastError != null ? " - " + leds.LastError : ""));
            leds.LwaDir = Path.Combine(ledBlinkyDir, "lwa");                     // LEDBlinky's .lwax animations
            passThrough = false;       // two programs must never drive the same boards
        }
        // the Pixelcade marquee: LEDBlinky's own [Pixelcade] settings first (same look as before), AmPanel.json wins
        if (string.Equals(Str(cfg, "Marquee"), "pixelcade", StringComparison.OrdinalIgnoreCase))
        {
            marquee = new Marquee(Log);
            marquee.LoadLEDBlinkySettings(ledBlinkyDir);
            if (Str(cfg, "PixelcadeUrl") != null) marquee.BaseUrl = Str(cfg, "PixelcadeUrl");
            if (Str(cfg, "PixelcadeDir") != null) marquee.PixelcadeDir = Str(cfg, "PixelcadeDir");
            if (Str(cfg, "MarqueeStartText") != null) marquee.StartText = Str(cfg, "MarqueeStartText");
            if (Str(cfg, "MarqueeQuitText") != null) marquee.QuitText = Str(cfg, "MarqueeQuitText");
            if (Str(cfg, "MarqueeNowPlaying") != null) marquee.NowPlaying = Str(cfg, "MarqueeNowPlaying");
            if (Str(cfg, "MarqueeColor") != null) marquee.Color = Str(cfg, "MarqueeColor");
            if (Str(cfg, "MarqueeSpeed") != null) marquee.Speed = Str(cfg, "MarqueeSpeed");
            if (Str(cfg, "MarqueeScreensaver") != null) marquee.Screensaver = Str(cfg, "MarqueeScreensaver").ToLowerInvariant();
            // two programs must never drive the same marquee: LEDBlinky stops getting the commands, unless
            // AmPanel.json asks for it with "PassThrough": true (then LEDBlinky's UsePixelcade must be 0)
            if (Str(cfg, "PassThrough") == null) passThrough = false;
            else if (passThrough) Log("marquee: PassThrough is on - set UsePixelcade=0 in LEDBlinky's Settings.ini, or both drive the marquee");
        }
        // the sticks follow the lights unless AmPanel.json says otherwise ("Sticks": "own" | "ledblinky")
        string st = Str(cfg, "Sticks");
        sticksOwn = st != null ? st.Equals("own", StringComparison.OrdinalIgnoreCase) : leds != null;
    }

    // ---------------------------------------------------------------- boards (PacDrive SDK)
    static List<object> ReadBoards()
    {
        var list = new List<object>();
        try
        {
            int n = PacInitialize();
            for (int i = 0; i < n; i++)
            {
                int t = PacGetDeviceType(i);
                var b = new Dictionary<string, object>();
                b["index"] = i; b["type"] = t;
                b["kind"] = t >= 0 && t < DeviceKinds.Length ? DeviceKinds[t] : "type " + t;
                b["usb"] = PacGetVendorId(i).ToString("X4") + ":" + PacGetProductId(i).ToString("X4");
                b["leds"] = t == 3 ? 64 : t == 4 ? 60 : t == 6 ? 96 : 0;
                list.Add(b);
            }
            PacShutdown();   // step 1 only reads: LEDBlinky keeps the boards
        }
        catch (Exception e) { Log("boards: PacDrive SDK not available (" + e.Message + ")"); }
        return list;
    }

    static void OpenButtons()
    {
        var f = new ButtonStudio(leds, Gate, manifestDir, delegate {
            lock (Gate) leds.LightGame(Convert.ToString(State.ContainsKey("selected") ? State["selected"] : null));   // normal lights again
        });
        f.Show(); f.Activate();
    }

    // ---------------------------------------------------------------- touch-screen search (Search.cs)
    // a SEARCH pill on the touch screen while the menus are up; it opens the search page. Needs RetroFE's cabinet link
    // (settings.conf linkEvents = yes) to jump, and <manifest>\search-index.json (tools/New-SearchIndex.py).
    static GameLink gameLink;
    static SearchIndex searchIndex;
    static SearchButton searchButton;
    static SearchScreen searchScreen;
    static void StartSearch()
    {
        try
        {
            bool touchScreen = Screen.AllScreens.Length >= 2;
            searchIndex = new SearchIndex(Path.Combine(manifestDir, "search-index.json"));
            if (searchIndex.Games.Count == 0) { Log("search: no search-index.json (tools/New-SearchIndex.py)"); return; }
            searchIndex.LoadOpenable(retroFERoot);   // search across all systems: only lists the frontend can open
            gameLink = new GameLink(Log); gameLink.Start();
            var th = ChooserTheme.Load(retroFERoot, null, null);
            // F3 on a keyboard opens the search in keyboard mode, on any cabinet (James 2026-11-26: the 2-player cabinet has
            // a keyboard below the panel and no touch screen). Only in the menus, never during a game.
            if (glow != null)
                glow.KeyPressed = delegate (int vk) {
                    if (vk != 0x72 /* F3 */) return;
                    bool inGame; lock (Gate) inGame = State.ContainsKey("playing") && State["playing"] is bool && (bool)State["playing"];
                    if (inGame || Process.GetProcessesByName("retrofe").Length == 0) return;
                    ui.BeginInvoke((MethodInvoker)delegate {
                        if (searchScreen != null && !searchScreen.IsDisposed) { searchScreen.Close(); return; }
                        searchScreen = new SearchScreen(searchIndex, gameLink, th, retroFERoot, true);
                        searchScreen.FormClosed += delegate { searchScreen = null; };
                        searchScreen.Show();
                    });
                };
            if (!touchScreen) { Log("search: " + searchIndex.Games.Count + " games indexed, F3 opens it (one screen: no SEARCH button)"); return; }
            searchButton = new SearchButton(th);
            searchButton.Tapped += delegate {
                if (searchScreen != null && !searchScreen.IsDisposed) return;
                searchScreen = new SearchScreen(searchIndex, gameLink, th, retroFERoot);
                searchScreen.FormClosed += delegate { searchScreen = null; };
                searchScreen.Show();
            };
            // shown while the menus are up, hidden while a game runs or the frontend is closed
            var t = new System.Windows.Forms.Timer { Interval = 500 };
            t.Tick += delegate {
                bool playing, frontend;
                lock (Gate) { playing = State.ContainsKey("playing") && State["playing"] is bool && (bool)State["playing"]; frontend = Process.GetProcessesByName("retrofe").Length > 0; }
                bool want = frontend && !playing && searchScreen == null;
                if (want && !searchButton.Visible) searchButton.Show(); else if (!want && searchButton.Visible) searchButton.Hide();
                if (playing && searchScreen != null) searchScreen.Close();
                searchButton.KeepOnTop(); if (searchScreen != null) searchScreen.KeepOnTop();
                if (frontend && !playing) { var fr = FrontendFocus.Guard(); if (fr != null) Log("focus: " + fr); }
            };
            t.Start();
            Log("search: " + searchIndex.Games.Count + " games indexed, SEARCH button on the touch screen");
        }
        catch (Exception e) { Log("search: not started - " + e.Message); }
    }

    // ---------------------------------------------------------------- the LOADING screen (LoadingScreen.cs)
    static LoadingScreen loading;
    static bool loadingOff;             // AmPanel.json "LoadingScreen": "off"
    static int loadingSeq;
    static void ShowLoadingLater(string game)
    {
        if (loadingOff || ui == null || string.IsNullOrEmpty(game) || game.StartsWith("__")) return;
        if (State.ContainsKey("emulator") && Convert.ToString(State["emulator"]) == "am_tools") return;   // Tools pages draw their own
        int seq = System.Threading.Interlocked.Increment(ref loadingSeq);
        HashSet<IntPtr> baseline;
        try { baseline = LoadingScreen.Snapshot(); } catch { return; }
        // the game opens on the main screen, and is moved there if it lands on the touch screen
        var keep = baseline;
        System.Threading.ThreadPool.QueueUserWorkItem(delegate {
            LoadingScreen.KeepGameOnMainScreen(keep, delegate { lock (Gate) return State.ContainsKey("playing") && State["playing"] is bool && (bool)State["playing"]; }, Log);
        });
        System.Threading.ThreadPool.QueueUserWorkItem(delegate {
            System.Threading.Thread.Sleep(LoadingScreen.ShowAfterMs);
            if (seq != loadingSeq) return;
            lock (Gate) { if (!(State.ContainsKey("playing") && State["playing"] is bool && (bool)State["playing"])) return; }
            try { if (LoadingScreen.NewWindowSince(baseline)) return; } catch { return; }   // the game is up already (MAME ...)
            try
            {
                ui.BeginInvoke((MethodInvoker)delegate {
                    if (seq != loadingSeq || loading != null) return;
                    try
                    {
                        LoadingScreen.Log = Log;
                        var f = new LoadingScreen(Speech.Title(game), LoadingScreen.ThemeFor(retroFERoot, game), baseline);
                        f.FormClosed += delegate { if (loading == f) loading = null; };
                        loading = f; f.Show();
                        Log("loading screen up for " + game);
                    }
                    catch (Exception e) { Log("loading screen: " + e.Message); }
                });
            }
            catch { }
        });
    }
    // self-heal (2026-11-26): after a game ends, tools\Repair-GameRoms.py reads the emulator's log (Supermodel) or verifies
    // a MAME set that closed within 20 s, and swaps in a complete copy of the set from another build on the drive
    static string healGame, healCollection, healEmulator;
    static DateTime healStarted;
    static void RepairRoms(string item, string collection, string emulator, double ran)
    {
        if (toolsDir == null || retroFERoot == null || string.IsNullOrEmpty(collection)) return;
        string script = Path.Combine(toolsDir, "Repair-GameRoms.py");
        if (!File.Exists(script)) return;
        string py = Path.Combine(Environment.GetEnvironmentVariable("LOCALAPPDATA") ?? "", @"Programs\Python\Python312\python.exe");
        if (!File.Exists(py)) py = "python";
        string args = "\"" + script + "\" --retrofe \"" + retroFERoot + "\" --manifest \"" + manifestDir + "\" --item \"" + item +
                      "\" --collection \"" + collection + "\" --emulator \"" + (emulator ?? "") + "\" --ran " + ((int)ran).ToString();
        System.Threading.ThreadPool.QueueUserWorkItem(delegate {
            try
            {
                var psi = new System.Diagnostics.ProcessStartInfo(py, args) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
                using (var p = System.Diagnostics.Process.Start(psi))
                {
                    string o = p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
                    p.WaitForExit(600000);
                    Log(o.Trim().Length > 0 ? o.Trim() : "roms: " + item + " checked");
                }
            }
            catch (Exception e) { Log("roms: repair failed for " + item + " - " + e.Message); }
        });
    }
    static void CloseLoading()
    {
        System.Threading.Interlocked.Increment(ref loadingSeq);
        if (ui == null) return;
        try { ui.BeginInvoke((MethodInvoker)delegate { if (loading != null && !loading.IsDisposed) loading.Close(); loading = null; }); } catch { }
    }

    // ---------------------------------------------------------------- LEDBlinky's documented command line
    static void Handle(string[] a, bool forwarded)
    {
        string what;
        lock (Gate)
        {
            string c = a.Length > 0 ? a[0] : "1";
            string arg1 = a.Length > 1 ? a[1] : null, arg2 = a.Length > 2 ? a[2] : null;
            // LEDBlinky command 3 = game start: "3 <rom> <emulator>" (RetroFE sends this form). Without this the game was
            // taken to be "3": every button lit white and the exit guard saw the rom as the emulator (2026-11-26)
            if (c == "3" && arg1 != null) { c = arg1; arg1 = arg2; arg2 = a.Length > 3 ? a[3] : null; }
            switch (c)
            {
                case "1": State["frontend"] = "running"; what = "frontend start"; break;
                case "2": State["frontend"] = "quit"; State["game"] = null; what = "frontend quit"; break;
                case "4": State["playing"] = false; what = "game stop"; break;
                case "5": State["screensaver"] = true; what = "screensaver start"; break;
                case "6": State["screensaver"] = false; what = "screensaver stop"; break;
                case "8": if (arg1 != null) State["emulator"] = arg1; what = "list change"; break;
                case "9": State["selected"] = arg1; if (arg2 != null) State["emulator"] = arg2; what = "game selected"; break;
                case "11": State["animation"] = null; what = "animation stop"; break;
                // 12: LEDBlinky reads a MAME -ctrlr file to translate input codes; AmPanel lights by Colors.ini labels,
                // so it only records which file the game uses (status: ctrlr)
                case "12": State["ctrlr"] = arg1; what = "MAME controller file " + arg1; break;
                case "13": State["ultrastikMap"] = arg1 ?? "joy8way"; what = "UltraStik map"; break;
                case "14": what = "set LED ports"; break;
                case "15": if (arg1 != null) State["selected"] = arg1; what = "light game controls"; break;
                case "16": State["paused"] = true; what = "game pause"; break;
                case "17": State["paused"] = false; what = "game unpause"; break;
                default:
                    if (c.EndsWith(".lwax", StringComparison.OrdinalIgnoreCase)) { State["animation"] = c; what = "animation start"; }
                    // a main-menu entry (EXIT, CORE's cmd) is not a game: RetroFE "starts" it from the Main collection. As a
                    // game it armed the Esc exit guard, which then closed Edge on the desktop after a menu Exit (2026-11-26)
                    else if (string.Equals(arg1, "main", StringComparison.OrdinalIgnoreCase)) what = "main menu entry " + c;
                    else { State["playing"] = true; State["game"] = c; if (arg1 != null) State["emulator"] = arg1; State["paused"] = false; what = "game start"; }
                    break;
            }
            if (leds != null)
            {
                // the documented events that change what the panel shows
                if (c == "9" || c == "15") State["lights"] = leds.LightGame(Convert.ToString(State.ContainsKey("selected") ? State["selected"] : null));
                else if (c == "2") { leds.AllOff(); State["lights"] = "off (frontend quit)"; }
                else if (c == "5") State["lights"] = "attract: " + (attractAnimation.EndsWith(".lwax") || attractAnimation == "random" ? leds.Play(attractAnimation, true) : leds.Animate(attractAnimation));
                else if (c == "11") State["lights"] = leds.Animate("stop");
                else if (what == "animation start") State["lights"] = leds.Play(c, true);
                else if (c == "6") State["lights"] = leds.Animate("stop");
                else if (what == "game start")
                {
                    // the game's colours, then LEDBlinky's per-game animations (lwa\GameSpecific): GamePlay loops for
                    // the whole game, else GameStart (the game's own file, or AmPanel.json GameStartAnimation) plays once
                    State["lights"] = leds.LightGame(c);
                    string play = leds.GameAnimation("GamePlay", c), start = leds.GameAnimation("GameStart", c) ?? gameStartAnimation;
                    if (play != null) State["lights"] = leds.Play(play, true);
                    else if (start != null) State["lights"] = leds.Play(start, false);
                }
                else if (c == "4")
                {
                    // back in the menus: no game animation outlives the game; the selected game's colours again
                    leds.Animate("stop"); leds.AudioFollowOff();
                    string sel =Convert.ToString(State.ContainsKey("selected") && State["selected"] != null ? State["selected"] : State.ContainsKey("game") ? State["game"] : null);
                    State["lights"] = leds.LightGame(sel);
                }
                else if (c == "14") State["lights"] = leds.SetPorts(string.Join(",", a, 1, a.Length - 1));
                else if (c == "16")
                {
                    string g = Convert.ToString(State.ContainsKey("game") ? State["game"] : null), pause = leds.GameAnimation("GamePause", g) ?? gamePauseAnimation;
                    State["lights"] = pause != null ? leds.Play(pause, true) : leds.Dim(true);
                }
                else if (c == "17")
                {
                    string g = Convert.ToString(State.ContainsKey("game") ? State["game"] : null), play = leds.GameAnimation("GamePlay", g);
                    State["lights"] = play != null ? leds.Play(play, true) : leds.Dim(false);
                }
            }
            // UltraStik: the game's map at start (written only when it changes), 8-way back in the menus, 13 = this map now
            if (sticks != null)
            {
                if (what == "game start")
                {
                    State["stick"] = sticks.Load(null, c, false);
                    // the ServoStik restrictor follows the game's map: 4-way (and 2-way) games flip it to 4-way
                    if (leds != null)
                    {
                        string mp = sticks.MapFor(c) ?? "";
                        string r = leds.Servo(mp.IndexOf("4", StringComparison.Ordinal) >= 0 || mp.IndexOf("2", StringComparison.Ordinal) >= 0);
                        State["servo"] = r; Log(r + " for " + c);
                    }
                }
                else if (c == "13") State["stick"] = sticks.Load(arg1, null, true);
                else if (what == "game stop" || what == "frontend start")
                {
                    State["stick"] = sticks.Load(null, null, false);
                    if (leds != null) State["servo"] = leds.Servo(false);   // menus: 8-way
                }
            }
            if (what == "game start" && speech == "start") Speech.Say("Now playing " + Speech.Title(c));
            if (marquee != null)
            {
                string emu = Convert.ToString(State.ContainsKey("emulator") ? State["emulator"] : null);
                string sel = Convert.ToString(State.ContainsKey("selected") ? State["selected"] : null);
                if (c == "1") marquee.FrontendStart();
                else if (c == "2") marquee.FrontendQuit();
                else if (c == "8") marquee.ListChange(emu);
                else if (c == "9" || c == "15") marquee.Selected(sel, emu);
                else if (c == "5") marquee.ScreensaverStart();
                else if (c == "6") marquee.ScreensaverStop(sel, emu);
                else if (c == "4") marquee.GameStop(sel, emu);
                else if (what == "game start") marquee.GameStart(c, emu, Speech.Title(c));
                State["marquee"] = marquee.Status();
            }
            // hot-plug refreshes wait while a game runs (James: no effect on game performance)
            if (devices != null)
            {
                if (what == "game start") devices.GameRunning = true;
                else if (what == "game stop" || what == "frontend start" || what == "game selected" || what == "frontend quit") { devices.GameRunning = false; devices.Resume(); }
            }
            // the universal end-game key is armed only while a game runs
            if (exitGuard != null)
            {
                if (what == "game start") { exitGuard.Emulator = Convert.ToString(State.ContainsKey("emulator") ? State["emulator"] : null); exitGuard.GameRunning = true; }
                else if (what == "game stop" || what == "frontend start" || what == "game selected" || what == "frontend quit") exitGuard.GameRunning = false;
            }
            // the LOADING screen for slow starts (TeknoParrot ...): only when the game has no window of its own yet
            if (what == "game start")
            {
                ShowLoadingLater(c);
                // Recently Played (any system): the game's own collection, as the frontend's link last reported it
                if (gameLink != null && !string.Equals(Convert.ToString(State.ContainsKey("emulator") ? State["emulator"] : ""), "am_tools", StringComparison.OrdinalIgnoreCase))
                {
                    string rc = gameLink.SelectedCollection ?? gameLink.Menu, ri = c;
                    System.Threading.ThreadPool.QueueUserWorkItem(delegate { RecentlyPlayed.Record(retroFERoot, manifestDir, rc, ri, Log); });
                }
                healGame = c; healEmulator = Convert.ToString(State.ContainsKey("emulator") ? State["emulator"] : "");
                healCollection = gameLink != null ? (gameLink.SelectedCollection ?? gameLink.Menu) : null; healStarted = DateTime.Now;
            }
            else if (what == "game stop" || what == "frontend start" || what == "frontend quit")
            {
                CloseLoading();
                if (what == "game stop" && healGame != null) { RepairRoms(healGame, healCollection, healEmulator, (DateTime.Now - healStarted).TotalSeconds); healGame = null; }
            }
            State["lastEvent"] = what;
            State["lastArgs"] = string.Join(" ", a);
            State["lastEventAt"] = DateTime.Now.ToString("s");
        }
        Log((forwarded ? "pipe " : "args ") + string.Join(" ", a) + "  -> " + what);
        PassThrough(a);
        SaveState();
        if (tray != null) tray.Text = TrayText();
    }

    // shadow mode: LEDBlinky.exe still lights the panel; it gets exactly the same command
    static void PassThrough(string[] a)
    {
        if (ledBlinkyDir == null || !passThrough) return;
        string exe = Path.Combine(ledBlinkyDir, "LEDBlinky.exe");
        if (!File.Exists(exe)) return;
        try
        {
            var sb = new StringBuilder();
            foreach (var s in a) sb.Append(sb.Length > 0 ? " " : "").Append(s.IndexOf(' ') >= 0 ? "\"" + s + "\"" : s);
            Process.Start(new ProcessStartInfo(exe, sb.ToString()) { WorkingDirectory = ledBlinkyDir, UseShellExecute = false, CreateNoWindow = true });
        }
        catch (Exception e) { Log("pass-through to LEDBlinky failed: " + e.Message); }
    }

    // ---------------------------------------------------------------- pipe: forwarded arguments and JSON commands
    static bool Forward(string[] a)
    {
        try
        {
            using (var c = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut))
            {
                // RetroFE calls this on every scroll: no JSON library, no waiting for the answer - write one line, go
                c.Connect(1000);
                var sb = new StringBuilder("{\"cmd\":\"args\",\"noreply\":true,\"args\":[");
                for (int i = 0; i < a.Length; i++)
                {
                    if (i > 0) sb.Append(',');
                    sb.Append('"').Append(a[i].Replace("\\", "\\\\").Replace("\"", "\\\"")).Append('"');
                }
                sb.Append("]}\n");
                var bytes = new UTF8Encoding(false).GetBytes(sb.ToString());
                c.Write(bytes, 0, bytes.Length);
                c.Flush();
                return true;
            }
        }
        catch { return false; }
    }

    static void PipeServer()
    {
        while (!quitting)
        {
            try
            {
                var s = new NamedPipeServerStream(PipeName, PipeDirection.InOut, 4, PipeTransmissionMode.Byte);
                s.WaitForConnection();
                var r = new StreamReader(s, Encoding.UTF8);
                var w = new StreamWriter(s, new UTF8Encoding(false)) { AutoFlush = true };
                string line = r.ReadLine();
                if (line != null && line.IndexOf("\"cmd\":\"choose\"", StringComparison.Ordinal) >= 0)
                {
                    // the controller question waits for a person: answer on its own thread, keep serving the rest
                    string l = line;
                    new Thread(delegate () { try { w.WriteLine(Reply(l)); } catch { } finally { s.Dispose(); } }) { IsBackground = true, Name = "choose" }.Start();
                    continue;
                }
                using (s)
                {
                    if (line != null && line.IndexOf("\"noreply\":true", StringComparison.Ordinal) >= 0)
                    {
                        // a forwarded command: the sender has already gone; handle it off the pipe thread so the
                        // next scroll's connection is accepted at once
                        string l = line; ThreadPool.QueueUserWorkItem(delegate { Reply(l); });
                        continue;
                    }
                    w.WriteLine(Reply(line));
                }
            }
            catch (Exception e) { Log("pipe: " + e.Message); Thread.Sleep(200); }
        }
    }

    static string Reply(string line)
    {
        var rep = new Dictionary<string, object>();
        try
        {
            var req = Json.Deserialize<Dictionary<string, object>>(line ?? "{}");
            string cmd = req.ContainsKey("cmd") ? Convert.ToString(req["cmd"]) : "status";
            if (cmd == "args")
            {
                var list = new List<string>();
                var arr = req["args"] as System.Collections.ArrayList;
                if (arr != null) foreach (var o in arr) list.Add(Convert.ToString(o));
                Handle(list.ToArray(), true);
                rep["ok"] = true;
            }
            else if (cmd == "status") { lock (Gate) { if (marquee != null) State["marquee"] = marquee.Status(); rep["state"] = new Dictionary<string, object>(State); } if (glow != null) rep["glowPresses"] = glow.Presses; rep["ok"] = true; }
            else if (cmd == "marquee")
            {
                // {"cmd":"marquee","text":"INSERT COIN","color":"yellow"} | {"cmd":"marquee","game":"pacman","system":"mame"}
                // | {"cmd":"marquee","path":"/info"} (one raw Pixelcade request, answered here) - tests, Tools
                if (marquee == null) { rep["ok"] = false; rep["error"] = "the marquee is off (AmPanel.json \"Marquee\": \"pixelcade\")"; }
                else
                {
                    if (req.ContainsKey("path")) { rep["sent"] = marquee.Get(Convert.ToString(req["path"])); rep["answer"] = marquee.LastAnswer; }
                    else if (req.ContainsKey("text")) marquee.ShowText(Convert.ToString(req["text"]), req.ContainsKey("color") ? Convert.ToString(req["color"]) : null);
                    else if (req.ContainsKey("game")) marquee.Selected(Convert.ToString(req["game"]), req.ContainsKey("system") ? Convert.ToString(req["system"]) : null);
                    rep["marquee"] = marquee.Status(); rep["ok"] = true;
                }
            }
            else if (cmd == "choose")   // {"cmd":"choose","game":"centiped","collection":"Arcades","seconds":8} - blocks until answered
            {
                string game = req.ContainsKey("game") ? Convert.ToString(req["game"]) : null, coll = req.ContainsKey("collection") ? Convert.ToString(req["collection"]) : null;
                int secs = req.ContainsKey("seconds") ? Convert.ToInt32(req["seconds"]) : 8;
                if (choicesDb == null) choicesDb = new ControllerChoices(manifestDir);
                string id = choicesDb.Find(game, coll);
                var ch = choicesDb.Choices(id);
                rep["ok"] = true;
                if (ch.Count >= 2 && ui != null)
                {
                    string picked = null;
                    ui.Invoke((MethodInvoker)delegate {
                        string artColl = coll ?? (id.IndexOf(':') > 0 ? id.Substring(0, id.IndexOf(':')) : null);
                        var theme = ChooserTheme.Load(retroFERoot, artColl, game);
                        // the panel shows what the question takes: button 1 = PLAY (New-LedColorsAuto.py "__chooser")
                        if (leds != null) lock (Gate) leds.LightGame("__chooser");
                        using (var f = new ControllerChooser(choicesDb.Title(id), ch, choicesDb.LastPick(id), secs, theme))
                        {
                            // a copy on the marquee / touch screen: touch a tile there to pick
                            ControllerChooser m = null;
                            foreach (var scr in Screen.AllScreens)
                                if (!scr.Primary && m == null)
                                {
                                    m = new ControllerChooser(choicesDb.Title(id), ch, choicesDb.LastPick(id), secs, theme) { Passive = true };
                                    m.Bounds = scr.Bounds; m.Peer = f; f.Peer = m; m.Show();
                                }
                            f.ShowDialog(); picked = f.Picked ?? (m != null ? m.Picked : null);
                            if (m != null && !m.IsDisposed) { m.Close(); m.Dispose(); }
                        }
                    });
                    if (picked != null)
                    {
                        choicesDb.SavePick(id, picked);
                        rep["choice"] = picked;
                        foreach (var c in ch) if (Convert.ToString(c["id"]) == picked && c.ContainsKey("stickMap"))
                            {
                                string map = Convert.ToString(c["stickMap"]); rep["stickMap"] = map;
                                if (sticks != null) { sticks.PickRom = game; sticks.PickMap = map; }
                            }
                        lock (Gate) { State["controller"] = picked; State["controllerFor"] = game; }
                        Log("choose: " + game + " -> " + picked);
                    }
                }
            }
            else if (cmd == "simulate")   // {"cmd":"simulate","output":"lamp0","value":1,"game":"sf2"} - a game output, as if MAME sent it
            {
                string name = req.ContainsKey("output") ? Convert.ToString(req["output"]) : "", g = req.ContainsKey("game") ? Convert.ToString(req["game"]) : null;
                int value = req.ContainsKey("value") ? Convert.ToInt32(req["value"]) : 1;
                lock (Gate)
                {
                    if (g == null) g = State.ContainsKey("game") && State["game"] != null ? Convert.ToString(State["game"]) : Convert.ToString(State.ContainsKey("selected") ? State["selected"] : null);
                    string sys = State.ContainsKey("emulator") ? Convert.ToString(State["emulator"]) : null;
                    rep["result"] = rules == null ? null : rules.Apply(name, value, g, sys, leds, Log);
                }
                rep["ok"] = true;
            }
            else if (cmd == "endgame")   // {"cmd":"endgame"} - end the game in front now, as the exit key does (tests, Stream Deck)
            {
                rep["result"] = exitGuard == null ? "exit guard off" : exitGuard.EndNow(); rep["ok"] = exitGuard != null;
            }
            else if (cmd == "buttons")   // {"cmd":"buttons"} - open the Buttons window on the cabinet (Tools)
            {
                if (leds == null || ui == null) { rep["ok"] = false; rep["error"] = "lights are not AmPanel's (AmPanel.json Lights = own)"; }
                else { ui.BeginInvoke((MethodInvoker)OpenButtons); rep["ok"] = true; }
            }
            else if (cmd == "attract")   // {"cmd":"attract","kind":"audio"} - the idle animation from now on (Cabinet Settings)
            {
                string k = req.ContainsKey("kind") ? Convert.ToString(req["kind"]).ToLowerInvariant() : "";
                if (req.ContainsKey("speech")) { speech = Convert.ToString(req["speech"]).ToLowerInvariant(); rep["speech"] = speech; }
                if (k == "" && req.ContainsKey("speech")) rep["ok"] = true;
                else if (k == "chase" || k == "breathe" || k == "audio" || k.EndsWith(".lwax")) { attractAnimation = k; rep["ok"] = true; rep["attract"] = k; }
                else { rep["ok"] = false; rep["error"] = "attract: chase, breathe or audio"; }
            }
            else if (cmd == "devicechange") { if (devices != null) devices.Poke(); rep["ok"] = devices != null; }   // as if a controller was plugged in
            else if (cmd == "sticks")   // {"cmd":"sticks"} status + maps; {"cmd":"sticks","map":"Joy4Way"} or {"rom":"pacman"} loads now
            {
                if (sticks == null) { rep["ok"] = false; rep["error"] = sticksOwn ? "no UltraStik found" : "sticks are not AmPanel's (AmPanel.json Sticks = own)"; }
                else
                {
                    string map = req.ContainsKey("map") ? Convert.ToString(req["map"]) : null, rom = req.ContainsKey("rom") ? Convert.ToString(req["rom"]) : null;
                    if (map != null || rom != null) { string r = sticks.Load(map, rom, true); lock (Gate) State["stick"] = r; rep["result"] = r; }
                    if (req.ContainsKey("reload")) sticks.Reload();
                    rep["count"] = sticks.Count; rep["current"] = sticks.Current; rep["maps"] = sticks.Maps();
                    if (rom != null) rep["mapFor"] = sticks.MapFor(rom);
                    rep["ok"] = true;
                }
            }
            else if (cmd == "guns") { var g = Guns.Find(); lock (Gate) State["guns"] = g; rep["guns"] = g; rep["ok"] = true; }
            else if (cmd == "boards") { var b = ReadBoards(); lock (Gate) State["boards"] = b; rep["boards"] = b; rep["ok"] = true; }
            else if (cmd == "light")   // {"cmd":"light","rom":"sf2"} - light a game's controls now (tests, Tools)
            {
                if (leds == null) { rep["ok"] = false; rep["error"] = "lights are not AmPanel's (AmPanel.json Lights = own)"; }
                else { string res; lock (Gate) { res = leds.LightGame(req.ContainsKey("rom") ? Convert.ToString(req["rom"]) : null); State["lights"] = res; } rep["result"] = res; rep["ok"] = true; }
            }
            else if (cmd == "off") { if (leds != null) lock (Gate) leds.AllOff(); rep["ok"] = leds != null; }
            else if (cmd == "colors" || cmd == "setcolor")
            {
                // {"cmd":"colors","rom":"sf2"} -> every button's colour for that game (0-48 R,G,B, after this cabinet's changes)
                // {"cmd":"setcolor","rom":"sf2","label":"P1B1","rgb":[0,48,0]} (rgb omitted = back to the game's own colour)
                if (leds == null) { rep["ok"] = false; rep["error"] = "lights are not AmPanel's (AmPanel.json Lights = own)"; }
                else
                {
                    string rom = req.ContainsKey("rom") ? Convert.ToString(req["rom"]) : null;
                    lock (Gate)
                    {
                        if (cmd == "setcolor")
                        {
                            var a = req.ContainsKey("rgb") ? req["rgb"] as System.Collections.ArrayList : null;
                            int[] rgb = a != null && a.Count == 3 ? new[] { Convert.ToInt32(a[0]), Convert.ToInt32(a[1]), Convert.ToInt32(a[2]) } : null;
                            leds.SetGameColor(rom, Convert.ToString(req["label"]), rgb);
                            leds.LightGame(rom);
                        }
                        var map = new Dictionary<string, object>();
                        foreach (var kv in leds.GameColors(rom)) map[kv.Key] = kv.Value;
                        rep["colors"] = map;
                    }
                    rep["ok"] = true;
                }
            }
            else if (cmd == "saverule" || cmd == "describe")
            {
                // {"cmd":"saverule","output":"led0","game":"asteroid","do":"led","target":"P1START","color":"Red"} (do "default" removes it)
                // {"cmd":"describe","output":"led0","game":"asteroid"} -> what that output does now
                string o = Convert.ToString(req["output"]), g = req.ContainsKey("game") ? Convert.ToString(req["game"]) : "*";
                if (cmd == "saverule")
                {
                    TriggerRules.SaveCabinetRule(Path.Combine(manifestDir, "panel-rules.json"), o, g, req.ContainsKey("do") ? Convert.ToString(req["do"]) : "led",
                        req.ContainsKey("target") ? Convert.ToString(req["target"]) : null, req.ContainsKey("color") ? Convert.ToString(req["color"]) : null);
                    ReloadRules();
                }
                rep["does"] = rules != null ? rules.Describe(o, g) : "-"; rep["ok"] = true;
            }
            else if (cmd == "animate")   // {"cmd":"animate","kind":"chase"|"breathe"|"audio"|"stop"}; "level" only reports
            {
                if (leds == null) { rep["ok"] = false; rep["error"] = "lights are not AmPanel's (AmPanel.json Lights = own)"; }
                else if (req.ContainsKey("kind") && Convert.ToString(req["kind"]) == "level") { rep["animation"] = leds.Animation; rep["level"] = leds.AudioLevelNow; rep["error"] = leds.LastError; rep["ok"] = true; }
                else { string res; lock (Gate) { res = leds.Animate(req.ContainsKey("kind") ? Convert.ToString(req["kind"]) : "chase"); State["lights"] = res; } rep["result"] = res; rep["ok"] = true; }
            }
            else if (cmd == "keylog")   // {"cmd":"keylog"} -> the last 200 key events the cabinet's controls sent (ReactiveKeys)
            {
                rep["keys"] = glow != null ? glow.KeyLog() : new string[0];
                rep["link"] = gameLink != null ? (object)new Dictionary<string, object> { { "alive", gameLink.Alive }, { "menu", gameLink.Menu }, { "selected", gameLink.Selected } } : null;
                rep["ok"] = glow != null;
            }
            else if (cmd == "outputs")   // live emulator outputs: {"connected":true,"outputs":{"led0":1,...}}
            {
                rep["connected"] = outputs != null && outputs.Connected;
                rep["outputs"] = outputs != null ? outputs.Snapshot() : new Dictionary<string, object>();
                rep["ok"] = true;
            }
            else { rep["ok"] = false; rep["error"] = "unknown command '" + cmd + "' (args, status, boards, light, off)"; }
        }
        catch (Exception e) { rep["ok"] = false; rep["error"] = e.Message; }
        return Json.Serialize(rep);
    }

    // ---------------------------------------------------------------- tray
    static void RunTray()
    {
        Application.EnableVisualStyles();
        try
        {
            outputs = new OutputListener(manifestDir, delegate {
                lock (Gate) { object g; if (State.TryGetValue("game", out g) && g != null) return Convert.ToString(g); if (State.TryGetValue("selected", out g) && g != null) return Convert.ToString(g); return null; }
            }, Log);
            ReloadRules();
            outputs.Changed += delegate (string name, int value) {
                if (leds == null && rules.Count == 0) return;
                lock (Gate)
                {
                    string game = State.ContainsKey("game") && State["game"] != null ? Convert.ToString(State["game"]) : Convert.ToString(State.ContainsKey("selected") ? State["selected"] : null);
                    string sys = State.ContainsKey("emulator") ? Convert.ToString(State["emulator"]) : null;
                    string done = rules.Apply(name, value, game, sys, leds, Log);
                    if (done != null) { State["lastTrigger"] = name + "=" + value + " -> " + done; State["triggerHits"] = rules.Hits; }
                }
            };
        }
        catch (Exception e) { Log("outputs: listener not started - " + e.Message); }
        if (leds != null && reactive)
        {
            try
            {
                // installed on this (the message-loop) thread, as a low-level hook must be
                glow = new ReactiveKeys(leds.KeyLabels(), delegate (string label, bool held) { lock (Gate) leds.Glow(label, held); });
                lock (Gate) State["reactive"] = glow.Active ? glow.MappedKeys + " keys glow their button while held" : "keyboard hook not installed";
                Log("reactive: " + State["reactive"]);
            }
            catch (Exception e) { Log("reactive: not started - " + e.Message); }
        }
        ui = new Control(); ui.CreateControl(); var unused = ui.Handle;   // the tray thread's window: Invoke target
        StartSearch();
        if (!exitKey.Equals("none", StringComparison.OrdinalIgnoreCase))
        {
            int vk = ReactiveKeys.VkOf(exitKey);
            if (vk == 0) Log("exit guard: unknown ExitKey '" + exitKey + "'");
            else try {
                    exitGuard = new ExitGuard(vk, exitGraceMs, "retrofe",
                        new[] { Path.Combine(manifestDir, "exit-rules.json"), Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "exit-rules.json") }, Log);
                } catch (Exception e) { Log("exit guard: not started - " + e.Message); }
        }
        if (!padKeysOff) try { padKeys = new PadKeys(manifestDir, new[] { "retrofe" }, Log); } catch (Exception e) { Log("pad keys: not started - " + e.Message); }
        tray = new NotifyIcon { Icon = SystemIcons.Application, Visible = true, Text = TrayText() };
        if (toolsDir != null && retroFERoot != null)
        {
            try
            {
                devices = new DeviceWatcher(toolsDir, retroFERoot, manifestDir, delegate (string line) {
                    lock (Gate) { State["devicesChanged"] = line; State["devicesChangedAt"] = DateTime.Now.ToString("s"); }
                    SaveState();
                    if (!line.StartsWith("CHANGED: nothing"))
                        try { tray.ShowBalloonTip(6000, "Controllers changed", line.Substring(9), ToolTipIcon.Info); } catch { }
                }, Log);
            }
            catch (Exception e) { Log("devices: listener not started - " + e.Message); }
        }
        try { var ico = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "AmPanel.ico"); if (File.Exists(ico)) tray.Icon = new Icon(ico); } catch { }
        var menu = new ContextMenuStrip();
        menu.Items.Add("Status", null, delegate { MessageBox.Show(StatusText(), "ArcadeMaster Panel"); });
        if (leds != null)
            menu.Items.Add("Buttons (which light is which)...", null, delegate { OpenButtons(); });
        if (leds != null)
            menu.Items.Add("Lights && Colours...", null, delegate {
                string g; lock (Gate) g = State.ContainsKey("selected") && State["selected"] != null ? Convert.ToString(State["selected"]) : "";
                new ColorStudio(leds, Gate, g).Show();
            });
        menu.Items.Add("Sticks && Guns...", null, delegate {
            string g; lock (Gate) g = State.ContainsKey("selected") && State["selected"] != null ? Convert.ToString(State["selected"]) : "";
            try { new StickStudio(sticks, manifestDir, ledBlinkyDir, Gate, g, Log).Show(); } catch (Exception e) { Log("sticks window: " + e.Message); }
        });
        menu.Items.Add("Triggers (game outputs)...", null, delegate {
            string g; lock (Gate) g = State.ContainsKey("game") && State["game"] != null ? Convert.ToString(State["game"]) : (State.ContainsKey("selected") && State["selected"] != null ? Convert.ToString(State["selected"]) : "");
            new TriggerStudio(outputs, delegate { return rules; }, ReloadRules, manifestDir, g,
                leds != null ? leds.Labels : new List<string>(), leds != null ? leds.ColorNames : new List<string> { "White", "Red", "Green", "Blue", "Yellow" }).Show();
        });
        menu.Items.Add("Re-scan boards", null, delegate { var b = ReadBoards(); lock (Gate) State["boards"] = b; SaveState(); });
        menu.Items.Add("Open log", null, delegate { try { Process.Start(logFile); } catch { } });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Quit", null, delegate { tray.Visible = false; Application.Exit(); });
        tray.ContextMenuStrip = menu;
        tray.DoubleClick += delegate { MessageBox.Show(StatusText(), "ArcadeMaster Panel"); };
        Application.Run();
        if (glow != null) glow.Stop();
        if (devices != null) devices.Stop();
        if (outputs != null) outputs.Shutdown();
        tray.Visible = false;
    }

    // the cabinet's rules first, then the shipped defaults next to the exe
    static void ReloadRules()
    {
        rules = new TriggerRules(Path.Combine(manifestDir, "panel-rules.json"), Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "panel-rules.json"));
        Log("rules: " + rules.Count + " trigger rule(s) loaded");
    }

    static string TrayText()
    {
        lock (Gate)
        {
            string g = State.ContainsKey("selected") && State["selected"] != null ? Convert.ToString(State["selected"]) : "-";
            string t = "ArcadeMaster Panel - " + g;
            return t.Length > 63 ? t.Substring(0, 63) : t;   // NotifyIcon.Text limit
        }
    }

    static string StatusText()
    {
        var sb = new StringBuilder();
        lock (Gate)
        {
            foreach (var kv in State)
            {
                if (kv.Key == "boards" || kv.Key == "guns") continue;
                sb.AppendLine(kv.Key + ": " + (kv.Value == null ? "-" : Convert.ToString(kv.Value)));
            }
            var boards = State.ContainsKey("boards") ? State["boards"] as List<object> : null;
            sb.AppendLine("boards: " + (boards == null ? 0 : boards.Count));
            if (boards != null) foreach (Dictionary<string, object> b in boards) sb.AppendLine("  #" + b["index"] + " " + b["kind"] + " " + b["usb"] + (Convert.ToInt32(b["leds"]) > 0 ? " (" + b["leds"] + " LEDs)" : ""));
            var guns = State.ContainsKey("guns") ? State["guns"] as List<object> : null;
            sb.AppendLine("light guns: " + (guns == null ? 0 : guns.Count));
            if (guns != null) foreach (Dictionary<string, object> g in guns) sb.AppendLine("  " + g["kind"] + " " + g["usb"] + " - " + g["name"]);
        }
        return sb.ToString();
    }

    // ---------------------------------------------------------------- helpers
    static void SaveState()
    {
        try
        {
            string json; lock (Gate) json = Json.Serialize(State);
            string p = Path.Combine(manifestDir, "panel-state.json"), tmp = p + ".tmp";
            File.WriteAllText(tmp, json, new UTF8Encoding(false));
            if (File.Exists(p)) File.Replace(tmp, p, null); else File.Move(tmp, p);
        }
        catch (Exception e) { Log("state: " + e.Message); }
    }

    static Dictionary<string, object> ReadJson(string p)
    {
        try { return File.Exists(p) ? Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(p)) : null; } catch { return null; }
    }
    static string Str(Dictionary<string, object> d, string k) { return d != null && d.ContainsKey(k) && d[k] != null ? Convert.ToString(d[k]) : null; }

    static void Log(string m)
    {
        try { if (logFile != null) File.AppendAllText(logFile, "[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] " + m + Environment.NewLine); } catch { }
    }
}
