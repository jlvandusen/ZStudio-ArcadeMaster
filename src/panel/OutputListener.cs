// AmPanel step 9 - emulator outputs (lamps, recoil, motors), docs/13-panel-service.md.
//
// MAME's documented Windows output protocol (src/osd/windows/winoutput, output.h), also spoken by Supermodel
// (-outputs=win), Model 2 Emulator, Flycast and TeknoParrot output plugins:
//   emulator -> HWND_BROADCAST  "MAMEOutputStart"        wParam = emulator's window
//   listener -> emulator         "MAMEOutputRegister"     wParam = client id, lParam = listener's window
//   emulator -> listener         "MAMEOutputUpdateState"  wParam = output id, lParam = value
//   listener -> emulator         "MAMEOutputGetIdString"  wParam = output id, lParam = listener's window
//   emulator -> listener         WM_COPYDATA dwData = 1   { UINT32 id; char name[] }
//   emulator -> HWND_BROADCAST  "MAMEOutputStop"
// An emulator already running when AmPanel starts is found with FindWindow("MAMEOutput", "MAMEOutput").
// Every output a game sends is recorded (name, last value, how often it changed) and saved to
// <manifest>\outputs\<game>.json when the emulator stops - the learned list the Triggers screen offers.
// C# 5.
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

