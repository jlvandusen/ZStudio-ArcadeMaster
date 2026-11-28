r"""Game lists from what discovery found, for a PC without RetroBat (or the systems RetroBat does not have). docs/BACKLOG
1a: "lists for PCs without RetroBat, from discovery.json" - most people have RetroArch or standalone emulators and
folders of games, not RetroBat.

For every system in <manifest>\discovery.json (tools/Find-Emulators.py) that has an emulator AND games, and no list in
the frontend yet, this makes collections\<System name>\ (settings.conf: its biggest game folder, the file types found
there, launcher = AM_RB_<system> as the placeholder tools/New-DirectLaunchers.py turns into the direct launcher), adds it
to Classic Systems and rebuilds the maker menus (Nintendo, Sega, Sony ... - the same grouping Import-RetroBatSystems.py
uses). Run New-DirectLaunchers.py next (tools/Invoke-FirstRun.ps1 does).
  python tools/New-ListsFromDiscovery.py --retrofe <frontend> --manifest <manifest> [--dry-run]
"""
import argparse
import importlib.util
import json
import os
import re

MARK = "am-discovery.txt"          # this collection was made from discovery
NAMES = {
    "nes": "Nintendo Entertainment System", "snes": "Super Nintendo Entertainment System", "n64": "Nintendo 64",
    "gb": "Game Boy", "gbc": "Game Boy Color", "gba": "Game Boy Advance", "nds": "Nintendo DS", "3ds": "Nintendo 3DS",
    "gamecube": "GameCube", "wii": "Wii", "wiiu": "Wii U", "switch": "Switch", "megadrive": "Megadrive - Genesis",
    "mastersystem": "Master System", "gamegear": "Game Gear", "saturn": "Saturn", "dreamcast": "Dreamcast",
    "psx": "PlayStation", "ps2": "PlayStation 2", "psp": "PlayStation Portable", "ps3": "PlayStation 3", "xbox": "Xbox",
    "xbox360": "Xbox 360", "pcengine": "PC Engine", "neogeo": "Neo Geo", "mame": "MAME", "model3": "Model 3",
    "model2": "Model 2", "naomi": "Naomi", "atomiswave": "Atomiswave", "atari2600": "Atari 2600", "c64": "Commodore 64",
    "amiga": "Amiga",
}
SKIP_EXT = {".txt", ".xml", ".jpg", ".png", ".ini", ".cfg", ".dat", ".nfo", ".srm", ".sav", ".state", ".db", ".json"}


def has_list(cols, system, folder=None):
    """a list for this system is there already: our launcher names it, it reads the same folder (links resolved), or -
    for MAME - a list is tagged metadata.type = MAME (a CoinOPS build's Arcades / Fight lists, 2026-11-27)"""
    rx = re.compile(r"^(?:\s*launcher\s*=\s*AM_(?:RB|DL)_%s\b|# was AM_RB_%s )" % (re.escape(system), re.escape(system)), re.M | re.I)
    real = os.path.normcase(os.path.realpath(folder)) if folder else None
    root = os.path.dirname(cols)
    for c in os.listdir(cols):
        sc = os.path.join(cols, c, "settings.conf")
        try:
            t = open(sc, encoding="latin-1").read()
        except OSError:
            t = ""
        if rx.search(t):
            return c
        if system == "mame" and re.search(r"^\s*metadata\.type\s*=\s*MAME\s*$", t, re.M | re.I):
            return c
        lp = re.search(r"^\s*list\.path\s*=\s*(.+?)\s*$", t, re.M)
        if real and lp:
            p = lp.group(1).replace("%BASE_ITEM_PATH%", os.path.join(root, "collections")).replace("%ITEM_COLLECTION_NAME%", c)
            p = p if os.path.isabs(p) else os.path.join(root, p)
            try:
                if os.path.normcase(os.path.realpath(p)) == real:
                    return c
            except OSError:
                pass
        mk = os.path.join(cols, c, MARK)
        if os.path.exists(mk) and open(mk, encoding="utf-8").read().strip() == "system=" + system:
            return c
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--retrofe", required=True)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    cols = os.path.join(a.retrofe, "collections")
    try:
        disc = json.load(open(os.path.join(a.manifest, "discovery.json"), encoding="utf-8"))
    except (OSError, ValueError):
        print("lists from discovery: no discovery.json - run tools/Find-Emulators.py first")
        return
    made = []
    for system, v in sorted(disc.get("systems", {}).items()):
        if not v.get("emulators") or not v.get("games") or system not in NAMES:
            continue
        folder = v["games"][0]["path"]                      # the biggest game folder (discovery sorts by count)
        if has_list(cols, system, folder):
            continue
        exts = sorted({os.path.splitext(f)[1].lower().lstrip(".") for f in os.listdir(folder)
                       if os.path.isfile(os.path.join(folder, f)) and os.path.splitext(f)[1] and os.path.splitext(f)[1].lower() not in SKIP_EXT})
        if not exts:
            continue
        name = NAMES[system]
        if os.path.isdir(os.path.join(cols, name)) and not os.path.exists(os.path.join(cols, name, MARK)):
            name += " (found)"                              # a list of that name that is not ours stays as it is
        print("  %-12s %5d games -> %-38s %s" % (system, v["games"][0]["games"], name, folder))
        made.append(name)
        if a.dry_run:
            continue
        cdir = os.path.join(cols, name)
        os.makedirs(cdir, exist_ok=True)
        open(os.path.join(cdir, MARK), "w", encoding="utf-8").write("system=%s\n" % system)
        with open(os.path.join(cdir, "settings.conf"), "w", newline="\r\n", encoding="latin-1") as f:
            f.write("# made by tools/New-ListsFromDiscovery.py from discovery.json - New-DirectLaunchers.py sets the launcher\n")
            f.write("list.path = %s\nlist.extensions = %s\nlist.includeMissingItems = false\nlist.menuSort = yes\nlauncher = AM_RB_%s\n"
                    % (folder, ",".join(exts), system))
    if made and not a.dry_run:
        menu = os.path.join(cols, "Classic Systems")
        os.makedirs(menu, exist_ok=True)
        mt = os.path.join(menu, "menu.txt")
        old = [l.strip() for l in open(mt) if l.strip()] if os.path.exists(mt) else []
        keep = [c for c in old if os.path.isdir(os.path.join(cols, c))]
        open(mt, "w", newline="\r\n").write("\n".join(sorted(set(keep + made))) + "\n")
        # the maker menus, with the importer's own grouping (Nintendo, Sega, Sony ...)
        spec = importlib.util.spec_from_file_location("am_import", os.path.join(os.path.dirname(os.path.abspath(__file__)), "Import-RetroBatSystems.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        print(mod.maker_menus(cols))
    print("lists from discovery: %d new%s" % (len(made), " (dry run)" if a.dry_run else ""))


if __name__ == "__main__":
    main()
