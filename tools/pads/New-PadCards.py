#!/usr/bin/env python3
r"""
New-PadCards.py - a controls card for playing a console's games with a hand-held controller.

The card is the size the game lists show (1100 x 300, like the wheel and panel cards): on the left the picture of the
controller (tools/pads/New-PadArt.py), with a numbered dot on every button the console uses; on the right the same
numbers with the console's own name for the button and, under it, the name printed on the controller.
"The console's A is your Circle."

What it reads:
  tools/pads/pads.json        each controller family and which of its buttons stands for which emulator button
  tools/system_buttons.py     each console's own button names
  layouts/ArcadeMaster/images/pads/pad_<family>.png + .json    the picture and where its buttons are

  python tools/pads/New-PadCards.py --out <folder> [--systems snes,n64] [--families ps4,snes] [--sheet sheet.png]

Writes <out>/<system>__<family>.png. A pair is skipped when fewer than two of the console's buttons are on that
controller. Only writes into --out.

On a cabinet (--retrofe): the console lists show <collection>/medium_artwork/am_controls/default.png for every game
that has no card of its own (tools/New-SystemCards.py puts the panel's card there).
  --retrofe <frontend> --family ps4     a controller is plugged in: every console list gets that controller's card.
                                        The panel's card is kept beside it as default.panel.png.
  --retrofe <frontend> --panel          the controller is gone: the panel's cards go back.
tools/Set-PadCards.ps1 does this from the controller that is plugged in. Only ever writes those two files per list.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import system_buttons as sb  # noqa: E402

W, H, S = 1100, 300, 2
CARD, CARD2 = (20, 22, 31), (28, 31, 44)
MAGENTA, CYAN, AMBER = (255, 47, 160), (46, 200, 255), (255, 176, 0)
VIOLET, GREEN, RED, ORANGE = (123, 92, 255), (61, 220, 132), (255, 90, 90), (255, 138, 61)
TEXT, DIM = (230, 233, 240), (154, 163, 178)
DOTS = [MAGENTA, CYAN, AMBER, GREEN, VIOLET, ORANGE, (155, 231, 255), RED, (255, 226, 89), (200, 200, 210)]
ORDER = ['b', 'a', 'y', 'x', 'l', 'r', 'l2', 'r2', 'start', 'select']
SYSTEM_NAMES = {'nes': 'NES', 'famicom': 'Famicom', 'snes': 'Super Nintendo', 'gb': 'Game Boy', 'gbc': 'Game Boy Color', 'gba': 'Game Boy Advance',
                'nds': 'Nintendo DS', '3ds': 'Nintendo 3DS', 'n64': 'Nintendo 64', 'wiiu': 'Wii U', 'switch': 'Switch', 'gamecube': 'GameCube',
                'xbox': 'Xbox', 'xbox360': 'Xbox 360', 'megadrive': 'Genesis / Mega Drive', 'sega32x': 'Sega 32X', 'segacd': 'Sega CD',
                'saturn': 'Saturn', 'mastersystem': 'Master System', 'gamegear': 'Game Gear', 'sg-1000': 'SG-1000', 'pcengine': 'TurboGrafx-16',
                'pcenginecd': 'TurboGrafx-CD', 'neogeo': 'Neo Geo', 'neogeocd': 'Neo Geo CD', 'psx': 'PlayStation', 'ps2': 'PlayStation 2',
                'psp': 'PSP', 'dreamcast': 'Dreamcast', 'atari2600': 'Atari 2600', 'c64': 'Commodore 64', 'amiga500': 'Amiga'}


def font(px, bold=True, italic=False):
    names = (['segoeuiz.ttf'] if italic and bold else []) + (['segoeuib.ttf'] if bold else []) + ['segoeui.ttf', 'arial.ttf']
    for n in names:
        p = Path(r'C:\Windows\Fonts') / n
        if p.exists():
            return ImageFont.truetype(str(p), int(px * S))
    return ImageFont.load_default()


def pairs(system: str, fam: dict):
    """[(console's name, controller's name)] for every button of the console this controller has"""
    native = sb.NATIVE.get(system, sb.GENERIC)
    rp = fam.get('retropad', {})
    return [(native[k], rp[k]) for k in ORDER if k in native and k in rp]


def render(system: str, key: str, fam: dict, art_dir: Path) -> Image.Image | None:
    rows = pairs(system, fam)
    if len(rows) < 2:
        return None
    pic = Image.open(art_dir / f'pad_{key}.png').convert('RGBA')
    spots = json.loads((art_dir / f'pad_{key}.json').read_text(encoding='utf-8'))
    im = Image.new('RGBA', (W * S, H * S), (0, 0, 0, 0)); d = ImageDraw.Draw(im)
    d.rounded_rectangle((2 * S, 2 * S, (W - 2) * S, (H - 2) * S), 18 * S, fill=CARD + (245,), outline=MAGENTA + (255,), width=2 * S)
    # the controller, as large as the card allows
    ph = H - 16; pw = int(spots['width'] * ph / spots['height']); px0, py0 = 14, 8
    k = ph / spots['height']
    im.alpha_composite(pic.resize((pw * S, ph * S), Image.LANCZOS), (px0 * S, py0 * S)); d = ImageDraw.Draw(im)
    x_text = px0 + pw + 26
    d.line((x_text - 14) * S if False else ((x_text - 14) * S, 26 * S, (x_text - 14) * S, (H - 26) * S), fill=(60, 66, 84, 255), width=S)
    # title
    sysname = SYSTEM_NAMES.get(system, system.upper())
    d.text((x_text * S, 18 * S), sysname.upper(), font=font(24, italic=True), fill=CYAN + (255,))
    tw = d.textlength(sysname.upper(), font=font(24, italic=True)) / S
    d.text(((x_text + tw + 14) * S, 25 * S), 'with a ' + fam['label'], font=font(16, bold=False), fill=DIM + (255,))
    # the rows: two columns
    per = (len(rows) + 1) // 2
    colw = (W - 20 - x_text) // 2
    rowh = min(44, (H - 70) // max(1, per))
    for i, (console, pad) in enumerate(rows):
        col = DOTS[i % len(DOTS)]
        cx = x_text + (i // per) * colw; cy = 66 + (i % per) * rowh
        r = 11
        d.ellipse(((cx) * S, (cy) * S, (cx + 2 * r) * S, (cy + 2 * r) * S), fill=col + (255,))
        d.text(((cx + r) * S, (cy + r - .5) * S), str(i + 1), font=font(13), fill=(12, 13, 18, 255), anchor='mm')
        d.text(((cx + 2 * r + 10) * S, (cy - 4) * S), console.title() if len(console) > 2 else console, font=font(19), fill=TEXT + (255,))
        d.text(((cx + 2 * r + 10) * S, (cy + 18) * S), pad + ' on this controller', font=font(12, bold=False), fill=col + (255,))
        sp = spots['buttons'].get(pad)
        if sp:                                              # the same number on the controller's button
            bx, by = px0 + sp['x'] * k, py0 + sp['y'] * k
            rr = 9
            ox, oy = bx + min(sp['r'] * k, 14) * .75, by - min(sp['r'] * k, 14) * .75
            d.ellipse(((ox - rr - 1.5) * S, (oy - rr - 1.5) * S, (ox + rr + 1.5) * S, (oy + rr + 1.5) * S), fill=(12, 13, 18, 255))
            d.ellipse(((ox - rr) * S, (oy - rr) * S, (ox + rr) * S, (oy + rr) * S), fill=col + (255,))
            d.text((ox * S, (oy - .5) * S), str(i + 1), font=font(11), fill=(12, 13, 18, 255), anchor='mm')
    return im.resize((W, H), Image.LANCZOS)


def console_lists(retrofe: Path):
    """(collection, system) for every console list of the cabinet: the systems inside the maker menus"""
    import importlib.util
    spec = importlib.util.spec_from_file_location('am_system_cards', HERE.parent / 'New-SystemCards.py')
    sc = importlib.util.module_from_spec(spec); spec.loader.exec_module(sc)
    cols = retrofe / 'collections'
    menu = cols / 'Main' / 'menu.txt'
    out, seen = [], set()
    makers = [ln.strip() for ln in menu.read_text(encoding='utf-8', errors='replace').splitlines()] if menu.is_file() else []
    for maker in makers:
        mt = cols / maker / 'menu.txt'
        if not maker or not mt.is_file():
            continue
        for coll in [ln.strip() for ln in mt.read_text(encoding='utf-8', errors='replace').splitlines() if ln.strip()]:
            key = sc.system_key(str(retrofe), coll)
            if key and coll not in seen and (cols / coll).is_dir():
                seen.add(coll); out.append((coll, key))
    return out


def place(retrofe: Path, family: str | None, cat: dict, art: Path) -> int:
    """put a controller's card on every console list (family), or the panel's cards back (family None)"""
    n = kept = 0
    for coll, system in console_lists(retrofe):
        d = retrofe / 'collections' / coll / 'medium_artwork' / 'am_controls'
        cur, panel, none = d / 'default.png', d / 'default.panel.png', d / 'default.no-panel-card'
        if family is None:
            if panel.is_file():
                panel.replace(cur); n += 1
            elif none.is_file():                        # the list had no card before the controller's: none again
                cur.unlink(missing_ok=True); none.unlink(); n += 1
            continue
        im = render(system, family, cat['families'][family], art)
        if im is None:
            kept += 1                                   # this controller has too few of the console's buttons
            continue
        d.mkdir(parents=True, exist_ok=True)
        if cur.is_file() and not panel.is_file() and not none.is_file():
            cur.replace(panel)                          # the panel's card, kept for when the controller is unplugged
        elif not cur.is_file() and not panel.is_file():
            none.write_text('this list had no card of its own before a controller card was shown', encoding='utf-8')
        im.save(cur, optimize=True); n += 1
    if family is None:
        print(f'pad cards: the panel cards are back on {n} console list(s)')
    else:
        print(f'pad cards: {cat["families"][family]["label"]} shown on {n} console list(s)' + (f', {kept} left on the panel card' if kept else ''))
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', type=Path)
    ap.add_argument('--retrofe', type=Path, help='a cabinet frontend: put the cards on its console lists')
    ap.add_argument('--family', help='with --retrofe: the controller that is plugged in')
    ap.add_argument('--panel', action='store_true', help='with --retrofe: put the panel cards back')
    ap.add_argument('--systems', help='comma list (default: every console in tools/system_buttons.py)')
    ap.add_argument('--families', help='comma list (default: every family in pads.json)')
    ap.add_argument('--art', type=Path, default=HERE.parent.parent / 'layouts' / 'ArcadeMaster' / 'images' / 'pads')
    ap.add_argument('--sheet', type=Path, help='also write the cards on one dark picture, to look them over')
    a = ap.parse_args(argv)
    cat = json.loads((HERE / 'pads.json').read_text(encoding='utf-8'))
    if a.retrofe:
        if not (a.panel or a.family in cat['families']):
            print('with --retrofe give --family <one of: ' + ', '.join(cat['families']) + '> or --panel')
            return 1
        return place(a.retrofe, None if a.panel else a.family, cat, a.art)
    if not a.out:
        print('give --out <folder>, or --retrofe <frontend>')
        return 1
    systems = [s.strip() for s in a.systems.split(',')] if a.systems else list(sb.NATIVE)
    fams = [f.strip() for f in a.families.split(',')] if a.families else list(cat['families'])
    a.out.mkdir(parents=True, exist_ok=True)
    made = []
    for s in systems:
        for f in fams:
            im = render(s, f, cat['families'][f], a.art)
            if im is None:
                continue
            im.save(a.out / f'{s}__{f}.png', optimize=True)
            made.append(im)
    if a.sheet and made:
        show = made[:12]
        sh = Image.new('RGB', (W * 2 + 30, (H + 10) * ((len(show) + 1) // 2) + 10), (10, 12, 18))
        for i, im in enumerate(show):
            sh.paste(im, (10 + (i % 2) * (W + 10), 10 + (i // 2) * (H + 10)), im)
        sh.save(a.sheet)
    print(f'pad cards: {len(made)} made for {len(systems)} console(s) x {len(fams)} controller famil{"y" if len(fams) == 1 else "ies"} -> {a.out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
