#!/usr/bin/env python3
"""Move-ToLibrary.py - plan-driven mover from the old builds on R: into R:\\ArcadeMaster\\library.

Stdlib only. Dry run by default; --apply really moves. Every move is a rename inside R:
(no copies, no deletes), written to a write-ahead log first and undoable with --rollback.

Game-folder mode (the only move mode so far):
  For each --games folder of --system, the copy in the first build of the system's keeper_order
  that has the folder is the keeper. Every file in it goes to
  <library>\\roms\\<system>\\<Game>\\<same relative path>. The same folder in every other build is
  compared file by file (blake2b, full, streamed): identical files go to
  R:\\_archive\\<path without R:\\>, anything else stays where it is and is reported.
  A game is moved only when every check passes for it (all-or-nothing per game folder).

Never moved, whatever the plan says: media and frontend files (James: "keep the frontends, we want
to borrow their artwork and graphics ideas"). Refused: anything not on R:, any path through a
junction/reparse point, R:\\ArcadeMaster\\frontend, and the plan's pinned_for_E paths.

Usage:
  Move-ToLibrary.py --system teknoparrot --games "Batman,CaladriusAC" [--kinds rom] [--apply]
  Move-ToLibrary.py --rollback R:\\ArcadeMaster\\manifest\\library-moves\\<stamp>-teknoparrot.tsv [--apply]
  Move-ToLibrary.py --backup-configs [--apply]      (step 0: copy path-holding config files)
"""
import argparse, ctypes, datetime, hashlib, json, os, shutil, stat, sys
from ctypes import wintypes

PLAN = r"R:\ArcadeMaster\manifest\library-plan.json"
LIBRARY = r"R:\ArcadeMaster\library"
ARCHIVE = r"R:\_archive"
LOGDIR = r"R:\ArcadeMaster\manifest\library-moves"
BACKUPDIR = r"R:\ArcadeMaster\manifest\library-backup"
FRONTEND = r"R:\ArcadeMaster\frontend"
ALLOWED_KINDS = {"rom", "emu", "bios"}
NEVER_KINDS = {"media", "frontend"}          # hard rule: frontends and their media stay
# folder names that hold frontend art/media anywhere in a path: never moved
MEDIA_DIRS = {"images", "videos", "video", "manuals", "media", "medium_artwork", "decorations",
              "layouts", "layout", "menu", "menus", "themes", "theme", "artwork", "marquee",
              "marquees", "snap", "snaps", "fanart", "downloaded_images", "downloaded_videos",
              "screenshots", "wheel", "logos", "boxart"}
REPARSE = 0x400


def lp(p):
    """Long-path form for file system calls."""
    p = os.path.abspath(p)
    return p if p.startswith("\\\\?\\") else "\\\\?\\" + p


def norm(p):
    return os.path.normcase(os.path.abspath(p))


def under(p, root):
    p, root = norm(p), norm(root).rstrip("\\")
    return p == root or p.startswith(root + "\\")


def is_reparse(p):
    try:
        return bool(os.lstat(lp(p)).st_file_attributes & REPARSE)
    except FileNotFoundError:
        return False


def through_junction(p):
    """True if p or any existing ancestor (below the drive root) is a reparse point."""
    p = os.path.abspath(p)
    while True:
        parent = os.path.dirname(p)
        if parent == p:
            return False
        if is_reparse(p):
            return True
        p = parent


class Guard:
    def __init__(self, pinned, extra_roots=()):
        self.pinned = list(pinned)
        self.dst_roots = list(extra_roots)

    def refuse(self, p, role):
        """Return a reason string if p must not be touched, else None."""
        a = os.path.abspath(p)
        if not a.upper().startswith("R:\\"):
            return f"{role} not on R: ({a})"
        if under(a, FRONTEND):
            return f"{role} under {FRONTEND}"
        for pin in self.pinned:
            if under(a, pin):
                return f"{role} is pinned for E: ({pin})"
        if through_junction(a):
            return f"{role} goes through a junction"
        if role == "dst" and not any(under(a, r) for r in self.dst_roots):
            return f"dst outside library/archive roots ({a})"
        return None


def kind_of(path, game_dir, default):
    """Kind of a file. Frontend media lives OUTSIDE game folders (roms\\<system>\\images, videos,
    manuals, collections\\<C>\\medium_artwork, layouts, ...), so the media/frontend test runs on the
    path down to and including the game folder. Subfolders inside a game folder (a game's own
    'media\\bgm' or 'menu' data) are game files and keep the default kind."""
    a = os.path.abspath(game_dir)
    parts = [x.lower() for x in os.path.splitdrive(a)[1].strip("\\").split("\\")]
    if any(x in MEDIA_DIRS for x in parts):
        return "media"
    if not under(path, a):
        return "media"   # not inside the game folder: never treated as a game file
    return default


