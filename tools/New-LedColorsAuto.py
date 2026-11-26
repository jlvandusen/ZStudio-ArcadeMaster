r"""Button colours for every game LEDBlinky's Colors.ini doesn't know (James 2026-11-26: "Certain games like 1943 missing
buttons we should detect and assign colors").

Writes <manifest>\led-colors-auto.json { "<game>": { "P1B1": [r,g,b], ..., "P1START": [...] } } (LEDBlinky's 0-48 scale),
which AmPanel uses when Colors.ini has no entry for a game:
  1. a clone takes its parent's Colors.ini colours (meta.db cloneOf: 1943u, 1943kai -> 1943);
  2. anything else gets colours from what it really uses - players and buttons from MAME's controls
     (mame-inputs.json) or the catalog (games.json: TeknoParrot and the rest): buttons 1-8 in a fixed palette,
     start / coin white, unused buttons off.
  python tools/New-LedColorsAuto.py --manifest R:/ArcadeMaster/manifest --retrofe R:/ArcadeMaster/frontend/LEGENDS-am
"""
import argparse
import json
import os
import sqlite3

PALETTE = [[48, 0, 0], [0, 0, 48], [0, 48, 0], [48, 48, 0], [36, 0, 48], [0, 48, 48], [48, 20, 0], [48, 8, 30]]
WHITE = [36, 36, 36]
NAMES = {"red": [48, 0, 0], "blue": [0, 0, 48], "green": [0, 48, 0], "yellow": [48, 48, 0], "white": [48, 48, 48],
         "black": [0, 0, 0], "orange": [48, 20, 0], "purple": [36, 0, 48], "cyan": [0, 48, 48], "pink": [48, 8, 30]}


def read_ini(path):
    games, sec = {}, None
    for line in open(path, encoding="latin-1"):
        s = line.strip()
        if not s or s[0] in ";#":
            continue
        if s.startswith("[") and s.endswith("]"):
            sec = s[1:-1].strip().lower(); games.setdefault(sec, {}); continue
        if sec and "=" in s:
            k, v = s.split("=", 1); games[sec][k.strip().upper()] = v.strip()
    return games


def palette(path):
    p = dict(NAMES)
    sec = None
    if os.path.exists(path):
        for line in open(path, encoding="latin-1"):
            s = line.strip()
            if s.startswith("["):
                sec = s.lower(); continue
            if sec == "[colors]" and "=" in s:
                k, v = s.split("=", 1); parts = v.split(",")
                if len(parts) == 3:
                    try:
                        p[k.strip().lower()] = [int(x) for x in parts]
                    except ValueError:
                        pass
    return p


def to_label(key):
    k = key.upper()
    if len(k) > 3 and k[0] == "P" and k[1].isdigit() and k[2] == "_":
        pl, rest = k[:2], k[3:]
        if rest.startswith("BUTTON"):
            return pl + "B" + rest[6:]
        if rest in ("START", "COIN"):
            return pl + rest
    return None


def from_controls(players, buttons):
    out = {}
    for p in range(1, max(1, min(players, 4)) + 1):
        out["P%dSTART" % p] = WHITE
        out["P%dCOIN" % p] = WHITE
        for b in range(1, max(0, min(buttons, 8)) + 1):
            out["P%dB%d" % (p, b)] = PALETTE[b - 1]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--retrofe", required=True)
    a = ap.parse_args()
    lb = os.path.join(a.retrofe, "LEDBlinky")
    ini = read_ini(os.path.join(lb, "Colors.ini")) if os.path.exists(os.path.join(lb, "Colors.ini")) else {}
    pal = palette(os.path.join(lb, "Color-RGB.ini"))
    parents = {}
    db = os.path.join(a.retrofe, "meta.db")
    if os.path.exists(db):
        c = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
        for name, clone in c.execute("select name, cloneOf from Meta where cloneOf is not null and cloneOf <> ''"):
            parents.setdefault(name.lower(), clone.lower())
    machines = {}
    mi = os.path.join(a.manifest, "mame-inputs.json")
    if os.path.exists(mi):
        machines = json.load(open(mi, encoding="utf-8")).get("machines", {})
    catalog = {}
    gj = os.path.join(a.manifest, "games.json")
    if os.path.exists(gj):
        g = json.load(open(gj, encoding="utf-8-sig")); g = g.get("games", g) if isinstance(g, dict) else g
        for x in (g if isinstance(g, list) else g.values()):
            ctl = x.get("controls") or {}
            players = max(int(ctl.get("players") or 0), int(ctl.get("gunPlayers") or 0))
            catalog[x["id"].split(":")[-1].lower()] = (players, int(ctl.get("buttons") or 0), bool(ctl.get("flightStick")))
    names = set(machines) | set(catalog) | set(parents)
    out, n_clone, n_ctl = {}, 0, 0
    for n in sorted(names):
        key = n.lower()
        if key in ini:
            continue                      # LEDBlinky knows it
        par = parents.get(key)
        if par and par in ini:
            m = {}
            for k, v in ini[par].items():
                lab, rgb = to_label(k), pal.get(v.lower())
                if lab and rgb is not None:
                    m[lab] = rgb
            if m:
                out[n] = m; n_clone += 1; continue
        players = buttons = 0
        flight = False
        mm = machines.get(n) or machines.get(key)
        if key in catalog:
            # the frontend's own catalog first: a TeknoParrot id can be a MAME machine name too ("abc" is After Burner
            # Climax here, an ABC computer in MAME)
            players, buttons, flight = catalog[key]
        elif mm:
            players = int(mm[0] or 0)
            buttons = max([int(c[1] or 0) for c in mm[1]] + [0])
        # James: every known game lights at least its players' coin + start (2Spicy: gun game, no buttons, 2 players)
        if mm is not None or key in catalog:
            m = from_controls(players or 1, buttons)
            if flight:
                # flight-stick games: the stick's own buttons too, and coin + start for both players
                for p in (1, 2):
                    m["P%dSTART" % p] = WHITE; m["P%dCOIN" % p] = WHITE
                    for b in range(1, 4):
                        m["P%dB%dJOY" % (p, b)] = PALETTE[b - 1]
            out[n] = m; n_ctl += 1
    path = os.path.join(a.manifest, "led-colors-auto.json")
    with open(path + ".tmp", "w", encoding="utf-8") as f:
        json.dump(out, f, separators=(",", ":"))
    os.replace(path + ".tmp", path)
    print("led-colors-auto.json: %d games (%d from their parent's Colors.ini entry, %d from their controls); Colors.ini has %d"
          % (len(out), n_clone, n_ctl, len(ini)))


if __name__ == "__main__":
    main()
