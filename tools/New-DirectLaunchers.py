r"""Direct launchers: the frontend starts the emulator itself, not through RetroBat's emulatorLauncher.

James 2026-11-27: "not require retrobat and use their default emulators, retrobat is just a frontend not the emulator".
For every collection that uses a RetroBat launcher (launcher = AM_RB_<system>) and a system this tool knows, it writes
launchers.windows\AM_DL_<system>.conf that runs the emulator directly, keeps the ArcadeMaster game hooks (pre/post
lines) of the RetroBat launcher, and points the collection at it. The collection's settings.conf remembers the old
launcher ("# was AM_RB_<system>"), and --revert puts every one back.

Step 1 (this file today): RetroArch + its cores. Our settings go in <manifest>\emulators\retroarch-am.cfg, appended with
--appendconfig (RetroBat's retroarch.cfg is not touched): borderless full screen, the panel's keys from
<manifest>\panel.json for players 1-4 in RetroBat's "bottom row" layout, and RetroArch's hotkeys locked behind F12 (its
defaults sit on panel keys: F5-F7 are player 3's buttons, R / F player 2's stick, Space player 1's B3, H player 4's B3).
Leaving a game stays with AmPanel's exit guard (hold Esc).
  python tools/New-DirectLaunchers.py --retrofe R:/ArcadeMaster/frontend/LEGENDS-am --manifest R:/ArcadeMaster/manifest
         [--systems snes,nes] [--dry-run] [--revert]
"""
import argparse
import json
import os
import re

# system -> RetroArch cores in order of preference (the first one installed is used)
CORES = {
    "nes": ["mesen", "nestopia", "fceumm"], "snes": ["snes9x", "bsnes"], "gb": ["gambatte", "sameboy", "mgba"],
    "gbc": ["gambatte", "sameboy", "mgba"], "gba": ["mgba"], "megadrive": ["genesis_plus_gx", "picodrive"],
    "mastersystem": ["genesis_plus_gx", "picodrive"], "gamegear": ["genesis_plus_gx"], "sg-1000": ["genesis_plus_gx"],
    "sega32x": ["picodrive"], "segacd": ["genesis_plus_gx", "picodrive"], "pcengine": ["mednafen_pce_fast", "mednafen_pce"],
    "pcenginecd": ["mednafen_pce_fast", "mednafen_pce"], "supergrafx": ["mednafen_pce"], "atari2600": ["stella"],
    "atari7800": ["prosystem"], "atarilynx": ["handy"], "jaguar": ["virtualjaguar"], "ngp": ["mednafen_ngp"],
    "ngpc": ["mednafen_ngp"], "psx": ["swanstation", "mednafen_psx_hw", "pcsx_rearmed"], "n64": ["mupen64plus_next", "parallel_n64"],
    "nds": ["melonds", "desmume"], "wswan": ["mednafen_wswan"], "wswanc": ["mednafen_wswan"], "c64": ["vice_x64sc", "vice_x64"],
    "amiga500": ["puae"], "amiga1200": ["puae"], "amigacd32": ["puae"], "msx1": ["bluemsx"], "msx2": ["bluemsx"],
    "zxspectrum": ["fuse"], "amstradcpc": ["cap32"], "colecovision": ["gearcoleco", "bluemsx"], "intellivision": ["freeintv"],
    "vectrex": ["vecx"], "3do": ["opera"], "virtualboy": ["mednafen_vb"], "saturn": ["mednafen_saturn", "kronos", "yabasanshiro"],
    # RetroBat's own names for the same systems
    "lynx": ["handy"], "sg1000": ["genesis_plus_gx"], "neogeo": ["fbneo"], "amiga": ["puae"], "msx": ["bluemsx"],
}
# RetroBat's "bottom row" panel layout: retropad button -> panel button (1-8, START, COIN)
PAD = {"b": "B1", "a": "B2", "r": "B3", "r2": "B4", "y": "B5", "x": "B6", "l": "B7", "l2": "B8", "start": "START", "select": "COIN"}
# panel.json key names -> RetroArch key names
KEYNAME = {"LCONTROL": "ctrl", "RCONTROL": "rctrl", "LALT": "alt", "RALT": "ralt", "LSHIFT": "shift", "RSHIFT": "rshift",
           "SPACE": "space", "BACKSLASH": "backslash", "SLASH": "slash", "ENTER": "enter", "TAB": "tab"}