def blake(p, buf=8 << 20):
    h = hashlib.blake2b(digest_size=20)
    with open(lp(p), "rb", buffering=0) as f:
        while True:
            b = f.read(buf)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


# --- locked-file probe: exclusive open (share mode 0) fails if anything holds the file -----------
_k32 = ctypes.WinDLL("kernel32", use_last_error=True)
_k32.CreateFileW.restype = wintypes.HANDLE
_k32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID,
                             wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
_k32.CloseHandle.argtypes = [wintypes.HANDLE]
INVALID = wintypes.HANDLE(-1).value


def locked(p):
    h = _k32.CreateFileW(lp(p), 0x80000000 | 0x00010000, 0, None, 3, 0x80, None)  # GENERIC_READ|DELETE, no sharing
    if h == INVALID or h is None:
        return ctypes.get_last_error()
    _k32.CloseHandle(h)
    return 0


def walk_files(root, problems):
    """Yield (abs_path, rel_parts, size) under root without following reparse points."""
    stack = [(root, [])]
    while stack:
        d, parts = stack.pop()
        try:
            it = list(os.scandir(lp(d)))
        except OSError as e:
            problems.append(f"cannot list {d}: {e}")
            continue
        for e in it:
            full = os.path.join(d, e.name)
            st = e.stat(follow_symlinks=False)
            if st.st_file_attributes & REPARSE:
                problems.append(f"reparse point inside game folder: {full}")
                continue
            if e.is_dir(follow_symlinks=False):
                stack.append((full, parts + [e.name]))
            else:
                yield full, parts + [e.name], st.st_size


def find_child(parent, name):
    """Case-insensitive child lookup; returns the real name or None."""
    try:
        for e in os.scandir(lp(parent)):
            if e.name.lower() == name.lower() and e.is_dir(follow_symlinks=False):
                return e.name
    except OSError:
        pass
    return None


def stamp():
    return datetime.datetime.now().strftime("%Y%m%d-%H%M%S")


class Log:
    COLS = ["src", "dst", "size", "hash", "status"]

    def __init__(self, path):
        self.path = path
        os.makedirs(os.path.dirname(path), exist_ok=True)
        new = not os.path.exists(path)
        self.f = open(path, "a", encoding="utf-8", newline="\n")
        if new:
            self.row(*self.COLS)

    def row(self, *vals):
        self.f.write("\t".join("" if v is None else str(v) for v in vals) + "\n")
        self.f.flush()
        os.fsync(self.f.fileno())

    def close(self):
        self.f.close()


def gb(n):
    return f"{n / 1024**3:.2f} GB"


