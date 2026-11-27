r"""Hero art for the main menu entries: a sharp themed backdrop, a character and the consoles, per entry.

James, 2026-11-27: "Need something better than that ugly dial need some awesome graphics etc and backdrops".
The art comes from the RELOAD theme installed with RetroBat on this cabinet (art\background fanart, art\characters,
art\consoles). It is copied onto the cabinet only (never into the repo or a release package).

For each entry of collections\Main\menu.txt that has art, writes into
<retrofe>\layouts\<layout>\collections\Main\medium_artwork\:
  am_hero_bg\<entry>.jpg         the backdrop, 1920x1080
  am_hero_char\<entry>.png       the character (at most 1100 px high)
  am_hero_console1..3\<entry>.png  up to three consoles; the layout fades between them (a maker's line-up)
  am_spinner\<entry>.png         blank: the main menu's dial is not drawn over an entry with hero art
An entry without art keeps the old look. Only redraws what changed (cheap at every boot).
  python tools/New-MenuHeroArt.py --retrofe R:/ArcadeMaster/frontend/LEGENDS-am [--theme <RELOAD art dir>] [--force]
"""
import argparse
import os

from PIL import Image

# entry -> (backdrop / character key, [consoles in order]). Keys are RELOAD file names without extension.
HEROES = {
    "Arcade": ("arcade", ["arcade", "mame", "neogeo"]),
    "Arcades": ("arcades", ["mame", "arcade", "fbneo"]),
    "Arcade Boards": ("model3", ["model3", "naomi", "teknoparrot"]),
    "Nintendo": ("snes", ["nes", "snes", "n64", "gc", "wii", "switch"]),
    "Sega": ("megadrive", ["megadrive", "saturn", "dreamcast"]),
    "Sony": ("psx", ["psx", "ps2", "ps3"]),
    "Microsoft": ("xbox", ["xbox", "xbox360"]),
    "Atari": ("atari2600", ["atari2600"]),
    "NEC": ("pcengine", ["pcengine", "pcenginecd"]),
    "SNK": ("neogeo", ["neogeo", "neogeocd", "neogeopocketcolor"]),
    "Computers": ("amiga", ["c64", "amiga500", "amiga1200"]),
    "Recently Played": ("auto-lastplayed", ["auto-lastplayed"]),
    "Favorites": ("auto-favorites", ["auto-favorites"]),
    "Racing": ("auto-racedriving", ["auto-wheel"]),
    "Light Guns": ("auto-lightgun", ["auto-lightgun"]),
    "Lightgun": ("auto-lightgun", ["auto-lightgun"]),
    "Other Systems": ("collections", ["3do", "neogeopocketcolor"]),
}
# the character show per entry (James 2026-11-27: "rotate chara ... stop and then wave ... slide off and another char
# arrives", "maybe 20+ per system or menu item"): RELOAD characters\<key>.png, in this order; missing keys are skipped
CAST = {
    "Arcade": ["arcade", "streetfighter", "mame", "capcom", "kof", "metalslug", "namco", "finalfight", "konami", "mk",
               "taito", "doubledragon", "tmnt", "midway", "cps2", "samuraishodown", "irem", "dataeast", "toaplan", "cave",
               "fatalfury", "artoffighting", "worldheroes", "technos", "psikyo", "neogeo"],
    "Arcades": ["arcades", "cps1", "cps2", "cps3", "capcom", "snk", "kof", "metalslug", "namco", "konami", "taito",
                "midway", "mk", "sega", "irem", "jaleco", "toaplan", "cave", "psikyo", "seibukaihatsu", "gaelco", "kaneko",
                "nmk", "dataeast", "technos"],
    "Arcade Boards": ["model3", "model2", "naomi", "naomi2", "atomiswave", "chihiro", "hikaru", "triforce", "teknoparrot",
                      "taito type x2", "nesicaxlive", "cps3", "zinc", "namco22", "cps2", "cps1", "neogeo", "igs"],
    "Nintendo": ["nintendo", "mario", "nes", "zelda", "snes", "donkeykong", "n64", "metroid", "gamecube", "pokemon",
                 "wii", "wiiu", "switch", "gb", "gbc", "gba", "nds", "3ds", "virtualboy", "gameandwatch", "famicom", "sfc",
                 "fds", "satellaview"],
    "Sega": ["sega", "sonic", "megadrive", "alexkidd", "mastersystem", "gamegear", "saturn", "dreamcast", "segacd",
             "sega32x", "sg-1000", "genesis", "model2", "model3", "naomi", "sc-3000"],
    "Sony": ["psx", "crashbandicoot", "ps2", "metalgear", "ps3", "residentevil", "psp", "finalfantasy", "psvita",
             "psx-classic", "pspminis"],
    "Microsoft": ["xbox", "xbox360", "windows", "pc", "msx2", "msx1"],
    "Atari": ["atari", "atari2600", "atari5200", "atari7800", "atari800", "atarijaguar", "atarilynx", "atarist"],
    "NEC": ["pcengine", "tg16", "supergrafx", "pce-cd", "tg-cd", "pcfx", "pc88", "pc98"],
    "SNK": ["snk", "neogeo", "kof", "metalslug", "samuraishodown", "fatalfury", "artoffighting", "worldheroes", "neogeocd",
            "ngpc", "ngp", "neogeo-classic", "neogeox"],
    "Computers": ["amiga", "c64", "amiga500", "zxspectrum", "amstradcpc", "amiga1200", "c128", "msx2", "apple2",
                  "atarist", "bbc", "x68000", "fmtowns", "oric", "ti99", "spectravideo", "thomson", "c16", "zx81"],
    "Other Systems": ["3do", "vectrex", "intellivision", "colecovision", "odyssey2", "channelf", "wonderswan",
                      "wonderswancolor", "pokemini", "supervision", "videopac", "pv1000"],
    "Recently Played": ["auto-lastplayed", "auto-favorites", "mario", "sonic", "streetfighter", "pokemon", "zelda",
                        "metalslug", "kof", "megaman", "castlevania", "contra", "bomberman", "tmnt", "mk", "crashbandicoot",
                        "donkeykong", "finalfight", "doubledragon", "dragonball", "metroid", "residentevil"],
}
SLOTS = 24
DEFAULT_THEME =r"R:\CP78\RetroBat\emulationstation\.emulationstation\themes\es-theme-RELOAD-\art"