# the I-PAC's stick keys (panel.json lists buttons only); players 3 / 4 use their own sticks (joysticks)
DIRS = {1: {"up": "up", "down": "down", "left": "left", "right": "right"}, 2: {"up": "r", "down": "f", "left": "d", "right": "g"}}
# every RetroArch hotkey that is a single key by default: behind F12 (input_enable_hotkey) so panel keys never fire them
HOTKEYS = ["input_exit_emulator", "input_save_state", "input_load_state", "input_state_slot_increase", "input_state_slot_decrease",
           "input_toggle_fullscreen", "input_pause_toggle", "input_frame_advance", "input_rewind", "input_hold_fast_forward",
           "input_toggle_fast_forward", "input_hold_slowmotion", "input_toggle_slowmotion", "input_screenshot", "input_shader_next",
           "input_shader_prev", "input_audio_mute", "input_movie_record", "input_reset", "input_volume_up", "input_volume_down",
           "input_disk_eject_toggle", "input_disk_next", "input_disk_prev", "input_cheat_toggle", "input_cheat_index_plus",
           "input_cheat_index_minus", "input_fps_toggle", "input_netplay_game_watch", "input_grab_mouse_toggle",
           "input_game_focus_toggle", "input_osk_toggle", "input_recording_toggle", "input_streaming_toggle", "input_ai_service"]


def keyname(k):
    k = (k or "").upper()
    if k in KEYNAME:
        return KEYNAME[k]
    if len(k) == 1 and k.isdigit():
        return "num" + k
    return k.lower()


def retroarch_cfg(manifest, panel):
    lines = ['# ArcadeMaster (tools/New-DirectLaunchers.py): appended to RetroArch with --appendconfig - do not edit',
             'video_fullscreen = "true"', 'video_windowed_fullscreen = "true"', 'pause_nonactive = "false"',
             'config_save_on_exit = "false"', 'menu_show_quit_retroarch = "true"', 'input_enable_hotkey = "f12"',
             # RetroBat writes its last system's bezel and aspect into retroarch.cfg (an Amiga bezel showed round a SNES
             # game): no overlay, the core's own aspect
             'input_overlay_enable = "false"', 'input_overlay = ""', 'video_aspect_ratio_auto = "true"',
             'aspect_ratio_index = "22"', 'video_shader_enable = "false"']
    lines += ['%s = "nul"' % h for h in HOTKEYS if h != "input_exit_emulator"]
    lines.append('input_exit_emulator = "escape"')   # with F12 held; AmPanel's hold-Esc exit is the everyday way out
    for p in (panel.get("players") or []):
        n = int(re.sub(r"\D", "", p.get("position", "P1")) or 1)
        keys = p.get("keys") or {}
        for pad, btn in PAD.items():
            k = keys.get("P%d%s" % (n, btn))
            if k:
                lines.append('input_player%d_%s = "%s"' % (n, pad, keyname(k)))
        for d, k in DIRS.get(n, {}).items():
            lines.append('input_player%d_%s = "%s"' % (n, d, k))
    p = os.path.join(manifest, "emulators", "retroarch-am.cfg")
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w", encoding="utf-8").write("\n".join(lines) + "\n")
    return p