# --------------------------------------------------------------------------------------------------
def plan_games(a, plan):
    sysd = next((s for s in plan["systems"] if s["system"] == a.system), None)
    if not sysd:
        sys.exit(f"system {a.system} not in plan")
    library = a.library_root
    sys_lib = os.path.join(library, "roms", a.system)
    if norm(sysd["library"]) != norm(os.path.join(LIBRARY, "roms", a.system)) and library == LIBRARY:
        sys.exit(f"plan library {sysd['library']} differs from expected layout")
    pinned = plan.get("pinned_for_E", {}).get("paths", [])
    guard = Guard(pinned, [library, a.archive_root])
    kinds = {k.strip() for k in a.kinds.split(",") if k.strip()}
    bad = kinds - ALLOWED_KINDS
    if bad:
        sys.exit(f"kinds {sorted(bad)} are never moved by this tool (allowed: rom, emu, bios)")
    if "rom" not in kinds:
        print("game-folder mode moves rom files only; --kinds has no rom: nothing to do")
        return 0

    # source roots per build, in keeper order; skip roots that are a whole build folder
    roots = []
    for b in sysd["keeper_order"]:
        for r in sysd["source_roots"].get(b, []):
            fr = r["from"]
            if len(norm(fr).rstrip("\\").split("\\")) <= 2:
                print(f"note: source root {fr} is a whole build folder; not used for game lookup")
                continue
            roots.append((b, fr))

    games = [g.strip() for g in a.games.split(",") if g.strip()]
    # plan index for those games: path(lower) -> (action, target, size)
    want = {}
    for b, r in roots:
        for g in games:
            want[norm(os.path.join(r, g)) + "\\"] = g
    planidx = {}
    for grp in plan["groups"]:
        _, size, _, members = grp
        for path, action, target in members:
            pl = norm(path)
            for pre in want:
                if pl.startswith(pre):
                    planidx[pl] = (action, target, size)
                    break
    print(f"plan entries for these games: {len(planidx)}")

    stamp_ = stamp()
    log = None
    totals = dict(lib_files=0, lib_bytes=0, arc_files=0, arc_bytes=0)
    skipped, left = [], []

    for g in games:
        print(f"\n=== {g}")
        if g.lower() in MEDIA_DIRS:
            skipped.append((g, "media/frontend folder name: never moved")); continue
        copies = []  # (build, root, real game folder)
        for b, r in roots:
            real = find_child(r, g)
            if real:
                copies.append((b, r, os.path.join(r, real)))
        if not copies:
            skipped.append((g, "not found in any source root")); continue
        kb, kr, kdir = copies[0]
        if a.keeper and kb != a.keeper:
            skipped.append((g, f"keeper is {kb}, not {a.keeper}")); continue
        reasons = []
        for _, _, d in copies:
            why = guard.refuse(d, "src")
            if why:
                reasons.append(f"{d}: {why}")
        gname = os.path.basename(kdir)
        libdir = os.path.join(sys_lib, gname)
        why = guard.refuse(libdir, "dst")
        if why:
            reasons.append(why)
        if os.path.exists(lp(libdir)):
            reasons.append(f"target already exists: {libdir}")
        problems = []
        kfiles = {}
        for p, parts, size in walk_files(kdir, problems):
            kfiles[os.path.normcase("\\".join(parts))] = (p, parts, size)
        if reasons or problems:
            skipped.append((g, "; ".join(reasons + problems))); continue
        print(f"keeper {kb}: {kdir}  ({len(kfiles)} files, {gb(sum(v[2] for v in kfiles.values()))})")

        # checks on keeper files: kind, plan size/target, lock
        moves = []   # (src, dst, size, hash, what)
        bad = []
        for key, (p, parts, size) in sorted(kfiles.items()):
            k = kind_of(p, kdir, "rom")
            if k in NEVER_KINDS:
                left.append((p, "media inside game folder: stays")); bad.append(f"media file {p}"); continue
            pe = planidx.get(norm(p))
            if pe and pe[2] != size:
                bad.append(f"size changed since plan: {p} plan {pe[2]} now {size}")
            dst = os.path.join(libdir, *parts)
            if pe and pe[0] == "keep" and pe[1] and norm(os.path.join(library, pe[1])) != norm(dst):
                bad.append(f"plan target differs: {p} -> plan {pe[1]}")
            moves.append([p, dst, size, None, "library"])
        # other copies
        others = []
        for b, r, d in copies[1:]:
            ofiles = list(walk_files(d, problems))
            print(f"other copy {b}: {d}  ({len(ofiles)} files)")
            others.append((b, d, ofiles))
        if bad or problems:
            skipped.append((g, "; ".join((bad + problems)[:10]))); continue

        # lock probe on every file we would move
        lk = [p for p, *_ in moves if locked(p)]
        if lk:
            skipped.append((g, f"{len(lk)} locked files, e.g. {lk[0]}")); continue

        # full hash: keeper files
        print("hashing keeper copy ...")
        for m in moves:
            m[3] = blake(m[0])
        kh = {}
        for m in moves:
            rel = os.path.normcase(os.path.relpath(m[1], libdir))
            kh[rel] = (m[2], m[3])
        arc_moves = []
        for b, d, ofiles in others:
            print(f"hashing {b} copy ...")
            for p, parts, size in ofiles:
                rel = os.path.normcase("\\".join(parts))
                if kind_of(p, d, "rom") in NEVER_KINDS:
                    left.append((p, "media: stays")); continue
                k = kh.get(rel)
                if not k:
                    left.append((p, "no file at this path in the keeper: stays")); continue
                if k[0] != size:
                    left.append((p, "differs from keeper (size): stays")); continue
                h = blake(p)
                if h != k[1]:
                    left.append((p, "differs from keeper (hash): stays")); continue
                dst = os.path.join(a.archive_root, os.path.splitdrive(os.path.abspath(p))[1].lstrip("\\"))
                why = guard.refuse(p, "src") or guard.refuse(dst, "dst")
                if why:
                    left.append((p, why)); continue
                if os.path.exists(lp(dst)):
                    left.append((p, f"archive target exists: {dst}")); continue
                if locked(p):
                    left.append((p, "locked: stays")); continue
                arc_moves.append([p, dst, size, h, "archive"])
        lb = sum(m[2] for m in moves); ab = sum(m[2] for m in arc_moves)
        print(f"{g}: {len(moves)} files {gb(lb)} -> {libdir}")
        print(f"{g}: {len(arc_moves)} files {gb(ab)} -> archive; "
              f"{sum(1 for x in left if under(x[0], kdir) or any(under(x[0], d) for _, d, _ in others))} left")
        if a.verbose:
            for m in moves[:5] + arc_moves[:5]:
                print("   ", m[4], m[0], "->", m[1])
        totals["lib_files"] += len(moves); totals["lib_bytes"] += lb
        totals["arc_files"] += len(arc_moves); totals["arc_bytes"] += ab
        if not a.apply:
            continue
        if log is None:
            log = Log(os.path.join(a.log_dir, f"{stamp_}-{a.system}.tsv"))
            print(f"log: {log.path}")
        made = set()
        for src, dst, size, h, what in moves + arc_moves:
            dd = os.path.dirname(dst)
            if dd not in made:
                # log every directory we create so rollback can remove it again if empty
                chain = []
                x = dd
                while not os.path.isdir(lp(x)):
                    chain.append(x); x = os.path.dirname(x)
                for c in reversed(chain):
                    log.row("", c, "", "", "mkdir")
                    os.mkdir(lp(c))
                made.add(dd)
            if os.path.exists(lp(dst)):
                log.row(src, dst, size, h, "skipped-target-exists"); left.append((src, "target appeared")); continue
            st = os.stat(lp(src))
            if st.st_size != size:
                log.row(src, dst, size, h, "skipped-size-changed"); left.append((src, "size changed")); continue
            log.row(src, dst, size, h, "pending")
            try:
                os.rename(lp(src), lp(dst))
            except OSError as e:
                log.row(src, dst, size, h, f"failed:{e.winerror}")
                print(f"STOP: rename failed {src}: {e}")
                log.close()
                return 2
            log.row(src, dst, size, h, "done")
        print(f"{g}: moved")

    print("\n===== summary" + ("" if a.apply else " (DRY RUN - nothing moved)"))
    print(f"into library: {totals['lib_files']} files, {totals['lib_bytes']:,} bytes ({gb(totals['lib_bytes'])})")
    print(f"into archive: {totals['arc_files']} files, {totals['arc_bytes']:,} bytes ({gb(totals['arc_bytes'])})")
    print(f"games skipped: {len(skipped)}")
    for g, why in skipped:
        print(f"  SKIP {g}: {why}")
    print(f"files left behind: {len(left)}")
    for p, why in left[: a.show_left]:
        print(f"  LEFT {p}  [{why}]")
    if len(left) > a.show_left:
        print(f"  ... {len(left) - a.show_left} more")
    if log:
        log.close()
        lf = log.path + ".left.tsv"
        with open(lf, "w", encoding="utf-8") as f:
            f.write("path\treason\n")
            for p, why in left:
                f.write(f"{p}\t{why}\n")
        print(f"\nmove log: {log.path}\nleft-behind list: {lf}")
        print(f'rollback: "{sys.executable}" "{os.path.abspath(__file__)}" --rollback "{log.path}" --apply')
    return 0