def find(folder, key, exts):
    for e in exts:
        p = os.path.join(folder, key + e)
        if os.path.exists(p):
            return p
    return None


def fresh(src, dst):
    return os.path.exists(dst) and os.path.getmtime(dst) >= os.path.getmtime(src)


def write_bg(src, dst, force):
    if not force and fresh(src, dst):
        return False
    im = Image.open(src).convert("RGB")
    # cover 1920x1080
    k = max(1920 / im.width, 1080 / im.height)
    im = im.resize((max(1920, round(im.width * k)), max(1080, round(im.height * k))), Image.LANCZOS)
    x, y = (im.width - 1920) // 2, (im.height - 1080) // 2
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    im.crop((x, y, x + 1920, y + 1080)).save(dst, quality=90)
    return True


def write_png(src, dst, max_h, force):
    if not force and fresh(src, dst):
        return False
    im = Image.open(src).convert("RGBA")
    if im.height > max_h:
        im = im.resize((round(im.width * max_h / im.height), max_h), Image.LANCZOS)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    im.save(dst)
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--retrofe", required=True)
    ap.add_argument("--layout", default="ArcadeMaster")
    ap.add_argument("--theme", default=DEFAULT_THEME, help="the RELOAD theme's art folder")
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()
    if not os.path.isdir(a.theme):
        # every cabinet keeps RetroBat somewhere else (R:\CP78\RetroBat, D:\RetroBat, ...): look for the RELOAD theme
        import glob
        pats = []
        for d in "CDEFGHR":
            for base in ("%s:\\RetroBat", "%s:\\*\\RetroBat", "%s:\\*\\*\\RetroBat"):
                pats.append((base % d) + r"\emulationstation\.emulationstation\themes\es-theme-RELOAD*\art")
        for p in pats:
            hits = [h for h in glob.glob(p) if os.path.isdir(os.path.join(h, "characters"))]
            if hits:
                a.theme = hits[0]
                break
    if not os.path.isdir(a.theme):
        print("menu heroes: no RELOAD theme art at %s - main menu keeps its old look" % a.theme)
        return
    menu = os.path.join(a.retrofe, "collections", "Main", "menu.txt")
    entries = [l.strip() for l in open(menu, encoding="utf-8", errors="replace")] if os.path.exists(menu) else list(HEROES)
    out = os.path.join(a.retrofe, "layouts", a.layout, "collections", "Main", "medium_artwork")
    blank = os.path.join(a.retrofe, "layouts", a.layout, "images", "blank.png")
    bgdir, chardir, condir = (os.path.join(a.theme, d) for d in ("background fanart", "characters", "consoles"))
    made, heroes, missing = 0, [], []
    for entry in entries:
        if not entry or entry not in HEROES:
            continue
        key, consoles = HEROES[entry]
        bg = find(bgdir, key, (".jpg", ".png"))
        ch = find(chardir, key, (".png",))
        cons = [p for p in (find(condir, c, (".png",)) for c in consoles) if p]
        if not (bg or ch or cons):
            missing.append(entry)
            continue
        heroes.append(entry)
        if bg:
            made += write_bg(bg, os.path.join(out, "am_hero_bg", entry + ".jpg"), a.force)
        # the cast: SLOTS characters (fewer repeat, so the show never has a gap)
        cast = [p for p in (find(chardir, c, (".png",)) for c in CAST.get(entry, [key])) if p]
        if not cast and ch:
            cast = [ch]
        for i in range(SLOTS if cast else 0):
            made += write_png(cast[i % len(cast)], os.path.join(out, "am_hero_char%d" % (i + 1), entry + ".png"), 900, a.force)
        for i in range(3):   # three slots; fewer consoles repeat, so the fade never shows an empty slot
            if cons:
                made += write_png(cons[i % len(cons)], os.path.join(out, "am_hero_console%d" % (i + 1), entry + ".png"), 700, a.force)
        if os.path.exists(blank):   # no dial over the hero art
            sp = os.path.join(out, "am_spinner", entry + ".png")
            if not os.path.exists(sp):
                os.makedirs(os.path.dirname(sp), exist_ok=True)
                Image.open(blank).save(sp)
                made += 1
    old = os.path.join(out, "am_hero_char")   # the single-character slot of the first version
    if os.path.isdir(old):
        import shutil
        shutil.rmtree(old, ignore_errors=True)
    print("menu heroes: %d entries (%s), %d files written%s" % (len(heroes), ", ".join(heroes), made,
          (", no art for: " + ", ".join(missing)) if missing else ""))


if __name__ == "__main__":
    main()
