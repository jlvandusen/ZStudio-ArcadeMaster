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
    "fbneo": ["fbneo"], "dreamcast": ["flycast"], "naomi": ["flycast"], "atomiswave": ["flycast"],
    "atari5200": ["a5200", "atari800"], "atari800": ["atari800"], "neogeocd": ["neocd"],
}
# steps 2-3: standalone emulators. system -> [(emulator in discovery.json, exe file name, arguments)], first one found
# wins (the one inside the RetroBat this frontend uses first). {rom} = the game file, {name} = its name without the
# extension, {w} {h} = the main screen's size. Each emulator's own command-line options for a full-screen batch start.
STANDALONE = {
    "model2": [("m2emulator", "emulator_multicpu.exe", '"{name}"'), ("m2emulator", "EMULATOR.EXE", '"{name}"')],
    "model3": [("supermodel", "supermodel.exe", '-res={w},{h} -fullscreen -wide-screen "{rom}"')],
    "gamecube": [("dolphin", "Dolphin.exe", '-b -C Dolphin.Display.Fullscreen=True -e "{rom}"')],
    "wii": [("dolphin", "Dolphin.exe", '-b -C Dolphin.Display.Fullscreen=True -e "{rom}"')],
    "ps2": [("pcsx2", "pcsx2-qt.exe", '-batch -fullscreen -nogui "{rom}"'), ("pcsx2", "pcsx2-qtx64.exe", '-batch -fullscreen -nogui "{rom}"')],
    "psp": [("ppsspp", "PPSSPPWindows64.exe", '--fullscreen "{rom}"')],
    "wiiu": [("cemu", "Cemu.exe", '-f -g "{rom}"')],
    "switch": [("yuzu", "yuzu.exe", '-f -g "{rom}"'), ("yuzu", "suyu.exe", '-f -g "{rom}"'), ("ryujinx", "Ryujinx.exe", '--fullscreen "{rom}"')],
    "xbox": [("xemu", "xemu.exe", '-full-screen -dvd_path "{rom}"')],
    "xbox360": [("xenia", "xenia_canary.exe", '--fullscreen "{rom}"'), ("xenia", "xenia.exe", '--fullscreen "{rom}"')],
    "dreamcast": [("flycast", "flycast.exe", '-config window:fullscreen=yes "{rom}"')],
    "naomi": [("flycast", "flycast.exe", '-config window:fullscreen=yes "{rom}"')],
    "atomiswave": [("flycast", "flycast.exe", '-config window:fullscreen=yes "{rom}"')],
    "jaguarcd": [("bigpemu", "BigPEmu.exe", '"{rom}"')],
    "3ds": [("citra", "azahar.exe", '-f "{rom}"'), ("citra", "citra-qt.exe", '-f "{rom}"'), ("citra", "lime3ds-gui.exe", '-f "{rom}"')],
}


def screen_size():
    import ctypes
    try:
        ctypes.windll.user32.SetProcessDPIAware()
        return ctypes.windll.user32.GetSystemMetrics(0), ctypes.windll.user32.GetSystemMetrics(1)
    except Exception:
        return 1920, 1080


# RetroBat's "bottom row" panel layout: retropad button -> panel button (1-8, START, COIN); shared with the controls
# cards and the button lights
from system_buttons import PAD

# bezels (James 2026-11-27: "Snes needs bezels"): RetroBat's decoration sets, a png per system and a .info that says
# where the game's picture goes. Not for arcade lists (vertical games would sit in a sideways frame).
NO_BEZEL = {"fbneo", "naomi", "atomiswave", "mame", "neogeo"}
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
             'aspect_ratio_index = "22"', 'video_shader_enable = "false"',
             # pads (Xbox, PS3 / PS4 through ScpToolkit / DS4Windows) set themselves up next to the panel's keys:
             # RetroBat turns this off and writes its own binds at each launch
             'input_autodetect_enable = "true"', 'input_joypad_driver = "xinput"']
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


def read_info(path):
    """A decoration's .info: JSON, or the name of another .info to use (RetroBat: "default_4_3.info", "../x.info")."""
    for _ in range(4):
        if not os.path.exists(path):
            return None
        t = open(path, encoding="utf-8-sig", errors="replace").read().strip()
        if t.startswith("{"):
            try:
                return json.loads(t)
            except ValueError:
                return None
        path = os.path.normpath(os.path.join(os.path.dirname(path), t))
    return None