# --------------------------------------------------------------------------------------------------
def rollback(a):
    rows = []
    with open(a.rollback, encoding="utf-8") as f:
        hdr = f.readline().rstrip("\n").split("\t")
        if hdr != Log.COLS:
            sys.exit("not a move log")
        for line in f:
            src, dst, size, h, status = line.rstrip("\n").split("\t")
            rows.append((src, dst, size, h, status))
    # final state per (src,dst): last status wins; keep first-seen order
    order, last, dirs = [], {}, []
    for src, dst, size, h, status in rows:
        if status == "mkdir":
            dirs.append(dst); continue
        k = (src, dst)
        if k not in last:
            order.append(k)
        last[k] = (size, h, status)
    todo = []
    for k in order:
        size, h, status = last[k]
        src, dst = k
        if status == "done" or (status == "pending" and os.path.exists(lp(dst)) and not os.path.exists(lp(src))):
            todo.append((src, dst, int(size)))
    print(f"rollback {a.rollback}: {len(todo)} files to move back, {len(dirs)} created dirs"
          + ("" if a.apply else " (DRY RUN)"))
    if not a.apply:
        return 0
    rlog = Log(a.rollback[:-4] + "-rollback.tsv" if a.rollback.endswith(".tsv") else a.rollback + "-rollback.tsv")
    bad = 0
    for src, dst, size in reversed(todo):
        if not (src.upper().startswith("R:\\") and dst.upper().startswith("R:\\")):
            rlog.row(dst, src, size, "", "refused-not-R"); bad += 1; continue
        if not os.path.exists(lp(dst)):
            rlog.row(dst, src, size, "", "missing"); bad += 1; continue
        if os.path.exists(lp(src)):
            rlog.row(dst, src, size, "", "src-occupied"); bad += 1; continue
        os.makedirs(lp(os.path.dirname(src)), exist_ok=True)
        rlog.row(dst, src, size, "", "pending")
        os.rename(lp(dst), lp(src))
        ok = os.stat(lp(src)).st_size == size
        rlog.row(dst, src, size, "", "done" if ok else "SIZE-MISMATCH")
        bad += 0 if ok else 1
    for d in reversed(dirs):   # remove only directories this run created, only when empty
        try:
            os.rmdir(lp(d))
        except OSError:
            pass
    rlog.close()
    print(f"rolled back {len(todo) - bad} files, problems {bad}; log {rlog.path}")
    return 1 if bad else 0


