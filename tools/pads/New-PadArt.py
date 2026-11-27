#!/usr/bin/env python3
r"""
New-PadArt.py - a drawn picture of each family of hand-held controller, for the controls cards.

One picture per family in tools/pads/pads.json (ps3, ps4, ps5, psx, xbox, n64, snes, snespro, nes, genesis, gamecube,
switch): the pad seen from the front, its buttons where they are on the real thing, each with the word printed on it.
Drawn here, not photographs, so nothing is downloaded and nothing belongs to anyone else.

Writes, per family:
  <out>/pad_<family>.png     the picture, 720 x 440, see-through background
  <out>/pad_<family>.json    where each button is in that picture (x, y, r), by the names used in pads.json -
                             the controls cards put their numbered dots there

  python tools/pads/New-PadArt.py --out layouts/ArcadeMaster/images/pads [--only snes,genesis] [--sheet sheet.png]

--sheet also writes one picture with every family on a dark background, to look them over.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

W, H, SS = 720, 440, 3                     # drawn three times as large, then made smaller: smooth edges
BODY = (38, 42, 54); BODY_HI = (58, 64, 80); EDGE = (120, 130, 150); DARK = (16, 18, 26); TXT = (235, 238, 245)
CYAN = (46, 200, 255); GREY = (150, 158, 172)
PS = {'Cross': (124, 178, 232), 'Circle': (255, 102, 102), 'Square': (255, 105, 248), 'Triangle': (64, 226, 160)}
SNES = {'A': (224, 60, 60), 'B': (240, 200, 40), 'X': (70, 120, 230), 'Y': (60, 180, 90)}
XB = {'A': (96, 200, 80), 'B': (224, 60, 60), 'X': (70, 120, 230), 'Y': (240, 200, 40)}
N64C = (240, 200, 40)


def font(size, bold=True):
    for n in (['segoeuib.ttf'] if bold else []) + ['segoeui.ttf', 'arial.ttf']:
        p = Path(r'C:\Windows\Fonts') / n
        if p.exists():
            return ImageFont.truetype(str(p), size * SS)
    return ImageFont.load_default()


class Pad:
    def __init__(self):
        self.im = Image.new('RGBA', (W * SS, H * SS), (0, 0, 0, 0))
        self.d = ImageDraw.Draw(self.im)
        self.spots: dict[str, dict] = {}

    def s(self, *v):
        return tuple(int(x * SS) for x in v)

    def blob(self, box, r, fill=BODY, outline=EDGE, width=3):
        self.d.rounded_rectangle(self.s(*box), int(r * SS), fill=fill, outline=outline, width=width * SS)

    def oval(self, cx, cy, rx, ry, fill=BODY, outline=EDGE, width=3):
        self.d.ellipse(self.s(cx - rx, cy - ry, cx + rx, cy + ry), fill=fill, outline=outline, width=width * SS)

    def spot(self, name, cx, cy, r):
        self.spots[name] = {'x': cx, 'y': cy, 'r': r}

    def button(self, name, cx, cy, r=22, color=BODY_HI, label=None, text=TXT, size=None):
        self.oval(cx, cy, r, r, fill=color, outline=DARK, width=2)
        lab = name if label is None else label
        if lab:
            self.d.text(self.s(cx, cy), lab, font=font(size or max(10, int(r * 0.85))), fill=text, anchor='mm')
        self.spot(name, cx, cy, r)

    def pill(self, name, cx, cy, w=54, h=18, label=None, angle=0):
        self.blob((cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2), h / 2, fill=BODY_HI, outline=DARK, width=2)
        self.d.text(self.s(cx, cy + h / 2 + 12), (label or name).upper(), font=font(11), fill=GREY, anchor='mm')
        self.spot(name, cx, cy, h)

    def dpad(self, cx, cy, arm=30, t=20):
        self.blob((cx - arm, cy - t / 2, cx + arm, cy + t / 2), 4, fill=DARK, outline=EDGE, width=2)
        self.blob((cx - t / 2, cy - arm, cx + t / 2, cy + arm), 4, fill=DARK, outline=EDGE, width=2)
        self.blob((cx - t / 2 + 2, cy - t / 2 + 2, cx + t / 2 - 2, cy + t / 2 - 2), 2, fill=DARK, outline=DARK, width=1)
        self.spot('D-pad', cx, cy, arm)

    def stick(self, name, cx, cy, r=30):
        self.oval(cx, cy, r + 8, r + 8, fill=DARK, outline=EDGE, width=2)
        self.oval(cx, cy, r, r, fill=BODY_HI, outline=DARK, width=2)
        self.oval(cx, cy, r * 0.55, r * 0.55, fill=BODY, outline=DARK, width=1)
        self.spot(name, cx, cy, r)

    def shoulder(self, name, x0, x1, y, label=None, h=24):
        self.blob((x0, y, x1, y + h + 14), 10, fill=BODY_HI, outline=EDGE, width=2)
        self.d.text(self.s((x0 + x1) / 2, y + h / 2 + 1), label or name, font=font(14), fill=TXT, anchor='mm')
        self.spot(name, (x0 + x1) / 2, y + h / 2, h / 2)

    def done(self):
        return self.im.resize((W, H), Image.LANCZOS)


def grips(p: Pad, top=120, bottom=400, spread=0):
    """two-handed pad with grips (PlayStation, Xbox, Switch Pro ...)"""
    p.oval(170 - spread, 300, 105, 120)
    p.oval(550 + spread, 300, 105, 120)
    p.blob((90, top, 630, 330), 70)
    p.blob((120, top + 6, 600, 322), 60, outline=BODY, width=1)       # hide the inner seams


def playstation(fam):
    p = Pad()
    lab = {'ps3': ('Select', 'Start'), 'psx': ('Select', 'Start'), 'ps4': ('Share', 'Options'), 'ps5': ('Create', 'Options')}[fam]
    p.shoulder('L2', 110, 250, 52); p.shoulder('R2', 470, 610, 52)
    p.shoulder('L1', 110, 250, 88); p.shoulder('R1', 470, 610, 88)
    grips(p)
    p.dpad(190, 205)
    for n, (dx, dy) in (('Triangle', (0, -42)), ('Circle', (42, 0)), ('Cross', (0, 42)), ('Square', (-42, 0))):
        cx, cy, k, c, w = 530 + dx, 205 + dy, 10, PS[n], 3 * SS
        p.button(n, cx, cy, 21, color=DARK, label='')
        if n == 'Triangle':                              # the shapes are drawn: the fonts on a cabinet do not have them
            p.d.polygon(p.s(cx, cy - k - 1, cx + k + 1, cy + k - 2, cx - k - 1, cy + k - 2), outline=c, width=w)
        elif n == 'Circle':
            p.d.ellipse(p.s(cx - k, cy - k, cx + k, cy + k), outline=c, width=w)
        elif n == 'Square':
            p.d.rectangle(p.s(cx - k + 1, cy - k + 1, cx + k - 1, cy + k - 1), outline=c, width=w)
        else:
            p.d.line(p.s(cx - k + 1, cy - k + 1, cx + k - 1, cy + k - 1), fill=c, width=w); p.d.line(p.s(cx - k + 1, cy + k - 1, cx + k - 1, cy - k + 1), fill=c, width=w)
    p.stick('L3', 275, 300); p.stick('R3', 445, 300)
    if fam in ('ps4', 'ps5'):
        p.blob((285, 150, 435, 235), 12, fill=DARK, outline=EDGE, width=2); p.spot('Touchpad', 360, 192, 40)
        p.d.text(p.s(360, 192), 'TOUCHPAD', font=font(11), fill=GREY, anchor='mm')
        p.pill(lab[0], 250, 150, 16, 28); p.pill(lab[1], 470, 150, 16, 28)
    else:
        p.pill(lab[0], 318, 205, 40, 16); p.pill(lab[1], 402, 205, 40, 16)
    if fam != 'psx':
        p.button('PS', 360, 300 if fam in ('ps4', 'ps5') else 255, 15, label='PS', size=11)
    if fam == 'ps5':
        p.button('Mute', 360, 338, 9, label='')
    return p


def xbox(fam='xbox'):
    p = Pad()
    sw = fam == 'switch'
    names = {'lb': 'L' if sw else 'LB', 'rb': 'R' if sw else 'RB', 'lt': 'ZL' if sw else 'LT', 'rt': 'ZR' if sw else 'RT',
             'back': 'Minus' if sw else 'View', 'start': 'Plus' if sw else 'Menu', 'home': 'Home' if sw else 'Xbox'}
    p.shoulder(names['lt'], 110, 250, 52); p.shoulder(names['rt'], 470, 610, 52)
    p.shoulder(names['lb'], 110, 250, 88); p.shoulder(names['rb'], 470, 610, 88)
    grips(p)
    p.stick('LS', 190, 200); p.dpad(275, 300)
    p.stick('RS', 445, 300)
    order = (('X', (0, -42)), ('A', (42, 0)), ('B', (0, 42)), ('Y', (-42, 0))) if sw else (('Y', (0, -42)), ('B', (42, 0)), ('A', (0, 42)), ('X', (-42, 0)))
    for n, (dx, dy) in order:
        p.button(n, 530 + dx, 205 + dy, 21, color=BODY_HI if sw else DARK, text=TXT if sw else XB[n])
    p.pill(names['back'], 318, 205, 30, 16); p.pill(names['start'], 402, 205, 30, 16)
    p.button(names['home'], 360, 160, 17, label='H' if sw else 'X', size=13)
    if sw:
        p.button('Capture', 318, 255, 10, label='')
    return p


def snes(fam):
    p = Pad()
    pro = fam == 'snespro'
    if pro:
        p.shoulder('L2', 100, 230, 60); p.shoulder('R2', 490, 620, 60)
    p.shoulder('L', 100, 250, 96); p.shoulder('R', 470, 620, 96)
    p.oval(170, 240, 125, 115); p.oval(550, 240, 125, 115)
    p.blob((170, 135, 550, 345), 30)
    p.oval(170, 240, 118, 108, outline=BODY, width=1); p.oval(550, 240, 118, 108, outline=BODY, width=1)
    p.dpad(165, 225, 36, 24)
    for n, (dx, dy) in (('X', (0, -44)), ('A', (44, 0)), ('B', (0, 44)), ('Y', (-44, 0))):
        p.button(n, 555 + dx, 225 + dy, 22, color=SNES[n], text=DARK)
    p.pill('Select', 322, 235, 46, 16); p.pill('Start', 398, 235, 46, 16)
    if pro:
        p.stick('L3', 270, 320, 26); p.stick('R3', 450, 320, 26)
        p.button('Home', 360, 180, 12, label='')
    return p


def nes():
    p = Pad()
    p.blob((90, 120, 630, 340), 16)
    p.blob((108, 138, 612, 322), 8, fill=DARK, outline=EDGE, width=1)
    p.dpad(195, 230, 40, 26)
    p.pill('Select', 330, 250, 50, 16); p.pill('Start', 400, 250, 50, 16)
    p.button('B', 490, 245, 26, color=(210, 50, 50), text=TXT); p.button('A', 560, 245, 26, color=(210, 50, 50), text=TXT)
    return p


def genesis():
    p = Pad()
    p.shoulder('L', 110, 250, 80); p.shoulder('R', 470, 610, 80)
    p.oval(180, 245, 135, 125); p.oval(540, 245, 135, 125)
    p.blob((180, 135, 540, 330), 40)
    p.oval(180, 245, 128, 118, outline=BODY, width=1); p.oval(540, 245, 128, 118, outline=BODY, width=1)
    p.oval(175, 240, 52, 52, fill=DARK, outline=EDGE, width=2); p.dpad(175, 240, 34, 22)
    for i, n in enumerate(('X', 'Y', 'Z')):
        p.button(n, 480 + i * 50, 205 - i * 12, 17, color=DARK)
    for i, n in enumerate(('A', 'B', 'C')):
        p.button(n, 470 + i * 56, 262 - i * 14, 23, color=DARK)
    p.pill('Start', 360, 190, 44, 16); p.pill('Mode', 360, 240, 34, 14)
    return p


def n64():
    p = Pad()
    p.shoulder('L', 100, 230, 80); p.shoulder('R', 490, 620, 80)
    p.oval(150, 300, 70, 125); p.oval(570, 300, 70, 125); p.oval(360, 310, 60, 120)
    p.blob((100, 110, 620, 290), 70)
    p.blob((125, 116, 595, 282), 60, outline=BODY, width=1)
    p.dpad(170, 195, 34, 22)
    p.stick('Stick', 360, 300, 26)
    p.button('Start', 360, 185, 15, color=(210, 50, 50), label='', text=TXT)
    p.d.text(p.s(360, 213), 'START', font=font(11), fill=GREY, anchor='mm')
    p.button('B', 478, 205, 22, color=(60, 170, 90), text=TXT); p.button('A', 520, 250, 22, color=(70, 120, 230), text=TXT)
    for n, (dx, dy), sym in (('C-Up', (0, -28), '\u25b2'), ('C-Right', (28, 0), '\u25b6'), ('C-Down', (0, 28), '\u25bc'), ('C-Left', (-28, 0), '\u25c0')):
        p.button(n, 572 + dx, 170 + dy, 14, color=N64C, label=sym, text=DARK, size=11)
    p.button('Z', 360, 395, 16, color=BODY_HI)
    return p


def gamecube():
    p = Pad()
    p.shoulder('L', 110, 250, 70); p.shoulder('R', 470, 610, 70); p.shoulder('Z', 490, 590, 104, h=14)
    grips(p)
    p.stick('Stick', 190, 200); p.dpad(275, 300, 24, 16)
    p.stick('C-Stick', 445, 300, 22)
    p.button('A', 530, 210, 32, color=(40, 170, 150), text=TXT); p.button('B', 478, 252, 18, color=(210, 50, 50), text=TXT)
    p.button('X', 588, 195, 17); p.button('Y', 512, 152, 17)
    p.button('Start', 360, 205, 13, label='')
    p.d.text(p.s(360, 232), 'START', font=font(11), fill=GREY, anchor='mm')
    return p


DRAW = {'ps3': lambda: playstation('ps3'), 'ps4': lambda: playstation('ps4'), 'ps5': lambda: playstation('ps5'), 'psx': lambda: playstation('psx'),
        'xbox': lambda: xbox('xbox'), 'switch': lambda: xbox('switch'), 'snes': lambda: snes('snes'), 'snespro': lambda: snes('snespro'),
        'nes': nes, 'genesis': genesis, 'n64': n64, 'gamecube': gamecube}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', required=True, type=Path)
    ap.add_argument('--only', help='comma list of families')
    ap.add_argument('--sheet', type=Path, help='also write every family on one dark picture, to look them over')
    a = ap.parse_args(argv)
    cat = json.loads(Path(__file__).with_name('pads.json').read_text(encoding='utf-8'))
    want = [f.strip() for f in a.only.split(',')] if a.only else list(cat['families'])
    a.out.mkdir(parents=True, exist_ok=True)
    made, missing = [], []
    for fam in want:
        if fam not in DRAW:
            print(f'  no drawing for family {fam}')
            continue
        p = DRAW[fam]()
        im = p.done()
        im.save(a.out / f'pad_{fam}.png', optimize=True)
        (a.out / f'pad_{fam}.json').write_text(json.dumps({'family': fam, 'width': W, 'height': H, 'buttons': p.spots}, indent=1) + '\n', encoding='utf-8')
        lost = [b for b in cat['families'][fam]['buttons'] if b not in p.spots]
        if lost:
            missing.append(f'{fam}: {", ".join(lost)}')
        made.append((fam, im))
    if a.sheet and made:
        cols = 3; rows = (len(made) + cols - 1) // cols
        sh = Image.new('RGB', (cols * W // 2, rows * (H // 2 + 30)), (14, 16, 24)); d = ImageDraw.Draw(sh)
        for i, (fam, im) in enumerate(made):
            x, y = (i % cols) * W // 2, (i // cols) * (H // 2 + 30)
            small = im.resize((W // 2, H // 2), Image.LANCZOS); sh.paste(small, (x, y + 26), small)
            d.text((x + 12, y + 6), cat['families'][fam]['label'], fill=CYAN)
        sh.save(a.sheet)
    print(f'pad pictures: {len(made)} drawn -> {a.out}')
    for m in missing:
        print(f'  a button in pads.json has no place in the picture - {m}')
    return 1 if missing else 0


if __name__ == '__main__':
    sys.exit(main())
