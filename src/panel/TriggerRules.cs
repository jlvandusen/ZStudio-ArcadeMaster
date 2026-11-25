// AmPanel step 10 - trigger -> activity rules (docs/13-panel-service.md).
//
// Rules come from tools\panel-rules.json (the repo's defaults, shipped next to AmPanel.exe as panel-rules.json) and
// <manifest>\panel-rules.json (this cabinet's own, tried first). The most specific rule wins: a game's own rule beats a
// system's beats a global one; within one level the first match in the file wins.
//
//   { "match": "led0", "game": "*", "do": "led", "target": "P1START", "color": "White" }
//   { "match": "*recoil*", "do": "recoil", "target": "P1" }          (logged until the gun output is wired - step 7)
//   { "match": "*", "game": "pacman", "do": "ignore" }
//
// "match" and "game" take * and ? wildcards, case-insensitive. "led": value != 0 lights target in color, value 0 puts
// the target back to the game's own colour. C# 5.
using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

class TriggerRules
{
    class Rule { public Regex Match, Game; public string System, Do, Target, Color; public int Specificity; public string Source; }
    readonly List<Rule> rules = new List<Rule>();
    public int Count { get { return rules.Count; } }
    public int Hits;

    public TriggerRules(params string[] files)
    {
        int order = 0, fileNo = -1;
        foreach (var f in files)
        {
            fileNo++;
            if (f == null || !File.Exists(f)) continue;
            string src = fileNo == 0 ? "this cabinet" : "defaults";   // files[0] is the cabinet's own, the rest are shipped
            try
            {
                var root = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(f));
                var list = root.ContainsKey("rules") ? root["rules"] as System.Collections.ArrayList : null;
                if (list == null) continue;
                foreach (Dictionary<string, object> r in list)
                {
                    string game = Get(r, "game") ?? "*", sys = Get(r, "system");
                    rules.Add(new Rule {
                        Match = Glob(Get(r, "match") ?? "*"), Game = Glob(game), System = sys,
                        Do = (Get(r, "do") ?? "led").ToLowerInvariant(), Target = Get(r, "target"), Color = Get(r, "color") ?? "White",
                        Specificity = (game != "*" ? 2 : sys != null ? 1 : 0) * 10000 - order++, Source = src });
                }
            }
            catch { /* a broken rules file must never stop the service; the log says it is missing rules */ }
        }
        rules.Sort((a, b) => b.Specificity.CompareTo(a.Specificity));
    }

    // what to do for this output of this game; null = nothing
    public string Apply(string output, int value, string game, string system, LedEngine leds, Action<string> log)
    {
        foreach (var r in rules)
        {
            if (!r.Match.IsMatch(output ?? "")) continue;
            if (!r.Game.IsMatch(game ?? "")) continue;
            if (r.System != null && !string.Equals(r.System, system, StringComparison.OrdinalIgnoreCase)) continue;
            Hits++;
            switch (r.Do)
            {
                case "ignore": return null;
                case "led":
                    if (leds == null || r.Target == null || !leds.HasLabel(r.Target)) return null;
                    leds.Override(r.Target, value != 0 ? (leds.Color(r.Color) ?? new[] { 48, 48, 48 }) : null);
                    return r.Target + (value != 0 ? " on (" + r.Color + ")" : " back to game colour");
                default:
                    // recoil / rumble / ffb / counter: the rule is honoured once that device path exists (steps 7 and 10)
                    if (log != null) log("rule '" + r.Do + "' for " + output + "=" + value + " (" + r.Target + "): not wired yet");
                    return r.Do + " (not wired yet)";
            }
        }
        return null;
    }

    // which rule an output follows for a game, in words (the Triggers screen)
    public string Describe(string output, string game)
    {
        foreach (var r in rules)
        {
            if (!r.Match.IsMatch(output ?? "") || !r.Game.IsMatch(game ?? "")) continue;
            return r.Do + (r.Target != null ? " " + r.Target : "") + (r.Do == "led" ? " " + r.Color : "") + "  (" + r.Source + ")";
        }
        return "-";
    }

    // the Triggers screen saves a game's rule for one output into the cabinet's own rules file; replaces an earlier one
    public static void SaveCabinetRule(string file, string output, string game, string action, string target, string color)
    {
        var js = new JavaScriptSerializer();
        var root = File.Exists(file) ? js.Deserialize<Dictionary<string, object>>(File.ReadAllText(file)) : new Dictionary<string, object>();
        var list = root.ContainsKey("rules") ? root["rules"] as System.Collections.ArrayList : null;
        if (list == null) list = new System.Collections.ArrayList();
        for (int i = list.Count - 1; i >= 0; i--)
        {
            var r = list[i] as Dictionary<string, object>;
            if (r != null && string.Equals(Get(r, "match"), output, StringComparison.OrdinalIgnoreCase) && string.Equals(Get(r, "game") ?? "*", game, StringComparison.OrdinalIgnoreCase)) list.RemoveAt(i);
        }
        if (action != "default")   // "default" = no cabinet rule: the shipped defaults apply again
        {
            var n = new Dictionary<string, object>(); n["match"] = output; n["game"] = game; n["do"] = action;
            if (!string.IsNullOrEmpty(target)) n["target"] = target;
            if (action == "led" && !string.IsNullOrEmpty(color)) n["color"] = color;
            list.Insert(0, n);
        }
        root["rules"] = list;
        if (!root.ContainsKey("_comment")) root["_comment"] = "This cabinet's own trigger rules (AmPanel Triggers screen). They win over the shipped defaults.";
        File.WriteAllText(file, js.Serialize(root), new System.Text.UTF8Encoding(false));
    }

    static string Get(Dictionary<string, object> d, string k) { return d.ContainsKey(k) && d[k] != null ? Convert.ToString(d[k]) : null; }
    static Regex Glob(string g) { return new Regex("^" + Regex.Escape(g).Replace("\\*", ".*").Replace("\\?", ".") + "$", RegexOptions.IgnoreCase | RegexOptions.Compiled); }
}
