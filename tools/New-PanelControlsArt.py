#!/usr/bin/env python3
"""
New-PanelControlsArt.py - per-game CONTROL PANEL cards for the 4-player arcade pedestal.

When a game is highlighted, the game list (layouts/ArcadeMaster/layout.xml, reloadableImage type="am_controls",
1100x300 at 1345,905) shows ONE player's panel - joystick + buttons in 2 rows of 3 - with the buttons the game uses
lit and numbered, how the stick moves (8-way / 4-way / 2-way / analog), how many players, and any special control
(trackball, spinner, light gun, paddle, wheel ...).

Where the facts come from (first hit wins):
  1. <manifest>/games.json  `controls` (tools/Add-GameControls.ps1)  - matched by (collection, item) from `sources`,
     then by normalised id / TeknoParrot profile / rom (the way New-GameControlsArt.ps1 maps titles)
  2. <retrofe>/meta.db  Meta.players / ctrltype / buttons / joyways  (free text, parsed loosely)
  3. MAME -listxml  <input>/<control> of every machine (only for collections whose metadata.type is MAME). The
     emulator is asked once; the answer is cached in <manifest>/mame-inputs.json (keyed on the exe's size+mtime).

Performance: 16k games share a few dozen control SIGNATURES. One card per signature is rendered into
<manifest>/controls-cards/<signature>.png and every item gets an NTFS HARD LINK to it
(collections/<col>/medium_artwork/am_controls/<item>.png); a copy only when linking fails (different volume).
Re-runs skip items already linked to the right card. An am_controls file that is NOT ours (a richer card from
New-GameControlsArt.ps1) is left alone unless --force.

  python tools/New-PanelControlsArt.py --retrofe R:/ArcadeMaster/frontend/LEGENDS-am --manifest R:/ArcadeMaster/manifest
         [--collections Arcades,TeknoParrot] [--force] [--preview sheet.png] [--rows 2 --cols 3] [--mame <exe>]
         [--dry-run]

Never writes into roms/ or video/ folders (they can be junctions to the live drive) - only medium_artwork/am_controls.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

# ------------------------------------------------------------------ style (tools/lib/AmVisual.ps1 AmPal)
BG, CARD, CARD2 = (8, 9, 14), (20, 22, 31), (28, 31, 44)
MAGENTA, CYAN, AMBER = (255, 47, 160), (46, 200, 255), (255, 176, 0)
VIOLET, GREEN, RED, ORANGE = (123, 92, 255), (61, 220, 132), (255, 90, 90), (255, 138, 61)
TEXT, DIM, FAINT = (230, 233, 240), (154, 163, 178), (60, 66, 84)
PLAYER = [(0xff, 0x3b, 0x3b), (0x2e, 0x8b, 0xff), (0x3d, 0xdc, 0x84), (0xff, 0xcc, 0x00)]
BTN_COLORS = [MAGENTA, CYAN, AMBER, GREEN, VIOLET, ORANGE, (155, 231, 255), RED]
CARD_VERSION = 4         # bump to force a re-render of every signature card (links follow: files are rewritten in place)

LINK_MAX = 1000           # NTFS caps a file at 1023 names; leave headroom
W, H, S = 1100, 300, 2   # card size, supersampling factor
FONT_DIR = Path(os.environ.get('WINDIR', r'C:\Windows')) / 'Fonts'
_fonts: dict = {}


def font(name: str, px: int) -> ImageFont.FreeTypeFont:
    key = (name, px)
    if key not in _fonts:
        files = {'black': 'seguibl.ttf', 'blackital': 'seguibli.ttf', 'semi': 'seguisb.ttf', 'bold': 'segoeuib.ttf'}
        try:
            _fonts[key] = ImageFont.truetype(str(FONT_DIR / files[name]), px * S)
        except OSError:
            _fonts[key] = ImageFont.truetype('arial.ttf', px * S)
    return _fonts[key]


EXTRA_LABEL = {'trackball': 'TRACKBALL', 'spinner': 'SPINNER', 'lightgun': 'LIGHT GUN', 'paddle': 'PADDLE',
               'wheel': 'WHEEL', 'pedal': 'PEDAL', 'flightstick': 'FLIGHT STICK', 'twinstick': 'TWIN STICK',
               'keypad': 'KEYPAD'}
EXTRA_ORDER = list(EXTRA_LABEL)
HOW_TO = {'trackball': 'ROLL THE TRACKBALL', 'spinner': 'SPIN WITH THE TRACKBALL', 'lightgun': 'AIM AT THE SCREEN + PULL',
          'paddle': 'TURN WITH THE TRACKBALL', 'wheel': 'STEER WITH THE STICK', 'pedal': 'PEDAL ON A BUTTON',
          'flightstick': 'FLY WITH THE STICK', 'twinstick': 'ONE STICK EACH HAND', 'keypad': 'MAHJONG / CASINO CONTROLS'}
STICK_TEXT = {'8': '8-WAY STICK', '4': '4-WAY STICK', '2h': '2-WAY STICK', '2v': 'UP/DOWN STICK',
              'analog': 'ANALOG STICK'}


# ------------------------------------------------------------------ control signature
WHEEL_LABELS = ('GAS', 'BRAKE', 'GEAR +', 'GEAR −', 'VIEW')


class Sig:
    __slots__ = ('players', 'alt', 'stick', 'buttons', 'extras', 'labels', 'emu')

    def __init__(self, players=0, alt=False, stick=None, buttons=0, extras=(), labels=(), emu=''):
        self.emu = emu
        ex0 = set(extras)
        # a racer on a stick panel: the stick steers and the pedals land on buttons 1 + 2 (gas, brake), then the
        # game's own buttons (gear up / down, view). Without this a wheel game showed "1 button".
        if ('wheel' in ex0 or ('pedal' in ex0 and ex0 & {'paddle', 'spinner'})) and not labels and buttons < 6:
            n = min(buttons + 2, 5)
            labels, buttons = WHEEL_LABELS[:n], n
        ex = set(extras)
        # fold variants that look the same on this panel, so 16k games share few cards
        if 'keypad' in ex:                                   # mahjong / casino / keyboard: the panel cannot play them
            stick, buttons, ex, labels = None, 0, {'keypad'}, ()
        if 'pedal' in ex and ex & {'paddle', 'spinner'} and not stick:
            ex -= {'pedal', 'paddle', 'spinner'}             # MAME racers: paddle/dial + pedal = a steering wheel
            ex.add('wheel')
        if 'pedal' in ex and (stick or len(ex) > 1):
            ex.discard('pedal')                              # throttle pedals of flight / wheel games
        self.players = min(max(1, players or 1), 5)          # 5 = "4+": all four positions can join
        self.alt, self.stick, self.buttons = alt, stick, min(buttons, 7)   # 7 = "7+"
        self.extras = tuple(e for e in EXTRA_ORDER if e in ex)
        self.labels = tuple(labels)

    def known(self) -> bool:
        return bool(self.stick or self.buttons or self.extras)

    def key(self) -> str:
        p = max(1, self.players or 1)
        k = f"p{p}{'a' if self.alt else ''}-{('j' + self.stick) if self.stick else 'nostick'}-b{self.buttons}"
        k += ''.join('-' + e for e in self.extras)
        if self.labels:
            k += '-L' + hashlib.sha1('|'.join(self.labels).encode()).hexdigest()[:8]
        if self.emu:
            k += '-E' + hashlib.sha1(self.emu.encode()).hexdigest()[:8]
        return k

    def with_emu(self, emu: str) -> 'Sig':
        s = Sig.__new__(Sig)
        for a in Sig.__slots__:
            setattr(s, a, getattr(self, a))
        s.emu = emu
        return s


def to_int(v, default=0) -> int:
    m = re.search(r'\d+', str(v or ''))
    return int(m.group()) if m else default


def ways_of(v) -> str | None:
    s = str(v or '').lower()
    if not s.strip():
        return None
    if 'vertical' in s or 'v' == s.strip()[-1:]:
        return '2v'
    n = to_int(s)
    if n >= 8 or n == 0 and 'analog' in s:
        return '8' if n else 'analog'
    if n == 4 or n == 5:
        return '4'
    if n in (2, 3):
        return '2h'
    if n == 1:
        return None
    return '8' if n > 8 else None


def sig_from_games_json(c: dict) -> Sig:
    ct = str(c.get('ctrltype') or '').lower()
    extras = set()
    for k, e in (('trackball', 'trackball'), ('spinner', 'spinner'), ('lightgun', 'lightgun'), ('wheel', 'wheel'),
                 ('flightStick', 'flightstick')):
        if c.get(k):
            extras.add(e)
    stick = ways_of(c.get('ways'))
    if 'wheel' in extras:
        stick = '2h'                                   # steering lands on the stick's left/right
    elif 'flightstick' in extras or (c.get('analogStick') and not c.get('gamepad') and not c.get('joystick')):
        stick = stick or 'analog'
    elif c.get('joystick') or c.get('gamepad') or 'joystick' in ct or 'gamepad' in ct:
        stick = stick or '8'
    m = re.search(r'(\d)-way', ct)
    if m and stick in (None, '8') and 'wheel' not in extras:
        stick = ways_of(m.group(1)) or stick
    if 'lightgun' in extras and not (c.get('joystick') or c.get('gamepad')):
        stick = None
    labels = c.get('labels') or c.get('functions') or c.get('buttonNames') or ()
    if isinstance(labels, dict):
        labels = [labels[k] for k in sorted(labels, key=lambda x: to_int(x))]
    return Sig(to_int(c.get('players'), 1), False, stick, min(to_int(c.get('buttons')), 9), extras,
               [str(x) for x in labels][:9])


def sig_from_meta(players, ctrltype, buttons, joyways) -> Sig | None:
    if not any(str(x or '').strip() for x in (players, ctrltype, buttons, joyways)):
        return None
    ct = str(ctrltype or '').lower()
    extras = set()
    for pat, e in ((r'track|roller', 'trackball'), (r'dial|spinner', 'spinner'), (r'gun', 'lightgun'),
                   (r'paddle', 'paddle'), (r'wheel|steer', 'wheel'), (r'pedal', 'pedal'),
                   (r'flight|yoke', 'flightstick'), (r'double|twin|dual', 'twinstick'), (r'key', 'keypad')):
        if re.search(pat, ct):
            extras.add(e)
    stick = ways_of(joyways)
    if stick is None:
        m = re.search(r'(\d+)[ -]?way', ct)
        if m:
            stick = ways_of(m.group(1))
        elif re.search(r'joy|stick|gamepad|pad\b', ct) and 'flightstick' not in extras:
            stick = '8'
        elif 'flightstick' in extras or 'analog' in ct:
            stick = 'analog'
        elif 'wheel' in extras:
            stick = '2h'
    alt = bool(re.search(r'alt', str(players or ''), re.I))
    return Sig(to_int(players, 1), alt, stick, min(to_int(buttons), 9), extras)


def sig_from_mame(entry) -> Sig | None:
    """entry = [players, [[type, buttons, ways], ...]] (player-1 controls)"""
    players, ctrls = entry
    if not ctrls:
        return None
    extras, stick, buttons = set(), None, 0
    for t, b, w in ctrls:
        buttons = max(buttons, b)
        if t in ('joy', 'doublejoy', 'triplejoy'):
            s = ways_of(w) or '8'
            stick = s if stick in (None, 'analog') or s == '8' else stick
            if t != 'joy':
                extras.add('twinstick')
        elif t == 'stick':
            stick = stick or 'analog'
        elif t in ('trackball', 'mouse'):
            extras.add('trackball')
        elif t in ('dial', 'positional'):
            extras.add('spinner')
        elif t == 'paddle':
            extras.add('paddle')
        elif t == 'pedal':
            extras.add('pedal')
        elif t == 'lightgun':
            extras.add('lightgun')
        elif t in ('keypad', 'keyboard', 'mahjong', 'hanafuda', 'gambling'):
            extras.add('keypad')
    return Sig(players, False, stick, min(buttons, 9), extras)


# ------------------------------------------------------------------ MAME -listxml cache
def mame_inputs(exe: Path | None, cache: Path, log) -> dict:
    if not exe or not exe.exists():
        if cache.exists():
            return json.loads(cache.read_text(encoding='utf-8')).get('machines', {})
        return {}
    st = exe.stat()
    stamp = f'{exe.name}|{st.st_size}|{int(st.st_mtime)}'
    if cache.exists():
        try:
            d = json.loads(cache.read_text(encoding='utf-8'))
            if d.get('stamp') == stamp:
                return d['machines']
        except (OSError, ValueError):
            pass
    log(f'asking {exe} -listxml once (cached in {cache}) ...')
    t0 = time.time()
    proc = subprocess.Popen([str(exe), '-listxml'], cwd=str(exe.parent), stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    machines = {}
    for _ev, el in ET.iterparse(proc.stdout, events=('end',)):
        if el.tag != 'machine' and el.tag != 'game':
            continue
        a = el.attrib
        if a.get('isbios') == 'yes' or a.get('isdevice') == 'yes' or a.get('runnable') == 'no':
            el.clear()
            continue
        inp = el.find('input')
        if inp is not None:
            ctrls = []
            for c in inp.findall('control'):
                if c.get('player', '1') != '1':
                    continue
                ctrls.append([c.get('type', ''), to_int(c.get('buttons')), c.get('ways', '')])
            if not ctrls and inp.get('buttons'):               # pre-0.150 layout: attributes on <input>
                ctrls.append([inp.get('control', 'joy'), to_int(inp.get('buttons')), inp.get('ways', '')])
            machines[a['name'].lower()] = [to_int(inp.get('players'), 1), ctrls]
        el.clear()
    proc.wait()
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_text(json.dumps({'stamp': stamp, 'machines': machines}, separators=(',', ':')), encoding='utf-8')
    log(f'  {len(machines)} machines in {time.time() - t0:.0f}s')
    return machines


# ------------------------------------------------------------------ drawing
class Card:
    def __init__(self):
        self.base = Image.new('RGBA', (W * S, H * S), (0, 0, 0, 0))
        self.glow = Image.new('RGBA', (W * S, H * S), (0, 0, 0, 0))
        self.d = ImageDraw.Draw(self.base)
        self.g = ImageDraw.Draw(self.glow)

    @staticmethod
    def r(*xy):
        return [v * S for v in xy]

    def text(self, xy, s, f, fill, anchor='la', glow=None):
        self.d.text(self.r(*xy), s, font=f, fill=fill, anchor=anchor)
        if glow:
            self.g.text(self.r(*xy), s, font=f, fill=glow, anchor=anchor)

    def width(self, s, f) -> float:
        return f.getlength(s) / S

    def finish(self) -> Image.Image:
        blurred = self.glow.filter(ImageFilter.GaussianBlur(9 * S))
        out = Image.alpha_composite(self.base_plate(), blurred)
        out = Image.alpha_composite(out, blurred)
        out = Image.alpha_composite(out, self.base)
        return out.resize((W, H), Image.LANCZOS)

    def base_plate(self):
        p = Image.new('RGBA', (W * S, H * S), (0, 0, 0, 0))
        d = ImageDraw.Draw(p)
        d.rounded_rectangle(self.r(2, 2, W - 2, H - 2), radius=22 * S, fill=BG + (236,),
                            outline=MAGENTA + (200,), width=3 * S)
        return p


def tri(cx, cy, ang, size):
    import math
    pts = []
    for da, rr in ((0, size), (140, size * 0.8), (-140, size * 0.8)):
        a = math.radians(ang + da)
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    return pts


def draw_stick(c: Card, cx, cy, stick, color_on):
    import math
    on = stick is not None
    ring = CYAN if on else FAINT
    # gate plate + base
    c.d.ellipse(c.r(cx - 86, cy - 86, cx + 86, cy + 86), fill=CARD + (255,), outline=FAINT + (255,), width=2 * S)
    if stick == '4':
        dirs = [0, 90, 180, 270]
    elif stick == '2h':
        dirs = [0, 180]
    elif stick == '2v':
        dirs = [90, 270]
    elif stick in ('8',):
        dirs = list(range(0, 360, 45))
    else:
        dirs = []
    if stick == 'analog':
        c.d.ellipse(c.r(cx - 70, cy - 70, cx + 70, cy + 70), outline=CYAN + (255,), width=4 * S)
        c.g.ellipse(c.r(cx - 70, cy - 70, cx + 70, cy + 70), outline=CYAN + (255,), width=6 * S)
        for a in range(0, 360, 30):
            x, y = cx + 70 * math.cos(math.radians(a)), cy + 70 * math.sin(math.radians(a))
            c.d.ellipse(c.r(x - 4, y - 4, x + 4, y + 4), fill=CYAN + (255,))
    for a in range(0, 360, 45):
        lit = a in dirs
        x, y = cx + 70 * math.cos(math.radians(a)), cy + 70 * math.sin(math.radians(a))
        size = 15 if lit else 9
        pts = [(px * S, py * S) for px, py in tri(x, y, a, size)]
        if lit:
            c.d.polygon(pts, fill=CYAN + (255,))
            c.g.polygon(pts, fill=CYAN + (255,))
        elif stick != 'analog':
            c.d.polygon(pts, fill=FAINT + (150,))
    if stick in ('2h', '2v'):        # slot gate
        if stick == '2h':
            box = (cx - 54, cy - 8, cx + 54, cy + 8)
        else:
            box = (cx - 8, cy - 54, cx + 8, cy + 54)
        c.d.rounded_rectangle(c.r(*box), radius=8 * S, outline=CYAN + (200,), width=2 * S)
    # shaft + balltop
    c.d.ellipse(c.r(cx - 12, cy - 12, cx + 12, cy + 12), fill=(40, 44, 58, 255))
    bt = color_on if on else FAINT
    c.d.ellipse(c.r(cx - 34, cy - 34, cx + 34, cy + 34), fill=bt + (255,))
    if on:
        c.g.ellipse(c.r(cx - 34, cy - 34, cx + 34, cy + 34), fill=bt + (200,))
    c.d.ellipse(c.r(cx - 22, cy - 26, cx - 2, cy - 10), fill=(255, 255, 255, 110 if on else 40))


def fit_label(c: Card, s, maxw, px=22):
    f = font('semi', px)
    if c.width(s, f) <= maxw:
        return s
    while s and c.width(s + '…', f) > maxw:
        s = s[:-1]
    return s + '…'


def draw_buttons(c: Card, x0, y0, sig: Sig, rows, cols):
    n = rows * cols
    labels = sig.labels
    rad = (27 if labels else 33) if rows <= 2 else 24
    gapx = 92 if cols <= 3 else max(60, 280 // cols)
    gapy = 112 if labels else 96
    if labels and rows <= 2:
        y0 -= 26
    if rows > 2:
        gapy = 70
    for i in range(n):
        r_, k = divmod(i, cols)
        cx = x0 + k * gapx + (14 if r_ == 0 else 0)        # top row nudged right, like a real panel
        cy = y0 + r_ * gapy
        lit = i < sig.buttons
        col = BTN_COLORS[i % len(BTN_COLORS)]
        box = c.r(cx - rad, cy - rad, cx + rad, cy + rad)
        if lit:
            c.d.ellipse(c.r(cx - rad - 5, cy - rad - 5, cx + rad + 5, cy + rad + 5), fill=(0, 0, 0, 255))
            c.d.ellipse(box, fill=col + (255,))
            c.g.ellipse(box, fill=col + (255,))
            c.d.ellipse(c.r(cx - rad + 8, cy - rad + 6, cx + rad - 8, cy - 4), fill=(255, 255, 255, 60))
            c.text((cx, cy + 1), str(i + 1), font('black', 34), BG + (255,), 'mm')
        else:
            c.d.ellipse(box, fill=CARD2 + (255,), outline=FAINT + (255,), width=3 * S)
        if lit and i < len(labels) and labels[i]:
            c.text((cx, cy + rad + 15), fit_label(c, labels[i].upper(), gapx - 4), font('semi', 22), TEXT + (255,), 'mm')
    if sig.buttons > n:
        c.text((x0 + (cols - 1) * gapx + rad + 6, y0 + (rows - 1) * gapy + rad), '+' if sig.buttons >= 7 else f'+{sig.buttons - n}',
               font('black', 34), AMBER + (255,), 'ls')


def draw_icon(c: Card, kind, cx, cy, col, size=24):
    import math
    rgba = col + (255,)
    s = size
    d, g = c.d, c.g
    if kind == 'trackball':
        d.ellipse(c.r(cx - s, cy - s, cx + s, cy + s), outline=rgba, width=3 * S)
        d.ellipse(c.r(cx - s + 6, cy - s + 6, cx + s - 6, cy + s - 6), fill=rgba)
        d.ellipse(c.r(cx - s + 11, cy - s + 10, cx - 2, cy - 3), fill=(255, 255, 255, 140))
        g.ellipse(c.r(cx - s, cy - s, cx + s, cy + s), fill=rgba)
    elif kind in ('spinner', 'paddle'):
        d.ellipse(c.r(cx - s + 4, cy - s + 4, cx + s - 4, cy + s - 4), fill=rgba)
        g.ellipse(c.r(cx - s, cy - s, cx + s, cy + s), fill=rgba)
        if kind == 'spinner':
            for a in range(0, 360, 30):
                x1, y1 = cx + (s - 4) * math.cos(math.radians(a)), cy + (s - 4) * math.sin(math.radians(a))
                x2, y2 = cx + (s - 11) * math.cos(math.radians(a)), cy + (s - 11) * math.sin(math.radians(a))
                d.line(c.r(x1, y1, x2, y2), fill=BG + (255,), width=2 * S)
            d.arc(c.r(cx - s - 1, cy - s - 1, cx + s + 1, cy + s + 1), 200, 330, fill=TEXT + (255,), width=3 * S)
        else:
            d.line(c.r(cx, cy, cx + (s - 7) * 0.6, cy - (s - 7) * 0.8), fill=BG + (255,), width=4 * S)
    elif kind == 'lightgun':
        poly = [(cx - s, cy - s * .55), (cx + s, cy - s * .55), (cx + s, cy - s * .05), (cx - s * .2, cy - s * .05),
                (cx - s * .35, cy + s), (cx - s * .95, cy + s), (cx - s * .7, cy - s * .05), (cx - s, cy - s * .05)]
        pts = [(x * S, y * S) for x, y in poly]
        d.polygon(pts, fill=rgba)
        g.polygon(pts, fill=rgba)
    elif kind == 'wheel':
        d.ellipse(c.r(cx - s, cy - s, cx + s, cy + s), outline=rgba, width=5 * S)
        d.ellipse(c.r(cx - 6, cy - 6, cx + 6, cy + 6), fill=rgba)
        for a in (90, 210, 330):
            d.line(c.r(cx, cy, cx + s * math.cos(math.radians(a)), cy + s * math.sin(math.radians(a))), fill=rgba,
                   width=4 * S)
        g.ellipse(c.r(cx - s, cy - s, cx + s, cy + s), outline=rgba, width=6 * S)
    elif kind == 'pedal':
        d.rounded_rectangle(c.r(cx - s * .5, cy - s, cx + s * .5, cy + s), radius=5 * S, fill=rgba)
        for k in range(3):
            yy = cy - s * .55 + k * s * .5
            d.line(c.r(cx - s * .3, yy, cx + s * .3, yy), fill=BG + (255,), width=2 * S)
        g.rounded_rectangle(c.r(cx - s * .5, cy - s, cx + s * .5, cy + s), radius=5 * S, fill=rgba)
    elif kind == 'flightstick':
        d.rounded_rectangle(c.r(cx - s * .35, cy - s, cx + s * .35, cy + s * .35), radius=8 * S, fill=rgba)
        d.rounded_rectangle(c.r(cx - s, cy + s * .55, cx + s, cy + s), radius=4 * S, fill=rgba)
        g.rounded_rectangle(c.r(cx - s * .35, cy - s, cx + s * .35, cy + s * .35), radius=8 * S, fill=rgba)
    elif kind == 'twinstick':
        for dx in (-s * .55, s * .55):
            d.line(c.r(cx + dx, cy, cx + dx, cy + s), fill=rgba, width=4 * S)
            d.ellipse(c.r(cx + dx - s * .45, cy - s * .7, cx + dx + s * .45, cy + s * .2), fill=rgba)
        g.ellipse(c.r(cx - s, cy - s, cx + s, cy + s), fill=rgba)
    elif kind == 'keypad':
        for i in range(3):
            for j in range(3):
                x, y = cx - s + j * s * .72, cy - s + i * s * .72
                d.rounded_rectangle(c.r(x, y, x + s * .56, y + s * .56), radius=2 * S, fill=rgba)
        g.rectangle(c.r(cx - s, cy - s, cx + s, cy + s), fill=rgba)


def render_card(sig: Sig, rows: int, cols: int) -> Image.Image:
    c = Card()
    # ---- left: one player's panel
    c.d.rounded_rectangle(c.r(18, 18, 552, H - 18), radius=18 * S, fill=CARD + (255,), outline=FAINT + (255,),
                          width=2 * S)
    c.d.rounded_rectangle(c.r(18, 18, 552, 24), radius=3 * S, fill=PLAYER[0] + (255,))
    c.text((36, 50), 'P1', font('black', 26), PLAYER[0] + (255,), 'lm', glow=PLAYER[0] + (160,))
    if not sig.stick and sig.extras:          # the game's own control takes the stick's place
        c.d.ellipse(c.r(50, 80, 222, 252), fill=CARD + (255,), outline=FAINT + (255,), width=2 * S)
        draw_icon(c, sig.extras[0], 136, 166, GREEN, 54)
    else:
        draw_stick(c, 136, 166, sig.stick, PLAYER[0])
    draw_buttons(c, 300, 108 if rows <= 2 else 80, sig, rows, cols)
    # ---- right: facts
    x0, x1 = 584, W - 26
    p = max(1, sig.players or 1)
    ptxt = '1 PLAYER' if p == 1 else ('4+ PLAYERS' if p > 4 else f'1–{p} PLAYERS')
    c.text((x0, 58), ptxt, font('black', 54), TEXT + (255,), 'lm')
    # player dots
    for i in range(4):
        dx = x1 - 14 - (3 - i) * 36
        lit = i < p
        col = PLAYER[i]
        if lit:
            c.d.ellipse(c.r(dx - 13, 45, dx + 13, 71), fill=col + (255,))
            c.g.ellipse(c.r(dx - 13, 45, dx + 13, 71), fill=col + (255,))
        else:
            c.d.ellipse(c.r(dx - 12, 46, dx + 12, 70), outline=FAINT + (255,), width=3 * S)
    if sig.alt:
        c.text((x1, 92), 'TAKE TURNS', font('semi', 22), AMBER + (255,), 'rm')
    # stick + buttons lines
    if sig.stick:
        st, scol = STICK_TEXT[sig.stick], CYAN
        if 'twinstick' in sig.extras:
            st = 'TWIN 8-WAY STICKS' if sig.stick == '8' else 'TWIN STICKS'
    elif sig.extras:
        st, scol = EXTRA_LABEL[sig.extras[0]] + ' GAME', GREEN
    else:
        st, scol = 'NO STICK', DIM
    c.text((x0, 136), st, font('black', 38), scol + (255,), 'lm', glow=scol + (90,))
    b = sig.buttons
    bt = 'NO BUTTONS' if b == 0 else ('1 BUTTON' if b == 1 else ('7+ BUTTONS' if b >= 7 else f'{b} BUTTONS'))
    if 'keypad' in sig.extras:
        bt = 'NO KEYPAD HERE'
    c.text((x0, 188), bt, font('black', 38), (MAGENTA if b else DIM) + (255,), 'lm', glow=(MAGENTA + (90,)) if b else None)
    # START + COIN pills, right column
    for (label, col, y) in (('START', TEXT, 136), ('COIN', AMBER, 188)):
        f = font('bold', 24)
        wdt = c.width(label, f) + 34
        c.d.rounded_rectangle(c.r(x1 - wdt, y - 20, x1, y + 20), radius=20 * S, outline=col + (255,), width=3 * S)
        c.text((x1 - wdt / 2, y + 1), label, f, col + (255,), 'mm')
    # extras chips
    x = x0
    y = 236 if sig.emu else 248
    if sig.emu:                                # which emulator runs it: the first thing to know when a game will not start
        f = font('semi', 20)
        c.text((x0, 276), 'RUNS ON', f, DIM + (255,), 'lm')
        c.text((x0 + c.width('RUNS ON', f) + 12, 276), fit_label(c, sig.emu, x1 - x0 - 110, 20), font('semi', 20),
               TEXT + (255,), 'lm')
    # chips for the special controls not already named on the stick line
    shown = [e for e in sig.extras if e != 'twinstick'] if sig.stick else list(sig.extras[1:])
    for e in shown:
        lab = EXTRA_LABEL[e]
        f = font('black', 28)
        wdt = 34 + 14 + c.width(lab, f)
        if x + wdt > x1:
            break
        draw_icon(c, e, x + 17, y, GREEN, 17)
        c.text((x + 44, y + 1), lab, f, GREEN + (255,), 'lm')
        x += wdt + 26
    if not shown:
        hint = 'JOYSTICK + BUTTONS' if sig.stick else ('BUTTONS ONLY' if sig.buttons else '')
        if not sig.stick and sig.extras:
            hint = HOW_TO.get(sig.extras[0], '')
        c.text((x0, y), hint, font('semi', 24), DIM + (255,), 'lm')
    return c.finish()


# ------------------------------------------------------------------ RetroFE collections
def read_conf(p: Path) -> dict:
    out = {}
    if p.exists():
        for line in p.read_text(encoding='utf-8', errors='replace').splitlines():
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            k, v = line.split('=', 1)
            out[k.strip().lower()] = v.strip()
    return out


def read_list(p: Path) -> list[str]:
    if not p.exists():
        return []
    return [ln.strip() for ln in p.read_text(encoding='utf-8', errors='replace').splitlines()
            if ln.strip() and not ln.strip().startswith('#')]


BAD = re.compile(r'[<>:"/\\|?*\x00-\x1f]')
SKIP_DEFAULT = re.compile(r'^(_|zzz|main$)', re.I)


class Emulators:
    """What runs a game, for the card's RUNS ON line: the collection's launcher (launchers.windows/<launcher>.conf),
    the RetroArch core from its arguments, TeknoParrot's emulator type from the game's profile, and for PC .bat
    games the program the .bat starts."""

    def __init__(self, root: Path):
        self.root = root
        self.cols: dict = {}

    def collection(self, col: str):
        if col in self.cols:
            return self.cols[col]
        conf = read_conf(self.root / 'collections' / col / 'settings.conf')
        ln = (conf.get('launcher') or '').replace('%ITEM_COLLECTION_NAME%', col)
        lc = read_conf(self.root / 'launchers.windows' / f'{ln}.conf') if ln else {}
        exe, args = lc.get('executable', '').replace('/', '\\'), lc.get('arguments', '')
        label, kind, base = ln, None, None
        if exe:
            p = Path(exe)
            stem, folder = p.stem.lower(), p.parent.name
            if 'retroarch' in stem:
                m = re.search(r'([\w\-]+?)_libretro', args, re.I)
                label = f'{folder} · {m.group(1)}' if m else folder
            elif 'teknoparrot' in stem:
                label, kind, base = 'TeknoParrot', 'tp', self.root / p.parent
            elif stem == 'cmd':
                if p.parent.parts[:1] and p.parent.parts[0].lower() == 'collections':
                    label, kind = 'PC', 'pc'
                else:
                    label = folder or ln
            else:
                label = f'{folder} · {p.name}' if folder and folder.lower() != stem else p.name
        self.cols[col] = (label, kind, base, conf)
        return self.cols[col]

    def item(self, col: str, item: str) -> str:
        label, kind, base, conf = self.collection(col)
        try:
            if kind == 'pc':
                lp = conf.get('list.path')
                ldir = (self.root / lp) if lp else (self.root / 'collections' / col / 'roms')
                for ext in ('.bat', '.cmd'):
                    f = ldir / f'{item}{ext}'
                    if f.exists():
                        txt = f.read_text(encoding='utf-8', errors='replace')
                        m = re.search(r'GAMENAME=([^"\r\n]+)', txt, re.I) or re.search(r'([\w .\-]+\.exe)', txt, re.I)
                        if m:
                            return f'PC · {m.group(1).strip()}'
            elif kind == 'tp':
                for sub in ('UserProfiles', 'GameProfiles'):
                    f = base / sub / f'{item}.xml'
                    if f.exists():
                        m = re.search(r'<EmulatorType>([^<]+)</EmulatorType>', f.read_text(encoding='utf-8', errors='replace'))
                        if m and m.group(1).strip().lower() != 'teknoparrot':
                            return f'TeknoParrot · {m.group(1).strip()}'
                        break
        except OSError:
            pass
        return label


def norm(s: str) -> str:
    return re.sub(r'[^a-z0-9]', '', re.sub(r'\(.*?\)', '', str(s)).lower())


class Frontend:
    def __init__(self, root: Path):
        self.root = root
        self.cdir = root / 'collections'

    def is_game_collection(self, name: str) -> bool:
        d = self.cdir / name
        conf = read_conf(d / 'settings.conf')
        return bool(conf.get('launcher') or conf.get('list.path') or (d / 'include.txt').exists()) \
            and not (d / 'menu.txt').exists()

    def sources_of(self, name: str) -> list[str]:
        """merged (.sub) collections show their source collections' art -> expand to the sources"""
        d = self.cdir / name
        if self.is_game_collection(name):
            return [name]
        return [s.stem for s in d.glob('*.sub') if (self.cdir / s.stem).is_dir()]

    def items(self, name: str, meta_names: dict, catalog_items: dict) -> list[str]:
        d = self.cdir / name
        conf = read_conf(d / 'settings.conf')
        found: dict[str, str] = {}

        def add(it):
            it = it.strip()
            if it and it != '*' and not BAD.search(it):
                found.setdefault(it.lower(), it)

        lp = conf.get('list.path')
        ldir = (self.root / lp) if lp else (d / 'roms')
        exts = {('.' + e.strip().lower().lstrip('.')) for e in conf.get('list.extensions', '').split(',') if e.strip()}
        listed = False
        if ldir.is_dir():
            listed = True
            with os.scandir(ldir) as it:
                for e in it:
                    if e.is_file() and (not exts or os.path.splitext(e.name)[1].lower() in exts):
                        add(os.path.splitext(e.name)[0])
        inc = read_list(d / 'include.txt')
        if inc:
            found.clear()
            for i in inc:
                add(i)
        if not listed and not (d / 'include.txt').exists():
            # list folder missing on this machine (e.g. MAME roms live elsewhere): every metadata row is an item
            mtype = conf.get('metadata.type', name).replace('%ITEM_COLLECTION_NAME%', name)
            for i in meta_names.get(mtype.lower(), ()):
                add(i)
        for i in catalog_items.get(name.lower(), ()):
            add(i)
        for pl in (d / 'playlists').glob('*.txt') if (d / 'playlists').is_dir() else ():
            for ln in read_list(pl):
                m = re.match(r'^_(.+?):(.*)$', ln)
                if m:
                    if m.group(1).lower() == name.lower():
                        add(m.group(2))
                else:
                    add(ln)
        for x in read_list(d / 'exclude.txt'):
            found.pop(x.lower(), None)
        return list(found.values())


