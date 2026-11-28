r"""The systems inside a maker menu (Nintendo > Game Boy Advance, ...): a controls card and a backdrop for each.

James, 2026-11-27, on the second-level menu: "need to do something about this ... and have something down here",
"maybe control instructions". The game list layout shows <collection>\medium_artwork\am_controls\<item>.png in the
bottom slot (over the panel dial) and am_backdrop\<item>.jpg behind everything. For every system of every maker menu
(collections\<Maker>\menu.txt) this writes into collections\<Maker>\medium_artwork\:
  am_controls\<system>.png   1100x300: the original controller (RELOAD art\controls) and which panel button is which
                             button of that console, per the panel layout in RetroBat's es_input.cfg
  am_backdrop\<system>.jpg   the system's RELOAD backdrop, 1920x1080
The system is found from its collection's launcher (AM_RB_<retrobat system>). RELOAD's art stays on the cabinet.
  python tools/New-SystemCards.py --retrofe R:/ArcadeMaster/frontend/LEGENDS-am [--theme <RELOAD art dir>] [--force]
"""
import argparse
import os
import re
import shutil

from PIL import Image, ImageDraw, ImageFilter

from system_buttons import CHIP, GENERIC, NATIVE, PANEL   # one table with the emulator configs and the lights

DEFAULT_THEME = r"R:\CP78\RetroBat\emulationstation\.emulationstation\themes\es-theme-RELOAD-\art"


def font(px):
    from PIL import ImageFont
    for n in ("seguibl.ttf", "arialbd.ttf"):
        p = os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Fonts", n)
        if os.path.exists(p):
            return ImageFont.truetype(p, px)
    return ImageFont.load_default()


def rgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def find_theme(theme):
    if os.path.isdir(theme):
        return theme
    import glob
    for d in "CDEFGHR":
        for base in ("%s:\\RetroBat", "%s:\\*\\RetroBat", "%s:\\*\\*\\RetroBat"):
            for h in glob.glob((base % d) + r"\emulationstation\.emulationstation\themes\es-theme-RELOAD*\art"):
                if os.path.isdir(os.path.join(h, "controls")):
                    return h
    return None


# a build's own system lists by name (no RetroBat launcher to read the system from): the RetroBat system key, so the
# console's own button names still apply
NAME_KEY = {
    "nintendo entertainment system": "nes", "super nintendo entertainment system": "snes", "nintendo 64": "n64",
    "nintendo gamecube": "gamecube", "nintendo wii": "wii", "nintendo wii u": "wiiu", "nintendo game boy": "gb",
    "nintendo game boy color": "gbc", "nintendo game boy advance": "gba", "sega genesis": "megadrive",
    "sega 32x": "sega32x", "sega saturn": "saturn", "sega dreamcast": "dreamcast", "sega game gear": "gamegear",
    "sony playstation": "psx", "sony playstation 2": "ps2", "sony playstation 3": "ps3", "sony psp": "psp",
    "atari 7800": "atari7800", "atari 2600": "atari2600",
}


def system_key(retrofe, coll):
    sc = os.path.join(retrofe, "collections", coll, "settings.conf")
    if os.path.exists(sc):
        # RetroBat's launcher or our direct one (New-DirectLaunchers.py: AM_DL_<same system>)
        m = re.search(r"^\s*launcher\s*=\s*AM_(?:RB|DL)_(\S+)", open(sc, encoding="latin-1").read(), re.M)
        if m:
            return m.group(1).lower()
    return NAME_KEY.get(coll.lower())


