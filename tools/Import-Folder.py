r"""Import: point at a folder and ArcadeMaster takes it in (James 2026-11-27: "add ability to perform import of a new game
or system etc as needed and point to a folder and consume the rom or emulators etc").

What the folder holds is worked out from the same tables discovery uses (tools/emulators/catalog.json):
  - an EMULATOR (an exe from the catalog, at the top or a level down): linked as <root>\emulators\<folder name> and
    added to discovery.json, RetroArch with its cores
  - a SYSTEM's games (the folder's name means a system - snes, Super Nintendo, psx ... - or --system says which):
    linked as <root>\library\roms\<system>; when that already exists, each game is linked into it (a folder link per
    folder, a hard link per file on the same drive; files on another drive need --move)
  - a COLLECTION of system folders (roms\snes, roms\psx ...): each recognised one as above
--move moves instead of linking (same drive: instant). The import is recorded in discovery.json; tools/Invoke-FirstRun.ps1
-ImportFolder runs this, then makes the lists, launchers, keys, art and lights for what came in.
  python tools/Import-Folder.py --folder D:\Games\snes --retrofe <frontend> --manifest <manifest> [--system snes] [--move] [--apply]
Dry run by default.
"""
import argparse
import glob
import json
import os
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
ROM_EXT = {".zip", ".7z", ".chd", ".iso", ".cue", ".bin", ".rvz", ".wbfs", ".gcz", ".nsp", ".xci", ".3ds", ".cia", ".cso",
           ".pbp", ".nes", ".sfc", ".smc", ".gb", ".gbc", ".gba", ".nds", ".md", ".gen", ".sms", ".gg", ".pce", ".a26",
           ".n64", ".z64", ".v64", ".wux", ".wua", ".rpx", ".xex", ".d64", ".adf", ".lha", ".cdi", ".gdi", ".m3u", ".dsk"}


def games_in(d):
    try:
        return [f for f in os.listdir(d) if os.path.splitext(f)[1].lower() in ROM_EXT]
    except OSError:
        return []


