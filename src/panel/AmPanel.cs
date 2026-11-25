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
    static NotifyIcon tray;
    static volatile bool quitting;

    [STAThread]
    static int Main(string[] args)
    {
        bool created;
        using (var mutex = new Mutex(true, MutexName, out created))
        {
            if (!created) return Forward(args) ? 0 : 1;   // the running AmPanel handles it
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
                }
                State["ledBlinkyRunning"] = Process.GetProcessesByName("LEDBlinky").Length > 0;
            }
            Handle(args, false);
            new Thread(PipeServer) { IsBackground = true, Name = "pipe" }.Start();
            RunTray();
            quitting = true;
            if (leds != null) leds.Close();
            Log("AmPanel stopped");
            return 0;
        }
    }

    // ---------------------------------------------------------------- config: <exe dir>\AmPanel.json, else the cabinet's
    static void LoadConfig()
    {
        string exeDir = AppDomain.CurrentDomain.BaseDirectory;
        var cfg = ReadJson(Path.Combine(exeDir, "AmPanel.json"));
        manifestDir = Str(cfg, "ManifestDir");
        ledBlinkyDir = Str(cfg, "LEDBlinkyDir");
        if (Str(cfg, "PassThrough") != null) passThrough = Convert.ToBoolean(cfg["PassThrough"]);
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
        if (manifestDir == null) manifestDir = Path.Combine(exeDir, "manifest");
        Directory.CreateDirectory(manifestDir);
        logFile = Path.Combine(manifestDir, "ampanel.log");
        if (ledBlinkyDir != null && Directory.Exists(ledBlinkyDir)) SetDllDirectory(ledBlinkyDir);   // PacDrive32.dll lives there
        if (string.Equals(Str(cfg, "Lights"), "own", StringComparison.OrdinalIgnoreCase) && ledBlinkyDir != null) {
            leds = new LedEngine(ledBlinkyDir);
            passThrough = false;       // two programs must never drive the same boards
        }
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

    // ---------------------------------------------------------------- LEDBlinky's documented command line
    static void Handle(string[] a, bool forwarded)
    {
        string what;
        lock (Gate)
        {
            string c = a.Length > 0 ? a[0] : "1";
            string arg1 = a.Length > 1 ? a[1] : null, arg2 = a.Length > 2 ? a[2] : null;
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
                case "12": what = "load MAME controller file " + arg1; break;
                case "13": State["ultrastikMap"] = arg1 ?? "joy8way"; what = "UltraStik map"; break;
                case "14": what = "set LED ports"; break;
                case "15": if (arg1 != null) State["selected"] = arg1; what = "light game controls"; break;
                case "16": State["paused"] = true; what = "game pause"; break;
                case "17": State["paused"] = false; what = "game unpause"; break;
                default:
                    if (c.EndsWith(".lwax", StringComparison.OrdinalIgnoreCase)) { State["animation"] = c; what = "animation start"; }
                    else { State["playing"] = true; State["game"] = c; if (arg1 != null) State["emulator"] = arg1; State["paused"] = false; what = "game start"; }
                    break;
            }
            if (leds != null)
            {
                // the documented events that change what the panel shows
                if (c == "9" || c == "15") State["lights"] = leds.LightGame(Convert.ToString(State.ContainsKey("selected") ? State["selected"] : null));
                else if (c == "2") { leds.AllOff(); State["lights"] = "off (frontend quit)"; }
                else if (what == "game start") State["lights"] = leds.LightGame(c);
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
                using (var s = new NamedPipeServerStream(PipeName, PipeDirection.InOut, 4, PipeTransmissionMode.Byte))
                {
                    s.WaitForConnection();
                    var r = new StreamReader(s, Encoding.UTF8);
                    var w = new StreamWriter(s, new UTF8Encoding(false)) { AutoFlush = true };
                    string line = r.ReadLine();
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
            else if (cmd == "status") { lock (Gate) rep["state"] = new Dictionary<string, object>(State); rep["ok"] = true; }
            else if (cmd == "boards") { var b = ReadBoards(); lock (Gate) State["boards"] = b; rep["boards"] = b; rep["ok"] = true; }
            else if (cmd == "light")   // {"cmd":"light","rom":"sf2"} - light a game's controls now (tests, Tools)
            {
                if (leds == null) { rep["ok"] = false; rep["error"] = "lights are not AmPanel's (AmPanel.json Lights = own)"; }
                else { string res; lock (Gate) { res = leds.LightGame(req.ContainsKey("rom") ? Convert.ToString(req["rom"]) : null); State["lights"] = res; } rep["result"] = res; rep["ok"] = true; }
            }
            else if (cmd == "off") { if (leds != null) lock (Gate) leds.AllOff(); rep["ok"] = leds != null; }
            else { rep["ok"] = false; rep["error"] = "unknown command '" + cmd + "' (args, status, boards, light, off)"; }
        }
        catch (Exception e) { rep["ok"] = false; rep["error"] = e.Message; }
        return Json.Serialize(rep);
    }

    // ---------------------------------------------------------------- tray
    static void RunTray()
    {
        Application.EnableVisualStyles();
        tray = new NotifyIcon { Icon = SystemIcons.Application, Visible = true, Text = TrayText() };
        try { var ico = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "AmPanel.ico"); if (File.Exists(ico)) tray.Icon = new Icon(ico); } catch { }
        var menu = new ContextMenuStrip();
        menu.Items.Add("Status", null, delegate { MessageBox.Show(StatusText(), "ArcadeMaster Panel"); });
        menu.Items.Add("Re-scan boards", null, delegate { var b = ReadBoards(); lock (Gate) State["boards"] = b; SaveState(); });
        menu.Items.Add("Open log", null, delegate { try { Process.Start(logFile); } catch { } });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Quit", null, delegate { tray.Visible = false; Application.Exit(); });
        tray.ContextMenuStrip = menu;
        tray.DoubleClick += delegate { MessageBox.Show(StatusText(), "ArcadeMaster Panel"); };
        Application.Run();
        tray.Visible = false;
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
                if (kv.Key == "boards") continue;
                sb.AppendLine(kv.Key + ": " + (kv.Value == null ? "-" : Convert.ToString(kv.Value)));
            }
            var boards = State.ContainsKey("boards") ? State["boards"] as List<object> : null;
            sb.AppendLine("boards: " + (boards == null ? 0 : boards.Count));
            if (boards != null) foreach (Dictionary<string, object> b in boards) sb.AppendLine("  #" + b["index"] + " " + b["kind"] + " " + b["usb"] + (Convert.ToInt32(b["leds"]) > 0 ? " (" + b["leds"] + " LEDs)" : ""));
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