def hooks(old_conf):
    if not os.path.exists(old_conf):
        return []
    return [l.rstrip("\n") for l in open(old_conf, encoding="latin-1") if re.match(r"^\s*(#|pre|post)", l)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--retrofe", required=True)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--systems", default="")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--revert", action="store_true")
    a = ap.parse_args()
    only = {s.strip().lower() for s in a.systems.split(",") if s.strip()}
    cols = os.path.join(a.retrofe, "collections")
    launchers = os.path.join(a.retrofe, "launchers.windows")

    if a.revert:
        n = 0
        for c in os.listdir(cols):
            sc = os.path.join(cols, c, "settings.conf")
            if not os.path.exists(sc):
                continue
            t = open(sc, encoding="latin-1").read()
            m = re.search(r"^# was (AM_RB_\S+) \(direct launcher\)$", t, re.M)
            if m and (not only or m.group(1)[6:].lower() in only):
                t = re.sub(r"^launcher\s*=.*$", "launcher = " + m.group(1), t, flags=re.M)
                t = re.sub(r"^# was AM_RB_\S+ \(direct launcher\)\r?\n", "", t, flags=re.M)
                open(sc, "w", encoding="latin-1").write(t)
                n += 1
        print("direct launchers: %d collections back on RetroBat's launcher" % n)
        return

    disc = {}
    try:
        disc = json.load(open(os.path.join(a.manifest, "discovery.json"), encoding="utf-8"))
    except Exception:
        pass
    ra = [e for e in disc.get("emulators", []) if e["emulator"] == "retroarch" and e.get("cores")]
    # the RetroArch of the RetroBat this frontend already uses (its BIOS folder and settings), else the one with most cores
    home = None
    for f in sorted(os.listdir(launchers)) if os.path.isdir(launchers) else []:
        if f.startswith("AM_RB_"):
            m = re.search(r"^executable\s*=\s*(.+?)\\emulationstation\\emulatorLauncher\.exe", open(os.path.join(launchers, f), encoding="latin-1").read(), re.M | re.I)
            if m:
                home = m.group(1).strip().lower()
                break
    ra.sort(key=lambda e: (0 if home and e["exe"].lower().startswith(home + "\\") else 1, -len(e["cores"])))
    if not ra:
        print("direct launchers: no RetroArch with cores found (run tools/Find-Emulators.py first)")
        return
    ra = ra[0]
    panel = {}
    try:
        panel = json.load(open(os.path.join(a.manifest, "panel.json"), encoding="utf-8"))
    except Exception:
        pass
    cfg = retroarch_cfg(a.manifest, panel) if not a.dry_run else os.path.join(a.manifest, "emulators", "retroarch-am.cfg")
    radir = os.path.dirname(ra["exe"])
    done, skipped = [], []
    for c in sorted(os.listdir(cols)):
        sc = os.path.join(cols, c, "settings.conf")
        if not os.path.exists(sc):
            continue
        t = open(sc, encoding="latin-1").read()
        m = re.search(r"^\s*launcher\s*=\s*AM_RB_(\S+)\s*$", t, re.M) or re.search(r"^# was AM_RB_(\S+) \(direct launcher\)$", t, re.M)
        if not m:
            continue
        sysname = m.group(1).lower()
        if only and sysname not in only:
            continue
        core = next((x for x in CORES.get(sysname, []) if x in ra["cores"]), None)
        if not core:
            skipped.append(sysname)
            continue
        name = "AM_DL_" + m.group(1)
        conf = ["executable = %s" % ra["exe"],
                'arguments = --appendconfig "%s" -L "%s" "%%ITEM_FILEPATH%%"' % (cfg, os.path.join(radir, "cores", core + "_libretro.dll")),
                "currentDirectory = %s" % radir]
        conf += hooks(os.path.join(launchers, "AM_RB_%s.conf" % m.group(1)))
        if not a.dry_run:
            open(os.path.join(launchers, name + ".conf"), "w", encoding="latin-1").write("\n".join(conf) + "\n")
            t = re.sub(r"^\s*launcher\s*=.*$", "launcher = %s" % name, t, flags=re.M)
            t = re.sub(r"^# was AM_RB_\S+ \(direct launcher\)\r?\n", "", t, flags=re.M)
            t = "# was AM_RB_%s (direct launcher)\n" % m.group(1) + t
            open(sc, "w", encoding="latin-1").write(t)
        done.append("%s=%s" % (c, core))
    print("direct launchers (RetroArch %s): %d collections%s" % (ra.get("version", ""), len(done), " (dry run)" if a.dry_run else ""))
    for d in done:
        print("  " + d)
    if skipped:
        print("  left on RetroBat (no RetroArch core for it yet): " + ", ".join(sorted(set(skipped))))


if __name__ == "__main__":
    main()