# --------------------------------------------------------------------------------------------------
def backup_configs(a, plan):
    """Step 0: copy small path-holding config files of every build into library-backup\\<stamp>."""
    builds = [b["build"] for b in plan["per_build_breaks"]]
    roots = [os.path.join("R:\\", b) for b in builds] + [os.path.join(FRONTEND, "LEGENDS-am")]
    dest = os.path.join(BACKUPDIR, stamp())
    n = nb = 0
    skipped_junctions = 0

    def pick(parts, name, size):
        low = [x.lower() for x in parts]
        nl = name.lower()
        ext = os.path.splitext(nl)[1]
        if ext == ".conf" and "launchers.windows" in low:
            return size <= 2 << 20
        if nl == "settings.conf":
            return size <= 2 << 20
        if ext == ".xml" and low and low[-1] == "userprofiles":
            return size <= 2 << 20
        tp = any("teknoparrot" in x for x in low)
        if tp and "gameprofiles" not in low and ext in (".xml", ".ini", ".json", ".cfg") and \
                len(low) and "teknoparrot" in low[-1]:
            return size <= 2 << 20          # TeknoParrot install-root config (ParrotData.xml etc.)
        if ext in (".ini", ".cfg") and "emulators" in low:
            return size <= 2 << 20
        if ext == ".bat" and ("collections" in low or "roms" in low):
            return size <= 1 << 20
        return False

    for root in roots:
        if not os.path.isdir(root):
            print(f"missing build: {root}"); continue
        stack = [(root, [])]
        c0 = n
        while stack:
            d, parts = stack.pop()
            try:
                it = list(os.scandir(lp(d)))
            except OSError:
                continue
            for e in it:
                try:
                    st = e.stat(follow_symlinks=False)
                except OSError:
                    continue
                if st.st_file_attributes & REPARSE:
                    skipped_junctions += 1
                    continue
                if e.is_dir(follow_symlinks=False):
                    stack.append((os.path.join(d, e.name), parts + [e.name]))
                elif pick(parts, e.name, st.st_size):
                    src = os.path.join(d, e.name)
                    rel = os.path.splitdrive(src)[1].lstrip("\\")
                    dst = os.path.join(dest, rel)
                    n += 1; nb += st.st_size
                    if a.apply:
                        os.makedirs(lp(os.path.dirname(dst)), exist_ok=True)
                        shutil.copy2(lp(src), lp(dst))
        print(f"{root}: {n - c0} files")
    print(f"backup {'->' if a.apply else '(dry run) would go to'} {dest}: {n} files, {nb:,} bytes; "
          f"{skipped_junctions} junctions/reparse points not followed")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--plan", default=PLAN)
    ap.add_argument("--system")
    ap.add_argument("--games", help="comma-separated top-level game folder names")
    ap.add_argument("--kinds", default="rom,emu,bios")
    ap.add_argument("--keeper", help="only move games whose keeper is this build (e.g. CP78)")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--rollback", metavar="LOG")
    ap.add_argument("--backup-configs", action="store_true")
    ap.add_argument("--library-root", default=LIBRARY)
    ap.add_argument("--archive-root", default=ARCHIVE)
    ap.add_argument("--log-dir", default=LOGDIR)
    ap.add_argument("--show-left", type=int, default=40)
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()
    if a.rollback:
        return rollback(a)
    print(f"loading {a.plan} ...", flush=True)
    with open(a.plan, encoding="utf-8") as f:
        plan = json.load(f)
    if a.backup_configs:
        return backup_configs(a, plan)
    if not a.system or not a.games:
        ap.error("--system and --games are required (game-folder mode)")
    return plan_games(a, plan)


if __name__ == "__main__":
    sys.exit(main())
