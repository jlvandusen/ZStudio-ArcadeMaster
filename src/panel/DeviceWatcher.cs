// AmPanel - hot-plug listener: a controller plugged in or pulled updates the cabinet without a reboot.
//
// RegisterDeviceNotification (all device-interface classes) delivers WM_DEVICECHANGE arrival / removal to a hidden
// window. Bursts are debounced (one USB device brings several interfaces, and Windows needs a moment to finish), then
// tools\Update-Controllers.ps1 runs in a hidden PowerShell - the boot's device steps - and its "CHANGED:" line goes to
// the tray and to the frontend's state (pipe "status": devicesChanged / devicesChangedAt).
// C# 5.
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

class DeviceWatcher : NativeWindow
{
    [StructLayout(LayoutKind.Sequential)] struct DEV_BROADCAST_DEVICEINTERFACE { public int dbcc_size; public int dbcc_devicetype; public int dbcc_reserved; public Guid dbcc_classguid; public short dbcc_name; }
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr RegisterDeviceNotification(IntPtr h, ref DEV_BROADCAST_DEVICEINTERFACE filter, int flags);
    [DllImport("user32.dll")] static extern bool UnregisterDeviceNotification(IntPtr h);
    const int WM_DEVICECHANGE = 0x0219, DBT_DEVICEARRIVAL = 0x8000, DBT_DEVICEREMOVECOMPLETE = 0x8004, DBT_DEVTYP_DEVICEINTERFACE = 5;
    const int DEVICE_NOTIFY_WINDOW_HANDLE = 0, DEVICE_NOTIFY_ALL_INTERFACE_CLASSES = 4;

    readonly IntPtr note;
    readonly System.Windows.Forms.Timer settle = new System.Windows.Forms.Timer { Interval = 2500 };
    readonly string script, retroFE, manifestDir;
    readonly Action<string> done, log;
    int running;
    public int Events;
    // James 2026-11-25: "when a game is running turn off the listener so we don't affect the game's performance".
    // While a game plays, a change only sets Pending; the refresh runs when the game stops (Resume).
    public volatile bool GameRunning;
    public bool Pending { get; private set; }
    public void Resume() { if (Pending) { Pending = false; Poke(); } }

    public DeviceWatcher(string toolsDir, string retroFE, string manifestDir, Action<string> done, Action<string> log)
    {
        this.retroFE = retroFE; this.manifestDir = manifestDir; this.done = done; this.log = log;
        script = System.IO.Path.Combine(toolsDir, "Update-Controllers.ps1");
        CreateHandle(new CreateParams { Caption = "AmPanel devices" });
        var f = new DEV_BROADCAST_DEVICEINTERFACE { dbcc_devicetype = DBT_DEVTYP_DEVICEINTERFACE };
        f.dbcc_size = Marshal.SizeOf(f);
        note = RegisterDeviceNotification(Handle, ref f, DEVICE_NOTIFY_WINDOW_HANDLE | DEVICE_NOTIFY_ALL_INTERFACE_CLASSES);
        settle.Tick += delegate { settle.Stop(); log("devices: settled - refreshing"); Refresh(); };
        log("devices: hot-plug listener " + (note != IntPtr.Zero ? "on" : "NOT registered") + " (" + script + ")");
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_DEVICECHANGE || m.Msg == WM_AM_POKE)
        {
            int ev = m.Msg == WM_AM_POKE ? DBT_DEVICEARRIVAL : m.WParam.ToInt32();
            if (ev == DBT_DEVICEARRIVAL || ev == DBT_DEVICEREMOVECOMPLETE)
            {
                Events++;
                if (Events <= 5) log("devices: " + (ev == DBT_DEVICEARRIVAL ? "arrival" : "removal") + " message #" + Events);
                if (GameRunning) { if (!Pending) log("devices: changed during a game - refresh held until it ends"); Pending = true; }
                else { settle.Stop(); settle.Start(); }   // restart the settle timer on every burst
            }
        }
        base.WndProc(ref m);
    }

    // one refresh at a time, in the background: the tray never freezes
    void Refresh()
    {
        if (!System.IO.File.Exists(script)) { log("devices: changed, but " + script + " is missing"); return; }
        if (Interlocked.Exchange(ref running, 1) == 1) { settle.Start(); return; }   // busy: try again after it
        ThreadPool.QueueUserWorkItem(delegate {
            try
            {
                // AmPanel is x86 (Ultimarc's DLLs are 32-bit): plain powershell.exe would be the 32-bit one, where the
                // device tools' cached 64-bit helpers cannot load. Sysnative reaches the 64-bit PowerShell from a 32-bit process.
                string ps = System.IO.Path.Combine(Environment.GetEnvironmentVariable("WINDIR") ?? @"C:\Windows", Environment.Is64BitProcess ? @"System32\WindowsPowerShell\v1.0\powershell.exe" : @"Sysnative\WindowsPowerShell\v1.0\powershell.exe");
                var psi = new ProcessStartInfo(ps, "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\" -RetroFE \"" + retroFE + "\" -ManifestDir \"" + manifestDir + "\"")
                    { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
                var sw = Stopwatch.StartNew();
                using (var p = Process.Start(psi))
                {
                    string all = p.StandardOutput.ReadToEnd(); p.WaitForExit(120000);
                    string line = "CHANGED: ?";
                    foreach (var l in all.Split('\n')) if (l.StartsWith("CHANGED:")) line = l.Trim();
                    log("devices: " + line + " (" + (int)sw.Elapsed.TotalSeconds + " s)");
                    done(line);
                }
            }
            catch (Exception e) { log("devices: refresh failed - " + e.Message); }
            finally { Interlocked.Exchange(ref running, 0); }
        });
    }

    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
    // the same path as a real plug-in, from any thread (pipe "devicechange", Detect Controllers)
    // Windows refuses to POST WM_DEVICECHANGE with arrival / removal (its lParam is a pointer - send-only), so a poke is
    // a private message the window treats exactly like an arrival
    const int WM_AM_POKE = 0x8001;   // WM_APP + 1
    public void Poke() { PostMessage(Handle, WM_AM_POKE, IntPtr.Zero, IntPtr.Zero); }

    public void Stop() { if (note != IntPtr.Zero) UnregisterDeviceNotification(note); DestroyHandle(); }
}
