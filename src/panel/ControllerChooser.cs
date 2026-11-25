// AmPanel - "Which controller will you use?" at game start (James 2026-11-25).
//
// <manifest>\controller-choices.json (tools\New-ControllerChoices.py: only games where THIS cabinet offers two or more
// controllers, best first) says what to offer. The question is a full-screen, top-most screen driven from the panel:
// stick / arrows move, button 1 (Left Ctrl) / Enter / Space picks, Esc keeps the highlighted one. The last pick for each
// game is highlighted and is taken by itself after a few seconds, so an unattended or attract launch never waits.
// Picks are kept in <manifest>\controller-picks.json.
// C# 5.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Windows.Forms;
using System.Web.Script.Serialization;

class ControllerChoices
{
    readonly string choicesFile, picksFile;
    Dictionary<string, Dictionary<string, object>> games = new Dictionary<string, Dictionary<string, object>>(StringComparer.OrdinalIgnoreCase);
    Dictionary<string, string> byItem = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);   // "pacman" -> "Arcades:pacman"
    Dictionary<string, string> picks = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    DateTime loadedAt;

    public ControllerChoices(string manifestDir)
    {
        choicesFile = Path.Combine(manifestDir, "controller-choices.json");
        picksFile = Path.Combine(manifestDir, "controller-picks.json");
        Reload();
    }

    // reloaded when the file changes: the hot-plug refresh rewrites it when controllers come and go
    void Reload()
    {
        var ser = new JavaScriptSerializer { MaxJsonLength = 32 * 1024 * 1024 };
        games.Clear(); byItem.Clear();
        try
        {
            if (File.Exists(choicesFile))
            {
                loadedAt = File.GetLastWriteTimeUtc(choicesFile);
                var root = ser.Deserialize<Dictionary<string, object>>(File.ReadAllText(choicesFile));
                var g = root.ContainsKey("games") ? root["games"] as Dictionary<string, object> : null;
                if (g != null) foreach (var kv in g)
                    {
                        var d = kv.Value as Dictionary<string, object>; if (d == null) continue;
                        games[kv.Key] = d;
                        int c = kv.Key.LastIndexOf(':'); string item = c >= 0 ? kv.Key.Substring(c + 1) : kv.Key;
                        if (!byItem.ContainsKey(item)) byItem[item] = kv.Key;
                    }
            }
            if (File.Exists(picksFile))
            {
                var p = ser.Deserialize<Dictionary<string, object>>(File.ReadAllText(picksFile));
                picks = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                foreach (var kv in p) picks[kv.Key] = Convert.ToString(kv.Value);
            }
        }
        catch { }
    }

    public int Count { get { return games.Count; } }

    // the game's entry: "<collection>:<item>" first, then the item alone
    public string Find(string item, string collection)
    {
        if (File.Exists(choicesFile) && File.GetLastWriteTimeUtc(choicesFile) != loadedAt) Reload();
        if (string.IsNullOrEmpty(item)) return null;
        if (collection != null && games.ContainsKey(collection + ":" + item)) return collection + ":" + item;
        if (games.ContainsKey(item)) return item;
        string id; return byItem.TryGetValue(item, out id) ? id : null;
    }

    public List<Dictionary<string, object>> Choices(string id)
    {
        var l = new List<Dictionary<string, object>>();
        Dictionary<string, object> g;
        if (id == null || !games.TryGetValue(id, out g)) return l;
        var a = g.ContainsKey("choices") ? g["choices"] as System.Collections.ArrayList : null;
        if (a != null) foreach (var o in a) { var d = o as Dictionary<string, object>; if (d != null) l.Add(d); }
        return l;
    }

    public string Title(string id) { Dictionary<string, object> g; return id != null && games.TryGetValue(id, out g) && g.ContainsKey("title") ? Convert.ToString(g["title"]) : id; }
    public string LastPick(string id) { string p; return id != null && picks.TryGetValue(id, out p) ? p : null; }

    public void SavePick(string id, string choice)
    {
        picks[id] = choice;
        try { File.WriteAllText(picksFile, new JavaScriptSerializer().Serialize(picks), new System.Text.UTF8Encoding(false)); } catch { }
    }
}

