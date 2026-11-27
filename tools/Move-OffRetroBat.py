r"""Take everything ArcadeMaster still uses out of the RetroBat folder (James 2026-11-27: "cleanup the remaining retrobat
items"). After New-DirectLaunchers.py no list runs through RetroBat, but the emulators, BIOS, saves, a few game folders
and the bezel art still sit inside it. This moves exactly what is used into ArcadeMaster's own folders and rewrites every
text setting that names the old place:

  <RetroBat>\emulators\<emu>        -> <dest>\emulators\<emu>        (each emulator a launcher or TeknoParrot names)
  <RetroBat>\bios, \saves           -> <dest>\bios, <dest>\saves
  <RetroBat>\roms\<system>          -> <dest>\library\roms\<system>  (lists and TeknoParrot games that still read there)
  <RetroBat>\system\decorations     -> <dest>\decorations            (the bezels)

The moves are renames on the same drive (instant; a different drive is refused). Rewritten: the frontend's launchers and
collection settings, TeknoParrot profiles, <manifest>\emulators\*, discovery.json, and the text configs inside every
moved emulator (logs are left alone). Each changed file is backed up first; <dest>\_off-retrobat\undo.json lists the
moves and --undo renames them back and restores the backups. RetroBat's own program (EmulationStation, RetroBat.exe)
and anything not used stays where it is: deleting RetroBat is a separate step, James's call.

  python tools/Move-OffRetroBat.py --retrobat R:\CP78\RetroBat --dest R:\ArcadeMaster
         --retrofe R:\ArcadeMaster\frontend\LEGENDS-am --manifest R:\ArcadeMaster\manifest [--apply | --undo]
Dry run by default.
"""
import argparse
import json
import os
import re
import shutil
import time

TEXT_EXT = {".cfg", ".ini", ".xml", ".toml", ".json", ".yml", ".yaml", ".conf", ".txt", ".opt"}


def is_log(path):
    n = os.path.basename(path).lower()
    return "log" in n and (n.endswith(".txt") or n.endswith(".log"))


def read_text(p):
    raw = open(p, "rb").read()
    if raw.startswith(b"\xff\xfe") or raw.startswith(b"\xfe\xff"):
        return raw.decode("utf-16"), "utf-16"
    if raw.startswith(b"\xef\xbb\xbf"):
        return raw[3:].decode("utf-8", "surrogateescape"), "utf-8-sig"
    return raw.decode("utf-8", "surrogateescape"), "utf-8"


def write_text(p, t, enc):
    if enc == "utf-16":
        open(p, "wb").write(t.encode("utf-16"))
    elif enc == "utf-8-sig":
        open(p, "wb").write(b"\xef\xbb\xbf" + t.encode("utf-8", "surrogateescape"))
    else:
        open(p, "wb").write(t.encode("utf-8", "surrogateescape"))


def variants(path):
    """The ways a path is written in config files: R:\\a\\b, R:/a/b, R:\\\\a\\\\b (JSON)."""
    b = path.rstrip("\\/")
    return [b, b.replace("\\", "/"), b.replace("\\", "\\\\")]


def rewriter(pairs):
    # longest old path first; case-insensitive; only whole path parts (the next character is a separator, quote, end)
    rules = []
    for old, new in sorted(pairs, key=lambda p: -len(p[0])):
        for ov, nv in zip(variants(old), variants(new)):
            rules.append((re.compile(re.escape(ov) + r'(?=[\\/"\'\s;,|<]|$)', re.I | re.M), nv))

    def run(t):
        n = 0
        for rx, nv in rules:
            t, k = rx.subn(lambda m: nv, t)
            n += k
        return t, n
    return run


def is_link_to(dst, src):
    try:
        return os.path.isdir(dst) and os.path.normcase(os.path.realpath(dst)) == os.path.normcase(os.path.realpath(src)) and os.path.normcase(os.path.normpath(dst)) != os.path.normcase(os.path.realpath(dst))
    except OSError:
        return False


