r"""Missing game art, found or made (James 2026-11-26: "for any missing title graphics can we try to find and download
and setup the graphics etc, if it can't use the system image").

For every game in the system lists (the maker menus' systems):
  cover  medium_artwork\cover\<item>.png   - box art from the libretro thumbnail library
         (github.com/libretro-thumbnails/<system>/Named_Boxarts/<name>.png - free, public, by No-Intro name)
  logo   medium_artwork\logo\<item>.png    - the title graphic the list shows:
         1. a logo of the same game in another build on the drive (R:\<build>\collections\*\medium_artwork\logo)
         2. else a made title card: the game's name with its system's console picture (New-SystemTiles.py art);
            made cards are listed in <manifest>\art-generated.txt and replaced when real art turns up
Downloads one at a time with a short pause. Re-runnable: only what is still missing is fetched.
  python tools/Get-GameArt.py --retrofe R:/ArcadeMaster/frontend/LEGENDS-am --manifest R:/ArcadeMaster/manifest
      [--donors R:/ ] [--no-download] [--limit N]
"""
import argparse
import importlib.util
import json
import os
import re
import time
import urllib.parse
import urllib.request

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("tiles", os.path.join(HERE, "New-SystemTiles.py"))
tiles = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tiles)

LIBRETRO = {
    "snes": "Nintendo - Super Nintendo Entertainment System", "nes": "Nintendo - Nintendo Entertainment System",
    "n64": "Nintendo - Nintendo 64", "gb": "Nintendo - Game Boy", "gbc": "Nintendo - Game Boy Color",
    "gba": "Nintendo - Game Boy Advance", "nds": "Nintendo - Nintendo DS", "gamecube": "Nintendo - GameCube",
    "wii": "Nintendo - Wii", "wiiu": "Nintendo - Wii U", "megadrive": "Sega - Mega Drive - Genesis",
    "mastersystem": "Sega - Master System - Mark III", "gamegear": "Sega - Game Gear", "sega32x": "Sega - 32X",
    "segacd": "Sega - Mega-CD - Sega CD", "saturn": "Sega - Saturn", "dreamcast": "Sega - Dreamcast", "sg1000": "Sega - SG-1000",
    "psx": "Sony - PlayStation", "ps2": "Sony - PlayStation 2", "psp": "Sony - PlayStation Portable", "xbox": "Microsoft - Xbox",
    "atari2600": "Atari - 2600", "atari5200": "Atari - 5200", "atari7800": "Atari - 7800", "jaguar": "Atari - Jaguar",
    "lynx": "Atari - Lynx", "atari800": "Atari - 8-bit", "pcengine": "NEC - PC Engine - TurboGrafx 16",
    "pcenginecd": "NEC - PC Engine CD - TurboGrafx-CD", "supergrafx": "NEC - PC Engine SuperGrafx",
    "ngp": "SNK - Neo Geo Pocket", "ngpc": "SNK - Neo Geo Pocket Color", "neogeocd": "SNK - Neo Geo CD",
    "c64": "Commodore - 64", "amiga500": "Commodore - Amiga", "zxspectrum": "Sinclair - ZX Spectrum",
    "amstradcpc": "Amstrad - CPC", "msx": "Microsoft - MSX", "msx2": "Microsoft - MSX2", "3do": "The 3DO Company - 3DO",
    "colecovision": "Coleco - ColecoVision",
}
EXTRA_ALIAS = {"atari 800": "atari800", "neo geo cd": "neogeocd", "amstrad cpc": "amstradcpc", "msx": "msx", "msx2": "msx2"}
IMG = (".png", ".jpg", ".jpeg")


def safe(name):
    """libretro's file names: &*/:`<>?\\| become _"""
    return re.sub(r'[&*/:`<>?\\|"]', "_", name)


def candidates(stem):
    """the item's own name, then without version / DLC / disc tags, then title + first region only"""
    out = [stem]
    s = re.sub(r"\s*\((v[\d.]+|DLC|Rev \w+|Disc \d+|Update|Patched|[^)]*Edition)\)", "", stem, flags=re.I).strip()
    if s and s not in out:
        out.append(s)
    m = re.match(r"^(.*?\((USA|Europe|Japan|World)[^)]*\))", s)
    if m and m.group(1) not in out:
        out.append(m.group(1))
    return out


