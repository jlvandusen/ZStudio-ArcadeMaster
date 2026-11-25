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
        int order = 0;
        foreach (var f in files)
        {
            if (f == null || !File.Exists(f)) continue;
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
                        Specificity = (game != "*" ? 2 : sys != null ? 1 : 0) * 10000 - order++, Source = Path.GetFileName(f) });
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

    static string Get(Dictionary<string, object> d, string k) { return d.ContainsKey(k) && d[k] != null ? Convert.ToString(d[k]) : null; }
    static Regex Glob(string g) { return new Regex("^" + Regex.Escape(g).Replace("\\*", ".*").Replace("\\?", ".") + "$", RegexOptions.IgnoreCase | RegexOptions.Compiled); }
}
