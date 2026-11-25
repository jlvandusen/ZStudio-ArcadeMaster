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
CARD_VERSION = 12   # bump to force a re-render of every signature card (links follow: files are rewritten in place)

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


DIR_WORDS = {'up', 'down', 'left', 'right', 'forward', 'backward', 'back', 'backwards'}
# two-stick games whose controls.dat only names directions ("Left Up" / "Right Down"): what each hand does
TWIN_FIXED = {'cclimber': ('Left Arm', 'Right Arm', False), 'cclimberj': ('Left Arm', 'Right Arm', False),
              'ccboot': ('Left Arm', 'Right Arm', False), 'cclimbr2': ('Left Arm', 'Right Arm', False)}


class Sig:
    __slots__ = ('players', 'alt', 'stick', 'buttons', 'extras', 'labels', 'emu', 'leds', 'roles')

    def __init__(self, players=0, alt=False, stick=None, buttons=0, extras=(), labels=(), emu=''):
        self.emu = emu
        self.roles = ()     # two-stick games: (left does, right does, left is, right is) - "LEFT TREAD" on "FLIGHT STICK 1"
        self.leds = ()      # the game's real button colours (LEDBlinky Colors.ini): (stick, b1, b2 ...) as RGB or None
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
        self.alt, self.stick, self.buttons = alt, stick, min(buttons, 9)   # 9 = "9+" (8-button panels exist)
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
        if self.leds:
            k += '-C' + hashlib.sha1(repr(self.leds).encode()).hexdigest()[:8]
        if self.roles:
            k += '-R' + hashlib.sha1('|'.join(self.roles).encode()).hexdigest()[:8]
        return k

    def with_emu(self, emu: str, leds=()) -> 'Sig':
        s = Sig.__new__(Sig)
        for a in Sig.__slots__:
            setattr(s, a, getattr(self, a))
        s.emu = emu
        s.leds = tuple(leds)
        return s


