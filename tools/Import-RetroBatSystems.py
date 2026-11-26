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
# the better choice when es_systems lists another first (docs/16): VICE x64sc is the accurate C64
PREFER = {"c64": ("libretro", "vice_x64sc")}
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


def pack_sources(plan, system):
    """The RetroFE packs that held this system (library-plan.json source roots, keeper order): their
    collections\\<C>\\medium_artwork folder and meta\\hyperlist\\<C>.xml - art and titles for games the library took
    from a pack rather than from RetroBat."""
    out = []
    s = next((x for x in plan.get("systems", []) if x["system"] == system), None)
    if not s:
        return out
    for b in s.get("keeper_order", []):
        for r in s.get("source_roots", {}).get(b, []):
            roms = r["from"].rstrip("\\")
            coll = os.path.dirname(roms)                       # ...\collections\<C>
            if os.path.basename(os.path.dirname(coll)).lower() != "collections":
                continue
            build = os.path.dirname(os.path.dirname(coll))
            out.append((os.path.join(coll, "medium_artwork"),
                        os.path.join(build, "meta", "hyperlist", os.path.basename(coll) + ".xml")))
    return out


def hyperlist_titles(files):
    t = {}
    for f in files:
        if not os.path.exists(f):
            continue
        try:
            for g in ET.parse(f).getroot().iter("game"):
                n, d = g.get("name"), (g.findtext("description") or "").strip()
                if n and d and n.lower() not in t:
                    t[n.lower()] = (d, (g.findtext("year") or "").strip(), (g.findtext("manufacturer") or "").strip(), (g.findtext("genre") or "").strip())
        except ET.ParseError:
            pass
    return t


def write_meta(retrofe, collection, romdir, games, extra_titles=None):
    """meta\\hyperlist\\<collection>.xml from RetroBat's gamelist.xml (then the packs' hyperlists): real titles,
    year, maker, genre, players."""
    extra_titles = extra_titles or {}
    gl = os.path.join(romdir, "gamelist.xml")
    info = {}
    if os.path.exists(gl):
        try:
            for g in ET.parse(gl).getroot().iter("game"):
                p = (g.findtext("path") or "").replace("\\", "/").split("/")[-1]
                if p:
                    info[os.path.splitext(p)[0]] = g
        except ET.ParseError:
            pass
    root = ET.Element("menu")
    ET.SubElement(ET.SubElement(root, "header"), "listname").text = collection
    titled = 0
    for f in games:
        base = os.path.splitext(f)[0]
        g = info.get(base)
        e = ET.SubElement(root, "game", name=base)
        title = (g.findtext("name") or "").strip() if g is not None else ""
        x = extra_titles.get(base.lower())
        if not title and x:
            title = x[0]
            for tag, v in (("year", x[1]), ("manufacturer", x[2]), ("genre", x[3])):
                if v:
                    ET.SubElement(e, tag).text = v
        ET.SubElement(e, "description").text = title or base
        titled += bool(title)
        if g is not None:
            year = (g.findtext("releasedate") or "")[:4]
            if year.isdigit():
                ET.SubElement(e, "year").text = year
            maker = (g.findtext("developer") or g.findtext("publisher") or "").strip()
            if maker:
                ET.SubElement(e, "manufacturer").text = maker
            genre = (g.findtext("genre") or "").strip()
            if genre:
                ET.SubElement(e, "genre").text = genre
            players = (g.findtext("players") or "").strip()
            if players:
                ET.SubElement(e, "players").text = players.split("-")[-1]
    out = os.path.join(retrofe, "meta", "hyperlist", collection + ".xml")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    ET.ElementTree(root).write(out, encoding="utf-8", xml_declaration=True)
    return titled


