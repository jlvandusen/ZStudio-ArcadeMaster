r"""The panel's keys in every standalone emulator, laid out like the controls card (James 2026-11-27, Wii U: "x and y are
not mapped" - and every standalone emulator still had RetroBat's own keyboard layout: Q, S, Page Up, Home ..., keys the
panel never sends). Player 1's buttons and stick from <manifest>\panel.json, in the button layout of
tools/system_buttons.py (the same table the controls cards and the button lights use); player 2's stick is the right
stick / C-stick (camera). Each file is kept once as <file>.am-bak before the first change.

  PS2       PCSX2      inis\PCSX2.ini              [Pad1]  (the pad's XInput-0 lines from New-DirectLaunchers stay)
  Xbox      xemu       xemu.toml                   [input.keyboard_controller_scancode_map]
  Xbox 360  Xenia      xenia-canary.config.toml    keybind_*
  GameCube  Dolphin    User\Config\GCPadNew.ini    [GCPad1]
  PSP       PPSSPP     memstick\PSP\SYSTEM\controls.ini [ControlMapping] (made when missing)
  3DS       Citra      user\config\qt-config.ini   profiles\1\*
  Switch    Yuzu       user\config\qt-config.ini   player_0_*

  python tools/Set-EmulatorPanelKeys.py --manifest R:\ArcadeMaster\manifest --emulators R:\ArcadeMaster\emulators [--dry-run]
"""
import argparse
import json
import os
import re
import shutil

from system_buttons import PAD

DIRS1 = {"up": "UP", "down": "DOWN", "left": "LEFT", "right": "RIGHT"}     # player 1's stick: the arrow keys
DIRS2 = {"up": "R", "down": "F", "left": "D", "right": "G"}                # player 2's stick (I-PAC defaults)

# ---- key names per emulator, from panel.json's names
SDL = {"LCONTROL": 224, "LSHIFT": 225, "LALT": 226, "SPACE": 44, "UP": 82, "DOWN": 81, "LEFT": 80, "RIGHT": 79}
VK = {"LCONTROL": "0xA2", "LALT": "0xA4", "LSHIFT": "0xA0", "SPACE": "0x20", "UP": "0x26", "DOWN": "0x28", "LEFT": "0x25", "RIGHT": "0x27"}
PCSX2 = {"LCONTROL": "Control", "LALT": "Alt", "LSHIFT": "Shift", "SPACE": "Space", "UP": "Up", "DOWN": "Down", "LEFT": "Left", "RIGHT": "Right"}
DINPUT = {"LCONTROL": "LCONTROL", "LALT": "LMENU", "LSHIFT": "LSHIFT", "SPACE": "SPACE", "UP": "UP", "DOWN": "DOWN", "LEFT": "LEFT", "RIGHT": "RIGHT"}
QT = {"LCONTROL": 16777249, "LALT": 16777251, "LSHIFT": 16777248, "SPACE": 32, "UP": 16777235, "DOWN": 16777237, "LEFT": 16777234, "RIGHT": 16777236}
QT_F12 = 16777275                       # the stick "half speed" modifier: a key the panel never sends
NK = {"LCONTROL": 113, "LALT": 57, "LSHIFT": 59, "SPACE": 62, "UP": 19, "DOWN": 20, "LEFT": 21, "RIGHT": 22, "ESCAPE": 111}


def sdl(k):
    k = k.upper()
    if k in SDL: return SDL[k]
    if len(k) == 1 and k.isalpha(): return ord(k) - ord("A") + 4
    if len(k) == 1 and k.isdigit(): return 39 if k == "0" else 29 + int(k)
    return None


def vk(k):
    k = k.upper()
    return VK.get(k, k if len(k) == 1 and k.isalnum() else None)


def pcsx2(k):
    k = k.upper()
    return "Keyboard/" + PCSX2.get(k, k)


def dinput(k):
    return DINPUT.get(k.upper(), k.upper())


def qt(k):
    k = k.upper()
    return QT.get(k, ord(k) if len(k) == 1 else None)


def nk(k):
    k = k.upper()
    if k in NK: return NK[k]
    if len(k) == 1 and k.isalpha(): return ord(k) - ord("A") + 29
    if len(k) == 1 and k.isdigit(): return 7 + int(k)
    return None


