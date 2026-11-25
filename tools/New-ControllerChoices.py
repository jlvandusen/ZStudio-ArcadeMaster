"""Which games give THIS cabinet a real choice of controller - the data behind "which controller will you use?" at
game start (James 2026-11-25: "when loading a game we can ask what controller will you be using if there are choices
for that game").

Reads games.json (what each game expects: Add-GameControls.ps1) and cabinet.json (what is plugged in:
Get-CabinetDevices.ps1, refreshed live by the hot-plug listener). Writes <manifest>/controller-choices.json:

  {"cabinet": "...", "at": "...", "games": {"<id>": {"title": "...", "choices": [
      {"id": "analog", "label": "UltraStik as an analog stick", "stickMap": "Analog"},
      {"id": "joystick", "label": "Joystick (8-way)", "stickMap": "Joy8Way"} ]}}}

Only games with two or more choices are listed; the first choice is the best fit (the one used when nobody answers).
stickMap is what AmPanel loads on the UltraStiks for that choice (src/panel/Sticks.cs).

  python tools/New-ControllerChoices.py --manifest R:/ArcadeMaster/manifest [--dry-run]
"""
import argparse
import collections
import datetime
import json
import os


def load(p):
    with open(p, encoding="utf-8-sig") as f:
        return json.load(f)


def choices_for(c, cap):
    """c = a game's controls, cap = the cabinet's capabilities -> list of choices, best first"""
    sticks = int(cap.get("arcadeSticks") or 0) > 0            # UltraStiks: digital or analog at the press of a map
    out = []

    def add(i, label, **kw):
        if i not in [x["id"] for x in out]:
            d = {"id": i, "label": label}
            d.update(kw)
            out.append(d)

    if c.get("wheel"):
        if cap.get("wheel"):
            add("wheel", "Steering wheel and pedals")
        if int(cap.get("gamepads") or 0):
            add("gamepad", "Gamepad")
        if sticks:
            add("analog", "UltraStik as an analog stick (steer)", stickMap="Analog")
    elif c.get("flightStick"):
        if cap.get("flightStick"):
            add("flightstick", "Flight stick")
        if sticks:
            add("analog", "UltraStik as an analog stick", stickMap="Analog")
        if int(cap.get("gamepads") or 0):
            add("gamepad", "Gamepad")
    elif c.get("lightgun"):
        if int(cap.get("lightguns") or 0):
            add("lightgun", "Light gun")
        if cap.get("trackball"):
            add("trackball", "Trackball (aim with the ball)")
        if int(cap.get("mice") or 0):
            add("mouse", "Mouse")
    elif c.get("trackball") or c.get("spinner"):
        if cap.get("trackball"):
            add("trackball", "Trackball" + (" / spinner" if c.get("spinner") else ""))
        if sticks:
            add("joystick", "Joystick (8-way)", stickMap="Joy8Way")
    elif c.get("analogStick"):
        if sticks:
            add("analog", "UltraStik as an analog stick", stickMap="Analog")
            add("joystick", "Joystick (8-way digital)", stickMap="Joy8Way")
        if cap.get("flightStick"):
            add("flightstick", "Flight stick")
        if int(cap.get("gamepads") or 0):
            add("gamepad", "Gamepad")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    games = load(os.path.join(a.manifest, "games.json"))
    games = games.get("games", games) if isinstance(games, dict) else games
    items = games if isinstance(games, list) else list(games.values())
    cab = load(os.path.join(a.manifest, "cabinet.json"))
    cap = cab.get("capabilities", {})
    # real titles: library games carry their rom name as title; history.dat (history-index.json, New-GameStories.py)
    # knows "After Burner II" for info:aburner2
    titles = {}
    hp = os.path.join(a.manifest, "history-index.json")
    if os.path.exists(hp):
        for e in load(hp).get("entries", []):
            for k in e.get("keys", []):
                if k.startswith("info:") and e.get("title"):
                    titles.setdefault(k[5:], e["title"])
    out, kinds = {}, collections.Counter()
    for g in items:
        ch = choices_for(g.get("controls") or {}, cap)
        if len(ch) >= 2:
            item = g["id"].split(":")[-1]
            title = g.get("title") or item
            if title == item and item in titles:
                title = titles[item]
            out[g["id"]] = {"title": title, "choices": ch}
            kinds[" / ".join(x["id"] for x in ch)] += 1
    # every game's spoken / shown title (AmPanel's "Now playing ..."), keyed by the item name RetroFE passes
    names = {}
    for g in items:
        item = g["id"].split(":")[-1]
        t = g.get("title") or item
        if t == item and item in titles:
            t = titles[item]
        names.setdefault(item, t)
    if not a.dry_run:
        tp = os.path.join(a.manifest, "game-titles.json")
        with open(tp + ".tmp", "w", encoding="utf-8") as f:
            json.dump(names, f, separators=(",", ":"), ensure_ascii=False)
        os.replace(tp + ".tmp", tp)
    print("controller choices on this cabinet: %d of %d games" % (len(out), len(items)))
    for k, n in kinds.most_common():
        print("  %5d  %s" % (n, k))
    if a.dry_run:
        return
    p = os.path.join(a.manifest, "controller-choices.json")
    with open(p + ".tmp", "w", encoding="utf-8") as f:
        json.dump({"cabinet": cab.get("computer") or os.environ.get("COMPUTERNAME"), "at": datetime.datetime.now().isoformat(timespec="seconds"),
                   "games": dict(sorted(out.items()))}, f, separators=(",", ":"))
    os.replace(p + ".tmp", p)
    print("wrote " + p)


if __name__ == "__main__":
    main()