def rebuild_db(retrofe):
    """RetroFE reads meta\\hyperlist into meta.db only on -rebuilddatabase; not while the frontend is running."""
    import subprocess
    exe = os.path.join(retrofe, "core", "retrofe.exe")
    if not os.path.exists(exe):
        return "no core\\retrofe.exe"
    running = subprocess.run(["tasklist", "/FI", "IMAGENAME eq retrofe.exe"], capture_output=True, text=True).stdout
    if "retrofe.exe" in running.lower():
        return "the frontend is running - meta.db is rebuilt at the next Rebuild Menus"
    try:
        subprocess.run([exe, "-rebuilddatabase"], cwd=os.path.dirname(exe), timeout=600, capture_output=True)
        return "meta.db rebuilt"
    except subprocess.TimeoutExpired:
        return "meta.db rebuild timed out"


# James 2026-11-26 (option B): the main menu shows the makers; each opens its systems, then the games. Matched against
# the Classic Systems names (first rule that fits wins); anything unmatched goes to "Other Systems".
MAKERS = [
    ("Nintendo", r"nintendo|super nintendo|\bnes\b|famicom|game ?boy|\bwii\b|wii u|switch|gamecube|\bds\b|3ds"),
    ("Sega", r"sega|master system|mark iii|megadrive|genesis|\b32x\b|game gear|saturn|dreamcast|sg-1000"),
    ("Sony", r"playstation|\bpsp\b"),
    ("Microsoft", r"xbox"),
    ("Atari", r"atari|jaguar|lynx"),
    ("NEC", r"pc engine|supergrafx|turbografx"),
    ("SNK", r"neo ?geo"),
    ("Computers", r"amiga|commodore|\bc64\b|spectrum|\bmsx\b|amstrad|\bdos\b"),
    ("Arcade Boards", r"final burn|naomi|atomiswave|model [23]|teknoparrot|cps|daphne|laser"),
]


def maker_menus(cols):
    """collections\\<Maker>\\menu.txt from Classic Systems\\menu.txt, and the makers on the main menu in place of
    Classic Systems (Main\\am-extra-menu.txt + Main\\menu.txt). Returns a one-line summary."""
    mt = os.path.join(cols, "Classic Systems", "menu.txt")
    if not os.path.exists(mt):
        return "maker menus: no Classic Systems menu yet"
    systems = [l.strip() for l in open(mt) if l.strip() and os.path.isdir(os.path.join(cols, l.strip()))]
    groups = {}
    for s in systems:
        name = next((m for m, rx in MAKERS if re.search(rx, s, re.I)), "Other Systems")
        groups.setdefault(name, []).append(s)
    order = [m for m, _ in MAKERS if m in groups] + (["Other Systems"] if "Other Systems" in groups else [])
    for m in list(order):
        d = os.path.join(cols, m)
        if os.path.isdir(d) and not os.path.exists(os.path.join(d, MADE_HERE)):
            print("  %s exists and was not made here - left alone" % m); order.remove(m); continue
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, MADE_HERE), "w").write("menu\n")
        open(os.path.join(d, "menu.txt"), "w", newline="\r\n").write("\n".join(sorted(groups[m])) + "\n")
        # RetroFE logs "Could not import any collection settings" for a collection without one
        sc = os.path.join(d, "settings.conf")
        if not os.path.exists(sc):
            open(sc, "w", newline="\r\n").write("# ArcadeMaster maker menu (Import-RetroBatSystems.py): its systems are in menu.txt\n"
                                                "list.includeMissingItems = false\nlist.menuSort = yes\n")
    # the main menu: the makers where Classic Systems was (kept as a collection, just not on the main menu)
    for fn in ("am-extra-menu.txt", "menu.txt"):
        p = os.path.join(cols, "Main", fn)
        lines = [l.strip() for l in open(p)] if os.path.exists(p) else []
        lines = [l for l in lines if l]
        if fn == "am-extra-menu.txt" and not lines:
            lines = ["Classic Systems"]
        if not lines:
            continue
        out = []
        for l in lines:
            if l == "Classic Systems":
                out += [m for m in order if m not in lines]
            elif l not in out:
                out.append(l)
        if "Classic Systems" not in lines:
            out += [m for m in order if m not in out]
        open(p, "w", newline="\r\n").write("\n".join(out) + "\n")
    return "maker menus: " + ", ".join("%s (%d)" % (m, len(groups[m])) for m in order)