def link_dir(src, dst):
    import _winapi
    _winapi.CreateJunction(src, dst)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--folder", required=True)
    ap.add_argument("--retrofe", required=True)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--system", help="the system these games are for, when the folder name does not say")
    ap.add_argument("--move", action="store_true")
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args()
    folder = os.path.normpath(a.folder)
    root = os.path.dirname(os.path.normpath(a.manifest))
    if not os.path.isdir(folder):
        print("import: %s is not a folder" % folder); return
    cat = json.load(open(os.path.join(HERE, "emulators", "catalog.json"), encoding="utf-8"))
    exes = {x.lower(): name for name, e in cat["emulators"].items() for x in e["exe"]}
    folder_sys = {}
    for s, names in cat["romFolders"].items():
        if not s.startswith("_"):
            for n in names:
                folder_sys.setdefault(n.lower(), s)

    # what is here
    emus, systems = [], []
    for d in [folder] + [os.path.join(folder, x) for x in os.listdir(folder) if os.path.isdir(os.path.join(folder, x))]:
        for f in os.listdir(d) if os.path.isdir(d) else []:
            if f.lower() in exes:
                emus.append((exes[f.lower()], os.path.join(d, f)))
    if a.system:
        systems.append((a.system, folder))
    elif folder_sys.get(os.path.basename(folder).lower()) and games_in(folder):
        systems.append((folder_sys[os.path.basename(folder).lower()], folder))
    else:
        for x in sorted(os.listdir(folder)):
            p = os.path.join(folder, x)
            s = folder_sys.get(x.lower())
            if s and os.path.isdir(p) and games_in(p):
                systems.append((s, p))
    if not emus and not systems:
        n = len(games_in(folder))
        print("import: nothing recognised in %s%s" % (folder, (" - %d game files: say which system with --system <name> (snes, psx, megadrive ...)" % n) if n else ""))
        return
    for name, exe in emus:
        print("  emulator  %-12s %s" % (name, exe))
    for s, p in systems:
        print("  games     %-12s %5d  %s" % (s, len(games_in(p)), p))
    if not a.apply:
        print("import: dry run - nothing changed (--apply to take it in)"); return

    disc_p = os.path.join(a.manifest, "discovery.json")
    disc = json.load(open(disc_p, encoding="utf-8")) if os.path.exists(disc_p) else {"emulators": [], "systems": {}}
    # emulators: a link in <root>\emulators, recorded with the link's path
    for name, exe in emus:
        d = os.path.dirname(exe)
        target = d if os.path.normcase(d).startswith(os.path.normcase(root) + os.sep) else os.path.join(root, "emulators", os.path.basename(d))
        # a name already taken by another emulator in the tree: this one gets "<name> 2", "<name> 3" ...
        base, k = target, 2
        while target != d and os.path.exists(target) and os.path.normcase(os.path.realpath(target)) != os.path.normcase(os.path.realpath(d)):
            target = "%s %d" % (base, k); k += 1
        if target != d and not os.path.exists(target):
            os.makedirs(os.path.dirname(target), exist_ok=True)
            if a.move:
                shutil.move(d, target)
            else:
                link_dir(d, target)
        e = {"emulator": name, "exe": os.path.join(target, os.path.basename(exe)), "version": "", "imported": True}
        if name == "retroarch":
            e["cores"] = sorted(os.path.basename(c)[:-len("_libretro.dll")] for c in glob.glob(os.path.join(target, "cores", "*_libretro.dll")))
        disc["emulators"] = [x for x in disc.get("emulators", []) if os.path.normcase(x["exe"]) != os.path.normcase(e["exe"])] + [e]
        for s in cat["emulators"][name]["systems"]:
            disc.setdefault("systems", {}).setdefault(s, {"emulators": [], "games": []})
            if e["exe"] not in disc["systems"][s]["emulators"]:
                disc["systems"][s]["emulators"].append(e["exe"])
        print("  linked emulator %s -> %s" % (target, d) if target != d else "  emulator already in the tree: %s" % d)
    # games: <root>\library\roms\<system>
    for s, p in systems:
        target = os.path.join(root, "library", "roms", s)
        if os.path.normcase(os.path.realpath(target)) == os.path.normcase(os.path.realpath(p)):
            print("  %s is already the %s library" % (p, s))
        elif not os.path.exists(target):
            os.makedirs(os.path.dirname(target), exist_ok=True)
            if a.move:
                shutil.move(p, target)
            else:
                link_dir(p, target)
            print("  %s %s -> %s" % ("moved" if a.move else "linked", target, p))
        else:
            n, skipped = 0, 0
            for f in os.listdir(p):
                src, dst = os.path.join(p, f), os.path.join(target, f)
                if os.path.exists(dst):
                    continue
                if a.move:
                    shutil.move(src, dst)
                elif os.path.isdir(src):
                    link_dir(src, dst)
                elif os.path.splitdrive(src)[0].lower() == os.path.splitdrive(target)[0].lower():
                    os.link(src, dst)
                else:
                    skipped += 1; continue
                n += 1
            print("  %d games added to %s%s" % (n, target, (" - %d files on another drive not linked (--move takes them)" % skipped) if skipped else ""))
        entry = disc.setdefault("systems", {}).setdefault(s, {"emulators": [], "games": []})
        entry["games"] = [g for g in entry.get("games", []) if os.path.normcase(g["path"]) != os.path.normcase(target)]
        entry["games"].insert(0, {"path": target, "games": len(games_in(target)), "imported": True})
    with open(disc_p + ".tmp", "w", encoding="utf-8") as f:
        json.dump(disc, f, indent=1)
    os.replace(disc_p + ".tmp", disc_p)
    print("import: done - discovery.json updated; the lists, launchers, art and lights come next (Invoke-FirstRun)")


if __name__ == "__main__":
    main()
