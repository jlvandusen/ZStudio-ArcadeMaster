// AmPanel - the Leap Motion works the menus (docs/20: "swipe / pinch / palm-hold into menu keys"; the 2P stand-up has the
// original Leap Motion Controller with software 3.2.1). The v3 service streams JSON frames over a local WebSocket
// (ws://127.0.0.1:6437/v6.json); with {"enableGestures": true} each frame carries finished gestures. While the frontend or
// one of AmPanel's own screens is in front (never in a game):
//   swipe up / down / left / right = the arrow keys     key tap (a finger pushed forward) or a pinch = Enter (select)
//   a circle drawn with a finger = Esc (back)
// No service running (LeapService is set to start by hand on the stand-up): it tries again every 10 s, quietly.
// C# 5.
using System;
using System.Diagnostics;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

class LeapGestures
{
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint type);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int pid);

    readonly Action<string> log;
    public Func<bool> GameRunning = () => false;
    DateTime lastKey = DateTime.MinValue;
    bool pinched;
    bool connectedOnce;

    public LeapGestures(Action<string> log)
    {
        this.log = log ?? delegate { };
        new Thread(Loop) { IsBackground = true, Name = "leap" }.Start();
    }

    void Loop()
    {
        bool saidMissing = false;
        while (true)
        {
            try
            {
                using (var ws = new ClientWebSocket())
                {
                    ws.ConnectAsync(new Uri("ws://127.0.0.1:6437/v6.json"), CancellationToken.None).Wait(3000);
                    if (ws.State != WebSocketState.Open) throw new Exception("no Leap Motion service on port 6437");
                    var hello = Encoding.UTF8.GetBytes("{\"enableGestures\": true}");
                    ws.SendAsync(new ArraySegment<byte>(hello), WebSocketMessageType.Text, true, CancellationToken.None).Wait();
                    log("leap: connected - swipe = arrows, tap / pinch = select, circle = back (menus only)");
                    connectedOnce = true; saidMissing = false;
                    var buf = new byte[65536]; var sb = new StringBuilder();
                    while (ws.State == WebSocketState.Open)
                    {
                        var r = ws.ReceiveAsync(new ArraySegment<byte>(buf), CancellationToken.None).Result;
                        if (r.MessageType == WebSocketMessageType.Close) break;
                        sb.Append(Encoding.UTF8.GetString(buf, 0, r.Count));
                        if (!r.EndOfMessage) continue;
                        string frame = sb.ToString(); sb.Clear();
                        try { OnFrame(frame); } catch { }
                    }
                }
                log("leap: connection closed");
            }
            catch (Exception e)
            {
                if (!saidMissing) { log("leap: " + (e.InnerException ?? e).Message + " (LeapService not running?) - trying again every 10 s"); saidMissing = true; }
            }
            Thread.Sleep(10000);
        }
    }

    // A frame is large; only the gestures and the hands' pinch matter here, read with patterns instead of a full parse.
    static readonly Regex Gesture = new Regex("\"direction\":\\[(?<x>-?[\\d.eE+-]+),(?<y>-?[\\d.eE+-]+),(?<z>-?[\\d.eE+-]+)\\][^{}]*?\"state\":\"(?<state>\\w+)\"[^{}]*?\"type\":\"(?<type>\\w+)\"|\"state\":\"(?<state2>\\w+)\"[^{}]*?\"type\":\"(?<type2>\\w+)\"");
    static readonly Regex Pinch = new Regex("\"pinchStrength\":(?<p>[\\d.]+)");

    void OnFrame(string f)
    {
        if (!InMenus()) { pinched = false; return; }
        int g = f.IndexOf("\"gestures\":[", StringComparison.Ordinal);
        if (g >= 0 && f.IndexOf("\"gestures\":[]", StringComparison.Ordinal) != g)
        {
            int end = f.IndexOf("],\"hands\"", g, StringComparison.Ordinal); if (end < 0) end = Math.Min(f.Length, g + 4000);
            foreach (Match m in Gesture.Matches(f.Substring(g, end - g)))
            {
                string type = m.Groups["type"].Success ? m.Groups["type"].Value : m.Groups["type2"].Value;
                string state = m.Groups["state"].Success ? m.Groups["state"].Value : m.Groups["state2"].Value;
                if (state != "stop") continue;   // a gesture counts once, when it ends
                if (type == "swipe")
                {
                    double x = double.Parse(m.Groups["x"].Value, System.Globalization.CultureInfo.InvariantCulture), y = double.Parse(m.Groups["y"].Value, System.Globalization.CultureInfo.InvariantCulture);
                    Press(Math.Abs(x) > Math.Abs(y) ? (byte)(x > 0 ? 0x27 : 0x25) : (byte)(y > 0 ? 0x26 : 0x28));
                }
                else if (type == "keyTap" || type == "screenTap") Press(0x0D);
                else if (type == "circle") Press(0x1B);
            }
        }
        // a pinch (thumb and finger together) selects, once per pinch
        var p = Pinch.Match(f);
        if (p.Success)
        {
            double v = double.Parse(p.Groups["p"].Value, System.Globalization.CultureInfo.InvariantCulture);
            if (v > 0.9 && !pinched) { pinched = true; Press(0x0D); }
            else if (v < 0.4) pinched = false;
        }
    }

    void Press(byte vk)
    {
        if ((DateTime.Now - lastKey).TotalMilliseconds < 350) return;   // one gesture, one key
        lastKey = DateTime.Now;
        bool ext = vk >= 0x25 && vk <= 0x28;
        uint sc = MapVirtualKey(vk, 0);
        keybd_event(vk, (byte)sc, ext ? 1u : 0u, UIntPtr.Zero);
        keybd_event(vk, (byte)sc, (ext ? 1u : 0u) | 2u, UIntPtr.Zero);
    }

    bool InMenus()
    {
        if (GameRunning()) return false;
        int pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        try { using (var p = Process.GetProcessById(pid)) return p.ProcessName.Equals("retrofe", StringComparison.OrdinalIgnoreCase) || p.Id == Process.GetCurrentProcess().Id; }
        catch { return false; }
    }
}