def list_items(cols, root, system):
    sc = os.path.join(cols, system, "settings.conf")
    if not os.path.exists(sc):
        return None, []
    txt = open(sc, encoding="latin-1").read()
    m = re.search(r"^\s*list\.path\s*=\s*(.+)$", txt, re.M)
    e = re.search(r"^\s*list\.extensions\s*=\s*(.+)$", txt, re.M)
    path = (m.group(1).strip() if m else os.path.join(cols, system, "roms")).replace("%BASE_ITEM_PATH%", cols).replace("%ITEM_COLLECTION_NAME%", system)
    if not os.path.isabs(path):
        path = os.path.join(root, path)
    exts = {"." + x.strip().lower() for x in (e.group(1) if e else "").split(",") if x.strip()}
    if not os.path.isdir(path):
        return path, []
    return path, sorted({os.path.splitext(f)[0] for f in os.listdir(path) if not exts or os.path.splitext(f)[1].lower() in exts})


def have(folder, item):
    return any(os.path.exists(os.path.join(folder, item + x)) for x in IMG)


def donor_index(roots, skip):
    """item name (lower) -> a logo file from any other build's collections"""
    idx = {}
    for r in roots:
        if not os.path.isdir(r):
            continue
        for build in os.listdir(r):
            cdir = os.path.join(r, build, "collections")
            if not os.path.isdir(cdir) or os.path.abspath(cdir).lower().startswith(os.path.abspath(skip).lower()):
                continue
            for c in os.listdir(cdir):
                ld = os.path.join(cdir, c, "medium_artwork", "logo")
                if os.path.isdir(ld):
                    for f in os.listdir(ld):
                        n, x = os.path.splitext(f)
                        if x.lower() in IMG:
                            idx.setdefault(n.lower(), os.path.join(ld, f))
    return idx


