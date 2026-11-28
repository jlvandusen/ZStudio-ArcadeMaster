#!/usr/bin/env python3
r"""
Repair-CheckerLogos.py - game logos that were saved with the grey-and-white "see-through" squares painted in.

Some logos come from a picture site's preview: the squares an editor draws behind a see-through picture are part of the
picture itself, so the menu shows a white box with squares around the logo (Battle Gear 4 Tuned on the racing cabinets,
2026-11-27). This finds those logos and takes the squares out, so only the logo is left.

How a logo is recognised: it has no see-through part at all, and its outer edge is made of two light greys that take
turns (the squares). What is taken out: only squares that are joined to the outer edge - a white part inside the logo's
own outline stays.

Without --apply it only lists what it found. With --apply the original is first copied to
  collections/<collection>/medium_artwork/logo_before_squares/<item>.png
(kept, never overwritten), then the logo is written again without the squares.

  python tools/Repair-CheckerLogos.py --retrofe D:/ArcadeMaster/frontend/DRIVE-coinops [--collections TeknoParrot] [--apply]

Only ever writes into medium_artwork/logo and medium_artwork/logo_before_squares.
"""
from __future__ import annotations

import argparse
import shutil
import sys
import time
from collections import Counter
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw

TOL = 14          # how far a pixel may be from a square's grey and still count as the square


def border_colours(im: Image.Image):
    """the two greys of the squares, or None when the edge is not squares"""
    w, h = im.size
    px = im.load()
    step = max(1, (w + h) // 400)
    edge = [px[x, y] for x in range(0, w, step) for y in (0, h - 1)] + [px[x, y] for y in range(0, h, step) for x in (0, w - 1)]
    cnt = Counter((r // 8, g // 8, b // 8) for r, g, b in edge)
    top = cnt.most_common(2)
    if len(top) < 2:
        return None
    (c1, n1), (c2, n2) = top
    if (n1 + n2) < 0.9 * len(edge) or n2 < 0.2 * len(edge):
        return None                                    # one flat colour, or a real picture
    cols = []
    for c in (c1, c2):
        r, g, b = (v * 8 + 4 for v in c)
        if max(r, g, b) - min(r, g, b) > 10 or min(r, g, b) < 180:
            return None                                # not a light grey
        cols.append((r, g, b))
    if abs(cols[0][0] - cols[1][0]) < 8:
        return None
    # the two greys must take turns along the top edge (squares), not sit in two halves
    row = [min(range(2), key=lambda i: abs(px[x, 0][0] - cols[i][0])) for x in range(w)]
    turns = sum(1 for a, b in zip(row, row[1:]) if a != b)
    return cols if turns >= 6 else None


def without_squares(im: Image.Image, cols) -> Image.Image:
    w, h = im.size
    near = None
    each = []
    for c in cols:                                     # 255 where the pixel is one of the two greys
        d2 = ImageChops.difference(im, Image.new('RGB', im.size, c))
        r, g, b = d2.split()
        m = ImageChops.lighter(ImageChops.lighter(r, g), b).point(lambda v: 255 if v <= TOL else 0)
        each.append(m)
        near = m if near is None else ImageChops.lighter(near, m)
    # flood from outside: a one-pixel frame of "square" around the picture joins every edge square
    pad = Image.new('L', (w + 2, h + 2), 255)
    pad.paste(near, (1, 1))
    ImageDraw.floodfill(pad, (0, 0), 128)
    # closed-in holes (the inside of a "4" or a "B"): taken out only when BOTH greys are in them, which a plain
    # white part of the logo never has
    for _ in range(400):
        left = pad.point(lambda v: 255 if v == 255 else 0)
        box = left.getbbox()
        if not box:
            break
        y = box[1]
        x = next(xx for xx in range(box[0], box[2]) if left.getpixel((xx, y)))
        ImageDraw.floodfill(pad, (x, y), 200)
        region = pad.point(lambda v: 255 if v == 200 else 0).crop((1, 1, w + 1, h + 1))
        area = region.histogram()[255]
        parts = [ImageChops.multiply(region, m).histogram()[255] for m in each]
        squares = area >= 64 and min(parts) >= 0.15 * area
        pad = pad.point(lambda v, s=squares: (128 if s else 60) if v == 200 else v)
    outside = pad.crop((1, 1, w + 1, h + 1)).point(lambda v: 0 if v == 128 else 255)     # 0 = take out
    out = im.convert('RGBA')
    out.putalpha(outside)
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--retrofe', required=True, type=Path)
    ap.add_argument('--collections', help='comma list (default: every collection that has logos)')
    ap.add_argument('--apply', action='store_true', help='write the repaired logos (the originals are kept beside them)')
    a = ap.parse_args(argv)
    cdir = a.retrofe / 'collections'
    if not cdir.is_dir():
        print(f'no collections folder in {a.retrofe}')
        return 1
    want = {c.strip().lower() for c in a.collections.split(',')} if a.collections else None
    t0 = time.time()
    seen = found = fixed = bad = 0
    for col in sorted(p for p in cdir.iterdir() if p.is_dir()):
        logos = col / 'medium_artwork' / 'logo'
        if not logos.is_dir() or (want and col.name.lower() not in want):
            continue
        for f in sorted(logos.glob('*.png')):
            seen += 1
            try:
                with Image.open(f) as s:
                    if s.width < 64 or s.height < 32 or s.width * s.height > 6_000_000:
                        continue
                    if s.mode in ('RGBA', 'LA', 'P') and s.convert('RGBA').getchannel('A').getextrema()[0] < 250:
                        continue                       # it has see-through parts: a proper logo
                    im = s.convert('RGB')
                cols = border_colours(im)
                if not cols:
                    continue
                found += 1
                print(f'  squares painted in: {col.name}/{f.name}  ({im.width}x{im.height})')
                if a.apply:
                    out = without_squares(im, cols)
                    keep = col / 'medium_artwork' / 'logo_before_squares'
                    keep.mkdir(parents=True, exist_ok=True)
                    if not (keep / f.name).exists():
                        shutil.copy2(f, keep / f.name)
                    box = out.getchannel('A').getbbox()
                    if box:
                        out = out.crop(box)             # no empty margin, so the menu sizes the logo itself
                    out.save(f, 'PNG', optimize=True)
                    fixed += 1
            except Exception as e:                      # one broken picture must not stop the rest
                bad += 1
                print(f'  could not read {col.name}/{f.name}: {e}')
    print(f'logos with squares: {found} found in {seen} logos, {fixed} repaired, {bad} unreadable, {time.time() - t0:.1f}s'
          + ('' if a.apply else '  [list only; --apply repairs them]'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
