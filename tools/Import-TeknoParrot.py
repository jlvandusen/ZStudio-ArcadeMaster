r"""Every playable TeknoParrot game on this cabinet in the frontend's TeknoParrot list (James 2026-11-26: "get all the
teknoparrot imported please, specifically pokemon and others").

A cabinet collects TeknoParrot installs from several builds (CoinOPS LEGENDS, CORE TYPE R, Forgotten Worlds, RetroBat
...), each with its own UserProfiles (the games configured in THAT install) and its own TeknoParrot version. This tool:
  1. finds every install (TeknoParrotUi.exe) under the roots given;
  2. takes every UserProfiles\<game>.xml whose GamePath exists (relative paths are resolved from the install);
  3. keeps each game once: the light-gun install's own profiles first (set up for the guns), then the newest
     TeknoParrot version;
  4. writes collections\TeknoParrot\roms\<game>.xml (a copy of the profile: the item), one launcher per install
     (launchers.windows\AM_TPX_<install>.conf: TeknoParrotUi --profile=...) and collections\TeknoParrot\launchers\<game>.conf
     naming it, and points the collection at roms\ (settings.conf backed up once to settings.conf.am-tp-backup);
  5. adds missing titles to meta\hyperlist\TeknoParrot.xml from the install's GameProfiles\<game>.xml <GameName>
     (meta.db picks them up at the next Rebuild Menus / -rebuilddatabase).
  python tools/Import-TeknoParrot.py --retrofe R:/ArcadeMaster/frontend/LEGENDS-am [--roots R:/ D:/] [--dry-run]
"""
import argparse
import os
import re
import shutil
import xml.etree.ElementTree as ET


def file_version(exe):
    """TeknoParrotUi's version as a tuple, from the PE version resource (0,0,0,0 when unreadable)"""
    try:
        data = open(exe, "rb").read()
        key = "FileVersion".encode("utf-16-le")
        i = data.find(key)
        if i < 0:
            return (0, 0, 0, 0)
        j = i + len(key)
        while j < len(data) and data[j] == 0:
            j += 1
        raw = data[j:j + 64].decode("utf-16-le", "ignore").split("\x00")[0]
        return tuple(int(p) for p in re.findall(r"\d+", raw)[:4]) or (0, 0, 0, 0)
    except Exception:
        return (0, 0, 0, 0)


def find_installs(roots):
    found = []
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            depth = dirpath[len(root):].count(os.sep)
            if depth > 4:
                dirnames[:] = []
                continue
            dirnames[:] = [d for d in dirnames if not d.startswith(("$", ".")) and d.lower() not in ("roms", "medium_artwork", "windows", "program files", "program files (x86)", "_archive", "library")]
            if "TeknoParrotUi.exe" in filenames and os.path.isdir(os.path.join(dirpath, "UserProfiles")):
                found.append(dirpath)
    return found


