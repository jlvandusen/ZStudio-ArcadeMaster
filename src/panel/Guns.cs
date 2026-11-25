// AmPanel step 7 - light guns: which are plugged in, from Windows' device list (docs/13-panel-service.md).
// Same USB ids as tools/Get-CabinetDevices.ps1. Calibration stays with each gun's own tool (no published AimTrak SDK);
// what AmPanel adds is presence, count and player order in one place, and (step 10) recoil rules per gun.
// C# 5.
using System;
using System.Collections.Generic;
using System.Management;
using System.Text.RegularExpressions;

static class Guns
{
    static readonly Dictionary<string, string> Known = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
        { "16C0:0F38", "Sinden" }, { "16C0:0F39", "Sinden" }, { "16C0:0F01", "Sinden" }, { "16C0:0F02", "Sinden" },
        { "2341:8042", "Gun4IR" }, { "2341:8043", "Gun4IR" }, { "2341:8044", "Gun4IR" }, { "2341:8045", "Gun4IR" } };

    // one entry per physical gun: kind, usb id, the name Windows gives it
    public static List<object> Find()
    {
        var found = new Dictionary<string, Dictionary<string, object>>(StringComparer.OrdinalIgnoreCase);
        try
        {
            using (var s = new ManagementObjectSearcher("SELECT DeviceID, Name FROM Win32_PnPEntity WHERE DeviceID LIKE 'USB\\\\VID_%'"))
                foreach (ManagementObject o in s.Get())
                {
                    string id = Convert.ToString(o["DeviceID"]), name = Convert.ToString(o["Name"]);
                    var m = Regex.Match(id, @"VID_([0-9A-F]{4})&PID_([0-9A-F]{4})", RegexOptions.IgnoreCase);
                    if (!m.Success) continue;
                    string usb = m.Groups[1].Value.ToUpperInvariant() + ":" + m.Groups[2].Value.ToUpperInvariant();
                    string kind = null;
                    if (Known.ContainsKey(usb)) kind = Known[usb];
                    else if (usb.StartsWith("D209:16")) kind = "Ultimarc AimTrak";            // D209:1601-1608 = AimTrak id 1-8
                    if (kind == null) continue;
                    // a gun is one USB device (several interfaces share the serial part of the instance path)
                    string key = usb + "|" + Regex.Replace(id, @"\\[^\\]*$", "") + Regex.Match(id, @"\\[^\\&]+$").Value;
                    if (found.ContainsKey(usb + "|" + id.Split('\\')[2].Split('&')[0])) continue;
                    var g = new Dictionary<string, object>();
                    g["kind"] = kind; g["usb"] = usb; g["name"] = name;
                    if (kind == "Ultimarc AimTrak") g["aimtrakId"] = Convert.ToInt32(usb.Substring(7), 16);   // 1601 -> 1 ...
                    found[usb + "|" + id.Split('\\')[2].Split('&')[0]] = g;
                }
        }
        catch { /* WMI unavailable: no guns listed, the service keeps running */ }
        var list = new List<object>(found.Values);
        list.Sort((a, b) => string.CompareOrdinal(Convert.ToString(((Dictionary<string, object>)a)["usb"]), Convert.ToString(((Dictionary<string, object>)b)["usb"])));
        return list;
    }
}