def bezel_cfg(manifest, deco, sysname, screen):
    """<manifest>\\emulators\\bezels\\<system>.cfg (the overlay) and retroarch-am-<system>.cfg (appended after
    retroarch-am.cfg: overlay on, the picture in the bezel's window). None when the set has no bezel for it."""
    if not deco or sysname in NO_BEZEL:
        return None
    png = os.path.join(deco, sysname + ".png")
    info = read_info(os.path.join(deco, sysname + ".info")) or read_info(os.path.join(deco, "default_4_3.info"))
    if not os.path.exists(png) or not info:
        return None
    try:
        iw, ih = float(info["width"]), float(info["height"])
        l, r, t, b = (float(info.get(k, 0)) for k in ("left", "right", "top", "bottom"))
    except (KeyError, ValueError, TypeError):
        return None
    sw, sh = screen
    x, y = round(l * sw / iw), round(t * sh / ih)
    w, h = round(sw - (l + r) * sw / iw), round(sh - (t + b) * sh / ih)
    bdir = os.path.join(manifest, "emulators", "bezels")
    os.makedirs(bdir, exist_ok=True)
    ov = os.path.join(bdir, sysname + ".cfg")
    open(ov, "w", encoding="utf-8").write(
        "overlays = 1\n" 'overlay0_overlay = "%s"\n' "overlay0_full_screen = true\n" "overlay0_normalized = true\n"
        "overlay0_descs = 0\n" % png)
    lines = ['# ArcadeMaster: the %s bezel (tools/New-DirectLaunchers.py) - do not edit' % sysname,
             'input_overlay_enable = "true"', 'input_overlay = "%s"' % ov, 'input_overlay_opacity = "1.000000"',
             'input_overlay_scale = "1.000000"', 'input_overlay_scale_landscape = "1.000000"',
             'input_overlay_auto_scale = "false"', 'input_overlay_enable_autopreferred = "false"',
             'input_overlay_show_mouse_cursor = "false"', 'input_overlay_hide_in_menu = "true"',
             'video_aspect_ratio_auto = "false"', 'aspect_ratio_index = "23"', 'video_scale_integer = "false"',
             'custom_viewport_x = "%d"' % x, 'custom_viewport_y = "%d"' % y,
             'custom_viewport_width = "%d"' % w, 'custom_viewport_height = "%d"' % h]
    p = os.path.join(manifest, "emulators", "retroarch-am-%s.cfg" % sysname)
    open(p, "w", encoding="utf-8").write("\n".join(lines) + "\n")
    return p


# Cemu (Wii U GamePad) button ids, from Cemu's VPADController
CEMU_IDS = {"a": 1, "b": 2, "x": 3, "y": 4, "l": 5, "r": 6, "l2": 7, "r2": 8, "start": 9, "select": 10}
CEMU_DIRS = {"up": (11, 17), "down": (12, 18), "left": (13, 19), "right": (14, 20)}   # d-pad and left stick
CEMU_RSTICK = {"up": 21, "down": 22, "left": 23, "right": 24}
# panel.json key names -> Windows virtual-key codes (Cemu stores those; it tells left and right Ctrl / Alt / Shift apart)
VK = {"LCONTROL": 162, "RCONTROL": 163, "LALT": 164, "RALT": 165, "LSHIFT": 160, "RSHIFT": 161, "SPACE": 32,
      "ENTER": 13, "TAB": 9, "BACKSLASH": 220, "SLASH": 191, "UP": 38, "DOWN": 40, "LEFT": 37, "RIGHT": 39}


def vk(k):
    k = (k or "").upper()
    if k in VK:
        return VK[k]
    if len(k) == 1 and k.isalnum():
        return ord(k)
    if re.match(r"^F([1-9]|1[0-2])$", k):
        return 111 + int(k[1:])
    return None