def storage_map(dest, manifest):
    """Every folder link under <dest> (emulators, library\\roms, bios, saves, decorations ...): where it really is.
    Written to <dest>\\STORAGE.md (for people) and <manifest>\\storage-map.json (for tools), so the cabinets' scattered
    folders can be combined later (--mode move, or a copy to one drive). James 2026-11-27: "document them so we can
    combine them all when time comes"."""
    def linked(p):
        try:
            return os.path.normcase(os.path.realpath(p)) != os.path.normcase(os.path.normpath(p))
        except OSError:
            return False
    rows, per_game = [], []
    for top in ("emulators", os.path.join("library", "roms"), "bios", "saves", "decorations"):
        base = os.path.join(dest, top)
        if not os.path.isdir(base):
            continue
        if linked(base):
            rows.append((base, os.path.realpath(base)))
            continue
        for e in os.listdir(base):
            p = os.path.join(base, e)
            if not os.path.isdir(p):
                continue
            if linked(p):
                rows.append((p, os.path.realpath(p)))
            elif top.endswith("roms"):
                n = sum(1 for g in os.listdir(p) if linked(os.path.join(p, g)))
                if n:
                    per_game.append((p, n))
    json.dump({"when": time.strftime("%Y-%m-%d %H:%M:%S"),
               "links": [{"path": p, "real": r} for p, r in rows],
               "perGameLinks": [{"folder": p, "count": n} for p, n in per_game]},
              open(os.path.join(manifest, "storage-map.json"), "w", encoding="utf-8"), indent=1)
    lines = ["# Storage map - %s" % dest, "",
             "Written by tools/Move-OffRetroBat.py on %s. ArcadeMaster uses the paths on the left. Each is a folder" % time.strftime("%Y-%m-%d %H:%M"),
             "link to where the files really are, so the frontend that owns them keeps working. To combine everything in",
             "ArcadeMaster's own folders later: `python tools/Move-OffRetroBat.py ... --mode move --apply` (same drive:",
             "instant), or copy each real folder and put the copy where its link is.", "",
             "| ArcadeMaster path | Real folder |", "|---|---|"]
    lines += ["| %s | %s |" % (p, r) for p, r in rows]
    lines += ["| %s\\* (%d games) | linked one game at a time |" % (p, n) for p, n in per_game]
    open(os.path.join(dest, "STORAGE.md"), "w", encoding="utf-8").write("\n".join(lines) + "\n")
    return len(rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--retrobat", required=True)
    ap.add_argument("--dest", required=True)
    ap.add_argument("--retrofe", required=True)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--mode", choices=["link", "move"], default="link",
                    help="link (default): a folder link (junction) in <dest> to each used folder, RetroBat untouched; move: the folders themselves")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--undo", action="store_true")
    ap.add_argument("--map", action="store_true", help="only (re)write STORAGE.md / storage-map.json")
    a = ap.parse_args()
    if a.map:
        print("storage map: %d links" % storage_map(os.path.normpath(a.dest), a.manifest))
        return
    rb, dest = os.path.normpath(a.retrobat), os.path.normpath(a.dest)
    work = os.path.join(dest, "_off-retrobat")
    undo_file = os.path.join(work, "undo.json")

    if a.undo:
        u = json.load(open(undo_file, encoding="utf-8"))
        for l in u.get("links", []):
            if os.path.isdir(l) and os.path.realpath(l) != os.path.normpath(l):
                os.rmdir(l)                   # removes the link only
            elif os.path.isfile(l) and os.stat(l).st_nlink > 1:
                os.remove(l)                  # a hard link: the other name keeps the file
        for src, dst in reversed(u["moves"]):
            if os.path.exists(dst) and not os.path.exists(src):
                os.makedirs(os.path.dirname(src), exist_ok=True)
                os.rename(dst, src)
                print("back: %s" % src)
        for orig, bak in u["backups"]:
            if os.path.exists(bak):
                shutil.copy2(bak, orig)
        print("undone: %d moves, %d files restored" % (len(u["moves"]), len(u["backups"])))
        return

    if os.path.splitdrive(rb)[0].lower() != os.path.splitdrive(dest)[0].lower():
        print("refused: %s and %s are on different drives (a move would copy hundreds of GB)" % (rb, dest))
        return

    # --- what is used: every RetroBat path named by a launcher, a collection, TeknoParrot or our manifest configs
    scan_files = []
    lw = os.path.join(a.retrofe, "launchers.windows")
    scan_files += [os.path.join(lw, f) for f in os.listdir(lw) if f.endswith(".conf") and not f.startswith("AM_RB_")]
    cols = os.path.join(a.retrofe, "collections")
    for c in os.listdir(cols):
        for f in (os.path.join(cols, c, "settings.conf"),):
            if os.path.exists(f):
                scan_files.append(f)
    tp_profiles = []
    for root in (os.path.join(a.retrofe, "emulators", "TeknoParrot", "UserProfiles"), os.path.join(rb, "emulators", "teknoparrot", "UserProfiles")):
        if os.path.isdir(root):
            tp_profiles += [os.path.join(root, f) for f in os.listdir(root) if f.endswith(".xml")]
    me = os.path.join(a.manifest, "emulators")
    for dp, _, fs in os.walk(me):
        scan_files += [os.path.join(dp, f) for f in fs if f.endswith(".cfg")]
    rbx = re.compile(re.escape(rb) + r"[\\/]+(emulators|roms)[\\/]+([^\\/\"\r\n]+)", re.I)
    used = set()
    for f in scan_files + tp_profiles:
        try:
            t, _ = read_text(f)
        except OSError:
            continue
        for m in rbx.finditer(t):
            used.add((m.group(1).lower(), m.group(2).strip()))
        if re.search(re.escape(rb) + r"[\\/]+system[\\/]+decorations", t, re.I):
            used.add(("system", "decorations"))

    moves = []
    for kind, name in sorted(used):
        src = os.path.join(rb, kind, name)
        if not os.path.exists(src):
            continue
        if kind == "emulators":
            dst = os.path.join(dest, "emulators", name)
        elif kind == "roms":
            dst = os.path.join(dest, "library", "roms", name)
        else:
            dst = os.path.join(dest, "decorations")
        moves.append((src, dst))
    for d in ("bios", "saves"):
        if os.path.isdir(os.path.join(rb, d)):
            moves.append((os.path.join(rb, d), os.path.join(dest, d)))

    print("to link (folder links, RetroBat untouched):" if a.mode == "link" else "to move (rename, same drive):")
    blocked, merges = [], []
    for src, dst in moves:
        busy = os.path.exists(dst) and not is_link_to(dst, src) and (not os.path.isdir(dst) or os.listdir(dst))
        if busy and a.mode == "link" and os.path.isdir(dst) and os.path.isdir(src):
            # the folder is already there with other things in it (library\roms\teknoparrot): a link per entry that it
            # lacks, never over one it has
            print("  MERGE %s -> %s (a link per missing entry)" % (src, dst))
            merges.append((src, dst))
            continue
        print("  %s %s -> %s" % ("SKIP (target not empty)" if busy else "", src, dst))
        if busy:
            blocked.append((src, dst))
    moves = [m for m in moves if m not in blocked and m not in merges]

    # --- the text files to rewrite after the move (their paths AFTER the move)
    def targets():
        out = list(scan_files) + [os.path.join(a.manifest, "discovery.json")]
        rbtp = os.path.join(rb, "emulators", "teknoparrot").lower()
        if a.mode == "move":
            out += [os.path.join(dest, "emulators", "teknoparrot") + p[len(rbtp):] if p.lower().startswith(rbtp) else p for p in tp_profiles]
        else:
            out += [p for p in tp_profiles if not p.lower().startswith(rbtp)]   # RetroBat's own profiles are RetroBat's
        for c in os.listdir(cols):
            ld = os.path.join(cols, c, "launchers")
            if os.path.isdir(ld):
                out += [os.path.join(ld, f) for f in os.listdir(ld)]
        for src, dst in (moves if a.mode == "move" else []):
            if "\\emulators\\" in dst.lower() or dst.lower().endswith("\\emulators"):
                for dp, _, fs in os.walk(dst if a.apply else src):
                    for f in fs:
                        p = os.path.join(dp, f)
                        if os.path.splitext(f)[1].lower() in TEXT_EXT and not is_log(p) and os.path.getsize(p) < 8 * 1024 * 1024:
                            out.append(p)
        return sorted(set(out))

    run = rewriter(moves + merges)
    if not a.apply:
        n_files = n_refs = 0
        for p in targets():
            try:
                t, _ = read_text(p)
            except (OSError, UnicodeError):
                continue
            _, k = run(t)
            if k:
                n_files += 1; n_refs += k
        print("would rewrite %d references in %d files. Dry run - add --apply" % (n_refs, n_files))
        return

    os.makedirs(work, exist_ok=True)
    undo = {"when": time.strftime("%Y-%m-%d %H:%M:%S"), "mode": a.mode, "moves": [], "links": [], "backups": []}
    if os.path.exists(undo_file):            # a second run (link, then move) adds to the first one's undo
        old = json.load(open(undo_file, encoding="utf-8"))
        for k in ("moves", "links", "backups"):
            undo[k] = old.get(k, []) + undo[k]
    import _winapi
    for src, dst in moves:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if a.mode == "link":
            if is_link_to(dst, src):
                continue
            if os.path.isdir(dst) and not os.listdir(dst):
                os.rmdir(dst)
            _winapi.CreateJunction(src, dst)
            undo["links"].append(dst)
        else:
            if is_link_to(dst, src):
                os.rmdir(dst)                 # the link from --mode link: the real folder takes its place
            if os.path.isdir(dst) and not os.listdir(dst):
                os.rmdir(dst)
            os.rename(src, dst)
            undo["moves"].append((src, dst))
        json.dump(undo, open(undo_file, "w", encoding="utf-8"), indent=1)
    for src, dst in merges:
        n = 0
        for e in os.listdir(src):
            s, d = os.path.join(src, e), os.path.join(dst, e)
            if os.path.exists(d):
                continue
            if os.path.isdir(s):
                _winapi.CreateJunction(s, d)
            else:
                os.link(s, d)                 # a file: a hard link (same drive)
            undo["links"].append(d); n += 1
        print("merged %s: %d links" % (dst, n))
    bak = os.path.join(work, "backup")
    n_files = n_refs = 0
    for p in targets():
        try:
            t, enc = read_text(p)
        except (OSError, UnicodeError):
            continue
        t2, k = run(t)
        if not k:
            continue
        b = os.path.join(bak, os.path.splitdrive(p)[1].lstrip("\\/"))
        os.makedirs(os.path.dirname(b), exist_ok=True)
        if not os.path.exists(b):
            shutil.copy2(p, b)
        undo["backups"].append((p, b))
        write_text(p, t2, enc)
        n_files += 1; n_refs += k
    json.dump(undo, open(undo_file, "w", encoding="utf-8"), indent=1)
    print("storage map: %d links -> %s\\STORAGE.md, %s\\storage-map.json" % (storage_map(dest, a.manifest), dest, a.manifest))
    print(("linked" if a.mode == "link" else "moved") + " %d folders, rewrote %d references in %d files; undo: %s --undo" % (len(moves), n_refs, n_files, __file__))


if __name__ == "__main__":
    main()