SUPERMODEL = {"LCONTROL": "KEY_LEFTCTRL", "RCONTROL": "KEY_RIGHTCTRL", "LALT": "KEY_LEFTALT", "RALT": "KEY_RIGHTALT",
              "LSHIFT": "KEY_LEFTSHIFT", "RSHIFT": "KEY_RIGHTSHIFT", "SPACE": "KEY_SPACE", "ENTER": "KEY_RETURN",
              "UP": "KEY_UP", "DOWN": "KEY_DOWN", "LEFT": "KEY_LEFT", "RIGHT": "KEY_RIGHT", "BACKSLASH": "KEY_BACKSLASH",
              "SLASH": "KEY_SLASH"}


def supermodel_key(k):
    k = k.upper()
    return SUPERMODEL.get(k, "KEY_" + k)


def real_wiimote():
    """a real Wii Remote is paired with this PC (Bluetooth name RVL-CNT-01 / Nintendo RVL-...)"""
    try:
        import subprocess
        o = subprocess.run(["powershell", "-NoProfile", "-Command",
                            "Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'RVL-CNT|Nintendo RVL' } | Select-Object -First 1 -ExpandProperty FriendlyName"],
                           capture_output=True, text=True, timeout=30).stdout
        return bool(o.strip())
    except Exception:
        return False


def backup(p):
    if os.path.exists(p) and not os.path.exists(p + ".am-bak"):
        shutil.copy2(p, p + ".am-bak")