def cemu_profile(exe, panel):
    """Cemu's player 1 controller (controllerProfiles\\controller0.xml) from the panel: RetroBat left its own keyboard
    default there (X, Z, Q, S, Page Up ...), so only two panel buttons did anything in a Wii U game. The layout is
    the controls card's (system_buttons.NATIVE["wiiu"]). The old file is kept once as controller0.xml.am-bak."""
    base = os.path.dirname(exe)
    d = os.path.join(base, "portable") if os.path.isdir(os.path.join(base, "portable")) else os.path.join(os.environ.get("APPDATA", ""), "Cemu")
    d = os.path.join(d, "controllerProfiles")
    p1 = next((p for p in (panel.get("players") or []) if p.get("position") == "P1"), None)
    if not p1:
        return None
    keys = p1.get("keys") or {}
    maps = []
    for pad, mid in CEMU_IDS.items():
        code = vk(keys.get("P1" + PAD[pad]))
        if code:
            maps.append((mid, code))
    for dname, ids in CEMU_DIRS.items():
        for mid in ids:
            maps.append((mid, vk(DIRS[1][dname])))
    for dname, mid in CEMU_RSTICK.items():
        maps.append((mid, vk(DIRS[2][dname])))       # player 2's stick turns the camera
    def block(api, uuid, name, pairs):
        entries = "".join("\t\t\t<entry>\n\t\t\t\t<mapping>%d</mapping>\n\t\t\t\t<button>%d</button>\n\t\t\t</entry>\n" % m
                          for m in sorted(pairs))
        return ("\t<controller>\n\t\t<api>%s</api>\n\t\t<uuid>%s</uuid>\n\t\t<display_name>%s</display_name>\n"
                "\t\t<axis>\n\t\t\t<deadzone>0.25</deadzone>\n\t\t\t<range>1</range>\n\t\t</axis>\n"
                "\t\t<rotation>\n\t\t\t<deadzone>0.25</deadzone>\n\t\t\t<range>1</range>\n\t\t</rotation>\n"
                "\t\t<trigger>\n\t\t\t<deadzone>0.25</deadzone>\n\t\t\t<range>1</range>\n\t\t</trigger>\n"
                "\t\t<mappings>\n%s\t\t</mappings>\n\t</controller>\n") % (api, uuid, name, entries)
    # the first XInput pad (an Xbox pad, or a PS3 / PS4 pad through ScpToolkit / DS4Windows) next to the panel, in
    # Cemu's own default layout (VPADController::set_default_mapping, Nintendo positions: A = the right face button)
    xi = [(1, 13), (2, 12), (3, 15), (4, 14), (5, 8), (6, 9), (7, 42), (8, 43), (9, 4), (10, 5), (11, 0), (12, 1),
          (13, 2), (14, 3), (15, 6), (16, 7), (17, 39), (18, 45), (19, 44), (20, 38), (21, 41), (22, 47), (23, 46), (24, 40)]
    xml = ('<?xml version="1.0" encoding="utf-8"?>\n<!-- ArcadeMaster: the panel + the first pad (tools/New-DirectLaunchers.py) -->\n'
           "<emulated_controller>\n\t<type>Wii U GamePad</type>\n" + block("Keyboard", "keyboard", "Keyboard", maps)
           + block("XInput", "0", "Controller 1", xi) + "</emulated_controller>\n")
    os.makedirs(d, exist_ok=True)
    f = os.path.join(d, "controller0.xml")
    if os.path.exists(f) and not os.path.exists(f + ".am-bak") and "ArcadeMaster" not in open(f, encoding="utf-8", errors="replace").read():
        import shutil
        shutil.copy2(f, f + ".am-bak")
    open(f, "w", encoding="utf-8").write(xml)
    return f


# PCSX2 pad 1 = the panel's keys (RetroBat wrote them) + the first XInput pad (James 2026-11-27: "properly map to use
# with Xbox and 360 and Sony games"). PCSX2 keeps every binding of a button as its own line.
PCSX2_XINPUT = {"Up": "DPadUp", "Right": "DPadRight", "Down": "DPadDown", "Left": "DPadLeft", "Triangle": "Y",
                "Circle": "B", "Cross": "A", "Square": "X", "Select": "Back", "Start": "Start", "L1": "LeftShoulder",
                "R1": "RightShoulder", "L2": "+LeftTrigger", "R2": "+RightTrigger", "L3": "LeftStick", "R3": "RightStick",
                "Analog": "Guide", "LUp": "-LeftY", "LRight": "+LeftX", "LDown": "+LeftY", "LLeft": "-LeftX",
                "RUp": "-RightY", "RRight": "+RightX", "RDown": "+RightY", "RLeft": "-RightX",
                "LargeMotor": "LargeMotor", "SmallMotor": "SmallMotor"}


