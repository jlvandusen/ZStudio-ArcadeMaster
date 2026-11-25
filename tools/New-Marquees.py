#!/usr/bin/env python3
"""
New-Marquees.py - a marquee for every game, and for every collection on the main menu.

A marquee is the wide banner above a cabinet's screen. RetroFE shows it on the second (marquee / touch) screen, on
RGB marquee panels and in layouts with type="marquee". Many games in a build have none. For each one this tool:

  1. lists every game of every game collection the way tools/New-PanelControlsArt.py does (Frontend.items(), plus
     the games a collection merges in through .sub files: those get the source collection's file as a HARD LINK)
  2. looks for a REAL marquee elsewhere, first in this build (the game's marquees / archives\\marquee folders, then
     the marquee folders of the other collections), then in the other frontend builds on the same drive (RetroFE
     builds: collections\\<c>\\medium_artwork\\marquee; RetroBat: roms\\<system>\\images\\*-marquee.* and
     media\\marquee(s), with gamelist.xml titles). Matched by item name, then by normalised title. Only real images
     at least 400 px wide and 2.5:1 or wider count. Copied (never linked across builds), at most 1920 px wide.
  3. otherwise draws a placeholder, 1920x480: the game's backdrop (am_backdrop, a blurred video frame), else its
     fanart - art from the game itself - else a calm dark gradient; the game's logo centred with a soft glow, or
     its title in Segoe UI Black with a coloured outline; a subtle thin frame and a light vignette. No retro / CRT
     effects (no scanlines, no synthwave grid): James, 2026-11-22, "I want something related to each game as the
     background".

Main menu: every collection on the main menu (collections\\Main\\menu.txt + <manifest>\\main-menu-full.txt) gets a
collection marquee in layouts\\ArcadeMaster\\collections\\Main\\medium_artwork\\marquee\\<collection>.png - the same
place this build keeps the main menu's logos - unless one already exists there, in collections\\Main\\medium_artwork,
or as the collection's system_artwork\\marquee.*.

Never overwrites a marquee that is not ours. Every file written is recorded in <manifest>\\marquees.json (item,
source, kind real / placeholder); --force-placeholders redraws only our placeholders (and swaps one for a real
marquee when one turns up). Resumable: whatever exists is skipped; each file is written under a temporary name and
renamed. A collection whose marquee folder is a junction gets medium_artwork\\am_marquee (a real folder) instead.

SAFETY: refuses to write into any folder that is, or has a parent up to the frontend root that is, a junction /
symlink, or that resolves onto E: (the live cabinet) or outside the frontend root.

  python tools/New-Marquees.py [--retrofe R:/ArcadeMaster/frontend/LEGENDS-am] [--manifest R:/ArcadeMaster/manifest]
         [--collections Arcades,Fight] [--dry-run] [--force-placeholders] [--limit N] [--jobs N]
         [--donors <dir>,<dir>] [--no-main] [--sheet sheet.png]
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import os
import random
import re
import shutil
import sqlite3
import stat
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageFont, ImageStat

DEFAULT_RETROFE = r'R:\ArcadeMaster\frontend\LEGENDS-am'
MANIFEST_DIR = r'R:\ArcadeMaster\manifest'
sys.path.insert(0, str(Path(__file__).resolve().parent / 'lib'))
from am_guard import is_protected  # noqa: E402  (the live frontend: ProtectedPaths in the config, else E:)
LAYOUT = 'ArcadeMaster'
IMG_EXTS = ('.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp')
MW, MH = 1920, 480                     # placeholder size
MIN_W, MIN_RATIO, MAX_W = 400, 2.5, 1920
PLACEHOLDER_VERSION = 3              # bump to redraw every placeholder of ours on the next run

# tools/lib/AmVisual.ps1 AmPal
BG = (8, 9, 14)
MAGENTA, CYAN, AMBER = (255, 47, 160), (46, 200, 255), (255, 176, 0)
VIOLET, GREEN, ORANGE = (123, 92, 255), (61, 220, 132), (255, 138, 61)
ACCENTS = [MAGENTA, CYAN, AMBER, VIOLET, GREEN, ORANGE]
FONT_DIR = Path(os.environ.get('WINDIR', r'C:\Windows')) / 'Fonts'


# ------------------------------------------------------------------ shared with New-PanelControlsArt.py
def _panel_module():
    spec = importlib.util.spec_from_file_location('am_panel_controls', Path(__file__).with_name('New-PanelControlsArt.py'))
    mod = importlib.util.module_from_spec(spec)
    keep, sys.dont_write_bytecode = sys.dont_write_bytecode, True     # no __pycache__ next to the tools
    try:
        spec.loader.exec_module(mod)
    finally:
        sys.dont_write_bytecode = keep
    return mod


_pm = _panel_module()
Frontend, read_conf, read_list, SKIP_DEFAULT = _pm.Frontend, _pm.read_conf, _pm.read_list, _pm.SKIP_DEFAULT


# ------------------------------------------------------------------ safety (as tools/New-PreviewMedia.py)
def is_reparse(p: str) -> bool:
    try:
        st = os.stat(p, follow_symlinks=False)
    except FileNotFoundError:
        return False
    return bool(getattr(st, 'st_file_attributes', 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT) or stat.S_ISLNK(st.st_mode)


def on_forbidden_drive(p: str) -> bool:
    return is_protected(p, MANIFEST_DIR)


class Unsafe(Exception):
    pass


def check_write_dir(target: str, root: str) -> None:
    target, root = os.path.abspath(target), os.path.abspath(root)
    if os.path.commonpath([target.lower(), root.lower()]) != root.lower():
        raise Unsafe(f'{target} is not inside {root}')
    if on_forbidden_drive(target) or on_forbidden_drive(root):
        raise Unsafe(f'{target} resolves onto a forbidden drive')
    real_t, real_r = os.path.realpath(target), os.path.realpath(root)
    if os.path.commonpath([real_t.lower(), real_r.lower()]) != real_r.lower():
        raise Unsafe(f'{target} resolves to {real_t}, outside {real_r}')
    p = target
    while True:
        if is_reparse(p):
            raise Unsafe(f'{p} is a junction / symlink')
        if os.path.normcase(p) == os.path.normcase(root):
            break
        parent = os.path.dirname(p)
        if parent == p:
            break
        p = parent


_made_dirs: set = set()
_dir_lock = threading.Lock()


def ensure_dir(target: str, root: str) -> None:
    with _dir_lock:
        if target in _made_dirs:
            return
        # create missing parents one by one, each checked first (mkdir makes real folders)
        missing = []
        p = os.path.abspath(target)
        while not os.path.isdir(p):
            missing.append(p)
            p = os.path.dirname(p)
        for d in reversed(missing):
            check_write_dir(os.path.dirname(d), root)
            os.mkdir(d)
        check_write_dir(target, root)
        _made_dirs.add(target)


def check_write_file(path: str, root: str) -> None:
    check_write_dir(os.path.dirname(path), root)
    if os.path.lexists(path) and is_reparse(path):
        raise Unsafe(f'{path} is a link')


# ------------------------------------------------------------------ names
def clean_title(s: str) -> str:
    """a title fit to print: no (region) / [tags], 'King of Fighters XIV, The' -> 'The King of Fighters XIV',
    'HauntedMuseum' -> 'Haunted Museum'"""
    s = re.sub(r'\s*[\(\[][^\)\]]*[\)\]]', '', str(s or '')).replace('_', ' ')
    s = re.sub(r'\s+', ' ', s).strip(' -')
    m = re.match(r'^(.*?),\s*(The|A|An)\b(.*)$', s, re.I)
    if m:
        s = f'{m.group(2)} {m.group(1)}{m.group(3)}'.strip()
    if ' ' not in s:
        s = re.sub(r'(?<=[a-z])(?=[A-Z])|(?<=[A-Za-z])(?=\d{2,})', ' ', s)
    return s


def ntitle(s: str) -> str:
    """normalised title: no (region) / [tags], 'X, The' == 'The X', & == and, letters and digits only"""
    s = re.sub(r'[\(\[][^\)\]]*[\)\]]', ' ', str(s or '').lower()).replace('&', ' and ').replace('_', ' ')
    s = re.sub(r'^(.*?),\s*(the|a|an)\b(.*)$', r'\2 \1\3', s.strip())
    s = re.sub(r'[^a-z0-9]', '', s)
    return s[3:] if s.startswith('the') and len(s) > 6 else s


def list_stems(d: Path) -> dict:
    """stem.lower() -> file name of the images in a folder (empty when it does not exist)"""
    out = {}
    try:
        with os.scandir(d) as it:
            for e in it:
                ext = os.path.splitext(e.name)[1].lower()
                if ext in IMG_EXTS and e.is_file():
                    out.setdefault(os.path.splitext(e.name)[0].lower(), e.name)
    except OSError:
        pass
    return out


# ------------------------------------------------------------------ donors (real marquees elsewhere)
class Donors:
    """Real marquees: this build's other marquee folders and the other frontend builds, by name and by title."""

    def __init__(self, log):
        self.log = log
        self.by_name: dict = {}     # (scope, key) -> [paths]   scope 'self' / 'other'
        self.by_title: dict = {}
        self.dims: dict = {}
        self.lock = threading.Lock()
        self.counts: dict = {}

    def _add(self, scope, name, title, path, origin):
        with self.lock:
            if name:
                self.by_name.setdefault((scope, name.lower()), []).append(path)
            for t in {ntitle(title), ntitle(name)} - {''}:
                self.by_title.setdefault((scope, t), []).append(path)
            self.counts[origin] = self.counts.get(origin, 0) + 1

    def add_retrofe(self, root: Path, scope: str, exclude: set, subs=('marquee', 'marquees', 'archives/marquee')):
        titles = {}
        mdb = root / 'meta.db'
        if mdb.exists():
            try:
                con = sqlite3.connect(f'file:{mdb}?mode=ro', uri=True)
                for col, name, title in con.execute('select collectionName, name, title from Meta'):
                    titles.setdefault(name.lower(), title)
                con.close()
            except sqlite3.Error:
                pass
        cdir = root / 'collections'
        try:
            cols = [e for e in os.scandir(cdir) if e.is_dir(follow_symlinks=False)]
        except OSError:
            return
        origin = root.name
        for c in cols:
            for sub in subs:
                d = os.path.join(c.path, 'medium_artwork', *sub.split('/'))
                if not os.path.isdir(d) or is_reparse(d) or is_reparse(os.path.dirname(d)):
                    continue                  # never follow junctions (they lead to the live drive)
                for stem, fn in list_stems(Path(d)).items():
                    p = os.path.join(d, fn)
                    if p.lower() in exclude:
                        continue
                    real = os.path.splitext(fn)[0]
                    self._add(scope, real, titles.get(stem, ''), p, origin)

    def add_retrobat(self, roms: Path):
        origin = str(roms.parent.relative_to(roms.anchor)) if roms.anchor else str(roms.parent)
        try:
            systems = [e for e in os.scandir(roms) if e.is_dir(follow_symlinks=False)]
        except OSError:
            return
        for s in systems:
            sp = Path(s.path)
            seen = set()
            gl = sp / 'gamelist.xml'
            if gl.exists():
                txt = gl.read_text(encoding='utf-8', errors='replace')
                for g in re.finditer(r'<game\b.*?</game>', txt, re.S):
                    b = g.group(0)
                    m = re.search(r'<marquee>([^<]+)</marquee>', b)
                    if not m:
                        continue
                    mp = os.path.normpath(os.path.join(s.path, m.group(1).strip().replace('&amp;', '&')))
                    if not os.path.isfile(mp):
                        continue
                    pm = re.search(r'<path>([^<]+)</path>', b)
                    nm = re.search(r'<name>([^<]+)</name>', b)
                    stem = Path(pm.group(1).strip().replace('&amp;', '&')).stem if pm else ''
                    title = nm.group(1).strip().replace('&amp;', '&') if nm else ''
                    self._add('other', stem, title, mp, origin)
                    seen.add(mp.lower())
            for sub, suffix in (('images', '-marquee'), ('media/marquees', ''), ('media/marquee', '')):
                d = sp / sub
                if not d.is_dir() or is_reparse(str(d)):
                    continue
                for stem, fn in list_stems(d).items():
                    p = str(d / fn)
                    if p.lower() in seen:
                        continue
                    real = os.path.splitext(fn)[0]
                    if suffix:
                        if not real.lower().endswith(suffix):
                            continue
                        real = real[:-len(suffix)]
                    self._add('other', real, '', p, origin)

    def ok(self, p: str):
        """(w, h) when the file is a real, wide-enough image, else None"""
        if p in self.dims:
            return self.dims[p]
        r = None
        try:
            with Image.open(p) as im:
                w, h = im.size
            if w >= MIN_W and h > 0 and w / h >= MIN_RATIO:
                r = (w, h)
        except Exception:
            r = None
        self.dims[p] = r
        return r

    def find(self, item: str, title: str):
        """(path, scope, how) of the best real marquee, or None"""
        keys = [('name', item.lower())] + [('title', t) for t in dict.fromkeys([ntitle(title), ntitle(item)]) if t]
        for scope in ('self', 'other'):
            for how, k in keys:
                idx = self.by_name if how == 'name' else self.by_title
                for p in idx.get((scope, k), ()):
                    if self.ok(p):
                        return p, scope, how
        return None


