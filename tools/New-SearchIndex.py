r"""The game index AmPanel's touch-screen search uses (James 2026-11-26: "add a search ... screen type lookup names for
games"). Reads RetroFE's meta.db (read-only) and writes <manifest>\search-index.json:
  [{"n": item name, "t": title, "c": collection, "y": year, "m": manufacturer}, ...]
one entry per game per collection, so AmPanel can search the menu that is open and tell RetroFE "goto <item>".
  python tools/New-SearchIndex.py --retrofe R:/ArcadeMaster/frontend/LEGENDS-am --manifest R:/ArcadeMaster/manifest
"""
import argparse
import json
import os
import sqlite3


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--retrofe", required=True)
    ap.add_argument("--manifest", required=True)
    a = ap.parse_args()
    db = os.path.join(a.retrofe, "meta.db")
    if not os.path.exists(db):
        print("no meta.db at %s - nothing to index" % db)
        return
    c = sqlite3.connect("file:%s?mode=ro" % db.replace("\\", "/"), uri=True)
    out, seen = [], set()
    for coll, name, title, year, manu in c.execute("select collectionName, name, title, year, manufacturer from Meta"):
        if not name or (coll, name) in seen:
            continue
        seen.add((coll, name))
        out.append({"n": name, "t": title or name, "c": coll or "", "y": year or "", "m": manu or ""})
    path = os.path.join(a.manifest, "search-index.json")
    with open(path + ".tmp", "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(path + ".tmp", path)
    print("search-index.json: %d games in %d collections" % (len(out), len({e["c"] for e in out})))


if __name__ == "__main__":
    main()
