r"""Year, maker, genre and a readable title for game-list entries that have none (2026-11-27: on the pedestal the
Arcades / ArcadesMini / Fight lists - written from MAME set names - had year='' manufacturer='' genre='' and the set name
as the title, so Split Screen's MAKER / YEAR / KIND OF GAME fields and Wall of Games' bottom line stayed empty).

For every <game> in <RetroFE>\meta\hyperlist\*.xml that lacks <year>, <manufacturer>, <genre>, or whose <description>
is just its set name, the gaps are filled from, in order:
  1. the same set name in another list that has it (Final Burn's hyperlist carries all of it for most arcade games)
  2. MAME itself: mame -listxml (description, year, manufacturer), cached in <manifest>\mame-meta.json
  3. catver.ini (genre), when one is found next to MAME or in the frontend
Only empty fields are filled; nothing a list already says is changed. Each changed file is kept once as
<file>.am-bak-meta. Then meta.db is rebuilt (retrofe -rebuilddatabase; not while the frontend is open).
  python tools/Fill-GameMeta.py --retrofe R:\ArcadeMaster\frontend\LEGENDS-am --manifest R:\ArcadeMaster\manifest [--dry-run] [--no-mame]
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET

FIELDS = ("year", "manufacturer", "genre")
SET_NAME = re.compile(r"^[a-z0-9_]+$")
# the lists whose items are MAME / FBNeo arcade sets (the same family Search.cs ranks as arcade, minus TeknoParrot)
ARCADE_LIST = re.compile(r"^(MAME|Final Burn|Arcade|Arcades|ArcadesMini|Fight|Atomiswave|Naomi|Model \d|Neo Geo|Laser Disc|All |CPS|Capcom|Sega|Konami)", re.I)


def find_mame(manifest):
    try:
        d = json.load(open(os.path.join(manifest, "discovery.json"), encoding="utf-8"))
        for e in d.get("emulators", []):
            if e.get("emulator") == "mame" and os.path.exists(e["exe"]):
                return e["exe"]
    except (OSError, ValueError):
        pass
    return None


def mame_meta(manifest, use_mame):
    cache = os.path.join(manifest, "mame-meta.json")
    if os.path.exists(cache):
        return json.load(open(cache, encoding="utf-8"))
    if not use_mame:
        return {}
    exe = find_mame(manifest)
    if not exe:
        return {}
    print("reading MAME's game list (%s -listxml, a minute or two) ..." % os.path.basename(exe))
    p = subprocess.Popen([exe, "-listxml"], cwd=os.path.dirname(exe), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    out = {}
    for ev, el in ET.iterparse(p.stdout, events=("end",)):
        if el.tag == "machine":
            n = el.get("name")
            out[n] = {"description": (el.findtext("description") or "").strip(), "year": (el.findtext("year") or "").strip(),
                      "manufacturer": (el.findtext("manufacturer") or "").strip()}
            el.clear()
    p.wait()
    with open(cache, "w", encoding="utf-8") as f:
        json.dump(out, f, separators=(",", ":"))
    return out


def catver(retrofe, mame_exe):
    dirs = ([os.path.dirname(mame_exe)] if mame_exe else []) + [retrofe]
    for d in dirs:
        for sub in ("", "folders", "ini", "dats", os.path.join("ini", "folders")):
            p = os.path.join(d, sub, "catver.ini")
            if os.path.exists(p):
                genres, sec = {}, None
                for line in open(p, encoding="latin-1"):
                    s = line.strip()
                    if s.startswith("["):
                        sec = s.lower(); continue
                    if sec == "[category]" and "=" in s:
                        k, v = s.split("=", 1); genres[k.strip()] = v.strip()
                return genres
    return {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--retrofe", required=True)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-mame", action="store_true", help="do not run mame -listxml (other lists + cache only)")
    a = ap.parse_args()
    hd = os.path.join(a.retrofe, "meta", "hyperlist")
    files = [os.path.join(hd, f) for f in sorted(os.listdir(hd)) if f.lower().endswith(".xml")]
    trees = {}
    for f in files:
        try:
            trees[f] = ET.parse(f)
        except ET.ParseError:
            # RetroFE reads lists with a bare "&" (MAME's "Game & Watch ..."); escape those and try again
            try:
                t = open(f, encoding="utf-8", errors="replace").read()
                t = re.sub(r"&(?!amp;|lt;|gt;|quot;|apos;|#)", "&amp;", t)
                trees[f] = ET.ElementTree(ET.fromstring(t.encode("utf-8")))
            except ET.ParseError as e:
                print("  skipped %s: %s" % (os.path.basename(f), e))
    # 1. what any list knows per set name
    known = {}
    for t in trees.values():
        for g in t.getroot().iter("game"):
            n = g.get("name")
            if not n:
                continue
            k = known.setdefault(n, {})
            for fld in FIELDS:
                v = (g.findtext(fld) or "").strip()
                if v and fld not in k:
                    k[fld] = v
            desc = (g.findtext("description") or "").strip()
            if desc and desc != n and "description" not in k:
                k["description"] = desc
    mm = mame_meta(a.manifest, not a.no_mame)
    genres = catver(a.retrofe, find_mame(a.manifest))
    total, changed_files = 0, 0
    for f, t in trees.items():
        if not ARCADE_LIST.match(os.path.splitext(os.path.basename(f))[0]):
            continue                    # MSX "1942" is not the arcade 1942; TeknoParrot "abc" is not MAME's abc
        n_here = 0
        for g in t.getroot().iter("game"):
            n = g.get("name")
            # only arcade set names (3wonders, sf2ce): one name is one game everywhere. A console file name
            # ("Tetris (USA)") can be a different game on another system, so it is never filled from another list
            if not n or not SET_NAME.match(n):
                continue
            src = dict(known.get(n, {}))
            for k2, v in (mm.get(n) or {}).items():
                if v and k2 not in src:
                    src[k2] = v
            if "genre" not in src and genres.get(n):
                src["genre"] = genres[n]
            de = g.find("description")
            if src.get("description") and (de is None or not (de.text or "").strip() or (de.text or "").strip() == n):
                if de is None:
                    de = ET.SubElement(g, "description")
                de.text = src["description"]; n_here += 1
            for fld in FIELDS:
                e = g.find(fld)
                if src.get(fld) and (e is None or not (e.text or "").strip()):
                    if e is None:
                        e = ET.SubElement(g, fld)
                    e.text = src[fld]; n_here += 1
        if n_here:
            changed_files += 1; total += n_here
            print("  %-34s %6d fields filled" % (os.path.basename(f), n_here))
            if not a.dry_run:
                if not os.path.exists(f + ".am-bak-meta"):
                    shutil.copy2(f, f + ".am-bak-meta")
                t.write(f, encoding="utf-8", xml_declaration=True)
    print("game meta: %d fields filled in %d lists%s" % (total, changed_files, " (dry run)" if a.dry_run else ""))
    if total and not a.dry_run:
        exe = os.path.join(a.retrofe, "core", "retrofe.exe")
        running = subprocess.run(["tasklist", "/FI", "IMAGENAME eq retrofe.exe"], capture_output=True, text=True).stdout
        if "retrofe.exe" in running.lower():
            print("the frontend is open - meta.db is rebuilt at the next Rebuild Game Menus")
        elif os.path.exists(exe):
            env = dict(os.environ, RETROFE_PATH=a.retrofe)
            subprocess.run([exe, "-rebuilddatabase"], cwd=a.retrofe, env=env, timeout=900, capture_output=True)
            print("meta.db rebuilt")


if __name__ == "__main__":
    main()
