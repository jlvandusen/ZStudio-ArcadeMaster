r"""Classic systems from RetroBat, in the RetroFE frontend: one collection per system, launched through RetroBat's own
emulatorLauncher.exe (docs/15-emulators.md).

emulatorLauncher -system <s> -emulator <e> -core <c> -rom <file> writes that emulator's config for THIS PC at every
launch (paths, BIOS, controllers) and waits for it, so adding a system is data, not hand work. Tested on the pedestal:
xbox/xemu, amiga500/puae, c64/vice_x64sc.

What it writes (nothing of the build's own is edited):
  <RetroFE>\collections\<System>\settings.conf     list.path = RetroBat's roms\<system>, its extensions, the launcher
  <RetroFE>\collections\<System>\medium_artwork\   hard links to RetroBat's scraped art (same drive: no copies)
                                                     marquee -> logo, image -> screenshot + am_backdrop, thumb -> cover,
                                                     video -> video
  <RetroFE>\launchers.windows\AM_RB_<system>.conf  emulatorLauncher.exe -system ... -rom "%ITEM_FILEPATH%"
  <RetroFE>\collections\Classic Systems\menu.txt  the systems, in the main menu through Main\am-extra-menu.txt
  <manifest>\systems.json                          every RetroBat system: emulators, installed or not, game count
A collection that already exists and was not made here (the build's own "Commodore 64") is left alone: ours is named
"<System> (RetroBat)". Emulator / core per system: the first INSTALLED choice in es_systems.cfg, unless
<manifest>\systems-cabinet.json says { "c64": { "emulator": "libretro", "core": "vice_x64sc" } }.

  python tools/Import-RetroBatSystems.py --retrofe R:/ArcadeMaster/frontend/LEGENDS-am --manifest R:/ArcadeMaster/manifest
  ... --systems c64,amiga500     only these        ... --all     every system with games     ... --dry-run
"""
import argparse
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

DEFAULT = ["c64", "amiga500", "nes", "snes", "megadrive", "mastersystem", "pcengine", "n64", "psx", "gamecube", "wii",
           "wiiu", "xbox", "dreamcast", "saturn", "atari2600"]
MADE_HERE = "am-retrobat.txt"          # marker file: this collection belongs to the importer
FOLDER = {"dolphin": "dolphin-emu", "cxbx": "cxbx-reloaded", "pcsx2": "pcsx2", "duckstation": "duckstation"}
MEDIA = [("marquee", ["logo"]), ("image", ["screenshot", "am_backdrop"]), ("thumb", ["cover"]), ("video", ["video"])]


def parse_systems(es_cfg):
    out = []
    for s in ET.parse(es_cfg).getroot().iter("system"):
        name = (s.findtext("name") or "").strip()
        if not name:
            continue
        exts = [e.strip().lstrip(".") for e in (s.findtext("extension") or "").split() if e.strip()]
        emus = []
        for e in s.iter("emulator"):
            cores = [c.text.strip() for c in e.iter("core") if c.text and c.text.strip()]
            emus.append((e.get("name"), cores or [None]))
        out.append({"name": name, "fullname": (s.findtext("fullname") or name).strip(), "extensions": exts, "emulators": emus})
    return out


def installed(rb, emu, core):
    if emu == "libretro":
        return os.path.exists(os.path.join(rb, "emulators", "retroarch", "retroarch.exe")) and \
            (core is None or os.path.exists(os.path.join(rb, "emulators", "retroarch", "cores", core + "_libretro.dll")))
    d = os.path.join(rb, "emulators", FOLDER.get(emu, emu))
    return os.path.isdir(d) and any(f.lower().endswith(".exe") and "unins" not in f.lower() for f in os.listdir(d))


def games_in(folder, exts):
    if not os.path.isdir(folder):
        return []
    want = {"." + e.lower() for e in exts}
    return sorted(f for f in os.listdir(folder) if os.path.splitext(f)[1].lower() in want and os.path.isfile(os.path.join(folder, f)))


def link(src, dst):
    if os.path.exists(dst):
        return False
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    try:
        os.link(src, dst)
    except OSError:
        return False   # another drive: no copy (art is optional)
    return True


