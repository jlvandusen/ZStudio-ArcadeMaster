// AmPanel - a key turned into another key while a given program is in front (James 2026-11-27, 2P stand-up: the foot
// pedals now send F13 / F14 / F15 so they never clash with the panel, but the PS3 Time Crisis games still wait for the
// old A / C). Rules from tools\key-remap.<COMPUTERNAME>.json: { "process": "<pattern on the program name>", "from": "F13",
// "to": "A" }. A low-level keyboard hook swallows the "from" key while that program has the foreground and presses
// "to" instead, held as long as "from" is held. Keys this hook sends itself (injected) are never remapped again.
// C# 5.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

class KeyRemap
{
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, LowLevelProc fn, IntPtr mod, uint thread);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int code, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint type);
    delegate IntPtr LowLevelProc(int code, IntPtr w, IntPtr l);
    const int WH_KEYBOARD_LL = 13, WM_KEYDOWN = 0x100, WM_KEYUP = 0x101, WM_SYSKEYDOWN = 0x104, WM_SYSKEYUP = 0x105, LLKHF_INJECTED = 0x10;

    class Rule { public Regex Process; public int From, To; }
    readonly List<Rule> rules = new List<Rule>();
    readonly Dictionary<int, int> held = new Dictionary<int, int>();   // from -> to, while held
    readonly LowLevelProc proc;
    IntPtr hook = IntPtr.Zero;
    readonly Action<string> log;
    string fgName = ""; DateTime fgAt = DateTime.MinValue;

    public int Count { get { return rules.Count; } }

    public KeyRemap(string toolsDir, Action<string> log)
    {
        this.log = log ?? delegate { };
        string f = toolsDir == null ? null : Path.Combine(toolsDir, "key-remap." + Environment.MachineName + ".json");
        if (f == null || !File.Exists(f)) return;
        try
        {
            var js = new System.Web.Script.Serialization.JavaScriptSerializer();
            var d = js.Deserialize<Dictionary<string, object>>(File.ReadAllText(f));
            var list = d.ContainsKey("rules") ? d["rules"] as System.Collections.ArrayList : null;
            if (list != null) foreach (var o in list)
            {
                var r = o as Dictionary<string, object>; if (r == null) continue;
                int from = ReactiveKeys.VkOf(Convert.ToString(r["from"])), to = ReactiveKeys.VkOf(Convert.ToString(r["to"]));
                if (from == 0 || to == 0) { this.log("key remap: unknown key in " + Convert.ToString(r["from"]) + " -> " + Convert.ToString(r["to"])); continue; }
                rules.Add(new Rule { Process = new Regex(Convert.ToString(r["process"]), RegexOptions.IgnoreCase), From = from, To = to });
            }
        }
        catch (Exception e) { this.log("key remap: " + f + " unreadable - " + e.Message); return; }
        if (rules.Count == 0) return;
        proc = Hook;
        using (var p = Process.GetCurrentProcess()) using (var m = p.MainModule) hook = SetWindowsHookEx(WH_KEYBOARD_LL, proc, GetModuleHandle(m.ModuleName), 0);
        this.log("key remap: " + rules.Count + " rule(s) from " + Path.GetFileName(f) + (hook == IntPtr.Zero ? " - keyboard hook failed" : ""));
    }

    public void Close() { if (hook != IntPtr.Zero) UnhookWindowsHookEx(hook); hook = IntPtr.Zero; }

    string Foreground()
    {
        if ((DateTime.Now - fgAt).TotalMilliseconds < 300) return fgName;   // a held key repeats: no process lookup each time
        fgAt = DateTime.Now; int pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        try { using (var p = Process.GetProcessById(pid)) fgName = p.ProcessName; } catch { fgName = ""; }
        return fgName;
    }

    IntPtr Hook(int code, IntPtr w, IntPtr l)
    {
        if (code >= 0)
        {
            int vk = Marshal.ReadInt32(l), flags = Marshal.ReadInt32(l, 8);
            bool down = (int)w == WM_KEYDOWN || (int)w == WM_SYSKEYDOWN, up = (int)w == WM_KEYUP || (int)w == WM_SYSKEYUP;
            if ((flags & LLKHF_INJECTED) == 0 && (down || up))
            {
                int to;
                if (up && held.TryGetValue(vk, out to)) { held.Remove(vk); Send(to, false); return (IntPtr)1; }   // let go of what we pressed
                if (down)
                {
                    if (held.TryGetValue(vk, out to)) { Send(to, true); return (IntPtr)1; }                         // auto-repeat
                    string fg = null;
                    foreach (var r in rules)
                        if (r.From == vk && r.Process.IsMatch(fg ?? (fg = Foreground()))) { held[vk] = r.To; Send(r.To, true); return (IntPtr)1; }
                }
            }
        }
        return CallNextHookEx(hook, code, w, l);
    }

    static void Send(int vk, bool down)
    {
        bool ext = vk >= 0x21 && vk <= 0x2E;   // arrows, Insert / Delete / Home / End / Page keys
        keybd_event((byte)vk, (byte)MapVirtualKey((uint)vk, 0), (ext ? 1u : 0u) | (down ? 0u : 2u), UIntPtr.Zero);
    }
}
