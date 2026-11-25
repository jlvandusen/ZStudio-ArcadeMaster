// AmPanel - speech: "Now playing After Burner II" at game start (LEDBlinky's voice option, done with the Windows voice).
// AmPanel.json "Speech": "off" (default) | "start". Titles come from <manifest>\game-titles.json
// (tools\New-ControllerChoices.py: history.dat names for library games). Spoken asynchronously: never delays a launch.
// C# 5.
using System;
using System.Collections.Generic;
using System.IO;

static class Speech
{
    static System.Speech.Synthesis.SpeechSynthesizer voice;
    static Dictionary<string, string> titles;
    static string titlesFile;

    public static void Init(string manifestDir) { titlesFile = Path.Combine(manifestDir, "game-titles.json"); }

    public static string Title(string item)
    {
        if (titles == null)
        {
            titles = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                if (titlesFile != null && File.Exists(titlesFile))
                    foreach (var kv in new System.Web.Script.Serialization.JavaScriptSerializer { MaxJsonLength = 32 * 1024 * 1024 }.Deserialize<Dictionary<string, object>>(File.ReadAllText(titlesFile)))
                        titles[kv.Key] = Convert.ToString(kv.Value);
            }
            catch { }
        }
        string t; return item != null && titles.TryGetValue(item, out t) ? t : item;
    }

    public static void Say(string text)
    {
        try
        {
            if (voice == null) { voice = new System.Speech.Synthesis.SpeechSynthesizer(); voice.SetOutputToDefaultAudioDevice(); voice.Rate = 0; }
            voice.SpeakAsyncCancelAll();
            voice.SpeakAsync(text);
        }
        catch { }
    }
}
