// AmPanel step 5 - reactive buttons: a button glows while it is held (docs/13-panel-service.md). LEDBlinky cannot.
//
// A low-level keyboard hook (the I-PAC sends the panel's buttons as keys) maps each key to its button through the
// InputMap's inputCodes. The hook callback only records the change and returns at once - Windows drops a hook that is
// slow, and every key on the PC goes through it - and a worker thread does the LED write (one SDK call, ~3 ms).
// C# 5.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

class ReactiveKeys
{
    delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int idHook, HookProc fn, IntPtr hMod, uint threadId);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
    const int WH_KEYBOARD_LL = 13, WM_KEYDOWN = 0x100, WM_KEYUP = 0x101, WM_SYSKEYDOWN = 0x104, WM_SYSKEYUP = 0x105;

    readonly HookProc proc;   // kept alive: the GC must not collect the callback
    IntPtr hook;
    readonly Dictionary<int, List<string>> vkToLabels = new Dictionary<int, List<string>>();
    readonly bool[] down = new bool[256];
    readonly Queue<KeyValuePair<string, bool>> work = new Queue<KeyValuePair<string, bool>>();
    readonly AutoResetEvent signal = new AutoResetEvent(false);
    readonly Action<string, bool> apply;
    public int Presses;

    // MAME KEYCODE names (as in LEDBlinkyInputMap.xml) -> Windows virtual keys
    static readonly Dictionary<string, int> Vk = BuildVk();
    static Dictionary<string, int> BuildVk()
    {
        var d = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase) {
            { "LEFT", 0x25 }, { "UP", 0x26 }, { "RIGHT", 0x27 }, { "DOWN", 0x28 }, { "LCONTROL", 0xA2 }, { "RCONTROL", 0xA3 },
            { "LALT", 0xA4 }, { "RALT", 0xA5 }, { "LSHIFT", 0xA0 }, { "RSHIFT", 0xA1 }, { "SPACE", 0x20 }, { "ENTER", 0x0D },
            { "ESC", 0x1B }, { "TAB", 0x09 }, { "OPENBRACE", 0xDB }, { "CLOSEBRACE", 0xDD }, { "EQUALS", 0xBB }, { "MINUS", 0xBD },
            { "COMMA", 0xBC }, { "STOP", 0xBE }, { "BACKSLASH", 0xDC }, { "SLASH", 0xBF }, { "COLON", 0xBA }, { "QUOTE", 0xDE },
            { "TILDE", 0xC0 }, { "BACKSPACE", 0x08 }, { "PGUP", 0x21 }, { "PGDN", 0x22 }, { "HOME", 0x24 }, { "END", 0x23 },
            { "INSERT", 0x2D }, { "DEL", 0x2E } };
        for (int i = 0; i < 26; i++) d[((char)('A' + i)).ToString()] = 0x41 + i;
        for (int i = 0; i < 10; i++) { d[i.ToString()] = 0x30 + i; d[i + "_PAD"] = 0x60 + i; }
        for (int i = 1; i <= 24; i++) d["F" + i] = 0x6F + i;   // F13-F24: the 2P stand-up's foot pedals (tools/Set-FootSwitch.ps1)
        return d;
    }

    // a MAME KEYCODE name ("KEYCODE_LCONTROL" or "LCONTROL") -> its Windows virtual key, 0 when unknown
    public static int VkOf(string keycode)
    {
        string n = keycode.StartsWith("KEYCODE_", StringComparison.OrdinalIgnoreCase) ? keycode.Substring(8) : keycode;
        int vk; return Vk.TryGetValue(n, out vk) ? vk : 0;
    }

    public ReactiveKeys(Dictionary<string, List<string>> keyLabels, Action<string, bool> apply)
    {
        this.apply = apply;
        foreach (var kv in keyLabels)
        {
            string name = kv.Key.StartsWith("KEYCODE_", StringComparison.OrdinalIgnoreCase) ? kv.Key.Substring(8) : kv.Key;
            int vk; if (!Vk.TryGetValue(name, out vk)) continue;
            List<string> l; if (!vkToLabels.TryGetValue(vk, out l)) { l = new List<string>(); vkToLabels[vk] = l; }
            foreach (var lab in kv.Value) if (!l.Contains(lab)) l.Add(lab);
        }
        new Thread(Worker) { IsBackground = true, Name = "glow" }.Start();
        proc = Hook;
        using (var p = Process.GetCurrentProcess()) using (var m = p.MainModule) hook = SetWindowsHookEx(WH_KEYBOARD_LL, proc, GetModuleHandle(m.ModuleName), 0);
    }

    public int MappedKeys { get { return vkToLabels.Count; } }
    public bool Active { get { return hook != IntPtr.Zero; } }

    // every key event the panel / keyboard sends (not only mapped buttons), newest last: the pipe's "keylog" command
    // shows it, so a remote session can see what the cabinet's controls really send (2026-11-26)
    readonly Queue<string> keyLog = new Queue<string>();
    public Action<int> KeyPressed;   // a real (not injected) key going down: AmPanel's hotkeys
    public string[] KeyLog() { lock (keyLog) return keyLog.ToArray(); }

    IntPtr Hook(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0)
        {
            int msg = wParam.ToInt32(), vk = Marshal.ReadInt32(lParam), flags = Marshal.ReadInt32(lParam, 8);
            bool isDown = msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN, isUp = msg == WM_KEYUP || msg == WM_SYSKEYUP;
            if (isDown && vk > 0 && vk < 256 && !down[vk] && (flags & 0x10) == 0 && KeyPressed != null)
                try { KeyPressed(vk); } catch { }   // hotkeys (F3 = search); must return at once - the hook has a time limit
            if ((isDown || isUp) && vk > 0 && vk < 256 && (isUp || !down[vk]))
                lock (keyLog)
                {
                    keyLog.Enqueue(DateTime.Now.ToString("HH:mm:ss.fff") + " " + (isDown ? "down " : "up   ") + (System.Windows.Forms.Keys)vk + ((flags & 0x10) != 0 ? " (injected)" : ""));
                    while (keyLog.Count > 200) keyLog.Dequeue();
                }
            List<string> labels;
            if ((isDown || isUp) && vk > 0 && vk < 256 && down[vk] != isDown && vkToLabels.TryGetValue(vk, out labels))
            {
                down[vk] = isDown;     // key repeat sends more downs: only the first one counts
                if (isDown) Presses++;
                lock (work) foreach (var l in labels) work.Enqueue(new KeyValuePair<string, bool>(l, isDown));
                signal.Set();
            }
        }
        return CallNextHookEx(hook, code, wParam, lParam);   // never swallows a key: games get every press
    }

    void Worker()
    {
        for (;;)
        {
            signal.WaitOne();
            for (;;)
            {
                KeyValuePair<string, bool> item;
                lock (work) { if (work.Count == 0) break; item = work.Dequeue(); }
                try { apply(item.Key, item.Value); } catch { }
            }
        }
    }

    public void Stop() { if (hook != IntPtr.Zero) { UnhookWindowsHookEx(hook); hook = IntPtr.Zero; } }
}