def title_card(title, pic, out):
    W, H, S = 640, 200, 2
    im = Image.new("RGBA", (W * S, H * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    x = 20
    if pic:
        try:
            p = Image.open(pic).convert("RGBA")
            p.thumbnail((170 * S, 150 * S), Image.LANCZOS)
            im.alpha_composite(p, (10 * S, int((H * S - p.height) / 2)))
            x = 200
        except Exception:
            pass
    label = re.sub(r"\s*\([^)]*\)", "", title).strip() or title
    size = 52
    lines = [label]
    while size > 18:
        f = tiles.font(size)
        words, lines, cur = label.split(), [], ""
        for w in words:
            t = (cur + " " + w).strip()
            if d.textlength(t, font=f) <= (W - x - 16) * S:
                cur = t
            else:
                lines.append(cur); cur = w
        lines.append(cur)
        if len(lines) <= 2 and all(d.textlength(l, font=f) <= (W - x - 16) * S for l in lines):
            break
        size -= 2
    f = tiles.font(size)
    lh = size * 1.15 * S
    y0 = (H * S - lh * len(lines)) / 2 + lh / 2
    for i, l in enumerate(lines):
        for dx, dy in ((3, 3), (0, 0)):
            d.text((x * S + dx, y0 + i * lh + dy), l, font=f, fill=((0, 0, 0, 170) if dx else (255, 255, 255, 255)), anchor="lm")
    im = im.resize((W, H), Image.LANCZOS)
    im.save(out)


def fetch(url, dest):
    req = urllib.request.Request(url, headers={"User-Agent": "ArcadeMaster-art/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            data = r.read()
        if len(data) < 500 or not data.startswith(b"\x89PNG"):
            return False
        with open(dest, "wb") as f:
            f.write(data)
        try:   # 800 px on the long side: sharp on the cabinet, a fraction of the full-size file
            im = Image.open(dest); im.load()
            if max(im.size) > 800:
                im.thumbnail((800, 800), Image.LANCZOS); im.save(dest, optimize=True)
        except Exception:
            pass
        return True
    except Exception:
        return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--retrofe", required=True)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--donors", nargs="*", default=["R:\\"])
    ap.add_argument("--themes", default=r"R:\CP78\RetroBat\emulationstation\.emulationstation\themes")
    ap.add_argument("--no-download", action="store_true")
    ap.add_argument("--limit", type=int, default=0, help="stop after this many downloads (0 = all)")
    a = ap.parse_args()
    cols = os.path.join(a.retrofe, "collections")
    byfull = {}
    sj = os.path.join(a.manifest, "systems.json")
    if os.path.exists(sj):
        for s in json.load(open(sj, encoding="utf-8-sig")).get("systems", []):
            byfull[(s.get("fullname") or "").lower()] = s.get("system")
    gen_file = os.path.join(a.manifest, "art-generated.txt")
    generated = set(open(gen_file, encoding="utf-8").read().splitlines()) if os.path.exists(gen_file) else set()
    print("indexing logos in other builds ...", flush=True)
    donors = donor_index(a.donors, a.retrofe)
    print("  %d logos found elsewhere" % len(donors), flush=True)
    stats = {"cover": 0, "cover_miss": 0, "logo_donor": 0, "logo_card": 0}
    downloads = 0
    for maker in tiles.MAKERS:
        mt = os.path.join(cols, maker, "menu.txt")
        if not os.path.exists(mt):
            continue
        for system in [l.strip() for l in open(mt) if l.strip()]:
            plain = re.sub(r"\s*\(retrobat\)\s*$", "", system.lower()).strip()
            key = tiles.ALIAS.get(plain) or EXTRA_ALIAS.get(plain) or byfull.get(plain)
            _, items = list_items(cols, a.retrofe, system)
            if not items:
                continue
            art = os.path.join(cols, system, "medium_artwork")
            cover_dir, logo_dir = os.path.join(art, "cover"), os.path.join(art, "logo")
            os.makedirs(cover_dir, exist_ok=True); os.makedirs(logo_dir, exist_ok=True)
            pic = tiles.picture(a.themes, key) if key else None
            lr = LIBRETRO.get(key or "")
            for it in items:
                tag = system + "\t" + it
                # logo: a real one from another build replaces a made card
                if not have(logo_dir, it) or tag in generated:
                    src = donors.get(it.lower())
                    if src:
                        dst = os.path.join(logo_dir, it + os.path.splitext(src)[1].lower())
                        try:
                            for x in IMG:
                                p = os.path.join(logo_dir, it + x)
                                if os.path.exists(p):
                                    os.remove(p)
                            os.link(src, dst) if os.path.splitdrive(src)[0].lower() == os.path.splitdrive(dst)[0].lower() else __import__("shutil").copyfile(src, dst)
                            generated.discard(tag); stats["logo_donor"] += 1
                        except Exception:
                            pass
                    elif not have(logo_dir, it):
                        title_card(it, pic, os.path.join(logo_dir, it + ".png"))
                        generated.add(tag); stats["logo_card"] += 1
                # cover: the libretro thumbnail library
                if not have(cover_dir, it) and lr and not a.no_download and (not a.limit or downloads < a.limit):
                    got = False
                    for cand in candidates(it):
                        # the libretro-thumbnails repositories on GitHub (thumbnails.libretro.com answered 404)
                        url = "https://raw.githubusercontent.com/libretro-thumbnails/%s/master/Named_Boxarts/%s.png" % (lr.replace(" ", "_"), urllib.parse.quote(safe(cand)))
                        downloads += 1
                        if fetch(url, os.path.join(cover_dir, it + ".png")):
                            got = True
                            break
                        time.sleep(0.15)
                    stats["cover" if got else "cover_miss"] += 1
                    time.sleep(0.25)
            print("  %-42s done (covers %d, missing %d, logos copied %d, cards %d)" % (system, stats["cover"], stats["cover_miss"], stats["logo_donor"], stats["logo_card"]), flush=True)
    with open(gen_file, "w", encoding="utf-8") as f:
        f.write("\n".join(sorted(generated)) + ("\n" if generated else ""))
    print("art: %d covers downloaded, %d not in the library; logos: %d copied from other builds, %d title cards made" %
          (stats["cover"], stats["cover_miss"], stats["logo_donor"], stats["logo_card"]))


if __name__ == "__main__":
    main()
