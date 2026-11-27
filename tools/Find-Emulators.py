r"""First run, step 1 (read-only): what is on this PC - every emulator from tools\emulators\catalog.json on the local
drives (RetroBat's emulators folder is just one place among others), RetroArch's cores, and the game folders per system.
James 2026-11-27: "introduce the ampanel to a new environment and have it discover everything and emulators", "not
require retrobat and use their default emulators".

Writes <manifest>\discovery.json and prints a report: per system, the emulators that can run it and the game folders.
Changes nothing. Local fixed drives only (the NAS holds backups); skips Windows, Program Files\WindowsApps, recycle bins.
  python tools/Find-Emulators.py --manifest R:/ArcadeMaster/manifest [--roots R:\ D:\] [--depth 6]
"""
import argparse
import ctypes
import glob
import json
import os
import string
import time

SKIP = {"windows", "$recycle.bin", "system volume information", "windowsapps", "programdata", "appdata", "node_modules",
        ".git", "medium_artwork", "system_artwork", "videos", "images", "manuals", "snaps", "screenshots", "shaders",
        "_archive", "am-bak", "saves", "states"}
ROM_EXT = {".zip", ".7z", ".chd", ".iso", ".cue", ".bin", ".rvz", ".wbfs", ".gcz", ".nsp", ".xci", ".3ds", ".cia", ".cso",
           ".pbp", ".nes", ".sfc", ".smc", ".gb", ".gbc", ".gba", ".nds", ".md", ".gen", ".sms", ".gg", ".pce", ".a26",
           ".n64", ".z64", ".v64", ".wux", ".wua", ".rpx", ".xex", ".d64", ".adf", ".lha", ".cdi", ".gdi", ".m3u", ".dsk"}


def local_drives():
    out = []
    bitmask = ctypes.windll.kernel32.GetLogicalDrives()
    for i, letter in enumerate(string.ascii_uppercase):
        if bitmask & (1 << i):
            root = letter + ":\\"
            if ctypes.windll.kernel32.GetDriveTypeW(root) == 3:   # DRIVE_FIXED: no network, no removable
                out.append(root)
    return out


def file_version(path):
    try:
        size = ctypes.windll.version.GetFileVersionInfoSizeW(path, None)
        if not size:
            return ""
        buf = ctypes.create_string_buffer(size)
        ctypes.windll.version.GetFileVersionInfoW(path, 0, size, buf)
        p, n = ctypes.c_void_p(), ctypes.c_uint()
        if ctypes.windll.version.VerQueryValueW(buf, "\\", ctypes.byref(p), ctypes.byref(n)) and n.value:
            ffi = ctypes.cast(p, ctypes.POINTER(ctypes.c_uint32 * 13)).contents
            ms, ls = ffi[2], ffi[3]
            return "%d.%d.%d.%d" % (ms >> 16, ms & 0xFFFF, ls >> 16, ls & 0xFFFF)
    except Exception:
        pass
    return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--roots", nargs="*")
    ap.add_argument("--depth", type=int, default=6)
    ap.add_argument("--catalog", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "emulators", "catalog.json"))
    a = ap.parse_args()
    cat = json.load(open(a.catalog, encoding="utf-8"))
    emus = cat["emulators"]
    want = {}
    for name, e in emus.items():
        for x in e["exe"]:
            want.setdefault(x.lower(), []).append(name)
    folder_sys = {}
    for sysname, names in cat["romFolders"].items():
        if sysname.startswith("_"):
            continue
        for n in names:
            folder_sys.setdefault(n.lower(), set()).add(sysname)

    t0 = time.time()
    roots = a.roots or local_drives()
    found_emus, rom_dirs = [], {}
    for root in roots:
        base_depth = root.rstrip("\\").count("\\")
        for dirpath, dirnames, filenames in os.walk(root):
            depth = dirpath.rstrip("\\").count("\\") - base_depth
            dirnames[:] = [d for d in dirnames if d.lower() not in SKIP and not d.startswith((".", "$")) and ".am-bak" not in d.lower()]
            if depth >= a.depth:
                dirnames[:] = []
            low = {f.lower(): f for f in filenames}
            for exe_low, names in want.items():
                if exe_low in low:
                    p = os.path.join(dirpath, low[exe_low])
                    for n in names:
                        e = {"emulator": n, "exe": p, "version": file_version(p)}
                        if n == "retroarch":
                            cores = glob.glob(os.path.join(dirpath, "cores", "*_libretro.dll"))
                            e["cores"] = sorted(os.path.basename(c)[:-len("_libretro.dll")] for c in cores)
                        found_emus.append(e)
            # a game folder: its name means a system and it holds game files
            sysnames = folder_sys.get(os.path.basename(dirpath).lower())
            if sysnames:
                games = [f for f in filenames if os.path.splitext(f)[1].lower() in ROM_EXT]
                if games:
                    for s in sysnames:
                        rom_dirs.setdefault(s, []).append({"path": dirpath, "games": len(games)})

    # per system: who can run it, where its games are
    systems = {}
    for e in found_emus:
        for s in emus[e["emulator"]]["systems"]:
            systems.setdefault(s, {"emulators": [], "games": []})["emulators"].append(e["exe"])
    for s, dirs in rom_dirs.items():
        systems.setdefault(s, {"emulators": [], "games": []})["games"] = sorted(dirs, key=lambda d: -d["games"])
    report = {"scanned": roots, "seconds": round(time.time() - t0, 1), "emulators": found_emus, "systems": systems}
    out = os.path.join(a.manifest, "discovery.json")
    with open(out + ".tmp", "w", encoding="utf-8") as f:
        json.dump(report, f, indent=1)
    os.replace(out + ".tmp", out)

    print("discovery: %d emulator installs, %d systems, scanned %s in %.0f s" % (len(found_emus), len(systems), " ".join(roots), report["seconds"]))
    for s in sorted(systems):
        v = systems[s]
        ngames = sum(d["games"] for d in v["games"][:1])
        state = "READY" if v["emulators"] and v["games"] else ("NO GAMES" if v["emulators"] else "NO EMULATOR")
        print("  %-18s %-11s emulators %d   games %5d  %s" % (s, state, len(v["emulators"]), ngames, v["games"][0]["path"] if v["games"] else ""))


if __name__ == "__main__":
    main()
