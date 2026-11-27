r"""The game index AmPanel's touch-screen search uses (James 2026-11-26: "add a search ... screen type lookup names for
games"). Reads RetroFE's meta.db (read-only) and writes <manifest>\search-index.json:
  [{"n": item name, "t": title, "c": collection, "y": year, "m": manufacturer}, ...]
one entry per game per collection, so AmPanel can search the menu that is open and tell RetroFE "goto <item>".

A game whose title is only its MAME set name ("mutnat") gets MAME's own full name ("Mutation Nation") from
mame -listfull (James 2026-11-27: "we need the correct full name of that game"), cached in <manifest>\mame-titles.json
and refreshed when the MAME exe changes.
  python tools/New-SearchIndex.py --retrofe R:/ArcadeMaster/frontend/LEGENDS-am --manifest R:/ArcadeMaster/manifest
"""
import argparse
import json
import os
import re
import sqlite3
import subprocess


def mame_titles(retrofe, manifest):
    """{set name: full name} from the frontend's MAME (-listfull), cached per MAME exe."""
    exe = None
    for n in ("mame64.exe", "mame.exe"):
        p = os.path.join(retrofe, "emulators", "mame", n)
        if os.path.exists(p):
            exe = p
            break
    if not exe:
        return {}
    cache = os.path.join(manifest, "mame-titles.json")
    stamp = "%s|%d|%d" % (exe, os.path.getsize(exe), int(os.path.getmtime(exe)))
    try:
        c = json.load(open(cache, encoding="utf-8"))
        if c.get("stamp") == stamp:
            return c["titles"]
    except Exception:
        pass
    try:
        out = subprocess.run([exe, "-listfull"], cwd=os.path.dirname(exe), capture_output=True, text=True,
                             encoding="utf-8", errors="replace", timeout=180).stdout
    except Exception:
        return {}
    titles = {}
    for line in out.splitlines():
        m = re.match(r'^(\S+)\s+"(.+)"\s*$', line)
        if m and m.group(1) != "Name:":
            titles[m.group(1).lower()] = m.group(2)
    with open(cache + ".tmp", "w", encoding="utf-8") as f:
        json.dump({"stamp": stamp, "titles": titles}, f, ensure_ascii=False)
    os.replace(cache + ".tmp", cache)
    return titles


def readable(full):
    """'Mutation Nation (NGM-014 ~ NGH-014)' -> 'Mutation Nation'; 'Street Fighter II: The World Warrior (World 910522)'
    keeps everything before the first bracket."""
    return re.sub(r"\s*[\(\[].*$", "", full).strip() or full


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--retrofe", required=True)
    ap.add_argument("--manifest", required=True)
    a = ap.parse_args()
    db = os.path.join(a.retrofe, "meta.db")
    if not os.path.exists(db):
        print("no meta.db at %s - nothing to index" % db)
        return
    mame = mame_titles(a.retrofe, a.manifest)
    c = sqlite3.connect("file:%s?mode=ro" % db.replace("\\", "/"), uri=True)
    out, seen, named = [], set(), 0
    for coll, name, title, year, manu in c.execute("select collectionName, name, title, year, manufacturer from Meta"):
        if not name or (coll, name) in seen:
            continue
        seen.add((coll, name))
        t = title or name
        # only a set name ("mutnat", no space, no lower-case letter after a capital): MAME's full name
        if (t.lower() == name.lower()) and name.lower() in mame:
            t = readable(mame[name.lower()])
            named += 1
        out.append({"n": name, "t": t, "c": coll or "", "y": year or "", "m": manu or ""})
    path = os.path.join(a.manifest, "search-index.json")
    with open(path + ".tmp", "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(path + ".tmp", path)
    print("search-index.json: %d games in %d collections (%d set names given MAME's full name)" % (len(out), len({e["c"] for e in out}), named))


if __name__ == "__main__":
    main()