def safe(s):
    return re.sub(r'[<>:"/\\|?*]', "", s).strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--retrofe", required=True)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--retrobat", default=r"R:\CP78\RetroBat")
    ap.add_argument("--library", default=r"R:\ArcadeMaster\library", help="ArcadeMaster's library: roms\\<system> here wins")
    ap.add_argument("--systems", default=",".join(DEFAULT))
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-db", action="store_true", help="write the meta files but leave meta.db (Rebuild Menus rebuilds it)")
    ap.add_argument("--menus-only", action="store_true", help="only (re)write the maker menus from Classic Systems")
    a = ap.parse_args()
    if a.menus_only:
        print(maker_menus(os.path.join(a.retrofe, "collections")))
        return
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
    plan = {}
    pp = os.path.join(a.manifest, "library-plan.json")
    if os.path.exists(pp):
        plan = json.load(open(pp, encoding="utf-8-sig"))
        plan = {"systems": plan.get("systems", [])}   # only the systems part is used (the file is large)
    cols = os.path.join(a.retrofe, "collections")
    report, made = [], []
    for s in parse_systems(es):
        # the games: ArcadeMaster's library when the system was moved there (Move-ToLibrary, docs/18 end state),
        # else RetroBat's folder. Art and gamelist.xml stay in RetroBat's folder (media is never moved).
        artdir = os.path.join(rb, "roms", s["name"])
        libdir = os.path.join(a.library, "roms", s["name"])
        romdir = libdir if games_in(libdir, s["extensions"]) else artdir
        games = games_in(romdir, s["extensions"])
        choice = None
        p = picks.get(s["name"])
        if not p and s["name"] in PREFER:
            p = {"emulator": PREFER[s["name"]][0], "core": PREFER[s["name"]][1]}
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
                src = os.path.join(artdir, sub, base + "-" + kind + ext)
                if not os.path.exists(src):
                    continue
                for t in types:
                    n += link(src, os.path.join(cdir, "medium_artwork", t, base + ext))
        # games the library took from a RetroFE pack: that pack's own art (every type it has) and titles
        packs = pack_sources(plan, s["name"]) if romdir == libdir else []
        if packs:
            pack_art = []   # (type, folder) in keeper order
            for ma, _ in packs:
                if os.path.isdir(ma):
                    for t in os.listdir(ma):
                        if os.path.isdir(os.path.join(ma, t)):
                            pack_art.append((t, os.path.join(ma, t)))
            index = {}
            for t, d in pack_art:
                try:
                    for f in os.listdir(d):
                        index.setdefault((t.lower(), os.path.splitext(f)[0].lower()), os.path.join(d, f))
                except OSError:
                    pass
            types = sorted({t for t, _ in pack_art}, key=str.lower)
            for g in games:
                base = os.path.splitext(g)[0]
                for t in types:
                    src = index.get((t.lower(), base.lower()))
                    if src:
                        n += link(src, os.path.join(cdir, "medium_artwork", t, base + os.path.splitext(src)[1]))
        t = write_meta(a.retrofe, name, artdir, games, hyperlist_titles([h for _, h in packs]))
        print("      %d art links, %d of %d real titles" % (n, t, len(games)))
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
            print("Classic Systems: %d systems" % len(set(keep + made)))
            print(maker_menus(cols))
        if made and not a.no_db:
            print(rebuild_db(a.retrofe))
        with open(os.path.join(a.manifest, "systems.json"), "w", encoding="utf-8") as f:
            json.dump({"retrobat": rb, "systems": report}, f, indent=1)
    with_games = [r for r in report if r["games"]]
    print("RetroBat: %d systems, %d with games, %d of those with an installed emulator" %
          (len(report), len(with_games), sum(1 for r in with_games if r["uses"])))


if __name__ == "__main__":
    main()