def set_ini(path, section, values, drop=None):
    """Set key = value lines inside [section] (keys matched case-insensitively); drop = a test for lines to remove."""
    lines = open(path, encoding="utf-8-sig", errors="replace").read().splitlines() if os.path.exists(path) else []
    out, sec, done, found = [], None, set(), False
    def flush():
        for k, v in values.items():
            if k.lower() not in done:
                out.append("%s = %s" % (k, v))
    for l in lines:
        s = l.strip()
        if s.startswith("[") and s.endswith("]"):
            if sec == section:
                flush()
            sec = s[1:-1]; found = found or sec == section
            out.append(l); continue
        if sec == section and "=" in l:
            k = l.split("=", 1)[0].strip()
            if drop and drop(k, l):
                continue
            hit = next((x for x in values if x.lower() == k.lower()), None)
            if hit:
                out.append("%s = %s" % (hit, values[hit])); done.add(hit.lower()); continue
        out.append(l)
    if sec == section:
        flush()
    if not found:
        out += ["", "[%s]" % section] + ["%s = %s" % kv for kv in values.items()]
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--emulators", required=True)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    panel = json.load(open(os.path.join(a.manifest, "panel.json"), encoding="utf-8"))
    p1 = next(p for p in panel["players"] if p.get("position") == "P1")
    key = {pad: p1["keys"].get("P1" + btn) for pad, btn in PAD.items()}          # retropad name -> panel key name
    done = []

    def write(path, text):
        if a.dry_run:
            done.append("would write " + path); return
        backup(path)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, "w", encoding="utf-8").write(text)
        done.append(path)

    E = a.emulators
    # ---- PS2: PCSX2 (button layout = system_buttons.NATIVE["ps2"])
    p = os.path.join(E, "pcsx2", "inis", "PCSX2.ini")
    if os.path.exists(p):
        m = {"Cross": "b", "Circle": "a", "Square": "y", "Triangle": "x", "L1": "l", "R1": "r", "L2": "l2", "R2": "r2", "Start": "start", "Select": "select"}
        kb = {n: pcsx2(key[pad]) for n, pad in m.items() if key.get(pad)}
        for d, k in DIRS1.items():
            kb[d.capitalize()] = pcsx2(k); kb["L" + d.capitalize()] = pcsx2(k)
        for d, k in DIRS2.items():
            kb["R" + d.capitalize()] = pcsx2(k)
        # PCSX2 keeps each binding of a button as its own line: our keyboard line + the pad line (XInput-0/...)
        lines = open(p, encoding="utf-8-sig").read().splitlines()
        out, sec = [], None
        for l in lines:
            s = l.strip()
            if s.startswith("["):
                if sec == "Pad1":
                    out += ["%s = %s" % kv for kv in kb.items()]
                sec = s[1:-1]
            elif sec == "Pad1" and "Keyboard/" in l:
                continue
            out.append(l)
        if sec == "Pad1":
            out += ["%s = %s" % kv for kv in kb.items()]
        write(p, "\n".join(out) + "\n")
    # ---- Xbox: xemu (SDL scancodes)
    p = os.path.join(E, "xemu", "xemu.toml")
    if os.path.exists(p):
        m = {"a": "b", "b": "a", "x": "y", "y": "x", "white": "l", "black": "r", "ltrigger": "l2", "rtrigger": "r2", "start": "start", "back": "select"}
        v = {n: sdl(key[pad]) for n, pad in m.items() if key.get(pad)}
        for d, k in DIRS1.items():
            v["dpad_" + d] = sdl(k); v["lstick_" + d] = sdl(k)
        for d, k in DIRS2.items():
            v["rstick_" + d] = sdl(k)
        t = open(p, encoding="utf-8").read()
        body = "".join("%s = %d\n" % kv for kv in v.items() if kv[1] is not None)
        sec = re.search(r"(?ms)^\[input\.keyboard_controller_scancode_map\]\n(.*?)(?=^\[|\Z)", t)
        if sec:
            keep = "".join(l + "\n" for l in sec.group(1).splitlines() if l.strip() and l.split("=")[0].strip() not in v)
            t = t[:sec.start(1)] + body + keep + "\n" + t[sec.end(1):]
        else:
            t += "\n[input.keyboard_controller_scancode_map]\n" + body
        write(p, t)
    # ---- Xbox 360: Xenia (virtual-key codes)
    for name in ("xenia-canary", "xenia"):
        p = os.path.join(E, name, name + ".config.toml")
        if not os.path.exists(p):
            continue
        m = {"a": "b", "b": "a", "x": "y", "y": "x", "left_shoulder": "l", "right_shoulder": "r", "left_trigger": "l2", "right_trigger": "r2", "start": "start", "back": "select"}
        v = {"keybind_" + n: vk(key[pad]) for n, pad in m.items() if key.get(pad)}
        for d, k in DIRS1.items():
            v["keybind_dpad_" + d] = vk(k); v["keybind_left_thumb_" + d] = vk(k)
        for d, k in DIRS2.items():
            v["keybind_right_thumb_" + d] = vk(k)
        v["keybind_left_thumb"] = ""; v["keybind_right_thumb"] = ""          # were F / K: player 2 keys
        t = open(p, encoding="utf-8").read()
        for k2, val in v.items():
            t, n = re.subn(r'(?m)^(%s\s*=\s*)"[^"]*"' % re.escape(k2), lambda mm: mm.group(1) + '"%s"' % val, t)
        write(p, t)
    # ---- GameCube: Dolphin (DirectInput key names); Wii remotes are left alone
    p = os.path.join(E, "dolphin-emu", "User", "Config", "GCPadNew.ini")
    if os.path.exists(p):
        m = {"Buttons/A": "b", "Buttons/B": "y", "Buttons/X": "a", "Buttons/Y": "x", "Buttons/Z": "r", "Triggers/L": "l2", "Triggers/R": "r2", "Buttons/Start": "start"}
        v = {"Device": "DInput/0/Keyboard Mouse"}
        v.update({n: dinput(key[pad]) for n, pad in m.items() if key.get(pad)})
        for d, k in DIRS1.items():
            v["Main Stick/" + d.capitalize()] = dinput(k); v["D-Pad/" + d.capitalize()] = dinput(k)
        for d, k in DIRS2.items():
            v["C-Stick/" + d.capitalize()] = dinput(k)
        # RetroBat's analog-trigger and modifier keys sat on Home / End / Insert / Delete: off
        drop = lambda k, l: k in ("Triggers/L-Analog", "Triggers/R-Analog", "Main Stick/Modifier", "C-Stick/Modifier")
        write(p, set_ini(p, "GCPad1", v, drop))
    # ---- Model 3: Supermodel (Config\Supermodel.ini). Each panel button carries its roles across Model 3's game types
    # (system_buttons.NATIVE["model3"]); player 2's for the two-player fighters. Only the keyboard part of a line changes:
    # a JOY / MOUSE binding on the same line (WheelMap's, a gun's) stays.
    p = os.path.join(E, "supermodel", "Config", "Supermodel.ini")
    if os.path.exists(p):
        p2 = next((pp for pp in panel["players"] if pp.get("position") == "P2"), None)
        key2 = {pad: (p2 or {}).get("keys", {}).get("P2" + btn) for pad, btn in PAD.items()}
        roles = {"b": ["Punch", "Shift", "ShortPass", "VR1", "ViewChange", "TwinJoyShot1", "AnalogJoyTrigger", "Trigger",
                       "AnalogTriggerLeft", "SkiPollLeft"],
                 "a": ["Kick", "Beat", "LongPass", "VR2", "HandBrake", "RearBrake", "TwinJoyShot2", "AnalogJoyEvent",
                       "Offscreen", "AnalogTriggerRight", "SkiPollRight"],
                 "r": ["Guard", "Charge", "Shoot", "VR3", "MusicSelect", "AnalogJoyTrigger2"],
                 "r2": ["Escape", "Jump", "VR4", "AnalogJoyEvent2"],
                 "y": ["TwinJoyTurbo1"], "x": ["TwinJoyTurbo2"], "l2": ["GearShiftN"], "start": ["Start1"], "select": ["Coin1"]}
        want = {}
        for pad, names in roles.items():
            if key.get(pad):
                for n in names:
                    want["Input" + n] = supermodel_key(key[pad])
        for pad, n in (("b", "Punch2"), ("a", "Kick2"), ("r", "Guard2"), ("r2", "Escape2"), ("start", "Start2"), ("select", "Coin2")):
            if key2.get(pad):
                want["Input" + n] = supermodel_key(key2[pad])
        for d, k in DIRS1.items():
            want["InputJoy" + d.capitalize()] = supermodel_key(k)
        for d, k in DIRS2.items():
            want["InputJoy" + d.capitalize() + "2"] = supermodel_key(k)
        t = open(p, encoding="utf-8", errors="replace").read()

        def fix(m):
            name, val, tail = m.group(1), m.group(2), m.group(3)
            # the panel's key first; every other binding already on the line stays (a second key someone added on
            # purpose - Start on Enter too - a wheel, a gun, the mouse); NONE goes once a real binding is there
            keep = [tok.strip() for tok in val.split(",") if tok.strip() and tok.strip().upper() not in ("NONE", want[name].upper())]
            return '%s = "%s"%s' % (name, ",".join([want[name]] + keep), tail)
        rx = re.compile(r'^(%s)\s*=\s*"([^"]*)"(.*)$' % "|".join(re.escape(k) for k in want), re.M)
        write(p, rx.sub(fix, t))
    # ---- Wii: Dolphin's Wii Remote 1 - a real one stays (the 2P stand-up pairs real remotes); without one paired, an
    # emulated Wii Remote + Nunchuk on the panel (layout = system_buttons.NATIVE["wii"]), the trackball / mouse as pointer
    p = os.path.join(E, "dolphin-emu", "User", "Config", "WiimoteNew.ini")
    if os.path.exists(os.path.join(E, "dolphin-emu")) and not real_wiimote():
        m = {"Buttons/A": "b", "Buttons/B": "a", "Buttons/1": "r", "Buttons/2": "r2", "Nunchuk/Buttons/C": "y",
             "Nunchuk/Buttons/Z": "x", "Buttons/Home": "l2", "Buttons/+": "start", "Buttons/-": "select"}
        v = {"Source": "1", "Device": "DInput/0/Keyboard Mouse", "Extension": "Nunchuk"}
        v.update({n: dinput(key[pad]) for n, pad in m.items() if key.get(pad)})
        if key.get("l"):
            for axis in ("X", "Y", "Z"):
                v["Shake/" + axis] = dinput(key["l"])
        for d, k in DIRS1.items():
            v["D-Pad/" + d.capitalize()] = dinput(k); v["Nunchuk/Stick/" + d.capitalize()] = dinput(k)
        v.update({"IR/Up": "`Cursor Y-`", "IR/Down": "`Cursor Y+`", "IR/Left": "`Cursor X-`", "IR/Right": "`Cursor X+`"})
        write(p, set_ini(p, "Wiimote1", v))
    # ---- PSP: PPSSPP (keyboard = device 1, Android key codes)
    exe = os.path.join(E, "ppsspp", "PPSSPPWindows64.exe")
    if os.path.exists(exe):
        mem = os.path.join(E, "ppsspp", "memstick") if os.path.exists(os.path.join(E, "ppsspp", "portable.txt")) else os.path.join(os.path.expanduser("~"), "Documents", "PPSSPP")
        p = os.path.join(mem, "PSP", "SYSTEM", "controls.ini")
        m = {"Cross": "b", "Circle": "a", "Square": "y", "Triangle": "x", "L": "l", "R": "r", "Start": "start", "Select": "select"}
        v = {n: "1-%d" % nk(key[pad]) for n, pad in m.items() if key.get(pad)}
        for d, k in DIRS1.items():
            v[d.capitalize()] = "1-%d" % nk(k); v["An." + d.capitalize()] = "1-%d" % nk(k)
        v["Pause"] = "1-%d" % NK["ESCAPE"]
        write(p, set_ini(p, "ControlMapping", v))
    # ---- 3DS: Citra / Azahar (Qt key codes)
    for name in ("citra-canary", "citra", "azahar", "lime3ds"):
        p = os.path.join(E, name, "user", "config", "qt-config.ini")
        if not os.path.exists(p):
            continue
        m = {"button_a": "a", "button_b": "b", "button_x": "x", "button_y": "y", "button_l": "l", "button_r": "r", "button_zl": "l2", "button_zr": "r2", "button_start": "start", "button_select": "select"}
        v = {n: qt(key[pad]) for n, pad in m.items() if key.get(pad)}
        for d, k in DIRS1.items():
            v["button_" + d] = qt(k)
        stick = lambda ks: ("down:code$0%d$1engine$0keyboard,engine:analog_from_button,left:code$0%d$1engine$0keyboard,modifier:code$0%d$1engine$0keyboard,"
                            "modifier_scale:0.500000,right:code$0%d$1engine$0keyboard,up:code$0%d$1engine$0keyboard") % (qt(ks["down"]), qt(ks["left"]), QT_F12, qt(ks["right"]), qt(ks["up"]))
        t = open(p, encoding="utf-8").read()
        for k2, val in v.items():
            t = set_qt(t, r"profiles\1\%s" % k2, '"code:%d,engine:keyboard"' % val)
        t = set_qt(t, r"profiles\1\circle_pad", '"%s"' % stick(DIRS1))
        t = set_qt(t, r"profiles\1\c_stick", '"%s"' % stick(DIRS2))
        write(p, t)
    # ---- Switch: Yuzu and its forks (Qt key codes)
    for name in ("yuzu", "suyu", "sudachi", "citron", "eden"):
        p = os.path.join(E, name, "user", "config", "qt-config.ini")
        if not os.path.exists(p):
            continue
        m = {"button_a": "a", "button_b": "b", "button_x": "x", "button_y": "y", "button_l": "l", "button_r": "r", "button_zl": "l2", "button_zr": "r2", "button_plus": "start", "button_minus": "select"}
        v = {n: qt(key[pad]) for n, pad in m.items() if key.get(pad)}
        for d, k in {"dup": "UP", "ddown": "DOWN", "dleft": "LEFT", "dright": "RIGHT"}.items():
            v["button_" + d] = qt(k)
        kb = lambda c: "engine$0keyboard$1code$0%d$1toggle$00" % c
        stick = lambda ks: "engine:analog_from_button,up:%s,left:%s,modifier:%s,modifier_scale:0.500000,down:%s,right:%s" % (
            kb(qt(ks["up"])), kb(qt(ks["left"])), kb(QT_F12), kb(qt(ks["down"])), kb(qt(ks["right"])))
        t = open(p, encoding="utf-8").read()
        for k2, val in v.items():
            t = set_qt(t, "player_0_" + k2.replace("button_dup", "button_dup"), '"engine:keyboard,code:%d,toggle:0"' % val)
        t = set_qt(t, "player_0_lstick", '"%s"' % stick(DIRS1))
        t = set_qt(t, "player_0_rstick", '"%s"' % stick(DIRS2))
        write(p, t)
    for d in done:
        print("  " + d)
    print("panel keys: %d emulator configs%s" % (len(done), " (dry run)" if a.dry_run else ""))


def set_qt(t, k, val):
    """A Qt ini value and its \\default=false line (Qt writes both; default=true would make the program use its own)."""
    rx = re.compile(r"(?m)^%s=.*$" % re.escape(k))
    if rx.search(t):
        t = rx.sub(lambda m: "%s=%s" % (k, val), t)
    else:
        t = re.sub(r"(?m)^\[Controls\]\s*$", lambda m: "[Controls]\n%s=%s" % (k, val), t, count=1)
    dk = re.compile(r"(?m)^%s\\default=.*$" % re.escape(k))
    return dk.sub(lambda m: "%s\\default=false" % k, t) if dk.search(t) else t.replace("%s=%s" % (k, val), "%s\\default=false\n%s=%s" % (k, k, val), 1)


if __name__ == "__main__":
    main()
