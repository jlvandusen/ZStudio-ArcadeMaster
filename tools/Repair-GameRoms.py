r"""Self-heal for incomplete ROM sets (James 2026-11-26: "how do we auto heal ... it loaded but errored out ... we need to
ensure the systems load and properly play each game"). Star Wars Trilogy (Model 3) stopped on "FAILED FEEDBACK LEVER
INITIALIZE" because its zip lacked the drive board ROM - another build on the drive had the complete set.

After a game ends AmPanel runs this with the game. It finds the files the emulator missed:
  - Supermodel: its log ("[Error] '<file>' with CRC32 ... not found in '<zip>'")
  - MAME: when the game ended within --short seconds, mame -verifyroms <set> ("<file> ... NOT FOUND")
then looks for the same set (same zip name) in every build on the drive that has those files and nothing less, keeps
the old zip as <zip>.am-bak-incomplete and puts the complete one in its place. Logged in <manifest>\rom-repairs.log.
The zips on the drive are indexed once into <manifest>\rom-index.json (rebuilt with --reindex).
  python tools/Repair-GameRoms.py --retrofe R:/ArcadeMaster/frontend/LEGENDS-am --manifest R:/ArcadeMaster/manifest
      --item swtrilgy --collection "Model 3" [--emulator am_rb_model3] [--ran 12] [--roots R:/]
"""
import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import zipfile

SKIP_DIRS = {"windows", "program files", "program files (x86)", "$recycle.bin", "system volume information", "_archive",
             "medium_artwork", "system_artwork", "videos", "images", "manuals", "snaps", "saves", "shaders"}


def build_index(roots, path):
    idx = {}
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            if dirpath[len(root):].count(os.sep) > 7:
                dirnames[:] = []
                continue
            dirnames[:] = [d for d in dirnames if d.lower() not in SKIP_DIRS and not d.startswith((".", "$"))]
            for f in filenames:
                if f.lower().endswith(".zip"):
                    idx.setdefault(f.lower(), []).append(os.path.join(dirpath, f))
    with open(path + ".tmp", "w", encoding="utf-8") as fh:
        json.dump(idx, fh)
    os.replace(path + ".tmp", path)
    return idx


def rom_file(retrofe, collection, item):
    cols = os.path.join(retrofe, "collections")
    sc = os.path.join(cols, collection, "settings.conf")
    if not os.path.exists(sc):
        return None
    txt = open(sc, encoding="latin-1").read()
    m = re.search(r"^\s*list\.path\s*=\s*(.+)$", txt, re.M)
    path = (m.group(1).strip() if m else os.path.join(cols, collection, "roms")).replace("%BASE_ITEM_PATH%", cols).replace("%ITEM_COLLECTION_NAME%", collection)
    if not os.path.isabs(path):
        path = os.path.join(retrofe, path)
    for ext in (".zip", ".7z"):
        p = os.path.join(path, item + ext)
        if os.path.exists(p):
            return p
    return None


def missing_supermodel(log, zip_path):
    if not os.path.exists(log):
        return set()
    out = set()
    for line in open(log, encoding="latin-1", errors="replace"):
        m = re.search(r"\[Error\]\s+'([^']+)' with CRC32 0x[0-9A-Fa-f]+ not found in '([^']+)'", line)
        if m and os.path.normcase(os.path.abspath(m.group(2))) == os.path.normcase(os.path.abspath(zip_path)):
            out.add(m.group(1).lower())
    return out


def missing_mame(mame_exe, item):
    try:
        r = subprocess.run([mame_exe, "-verifyroms", item], cwd=os.path.dirname(mame_exe), capture_output=True, text=True, timeout=120)
    except Exception:
        return set()
    out = set()
    for line in (r.stdout + r.stderr).splitlines():
        m = re.match(r"\s*\S+\s*:\s*(\S+).*NOT FOUND", line)
        if m:
            out.add(m.group(1).lower())
    return out


def names(z):
    try:
        with zipfile.ZipFile(z) as f:
            return {os.path.basename(i.filename).lower() for i in f.infolist() if not i.is_dir()}
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--retrofe", required=True)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--item", required=True)
    ap.add_argument("--collection", default="")
    ap.add_argument("--emulator", default="")
    ap.add_argument("--ran", type=float, default=999, help="seconds the game ran (MAME is only verified after a short run)")
    ap.add_argument("--short", type=float, default=20)
    ap.add_argument("--roots", nargs="*", default=["R:\\"])
    ap.add_argument("--reindex", action="store_true")
    a = ap.parse_args()

    zp = rom_file(a.retrofe, a.collection, a.item) if a.collection else None
    emu = a.emulator.lower()
    missing = set()
    if zp and ("model3" in emu or "supermodel" in emu):
        for log in (r"R:\CP78\RetroBat\emulators\supermodel\Supermodel.log", os.path.join(os.path.dirname(os.path.dirname(zp)), "Supermodel.log")):
            missing |= missing_supermodel(log, zp)
    elif "mame" in emu and a.ran < a.short:
        mame = os.path.join(a.retrofe, "emulators", "MAME", "mame64.exe")
        if os.path.exists(mame):
            missing = missing_mame(mame, a.item)
            if not zp:
                ini = os.path.join(os.path.dirname(mame), "roms", a.item + ".zip")
                zp = ini if os.path.exists(ini) else None
    if not missing:
        print("roms: %s ok" % a.item)
        return
    if not zp:
        print("roms: %s misses %s, but its zip was not found" % (a.item, ", ".join(sorted(missing))))
        return

    ip = os.path.join(a.manifest, "rom-index.json")
    idx = build_index(a.roots, ip) if a.reindex or not os.path.exists(ip) else json.load(open(ip, encoding="utf-8"))
    have = names(zp) or set()
    best = None
    for cand in idx.get(os.path.basename(zp).lower(), []):
        if os.path.normcase(os.path.abspath(cand)) == os.path.normcase(os.path.abspath(zp)) or not os.path.exists(cand):
            continue
        n = names(cand)
        if n and missing <= n and have <= n:
            best = cand
            break
    stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(os.path.join(a.manifest, "rom-repairs.log"), "a", encoding="utf-8") as lg:
        if best:
            if not os.path.exists(zp + ".am-bak-incomplete"):
                shutil.copyfile(zp, zp + ".am-bak-incomplete")
            shutil.copyfile(best, zp)
            msg = "roms: %s was missing %s - replaced with the complete set from %s" % (a.item, ", ".join(sorted(missing)), best)
        else:
            msg = "roms: %s is missing %s - no complete copy on the drive" % (a.item, ", ".join(sorted(missing)))
        lg.write("%s  %s\n" % (stamp, msg))
    print(msg)


if __name__ == "__main__":
    main()