def slug(path):
    s = re.sub(r"[^A-Za-z0-9]+", "_", os.path.splitdrive(path)[1]).strip("_")
    return s[-60:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--retrofe", required=True)
    ap.add_argument("--roots", nargs="*", default=["R:\\", "D:\\"])
    ap.add_argument("--installs", nargs="*", help="TeknoParrot folders to use instead of searching the roots (a full drive walk is slow)")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    installs = [i for i in (a.installs or []) if os.path.exists(os.path.join(i, "TeknoParrotUi.exe"))] or find_installs(a.roots)
    info = {i: file_version(os.path.join(i, "TeknoParrotUi.exe")) for i in installs}
    for i in installs:
        print("install %-70s v%s" % (i, ".".join(map(str, info[i]))))

    def rank(inst):
        gun = "lightgun" in inst.lower()
        return (1 if gun else 0, info[inst])

    best = {}
    for inst in installs:
        up = os.path.join(inst, "UserProfiles")
        for f in os.listdir(up):
            if not f.lower().endswith(".xml"):
                continue
            try:
                gp = ET.parse(os.path.join(up, f)).getroot().findtext("GamePath") or ""
            except Exception:
                continue
            if not gp:
                continue
            full = gp if os.path.isabs(gp) else os.path.normpath(os.path.join(inst, gp))
            if not os.path.exists(full):
                continue
            name = f[:-4]
            if name not in best or rank(inst) > rank(best[name]):
                best[name] = inst
    print("playable games: %d" % len(best))
    if a.dry_run:
        for n in sorted(best):
            print("  %-40s %s" % (n, best[n]))
        return

    col = os.path.join(a.retrofe, "collections", "TeknoParrot")
    roms = os.path.join(col, "roms")
    os.makedirs(roms, exist_ok=True)
    os.makedirs(os.path.join(col, "launchers"), exist_ok=True)
    lw = os.path.join(a.retrofe, "launchers.windows")
    made = set()
    for inst in sorted(set(best.values())):
        name = "AM_TPX_" + slug(inst)
        with open(os.path.join(lw, name + ".conf"), "w", newline="\r\n") as f:
            f.write("executable = %s\narguments = --profile=\"%%ITEM_FILENAME%%\"\ncurrentDirectory = %s\n"
                    % (os.path.join(inst, "TeknoParrotUi.exe"), inst))
        made.add(inst)
    # this tool's own items: earlier runs' are refreshed, other files in roms\ are left alone
    own = os.path.join(col, "am-teknoparrot.txt")
    old = set(open(own).read().split()) if os.path.exists(own) else set()
    for n in old - set(best):
        for p in (os.path.join(roms, n + ".xml"), os.path.join(col, "launchers", n + ".conf")):
            if os.path.exists(p):
                os.remove(p)
    for n, inst in best.items():
        shutil.copyfile(os.path.join(inst, "UserProfiles", n + ".xml"), os.path.join(roms, n + ".xml"))
        with open(os.path.join(col, "launchers", n + ".conf"), "w") as f:
            f.write("AM_TPX_" + slug(inst))
    open(own, "w").write("\n".join(sorted(best)) + "\n")

    sc = os.path.join(col, "settings.conf")
    if os.path.exists(sc) and not os.path.exists(sc + ".am-tp-backup"):
        shutil.copyfile(sc, sc + ".am-tp-backup")
    lines = open(sc).read().splitlines() if os.path.exists(sc) else []
    keep = [l for l in lines if not re.match(r"\s*(list\.path|list\.extensions|list\.includeMissingItems|launcher)\s*=", l)]
    first = "AM_TPX_" + slug(sorted(made)[0]) if made else "TeknoParrot"
    keep += ["list.path = %BASE_ITEM_PATH%\\%ITEM_COLLECTION_NAME%\\roms", "list.extensions = xml",
             "list.includeMissingItems = false", "launcher = " + first]
    open(sc, "w", newline="\r\n").write("\n".join(keep) + "\n")

    # titles
    hl = os.path.join(a.retrofe, "meta", "hyperlist", "TeknoParrot.xml")
    have = set()
    tree = None
    if os.path.exists(hl):
        try:
            tree = ET.parse(hl)
            have = {g.get("name", "").lower() for g in tree.getroot().iter("game")}
        except Exception:
            tree = None
    if tree is None:
        tree = ET.ElementTree(ET.Element("menu"))
    added = 0
    for n, inst in sorted(best.items()):
        if n.lower() in have:
            continue
        title = n
        gpf = os.path.join(inst, "GameProfiles", n + ".xml")
        if os.path.exists(gpf):
            try:
                title = ET.parse(gpf).getroot().findtext("GameName") or n
            except Exception:
                pass
        g = ET.SubElement(tree.getroot(), "game", {"name": n})
        ET.SubElement(g, "description").text = title
        ET.SubElement(g, "manufacturer").text = ""
        ET.SubElement(g, "year").text = ""
        ET.SubElement(g, "genre").text = ""
        added += 1
    if added:
        if os.path.exists(hl) and not os.path.exists(hl + ".am-tp-backup"):
            shutil.copyfile(hl, hl + ".am-tp-backup")
        tree.write(hl, encoding="utf-8", xml_declaration=True)
    print("TeknoParrot list: %d games, %d launchers, %d titles added (meta.db at the next Rebuild Menus)" % (len(best), len(made), added))


if __name__ == "__main__":
    main()
