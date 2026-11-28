r"""System tiles for the maker menus (James 2026-11-26: "how do we sort by systems ... how we navigate through systems",
"do all"). Opening Nintendo / Sega / Sony ... shows each system as a tile: the console's photo, its name and how many
games it has, instead of a bare name.

Pictures come from RetroBat's carbon theme (art/consoles/us/<system>.png, else art/consoles/<system>.png) and its
RELOAD theme (art/consoles, art/logos). A system list is matched to RetroBat's system key by its full name (es_systems,
manifest\systems.json; "(RetroBat)" ignored) or the alias table below. Counts come from manifest\search-index.json.
Writes collections\<maker>\medium_artwork\logo\<system>.png (what the menu shows for that entry).
  python tools/New-SystemTiles.py --retrofe R:/ArcadeMaster/frontend/LEGENDS-am --manifest R:/ArcadeMaster/manifest
"""
import argparse
import json
import os
import re

from PIL import Image, ImageDraw, ImageFilter, ImageFont

S = 2
W, H = 720, 200
ACCENT, TEXT, DIM = (46, 200, 255), (240, 244, 250), (154, 163, 178)
MAKERS = ["Nintendo", "Sega", "Sony", "Microsoft", "Atari", "NEC", "SNK", "Computers", "Arcade Boards", "Other Systems"]
# list names that aren't a RetroBat full name -> RetroBat system key
ALIAS = {
    "super nintendo entertainment system": "snes", "nintendo entertainment system - famicom": "nes", "megadrive - genesis": "megadrive",
    "master system - mark iii": "mastersystem", "neo geo": "neogeo", "neo geo pocket": "ngp", "neo geo pocket color": "ngpc",
    "playstation": "psx", "playstation 2": "ps2", "playstation portable": "psp", "game boy": "gb", "game boy color": "gbc",
    "game boy advance": "gba", "nintendo ds": "nds", "nintendo 64": "n64", "gamecube": "gamecube", "wii": "wii", "wii u": "wiiu",
    "switch": "switch", "xbox": "xbox", "xbox 360": "xbox360", "dreamcast": "dreamcast", "saturn": "saturn", "32x": "sega32x",
    "sg-1000": "sg1000", "game gear": "gamegear", "atari 2600": "atari2600", "atari 5200": "atari5200", "atari 7800": "atari7800",
    "jaguar": "jaguar", "jaguar cd": "jaguarcd", "lynx": "lynx", "pc engine": "pcengine", "pc engine cd": "pcenginecd",
    "supergrafx": "supergrafx", "3do": "3do", "colecovision": "colecovision", "amiga ocsecs": "amiga500", "commodore 64": "c64",
    "zx spectrum": "zxspectrum", "naomi": "naomi", "atomiswave": "atomiswave", "model 2": "model2", "model 3": "model3",
    "final burn": "fbneo", "teknoparrot": "teknoparrot", "ports": "ports",
}


SHORT = {"super nintendo entertainment system": "Super Nintendo", "nintendo entertainment system - famicom": "NES / Famicom",
         "megadrive - genesis": "Genesis / Mega Drive", "master system - mark iii": "Master System",
         "playstation portable": "PSP", "game boy advance": "Game Boy Advance", "teknoparrot": "TeknoParrot"}


def font(size):
    for n in ("seguibl.ttf", "segoeuib.ttf"):
        p = os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Fonts", n)
        if os.path.exists(p):
            return ImageFont.truetype(p, int(size * S))
    return ImageFont.load_default()


def game_counts(manifest):
    """games per list that are really on this cabinet: games.json (only what was found on disk; James 2026-11-27: the
    Wii tile said 1529 games for 13), else the search index (every game a list knows, present or not)"""
    import json
    counts = {}
    try:
        for g in json.load(open(os.path.join(manifest, "games.json"), encoding="utf-8-sig")).get("games", []):
            seen = set()
            for v in (g.get("variants") or {}).values():
                c = (v or {}).get("retrofeCollection")
                if c and (v or {}).get("ok") and c not in seen:
                    seen.add(c)
                    counts[c] = counts.get(c, 0) + 1
    except Exception:
        counts = {}
    # a list the game list does not know (a RetroBat system on the pedestal) keeps the search index's count
    index = {}
    try:
        for g in json.load(open(os.path.join(manifest, "search-index.json"), encoding="utf-8")):
            index[g.get("c", "")] = index.get(g.get("c", ""), 0) + 1
    except Exception:
        pass
    for c, n in index.items():
        counts.setdefault(c, n)
    return counts


