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
import re

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

# captions under the console pictures (same order as HEROES consoles)
CONSOLE_NAMES = {
    "nes": "NES  -  1983", "snes": "SUPER NINTENDO  -  1990", "n64": "NINTENDO 64  -  1996", "gc": "GAMECUBE  -  2001",
    "wii": "WII  -  2006", "switch": "SWITCH  -  2017", "megadrive": "MEGA DRIVE  -  1988", "saturn": "SATURN  -  1994",
    "dreamcast": "DREAMCAST  -  1998", "psx": "PLAYSTATION  -  1994", "ps2": "PLAYSTATION 2  -  2000",
    "ps3": "PLAYSTATION 3  -  2006", "xbox": "XBOX  -  2001", "xbox360": "XBOX 360  -  2005",
    "atari2600": "ATARI 2600  -  1977", "pcengine": "PC ENGINE  -  1987", "pcenginecd": "PC ENGINE CD  -  1988",
    "neogeo": "NEO GEO  -  1990", "neogeocd": "NEO GEO CD  -  1994", "neogeopocketcolor": "NEO GEO POCKET COLOR  -  1999",
    "c64": "COMMODORE 64  -  1982", "amiga500": "AMIGA 500  -  1987", "amiga1200": "AMIGA 1200  -  1992",
    "arcade": "ARCADE CABINETS", "mame": "MAME", "fbneo": "FINAL BURN NEO", "model3": "SEGA MODEL 3  -  1996",
    "naomi": "SEGA NAOMI  -  1998", "teknoparrot": "TEKNOPARROT", "3do": "3DO  -  1993", "auto-lastplayed": "YOUR LAST GAMES",
}
# the line-up along the top (year, name)
TIMELINE = {
    "Nintendo": [(1983, "NES"), (1989, "GAME BOY"), (1990, "SNES"), (1996, "N64"), (2001, "GAMECUBE"), (2001, "GBA"),
                 (2004, "DS"), (2006, "WII"), (2011, "3DS"), (2012, "WII U"), (2017, "SWITCH")],
    "Sega": [(1983, "SG-1000"), (1985, "MASTER SYSTEM"), (1988, "MEGA DRIVE"), (1990, "GAME GEAR"), (1994, "32X"),
             (1994, "SATURN"), (1998, "DREAMCAST")],
    "Sony": [(1994, "PLAYSTATION"), (2000, "PS2"), (2004, "PSP"), (2006, "PS3"), (2011, "PS VITA")],
    "Microsoft": [(2001, "XBOX"), (2005, "XBOX 360")],
    "Atari": [(1977, "2600"), (1979, "800"), (1982, "5200"), (1986, "7800"), (1989, "LYNX"), (1993, "JAGUAR")],
    "NEC": [(1987, "PC ENGINE"), (1988, "PC ENGINE CD"), (1989, "SUPERGRAFX"), (1994, "PC-FX")],
    "SNK": [(1990, "NEO GEO"), (1994, "NEO GEO CD"), (1998, "POCKET"), (1999, "POCKET COLOR")],
    "Computers": [(1977, "APPLE II"), (1982, "C64"), (1982, "ZX SPECTRUM"), (1983, "MSX"), (1984, "AMSTRAD CPC"),
                  (1985, "AMIGA"), (1992, "AMIGA 1200")],
    "Arcade": [(1978, "SPACE INVADERS"), (1980, "PAC-MAN"), (1981, "DONKEY KONG"), (1988, "CPS-1"), (1990, "NEO GEO MVS"),
               (1991, "STREET FIGHTER II"), (1993, "CPS-2"), (1996, "MODEL 3"), (1998, "NAOMI")],
    "Arcades": [(1980, "GOLDEN AGE"), (1988, "CPS-1"), (1990, "NEO GEO"), (1993, "CPS-2"), (1996, "CPS-3")],
    "Arcade Boards": [(1993, "MODEL 2"), (1996, "MODEL 3"), (1998, "NAOMI"), (2003, "ATOMISWAVE"), (2005, "TAITO TYPE X"),
                      (2011, "NESICAXLIVE")],
    "Other Systems": [(1979, "INTELLIVISION"), (1982, "VECTREX"), (1982, "COLECOVISION"), (1993, "3DO"), (1999, "WONDERSWAN")],
}
# facts that drop in one at a time under the logo strip (James 2026-11-27: "come down and stop then go back up and
# something else about it comes down"). Plain, well-known facts only.
FACTS = {
    "Nintendo": ["NINTENDO STARTED IN 1889 IN KYOTO, MAKING PLAYING CARDS",
                 "THE NES BROUGHT HOME GAMING BACK AFTER THE 1983 CRASH",
                 "MARIO FIRST APPEARED IN DONKEY KONG IN 1981"],
    "Sega": ["SEGA BEGAN AS AN ARCADE COMPANY BEFORE MAKING CONSOLES",
             "SONIC THE HEDGEHOG ARRIVED IN 1991 ON THE MEGA DRIVE",
             "THE DREAMCAST WAS SEGA'S LAST HOME CONSOLE"],
    "Sony": ["THE PLAYSTATION BROUGHT CD GAMES TO MILLIONS IN 1994",
             "THE PLAYSTATION 2 IS THE BEST-SELLING HOME CONSOLE EVER"],
    "Microsoft": ["THE FIRST XBOX LAUNCHED IN 2001 WITH HALO",
                  "XBOX 360 BROUGHT ONLINE PLAY TO THE LIVING ROOM"],
    "Atari": ["ATARI MADE PONG IN 1972 AND STARTED THE ARCADE BOOM",
              "THE ATARI 2600 PUT CARTRIDGE GAMES IN MILLIONS OF HOMES"],
    "NEC": ["THE PC ENGINE WAS SMALLER THAN A VHS TAPE",
            "THE PC ENGINE CD WAS THE FIRST CD-ROM GAME SYSTEM"],
    "SNK": ["THE NEO GEO HOME CONSOLE RAN THE SAME GAMES AS THE ARCADE",
            "KING OF FIGHTERS AND METAL SLUG ARE SNK CLASSICS"],
    "Computers": ["THE COMMODORE 64 IS THE BEST-SELLING HOME COMPUTER MODEL",
                  "THE AMIGA WAS FAMOUS FOR ITS GRAPHICS AND SOUND"],
    "Arcade": ["SPACE INVADERS (1978) STARTED THE GOLDEN AGE OF ARCADES",
               "STREET FIGHTER II (1991) STARTED THE FIGHTING GAME BOOM",
               "PAC-MAN WAS MADE TO APPEAL TO EVERYONE, NOT JUST SHOOTER FANS"],
    "Arcades": ["CAPCOM'S CPS BOARDS RAN STREET FIGHTER II AND FINAL FIGHT",
                "NEO GEO MVS CABINETS HELD UP TO SIX GAMES AT ONCE"],
    "Arcade Boards": ["SEGA'S MODEL 3 RAN VIRTUA FIGHTER 3 AND DAYTONA USA 2",
                      "NAOMI WAS BUILT ON DREAMCAST HARDWARE"],
    "Other Systems": ["THE VECTREX DREW ITS GAMES WITH VECTOR LINES",
                      "THE 3DO WAS ONE OF THE FIRST 32-BIT CD CONSOLES"],
    "Recently Played": ["YOUR LATEST GAMES, NEWEST FIRST", "PICK UP WHERE YOU LEFT OFF"],
}
FACT_SLOTS = 6
COLORS = {"Nintendo": "ff3b3b", "Sega": "2e8bff", "Sony": "9be7ff", "Microsoft": "3ddc84", "Atari": "ff6a00",
          "NEC": "ffb000", "SNK": "2ec8ff", "Computers": "7cf0c8", "Arcade": "ff2fa0", "Arcades": "ff2fa0",
          "Arcade Boards": "ff2fa0", "Other Systems": "9aa3b2", "Recently Played": "ffe259"}


