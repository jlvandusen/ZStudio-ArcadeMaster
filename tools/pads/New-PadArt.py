#!/usr/bin/env python3
r"""
New-PadArt.py - a picture of each family of hand-held controller, for the controls cards.

One picture per family in tools/pads/pads.json (ps3, ps4, ps5, psx, xbox, n64, snes, snespro, nes, genesis, gamecube,
switch): the pad seen from the front, its buttons where they are on the real thing, each with the word printed on it.
Rendered here - moulded plastic with light from above, a shadow under the pad, domed buttons, rubber sticks, the
colours the real pads have - not photographs, so nothing is downloaded and nothing belongs to anyone else.
(James, 2026-11-27: "make better more realistic looking".)

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

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

W, H, SS = 720, 440, 3                     # drawn three times as large, then made smaller: smooth edges
WHITE = (245, 246, 250); INK = (22, 24, 30); CYAN = (46, 200, 255)
PS = {'Cross': (124, 178, 232), 'Circle': (255, 102, 102), 'Square': (255, 105, 248), 'Triangle': (64, 226, 160)}
SFC = {'A': (214, 48, 56), 'B': (238, 196, 40), 'X': (56, 104, 214), 'Y': (48, 164, 84)}
XB = {'A': (120, 210, 90), 'B': (230, 70, 70), 'X': (80, 140, 240), 'Y': (245, 205, 60)}


def mix(c, k):
    """k > 1 lighter, k < 1 darker"""
    if k >= 1:
        return tuple(min(255, int(v + (255 - v) * (k - 1))) for v in c)
    return tuple(int(v * k) for v in c)


def font(size, bold=True):
    for n in (['segoeuib.ttf'] if bold else []) + ['segoeui.ttf', 'arial.ttf']:
        p = Path(r'C:\Windows\Fonts') / n
        if p.exists():
            return ImageFont.truetype(str(p), int(size * SS))
    return ImageFont.load_default()


class Pad:
    def __init__(self, ink=WHITE):
        self.im = Image.new('RGBA', (W * SS, H * SS), (0, 0, 0, 0))
        self.d = ImageDraw.Draw(self.im)
        self.mask = Image.new('L', self.im.size, 0)          # the shell being moulded
        self.md = ImageDraw.Draw(self.mask)
        self.spots: dict[str, dict] = {}
        self.ink = ink                                       # small words printed on the shell

    def s(self, *v):
        return tuple(int(x * SS) for x in v)

    # ---- the shell: add shapes, then mould them as one piece of plastic
    def m_oval(self, cx, cy, rx, ry):
        self.md.ellipse(self.s(cx - rx, cy - ry, cx + rx, cy + ry), fill=255)

    def m_box(self, x0, y0, x1, y1, r):
        self.md.rounded_rectangle(self.s(x0, y0, x1, y1), int(r * SS), fill=255)

    def m_poly(self, *pts):
        self.md.polygon(self.s(*pts), fill=255)

    def mould(self, color, shadow=True, gloss=.30, depth=7):
        """turn the collected shapes into one lit plastic part and start a new empty one"""
        m = self.mask.filter(ImageFilter.GaussianBlur(SS * .6))
        size = self.im.size
        if shadow:                                           # the pad's shadow on the table
            sh = ImageChops.offset(m, 0, 12 * SS).filter(ImageFilter.GaussianBlur(11 * SS)).point(lambda v: int(v * .55))
            self.im.alpha_composite(Image.merge('RGBA', (*Image.new('RGB', size, (0, 0, 0)).split(), sh)))
        grad = Image.linear_gradient('L').resize(size)        # 0 at the top
        body = Image.composite(Image.new('RGB', size, mix(color, .74)), Image.new('RGB', size, mix(color, 1.10)), grad)
        part = Image.merge('RGBA', (*body.split(), m))
        # light from above: a bright lip on top edges, a dark roll-off on bottom edges
        lip = ImageChops.subtract(m, ImageChops.offset(m, 0, depth * SS)).filter(ImageFilter.GaussianBlur(depth * SS * .5))
        und = ImageChops.subtract(m, ImageChops.offset(m, 0, -int(depth * 1.4) * SS)).filter(ImageFilter.GaussianBlur(depth * SS * .8))
        part.alpha_composite(Image.merge('RGBA', (*Image.new('RGB', size, (255, 255, 255)).split(), ImageChops.multiply(lip, m).point(lambda v: int(v * gloss)))))
        part.alpha_composite(Image.merge('RGBA', (*Image.new('RGB', size, (0, 0, 0)).split(), ImageChops.multiply(und, m).point(lambda v: int(v * .50)))))
        # a thin dark seam all round
        rim = ImageChops.subtract(m, m.filter(ImageFilter.MinFilter(2 * SS + 1)))
        part.alpha_composite(Image.merge('RGBA', (*Image.new('RGB', size, mix(color, .45)).split(), rim.point(lambda v: int(v * .8)))))
        self.im.alpha_composite(part)
        self.mask = Image.new('L', size, 0); self.md = ImageDraw.Draw(self.mask)
        self.d = ImageDraw.Draw(self.im)

    # ---- soft paint (blended, unlike ImageDraw on a see-through picture)
    def soft(self, cx, cy, rx, ry, color, alpha, blur=0.0, box=False, r=0):
        pad = int((blur * 3 + 4) * SS)
        x0, y0 = int((cx - rx) * SS) - pad, int((cy - ry) * SS) - pad
        w, h = int(rx * 2 * SS) + 2 * pad, int(ry * 2 * SS) + 2 * pad
        a = Image.new('L', (w, h), 0); ad = ImageDraw.Draw(a)
        if box:
            ad.rounded_rectangle((pad, pad, w - pad, h - pad), int(r * SS), fill=int(255 * alpha))
        else:
            ad.ellipse((pad, pad, w - pad, h - pad), fill=int(255 * alpha))
        if blur:
            a = a.filter(ImageFilter.GaussianBlur(blur * SS))
        self.im.alpha_composite(Image.merge('RGBA', (*Image.new('RGB', (w, h), color).split(), a)), (max(0, x0), max(0, y0)),
                                (max(0, -x0), max(0, -y0), w, h))
        self.d = ImageDraw.Draw(self.im)

    def text(self, cx, cy, s, size, color=None, bold=True):
        self.d.text(self.s(cx, cy), s, font=font(size, bold), fill=color or self.ink, anchor='mm')

    def spot(self, name, cx, cy, r):
        self.spots[name] = {'x': cx, 'y': cy, 'r': r}

    # ---- parts
    def button(self, name, cx, cy, r=22, color=(60, 64, 76), label=None, text=None, size=None, well=True):
        if well:
            self.soft(cx, cy + 1, r + 4, r + 4, (0, 0, 0), .55, 1.2)             # the hole it sits in
        self.soft(cx, cy + 3, r, r, (0, 0, 0), .5, 2)                            # its shadow
        self.soft(cx, cy, r, r, mix(color, .62), 1)                              # side of the dome
        self.soft(cx, cy - r * .08, r * .90, r * .90, color, 1, .6)              # top of the dome
        self.soft(cx - r * .18, cy - r * .42, r * .52, r * .30, (255, 255, 255), .34, r * .10)   # the shine
        lab = name if label is None else label
        if lab:
            dark = sum(color) > 420
            self.text(cx, cy - r * .04, lab, size or max(10, r * .86), text or (INK if dark else WHITE))
        self.spot(name, cx, cy, r)

    def pill(self, name, cx, cy, w=54, h=18, label=None, color=(52, 55, 64), below=True, cap=None):
        self.soft(cx, cy + 2, w / 2 + 1, h / 2 + 1, (0, 0, 0), .55, 1.4, box=True, r=h / 2)
        self.soft(cx, cy, w / 2, h / 2, mix(color, .6), 1, box=True, r=h / 2)
        self.soft(cx, cy - 1.2, w / 2 - 1.2, h / 2 - 1.6, color, 1, .5, box=True, r=h / 2)
        self.soft(cx, cy - h * .22, w / 2 - 4, h * .14, (255, 255, 255), .22, 1, box=True, r=2)
        self.text(cx, cy + (h / 2 + 11 if below else -h / 2 - 11), (cap or label or name).upper(), 11, mix(self.ink, .8) if sum(self.ink) > 380 else self.ink)
        self.spot(name, cx, cy, max(h, 12))

    def dpad(self, cx, cy, arm=30, t=20, color=(34, 36, 42), disc=None):
        if disc:
            self.soft(cx, cy + 1, arm + 14, arm + 14, (0, 0, 0), .5, 2); self.soft(cx, cy, arm + 12, arm + 12, disc, 1)
            self.soft(cx, cy - 2, arm + 9, arm + 8, mix(disc, 1.12), .6, 2)
        for dy, c, k in ((3, (0, 0, 0), .55), (0, mix(color, .6), 1), (-1.5, color, 1)):
            b = 2 if dy == 3 else 0
            self.soft(cx, cy + dy, arm, t / 2, c, k, b, box=True, r=4); self.soft(cx, cy + dy, t / 2, arm, c, k, b, box=True, r=4)
        self.soft(cx, cy - 1.5, t * .28, t * .28, mix(color, .7), 1, 1.5)                       # the dimple
        self.soft(cx, cy - arm * .62 - 1.5, t * .3, 1.4, (255, 255, 255), .25, .8, box=True, r=1)  # light on the top arm
        hi = mix(color, 1.5)
        for ax, ay in ((0, -1), (1, 0), (0, 1), (-1, 0)):                                        # little arrows
            px, py = cx + ax * arm * .68, cy + ay * arm * .68 - 1.5
            k = 3.4
            pts = (px + ax * k, py + ay * k, px - ax * k + ay * k, py - ay * k + ax * k, px - ax * k - ay * k, py - ay * k - ax * k)
            self.d.polygon(self.s(*pts), fill=hi + (255,))
        self.spot('D-pad', cx, cy, arm)

    def stick(self, name, cx, cy, r=30, color=(44, 46, 54), concave=True):
        self.soft(cx, cy + 2, r + 10, r + 10, (0, 0, 0), .75, 1.5)               # the well
        self.soft(cx, cy, r + 8, r + 8, (14, 15, 19), 1)
        self.soft(cx, cy + 5, r, r, (0, 0, 0), .6, 3)                            # cap shadow
        self.soft(cx, cy, r, r, mix(color, .55), 1)
        self.soft(cx, cy - 1.5, r - 1.5, r - 2, color, 1, .6)
        self.soft(cx, cy - r * .55, r * .62, r * .2, (255, 255, 255), .16, 2)    # light on the rim
        if concave:
            self.soft(cx, cy, r * .62, r * .62, mix(color, .7), 1, 1.2)
            self.soft(cx, cy + r * .2, r * .46, r * .34, mix(color, 1.25), .5, 2.5)
        else:
            self.soft(cx - r * .15, cy - r * .3, r * .5, r * .3, (255, 255, 255), .2, 3)
        self.spot(name, cx, cy, r)

    def shoulder(self, name, x0, x1, y, color, label=None, h=24, text=None):
        """a bumper or trigger seen from the front: a tab that sticks up behind the shell"""
        self.m_box(x0, y, x1, y + h + 26, 11)
        self.mould(color, shadow=False, gloss=.4, depth=4)
        dark = sum(color) > 420
        self.text((x0 + x1) / 2, y + h / 2 + 1, label or name, 13, text or (INK if dark else WHITE))
        self.spot(name, (x0 + x1) / 2, y + h / 2, h / 2)

    def done(self):
        return self.im.resize((W, H), Image.LANCZOS)


def grip_shell(p: Pad, color, top=118, wide=0, grip=(104, 122), **kw):
    """two-handed pad with grips (PlayStation, Xbox, Switch Pro ...)"""
    p.m_oval(172 - wide, 296, *grip); p.m_oval(548 + wide, 296, *grip)
    p.m_box(92, top, 628, 328, 72)
    p.mould(color, **kw)


def ps_symbol(p: Pad, n, cx, cy, k=10):
    c, w = PS[n], int(2.6 * SS)
    cy -= 1
    if n == 'Triangle':
        p.d.polygon(p.s(cx, cy - k - 1, cx + k + 1, cy + k - 2, cx - k - 1, cy + k - 2), outline=c + (255,), width=w)
    elif n == 'Circle':
        p.d.ellipse(p.s(cx - k, cy - k, cx + k, cy + k), outline=c + (255,), width=w)
    elif n == 'Square':
        p.d.rectangle(p.s(cx - k + 1, cy - k + 1, cx + k - 1, cy + k - 1), outline=c + (255,), width=w)
    else:
        p.d.line(p.s(cx - k + 1, cy - k + 1, cx + k - 1, cy + k - 1), fill=c + (255,), width=w)
        p.d.line(p.s(cx - k + 1, cy + k - 1, cx + k - 1, cy - k + 1), fill=c + (255,), width=w)


def playstation(fam):
    ps5 = fam == 'ps5'
    shell = (232, 234, 240) if ps5 else (30, 31, 36)
    trim = (26, 27, 32) if ps5 else (46, 48, 56)
    p = Pad(ink=(70, 74, 86) if ps5 else (170, 176, 190))
    lab = {'ps3': ('Select', 'Start'), 'psx': ('Select', 'Start'), 'ps4': ('Share', 'Options'), 'ps5': ('Create', 'Options')}[fam]
    for n, x0, x1, y in (('L2', 118, 246, 50), ('R2', 474, 602, 50), ('L1', 110, 254, 84), ('R1', 466, 610, 84)):
        p.shoulder(n, x0, x1, y, trim)
    if fam in ('ps4', 'ps5'):
        p.m_oval(170, 300, 96, 126); p.m_oval(550, 300, 96, 126); p.m_box(96, 120, 624, 318, 78)
        p.mould(shell)
        if ps5:                                              # the black middle of a DualSense
            p.m_box(246, 136, 474, 352, 46); p.mould(trim, shadow=False, gloss=.18, depth=4)
    else:
        grip_shell(p, shell)
    face = (24, 25, 30)
    p.dpad(190, 205, 30, 19, color=(40, 42, 50))
    for n, (dx, dy) in (('Triangle', (0, -42)), ('Circle', (42, 0)), ('Cross', (0, 42)), ('Square', (-42, 0))):
        p.button(n, 530 + dx, 205 + dy, 20, color=(238, 240, 244) if ps5 else face, label='')
        ps_symbol(p, n, 530 + dx, 205 + dy, 9)
    p.stick('L3', 278, 298, 29); p.stick('R3', 442, 298, 29)
    if fam in ('ps4', 'ps5'):
        p.soft(360, 190, 76, 44, (0, 0, 0), .6, 2, box=True, r=12)
        p.soft(360, 189, 74, 42, (232, 234, 240) if ps5 else (40, 42, 50), 1, box=True, r=12)
        p.soft(360, 172, 66, 14, (255, 255, 255), .10, 4, box=True, r=8)
        p.spot('Touchpad', 360, 190, 40)
        p.text(360, 190, 'TOUCHPAD', 10, (120, 124, 136))
        p.pill(lab[0], 262, 148, 14, 26, color=(70, 72, 82), cap=lab[0], below=False)
        p.pill(lab[1], 458, 148, 14, 26, color=(70, 72, 82), cap=lab[1], below=False)
    else:
        p.pill(lab[0], 318, 205, 38, 15); p.pill(lab[1], 402, 205, 38, 15)
    if fam != 'psx':
        p.button('PS', 360, 296 if fam in ('ps4', 'ps5') else 252, 14, color=(52, 54, 62), label='PS', size=10)
    if ps5:
        p.pill('Mute', 360, 330, 26, 9, color=(60, 62, 70), cap=' ')
    return p


def xbox(fam='xbox'):
    sw = fam == 'switch'
    shell = (44, 46, 52) if sw else (28, 29, 33)
    trim = (58, 60, 68) if sw else (44, 46, 52)
    p = Pad(ink=(170, 176, 190))
    nm = {'lb': 'L' if sw else 'LB', 'rb': 'R' if sw else 'RB', 'lt': 'ZL' if sw else 'LT', 'rt': 'ZR' if sw else 'RT',
          'back': 'Minus' if sw else 'View', 'start': 'Plus' if sw else 'Menu', 'home': 'Home' if sw else 'Xbox'}
    for n, x0, x1, y in ((nm['lt'], 118, 246, 50), (nm['rt'], 474, 602, 50), (nm['lb'], 110, 254, 84), (nm['rb'], 466, 610, 84)):
        p.shoulder(n, x0, x1, y, trim)
    grip_shell(p, shell, grip=(100, 126))
    p.stick('LS', 190, 200, 29); p.dpad(275, 298, 27, 18, color=(40, 42, 50), disc=None if sw else (22, 23, 27))
    p.stick('RS', 445, 298, 29)
    order = (('X', (0, -42)), ('A', (42, 0)), ('B', (0, 42)), ('Y', (-42, 0))) if sw else (('Y', (0, -42)), ('B', (42, 0)), ('A', (0, 42)), ('X', (-42, 0)))
    for n, (dx, dy) in order:
        p.button(n, 530 + dx, 205 + dy, 20, color=(40, 42, 48) if sw else (22, 23, 27), text=WHITE if sw else XB[n])
    p.pill(nm['back'], 318, 205, 22, 14, cap=nm['back']); p.pill(nm['start'], 402, 205, 22, 14, cap=nm['start'])
    if sw:
        p.button('Home', 402, 252, 11, color=(60, 62, 70), label=''); p.button('Capture', 318, 252, 10, color=(60, 62, 70), label='')
    else:
        p.button('Xbox', 360, 158, 19, color=(236, 238, 242), label='X', text=(30, 32, 38), size=17)
    return p


def snes(fam):
    pro = fam == 'snespro'
    shell = (196, 196, 202); inlay = (128, 128, 138)
    p = Pad(ink=(84, 86, 98))
    if pro:
        p.shoulder('L2', 108, 232, 58, (150, 150, 158)); p.shoulder('R2', 488, 612, 58, (150, 150, 158))
    p.shoulder('L', 100, 256, 92, (166, 166, 174)); p.shoulder('R', 464, 620, 92, (166, 166, 174))
    p.m_oval(172, 238, 124, 112); p.m_oval(548, 238, 124, 112); p.m_box(172, 138, 548, 338, 26)
    if pro:
        p.m_oval(190, 318, 74, 78); p.m_oval(530, 318, 74, 78)
    p.mould(shell)
    p.m_oval(554, 226, 92, 92); p.mould(inlay, shadow=False, gloss=.2, depth=3)          # the darker round face on the right
    p.m_box(300, 196, 420, 268, 10); p.mould(mix(shell, .93), shadow=False, gloss=.2, depth=2)
    p.dpad(166, 226, 36, 23, color=(44, 45, 52))
    for n, (dx, dy) in (('X', (0, -44)), ('A', (44, 0)), ('B', (0, 44)), ('Y', (-44, 0))):
        p.button(n, 554 + dx, 226 + dy, 21, color=SFC[n], text=WHITE, well=False)
    for n, cx in (('Select', 328), ('Start', 392)):
        p.pill(n, cx, 226, 40, 14, color=(60, 62, 72))
    if pro:
        p.stick('L3', 268, 318, 25); p.stick('R3', 452, 318, 25)
        p.button('Home', 360, 172, 10, color=(120, 120, 130), label='')
    return p


def nes():
    p = Pad(ink=(200, 60, 60))
    p.m_box(92, 124, 628, 336, 12); p.mould((198, 196, 196))
    p.m_box(112, 146, 608, 314, 6); p.mould((26, 26, 30), shadow=False, gloss=.15, depth=3)
    p.m_box(292, 164, 440, 196, 5); p.mould((150, 150, 154), shadow=False, gloss=.2, depth=2)
    p.m_box(292, 226, 440, 276, 8); p.mould((198, 196, 196), shadow=False, gloss=.2, depth=2)
    p.dpad(196, 232, 40, 26, color=(30, 30, 34))
    p.pill('Select', 332, 251, 40, 13, color=(34, 34, 38), below=False); p.pill('Start', 400, 251, 40, 13, color=(34, 34, 38), below=False)
    for n, cx in (('B', 492), ('A', 560)):
        p.soft(cx, 246, 31, 31, (198, 196, 196), 1, box=True, r=6)
        p.button(n, cx, 246, 24, color=(204, 34, 40), label='', well=False)
        p.text(cx + 22, 290, n, 15, (204, 34, 40))
    return p


def genesis():
    shell = (24, 24, 28)
    p = Pad(ink=(214, 216, 224))
    p.shoulder('L', 112, 250, 82, (40, 40, 46)); p.shoulder('R', 470, 608, 82, (40, 40, 46))
    p.m_oval(182, 244, 134, 122); p.m_oval(538, 244, 134, 122); p.m_box(182, 138, 538, 322, 36)
    p.mould(shell, gloss=.36)
    p.dpad(176, 238, 33, 22, color=(30, 30, 35), disc=(40, 40, 46))
    for i, n in enumerate(('X', 'Y', 'Z')):
        p.button(n, 478 + i * 50, 204 - i * 12, 16, color=(36, 36, 42))
    for i, n in enumerate(('A', 'B', 'C')):
        p.button(n, 468 + i * 56, 262 - i * 14, 23, color=(36, 36, 42))
    p.pill('Start', 356, 196, 40, 14, color=(60, 60, 68)); p.pill('Mode', 356, 252, 30, 12, color=(60, 60, 68))
    return p


def n64():
    shell = (148, 150, 156)
    p = Pad(ink=(58, 60, 70))
    p.shoulder('L', 104, 232, 78, (120, 122, 130)); p.shoulder('R', 488, 616, 78, (120, 122, 130))
    p.m_oval(150, 300, 66, 124); p.m_oval(570, 300, 66, 124); p.m_oval(360, 312, 56, 118)
    p.m_box(102, 112, 618, 288, 68)
    p.mould(shell)
    p.dpad(170, 196, 33, 21, color=(52, 54, 62))
    p.stick('Stick', 360, 298, 24, color=(196, 198, 204), concave=False)
    p.button('Start', 360, 186, 14, color=(206, 40, 46), label='')
    p.text(360, 213, 'START', 10)
    p.button('B', 476, 206, 21, color=(36, 150, 84), text=WHITE); p.button('A', 520, 250, 21, color=(40, 96, 200), text=WHITE)
    for n, (dx, dy), ar in (('C-Up', (0, -27), (0, -1)), ('C-Right', (27, 0), (1, 0)), ('C-Down', (0, 27), (0, 1)), ('C-Left', (-27, 0), (-1, 0))):
        cx, cy = 572 + dx, 172 + dy
        p.button(n, cx, cy, 13, color=(236, 196, 36), label='')
        ax, ay = ar; k = 4.5
        p.d.polygon(p.s(cx + ax * k, cy + ay * k - 1, cx - ax * k + ay * k, cy - ay * k + ax * k - 1, cx - ax * k - ay * k, cy - ay * k - ax * k - 1), fill=(90, 70, 10, 255))
    p.text(572, 124, 'C', 12)
    p.button('Z', 360, 396, 15, color=(96, 98, 106), text=WHITE)
    return p


def gamecube():
    shell = (92, 84, 164)
    p = Pad(ink=(214, 212, 236))
    p.shoulder('L', 116, 250, 68, (150, 152, 160)); p.shoulder('R', 470, 604, 68, (150, 152, 160))
    p.shoulder('Z', 492, 590, 100, (70, 64, 140), h=12)
    grip_shell(p, shell, grip=(96, 126))
    p.stick('Stick', 190, 200, 27, color=(196, 198, 204), concave=False); p.dpad(275, 298, 22, 15, color=(150, 152, 160))
    p.stick('C-Stick', 445, 298, 20, color=(240, 200, 40), concave=False)
    p.button('A', 530, 210, 31, color=(36, 168, 150), text=WHITE); p.button('B', 478, 252, 17, color=(206, 44, 50), text=WHITE)
    p.button('X', 588, 196, 16, color=(196, 198, 204)); p.button('Y', 512, 154, 16, color=(196, 198, 204))
    p.button('Start', 360, 205, 11, color=(196, 198, 204), label='')
    p.text(360, 230, 'START', 10)
    return p


def dreamcast():
    shell = (222, 222, 226)
    p = Pad(ink=(84, 86, 98))
    p.shoulder('L', 120, 250, 70, (190, 190, 196)); p.shoulder('R', 470, 600, 70, (190, 190, 196))
    p.m_oval(176, 290, 100, 124); p.m_oval(544, 290, 100, 124); p.m_box(100, 108, 620, 322, 76)
    p.mould(shell)
    p.m_box(292, 124, 428, 226, 14); p.mould((60, 62, 70), shadow=False, gloss=.2, depth=3)        # the memory card window
    p.soft(360, 172, 54, 36, (150, 170, 150), 1, box=True, r=6)
    p.stick('Stick', 196, 190, 27, color=(206, 208, 214), concave=False)
    p.dpad(206, 288, 26, 18, color=(90, 92, 100))
    for n, (dx, dy), c in (('Y', (0, -40), (60, 170, 90)), ('B', (40, 0), (70, 120, 220)), ('A', (0, 40), (214, 56, 60)), ('X', (-40, 0), (236, 196, 40))):
        p.button(n, 524 + dx, 218 + dy, 19, color=c, text=WHITE)
    p.button('Start', 360, 282, 13, color=(214, 56, 60), label='')
    p.text(360, 308, 'START', 10)
    return p


def pcengine():
    p = Pad(ink=(206, 208, 216))
    p.m_box(100, 132, 620, 328, 22); p.mould((228, 226, 220))
    p.m_box(118, 150, 602, 310, 12); p.mould((36, 38, 46), shadow=False, gloss=.15, depth=3)
    p.dpad(204, 230, 40, 26, color=(34, 36, 42), disc=(52, 54, 62))
    p.pill('Select', 336, 252, 42, 13, color=(96, 98, 106)); p.pill('Run', 400, 252, 42, 13, color=(96, 98, 106))
    p.button('II', 488, 240, 25, color=(228, 110, 40), text=WHITE); p.button('I', 556, 240, 25, color=(228, 110, 40), text=WHITE)
    return p


DRAW = {'ps3': lambda: playstation('ps3'), 'ps4': lambda: playstation('ps4'), 'ps5': lambda: playstation('ps5'), 'psx': lambda: playstation('psx'),
        'xbox': lambda: xbox('xbox'), 'switch': lambda: xbox('switch'), 'snes': lambda: snes('snes'), 'snespro': lambda: snes('snespro'),
        'nes': nes, 'genesis': genesis, 'n64': n64, 'gamecube': gamecube, 'dreamcast': dreamcast, 'pcengine': pcengine}


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
        cw, ch = W * 2 // 3, H * 2 // 3
        sh = Image.new('RGB', (cols * cw, rows * (ch + 30)), (30, 34, 46)); d = ImageDraw.Draw(sh)
        for i, (fam, im) in enumerate(made):
            x, y = (i % cols) * cw, (i // cols) * (ch + 30)
            small = im.resize((cw, ch), Image.LANCZOS); sh.paste(small, (x, y + 26), small)
            d.text((x + 12, y + 6), cat['families'][fam]['label'], fill=CYAN)
        sh.save(a.sheet)
    print(f'pad pictures: {len(made)} drawn -> {a.out}')
    for m in missing:
        print(f'  a button in pads.json has no place in the picture - {m}')
    return 1 if missing else 0


if __name__ == '__main__':
    sys.exit(main())