def picture(themes, key):
    for rel in (("es-theme-carbon-master", "art", "consoles", "us", key + ".png"), ("es-theme-carbon-master", "art", "consoles", key + ".png"),
                ("es-theme-RELOAD-", "art", "consoles", key + ".png"), ("es-theme-RELOAD-", "art", "logos", key + ".png")):
        p = os.path.join(themes, *rel)
        if os.path.exists(p):
            return p
    return None


def tile(name, games, pic, out):
    im = Image.new("RGBA", (W * S, H * S), (0, 0, 0, 0))
    glow = Image.new("RGBA", im.size, (0, 0, 0, 0))
    ImageDraw.Draw(glow).rounded_rectangle((8 * S, 8 * S, (W - 8) * S, (H - 8) * S), radius=28 * S, fill=ACCENT + (70,))
    im = Image.alpha_composite(im, glow.filter(ImageFilter.GaussianBlur(6 * S)))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((10 * S, 10 * S, (W - 10) * S, (H - 10) * S), radius=26 * S, fill=(12, 14, 22, 225), outline=ACCENT + (220,), width=2 * S)
    x = 34
    if pic:
        try:
            p = Image.open(pic).convert("RGBA")
            box = (230 * S, (H - 44) * S)
            p.thumbnail(box, Image.LANCZOS)
            im.alpha_composite(p, (int(26 * S + (box[0] - p.width) / 2), int((H * S - p.height) / 2)))
            x = 270
        except Exception:
            pass
    d = ImageDraw.Draw(im)
    label = SHORT.get(name.lower(), name).upper()
    size = 46
    while size > 18 and d.textlength(label, font=font(size)) > (W - x - 36) * S:
        size -= 2
    d.text((x * S, (H / 2 - 14) * S), label, font=font(size), fill=TEXT + (255,), anchor="lm")
    d.text((x * S, (H / 2 + 34) * S), ("%d GAMES" % games) if games else "", font=font(20), fill=DIM + (255,), anchor="lm")
    im.resize((W, H), Image.LANCZOS).save(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--retrofe", required=True)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--themes", default=r"R:\CP78\RetroBat\emulationstation\.emulationstation\themes")
    a = ap.parse_args()
    byfull = {}
    sj = os.path.join(a.manifest, "systems.json")
    if os.path.exists(sj):
        for s in json.load(open(sj, encoding="utf-8-sig")).get("systems", []):
            byfull[(s.get("fullname") or "").lower()] = s.get("system")
    counts = {k.lower(): n for k, n in game_counts(a.manifest).items()}
    cols = os.path.join(a.retrofe, "collections")
    made = missing = 0
    for maker in MAKERS:
        mt = os.path.join(cols, maker, "menu.txt")
        if not os.path.exists(mt):
            continue
        out = os.path.join(cols, maker, "medium_artwork", "logo")
        os.makedirs(out, exist_ok=True)
        for system in [l.strip() for l in open(mt) if l.strip()]:
            plain = re.sub(r"\s*\(retrobat\)\s*$", "", system.lower()).strip()
            key = ALIAS.get(plain) or byfull.get(plain)
            pic = picture(a.themes, key) if key else None
            if not pic:   # the system's own art (a build without RetroBat; James 2026-11-27: "we don't want to rely on any other frontends")
                for own in ("device.png", "logo.png"):
                    p = os.path.join(cols, system, "system_artwork", own)
                    if os.path.exists(p):
                        pic = p
                        break
            if not pic:
                missing += 1
            tile(re.sub(r"\s*\(RetroBat\)\s*$", "", system), counts.get(system.lower(), 0), pic, os.path.join(out, system + ".png"))
            made += 1
    print("system tiles: %d (%d without a picture)" % (made, missing))


if __name__ == "__main__":
    main()