def donor_roots(root: Path, arg: str | None) -> list:
    """the other frontend builds: top-level folders of the frontend's drive with collections\\ (RetroFE) or a
    RetroBat roms\\ (also one level down, e.g. CP78\\RetroBat)"""
    if arg:
        cands = [Path(x.strip()) for x in arg.split(',') if x.strip()]
    else:
        cands = []
        try:
            for e in os.scandir(root.anchor):
                if e.is_dir(follow_symlinks=False) and not is_reparse(e.path):
                    cands.append(Path(e.path))
                    try:
                        cands += [Path(x.path) for x in os.scandir(e.path)
                                  if x.is_dir(follow_symlinks=False) and x.name.lower() == 'retrobat']
                    except OSError:
                        pass
        except OSError:
            pass
    out = []
    rr = str(root.resolve()).lower()
    for c in cands:
        cr = str(c.resolve()).lower()
        if rr.startswith(cr + os.sep) or rr == cr:
            continue                                   # the folder holding this build (R:\ArcadeMaster)
        if (c / 'collections').is_dir() and not is_reparse(str(c / 'collections')):
            out.append(('retrofe', c))
        elif (c / 'roms').is_dir() and ((c / 'emulationstation').is_dir() or (c / 'retrobat.exe').exists()):
            out.append(('retrobat', c / 'roms'))
    return out