class OutputListener : NativeWindow
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RegisterWindowMessage(string name);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] struct COPYDATASTRUCT { public IntPtr dwData; public int cbData; public IntPtr lpData; }
    const int WM_COPYDATA = 0x004A;
    const int ClientId = 0x414D50;   // "AMP"

    readonly uint msgStart, msgStop, msgUpdate, msgRegister, msgUnregister, msgGetId;
    IntPtr emulator = IntPtr.Zero;
    readonly object gate = new object();
    public class Output { public string Name; public int Value; public int Changes; public DateTime Last; }
    readonly Dictionary<int, Output> outputs = new Dictionary<int, Output>();
    readonly Func<string> currentGame;
    readonly string outDir;
    readonly Action<string> log;
    public event Action<string, int> Changed;   // name, value - the trigger -> activity rules hook in here (step 10)
    public bool Connected { get { return emulator != IntPtr.Zero; } }

    public OutputListener(string manifestDir, Func<string> currentGame, Action<string> log)
    {
        this.currentGame = currentGame; this.log = log;
        outDir = Path.Combine(manifestDir, "outputs");
        msgStart = RegisterWindowMessage("MAMEOutputStart");
        msgStop = RegisterWindowMessage("MAMEOutputStop");
        msgUpdate = RegisterWindowMessage("MAMEOutputUpdateState");
        msgRegister = RegisterWindowMessage("MAMEOutputRegister");
        msgUnregister = RegisterWindowMessage("MAMEOutputUnregister");
        msgGetId = RegisterWindowMessage("MAMEOutputGetIDString");
        // a top-level (hidden) window: HWND_BROADCAST does not reach message-only windows
        CreateHandle(new CreateParams { Caption = "AmPanel outputs", ClassName = null });
        IntPtr running = FindWindow("MAMEOutput", "MAMEOutput");
        if (running != IntPtr.Zero) Attach(running);
    }

    void Attach(IntPtr hwnd)
    {
        // the output window by its documented class name; the broadcast's wParam is only a fallback
        IntPtr byClass = FindWindow("MAMEOutput", null);
        if (Trace) log("outputs: start wParam " + hwnd + ", FindWindow(MAMEOutput) " + byClass);
        if (byClass != IntPtr.Zero) hwnd = byClass;
        emulator = hwnd;
        lock (gate) outputs.Clear();
        // synchronous, as the protocol's own listeners do; MAME answers by sending every current output state
        IntPtr r = SendMessage(emulator, msgRegister, Handle, (IntPtr)ClientId);   // wParam = our window, lParam = client id
        log("outputs: emulator connected (register answered " + r + ")");
    }

    void Detach()
    {
        if (emulator == IntPtr.Zero) return;
        Save();
        emulator = IntPtr.Zero;
        log("outputs: emulator stopped");
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClipboardFormatName(uint format, StringBuilder name, int size);
    public static bool Trace;          // AmPanel.json "TraceOutputs": true - log every registered message the listener gets
    int traced;

    protected override void WndProc(ref Message m)
    {
        uint msg = (uint)m.Msg;
        if (Trace && traced < 60 && (msg >= 0xC000 || msg == WM_COPYDATA))
        {
            var nb = new StringBuilder(128); GetClipboardFormatName(msg, nb, 128);
            log(string.Format("outputs trace: msg 0x{0:X4} {1} w={2} l={3}", msg, msg == WM_COPYDATA ? "WM_COPYDATA" : nb.ToString(), m.WParam, m.LParam));
            traced++;
        }
        if (msg == msgStart && msgStart != 0) { Attach(m.WParam); return; }
        if (msg == msgStop && msgStop != 0) { Detach(); return; }
        if (msg == msgUpdate && msgUpdate != 0)
        {
            int id = m.WParam.ToInt32(), value = m.LParam.ToInt32();
            Output o; bool ask = false;
            lock (gate)
            {
                if (!outputs.TryGetValue(id, out o)) { o = new Output { Name = "#" + id }; outputs[id] = o; ask = true; }
                o.Value = value; o.Changes++; o.Last = DateTime.Now;
            }
            if (ask && emulator != IntPtr.Zero) PostMessage(emulator, msgGetId, Handle, (IntPtr)id);   // wParam = our window, lParam = output id; name arrives as WM_COPYDATA
            var h = Changed; if (h != null) h(o.Name, value);
            return;
        }
        if (m.Msg == WM_COPYDATA)
        {
            var cds = (COPYDATASTRUCT)Marshal.PtrToStructure(m.LParam, typeof(COPYDATASTRUCT));
            if (cds.dwData.ToInt64() == 1 && cds.cbData > 4)   // COPYDATA_MESSAGE_ID_STRING: { UINT32 id; char name[] }
            {
                int id = Marshal.ReadInt32(cds.lpData);
                var bytes = new byte[cds.cbData - 4];
                Marshal.Copy(IntPtr.Add(cds.lpData, 4), bytes, 0, bytes.Length);
                string name = Encoding.ASCII.GetString(bytes).TrimEnd('\0');
                lock (gate) { Output o; if (outputs.TryGetValue(id, out o)) o.Name = name; else outputs[id] = new Output { Name = name }; }
                m.Result = (IntPtr)1;
                return;
            }
        }
        base.WndProc(ref m);
    }

    // what the pipe's "status" shows: name -> value
    public Dictionary<string, object> Snapshot()
    {
        var d = new Dictionary<string, object>();
        lock (gate) foreach (var o in outputs.Values) d[o.Name] = o.Value;
        return d;
    }

    // <manifest>\outputs\<game>.json: every output the game sent, merged with earlier sessions
    void Save()
    {
        string game = currentGame() ?? "unknown";
        try
        {
            Directory.CreateDirectory(outDir);
            var sb = new StringBuilder("{\n  \"game\": \"").Append(Esc(game)).Append("\",\n  \"saved\": \"").Append(DateTime.Now.ToString("s")).Append("\",\n  \"outputs\": {");
            bool first = true;
            lock (gate)
            {
                foreach (var o in outputs.Values)
                {
                    sb.Append(first ? "\n" : ",\n").Append("    \"").Append(Esc(o.Name)).Append("\": { \"last\": ").Append(o.Value).Append(", \"changes\": ").Append(o.Changes).Append(" }");
                    first = false;
                }
            }
            sb.Append("\n  }\n}\n");
            string safe = string.Join("_", game.Split(Path.GetInvalidFileNameChars()));
            File.WriteAllText(Path.Combine(outDir, safe + ".json"), sb.ToString(), new UTF8Encoding(false));
            log("outputs: saved " + outputs.Count + " for " + game);
        }
        catch (Exception e) { log("outputs: save failed - " + e.Message); }
    }

    static string Esc(string s) { return (s ?? "").Replace("\\", "\\\\").Replace("\"", "\\\""); }

    public void Shutdown()
    {
        if (emulator != IntPtr.Zero) { PostMessage(emulator, msgUnregister, Handle, (IntPtr)ClientId); Save(); }
        DestroyHandle();
    }
}