def card(title, controller, key, dst):
    W, H, S = 1100, 300, 2
    im = Image.new("RGBA", (W * S, H * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    # the panel: dark glass with a neon edge (opaque enough to hide the dial behind it)
    d.rounded_rectangle((4 * S, 4 * S, (W - 4) * S, (H - 4) * S), radius=34 * S, fill=(10, 12, 24, 238),
                        outline=(46, 200, 255, 255), width=4 * S)
    x0 = 30 * S
    if controller:
        c = Image.open(controller).convert("RGBA")
        bb = c.getbbox()
        if bb:
            c = c.crop(bb)
        k = min(330 * S / c.width, 240 * S / c.height)
        c = c.resize((max(1, round(c.width * k)), max(1, round(c.height * k))), Image.LANCZOS)
        im.alpha_composite(c, (x0 + (330 * S - c.width) // 2, (H * S - c.height) // 2))
        x0 += 360 * S
    # the title shrinks to fit ("SUPER NINTENDO ENTERTAINMENT SYSTEM" was cut off at 30 px)
    head = "HOW TO PLAY  " + title.upper()
    size = 30
    while size > 16 and d.textlength(head, font=font(size * S)) > W * S - x0 - 30 * S:
        size -= 1
    d.text((x0, (26 + (30 - size) // 2) * S), head, font=font(size * S), fill=(255, 255, 255, 255))
    names = NATIVE.get(key)
    rows = [(panel, (names or GENERIC).get(pad)) for pad, panel in PANEL]
    rows = [(p, n) for p, n in rows if n]
    if not names:
        d.text((x0, 64 * S), "PANEL BUTTONS = A MODERN PAD, BY POSITION", font=font(18 * S), fill=(154, 163, 178, 255))
    # two columns of "chip  name"
    fy, cols, per = 104 * S, 2, (len(rows) + 1) // 2
    colw = (W * S - x0 - 30 * S) // cols
    f = font(26 * S)
    for i, (panel, name) in enumerate(rows):
        cx, cy = x0 + (i // per) * colw, fy + (i % per) * 36 * S
        chip_w = (64 if len(panel) <= 2 else 104) * S
        d.rounded_rectangle((cx, cy, cx + chip_w, cy + 30 * S), radius=15 * S, fill=rgb(CHIP.get(panel, "ffffff")) + (255,))
        d.text((cx + chip_w / 2, cy + 15 * S), panel, font=font(18 * S), fill=(10, 12, 24, 255), anchor="mm")
        d.text((cx + chip_w + 14 * S, cy + 15 * S), name, font=f, fill=(230, 233, 240, 255), anchor="lm")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    im.resize((W, H), Image.LANCZOS).save(dst)


def backdrop(src, dst):
    im = Image.open(src).convert("RGB")
    k = max(1920 / im.width, 1080 / im.height)
    im = im.resize((max(1920, round(im.width * k)), max(1080, round(im.height * k))), Image.LANCZOS)
    x, y = (im.width - 1920) // 2, (im.height - 1080) // 2
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    im.crop((x, y, x + 1920, y + 1080)).save(dst, quality=90)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--retrofe", required=True)
    ap.add_argument("--theme", default=DEFAULT_THEME)
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()
    theme = find_theme(a.theme)
    if not theme:   # a build without RetroBat (James 2026-11-27: "we don't want to rely on any other frontends")
        print("system cards: no RELOAD theme art - each system's own art (system_artwork) is used")
    cols = os.path.join(a.retrofe, "collections")
    menu = os.path.join(cols, "Main", "menu.txt")
    makers = [l.strip() for l in open(menu, encoding="utf-8", errors="replace")] if os.path.exists(menu) else []
    done, sure, lists, marquees = 0, 0, 0, 0
    for maker in makers:
        mt = os.path.join(cols, maker, "menu.txt")
        if not maker or not os.path.exists(mt):
            continue
        art = os.path.join(cols, maker, "medium_artwork")
        for coll in [l.strip() for l in open(mt, encoding="utf-8", errors="replace") if l.strip()]:
            key = system_key(a.retrofe, coll)
            if not key:
                continue
            own = os.path.join(cols, coll, "system_artwork")
            ctrl = os.path.join(theme, "controls", key + ".png") if theme else ""
            if not os.path.exists(ctrl):
                ctrl = os.path.join(own, "device.png")
            title = re.sub(r"\s*\(RetroBat\)", "", coll)
            dst = os.path.join(art, "am_controls", coll + ".png")
            if a.force or not os.path.exists(dst):
                card(title, ctrl if os.path.exists(ctrl) else None, key, dst)
                done += 1
                sure += key in NATIVE
            # the system's own game list shows the same card for every game (RetroFE's "default" fallback in
            # <collection>\medium_artwork\am_controls), not the bare panel dial (James 2026-11-27, Wii U: "missing
            # joystick graphics"). A game's own card, where one exists, still wins.
            gdef = os.path.join(cols, coll, "medium_artwork", "am_controls", "default.png")
            if os.path.exists(dst) and os.path.isdir(os.path.join(cols, coll)) and (a.force or not os.path.exists(gdef)):
                os.makedirs(os.path.dirname(gdef), exist_ok=True)
                shutil.copy2(dst, gdef)
                lists += 1
            bg = os.path.join(theme, "background fanart", key + ".jpg") if theme else ""
            if not os.path.exists(bg):
                bg = os.path.join(own, "fanart.jpg")
            bdst = os.path.join(art, "am_backdrop", coll + ".jpg")
            if os.path.exists(bg) and (a.force or not os.path.exists(bdst)):
                backdrop(bg, bdst)
            # a system has no marquee of its own: its menu tile (the logo, "GAME BOY - 61 GAMES") is its marquee, so a
            # theme that shows marquees (Arcade Hall's marquee stack and cabinet window, Cabinet) is never empty in a
            # maker menu (2026-11-27). A marquee already there is kept.
            logo, mq = os.path.join(art, "logo", coll + ".png"), os.path.join(art, "marquee", coll + ".png")
            if os.path.exists(logo) and not os.path.exists(mq):
                os.makedirs(os.path.dirname(mq), exist_ok=True)
                shutil.copy2(logo, mq)
                marquees += 1
    print("system cards: %d system marquees from their tiles" % marquees)
    print("system cards: %d written (%d with the console's own button names), %d game lists show theirs" % (done, sure, lists))


if __name__ == "__main__":
    main()
