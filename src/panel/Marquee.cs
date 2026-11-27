// AmPanel - the Pixelcade LED marquee, so LEDBlinky is no longer needed for it (docs/20, the 2-player stand-up).
//
// AmPanel.json "Marquee": "pixelcade" turns it on (default: off - LEDBlinky keeps the marquee, as before).
// It talks to the Pixelcade listener (pixelweb) over its local HTTP API, sending the same requests LEDBlinky sent
// on this cabinet (pixelweb.log, 2026-11-26) and the paths in Pixelcade's developer docs (pixelcade.org/developers):
//   frontend start   /text?t=<FEStartText>&l=1&event=FEStart
//   list change      /console/stream/<system>?t=<SYSTEM>&l=0&event=FEListChange
//   game selected    /arcade/stream/<system>/<game>?l=0&event=FEScroll
//   game start       blank, then "Now playing <title>" once, then the game's marquee held (l=99999) for the whole game
//   game stop        the selected game's marquee again (l=0 clears the held one)
//   screensaver      a random animation (/animations/stream/random?r), held until the screensaver ends
//   frontend quit    /text?t=<FEQuitText>, then /localplayback (the marquee's own idle image)
// The texts, colour and speed come from LEDBlinky's own [Pixelcade] settings (Settings.ini) when LEDBlinky is
// installed, so the marquee looks the same as before; AmPanel.json "MarqueeStartText", "MarqueeQuitText",
// "MarqueeNowPlaying" (~game~ = the title), "MarqueeColor" (a name, 6-digit hex or "random"), "MarqueeSpeed",
// "MarqueeScreensaver" ("random" | "attract" | "none") and "PixelcadeUrl" win over them.
// The listener itself is looked after too: if nothing answers, AmPanel starts <PixelcadeDir>\pixelweb.exe once
// a minute at most, so the "Pixelcade Listener" startup shortcut is no longer needed.
// Requests go out on their own thread: a slow or missing listener never holds up the frontend. When events come
// faster than the marquee can follow (scrolling the wheel), only the newest one is sent.
// C# 5.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;

class Marquee
{
    public string BaseUrl = "http://127.0.0.1:8080";
    public string PixelcadeDir;
    public string StartText = "Welcome and Game On!", QuitText = "Thanks for Playing", NowPlaying = "Now Playing ~game~";
    public string Color = "random", Speed = "1", Screensaver = "random";
    public bool LocalPlaybackOnQuit = true;
    public string LastSent, LastError, LastAnswer;
    public int Sent, Failed;