# ------------------------------------------------------------------ main
def main(argv=None):
    ap = argparse.ArgumentParser(description='Per-game control panel cards (am_controls) for RetroFE.')
    ap.add_argument('--retrofe', required=True, type=Path)
    ap.add_argument('--manifest', required=True, type=Path)
    ap.add_argument('--collections', help='comma list; merged (.sub) collections expand to their sources')
    ap.add_argument('--force', action='store_true', help='re-render cards and replace am_controls files that are not ours')
    ap.add_argument('--preview', type=Path, help='contact sheet of every signature card')
    ap.add_argument('--rows', type=int, default=2)
    ap.add_argument('--cols', type=int, default=3)
    ap.add_argument('--mame', type=Path, help='MAME exe for -listxml (default: emulators/mame/mame64.exe from the mame launcher)')
    ap.add_argument('--dry-run', action='store_true', help='resolve and count only; write nothing')
    ap.add_argument('--list-sigs', action='store_true', help='print every signature with its game count')
    a = ap.parse_args(argv)
    t0 = time.time()
    log = lambda m: print(m, flush=True)
    root, man = a.retrofe.resolve(), a.manifest.resolve()
    fe = Frontend(root)
    cards_dir = man / 'controls-cards'
    state_file = cards_dir / 'index.json'
    state = {}
    if state_file.exists():
        try:
            state = json.loads(state_file.read_text(encoding='utf-8'))
        except ValueError:
            state = {}
    copies: dict = state.get('copies', {})

    # ---- data: games.json
    by_item, by_norm = {}, {}
    catalog_items: dict[str, list] = {}
    gj = man / 'games.json'
    if gj.exists():
        for g in json.loads(gj.read_text(encoding='utf-8-sig')).get('games', []):
            c = g.get('controls')
            if not c:
                continue
            sig = sig_from_games_json(c)
            for s in g.get('sources') or []:
                if s.get('collection') and s.get('item'):
                    by_item[(s['collection'].lower(), s['item'].lower())] = sig
                    catalog_items.setdefault(s['collection'].lower(), []).append(s['item'])
            keys = [g.get('id')]
            for v in (g.get('variants') or {}).values():
                keys += [v.get('profile'), v.get('rom')]
                rc = v.get('retrofeCollection')
                for k in (v.get('profile'), v.get('rom')):
                    if isinstance(rc, str) and k:
                        by_item.setdefault((rc.lower(), str(k).lower()), sig)
            for k in keys:
                if k:
                    by_norm.setdefault(norm(k), sig)
    # ---- data: hand-written controls for games no database knows (PC ports ...): "<collection>/<item>" -> controls
    overrides = {}
    for of in (Path(__file__).with_name('panel-controls-overrides.json'), man / 'panel-controls-overrides.json'):
        if of.exists():
            for k, c in json.loads(of.read_text(encoding='utf-8-sig')).items():
                if not k.startswith('_') and isinstance(c, dict):
                    overrides[k.lower()] = sig_from_games_json(c)
    emus = Emulators(root)
    # ---- data: meta.db
    meta, meta_names = {}, {}
    mdb = root / 'meta.db'
    if mdb.exists():
        con = sqlite3.connect(f'file:{mdb}?mode=ro', uri=True)
        for col, name, pl, ct, bt, jw in con.execute(
                'select collectionName, name, players, ctrltype, buttons, joyways from Meta'):
            meta_names.setdefault(col.lower(), []).append(name)
            s = sig_from_meta(pl, ct, bt, jw)
            if s:
                meta[(col.lower(), name.lower())] = s
        con.close()
    # ---- collections
    if a.collections:
        cols = []
        for n in a.collections.split(','):
            n = n.strip()
            if (fe.cdir / n).is_dir():
                cols += [x for x in fe.sources_of(n) if x not in cols]
            else:
                log(f'no collection {n}')
    else:
        cols = [d.name for d in sorted(fe.cdir.iterdir()) if d.is_dir() and not SKIP_DEFAULT.match(d.name)
                and fe.is_game_collection(d.name)]
    # ---- MAME (only when a MAME-metadata collection is in play)
    mtypes = {c: read_conf(fe.cdir / c / 'settings.conf').get('metadata.type', c).replace('%ITEM_COLLECTION_NAME%', c)
              for c in cols}
    mame = {}
    if any(v.lower() == 'mame' for v in mtypes.values()):
        exe = a.mame
        if not exe:
            lc = read_conf(root / 'launchers.windows' / 'mame.conf').get('executable')
            exe = (root / lc) if lc else None
            if not exe or not exe.exists():
                cands = sorted((root / 'emulators' / 'mame').glob('mame*.exe'), key=lambda p: p.stat().st_size)
                exe = cands[-1] if cands else None
        mame = mame_inputs(exe, man / 'mame-inputs.json', log)
    t_data = time.time()

    # ---- resolve every item to a signature
    plan: dict[str, list] = {}           # collection -> [(item, sigkey)]
    sigs: dict[str, Sig] = {}
    src_count = {'games.json': 0, 'meta.db': 0, 'mame': 0}
    unknown: dict[str, int] = {}
    unknown_examples: dict[str, list] = {}
    def mtype_of(c):
        if c not in mtypes:
            mtypes[c] = read_conf(fe.cdir / c / 'settings.conf').get('metadata.type', c).replace('%ITEM_COLLECTION_NAME%', c)
        return mtypes[c]

    for col in cols:
        # a game list that also merges other systems in (LEGENDS' Arcades has TeknoParrot.sub, Naomi.sub ...) shows
        # those games with ITS OWN art folder first: they need their card here too, or a stale one wins
        pairs, seen_items = [], set()
        for it in fe.items(col, meta_names, catalog_items):
            seen_items.add(it.lower()); pairs.append((col, it))
        for sf in sorted((fe.cdir / col).glob('*.sub')):
            sc = sf.stem
            if sc.lower() == col.lower() or SKIP_DEFAULT.match(sc) or not (fe.cdir / sc).is_dir() or not fe.is_game_collection(sc):
                continue
            only = {x.lower() for x in read_list(sf)}
            for it in fe.items(sc, meta_names, catalog_items):
                if (not only or it.lower() in only) and it.lower() not in seen_items:
                    seen_items.add(it.lower()); pairs.append((sc, it))
        lst = plan.setdefault(col, [])
        for scol, it in pairs:
            mt = mtype_of(scol).lower()
            k = it.lower()
            s = overrides.get(f'{scol.lower()}/{k}') or by_item.get((scol.lower(), k)) or by_norm.get(norm(it))
            src = 'games.json'
            if s is None:
                s = meta.get((mt, k)) or meta.get((scol.lower(), k))
                src = 'meta.db'
                if s is not None and not s.known() and mt == 'mame' and k in mame:
                    s = None
            if (s is None or not s.known()) and mt == 'mame' and k in mame:
                s, src = sig_from_mame(mame[k]), 'mame'
            if s is None or not s.known():
                unknown[col] = unknown.get(col, 0) + 1
                ex = unknown_examples.setdefault(col, [])
                if len(ex) < 5:
                    ex.append(it)
                continue
            src_count[src] += 1
            s = s.with_emu(emus.item(scol, it))
            key = s.key()
            sigs.setdefault(key, s)
            lst.append((it, key))
    t_resolve = time.time()

    # ---- render one card per signature
    cards_dir.mkdir(parents=True, exist_ok=True)
    rendered = 0
    old_ver = state.get('version')
    for key, s in sigs.items():
        p = cards_dir / f'{key}.png'
        if p.exists() and not a.force and old_ver == CARD_VERSION:
            continue
        if a.dry_run:
            continue
        buf = io.BytesIO()
        render_card(s, a.rows, a.cols).save(buf, 'PNG', optimize=True)
        # rewrite IN PLACE (truncate the same file) so every hard link to it - and every shard - shows the new card
        for q in [p] + sorted(cards_dir.glob(f'{key}~*.png')):
            with open(q, 'r+b' if q.exists() else 'wb') as fh:
                fh.truncate(0)
                fh.write(buf.getvalue())
        rendered += 1
    t_render = time.time()
    # NTFS allows 1023 hard links per file: popular signatures spill into shards <sig>~2.png, <sig>~3.png ...
    ours_ino = {}                         # inode -> signature key (main card or shard)
    shards: dict[str, list] = {}
    for p in sorted(cards_dir.glob('*.png')):
        st = os.stat(p)
        k = p.stem.split('~')[0]
        ours_ino[st.st_ino] = k
        shards.setdefault(k, []).append([p, st.st_nlink])
    cards_dev = os.stat(cards_dir).st_dev

    def link_card(key, dst) -> bool:
        """hard-link dst to a shard of key with room; False when linking is impossible (other volume)"""
        lst = shards[key]
        while True:
            p, n = lst[-1]
            if n < LINK_MAX:
                try:
                    os.link(p, dst)
                    lst[-1][1] += 1
                    return True
                except OSError as ex:
                    if getattr(ex, 'winerror', None) != 1142 and ex.errno != 31:   # 1142/EMLINK = too many links
                        return False
            q = cards_dir / f'{key}~{len(lst) + 1}.png'
            if not q.exists():
                shutil.copyfile(lst[0][0], q)
            st = os.stat(q)
            ours_ino[st.st_ino] = key
            lst.append([q, st.st_nlink])

    # ---- link items
    linked = already = foreign = copied = relinked = stale = 0
    per_col = {}
    for col, lst in plan.items():
        if not lst:
            continue
        adir = fe.cdir / col / 'medium_artwork' / 'am_controls'
        existing = {}
        if adir.is_dir():
            with os.scandir(adir) as it:
                for e in it:
                    if e.name.lower().endswith('.png'):
                        existing[e.name[:-4].lower()] = e
        elif not a.dry_run:
            adir.mkdir(parents=True, exist_ok=True)
        n_col = 0
        for item, key in lst:
            dst = adir / f'{item}.png'
            e = existing.get(item.lower())
            if e is not None:
                ino = e.inode()
                if ours_ino.get(ino) == key:
                    already += 1
                    continue
                cp = copies.get(str(dst).lower())
                mine = ino in ours_ino or cp is not None
                if cp == key and not a.force and os.stat(e.path).st_dev != cards_dev:
                    already += 1              # a copy because the art lives on another volume: still right
                    continue
                if not mine and not a.force:
                    foreign += 1
                    continue
                if a.dry_run:
                    relinked += 1
                    continue
                os.unlink(e.path)
                relinked += 1
            elif a.dry_run:
                linked += 1
                continue
            if link_card(key, dst):
                copies.pop(str(dst).lower(), None)
            else:
                shutil.copyfile(cards_dir / f'{key}.png', dst)
                copies[str(dst).lower()] = key
                copied += 1
            linked += 1
            n_col += 1
        # cards of ours that no listed game uses any more (an earlier run saw other items): a stale card would win
        # over the right one, so remove it. Files that are not ours are left alone.
        planned = {item.lower() for item, _ in lst}
        for name, e in existing.items():
            if name in planned:
                continue
            try:
                if e.inode() in ours_ino or str(adir / e.name).lower() in copies:
                    if not a.dry_run:
                        os.unlink(e.path)
                        copies.pop(str(adir / e.name).lower(), None)
                    stale += 1
            except OSError:
                pass
        per_col[col] = (len(lst), n_col)

    # ---- state + preview
    counts = {}
    for lst in plan.values():
        for _, k in lst:
            counts[k] = counts.get(k, 0) + 1
    if not a.dry_run:
        state = {'version': CARD_VERSION, 'rows': a.rows, 'cols': a.cols, 'copies': copies,
                 'signatures': {k: counts.get(k, 0) for k in sorted(sigs)}}
        state_file.write_text(json.dumps(state, indent=1), encoding='utf-8')
    if a.preview:
        keys = sorted(sigs, key=lambda k: -counts.get(k, 0))
        ncol = 2
        nrow = (len(keys) + ncol - 1) // ncol
        sheet = Image.new('RGB', (ncol * (W + 20) + 20, nrow * (H + 52) + 20), (40, 40, 46))
        dsh = ImageDraw.Draw(sheet)
        fl = ImageFont.truetype(str(FONT_DIR / 'seguisb.ttf'), 22)
        for i, k in enumerate(keys):
            x, y = 20 + (i % ncol) * (W + 20), 20 + (i // ncol) * (H + 52)
            im = Image.open(cards_dir / f'{k}.png') if (cards_dir / f'{k}.png').exists() else render_card(sigs[k], a.rows, a.cols)
            sheet.paste(im, (x, y + 30), im.convert('RGBA'))
            dsh.text((x, y), f'{k}   ({counts.get(k, 0)} games)', font=fl, fill=(220, 220, 220))
        a.preview.parent.mkdir(parents=True, exist_ok=True)
        sheet.save(a.preview)
        log(f'preview: {a.preview}')

    if a.list_sigs:
        for k in sorted(sigs, key=lambda k: -counts.get(k, 0)):
            log(f'  {counts.get(k, 0):>6}  {k}')
    t_end = time.time()
    disk = sum(p.stat().st_size for p in cards_dir.glob('*.png'))
    nshard = sum(1 for p in cards_dir.glob('*~*.png'))
    log(f'collections: {", ".join(cols)}')
    for col in cols:
        if col in per_col or unknown.get(col):
            tot, new = per_col.get(col, (0, 0))
            log(f'  {col:<28} {tot:>6} with a card ({new} new links), {unknown.get(col, 0)} unknown controls'
                + (f'  e.g. {", ".join(unknown_examples[col][:3])}' if unknown.get(col) else ''))
    log(f'signatures: {len(sigs)} ({rendered} rendered)  sources: {src_count}')
    log(f'items: {linked} linked ({copied} as copies), {relinked} replaced, {already} already linked, '
        f'{foreign} skipped (not ours; --force replaces), {stale} stale removed, {sum(unknown.values())} unknown controls')
    log(f'disk: {disk / 1024:.0f} KB in {cards_dir} ({nshard} link-limit shards; links add no data)')
    log(f'time: data {t_data - t0:.1f}s, resolve {t_resolve - t_data:.1f}s, render {t_render - t_resolve:.1f}s, '
        f'link {t_end - t_render:.1f}s, total {t_end - t0:.1f}s' + ('  [dry run]' if a.dry_run else ''))


if __name__ == '__main__':
    sys.exit(main())
