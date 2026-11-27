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

from PIL import Image, ImageDraw, ImageFilter

# RetroBat's keyboard layout for the panel (es_input.cfg, 2026-11-26 "bottom row"): retropad button -> panel button
PANEL = [("b", "B1"), ("a", "B2"), ("r", "B3"), ("r2", "B4"), ("y", "B5"), ("x", "B6"), ("l", "B7"), ("l2", "B8"),
         ("start", "START"), ("select", "COIN")]
# retropad -> the console's own button names, only where the RetroBat default is well known
NATIVE = {
    "nes": {"b": "B", "a": "A", "start": "START", "select": "SELECT"},
    "famicom": {"b": "B", "a": "A", "start": "START", "select": "SELECT"},
    "snes": {"b": "B", "a": "A", "y": "Y", "x": "X", "l": "L", "r": "R", "start": "START", "select": "SELECT"},
    "gb": {"b": "B", "a": "A", "start": "START", "select": "SELECT"},
    "gbc": {"b": "B", "a": "A", "start": "START", "select": "SELECT"},
    "gba": {"b": "B", "a": "A", "l": "L", "r": "R", "start": "START", "select": "SELECT"},
    "nds": {"b": "B", "a": "A", "y": "Y", "x": "X", "l": "L", "r": "R", "start": "START", "select": "SELECT"},
    "3ds": {"b": "B", "a": "A", "y": "Y", "x": "X", "l": "L", "r": "R", "start": "START", "select": "SELECT"},
    "megadrive": {"y": "A", "b": "B", "a": "C", "l": "X", "x": "Y", "r": "Z", "start": "START", "select": "MODE"},
    "sega32x": {"y": "A", "b": "B", "a": "C", "l": "X", "x": "Y", "r": "Z", "start": "START"},
    "segacd": {"y": "A", "b": "B", "a": "C", "l": "X", "x": "Y", "r": "Z", "start": "START"},
    "saturn": {"y": "A", "b": "B", "a": "C", "l": "X", "x": "Y", "r": "Z", "l2": "L", "r2": "R", "start": "START"},
    "mastersystem": {"b": "1", "a": "2", "start": "PAUSE"},
    "gamegear": {"b": "1", "a": "2", "start": "START"},
    "sg-1000": {"b": "1", "a": "2", "start": "PAUSE"},
    "pcengine": {"b": "II", "a": "I", "start": "RUN", "select": "SELECT"},
    "pcenginecd": {"b": "II", "a": "I", "start": "RUN", "select": "SELECT"},
    "neogeo": {"b": "A", "a": "B", "y": "C", "x": "D", "start": "START", "select": "COIN"},
    "neogeocd": {"b": "A", "a": "B", "y": "C", "x": "D", "start": "START", "select": "SELECT"},
    "psx": {"b": "CROSS", "a": "CIRCLE", "y": "SQUARE", "x": "TRIANGLE", "l": "L1", "r": "R1", "l2": "L2", "r2": "R2",
            "start": "START", "select": "SELECT"},
    "ps2": {"b": "CROSS", "a": "CIRCLE", "y": "SQUARE", "x": "TRIANGLE", "l": "L1", "r": "R1", "l2": "L2", "r2": "R2",
            "start": "START", "select": "SELECT"},
    "psp": {"b": "CROSS", "a": "CIRCLE", "y": "SQUARE", "x": "TRIANGLE", "l": "L", "r": "R", "start": "START", "select": "SELECT"},
    "dreamcast": {"b": "A", "a": "B", "y": "X", "x": "Y", "l2": "L", "r2": "R", "start": "START"},
    "atari2600": {"b": "FIRE", "start": "RESET", "select": "SELECT"},
    "c64": {"b": "FIRE", "start": "RUN/STOP"},
    "amiga500": {"b": "FIRE", "a": "FIRE 2"},
}
# a modern pad, for systems without a sure table: the button by its place
GENERIC = {"b": "BOTTOM", "a": "RIGHT", "y": "LEFT", "x": "TOP", "l": "L", "r": "R", "l2": "L2", "r2": "R2",
           "start": "START", "select": "SELECT"}
CHIP = {"B1": "ff3b3b", "B2": "ffb000", "B3": "2ec8ff", "B4": "3ddc84", "B5": "ff2fa0", "B6": "7b5cff", "B7": "9be7ff",
        "B8": "ffe259", "START": "ffffff", "COIN": "ffe259"}
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


def system_key(retrofe, coll):
    sc = os.path.join(retrofe, "collections", coll, "settings.conf")
    if not os.path.exists(sc):
        return None
    m = re.search(r"^\s*launcher\s*=\s*AM_RB_(\S+)", open(sc, encoding="latin-1").read(), re.M)
    return m.group(1).lower() if m else None


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
    d.text((x0, 26 * S), "HOW TO PLAY  " + title.upper(), font=font(30 * S), fill=(255, 255, 255, 255))
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
    if not theme:
        print("system cards: no RELOAD theme art - skipped")
        return
    cols = os.path.join(a.retrofe, "collections")
    menu = os.path.join(cols, "Main", "menu.txt")
    makers = [l.strip() for l in open(menu, encoding="utf-8", errors="replace")] if os.path.exists(menu) else []
    done, sure = 0, 0
    for maker in makers:
        mt = os.path.join(cols, maker, "menu.txt")
        if not maker or not os.path.exists(mt):
            continue
        art = os.path.join(cols, maker, "medium_artwork")
        for coll in [l.strip() for l in open(mt, encoding="utf-8", errors="replace") if l.strip()]:
            key = system_key(a.retrofe, coll)
            if not key:
                continue
            ctrl = os.path.join(theme, "controls", key + ".png")
            title = re.sub(r"\s*\(RetroBat\)", "", coll)
            dst = os.path.join(art, "am_controls", coll + ".png")
            if a.force or not os.path.exists(dst):
                card(title, ctrl if os.path.exists(ctrl) else None, key, dst)
                done += 1
                sure += key in NATIVE
            bg = os.path.join(theme, "background fanart", key + ".jpg")
            bdst = os.path.join(art, "am_backdrop", coll + ".jpg")
            if os.path.exists(bg) and (a.force or not os.path.exists(bdst)):
                backdrop(bg, bdst)
    print("system cards: %d written (%d with the console's own button names)" % (done, sure))


if __name__ == "__main__":
    main()
