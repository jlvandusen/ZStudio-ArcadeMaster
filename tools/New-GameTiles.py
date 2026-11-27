#!/usr/bin/env python3
r"""
New-GameTiles.py - a small picture tile for every game, for themes that show many games at once (Wall of Games).

A wall shows fifteen games on one screen. Loading fifteen full-screen pictures for that is slow, so each game gets one
small tile, drawn once: collections/<collection>/medium_artwork/am_tile/<item>.jpg, 384 x 216.

Where the picture comes from (first one found):
  1. the game's own fan art        medium_artwork/fanart/<item>.jpg|png
  2. its backdrop                  medium_artwork/am_backdrop/<item>.jpg   (a blurred frame of its video)
  3. nothing: a plain dark tile, so the game's logo still has something to sit on
The bottom third is darkened a little, because the theme puts the game's logo there.

Games are taken from every collection's own list (menu.txt, *.sub, the logos it has), so merged lists such as Racing
are covered through their sources. A tile that is already there is left alone unless --force.

  python tools/New-GameTiles.py --retrofe D:/ArcadeMaster/frontend/DRIVE-coinops [--collections TeknoParrot,MAME] [--force] [--dry-run]

Only ever writes into medium_artwork/am_tile. Never touches roms, videos or any other art.
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

from PIL import Image, ImageDraw, ImageOps

TILE = (384, 216)


def items_of(col: Path) -> set[str]:
    names: set[str] = set()
    for f in [col / 'menu.txt', *col.glob('*.sub')]:
        if f.is_file():
            names |= {ln.strip() for ln in f.read_text(encoding='utf-8', errors='replace').splitlines() if ln.strip() and not ln.startswith('#')}
    art = col / 'medium_artwork'
    for d in ('logo', 'fanart', 'am_backdrop'):
        if (art / d).is_dir():
            names |= {p.stem for p in (art / d).iterdir() if p.is_file() and p.suffix.lower() in ('.png', '.jpg', '.jpeg')}
    return names


def source_for(art: Path, item: str) -> Path | None:
    for d, exts in (('fanart', ('.jpg', '.png', '.jpeg')), ('am_backdrop', ('.jpg', '.png'))):
        for e in exts:
            p = art / d / (item + e)
            if p.is_file():
                return p
    return None


def shade_bottom(im: Image.Image) -> Image.Image:
    """darken the lower third so a logo on top stays readable"""
    w, h = im.size
    ov = Image.new('L', (1, h), 0)
    for y in range(h):
        t = max(0.0, (y - h * 0.45) / (h * 0.55))
        ov.putpixel((0, y), int(150 * t))
    black = Image.new('RGB', (w, h), (0, 0, 0))
    return Image.composite(black, im, ov.resize((w, h)))


def plain_tile() -> Image.Image:
    im = Image.new('RGB', TILE, (16, 19, 30))
    d = ImageDraw.Draw(im)
    for y in range(TILE[1]):
        c = 16 + int(18 * y / TILE[1])
        d.line((0, y, TILE[0], y), fill=(c, c + 3, c + 14))
    return im


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--retrofe', required=True, type=Path)
    ap.add_argument('--collections', help='comma list (default: every collection that has medium_artwork)')
    ap.add_argument('--force', action='store_true', help='draw tiles again even when they are there')
    ap.add_argument('--dry-run', action='store_true')
    a = ap.parse_args(argv)
    cdir = a.retrofe / 'collections'
    if not cdir.is_dir():
        print(f'no collections folder in {a.retrofe}')
        return 1
    want = {c.strip().lower() for c in a.collections.split(',')} if a.collections else None
    t0 = time.time()
    made = kept = plain = bad = 0
    for col in sorted(p for p in cdir.iterdir() if p.is_dir()):
        art = col / 'medium_artwork'
        if not art.is_dir() or (want and col.name.lower() not in want):
            continue
        out = art / 'am_tile'
        n_col = 0
        for item in sorted(items_of(col)):
            if any(ch in item for ch in '\\/:*?"<>|'):
                continue
            dst = out / (item + '.jpg')
            if dst.exists() and not a.force:
                kept += 1
                continue
            src = source_for(art, item)
            if src is None and not (art / 'logo' / (item + '.png')).is_file():
                continue          # a name with no art at all: not a game this cabinet shows
            try:
                if src is None:
                    im = plain_tile()
                    plain += 1
                else:
                    with Image.open(src) as s:
                        im = shade_bottom(ImageOps.fit(s.convert('RGB'), TILE, Image.LANCZOS, centering=(0.5, 0.4)))
                if not a.dry_run:
                    out.mkdir(parents=True, exist_ok=True)
                    im.save(dst, 'JPEG', quality=86, optimize=True)
                made += 1
                n_col += 1
            except Exception as e:      # one broken picture must not stop the rest
                bad += 1
                print(f'  could not make a tile for {col.name}/{item}: {e}')
        if n_col:
            print(f'  {col.name:<30} {n_col} tile(s)')
    print(f'game tiles: {made} made ({plain} plain, no art), {kept} already there, {bad} failed, {time.time() - t0:.1f}s'
          + ('  [dry run]' if a.dry_run else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main())
