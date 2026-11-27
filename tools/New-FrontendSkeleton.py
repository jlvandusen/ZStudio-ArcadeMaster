r"""A clean ArcadeMaster frontend root for a release (docs/BACKLOG 1a: the installer for Daniel and the community).
The cabinets started from a CoinOPS build; a release must not ship CoinOPS's art, videos or programs, so this makes a
RetroFE root from our own parts only:

  <dest>\core\                  the RetroFE fork runtime (a build folder from Update-Cabinet / Build-RetroFE), no .pdb
  <dest>\settings.conf          release/frontend-template/settings.conf, {ROOT} = the install folder
  <dest>\controls.conf          release/frontend-template/controls.conf
  <dest>\layouts\<ours>         the repo's layouts\ (ArcadeMaster, AM-*)
  <dest>\collections\Main\      an empty main menu: Set up this PC (Import-RetroBatSystems) fills it
  <dest>\launchers.windows\, meta\hyperlist\   empty
Game lists, art, launchers and the Tools menu come from the user's own PC at setup. Never ROMs, BIOS, emulators or
game art.
  python tools/New-FrontendSkeleton.py --dest <release>\frontend\ArcadeMaster --runtime <build>\retrofe --root-path "{ROOT}"
"""
import argparse
import os
import shutil

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dest", required=True)
    ap.add_argument("--runtime", required=True, help="a RetroFE build's runtime folder (retrofe.exe + DLLs)")
    ap.add_argument("--root-path", default="{ROOT}", help="the install folder written into settings.conf ({ROOT} = filled at install)")
    a = ap.parse_args()
    if not os.path.exists(os.path.join(a.runtime, "retrofe.exe")):
        raise SystemExit("no retrofe.exe in %s" % a.runtime)
    dest = os.path.normpath(a.dest)
    if os.path.exists(dest) and os.listdir(dest):
        raise SystemExit("%s is not empty - the skeleton is only made into an empty folder" % dest)
    os.makedirs(dest, exist_ok=True)
    # the runtime, without debug symbols (30 MB; they stay with the build)
    shutil.copytree(a.runtime, os.path.join(dest, "core"), ignore=shutil.ignore_patterns("*.pdb", "am-test-build.txt"))
    tpl = os.path.join(REPO, "release", "frontend-template")
    s = open(os.path.join(tpl, "settings.conf"), encoding="utf-8").read().replace("{ROOT}", a.root_path)
    open(os.path.join(dest, "settings.conf"), "w", encoding="utf-8").write(s)
    shutil.copy2(os.path.join(tpl, "controls.conf"), os.path.join(dest, "controls.conf"))
    shutil.copytree(os.path.join(REPO, "layouts"), os.path.join(dest, "layouts"))
    main_dir = os.path.join(dest, "collections", "Main")
    os.makedirs(main_dir)
    open(os.path.join(main_dir, "menu.txt"), "w", encoding="utf-8").write("")
    for d in ("launchers.windows", os.path.join("meta", "hyperlist")):
        os.makedirs(os.path.join(dest, d), exist_ok=True)
    n = sum(len(f) for _, _, f in os.walk(dest))
    mb = sum(os.path.getsize(os.path.join(p, f)) for p, _, fs in os.walk(dest) for f in fs) / 1048576
    print("frontend skeleton: %s (%d files, %.0f MB)" % (dest, n, mb))


if __name__ == "__main__":
    main()
