r"""Xbox (xemu) played on the arcade panel: write xemu's keyboard -> Xbox pad map from this cabinet's panel.json.

The pedestal has no gamepad: its buttons are keyboard keys (I-PAC). xemu 0.8 takes a keyboard as player 1's pad through
[input.keyboard_controller_scancode_map] (SDL scancodes), and RetroBat's emulatorLauncher keeps that section when it
rewrites xemu.toml at every launch (tested 2026-11-25). The layout follows the cabinet's twin-stick convention:

  left stick  = P1 stick         right stick = P2 stick           A B X Y      = P1 buttons 1-4
  white/black = P1 buttons 5-6   LT / RT     = P1 buttons 7-8     L3 / R3      = P2 buttons 1-2
  d-pad       = P2 buttons 5-8   start       = P1 start           back         = P1 coin

  python tools/Set-XemuPanelMap.py --manifest R:/ArcadeMaster/manifest [--xemu R:/CP78/RetroBat/emulators/xemu] [--dry-run]
"""
import argparse
import json
import os
import re

# MAME KEYCODE names (panel.json) -> SDL scancodes (xemu)
SDL = {"LCONTROL": 224, "LSHIFT": 225, "LALT": 226, "RCONTROL": 228, "RSHIFT": 229, "RALT": 230, "SPACE": 44,
       "ENTER": 40, "ESC": 41, "TAB": 43, "BACKSPACE": 42, "UP": 82, "DOWN": 81, "LEFT": 80, "RIGHT": 79,
       "OPENBRACE": 47, "CLOSEBRACE": 48, "BACKSLASH": 49, "COLON": 51, "QUOTE": 52, "TILDE": 53, "COMMA": 54,
       "STOP": 55, "SLASH": 56, "MINUS": 45, "EQUALS": 46}
for i, ch in enumerate("ABCDEFGHIJKLMNOPQRSTUVWXYZ"):
    SDL[ch] = 4 + i
for i in range(1, 10):
    SDL[str(i)] = 29 + i
SDL["0"] = 39
for i in range(1, 13):
    SDL["F%d" % i] = 57 + i

# the sticks are not in panel.json (MAME defaults on the I-PAC): P1 = arrows, P2 = R F D G
STICKS = {"lstick_up": "UP", "lstick_down": "DOWN", "lstick_left": "LEFT", "lstick_right": "RIGHT",
          "rstick_up": "R", "rstick_down": "F", "rstick_left": "D", "rstick_right": "G"}
LAYOUT = {"a": "P1B1", "b": "P1B2", "x": "P1B3", "y": "P1B4", "white": "P1B5", "black": "P1B6", "ltrigger": "P1B7",
          "rtrigger": "P1B8", "lstick_btn": "P2B1", "rstick_btn": "P2B2", "dpad_up": "P2B5", "dpad_down": "P2B6",
          "dpad_left": "P2B7", "dpad_right": "P2B8", "start": "P1START", "back": "P1COIN"}
SECTION = "[input.keyboard_controller_scancode_map]"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--xemu", default=r"R:\CP78\RetroBat\emulators\xemu")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    toml = os.path.join(a.xemu, "xemu.toml")
    if not os.path.exists(toml):
        print("no xemu.toml at %s - nothing to do" % a.xemu)
        return
    keys = {}
    for p in json.load(open(os.path.join(a.manifest, "panel.json"), encoding="utf-8-sig")).get("players", []):
        keys.update(p.get("keys", {}))
    lines, missing = [SECTION], []
    for pad, ctl in list(LAYOUT.items()) + [(k, None) for k in STICKS]:
        name = keys.get(ctl) if ctl else STICKS[pad]
        code = SDL.get((name or "").upper())
        if code is None:
            missing.append("%s (%s)" % (pad, ctl or name))
            continue
        lines.append("%s = %d" % (pad, code))
    text = open(toml, encoding="utf-8").read()
    # replace our section if it is there (up to the next [section] or the end), else append it
    text = re.sub(r"\n?\[input\.keyboard_controller_scancode_map\][^\[]*", "\n", text).rstrip() + "\n\n" + "\n".join(lines) + "\n"
    print("xemu pad on the panel: %d controls mapped%s" % (len(lines) - 1, ("; not on this panel: " + ", ".join(missing)) if missing else ""))
    if a.dry_run:
        print("\n".join(lines))
        return
    open(toml, "w", encoding="utf-8", newline="\n").write(text)
    print("wrote " + toml)


if __name__ == "__main__":
    main()
