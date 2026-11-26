"""Which UltraStik map each game wants, for AmPanel (src/panel/Sticks.cs, LEDBlinky command 13).

Writes, into the manifest folder:
  stick-maps.json   {"default": "Joy8Way", "games": {"pacman": "Joy4Way", "qbert": "JoyDiag", ...}}
                    only games that do NOT want the 8-way default are listed
  ultrastik/*.um    ArcadeMaster's own map set (9x9 grids computed from angles, UltraMap's text format):
                    Joy8Way Joy4Way Joy2Way vJoy2Way JoyDiag Analog

Sources: mame-inputs.json (MAME -listxml controls, cached by Add-GameControls.ps1): joy 4 / 3 (half4) -> Joy4Way,
joy 2 -> Joy2Way, joy vertical2 -> vJoy2Way, an analog stick and no digital joystick -> Analog. Then
tools/stick-maps-overrides.json wins (games MAME calls 8-way that are not: Q*bert is diagonal).

  python tools/New-StickMaps.py --manifest R:/ArcadeMaster/manifest
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BORDERS = "30,58,86,114,142,170,198,226"   # the 9 zones across the stick's 0-255 travel


def grid(fn):
    """9x9 rows of direction codes; fn(x, y) gets -4..4 coordinates (y up) and returns a code."""
    rows = []
    for r in range(9):
        y = 4 - r
        rows.append(",".join(fn(c - 4, y) for c in range(9)))
    return rows


def sector8(x, y):
    """a square 8-way gate: a direction only in the outer two ninths of each axis. The centre is wide (58-198 of 0-255)
    because the pedestal's UltraStiks jitter about +-30 at rest: with the old 86-170 centre that noise read as full
    left / up blips that moved the menu by itself (2026-11-26)"""
    v = "N" if y >= 3 else "S" if y <= -3 else ""
    h = "E" if x >= 3 else "W" if x <= -3 else ""
    return (v + h) or "C"


def sector4(x, y):
    if abs(x) <= 2 and abs(y) <= 2:
        return "C"
    if abs(x) == abs(y):
        return "*"                      # exact diagonal: keep the last direction (no flicker between two)
    return ("E" if x > 0 else "W") if abs(x) > abs(y) else ("N" if y > 0 else "S")


def diag(x, y):
    if abs(x) <= 2 and abs(y) <= 2:
        return "C"
    if x == 0 or y == 0:
        return "*"
    return ("N" if y > 0 else "S") + ("E" if x > 0 else "W")


MAPS = {
    "Joy8Way": grid(sector8),
    "Joy4Way": grid(sector4),
    "Joy2Way": grid(lambda x, y: "C" if abs(x) <= 2 else ("E" if x > 0 else "W")),
    "vJoy2Way": grid(lambda x, y: "C" if abs(y) <= 2 else ("N" if y > 0 else "S")),
    "JoyDiag": grid(diag),
    "Analog": grid(lambda x, y: "-"),
}


def write_maps(folder):
    os.makedirs(folder, exist_ok=True)
    for name, rows in MAPS.items():
        text = ["MapFileFormatVersion=1.0", "", "MapSize=9", "MapBorderLocations=" + BORDERS]
        text += ["MapRow%d=%s" % (i + 1, r) for i, r in enumerate(rows)]
        with open(os.path.join(folder, name + ".um"), "w", newline="\r\n") as f:
            f.write("\n".join(text) + "\n")


def map_for(controls):
    """controls = [[type, buttons, ways], ...] from mame-inputs.json"""
    digital = [w for t, b, w in controls if t in ("joy", "doublejoy", "triplejoy")]
    if digital:
        w = digital[0]
        if w in ("4", "3 (half4)"):
            return "Joy4Way"
        if w == "2":
            return "Joy2Way"
        if w == "vertical2":
            return "vJoy2Way"
        return None                       # 8, 16, 5 (half8): the default
    if any(t == "stick" for t, b, w in controls):
        return "Analog"
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    src = os.path.join(a.manifest, "mame-inputs.json")
    if not os.path.exists(src):
        sys.exit("no %s (Add-GameControls.ps1 writes it)" % src)
    machines = json.load(open(src, encoding="utf-8"))["machines"]
    games = {}
    for rom, v in machines.items():
        m = map_for(v[1])
        if m:
            games[rom] = m
    over = json.load(open(os.path.join(HERE, "stick-maps-overrides.json"), encoding="utf-8"))
    for rom, m in over.get("games", {}).items():
        if m == "Joy8Way":
            games.pop(rom, None)
        else:
            games[rom] = m
    counts = {}
    for m in games.values():
        counts[m] = counts.get(m, 0) + 1
    print("stick maps: %d games off the 8-way default: %s" % (len(games), ", ".join("%s %d" % kv for kv in sorted(counts.items()))))
    if a.dry_run:
        return
    write_maps(os.path.join(a.manifest, "ultrastik"))
    out = os.path.join(a.manifest, "stick-maps.json")
    with open(out + ".tmp", "w", encoding="utf-8") as f:
        json.dump({"default": "Joy8Way", "games": dict(sorted(games.items()))}, f, separators=(",", ":"))
    os.replace(out + ".tmp", out)
    print("wrote %s and %s" % (out, os.path.join(a.manifest, "ultrastik")))


if __name__ == "__main__":
    main()
