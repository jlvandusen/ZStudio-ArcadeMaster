// AmPanel - the frontend watchdog (James 2026-11-27: "can we detect it and kill and reload?").
// On ARCADE-PEDESTAL Pokken Tournament (TeknoParrot) exited and left the NVIDIA driver stuck: RetroFE hung in
// NtGdiDdDDIGetDeviceState / nvoglv64, both screens stayed black and Alt+Tab did nothing, so the cabinet was dead
// until somebody came with a keyboard. This watches RetroFE while the menus are up (never during a game, where RetroFE
// waits on the game and may legitimately not pump its windows) and, after it has not answered for HangSec seconds:
//   1. stops RetroFE and the launcher's helpers (AmPanel stays: it is the one doing this),
//   2. resets the graphics driver through the "ArcadeMaster GPU Reset" task when it is installed
//      (tools\Install-GpuReset.ps1, run once elevated - it runs as SYSTEM, any user may start it),
//   3. starts the frontend again through ArcadeMaster.exe (its update check, then Start-ArcadeMaster).
// At most MaxPerWindow recoveries in WindowMin minutes, so a frontend that hangs every time is not restarted forever.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Management;

static class FrontendWatchdog
{
    public static int HangSec = 25, StartGraceSec = 60, MaxPerWindow = 2, WindowMin = 10;
    static DateTime hungSince = DateTime.MinValue;
    static readonly List<DateTime> recoveries = new List<DateTime>();
    static bool busy;

    // called every few seconds from AmPanel's UI timer; playing = a game is running (AmPanel's State["playing"])
    public static void Tick(bool playing, string installDir, Action<string> log)
    {
        if (busy) return;
        Process fe = null;
        try { var ps = Process.GetProcessesByName("retrofe"); if (ps.Length > 0) fe = ps[0]; } catch { }
        if (fe == null || playing) { hungSince = DateTime.MinValue; return; }
        bool responding = true; DateTime started = DateTime.Now;
        try { fe.Refresh(); responding = fe.Responding; started = fe.StartTime; } catch { }
        if (responding || (DateTime.Now - started).TotalSeconds < StartGraceSec) { hungSince = DateTime.MinValue; return; }
        // RetroFE is waiting on something it started (a Tools script, a game AmPanel was not told about): not a hang
        if (HasChild(fe.Id)) { hungSince = DateTime.MinValue; return; }
        if (hungSince == DateTime.MinValue) { hungSince = DateTime.Now; log("watchdog: the frontend is not answering - watching"); return; }
        if ((DateTime.Now - hungSince).TotalSeconds < HangSec) return;
        recoveries.RemoveAll(t => (DateTime.Now - t).TotalMinutes > WindowMin);
        if (recoveries.Count >= MaxPerWindow)
        {
            if ((DateTime.Now - hungSince).TotalSeconds < HangSec + 5)
                log("watchdog: the frontend hung again - " + recoveries.Count + " recoveries in " + WindowMin + " min already, leaving it (restart the PC)");
            return;
        }
        recoveries.Add(DateTime.Now); hungSince = DateTime.MinValue; busy = true;
        var th = new System.Threading.Thread(() => { try { Recover(installDir, log); } finally { busy = false; } });
        th.IsBackground = true; th.Start();
    }

    static void Recover(string installDir, Action<string> log)
    {
        log("watchdog: the frontend has not answered for " + HangSec + " s in the menus - stopping it, resetting the graphics driver, starting it again");
        // 1. RetroFE and the launcher's helpers (Start-ArcadeMaster, the cabinet link, hold-to-exit, the LEDBlinky shim)
        try
        {
            using (var q = new ManagementObjectSearcher("SELECT ProcessId, Name, CommandLine FROM Win32_Process"))
                foreach (ManagementObject p in q.Get())
                {
                    string name = Convert.ToString(p["Name"]), cl = Convert.ToString(p["CommandLine"]);
                    bool helper = (name.Equals("powershell.exe", StringComparison.OrdinalIgnoreCase) || name.Equals("pwsh.exe", StringComparison.OrdinalIgnoreCase))
                                  && (cl.IndexOf("Start-ArcadeMaster", StringComparison.OrdinalIgnoreCase) >= 0 || cl.IndexOf("AmLink", StringComparison.OrdinalIgnoreCase) >= 0 || cl.IndexOf("Watch-GameExit", StringComparison.OrdinalIgnoreCase) >= 0);
                    if (name.Equals("retrofe.exe", StringComparison.OrdinalIgnoreCase) || name.Equals("ArcadeMaster.exe", StringComparison.OrdinalIgnoreCase)
                        || name.Equals("LEDBlinky.exe", StringComparison.OrdinalIgnoreCase) || helper)
                        try { int pid = Convert.ToInt32(p["ProcessId"]); if (pid != Process.GetCurrentProcess().Id) Process.GetProcessById(pid).Kill(); } catch { }   // never itself (the LEDBlinky shim can be the tray)
                }
        }
        catch (Exception e) { log("watchdog: stopping the frontend: " + e.Message); }
        System.Threading.Thread.Sleep(2000);
        // 2. the graphics driver, when the elevated task is there
        string res = Run("schtasks.exe", "/run /tn \"ArcadeMaster GPU Reset\"");
        if (res.IndexOf("SUCCESS", StringComparison.OrdinalIgnoreCase) >= 0) { log("watchdog: graphics driver reset asked"); System.Threading.Thread.Sleep(10000); }
        else log("watchdog: no GPU reset task (run tools\\Install-GpuReset.ps1 once as admin) - restarting the frontend only");
        // 3. the frontend again
        string exe = Path.Combine(installDir ?? "", "ArcadeMaster.exe");
        try
        {
            if (File.Exists(exe)) { Process.Start(new ProcessStartInfo(exe) { WorkingDirectory = installDir, UseShellExecute = true }); log("watchdog: frontend started again"); }
            else log("watchdog: " + exe + " not found - the frontend was not started again");
        }
        catch (Exception e) { log("watchdog: start: " + e.Message); }
    }

    static bool HasChild(int pid)
    {
        try
        {
            using (var q = new ManagementObjectSearcher("SELECT ProcessId FROM Win32_Process WHERE ParentProcessId = " + pid))
                foreach (ManagementObject p in q.Get()) return true;
        }
        catch { }
        return false;
    }

    static string Run(string exe, string args)
    {
        try
        {
            var p = Process.Start(new ProcessStartInfo(exe, args) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true });
            string o = p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd(); p.WaitForExit(15000); return o;
        }
        catch (Exception e) { return e.Message; }
    }
}
