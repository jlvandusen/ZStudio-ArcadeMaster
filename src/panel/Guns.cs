// AmPanel step 7 - light guns: which are plugged in, from Windows' device list (docs/13-panel-service.md).
// Every gun ArcadeMaster knows is in tools/light-guns.json (shared with tools/Get-CabinetDevices.ps1; Build-AmPanel.ps1
// copies it next to AmPanel.exe): AimTrak, Sinden, GUN4IR (and the AE builds), OpenFIRE, Namco GunCon 2 / 3, and by
// name Retro Shooter / Blamcon (no published USB id). Calibration stays with each gun's own tool. One entry per
// physical gun: a gun is one USB device; its interfaces (&MI_00, &MI_01 ...) are not counted again (the 2P stand-up's
// two AimTraks showed as four, 2026-11-27).
// C# 5.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Management;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

static class Guns
{
    class Rule { public string Usb, Kind, Match; public int Player; }
    static List<Rule> byUsb, byName;
    static HashSet<string> notGuns;

    static void Load()
    {
        if (byUsb != null) return;
        byUsb = new List<Rule>(); byName = new List<Rule>(); notGuns = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        string exe = AppDomain.CurrentDomain.BaseDirectory;
        foreach (var f in new[] { Path.Combine(exe, "light-guns.json"), Path.Combine(exe, @"..\tools\light-guns.json") })
        {
            if (!File.Exists(f)) continue;
            try
            {
                var j = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(f));
                foreach (Dictionary<string, object> g in (System.Collections.ArrayList)j["guns"])
                    byUsb.Add(new Rule { Usb = Convert.ToString(g["usb"]).ToUpperInvariant(), Kind = Convert.ToString(g["kind"]), Player = g.ContainsKey("player") ? Convert.ToInt32(g["player"]) : 0 });
                if (j.ContainsKey("names")) foreach (Dictionary<string, object> n in (System.Collections.ArrayList)j["names"]) byName.Add(new Rule { Match = Convert.ToString(n["match"]), Kind = Convert.ToString(n["kind"]) });
                if (j.ContainsKey("not")) foreach (var n in (System.Collections.ArrayList)j["not"]) notGuns.Add(Convert.ToString(n));
                return;
            }
            catch { byUsb.Clear(); byName.Clear(); notGuns.Clear(); }
        }
        // built in, when the file is missing: the families the cabinets have used
        byUsb.Add(new Rule { Usb = "D209:16", Kind = "Ultimarc AimTrak" });
        foreach (var p in new[] { "0F01", "0F02", "0F38", "0F39" }) byUsb.Add(new Rule { Usb = "16C0:" + p, Kind = "Sinden" });
        foreach (var p in new[] { "8042", "8043", "8044", "8045", "8046", "8047" }) byUsb.Add(new Rule { Usb = "2341:" + p, Kind = "GUN4IR" });
        foreach (var p in new[] { "0001", "0002", "0003", "0004" }) byUsb.Add(new Rule { Usb = "F143:" + p, Kind = "OpenFIRE" });
        byUsb.Add(new Rule { Usb = "0B9A:016A", Kind = "Namco GunCon 2" }); byUsb.Add(new Rule { Usb = "0B9A:0800", Kind = "Namco GunCon 3" });
        byName.Add(new Rule { Match = "(?i)retro ?shooter|blamcon|light ?gun", Kind = "light gun" });
        notGuns.Add("16C0:0F37");
    }

    // the gun kind for a USB id (and the name Windows gives the device), or null when it is not a light gun
    public static string Kind(string usb, string name)
    {
        Load();
        if (usb != null)
        {
            usb = usb.ToUpperInvariant();
            if (notGuns.Contains(usb)) return null;
            var r = byUsb.FirstOrDefault(x => usb == x.Usb || (x.Usb.Length < 9 && usb.StartsWith(x.Usb)));
            if (r != null) return r.Kind + (r.Kind == "Ultimarc AimTrak" && usb.Length == 9 ? " " + Convert.ToInt32(usb.Substring(7), 16) : "");
        }
        if (!string.IsNullOrEmpty(name)) { var n = byName.FirstOrDefault(x => Regex.IsMatch(name, x.Match)); if (n != null) return n.Kind; }
        return null;
    }

    // one entry per physical gun: kind, usb id, the name Windows gives it (AimTrak: its id; known player slots)
    public static List<object> Find()
    {
        Load();
        var found = new Dictionary<string, Dictionary<string, object>>(StringComparer.OrdinalIgnoreCase);
        try
        {
            using (var s = new ManagementObjectSearcher("SELECT DeviceID, Name FROM Win32_PnPEntity WHERE DeviceID LIKE 'USB\\\\VID_%'"))
                foreach (ManagementObject o in s.Get())
                {
                    string id = Convert.ToString(o["DeviceID"]), name = Convert.ToString(o["Name"]);
                    if (id.IndexOf("&MI_", StringComparison.OrdinalIgnoreCase) >= 0) continue;   // an interface of a device already counted
                    var m = Regex.Match(id, @"VID_([0-9A-F]{4})&PID_([0-9A-F]{4})", RegexOptions.IgnoreCase);
                    if (!m.Success) continue;
                    string usb = m.Groups[1].Value.ToUpperInvariant() + ":" + m.Groups[2].Value.ToUpperInvariant();
                    string kind = Kind(usb, name);
                    if (kind == null) continue;
                    var g = new Dictionary<string, object>();
                    g["kind"] = kind; g["usb"] = usb; g["name"] = name;
                    if (usb.StartsWith("D209:16")) g["aimtrakId"] = Convert.ToInt32(usb.Substring(7), 16);   // 1601 -> 1 ...
                    var rule = byUsb.FirstOrDefault(x => x.Usb == usb);
                    if (rule != null && rule.Player > 0) g["player"] = rule.Player;
                    found[id] = g;
                }
        }
        catch { /* WMI unavailable: no guns listed, the service keeps running */ }
        var list = new List<object>(found.Values);
        list.Sort((a, b) => string.CompareOrdinal(Convert.ToString(((Dictionary<string, object>)a)["usb"]), Convert.ToString(((Dictionary<string, object>)b)["usb"])));
        return list;
    }
}