def pcsx2_pad(exe):
    ini = os.path.join(os.path.dirname(exe), "inis", "PCSX2.ini")
    if not os.path.exists(ini):
        return None
    lines = open(ini, encoding="utf-8-sig").read().splitlines()
    if not os.path.exists(ini + ".am-bak"):
        import shutil
        shutil.copy2(ini, ini + ".am-bak")
    out, sec = [], None
    for l in lines:
        s = l.strip()
        if s.startswith("["):
            if sec == "Pad1":
                out += ["%s = XInput-0/%s" % kv for kv in PCSX2_XINPUT.items()]
            sec = s[1:-1]
        if sec == "Pad1" and "XInput-0/" in l:
            continue                      # ours, written again below
        if sec == "InputSources" and re.match(r"^\s*XInput\s*=", l):
            l = "XInput = true"
        out.append(l)
    if sec == "Pad1":
        out += ["%s = XInput-0/%s" % kv for kv in PCSX2_XINPUT.items()]
    open(ini, "w", encoding="utf-8").write("\n".join(out) + "\n")
    return ini


def xemu_pad(exe):
    """Xbox: the pad is player 1 (xemu binds the first pad it sees to an empty port), the panel's keys player 2."""
    toml = os.path.join(os.path.dirname(exe), "xemu.toml")
    if not os.path.exists(toml):
        return None
    t = open(toml, encoding="utf-8").read()
    if not os.path.exists(toml + ".am-bak"):
        open(toml + ".am-bak", "w", encoding="utf-8").write(t)
    t = re.sub(r"(?ms)^\[input\.bindings\]\n.*?(?=^\[|\Z)", "[input.bindings]\nport2 = 'keyboard'\n\n", t)
    open(toml, "w", encoding="utf-8").write(t)
    return toml


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
    ap.add_argument("--bezels", default="default_unglazed", help="RetroBat decoration set, or none")
    a = ap.parse_args()
    a.manifest = os.path.normpath(a.manifest)
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
    # ArcadeMaster's own emulators folder first (tools/Move-OffRetroBat.py links / moves them there), then the
    # RetroBat this frontend came from
    own = os.path.join(os.path.dirname(a.manifest), "emulators").lower() + "\\"

    def pref(exe):
        x = exe.lower()
        return 0 if x.startswith(own) else 1 if home and x.startswith(home + "\\") else 2
    # the RetroArch of the RetroBat this frontend already uses (its BIOS folder and settings), else the one with most cores
    home = None
    for f in sorted(os.listdir(launchers)) if os.path.isdir(launchers) else []:
        if f.startswith("AM_RB_"):
            m = re.search(r"^executable\s*=\s*(.+?)\\emulationstation\\emulatorLauncher\.exe", open(os.path.join(launchers, f), encoding="latin-1").read(), re.M | re.I)
            if m:
                home = m.group(1).strip().lower()
                break
    ra.sort(key=lambda e: (pref(e["exe"]), -len(e["cores"])))
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
    # the bezel set: RetroBat's decorations next to the RetroArch in use (system\decorations\<set>\systems)
    deco = None
    if a.bezels != "none":
        # ArcadeMaster's own decorations folder first (tools/Move-OffRetroBat.py), then RetroBat's
        for d in [os.path.join(os.path.dirname(a.manifest), "decorations", a.bezels, "systems")] + [
                os.path.join(root, "system", "decorations", a.bezels, "systems")
                for root in ([home] if home else []) + [os.path.dirname(os.path.dirname(radir))]]:
            if os.path.isdir(d):
                deco = d
                break
    screen = screen_size()
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
        name = "AM_DL_" + m.group(1)
        if sysname == "ports":
            # each port is its own RetroArch core (<item>.libretro -> cores\<item>_libretro.dll), started with no game
            # file - except a port whose core reads data from a folder of the same name (XRick: xrick\data.zip).
            # RetroFE picks the launcher per item from collections\Ports\launchers\<item>.conf.
            lp = re.search(r"^\s*list\.path\s*=\s*(.+?)\s*$", t, re.M)
            pdir = lp.group(1) if lp else ""
            items = sorted(f[:-len(".libretro")] for f in (os.listdir(pdir) if os.path.isdir(pdir) else []) if f.endswith(".libretro"))
            made = []
            for it in items:
                dll = os.path.join(radir, "cores", it + "_libretro.dll")
                if not os.path.exists(dll):
                    continue
                data = next((os.path.join(pdir, it, d) for d in ("data.zip", "data") if os.path.exists(os.path.join(pdir, it, d))), None)
                pconf = ["executable = %s" % ra["exe"],
                         'arguments = --appendconfig "%s" -L "%s"%s' % (cfg, dll, ' "%s"' % data if data else ""),
                         "currentDirectory = %s" % radir] + hooks(os.path.join(launchers, "AM_RB_%s.conf" % m.group(1)))
                if not a.dry_run:
                    open(os.path.join(launchers, "%s_%s.conf" % (name, it)), "w", encoding="latin-1").write("\n".join(pconf) + "\n")
                    os.makedirs(os.path.join(cols, c, "launchers"), exist_ok=True)
                    open(os.path.join(cols, c, "launchers", it + ".conf"), "w", encoding="latin-1").write("%s_%s\n" % (name, it))
                made.append(it)
            if not made:
                skipped.append(sysname)
                continue
            if not a.dry_run:
                # the list's own launcher: the first port (an item without its own file still starts something real)
                first = open(os.path.join(launchers, "%s_%s.conf" % (name, made[0])), encoding="latin-1").read()
                open(os.path.join(launchers, name + ".conf"), "w", encoding="latin-1").write(first)
                t = re.sub(r"^\s*launcher\s*=.*$", "launcher = %s" % name, t, flags=re.M)
                t = re.sub(r"^# was AM_RB_\S+ \(direct launcher\)\r?\n", "", t, flags=re.M)
                open(sc, "w", encoding="latin-1").write("# was AM_RB_%s (direct launcher)\n" % m.group(1) + t)
            done.append("%s=%d ports (%s)" % (c, len(made), ", ".join(made)))
            continue
        core = next((x for x in CORES.get(sysname, []) if x in ra["cores"]), None)
        if core:
            bz = bezel_cfg(a.manifest, deco, sysname, screen) if not a.dry_run else None
            append = cfg + ("|" + bz if bz else "")
            conf = ["executable = %s" % ra["exe"],
                    'arguments = --appendconfig "%s" -L "%s" "%%ITEM_FILEPATH%%"' % (append, os.path.join(radir, "cores", core + "_libretro.dll")),
                    "currentDirectory = %s" % radir]
            how = core + (" +bezel" if bz else "")
        else:
            # a standalone emulator (steps 2-3)
            pick = None
            for emu, exe_name, args in STANDALONE.get(sysname, []):
                cands = [e for e in disc.get("emulators", []) if e["emulator"] == emu and os.path.basename(e["exe"]).lower() == exe_name.lower()]
                cands.sort(key=lambda e: pref(e["exe"]))
                if cands:
                    pick = (cands[0]["exe"], args)
                    break
            if not pick:
                skipped.append(sysname)
                continue
            w, h = screen
            if sysname == "wiiu" and not a.dry_run:
                cemu_profile(pick[0], panel)          # the panel's keys, as the controls card shows them, + the pad
            if sysname == "ps2" and not a.dry_run:
                pcsx2_pad(pick[0])
            if sysname == "xbox" and not a.dry_run:
                xemu_pad(pick[0])
            args = pick[1].replace("{rom}", "%ITEM_FILEPATH%").replace("{name}", "%ITEM_NAME%").replace("{w}", str(w)).replace("{h}", str(h))
            conf = ["executable = %s" % pick[0], "arguments = %s" % args, "currentDirectory = %s" % os.path.dirname(pick[0])]
            how = os.path.basename(pick[0])
        conf += hooks(os.path.join(launchers, "AM_RB_%s.conf" % m.group(1)))
        if not a.dry_run:
            open(os.path.join(launchers, name + ".conf"), "w", encoding="latin-1").write("\n".join(conf) + "\n")
            t = re.sub(r"^\s*launcher\s*=.*$", "launcher = %s" % name, t, flags=re.M)
            t = re.sub(r"^# was AM_RB_\S+ \(direct launcher\)\r?\n", "", t, flags=re.M)
            t = "# was AM_RB_%s (direct launcher)\n" % m.group(1) + t
            open(sc, "w", encoding="latin-1").write(t)
        done.append("%s=%s" % (c, how))
    print("direct launchers (RetroArch %s): %d collections%s" % (ra.get("version", ""), len(done), " (dry run)" if a.dry_run else ""))
    for d in done:
        print("  " + d)
    if skipped:
        print("  left on RetroBat (no RetroArch core for it yet): " + ", ".join(sorted(set(skipped))))


if __name__ == "__main__":
    main()