# ------------------------------------------------------------------ placeholder drawing
_font_cache: dict = {}


def font(px: int, black=True) -> ImageFont.FreeTypeFont:
    key = (px, black)
    if key not in _font_cache:
        for f in (('seguibl.ttf', 'segoeuib.ttf') if black else ('segoeuib.ttf',)) + ('arialbd.ttf',):
            try:
                _font_cache[key] = ImageFont.truetype(str(FONT_DIR / f), px)
                break
            except OSError:
                continue
        else:
            _font_cache[key] = ImageFont.load_default()
    return _font_cache[key]


def accent_of(key: str):
    return ACCENTS[int(hashlib.md5(key.lower().encode('utf-8')).hexdigest(), 16) % len(ACCENTS)]


def lighten(c, k=0.55):
    return tuple(int(v + (255 - v) * k) for v in c)


def cover(img: Image.Image, w: int, h: int, focus_y=0.45) -> Image.Image:
    iw, ih = img.size
    s = max(w / iw, h / ih)
    nw, nh = max(w, math.ceil(iw * s)), max(h, math.ceil(ih * s))
    x, y = (nw - w) // 2, int((nh - h) * focus_y)
    # crop in source space first (cheaper resize)
    box = (x / s, y / s, (x + w) / s, (y + h) / s)
    return img.resize((w, h), Image.BILINEAR, box=box, reducing_gap=2.0)


_statics: dict = {}
_static_lock = threading.Lock()