def font(px):
    from PIL import ImageFont
    for n in ("seguibl.ttf", "seguibli.ttf", "arialbd.ttf"):
        p = os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Fonts", n)
        if os.path.exists(p):
            return ImageFont.truetype(p, px)
    return ImageFont.load_default()


def neon_text(text, px, color, dst, max_w=1800):
    """White text with a coloured glow on a transparent picture (for captions, the stats line and the timeline)."""
    from PIL import ImageDraw, ImageFilter
    f = font(px)
    while px > 16 and ImageDraw.Draw(Image.new("L", (8, 8))).textlength(text, font=f) > max_w:
        px -= 2
        f = font(px)
    w = int(ImageDraw.Draw(Image.new("L", (8, 8))).textlength(text, font=f)) + px * 2
    h = int(px * 1.9)
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).text((w / 2, h / 2), text, font=f, fill=255, anchor="mm")
    col = tuple(int(color[i:i + 2], 16) for i in (0, 2, 4))
    glow = Image.new("RGBA", (w, h), col + (0,))
    glow.putalpha(mask.filter(ImageFilter.MaxFilter(5)).filter(ImageFilter.GaussianBlur(px / 5)).point(lambda v: v * 200 // 255))
    dark = Image.new("RGBA", (w, h), (8, 6, 20, 0))
    dark.putalpha(mask.filter(ImageFilter.MaxFilter(3)).point(lambda v: v * 230 // 255))
    white = Image.new("RGBA", (w, h), (255, 255, 255, 0))
    white.putalpha(mask)
    im = Image.alpha_composite(Image.alpha_composite(glow, dark), white)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    im.save(dst)


def entry_collections(retrofe, entry):
    """The game lists behind a main-menu entry: a maker's menu.txt, a merged list's .sub files, or the list itself."""
    d = os.path.join(retrofe, "collections", entry)
    menu = os.path.join(d, "menu.txt")
    if os.path.exists(menu):
        return [l.strip() for l in open(menu, encoding="utf-8", errors="replace") if l.strip()]
    subs = [f[:-4] for f in os.listdir(d)] if os.path.isdir(d) else []
    subs = [s for s in subs if os.path.exists(os.path.join(d, s + ".sub"))]
    return subs or [entry]


def logo_strip(retrofe, colls, dst, count=12, height=110):
    """A long strip of game logos from the entry's own lists; the layout scrolls it across the top."""
    import random
    logos = []
    for c in colls:
        ld = os.path.join(retrofe, "collections", c, "medium_artwork", "logo")
        if os.path.isdir(ld):
            logos += [os.path.join(ld, f) for f in os.listdir(ld) if f.lower().endswith(".png")]
    if not logos:
        return False
    random.shuffle(logos)
    tiles = []
    for p in logos[:count * 3]:
        try:
            im = Image.open(p).convert("RGBA")
            bb = im.getbbox()
            if not bb:
                continue
            im = im.crop(bb)
            k = min(height / im.height, 360 / im.width)
            tiles.append(im.resize((max(1, round(im.width * k)), max(1, round(im.height * k))), Image.LANCZOS))
        except Exception:
            continue
        if len(tiles) >= count:
            break
    if not tiles:
        return False
    gap = 90
    strip = Image.new("RGBA", (sum(t.width for t in tiles) + gap * len(tiles), height), (0, 0, 0, 0))
    x = gap // 2
    for t in tiles:
        strip.alpha_composite(t, (x, (height - t.height) // 2))
        x += t.width + gap
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    strip.save(dst)
    return True


def random_title(manifest, colls):
    """A real game from the entry's own lists, for the 'TRY:' fact (titles only, no long rom names)."""
    import json
    import random
    try:
        games = [g for g in json.load(open(os.path.join(manifest, "search-index.json"), encoding="utf-8")) if g.get("c") in colls]
    except Exception:
        return None
    # a real title only (James 2026-11-27: "TRY: MUTNAT" - the MAME set name, not "Mutation Nation"): the title must
    # differ from the item / rom name and read like words; "(Rev A)" style tails are cut off
    def clean(t):
        t = re.sub(r"\s*[\(\[].*$", "", t or "").strip()
        return t

    real = []
    for g in games:
        t, n = clean(g.get("t", "")), (g.get("n") or "").strip()
        if not (4 <= len(t) <= 40) or t.lower() == n.lower() or t.lower() == clean(n).lower():
            continue
        if " " not in t and not any(ch.islower() for ch in t):   # one all-caps word: still a set name
            continue
        real.append(t)
    if not real:
        return None
    return random.choice(real)


def game_counts(manifest):
    import json
    p = os.path.join(manifest, "search-index.json")
    counts = {}
    try:
        for g in json.load(open(p, encoding="utf-8")):
            counts[g.get("c", "")] = counts.get(g.get("c", ""), 0) + 1
    except Exception:
        pass
    return counts
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


def write_fit(src, dst, box_w, box_h, force):
    """Scale (up or down) to fill box_w x box_h keeping the shape: RetroFE's maxWidth / maxHeight never enlarge, and
    RELOAD's console photos are small (James 2026-11-27: "make bigger those symbols on the left")."""
    if not force and fresh(src, dst) and Image.open(dst).size[0] >= min(box_w, 10 ** 6) * 0.98 or \
       (not force and fresh(src, dst) and Image.open(dst).size[1] >= box_h * 0.98):
        return False
    im = Image.open(src).convert("RGBA")
    bb = im.getbbox()   # trim the empty margin first, so the console itself fills the box
    if bb:
        im = im.crop(bb)
    k = min(box_w / im.width, box_h / im.height)
    im = im.resize((max(1, round(im.width * k)), max(1, round(im.height * k))), Image.LANCZOS)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    im.save(dst)
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--retrofe", required=True)
    ap.add_argument("--layout", default="ArcadeMaster")
    ap.add_argument("--theme", default=DEFAULT_THEME, help="the RELOAD theme's art folder")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--manifest", help="for game counts (search-index.json); default <retrofe>\\..\\..\\manifest")
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
    manifest = a.manifest or os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(a.retrofe))), "manifest")
    counts = game_counts(manifest)
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
                made += write_fit(cons[i % len(cons)], os.path.join(out, "am_hero_console%d" % (i + 1), entry + ".png"), 1000, 640, a.force)
        # the info around the pictures (James 2026-11-27: "still feels empty, fill more info on those screens")
        color = COLORS.get(entry, "ff2fa0")
        con_keys = [c for c in consoles if find(condir, c, (".png",))]   # same order as the console slots
        for i in range(3):
            if con_keys:
                ck = con_keys[i % len(con_keys)]
                neon_text(CONSOLE_NAMES.get(ck, ck.upper()), 44, color, os.path.join(out, "am_hero_caption%d" % (i + 1), entry + ".png"), 900)
        colls = entry_collections(a.retrofe, entry)
        n_games = sum(counts.get(c, 0) for c in colls)
        stats = entry.upper()
        if len(colls) > 1 and entry not in ("Recently Played",):
            stats += "  -  %d SYSTEMS" % len(colls)
        if n_games:
            stats += "  -  {:,} GAMES".format(n_games)
        neon_text(stats, 54, color, os.path.join(out, "am_hero_stats", entry + ".png"), 1500)
        # the facts that drop in one at a time: the stats, the biggest system, a game to try, the maker's facts
        facts = [stats]
        sized = sorted(((counts.get(c, 0), c) for c in colls), reverse=True)
        if len(colls) > 1 and sized and sized[0][0]:
            facts.append("MOST GAMES HERE: %s - %s" % (sized[0][1].replace("(RetroBat)", "").strip().upper(), "{:,}".format(sized[0][0])))
        try_title = random_title(manifest, colls)
        if try_title:
            facts.append("TRY: " + try_title.upper())
        facts += FACTS.get(entry, [])
        for i in range(FACT_SLOTS):
            neon_text(facts[i % len(facts)], 46, color, os.path.join(out, "am_hero_fact%d" % (i + 1), entry + ".png"), 1600)
        if entry in TIMELINE:
            neon_text("   >   ".join("%d %s" % (y, n) for y, n in TIMELINE[entry]), 34, color,
                      os.path.join(out, "am_hero_timeline", entry + ".png"), 1840)
        logo_strip(a.retrofe, colls, os.path.join(out, "am_hero_strip", entry + ".png"))
        made += 1
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
