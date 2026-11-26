r"""Amiga (WinUAE) played on the arcade panel: both players' sticks and fire buttons in every per-game .uae config.

James 2026-11-26: "I really don't like retroarch ... But I do need proper joystick controls for these legacy systems."
The Pipmick configs map player 1 (Amiga port 1, joyportcustom0) to a game controller AND the panel's P1 keys
(arrows + Left Ctrl), but player 2 (port 0, joyportcustom1) to a game controller only - on a keyboard-encoder panel
player 2 had no controls. This adds the panel's P2 keys (manifest\panel.json; stick = MAME's R F D G) to port 0 and
makes sure P1's keys match the panel too. DirectInput scancodes (WinUAE's "k.0.b.<scancode>.0").
Each .uae is backed up once (<file>.am-bak); running again changes nothing.

  python tools/Set-WinUAEPanelMap.py --manifest R:/ArcadeMaster/manifest --configs "<pack>\Configurations\Host" [--dry-run]
"""
import argparse
import glob
import json
import os
import re
import shutil

DIK = {"ESC": 1, "1": 2, "2": 3, "3": 4, "4": 5, "5": 6, "6": 7, "7": 8, "8": 9, "TAB": 15, "Q": 16, "W": 17, "E": 18,
       "R": 19, "T": 20, "Y": 21, "U": 22, "I": 23, "O": 24, "P": 25, "ENTER": 28, "LCONTROL": 29, "A": 30, "S": 31,
       "D": 32, "F": 33, "G": 34, "H": 35, "J": 36, "K": 37, "L": 38, "LSHIFT": 42, "BACKSLASH": 43, "Z": 44, "X": 45,
       "C": 46, "V": 47, "B": 48, "N": 49, "M": 50, "SLASH": 53, "RSHIFT": 54, "LALT": 56, "SPACE": 57, "F1": 59,
       "F2": 60, "F3": 61, "F4": 62, "F5": 63, "F6": 64, "F7": 65, "F8": 66, "F9": 67, "F10": 68, "F11": 87, "F12": 88,
       "RCONTROL": 157, "RALT": 184, "UP": 200, "LEFT": 203, "RIGHT": 205, "DOWN": 208}
# the sticks are not in panel.json (MAME defaults on the I-PAC)
STICK = {"P1": {"UP": "UP", "DOWN": "DOWN", "LEFT": "LEFT", "RIGHT": "RIGHT"},
         "P2": {"UP": "R", "DOWN": "F", "LEFT": "D", "RIGHT": "G"}}


def wanted(keys, player, amiga):
    """k.0 entries for one panel player on one Amiga joystick (JOY1 = port 0, JOY2 = port 1)."""
    out = []
    for d, k in STICK[player].items():
        out.append("k.0.b.%d.0=%s_%s" % (DIK[k], amiga, d))
    # James 2026-11-26: "The Amiga did understand a Genesis joystick and sometimes used all 3 buttons" - so each player
    # gets fire + 2nd + 3rd button (P1: LCtrl / LAlt / Space; P2: A / S / Q). P1's Left Alt and Space stop being
    # the Amiga's Alt / space keys (Right Alt stays the Amiga Alt).
    for btn, func in (("B1", "FIRE_BUTTON"), ("B2", "2ND_BUTTON"), ("B3", "3RD_BUTTON")):
        k = keys.get(player + btn)
        if k and k.upper() in DIK:
            out.append("k.0.b.%d.0=%s_%s" % (DIK[k.upper()], amiga, func))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--configs", required=True, help="folder with the per-game .uae files")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    keys = {}
    for p in json.load(open(os.path.join(a.manifest, "panel.json"), encoding="utf-8-sig")).get("players", []):
        keys.update(p.get("keys", {}))
    plan = {"joyportcustom0": wanted(keys, "P1", "JOY2"), "joyportcustom1": wanted(keys, "P2", "JOY1")}
    changed = 0
    files = sorted(glob.glob(os.path.join(a.configs, "*.uae")))
    for f in files:
        text = open(f, encoding="latin-1").read()
        new = text
        for line_key, ents in plan.items():
            m = re.search(r"^%s=(.*)$" % line_key, new, re.M)
            if not m:
                continue
            amiga = "JOY2" if line_key == "joyportcustom0" else "JOY1"
            parts = m.group(1).split()
            # drop earlier keyboard entries for this Amiga joystick's directions/fire (ours or stale), keep the rest
            mine = {e.split("=")[0] for e in ents}          # the keys we map: any older use of them goes (KEY_ALT_LEFT ...)
            keep = [x for x in parts if not (x.startswith("k.0.") and (x.split("=")[0] in mine or
                    re.search(r"=%s_(UP|DOWN|LEFT|RIGHT|FIRE_BUTTON|2ND_BUTTON|3RD_BUTTON)$" % amiga, x)))]
            line = "%s=%s" % (line_key, " ".join(keep + ents))
            new = new[:m.start()] + line + new[m.end():]
        if new != text:
            changed += 1
            if not a.dry_run:
                if not os.path.exists(f + ".am-bak"):
                    shutil.copy2(f, f + ".am-bak")
                open(f, "w", encoding="latin-1", newline="").write(new)
    print("WinUAE panel map: %d of %d configs %s (P1 %s; P2 %s)" % (changed, len(files), "would change" if a.dry_run else "updated",
          " ".join(plan["joyportcustom0"]), " ".join(plan["joyportcustom1"])))


if __name__ == "__main__":
    main()