def statics():
    with _static_lock:
        if not _statics:
            # vignette: black, stronger towards the edges
            vw, vh = 192, 48
            v = Image.new('L', (vw, vh))
            px = v.load()
            for yy in range(vh):
                for xx in range(vw):
                    dx, dy = (xx + .5) / vw * 2 - 1, (yy + .5) / vh * 2 - 1
                    r = math.sqrt(dx * dx * 0.85 + dy * dy * 0.55)
                    px[xx, yy] = int(max(0.0, min(1.0, (r - 0.45) / 0.75)) ** 1.6 * 130)
            vig = Image.new('RGBA', (MW, MH), (0, 0, 0, 255))
            vig.putalpha(v.resize((MW, MH), Image.BICUBIC))
            _statics['vig'] = vig
            # a dark pool behind the logo / title, for contrast on bright backdrops
            pool = Image.new('L', (MW // 4, MH // 4), 0)
            ImageDraw.Draw(pool).ellipse((MW // 4 * 0.14, MH // 4 * 0.12, MW // 4 * 0.86, MH // 4 * 0.88), fill=150)
            pool = pool.filter(ImageFilter.GaussianBlur(14)).resize((MW, MH), Image.BICUBIC)
            p = Image.new('RGBA', (MW, MH), (0, 0, 0, 255))
            p.putalpha(pool)
            _statics['pool'] = p
        return _statics


_frames: dict = {}


def frame(accent) -> Image.Image:
    with _static_lock:
        if accent not in _frames:
            # subtle and modern: one thin line in a softened accent, part transparent, no glow
            f = Image.new('RGBA', (MW, MH), (0, 0, 0, 0))
            box = (14, 14, MW - 15, MH - 15)
            ImageDraw.Draw(f).rounded_rectangle(box, 18, outline=lighten(accent, .35) + (120,), width=2)
            _frames[accent] = f
        return _frames[accent]


def gradient_bg(accent, key: str) -> Image.Image:
    """a calm dark gradient for a game with no art of its own: near-black with a faint tint of the accent,
    a little lighter in the middle"""
    edge = tuple(int(c * .06 + b * .94) for c, b in zip(accent, BG))
    mid = tuple(int(c * .16 + b * .84) for c, b in zip(accent, (24, 26, 36)))
    small = Image.new('RGB', (3, 1))
    small.putpixel((0, 0), edge)
    small.putpixel((1, 0), mid)
    small.putpixel((2, 0), edge)
    bg = small.resize((MW, MH), Image.BICUBIC)
    # the same soft fall-off vertically
    lift = Image.new('L', (MW // 8, MH // 8), 0)
    ImageDraw.Draw(lift).ellipse((-MW // 16, -MH // 32, MW // 8 + MW // 16, MH // 8 + MH // 32), fill=60)
    lift = lift.filter(ImageFilter.GaussianBlur(10)).resize((MW, MH), Image.BICUBIC)
    bg = Image.composite(Image.new('RGB', (MW, MH), lighten(mid, .08)), bg, lift)
    return bg.convert('RGBA')


def load_bg(backdrop: Path | None, fanart: Path | None, accent, key: str):
    if backdrop:
        try:
            with Image.open(backdrop) as im:
                im.draft('RGB', (MW, MW * im.size[1] // max(1, im.size[0])))
                bg = cover(im.convert('RGB'), MW, MH)
            bg = ImageEnhance.Brightness(bg).enhance(0.8)
            return bg.convert('RGBA'), 'backdrop'
        except Exception:
            pass
    if fanart:
        try:
            with Image.open(fanart) as im:
                im.draft('RGB', (MW // 2, MW // 2 * im.size[1] // max(1, im.size[0])))
                small = cover(im.convert('RGB'), MW // 2, MH // 2)
            small = small.filter(ImageFilter.GaussianBlur(5))
            bg = small.resize((MW, MH), Image.BICUBIC)
            bg = ImageEnhance.Brightness(ImageEnhance.Color(bg).enhance(1.15)).enhance(0.5)
            return bg.convert('RGBA'), 'fanart'
        except Exception:
            pass
    return gradient_bg(accent, key), 'gradient'


def glow_layer(mask: Image.Image, color, radius: int, gain: float) -> Image.Image:
    """coloured glow of an L mask (full size), blurred at half resolution"""
    small = mask.resize((MW // 2, MH // 2), Image.BILINEAR).filter(ImageFilter.GaussianBlur(radius / 2))
    a = small.point(lambda v: min(255, int(v * gain))).resize((MW, MH), Image.BICUBIC)
    lay = Image.new('RGBA', (MW, MH), color + (255,))
    lay.putalpha(a)
    return lay


def place_logo(canvas: Image.Image, logo_path: Path, accent) -> bool:
    try:
        with Image.open(logo_path) as im:
            logo = im.convert('RGBA')
    except Exception:
        return False
    a = logo.getchannel('A')
    bb = a.point(lambda v: 255 if v > 16 else 0).getbbox()
    if not bb or (bb[2] - bb[0]) < 8 or (bb[3] - bb[1]) < 8:
        return False
    logo = logo.crop(bb)
    w, h = logo.size
    box_w, box_h = 1560, 380
    s = min(box_w / w, box_h / h, 4.0)
    nw, nh = max(1, int(w * s)), max(1, int(h * s))
    logo = logo.resize((nw, nh), Image.LANCZOS)
    x, y = (MW - nw) // 2, (MH - nh) // 2
    mask = Image.new('L', (MW, MH), 0)
    mask.paste(logo.getchannel('A'), (x, y))
    # brightness of the logo itself: a dark logo gets a bright halo so it still reads on a dark marquee
    lum = logo_luma(logo)
    dark = lum < 100
    halo = lighten(accent, .7) if dark else accent
    shadow = Image.new('RGBA', (MW, MH), (0, 0, 0, 255))
    shadow.putalpha(mask.filter(ImageFilter.GaussianBlur(6)).point(lambda v: int(v * .75)))
    canvas.alpha_composite(glow_layer(mask, halo, 34, 2.2 if dark else 1.15))
    canvas.alpha_composite(glow_layer(mask, lighten(halo, .3), 10, 1.6 if dark else 1.0))
    canvas.alpha_composite(shadow, (4, 6))
    canvas.alpha_composite(logo, (x, y))
    return True


def logo_luma(rgba: Image.Image) -> float:
    """mean brightness of the logo's opaque pixels"""
    small = rgba.copy()
    small.thumbnail((96, 96))
    mask = small.getchannel('A').point(lambda v: 255 if v > 128 else 0)
    if not mask.getbbox():
        return 255.0
    return ImageStat.Stat(small.convert('L'), mask).mean[0]


def fit_title(title: str, maxw=1620, maxh=320):
    """(lines, px) - one line when it fits big enough, else two balanced lines; never wider than maxw"""
    t = title.upper().strip() or '?'
    ref = 100

    def width(s, px):
        b = font(px).getbbox(s)
        return b[2] - b[0]

    def size_for(lines):
        widest = max(width(l, ref) for l in lines)
        by_w = ref * maxw / max(1, widest)
        by_h = maxh / (len(lines) * 1.08)
        return int(min(by_w, by_h, 230))

    one = size_for([t])
    words = t.split()
    if len(words) > 1 and one < 150:
        two = max(([' '.join(words[:i]), ' '.join(words[i:])] for i in range(1, len(words))), key=size_for)
        px2 = size_for(two)
        if px2 > one * 1.12:
            return two, px2
    return [t], one


def place_title(canvas: Image.Image, title: str, accent):
    lines, px = fit_title(title)
    f = font(px)
    sw = max(3, px // 16)
    fill_mask = Image.new('L', (MW, MH), 0)
    stroke_mask = Image.new('L', (MW, MH), 0)
    df, ds = ImageDraw.Draw(fill_mask), ImageDraw.Draw(stroke_mask)
    lh = px * 1.08
    y0 = MH / 2 - lh * (len(lines) - 1) / 2
    for i, l in enumerate(lines):
        pos = (MW / 2, y0 + i * lh)
        df.text(pos, l, font=f, fill=255, anchor='mm')
        ds.text(pos, l, font=f, fill=255, anchor='mm', stroke_width=sw, stroke_fill=255)
    canvas.alpha_composite(glow_layer(stroke_mask, accent, 40, 0.9))
    sh = Image.new('RGBA', (MW, MH), (0, 0, 0, 255))
    sh.putalpha(stroke_mask.filter(ImageFilter.GaussianBlur(5)).point(lambda v: int(v * .7)))
    canvas.alpha_composite(sh, (5, 7))
    edge = Image.new('RGBA', (MW, MH), accent + (255,))
    edge.putalpha(stroke_mask)
    canvas.alpha_composite(edge)
    # fill: white at the top fading to a pale accent at the bottom of each line
    grad = Image.new('RGB', (1, 2))
    grad.putpixel((0, 0), (255, 255, 255))
    grad.putpixel((0, 1), lighten(accent, .45))
    g = grad.resize((MW, MH), Image.BILINEAR).convert('RGBA')
    g.putalpha(fill_mask)
    canvas.alpha_composite(g)


def render_placeholder(title: str, key: str, logo: Path | None, backdrop: Path | None, fanart: Path | None,
                       accent=None) -> tuple[Image.Image, str]:
    accent = accent or accent_of(key)
    st = statics()
    canvas, bgkind = load_bg(backdrop, fanart, accent, key)
    if bgkind != 'gradient':
        tint = Image.new('RGBA', (MW, MH), accent + (28,))
        canvas.alpha_composite(tint)
    canvas.alpha_composite(st['pool'])
    canvas.alpha_composite(st['vig'])
    used = 'logo' if (logo and place_logo(canvas, logo, accent)) else 'title'
    if used == 'title':
        place_title(canvas, title, accent)
    canvas.alpha_composite(frame(accent))
    return canvas.convert('RGB'), f'{bgkind}+{used}'


# ------------------------------------------------------------------ the run
class Run:
    def __init__(self, a, root: Path, man: Path, log):
        self.a, self.root, self.man, self.log = a, root, man, log
        self.mf_path = man / 'marquees.json'
        self.mf = {'version': 1, 'files': {}}
        if self.mf_path.exists():
            try:
                self.mf = json.loads(self.mf_path.read_text(encoding='utf-8'))
                self.mf.setdefault('files', {})
            except ValueError:
                pass
        self.lock = threading.Lock()
        self.dirty = 0
        self.donors: Donors | None = None
        self.redirected: list = []
        self.errors: list = []
        self.made = 0
        self.redone: set = set()
        self.limit = a.limit if a.limit and a.limit > 0 else None

    # -- manifest
    def rel(self, p: Path | str) -> str:
        return os.path.relpath(str(p), str(self.root))

    def ours(self, p: Path | str):
        return self.mf['files'].get(self.rel(p).lower())

    def record(self, p: Path, **kw):
        if self.a.dry_run:
            return
        with self.lock:
            kw.update(path=self.rel(p), at=time.strftime('%Y-%m-%dT%H:%M:%S'))
            self.mf['files'][self.rel(p).lower()] = kw
            self.dirty += 1
            if self.dirty >= 100:
                self.save_manifest_locked()

    def forget(self, p: Path):
        with self.lock:
            self.mf['files'].pop(self.rel(p).lower(), None)

    def save_manifest_locked(self):
        if self.a.dry_run:
            return
        self.mf['updated'] = time.strftime('%Y-%m-%dT%H:%M:%S')
        self.mf['retrofe'] = str(self.root)
        tmp = self.mf_path.with_suffix('.json.part')
        tmp.write_text(json.dumps(self.mf, indent=1, ensure_ascii=False), encoding='utf-8')
        os.replace(tmp, self.mf_path)
        self.dirty = 0

    def save_manifest(self):
        with self.lock:
            self.save_manifest_locked()

    def take_slot(self) -> bool:
        with self.lock:
            if self.limit is not None and self.made >= self.limit:
                return False
            self.made += 1
            return True

    # -- writing
    def write_image(self, img: Image.Image, dst: Path, fmt: str):
        ensure_dir(str(dst.parent), str(self.root))
        check_write_file(str(dst), str(self.root))
        tmp = dst.with_name(dst.name + '.part')
        if fmt == 'PNG':
            img.save(tmp, 'PNG', optimize=False, compress_level=6)
        else:
            img.save(tmp, 'JPEG', quality=88, optimize=True, progressive=True)
        os.replace(tmp, dst)

    def copy_file(self, src: str, dst: Path, link: bool):
        ensure_dir(str(dst.parent), str(self.root))
        check_write_file(str(dst), str(self.root))
        tmp = dst.with_name(dst.name + '.part')
        if os.path.lexists(tmp):
            os.unlink(tmp)
        if link:
            try:
                os.link(src, tmp)
            except OSError:
                shutil.copyfile(src, tmp)
        else:
            shutil.copyfile(src, tmp)
        os.replace(tmp, dst)

    def drop_other(self, dst_dir: Path, stem: str, keep: Path):
        """an old file of ours under another extension (a placeholder .jpg replaced by a real .png) goes"""
        for e in IMG_EXTS:
            p = dst_dir / f'{stem}{e}'
            if p != keep and p.exists() and self.ours(p):
                os.unlink(p)
                self.forget(p)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description='Marquees for every game and main-menu collection (real ones found '
                                             'elsewhere, else a generated placeholder).')
    ap.add_argument('--retrofe', default=DEFAULT_RETROFE, type=Path)
    ap.add_argument('--manifest', default=MANIFEST_DIR, type=Path)
    ap.add_argument('--collections', help='comma list; merged (.sub) collections expand to their sources')
    ap.add_argument('--dry-run', action='store_true', help='find the gaps and what would fill them; write nothing')
    ap.add_argument('--force-placeholders', action='store_true',
                    help='redraw the placeholders this tool made (a real marquee replaces one when found)')
    ap.add_argument('--limit', type=int, default=0, help='make at most N new files this run (the next run continues)')
    ap.add_argument('--jobs', type=int, default=max(2, min(8, (os.cpu_count() or 4))))
    ap.add_argument('--donors', help='comma list of other frontend builds to take real marquees from '
                                     '(default: every RetroFE / RetroBat build on the same drive)')
    ap.add_argument('--no-donors', action='store_true', help='placeholders only, no search for real marquees')
    ap.add_argument('--no-main', action='store_true', help='skip the main menu collection marquees')
    ap.add_argument('--sheet', type=Path, help='write a contact sheet of 12 marquees from the manifest and stop')
    a = ap.parse_args(argv)
    t0 = time.time()
    log = lambda m: print(m, flush=True)
    root, man = a.retrofe.resolve(), a.manifest.resolve()
    if on_forbidden_drive(str(root)):
        log(f'refusing: {root} resolves onto a forbidden drive (the live cabinet)')
        return 1
    if on_forbidden_drive(str(man)):
        log(f'refusing: {man} resolves onto a forbidden drive')
        return 1
    if not (root / 'collections').is_dir():
        log(f'no collections folder in {root}')
        return 1
    if a.sheet:
        return contact_sheet(root, man, a.sheet, log)
    man.mkdir(parents=True, exist_ok=True)
    run = Run(a, root, man, log)
    fe = Frontend(root)

    # ---- titles and catalog items (games.json + meta.db)
    catalog_items: dict = {}
    gj_title: dict = {}
    gj = man / 'games.json'
    if gj.exists():
        for g in json.loads(gj.read_text(encoding='utf-8-sig')).get('games', []):
            for s in g.get('sources') or []:
                if s.get('collection') and s.get('item'):
                    catalog_items.setdefault(s['collection'].lower(), []).append(s['item'])
                    if g.get('title'):
                        gj_title.setdefault((s['collection'].lower(), s['item'].lower()), g['title'])
    meta_title, meta_names = {}, {}
    mdb = root / 'meta.db'
    if mdb.exists():
        con = sqlite3.connect(f'file:{mdb}?mode=ro', uri=True)
        for col, name, title in con.execute('select collectionName, name, title from Meta'):
            meta_names.setdefault(col.lower(), []).append(name)
            if title:
                meta_title[(col.lower(), name.lower())] = title
        con.close()

    # ---- collections (sources of merged lists first, so the merged list only links)
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
    order = {c: i for i, c in enumerate(cols)}
    cols.sort(key=lambda c: (any((fe.cdir / c).glob('*.sub')), order[c]))
    mtypes = {}

    def mtype_of(c):
        if c not in mtypes:
            mtypes[c] = read_conf(fe.cdir / c / 'settings.conf').get('metadata.type', c).replace('%ITEM_COLLECTION_NAME%', c)
        return mtypes[c]

    def title_of(scol, item):
        return clean_title(meta_title.get((mtype_of(scol).lower(), item.lower())) or meta_title.get((scol.lower(), item.lower()))
                           or gj_title.get((scol.lower(), item.lower())) or item) or item

    art_cache: dict = {}

    def art(col: str, kind: str) -> dict:
        k = (col.lower(), kind)
        if k not in art_cache:
            art_cache[k] = list_stems(fe.cdir / col / 'medium_artwork' / kind)
        return art_cache[k]

    def art_path(col, kind, item):
        fn = art(col, kind).get(item.lower())
        return fe.cdir / col / 'medium_artwork' / kind / fn if fn else None

    def target_dir(col: str) -> Path:
        d = fe.cdir / col / 'medium_artwork' / 'marquee'
        if is_reparse(str(d)) or is_reparse(str(d.parent)):
            alt = fe.cdir / col / 'medium_artwork' / 'am_marquee'
            if col not in run.redirected:
                run.redirected.append(col)
            return alt
        return d

    def present(col: str, item: str):
        """file name of the marquee this collection already shows for item (marquee or am_marquee), else None"""
        for kind in ('marquee', 'am_marquee'):
            fn = art(col, kind).get(item.lower())
            if fn:
                return fe.cdir / col / 'medium_artwork' / kind / fn
        return None

    # ---- plan: per collection, its own games + the games it merges in
    plan = []                     # (col, scol, item)
    for col in cols:
        seen = set()
        for it in fe.items(col, meta_names, catalog_items):
            seen.add(it.lower())
            plan.append((col, col, it))
        for sf in sorted((fe.cdir / col).glob('*.sub')):
            sc = sf.stem
            if sc.lower() == col.lower() or SKIP_DEFAULT.match(sc) or not (fe.cdir / sc).is_dir() or not fe.is_game_collection(sc):
                continue
            only = {x.lower() for x in read_list(sf)}
            for it in fe.items(sc, meta_names, catalog_items):
                if (not only or it.lower() in only) and it.lower() not in seen:
                    seen.add(it.lower())
                    plan.append((col, sc, it))
    t_plan = time.time()

    def needs(col, item):
        p = present(col, item)
        if p is None:
            return True, None
        e = run.ours(p)
        if a.force_placeholders and e and e.get('kind') == 'placeholder':
            return True, p
        return False, p

    todo_count = sum(1 for col, scol, it in plan if needs(col, it)[0])
    log(f'{len(plan)} games in {len(cols)} collections, {todo_count} without a marquee'
        + (' (or with a placeholder to redraw)' if a.force_placeholders else '') + f'  [{t_plan - t0:.1f}s]')

    # ---- donors (only when something is missing)
    if todo_count and not a.no_donors:
        td = time.time()
        donors = Donors(log)
        ours_abs = {str(root / v['path']).lower() for v in run.mf['files'].values()}
        roots = donor_roots(root, a.donors)
        with ThreadPoolExecutor(max_workers=8) as ex:
            futs = [ex.submit(donors.add_retrofe, root, 'self', ours_abs)]
            for kind, p in roots:
                futs.append(ex.submit(donors.add_retrofe, p, 'other', set()) if kind == 'retrofe' else ex.submit(donors.add_retrobat, p))
            for f in futs:
                f.result()
        run.donors = donors
        log(f'real marquees to draw from: {sum(donors.counts.values())} files in {len(donors.counts)} builds '
            f'({len(roots)} other builds)  [{time.time() - td:.1f}s]')

    # ---- work
    stats: dict = {}                  # col -> counters
    key_locks: dict = {}

    def bump(col, k, n=1):
        with run.lock:
            s = stats.setdefault(col, {'games': 0, 'had': 0, 'real': 0, 'placeholder': 0, 'failed': 0, 'skipped': 0, 'sec': 0.0})
            s[k] += n

    def lock_for(k):
        with run.lock:
            return key_locks.setdefault(k, threading.Lock())

    def make_own(col, item, old: Path | None):
        """make the marquee of item in col's own folder; returns (path, kind)"""
        with run.lock:
            run.redone.add((col.lower(), item.lower()))
        tdir = target_dir(col)
        title = title_of(col, item)
        if run.donors:
            hit = run.donors.find(item, title)
            if hit:
                src, scope, how = hit
                w, h = run.donors.dims[src]
                ext = os.path.splitext(src)[1].lower()
                direct = ext in ('.png', '.jpg', '.jpeg') and w <= MAX_W
                out_ext = '.jpg' if ext == '.jpeg' else ext
                if not direct:
                    with Image.open(src) as im:
                        alpha = im.mode in ('RGBA', 'LA') or (im.mode == 'P' and 'transparency' in im.info)
                    out_ext = '.png' if alpha else '.jpg'
                dst = tdir / f'{item}{out_ext}'
                if a.dry_run:
                    return dst, 'real'
                if direct:
                    run.copy_file(src, dst, link=(scope == 'self'))
                else:
                    with Image.open(src) as im:
                        im = im.convert('RGBA' if out_ext == '.png' else 'RGB')
                        if im.size[0] > MAX_W:
                            im = im.resize((MAX_W, round(im.size[1] * MAX_W / im.size[0])), Image.LANCZOS)
                        run.write_image(im, dst, 'PNG' if out_ext == '.png' else 'JPEG')
                run.drop_other(tdir, item, dst)
                run.record(dst, collection=col, item=item, kind='real', source=src, match=how,
                           link=(scope == 'self' and direct))
                return dst, 'real'
        dst = tdir / f'{item}.jpg'
        if a.dry_run:
            return dst, 'placeholder'
        logo = art_path(col, 'logo', item)
        img, how = render_placeholder(title, f'{col}/{item}', logo, art_path(col, 'am_backdrop', item),
                                      art_path(col, 'fanart', item))
        run.write_image(img, dst, 'JPEG')
        run.drop_other(tdir, item, dst)
        run.record(dst, collection=col, item=item, kind='placeholder', source=how, title=title, v=PLACEHOLDER_VERSION)
        return dst, 'placeholder'

    def job(col, scol, item):
        t = time.time()
        try:
            need, old = needs(col, item)
            if not need:
                bump(col, 'had')
                return
            if not run.take_slot():
                bump(col, 'skipped')
                return
            if scol == col:
                with lock_for((col.lower(), item.lower())):
                    p, kind = make_own(col, item, old)
            else:
                # a merged game: the source collection's marquee, hard-linked (made there first when missing)
                made = None
                with lock_for((scol.lower(), item.lower())):
                    sp = present(scol, item)
                    se = run.ours(sp) if sp else None
                    redo = (a.force_placeholders and se and se.get('kind') == 'placeholder'
                            and (scol.lower(), item.lower()) not in run.redone)
                    if sp is None or redo:
                        sp, made = make_own(scol, item, sp)
                        if not a.dry_run:
                            with run.lock:
                                art(scol, sp.parent.name)[item.lower()] = sp.name
                    se = run.ours(sp) if (sp is not None and not a.dry_run) else None
                kind = made or (se or {}).get('kind') or 'real'
                tdir = target_dir(col)
                ext = sp.suffix.lower()
                dst = tdir / f'{item}{".jpg" if ext == ".jpeg" else ext}'
                if not a.dry_run:
                    run.copy_file(str(sp), dst, link=True)
                    run.drop_other(tdir, item, dst)
                    run.record(dst, collection=col, item=item, kind=kind, source=run.rel(sp), link=True, merged=True)
                p = dst
            if not a.dry_run:
                with run.lock:
                    art(col, p.parent.name)[item.lower()] = p.name
            bump(col, kind)
        except Unsafe as ex:
            bump(col, 'failed')
            run.errors.append(f'REFUSED {col}/{item}: {ex}')
        except Exception as ex:
            bump(col, 'failed')
            run.errors.append(f'{col}/{item}: {type(ex).__name__}: {ex}')
        finally:
            bump(col, 'sec', time.time() - t)

    t_work = time.time()
    by_col: dict = {}
    for col, scol, it in plan:
        by_col.setdefault(col, []).append((col, scol, it))
    for col in cols:
        lst = by_col.get(col, [])
        bump(col, 'games', len(lst))
        tc = time.time()
        with ThreadPoolExecutor(max_workers=a.jobs) as ex:
            list(ex.map(lambda x: job(*x), lst))
        stats[col]['wall'] = time.time() - tc
    run.save_manifest()
    t_main = time.time()

    # ---- main menu collection marquees
    main_stats = None
    if not a.no_main and not a.collections:
        main_stats = main_menu(run, fe, root, man, log)
        run.save_manifest()

    # ---- summary
    t_end = time.time()
    log('')
    log(f'{"collection":34} {"games":>6} {"had":>6} {"real":>6} {"placeh":>6} {"failed":>6} {"time":>7}')
    tot = {'games': 0, 'had': 0, 'real': 0, 'placeholder': 0, 'failed': 0, 'skipped': 0}
    for col in cols:
        s = stats.get(col)
        if not s:
            continue
        for k in tot:
            tot[k] += s[k]
        log(f'{col[:34]:34} {s["games"]:6} {s["had"]:6} {s["real"]:6} {s["placeholder"]:6} {s["failed"]:6} {s.get("wall", 0):6.1f}s')
    if main_stats:
        log(f'{"(main menu)":34} {main_stats["games"]:6} {main_stats["had"]:6} {main_stats["real"]:6} '
            f'{main_stats["placeholder"]:6} {main_stats["failed"]:6} {main_stats["sec"]:6.1f}s')
    log(f'{"TOTAL":34} {tot["games"]:6} {tot["had"]:6} {tot["real"]:6} {tot["placeholder"]:6} {tot["failed"]:6} '
        f'{t_end - t0:6.1f}s' + ('  [dry run]' if a.dry_run else ''))
    if tot['skipped']:
        log(f'{tot["skipped"]} left for the next run (--limit {a.limit})')
    if run.redirected:
        log('marquee folder is a junction - written to medium_artwork\\am_marquee instead: ' + ', '.join(run.redirected))
    for e in run.errors[:25]:
        log('  ' + e)
    if len(run.errors) > 25:
        log(f'  ... {len(run.errors) - 25} more')
    log(f'time: plan {t_plan - t0:.1f}s, games {t_main - t_work:.1f}s, main menu {t_end - t_main:.1f}s, total {t_end - t0:.1f}s')
    log(f'manifest: {run.mf_path}')
    return 1 if any(e.startswith('REFUSED') for e in run.errors) else 0


def main_menu(run: Run, fe, root: Path, man: Path, log) -> dict:
    """a marquee for every collection on the main menu, where this build keeps the main menu's art"""
    s = {'games': 0, 'had': 0, 'real': 0, 'placeholder': 0, 'failed': 0, 'sec': 0.0}
    t = time.time()
    names = []
    for p in (fe.cdir / 'Main' / 'menu.txt', man / 'main-menu-full.txt'):
        for n in read_list(p):
            if n not in names and (fe.cdir / n).is_dir():
                names.append(n)
    for p in (fe.cdir / 'Main' / 'menu').glob('*.txt') if (fe.cdir / 'Main' / 'menu').is_dir() else ():
        if p.stem not in names and (fe.cdir / p.stem).is_dir():
            names.append(p.stem)
    lay = root / 'layouts' / LAYOUT / 'collections'
    tdir = lay / 'Main' / 'medium_artwork' / 'marquee'
    for n in names:
        s['games'] += 1
        have = None
        for d in (tdir, fe.cdir / 'Main' / 'medium_artwork' / 'marquee', fe.cdir / n / 'system_artwork',
                  lay / n / 'system_artwork'):
            st = list_stems(d)
            fn = st.get(n.lower()) if 'medium_artwork' in str(d) else st.get('marquee')
            if fn:
                have = d / fn
                break
        e = run.ours(have) if have else None
        if have and not (run.a.force_placeholders and e and e.get('kind') == 'placeholder'):
            s['had'] += 1
            continue
        if run.a.dry_run:
            s['placeholder'] += 1
            continue
        try:
            logo = None
            for c in (lay / 'Main' / 'medium_artwork' / 'logo' / f'{n}.png', fe.cdir / n / 'system_artwork' / 'logo.png',
                      lay / n / 'system_artwork' / 'logo.png'):
                if c.exists():
                    logo = c
                    break
            bg = None
            for d in (lay / n / 'system_artwork', fe.cdir / n / 'system_artwork', lay / 'Main' / 'system_artwork'):
                cands = sorted(d.glob('am_bg*.*')) + sorted(d.glob('fanart.*')) if d.is_dir() else []
                if cands:
                    bg = cands[0]
                    break
            title = re.sub(r'^\d+[a-z]?\s+', '', n).strip()
            img, how = render_placeholder(title, f'Main/{n}', logo, None, bg)
            dst = tdir / f'{n}.png'
            run.write_image(img, dst, 'PNG')
            run.record(dst, collection='Main', item=n, kind='placeholder', source=how, title=title, v=PLACEHOLDER_VERSION)
            s['placeholder'] += 1
        except Unsafe as ex:
            s['failed'] += 1
            run.errors.append(f'REFUSED Main/{n}: {ex}')
        except Exception as ex:
            s['failed'] += 1
            run.errors.append(f'Main/{n}: {type(ex).__name__}: {ex}')
    s['sec'] = time.time() - t
    log(f'main menu: {len(names)} collections ({", ".join(names)}) -> {tdir}')
    return s


def contact_sheet(root: Path, man: Path, out: Path, log, n=12) -> int:
    """12 marquees from the manifest, real and placeholder mixed, two to a row, about 2000 px wide"""
    mf = json.loads((man / 'marquees.json').read_text(encoding='utf-8'))
    files = [v for v in mf.get('files', {}).values() if not v.get('merged') and (root / v['path']).exists()]
    rnd = random.Random(7)
    real = [v for v in files if v['kind'] == 'real']
    ph = [v for v in files if v['kind'] == 'placeholder' and v.get('collection') != 'Main']
    mainm = [v for v in files if v.get('collection') == 'Main']
    # variety: placeholders from each background / logo kind
    groups: dict = {}
    for v in ph:
        groups.setdefault(v.get('source', ''), []).append(v)
    pick_ph = []
    for g in sorted(groups):
        rnd.shuffle(groups[g])
    while len(pick_ph) < 6 and any(groups.values()):
        for g in sorted(groups):
            if groups[g] and len(pick_ph) < 6:
                pick_ph.append(groups[g].pop())
    pick = rnd.sample(real, min(len(real), n - len(pick_ph) - min(1, len(mainm)))) + pick_ph + mainm[:1]
    pick = pick[:n]
    rnd.shuffle(pick)
    cw, ch, gap, lab = 980, 245, 14, 34
    cols_ = 2
    rows = math.ceil(len(pick) / cols_)
    W = cols_ * cw + (cols_ + 1) * gap
    H = rows * (ch + lab + gap) + gap + 50
    sheet = Image.new('RGB', (W, H), (14, 15, 22))
    d = ImageDraw.Draw(sheet)
    d.text((gap, 12), f'ArcadeMaster marquees - {len(real)} real copied, {len(ph)} placeholders  ({root.name})',
           font=font(26, black=False), fill=(230, 233, 240))
    for i, v in enumerate(pick):
        x = gap + (i % cols_) * (cw + gap)
        y = 50 + gap + (i // cols_) * (ch + lab + gap)
        with Image.open(root / v['path']) as im:
            im = im.convert('RGB')
            s = min(cw / im.size[0], ch / im.size[1])
            im = im.resize((max(1, int(im.size[0] * s)), max(1, int(im.size[1] * s))), Image.LANCZOS)
        d.rectangle((x, y, x + cw - 1, y + ch - 1), fill=(0, 0, 0))
        sheet.paste(im, (x + (cw - im.size[0]) // 2, y + (ch - im.size[1]) // 2))
        col = (61, 220, 132) if v['kind'] == 'real' else (255, 176, 0)
        sp = Path(v.get('source', '')).parts
        donor = sp[1] if len(sp) > 1 else '?'
        if str(v.get('source', '')).lower().startswith(str(root).lower()):
            donor = 'this build'
        info = v.get('source', '') if v['kind'] == 'placeholder' else f'from {donor}'
        d.text((x, y + ch + 5), f"{v['kind'].upper()}  {v['collection']} / {v['item']}  ({info})"[:90],
               font=font(20, black=False), fill=col)
    out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out, 'PNG', optimize=True)
    log(f'contact sheet: {len(pick)} marquees ({sum(1 for v in pick if v["kind"] == "real")} real) -> {out} ({W}x{H})')
    return 0


if __name__ == '__main__':
    sys.exit(main())