# ------------------------------------------------------------------ the panel's real button colours (LEDBlinky)
# LEDBlinky lights each game's buttons in that game's own colours (Colors.ini, ~1,400 arcade games: 1942 fire = red,
# bomb = white ...). The card draws the same colours, so what glows on the panel is what the screen shows.
class LedColors:
    def __init__(self, root: Path, log):
        self.games: dict = {}
        self.rgb: dict = {}
        self.names: dict = {}
        lb = read_conf(root / 'settings.conf').get('ledblinkydirectory')
        d = Path(lb) if lb else root / 'LEDBlinky'
        if not d.is_absolute():
            d = root / d
        if not (d / 'Colors.ini').exists():
            return
        for line in (d / 'Color-RGB.ini').read_text(encoding='utf-8', errors='replace').splitlines() if (d / 'Color-RGB.ini').exists() else ():
            m = re.match(r'^\s*([^;=\[\]]+?)\s*=\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)', line)
            if m:   # LEDBlinky intensity 0-48 -> 0-255; "Black" (5,5,5) still reads as a dark button on the card
                self.rgb[m.group(1).strip().lower()] = tuple(min(255, int(int(v) * 255 / 48)) for v in m.groups()[1:])
        cur = None
        for line in (d / 'Colors.ini').read_text(encoding='utf-8', errors='replace').splitlines():
            line = line.strip()
            if line.startswith('[') and line.endswith(']'):
                cur = self.games.setdefault(line[1:-1].strip().lower(), {})
            elif cur is not None and '=' in line:
                k, v = line.split('=', 1)
                cur[k.strip().upper()] = v.strip().lower()
        log(f'button colours: {len(self.games)} games from {d / "Colors.ini"}')
        # what each button DOES in each game (LEDBlinky Controls.ini, the controls.dat data: sf2 = Light Punch ...)
        ci = d / 'Controls.ini'
        if ci.exists():
            cur = None
            for line in ci.read_text(encoding='utf-8', errors='replace').splitlines():
                line = line.strip()
                if line.startswith('[') and line.endswith(']'):
                    cur = self.names.setdefault(line[1:-1].strip().lower(), {})
                elif cur is not None and '=' in line and (line.split('=', 1)[0].strip().lower() in ('numplayers', 'alternating', 'p1controls', 'p1numbuttons')
                                                          or re.match(r'(?i)P1_JOYSTICK(LEFT|RIGHT)_(UP|DOWN|LEFT|RIGHT)\s*=', line)):
                    k, v = line.split('=', 1)
                    cur['_' + k.strip().lower()] = v.strip()
                elif cur is not None and line.upper().startswith('P1_BUTTON') and '=' in line:
                    k, v = line.split('=', 1)
                    m = re.match(r'P1_BUTTON(\d+)$', k.strip().upper())
                    if m:
                        cur[int(m.group(1))] = v.strip()
            log(f'button names: {sum(1 for g in self.names.values() if any(isinstance(k, int) for k in g))} games from {ci}')

    def twin_roles(self, item: str):
        """a two-stick game's roles from controls.dat: (left does, right does, is_tread) or None.
        P1_JOYSTICKRIGHT_UP=Fire Up -> FIRE; Right Tread Forward -> RIGHT TREAD; bare directions -> MOVE"""
        g = self.names.get(item.lower())
        if not g:
            return None
        pc = g.get('_p1controls', '').lower()
        if item.lower() in TWIN_FIXED:
            return TWIN_FIXED[item.lower()]
        def role(side):
            vals = [v for k, v in g.items() if isinstance(k, str) and k.lower().startswith(f'_p1_joystick{side}_')]
            words = {' '.join(w for w in re.split(r'\s+', v) if w.lower() not in DIR_WORDS).strip() for v in vals}
            words.discard('')
            return words.pop() if len(words) == 1 else ''
        left, right = role('left'), role('right')
        tread = 'tread' in (left + right).lower() or 'triggerstick' in pc or 'vdoublejoy2way' in pc
        if tread:
            left, right = 'Left Tread', 'Right Tread'
        # a stick whose directions carry no role word ("Up", "Down"...) moves the player: Front Line's right stick,
        # Black Widow's left one. Only when neither side says anything is it the plain move / fire pair.
        if not left and not right:
            return ('Move', 'Fire', tread)
        return (left or 'Move', right or 'Move', tread)

    def cabinet(self, item: str):
        """the real cabinet as controls.dat describes it: (players, alternating, controls) or None. MAME's -listxml
        lists every input the board has (Centipede: a joystick AND the trackball); controls.dat says what the cabinet
        had (Centipede: "Trackball+trackball", 2 players taking turns)."""
        g = self.names.get(item.lower())
        if not g or '_p1controls' not in g:
            return None
        return (to_int(g.get('_numplayers'), 0), g.get('_alternating') == '1', g['_p1controls'].lower(),
                to_int(g.get('_p1numbuttons'), -1))

    def labels_of(self, item: str, buttons: int) -> tuple:
        """the game's button names, only when they say something ("A" / "B" / "Button 1" do not)"""
        g = self.names.get(item.lower())
        if not g or buttons <= 0:
            return ()
        out = []
        for i in range(1, buttons + 1):
            v = str(g.get(i, ''))
            out.append('' if (len(v) <= 1 or re.fullmatch(r'(?i)(button|btn|b)\s*\d+', v)) else v)
        return tuple(out) if any(out) else ()

    def of(self, item: str, buttons: int) -> tuple:
        g = self.games.get(item.lower())
        if not g:
            return ()
        out = [self.rgb.get(g.get('P1_JOYSTICK', ''), None)]
        for i in range(1, max(buttons, 0) + 1):
            out.append(self.rgb.get(g.get(f'P1_BUTTON{i}', ''), None))
        return tuple(out) if any(out) else ()


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
    def __init__(self, w=W, h=H, accent=MAGENTA):
        self.w, self.h, self.accent = w, h, accent
        self.base = Image.new('RGBA', (w * S, h * S), (0, 0, 0, 0))
        self.glow = Image.new('RGBA', (w * S, h * S), (0, 0, 0, 0))
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
        return out.resize((self.w, self.h), Image.LANCZOS)

    def base_plate(self):
        p = Image.new('RGBA', (self.w * S, self.h * S), (0, 0, 0, 0))
        d = ImageDraw.Draw(p)
        rad = min(22, self.h // 2 - 2)
        d.rounded_rectangle(self.r(2, 2, self.w - 2, self.h - 2), radius=rad * S, fill=BG + (236,),
                            outline=self.accent + (200,), width=3 * S)
        return p


def tri(cx, cy, ang, size):
    import math
    pts = []
    for da, rr in ((0, size), (140, size * 0.8), (-140, size * 0.8)):
        a = math.radians(ang + da)
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    return pts


def draw_stick(c: Card, cx, cy, stick, color_on, k=1.0):
    """one joystick: gate plate, direction arrows, balltop. k scales it around (cx, cy) - twin-stick cards use ~.6"""
    import math
    on = stick is not None

    def R(*xy):
        return [((cx if i % 2 == 0 else cy) + (v - (cx if i % 2 == 0 else cy)) * k) * S for i, v in enumerate(xy)]
    c.d.ellipse(R(cx - 86, cy - 86, cx + 86, cy + 86), fill=CARD + (255,), outline=FAINT + (255,), width=2 * S)
    dirs = {'4': [0, 90, 180, 270], '2h': [0, 180], '2v': [90, 270], '8': list(range(0, 360, 45))}.get(stick, [])
    if stick == 'analog':
        c.d.ellipse(R(cx - 70, cy - 70, cx + 70, cy + 70), outline=CYAN + (255,), width=4 * S)
        c.g.ellipse(R(cx - 70, cy - 70, cx + 70, cy + 70), outline=CYAN + (255,), width=6 * S)
        for a in range(0, 360, 30):
            x, y = cx + 70 * math.cos(math.radians(a)), cy + 70 * math.sin(math.radians(a))
            c.d.ellipse(R(x - 4, y - 4, x + 4, y + 4), fill=CYAN + (255,))
    for a in range(0, 360, 45):
        lit = a in dirs
        x, y = cx + 70 * math.cos(math.radians(a)), cy + 70 * math.sin(math.radians(a))
        pts = [tuple(R(px, py)) for px, py in tri(x, y, a, 15 if lit else 9)]
        if lit:
            c.d.polygon(pts, fill=CYAN + (255,))
            c.g.polygon(pts, fill=CYAN + (255,))
        elif stick != 'analog':
            c.d.polygon(pts, fill=FAINT + (150,))
    if stick in ('2h', '2v'):        # slot gate
        box = (cx - 54, cy - 8, cx + 54, cy + 8) if stick == '2h' else (cx - 8, cy - 54, cx + 8, cy + 54)
        c.d.rounded_rectangle(R(*box), radius=8 * k * S, outline=CYAN + (200,), width=2 * S)
    c.d.ellipse(R(cx - 12, cy - 12, cx + 12, cy + 12), fill=(40, 44, 58, 255))
    bt = color_on if on else FAINT
    c.d.ellipse(R(cx - 34, cy - 34, cx + 34, cy + 34), fill=bt + (255,))
    if on:
        c.g.ellipse(R(cx - 34, cy - 34, cx + 34, cy + 34), fill=bt + (200,))
    c.d.ellipse(R(cx - 22, cy - 26, cx - 2, cy - 10), fill=(255, 255, 255, 110 if on else 40))


def fit_label(c: Card, s, maxw, px=22):
    f = font('semi', px)
    if c.width(s, f) <= maxw:
        return s
    while s and c.width(s + '…', f) > maxw:
        s = s[:-1]
    return s + '…'


ABBREV = {'ROUNDHOUSE': 'R.HOUSE', 'FORWARD': 'FWD', 'BACKWARD': 'BACK', 'SPECIAL': 'SPEC.', 'SELECT': 'SEL.',
          'ACCELERATE': 'GAS', 'ACCELERATOR': 'GAS'}   # used only when the full name does not fit


def draw_label(c: Card, cx, cy, s, maxw):
    """a button's name under it: shrink to fit, else two lines (LIGHT / PUNCH), else shorten"""
    for px in (22, 20, 18, 16):
        if c.width(s, font('semi', px)) <= maxw:
            c.text((cx, cy), s, font('semi', px), TEXT + (255,), 'mm')
            return
    for long_, short in ABBREV.items():                         # the arcade's own short forms, before cutting words
        s = s.replace(long_, short)
    for px in (22, 20, 18, 16):
        if c.width(s, font('semi', px)) <= maxw:
            c.text((cx, cy), s, font('semi', px), TEXT + (255,), 'mm')
            return
    words = s.split()
    # a word too long even at 13 px breaks in two with a hyphen (HYPERSPACE -> HYPER- / SPACE, ROUNDHOUSE -> ROUND- / HOUSE)
    if any(c.width(w, font('semi', 13)) > maxw for w in words) and len(words) <= 2:
        long_ = max(words, key=len)
        if '/' in long_.strip('/'):                           # TANK/GRENADE -> TANK/ + GRENADE, never TANK/G-RENADE
            h = long_.index('/', 1) + 1
            a, b = long_[:h], long_[h:]
        else:
            h = (len(long_) + 1) // 2
            a, b = long_[:h] + '-', long_[h:]
        if len(words) == 2:                                   # ROUNDHOUSE KICK -> ROUND- / HOUSE KICK when that fits
            other = words[1] if words[0] == long_ else words[0]
            b = f'{b} {other}' if words[0] == long_ else b
            a = a if words[0] == long_ else f'{other} {a}'
        px = next((p for p in (15, 14, 13, 12) if max(c.width(a, font('semi', p)), c.width(b, font('semi', p))) <= maxw), None)
        if px:
            c.text((cx, cy - 8), a, font('semi', px), TEXT + (255,), 'mm')
            c.text((cx, cy + 10), b, font('semi', px), TEXT + (255,), 'mm')
            return
    if len(words) > 1:
        best = None
        for k in range(1, len(words)):
            a, b = ' '.join(words[:k]), ' '.join(words[k:])
            w = max(c.width(a, font('semi', 16)), c.width(b, font('semi', 16)))
            if best is None or w < best[0]:
                best = (w, a, b)
        _, a, b = best
        # the size at which both lines fit ("MUTANT / POWER"); only then cut a word short
        px = next((p for p in (16, 15, 14, 13) if max(c.width(a, font('semi', p)), c.width(b, font('semi', p))) <= maxw), 13)
        c.text((cx, cy - 8), fit_label(c, a, maxw, px), font('semi', px), TEXT + (255,), 'mm')
        c.text((cx, cy + 10), fit_label(c, b, maxw, px), font('semi', px), TEXT + (255,), 'mm')
        return
    px = next((p for p in (15, 14, 13) if c.width(s, font('semi', p)) <= maxw), 13)   # one long word: ROUNDHOUSE
    c.text((cx, cy), fit_label(c, s, maxw, px), font('semi', px), TEXT + (255,), 'mm')


def draw_buttons(c: Card, x0, y0, sig: Sig, rows, cols, x_max=545, numbers=None):
    n = rows * cols
    labels = sig.labels
    rad = (27 if labels else 33) if rows <= 2 else 24
    if cols > 3:
        rad = min(rad, 28)
    gapx = 92 if cols <= 3 else int((x_max - x0 - rad - 14) / (cols - 1))
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
        led = sig.leds[i + 1] if len(sig.leds) > i + 1 and sig.leds[i + 1] else None
        if led:                                   # the colour this button really lights up in for this game
            col = led
        dark = sum(col) < 140                     # a "black" button: dark cap with a light rim and number
        box = c.r(cx - rad, cy - rad, cx + rad, cy + rad)
        if lit:
            c.d.ellipse(c.r(cx - rad - 5, cy - rad - 5, cx + rad + 5, cy + rad + 5), fill=(0, 0, 0, 255))
            c.d.ellipse(box, fill=col + (255,), outline=(TEXT + (255,)) if dark else None, width=3 * S)
            if not dark:
                c.g.ellipse(box, fill=col + (255,))
            c.d.ellipse(c.r(cx - rad + 8, cy - rad + 6, cx + rad - 8, cy - 4), fill=(255, 255, 255, 60))
            light = (col[0] * 299 + col[1] * 587 + col[2] * 114) / 1000 > 150
            c.text((cx, cy + 1), str(i + 1), font('black', 34), (BG if light else TEXT) + (255,), 'mm')
        else:
            c.d.ellipse(box, fill=CARD2 + (255,), outline=FAINT + (255,), width=3 * S)
        if lit and i < len(labels) and labels[i]:
            # a label is centred under its button: it may use the room of a neighbour that has no label of its own
            def named(j):
                return 0 <= j < min(sig.buttons, len(labels)) and bool(labels[j])
            half = (gapx - 4) / 2
            left = half if (k > 0 and named(i - 1)) else (gapx * .9 if k > 0 else gapx * .6)
            right = half if (k < cols - 1 and named(i + 1)) else (gapx * .9 if k < cols - 1 else max(half, x_max + 4 - cx))
            draw_label(c, cx, cy + rad + 15, labels[i].upper(), int(2 * min(left, right)))
    if sig.buttons > n:
        c.text((x0 + (cols - 1) * gapx + rad + 6, y0 + (rows - 1) * gapy + rad), '+' if sig.buttons >= 9 else f'+{sig.buttons - n}',
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


# ------------------------------------------------------------------ the cabinet's control panel
# <manifest>/panel.json (else tools/panels/<COMPUTERNAME>.json, else these defaults): buttons per player position and the
# special devices with their own buttons. The cards draw THIS hardware, not a generic panel.
PANEL = {
    'players': [{'buttons': 6, 'rows': 2, 'cols': 3}] * 4,
    'trackball': {'name': 'Rollerball', 'buttons': 2},
    'spinner': {'name': 'Dial', 'buttons': 2},
    'flightStick': {'name': 'Flight stick', 'buttons': 3},
    'twinStick': {'left': 'P1 stick', 'right': 'P2 stick', 'leftDoes': 'Move', 'rightDoes': 'Fire'},
}


def load_panel(man: Path, log) -> str:
    """fills PANEL; returns a short hash so a changed panel re-renders every card"""
    for f in (man / 'panel.json', Path(__file__).parent / 'panels' / f'{os.environ.get("COMPUTERNAME", "")}.json'):
        if f.exists():
            try:
                data = json.loads(f.read_text(encoding='utf-8-sig'))
            except ValueError as ex:
                log(f'panel file {f} unreadable: {ex}')
                continue
            for k, v in data.items():
                if k.startswith('_'):
                    continue
                PANEL[k] = {**PANEL[k], **v} if isinstance(v, dict) and isinstance(PANEL.get(k), dict) else v
            log(f'panel: {f}')
            break
    return hashlib.sha1(json.dumps(PANEL, sort_keys=True).encode()).hexdigest()[:8]


def device_of(s: Sig):
    """the special device a game is played with instead of a stick (None = stick + panel buttons)"""
    ex = set(s.extras)
    if s.stick and s.stick != 'analog':
        return None
    if 'trackball' in ex:
        return 'trackball'
    if ex & {'spinner', 'paddle'}:
        return 'spinner'
    if 'flightstick' in ex or s.stick == 'analog':
        return 'flightStick'
    return None


def render_card(sig: Sig, rows: int, cols: int) -> Image.Image:
    c = Card()
    # ---- left: one player's panel
    c.d.rounded_rectangle(c.r(18, 18, 552, H - 18), radius=18 * S, fill=CARD + (255,), outline=FAINT + (255,),
                          width=2 * S)
    c.d.rounded_rectangle(c.r(18, 18, 552, 24), radius=3 * S, fill=PLAYER[0] + (255,))
    c.text((36, 50), 'P1', font('black', 26), PLAYER[0] + (255,), 'lm', glow=PLAYER[0] + (160,))
    dev = device_of(sig)
    if 'twinstick' in sig.extras:
        # two sticks side by side, what each one does, which panel stick it is
        ts = PANEL['twinStick']
        ld, rd, lw, rw = sig.roles if sig.roles else (ts['leftDoes'], ts['rightDoes'], ts['left'], ts['right'])
        for cx, does, which, pc in ((112, ld, lw, PLAYER[0]), (282, rd, rw, PLAYER[1])):
            draw_stick(c, cx, 134, sig.stick or '8', pc, k=.72)
            c.text((cx, 214), does.upper(), font('black', 24), CYAN + (255,), 'mm', glow=CYAN + (90,))
            c.text((cx, 244), which.upper(), font('semi', 19), DIM + (255,), 'mm')
        c.d.line(c.r(197, 92, 197, 252), fill=FAINT + (255,), width=2 * S)
        if sig.buttons:
            draw_buttons(c, 400, 108, sig, 2, 2, x_max=540)
    elif dev:
        # a rollerball / dial / flight stick game: the device and ITS OWN buttons, as they sit on the cabinet
        d = PANEL[dev]
        icon = {'trackball': 'trackball', 'spinner': 'spinner', 'flightStick': 'flightstick'}[dev]
        c.d.ellipse(c.r(44, 64, 228, 248), fill=CARD + (255,), outline=GREEN + (160,), width=3 * S)
        draw_icon(c, icon if not (dev == 'spinner' and 'paddle' in sig.extras) else 'paddle', 136, 156, GREEN, 60)
        c.text((136, 268), d['name'].upper(), font('black', 22), GREEN + (255,), 'mm', glow=GREEN + (80,))
        nb = int(d['buttons'])
        ds = Sig.__new__(Sig)
        for a_ in Sig.__slots__:
            setattr(ds, a_, getattr(sig, a_))
        ds.buttons = min(sig.buttons, nb)
        draw_buttons(c, 300, 140, ds, 1, max(nb, 1), x_max=520 if nb > 2 else 470)
        c.text((394, 216), f'NEXT TO THE {d["name"].upper()}', font('semi', 19), DIM + (255,), 'mm')
        if sig.buttons > nb:
            c.text((394, 246), f'BUTTONS {nb + 1}+ ON THE PANEL', font('semi', 19), AMBER + (255,), 'mm')
    else:
        if not sig.stick and sig.extras:          # gun / wheel / keypad: the game's own control takes the stick's place
            c.d.ellipse(c.r(50, 80, 222, 252), fill=CARD + (255,), outline=FAINT + (255,), width=2 * S)
            draw_icon(c, sig.extras[0], 136, 166, GREEN, 54)
        else:
            draw_stick(c, 136, 166, sig.stick, (sig.leds[0] if sig.leds and sig.leds[0] else PLAYER[0]))
        draw_buttons(c, 282 if cols > 3 else 300, 108 if rows <= 2 else 80, sig, rows, cols, x_max=528)
    # P3 / P4 have fewer buttons than P1 / P2 on some cabinets
    p34 = min(int(p.get('buttons', 6)) for p in PANEL['players'][2:4]) if len(PANEL['players']) > 2 else 99
    if sig.players >= 3 and sig.buttons > p34 and not dev:
        c.text((W - 26, 92), f'P3 / P4 HAVE {p34} BUTTONS', font('semi', 20), AMBER + (255,), 'rm')
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
    if dev:
        st, scol = PANEL[dev]['name'].upper() + ' GAME', GREEN
    elif 'twinstick' in sig.extras:
        st, scol = 'TWIN STICKS', CYAN
    elif sig.stick:
        st, scol = STICK_TEXT[sig.stick], CYAN
    elif sig.extras:
        st, scol = EXTRA_LABEL[sig.extras[0]] + ' GAME', GREEN
    else:
        st, scol = 'NO STICK', DIM
    fs = 38
    while fs > 26 and c.width(st, font('black', fs)) > 370:     # keep clear of the START pill
        fs -= 2
    c.text((x0, 136), st, font('black', fs), scol + (255,), 'lm', glow=scol + (90,))
    b = sig.buttons
    bt = 'NO BUTTONS' if b == 0 else ('1 BUTTON' if b == 1 else ('9+ BUTTONS' if b >= 9 else f'{b} BUTTONS'))
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
    if dev or 'twinstick' in sig.extras:          # the left panel already shows the device: one plain line instead
        shown = []
    for e in shown:
        # this panel's own name for the device ("DIAL", "ROLLERBALL") rather than the generic one
        lab = {'spinner': PANEL.get('spinner', {}).get('name', ''), 'trackball': PANEL.get('trackball', {}).get('name', '')}.get(e, '').upper() or EXTRA_LABEL[e]
        f = font('black', 28)
        wdt = 34 + 14 + c.width(lab, f)
        if x + wdt > x1:
            break
        draw_icon(c, e, x + 17, y, GREEN, 17)
        c.text((x + 44, y + 1), lab, f, GREEN + (255,), 'lm')
        x += wdt + 26
    if not shown or dev or 'twinstick' in sig.extras:
        hint = 'JOYSTICK + BUTTONS' if sig.stick else ('BUTTONS ONLY' if sig.buttons else '')
        if not sig.stick and sig.extras:
            hint = HOW_TO.get(sig.extras[0], '')
        if dev == 'trackball':
            hint = f'ROLL THE {PANEL["trackball"]["name"].upper()}'
        elif dev == 'spinner':
            hint = f'{"TURN" if "paddle" in sig.extras else "SPIN"} THE {PANEL["spinner"]["name"].upper()}'
        elif dev == 'flightStick':
            hint = f'FLY WITH THE {PANEL["flightStick"]["name"].upper()}'
        elif 'twinstick' in sig.extras:
            hint = 'ONE STICK IN EACH HAND'
        c.text((x0, y), hint, font('semi', 24), DIM + (255,), 'lm')
    return c.finish()


# ------------------------------------------------------------------ special-control reminder (am_hint)
# A strip over the top of the preview video for games played with something other than stick + buttons. The layout
# pulses it so it catches the eye: players forget the trackball, the restrictor switching to 4-way, gas on button 1.
HINT_W, HINT_H = 980, 92


def hint_of(s: Sig):
    ex, b = set(s.extras), s.buttons
    if 'keypad' in ex:
        return None
    if 'lightgun' in ex:
        return 'lightgun', LIGHTGUN_HINT
    if 'wheel' in ex:
        return 'wheel', 'STICK STEERS  ·  1 = GAS  ·  2 = BRAKE'
    if 'trackball' in ex:
        if s.stick:
            return 'trackball', f'STICK MOVES  +  {PANEL["trackball"]["name"].upper()} AIMS'
        return 'trackball', f'ROLL THE {PANEL["trackball"]["name"].upper()}' + ('  +  PRESS 1' if b else '')
    if ex & {'spinner', 'paddle'}:
        return 'spinner', f'SPIN THE {PANEL["spinner"]["name"].upper()}' + ('  +  PRESS 1' if b else '')
    if 'flightstick' in ex:
        return 'flightstick', f'FLY WITH THE {PANEL["flightStick"]["name"].upper()}'
    if 'twinstick' in ex:
        ts = PANEL['twinStick']
        ld, rd, lw, rw = s.roles if s.roles else (ts['leftDoes'], ts['rightDoes'], ts['left'], ts['right'])
        return 'twinstick', f'{lw} {ld}  ·  {rw} {rd}'.upper()
    if s.stick == '4':
        return '4way', '4-WAY GAME  ·  STICK SWITCHES ITSELF'
    return None


LIGHTGUN_HINT = 'AIM AT THE SCREEN  +  PULL THE TRIGGER'


def hint_key(h) -> str:
    return 'hint-' + hashlib.sha1(('|'.join(h) + f'|{CARD_VERSION}|{PANEL_HASH}').encode()).hexdigest()[:10]


PANEL_HASH = ''


def render_hint(kind: str, text: str) -> Image.Image:
    c = Card(HINT_W, HINT_H, accent=GREEN)
    cy = HINT_H / 2
    c.d.ellipse(c.r(14, cy - 34, 82, cy + 34), fill=CARD + (255,), outline=GREEN + (255,), width=3 * S)
    if kind == '4way':
        c.text((48, cy + 1), '4', font('black', 40), CYAN + (255,), 'mm', glow=CYAN + (140,))
    else:
        draw_icon(c, kind, 48, cy, GREEN, 26)
    f = font('black', 36)
    t = text
    while c.width(t, f) > HINT_W - 130 and len(t) > 4:
        t = t[:-2]
    c.text((104, cy + 1), t, f, TEXT + (255,), 'lm', glow=GREEN + (120,))
    return c.finish()


# ------------------------------------------------------------------ filters (RetroFE playlists)
# Written into every game collection's playlists folder; the ArcadeMaster layout switches them with LEFT / RIGHT and
# shows the name as a banner. Our names start at 20 so the build's own playlists (00-19) come first.
FILTERS = [
    ('20 2 player games', lambda s: s.players >= 2 and not s.alt),
    ('21 4 player games', lambda s: s.players >= 4 and not s.alt),
    ('22 trackball', lambda s: 'trackball' in s.extras),
    ('23 trackball + stick', lambda s: 'trackball' in s.extras and bool(s.stick)),
    ('24 spinner + paddle', lambda s: bool({'spinner', 'paddle'} & set(s.extras))),
    ('25 light gun', lambda s: 'lightgun' in s.extras),
    ('26 driving', lambda s: 'wheel' in s.extras),
    ('27 flight stick', lambda s: 'flightstick' in s.extras),
    ('28 twin stick', lambda s: 'twinstick' in s.extras),
    ('29 4-way stick', lambda s: s.stick == '4'),
]
FILTER_MIN = 3          # a filter with fewer games is not worth a stop on the cycle


def write_filters(fe, plan, sigs, dry) -> dict:
    made = {}
    for col, lst in plan.items():
        pdir = fe.cdir / col / 'playlists'
        for name, test in FILTERS:
            lines = sorted({(it if src.lower() == col.lower() else f'_{src}:{it}') for it, k, src in lst if test(sigs[k])},
                           key=str.lower)
            f = pdir / f'{name}.txt'
            if len(lines) >= FILTER_MIN:
                made[(col, name)] = len(lines)
                body = '\r\n'.join(lines) + '\r\n'
                if dry:
                    continue
                pdir.mkdir(parents=True, exist_ok=True)
                if not f.exists() or f.read_text(encoding='utf-8', errors='replace') != body:
                    f.write_text(body, encoding='utf-8', newline='')
            elif f.exists() and not dry:
                f.unlink()                                   # ours (fixed name): too few games now
    return made


def friendly_playlist(name: str) -> str:
    n = re.sub(r'^\d+\s+', '', name).strip()
    return {'all': 'ALL GAMES', 'favorites': 'FAVORITES', 'lastplayed': 'LAST PLAYED'}.get(n.lower(), n.upper())


def render_banner(label: str) -> Image.Image:
    bw, bh = 760, 74
    c = Card(bw, bh, accent=CYAN)
    cy = bh / 2
    for x, ang in ((34, 180), (bw - 34, 0)):
        pts = [(px * S, py * S) for px, py in tri(x, cy, ang, 17)]
        c.d.polygon(pts, fill=CYAN + (255,))
        c.g.polygon(pts, fill=CYAN + (200,))
    f = font('black', 36)
    t = label
    while c.width(t, f) > bw - 130 and len(t) > 3:
        t = t[:-1]
    c.text((bw / 2, cy + 1), t, f, TEXT + (255,), 'mm', glow=CYAN + (110,))
    return c.finish()


def write_banners(fe, layout_dir: Path, dry, force) -> int:
    names = {'all', 'favorites', 'lastplayed'}
    for d in fe.cdir.iterdir():
        if d.is_dir() and (d / 'playlists').is_dir():
            names |= {p.stem for p in (d / 'playlists').glob('*.txt')}
    out = layout_dir / 'collections' / '_common' / 'medium_artwork' / 'playlist'
    n = 0
    for nm in sorted(names):
        p = out / f'{nm}.png'
        if p.exists() and not force:
            continue
        n += 1
        if not dry:
            out.mkdir(parents=True, exist_ok=True)
            render_banner(friendly_playlist(nm)).save(p, 'PNG', optimize=True)
    return n


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
SKIP_DEFAULT = re.compile(r'^(_|zzz|main$|tools$)', re.I)   # Tools = the ArcadeMaster settings list


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
            and not read_list(d / 'menu.txt')   # an EMPTY menu.txt (a CoinOPS leftover in MAME / GameCube) is not a menu

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
    ap.add_argument('--no-filters', action='store_true', help='do not write the player / control filters (playlists)')
    ap.add_argument('--layout', default='ArcadeMaster', help='layout whose _common playlist banners are written')
    a = ap.parse_args(argv)
    t0 = time.time()
    log = lambda m: print(m, flush=True)
    root, man = a.retrofe.resolve(), a.manifest.resolve()
    fe = Frontend(root)
    global PANEL_HASH
    PANEL_HASH = load_panel(man, log)
    p1 = PANEL['players'][0] if PANEL['players'] else {}
    if p1.get('rows') and p1.get('cols') and a.rows == 2 and a.cols == 3:    # no --rows/--cols given: the cabinet's P1 panel
        a.rows, a.cols = int(p1['rows']), int(p1['cols'])
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
    leds = LedColors(root, log)
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
            ov = overrides.get(f'{scol.lower()}/{k}') or overrides.get(f'*/{k}')   # "*/mslug": in every collection
            s = ov or by_item.get((scol.lower(), k)) or by_norm.get(norm(it))
            src = 'games.json'
            # MAME games: MAME's own -listxml knows the real players / buttons / controls. games.json only wins with
            # hand-made detail (an override or named buttons); its generic rows said "1 player, no buttons" for 1942.
            # (the same for meta.db, which Rebuild Game Menus fills from games.json)
            if not ov and not (s is not None and s.labels) and mt == 'mame' and k in mame:
                ms = sig_from_mame(mame[k])
                if ms is not None and ms.known():
                    s, src = ms, 'mame'
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
            if src == 'mame':                                      # the cabinet, not every input the board has
                cab = leds.cabinet(it)
                if cab:
                    np, alt, pc, nb = cab
                    if 0 <= nb < s.buttons:
                        s.buttons = nb                             # MK: 5 on the cabinet (MAME adds a half-working 6th)
                    if s.stick and s.stick != 'analog' and 'joy' not in pc and re.search(r'trackball|dial|paddle', pc):
                        s.stick = None                             # Centipede, Millipede: trackball only
                    if np > (s.players or 0):
                        s.players, s.alt = np, alt                 # Centipede, Robotron: 2 players taking turns
                    if 'twinstick' in s.extras and 'doublejoy' not in pc:
                        s.extras = tuple(e for e in s.extras if e != 'twinstick')   # Tutankham: one stick + buttons
                    # MAME's extra input ports are not always cabinet controls (Discs of Tron's internal "Track Y"
                    # made it a trackball game): keep a trackball only when the cabinet had one
                    if 'trackball' in s.extras and not re.search(r'trackball|mouse', pc):
                        s.extras = tuple(e for e in s.extras if e != 'trackball')
                if 'twinstick' in s.extras:
                    tr = leds.twin_roles(it)
                    if tr:
                        ld, rd, tread = tr
                        fs = PANEL.get('flightStick', {}).get('name', 'Flight stick')
                        s.roles = (ld, rd, f'{fs} 1', f'{fs} 2') if tread else (ld, rd, PANEL['twinStick']['left'], PANEL['twinStick']['right'])
            src_count[src] += 1
            s = s.with_emu(emus.item(scol, it), leds.of(it, s.buttons))
            if not s.labels and 'wheel' not in s.extras:          # the game's own button names (Fire, Light Punch ...)
                nm = leds.labels_of(it, s.buttons)
                if nm:
                    s.labels = nm
            key = s.key()
            sigs.setdefault(key, s)
            lst.append((it, key, scol))
    t_resolve = time.time()

    # ---- render one card per signature
    cards_dir.mkdir(parents=True, exist_ok=True)
    rendered = 0
    old_ver = state.get('version')
    for key, s in sigs.items():
        p = cards_dir / f'{key}.png'
        if p.exists() and not a.force and old_ver == CARD_VERSION and state.get('panel') == PANEL_HASH:
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
    # special-control reminder strips: one per distinct hint, linked per game like the cards
    sig_hint = {}
    for key, s in sigs.items():
        h = hint_of(s)
        if h:
            hk = hint_key(h)
            sig_hint[key] = hk
            p = cards_dir / f'{hk}.png'
            if not p.exists() and not a.dry_run:
                render_hint(*h).save(p, 'PNG', optimize=True)
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
        for item, key, _src in lst:
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
        planned = {item.lower() for item, _k, _s in lst}
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

    # ---- special-control reminders: am_hint/<item>.png (only games with a special control get one)
    hints_linked = hints_stale = 0
    for col, lst in plan.items():
        hdir = fe.cdir / col / 'medium_artwork' / 'am_hint'
        existing = {}
        if hdir.is_dir():
            with os.scandir(hdir) as it:
                for e in it:
                    if e.name.lower().endswith('.png'):
                        existing[e.name[:-4].lower()] = e
        wanted = {}
        for item, key, _src in lst:
            if key in sig_hint:
                wanted[item.lower()] = (item, sig_hint[key])
        for low, (item, hk) in wanted.items():
            e = existing.get(low)
            if e is not None:
                if ours_ino.get(e.inode()) == hk:
                    continue
                if e.inode() not in ours_ino and not a.force:
                    continue
                if not a.dry_run:
                    os.unlink(e.path)
            if a.dry_run:
                hints_linked += 1
                continue
            hdir.mkdir(parents=True, exist_ok=True)
            dst = hdir / f'{item}.png'
            if not link_card(hk, dst):
                shutil.copyfile(cards_dir / f'{hk}.png', dst)
            hints_linked += 1
        for low, e in existing.items():
            if low not in wanted and e.inode() in ours_ino:
                if not a.dry_run:
                    os.unlink(e.path)
                hints_stale += 1

    # ---- filters + their banners
    filters = write_filters(fe, plan, sigs, a.dry_run) if not a.no_filters else {}
    banners = write_banners(fe, root / 'layouts' / a.layout, a.dry_run, a.force) if (root / 'layouts' / a.layout).is_dir() else 0

    # ---- state + preview
    counts = {}
    for lst in plan.values():
        for _, k, _s in lst:
            counts[k] = counts.get(k, 0) + 1
    if not a.dry_run:
        state = {'version': CARD_VERSION, 'panel': PANEL_HASH, 'rows': a.rows, 'cols': a.cols, 'copies': copies,
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
    log(f'reminders: {hints_linked} linked, {hints_stale} stale removed ({len(set(sig_hint.values()))} kinds)')
    fsum = {}
    for (col, name), n in filters.items():
        fsum.setdefault(name, []).append(f'{col} {n}')
    for name in sorted(fsum):
        log(f'filter {friendly_playlist(name):<20} ' + ', '.join(fsum[name]))
    log(f'filter banners: {banners} written')
    log(f'disk: {disk / 1024:.0f} KB in {cards_dir} ({nshard} link-limit shards; links add no data)')
    log(f'time: data {t_data - t0:.1f}s, resolve {t_resolve - t_data:.1f}s, render {t_render - t_resolve:.1f}s, '
        f'link {t_end - t_render:.1f}s, total {t_end - t0:.1f}s' + ('  [dry run]' if a.dry_run else ''))


if __name__ == '__main__':
    sys.exit(main())