    static readonly string[] Named = { "red", "blue", "cyan", "green", "magenta", "orange", "yellow", "pink", "white", "lightgray" };
    readonly Random rnd = new Random();
    readonly Action<string> log;
    readonly object qGate = new object();
    List<string> pending;            // the newest event's requests, waiting for the worker
    readonly AutoResetEvent wake = new AutoResetEvent(false);
    DateTime lastListenerStart = DateTime.MinValue;
    bool inAttract;

    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] static extern IntPtr FindWindow(string cls, string title);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    // pixelweb opens a console window titled "Pixelcade Listener" (its log). On a cabinet it sat on the game screen
    // (2P stand-up, 2026-11-27): hidden whenever it shows up. The log still goes to <Pixelcade>\pixelweb.log.
    static void HideListenerWindow() { try { IntPtr w = FindWindow(null, "Pixelcade Listener"); if (w != IntPtr.Zero) ShowWindow(w, 0); } catch { } }

    public Marquee(Action<string> log)
    {
        this.log = log ?? delegate { };
        new Thread(Worker) { IsBackground = true, Name = "marquee" }.Start();
        // the listener may start after AmPanel (Startup shortcut) or be restarted: look for its window for a while
        new Thread(() => { for (int i = 0; i < 120; i++) { HideListenerWindow(); Thread.Sleep(1000); } }) { IsBackground = true, Name = "marquee-hide" }.Start();
    }

    // LEDBlinky's [Pixelcade] section: the texts and colour this cabinet already uses
    public void LoadLEDBlinkySettings(string ledBlinkyDir)
    {
        if (ledBlinkyDir == null) return;
        string ini = Path.Combine(ledBlinkyDir, "Settings.ini");
        if (!File.Exists(ini)) return;
        try
        {
            bool inSection = false;
            var v = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var raw in File.ReadAllLines(ini, Encoding.Default))
            {
                string line = raw.Trim();
                if (line.StartsWith("[")) { inSection = line.Equals("[Pixelcade]", StringComparison.OrdinalIgnoreCase); continue; }
                int eq = line.IndexOf('=');
                if (inSection && eq > 0) v[line.Substring(0, eq).Trim()] = line.Substring(eq + 1).Trim();
            }
            string s;
            if (v.TryGetValue("PixelcadeFolder", out s) && s.Length > 0) PixelcadeDir = s;
            if (v.TryGetValue("PixelcadePort", out s) && s.Length > 0) BaseUrl = "http://127.0.0.1:" + s;
            if (v.TryGetValue("PixelcadeFEStartText", out s)) StartText = s;
            if (v.TryGetValue("PixelcadeFEQuitText", out s)) QuitText = s;
            if (v.TryGetValue("PixelcadeGameActiveText", out s) && s.Length > 0) NowPlaying = s;
            if (v.TryGetValue("PixelcadeScrollTextColor", out s) && s.Length > 0) Color = s.Trim('<', '>');
            if (v.TryGetValue("PixelcadeScrollTextSpeed", out s) && s.Length > 0) Speed = s;
            if (v.TryGetValue("PixelcadeLocalPlaybackOnQuit", out s)) LocalPlaybackOnQuit = s == "1";
        }
        catch (Exception e) { log("marquee: LEDBlinky settings not read - " + e.Message); }
    }

    // ---------------------------------------------------------------- the frontend's events
    public void FrontendStart() { inAttract = false; Send(Text(StartText, 1, "FEStart")); }
    public void FrontendQuit()
    {
        inAttract = false;
        var r = new List<string>();
        string t = Text(QuitText, 1, "FEQuit"); if (t != null) r.Add(t);
        if (LocalPlaybackOnQuit) r.Add("/localplayback");
        Send(r.ToArray());
    }
    public void ListChange(string system)
    {
        if (string.IsNullOrEmpty(system)) return;
        Send("/console/stream/" + Esc(system) + "?t=" + Esc(system.ToUpperInvariant()) + "&c=white&ss=" + Esc(Speed) + "&l=0&event=FEListChange");
    }
    public void Selected(string game, string system)
    {
        if (string.IsNullOrEmpty(game)) return;
        Send(StopAttract(), Stream(game, system, 0, null, "FEScroll"));
    }
    public void GameStart(string game, string system, string title)
    {
        if (string.IsNullOrEmpty(game)) return;
        string np = (NowPlaying ?? "").Replace("~game~", title ?? game).Replace("~system~", system ?? "");
        np = System.Text.RegularExpressions.Regex.Replace(np, "~[a-z0-9]+~", "").Trim();   // ~hiscoretop3~ etc.: not yet
        Send(StopAttract(), "/arcade/stream/black/dummy?l=0&event=GameStart", Text(np, 1, "GameStart", "green", game, system),
             Stream(game, system, 99999, game, "GameStart"));
    }
    public void GameStop(string selected, string system) { if (!string.IsNullOrEmpty(selected)) Send(Stream(selected, system, 0, null, "FEScroll")); }
    public void ScreensaverStart()
    {
        // "random" (default): a random animation from <Pixelcade>\animations, held until the screensaver ends -
        // what LEDBlinky did here (PixelcadeFEScreenSaverAniUserFile=<Random>). "attract": Pixelcade's own attract
        // mode, which needs a newer listener (4.4.7 on the 2P stand-up does not have /attract). "none": leave it.
        if (Screensaver == "attract") { inAttract = true; Send("/attract"); }
        else if (Screensaver != "none") Send("/animations/stream/random?r&l=99999&event=FEScreenSaver");
    }
    public void ScreensaverStop(string selected, string system)
    {
        string stop = StopAttract();
        if (!string.IsNullOrEmpty(selected)) Send(stop, Stream(selected, system, 0, null, "FEScroll")); else Send(stop);
    }
    public void ShowText(string text, string color) { Send(StopAttract(), Text(text, 1, null, color, null, null)); }

    // ---------------------------------------------------------------- requests
    string StopAttract() { if (!inAttract) return null; inAttract = false; return "/attract/stop"; }

    string Stream(string game, string system, int loops, string altText, string ev)
    {
        // the system the frontend sends is passed on unchanged (LEDBlinky does the same); pixelweb maps it to a folder
        string sys = string.IsNullOrEmpty(system) ? "mame" : system;
        var sb = new StringBuilder("/arcade/stream/").Append(Esc(sys)).Append('/').Append(Esc(game)).Append('?');
        if (altText != null) sb.Append("ss=").Append(Esc(Speed)).Append("&c=").Append(Esc(PickColor(null))).Append("&t=").Append(Esc(altText)).Append('&');
        sb.Append("l=").Append(loops).Append("&event=").Append(ev);
        return sb.ToString();
    }

    string Text(string text, int loops, string ev) { return Text(text, loops, ev, null, null, null); }
    string Text(string text, int loops, string ev, string color, string game, string system)
    {
        if (string.IsNullOrEmpty(text)) return null;
        var sb = new StringBuilder("/text?t=").Append(Esc(text)).Append("&ss=").Append(Esc(Speed)).Append("&c=").Append(Esc(PickColor(color))).Append("&l=").Append(loops);
        if (ev != null) sb.Append("&game=").Append(Esc(game ?? "")).Append("&system=").Append(Esc(system ?? "")).Append("&event=").Append(ev);
        return sb.ToString();
    }

    string PickColor(string wanted)
    {
        string c = wanted ?? Color;
        if (string.IsNullOrEmpty(c) || c.Equals("random", StringComparison.OrdinalIgnoreCase)) lock (rnd) return Named[rnd.Next(Named.Length)];
        return c.TrimStart('#');
    }

    static string Esc(string s) { return Uri.EscapeDataString(s ?? ""); }

    void Send(params string[] paths)
    {
        var list = new List<string>();
        foreach (var p in paths) if (p != null) list.Add(p);
        if (list.Count == 0) return;
        lock (qGate) pending = list;     // newer events replace older ones that have not gone out yet
        wake.Set();
    }

    void Worker()
    {
        while (true)
        {
            wake.WaitOne();
            List<string> batch;
            lock (qGate) { batch = pending; pending = null; }
            if (batch == null) continue;
            foreach (var p in batch)
            {
                if (!Get(p) && EnsureListener()) Get(p);   // listener was down: started it, one retry
                lock (qGate) if (pending != null) break;    // a newer event arrived: it wins
            }
        }
    }

    public bool Get(string path)
    {
        try
        {
            var req = (HttpWebRequest)WebRequest.Create(BaseUrl.TrimEnd('/') + path);
            req.Timeout = 3000; req.ReadWriteTimeout = 3000; req.Proxy = null; req.KeepAlive = false;
            string body;
            using (var resp = (HttpWebResponse)req.GetResponse())
            using (var rd = new StreamReader(resp.GetResponseStream())) body = rd.ReadToEnd();
            LastSent = path; Sent++;
            HideListenerWindow();
            // a path pixelweb does not know is answered with its web page, not an error
            if (body.TrimStart().StartsWith("<!DOCTYPE", StringComparison.OrdinalIgnoreCase)) log("marquee: this Pixelcade listener does not know " + path);
            LastAnswer = body.Length > 300 ? body.Substring(0, 300) : body;
            return true;
        }
        catch (WebException e)
        {
            // pixelweb answers some paths with a non-200 status but still acts on them; only "nobody there" is a failure
            if (e.Response != null) { e.Response.Close(); LastSent = path; Sent++; return true; }
            LastError = path + ": " + e.Message; Failed++;
            log("marquee: " + LastError);
            return false;
        }
        catch (Exception e) { LastError = path + ": " + e.Message; Failed++; log("marquee: " + LastError); return false; }
    }

    // start the Pixelcade listener when it is not answering (at most once a minute)
    bool EnsureListener()
    {
        if (PixelcadeDir == null || (DateTime.Now - lastListenerStart).TotalSeconds < 60) return false;
        string exe = Path.Combine(PixelcadeDir, "pixelweb.exe");
        // pixelweb.exe is a launcher: the listener itself is <Pixelcade>\jre\bin\java.exe. Anything still running from the
        // Pixelcade folder means it is starting or busy, not gone - never start a second one.
        if (!File.Exists(exe) || RunningFrom(PixelcadeDir)) return false;
        lastListenerStart = DateTime.Now;
        try
        {
            Process.Start(new ProcessStartInfo(exe) { WorkingDirectory = PixelcadeDir, UseShellExecute = false, CreateNoWindow = true });
            log("marquee: Pixelcade listener was not running - started " + exe);
            // it takes a few seconds to find the panel: wait for /v2/info to answer with the device, not the web page
            for (int i = 0; i < 30; i++) { Thread.Sleep(500); HideListenerWindow(); if (Probe()) { Thread.Sleep(1000); HideListenerWindow(); return true; } }
        }
        catch (Exception e) { log("marquee: could not start the Pixelcade listener - " + e.Message); }
        return false;
    }

    bool Probe()
    {
        try
        {
            var req = (HttpWebRequest)WebRequest.Create(BaseUrl.TrimEnd('/') + "/v2/info");
            req.Timeout = 1500; req.Proxy = null; req.KeepAlive = false;
            using (var resp = (HttpWebResponse)req.GetResponse())
            using (var rd = new StreamReader(resp.GetResponseStream())) return rd.ReadToEnd().IndexOf("\"type\"", StringComparison.Ordinal) >= 0;
        }
        catch { return false; }
    }

    static bool RunningFrom(string dir)
    {
        try
        {
            string d = Path.GetFullPath(dir).TrimEnd('\\') + "\\";
            using (var q = new System.Management.ManagementObjectSearcher("SELECT ExecutablePath FROM Win32_Process WHERE Name='java.exe' OR Name='javaw.exe' OR Name='pixelweb.exe'"))
                foreach (System.Management.ManagementObject p in q.Get())
                {
                    string path = Convert.ToString(p["ExecutablePath"]);
                    if (path.StartsWith(d, StringComparison.OrdinalIgnoreCase)) return true;
                }
        }
        catch { }
        return false;
    }

    public string Status()
    {
        return string.Format("pixelcade at {0}: {1} sent, {2} failed{3}", BaseUrl, Sent, Failed, LastError != null && Failed > 0 ? " (last: " + LastError + ")" : "");
    }
}