def safe(s):
    return re.sub(r'[<>:"/\\|?*]', "", s).strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--retrofe", required=True)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--retrobat", default=r"R:\CP78\RetroBat")
    ap.add_argument("--systems", default=",".join(DEFAULT))
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    rb = a.retrobat
    es = os.path.join(rb, "emulationstation", ".emulationstation", "es_systems.cfg")
    launcher = os.path.join(rb, "emulationstation", "emulatorLauncher.exe")
    if not (os.path.exists(es) and os.path.exists(launcher)):
        print("no RetroBat at %s (es_systems.cfg + emulatorLauncher.exe) - nothing to import on this cabinet" % rb)
        return
    picks = {}
    pf = os.path.join(a.manifest, "systems-cabinet.json")
    if os.path.exists(pf):
        picks = json.load(open(pf, encoding="utf-8-sig"))
    wanted = None if a.all else {s.strip() for s in a.systems.split(",") if s.strip()}
    cols = os.path.join(a.retrofe, "collections")
    report, made = [], []
    for s in parse_systems(es):
        romdir = os.path.join(rb, "roms", s["name"])
        games = games_in(romdir, s["extensions"])
        choice = None
        p = picks.get(s["name"])
        if p and installed(rb, p.get("emulator"), p.get("core")):
            choice = (p.get("emulator"), p.get("core"))
        for emu, cores in s["emulators"]:
            for core in cores:
                if choice is None and installed(rb, emu, core):
                    choice = (emu, core)
        report.append({"system": s["name"], "fullname": s["fullname"], "games": len(games), "extensions": s["extensions"],
                       "emulators": [{"emulator": e, "cores": [c for c in cs if c], "installed": any(installed(rb, e, c) for c in cs)} for e, cs in s["emulators"]],
                       "uses": {"emulator": choice[0], "core": choice[1]} if choice else None})
        if wanted is not None and s["name"] not in wanted:
            continue
        if not games or not choice:
            if wanted is not None:
                print("  skip %-12s %s" % (s["name"], "no games" if not games else "no installed emulator"))
            continue
        # the collection: our own name, or "<name> (RetroBat)" when the build already has one of its own
        name = safe(s["fullname"])
        if os.path.isdir(os.path.join(cols, name)) and not os.path.exists(os.path.join(cols, name, MADE_HERE)):
            name = name + " (RetroBat)"
        made.append(name)
        lname = "AM_RB_" + s["name"]
        args = '-system %s -emulator %s%s -rom "%%ITEM_FILEPATH%%"' % (s["name"], choice[0], (" -core " + choice[1]) if choice[1] else "")
        print("  %-12s %4d games -> %-34s %s%s" % (s["name"], len(games), name, choice[0], ("/" + choice[1]) if choice[1] else ""))
        if a.dry_run:
            continue
        cdir = os.path.join(cols, name)
        os.makedirs(cdir, exist_ok=True)
        open(os.path.join(cdir, MADE_HERE), "w").write("system=%s\n" % s["name"])
        with open(os.path.join(cdir, "settings.conf"), "w", newline="\r\n") as f:
            f.write("# made by tools/Import-RetroBatSystems.py - RetroBat %s through emulatorLauncher (docs/15)\n" % s["name"])
            f.write("list.path = %s\nlist.extensions = %s\nlist.includeMissingItems = false\nlist.menuSort = yes\nlauncher = %s\n"
                    % (romdir, ",".join(s["extensions"]), lname))
        ldir = os.path.join(a.retrofe, "launchers.windows")
        os.makedirs(ldir, exist_ok=True)
        with open(os.path.join(ldir, lname + ".conf"), "w", newline="\r\n") as f:
            f.write("executable = %s\narguments = %s\ncurrentDirectory = %s\n" % (launcher, args, os.path.dirname(launcher)))
        # art: RetroBat's scraped files, linked under RetroFE's names
        n = 0
        for g in games:
            base = os.path.splitext(g)[0]
            for kind, types in MEDIA:
                sub, ext = ("videos", ".mp4") if kind == "video" else ("images", ".png")
                src = os.path.join(romdir, sub, base + "-" + kind + ext)
                if not os.path.exists(src):
                    continue
                for t in types:
                    n += link(src, os.path.join(cdir, "medium_artwork", t, base + ext))
        if n:
            print("      %d art links" % n)
    if not a.dry_run:
        if made:
            menu = os.path.join(cols, "Classic Systems")
            os.makedirs(menu, exist_ok=True)
            open(os.path.join(menu, MADE_HERE), "w").write("menu\n")
            old = []
            mt = os.path.join(menu, "menu.txt")
            if os.path.exists(mt):
                old = [l.strip() for l in open(mt) if l.strip()]
            keep = [c for c in old if c not in made and os.path.isdir(os.path.join(cols, c))]   # earlier runs' systems stay
            open(mt, "w", newline="\r\n").write("\n".join(sorted(set(keep + made))) + "\n")
            extra = os.path.join(cols, "Main", "am-extra-menu.txt")
            lines = [l.strip() for l in open(extra)] if os.path.exists(extra) else []
            if "Classic Systems" not in lines:
                os.makedirs(os.path.dirname(extra), exist_ok=True)
                open(extra, "w", newline="\r\n").write("\n".join([l for l in lines if l] + ["Classic Systems"]) + "\n")
            print("Classic Systems menu: %d systems (Main\\am-extra-menu.txt -> main menu at the next Rebuild Menus)" % len(set(keep + made)))
        with open(os.path.join(a.manifest, "systems.json"), "w", encoding="utf-8") as f:
            json.dump({"retrobat": rb, "systems": report}, f, indent=1)
    with_games = [r for r in report if r["games"]]
    print("RetroBat: %d systems, %d with games, %d of those with an installed emulator" %
          (len(report), len(with_games), sum(1 for r in with_games if r["uses"])))


if __name__ == "__main__":
    main()
