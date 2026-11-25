#!/usr/bin/env python3
"""
New-LayoutFx.py - motion layers for the ArcadeMaster layout (all original art, generated).

  fx_stars.png      3840x1080 starfield, 2 screens wide: the layout slides it left and wraps -> endless drift
  fx_grid.png       1920x600 neon perspective floor whose lines repeat every 120 px: the layout moves it up by 120 px
                    and snaps back -> the floor runs towards the viewer forever
  fx_scan.png       1920x1080 faint scanlines + soft top light (a CRT sheen over everything)
  fx_sweep.png      1920x160 bright horizontal band for the game-launch sweep

  python tools/New-LayoutFx.py [--out layouts/ArcadeMaster/images]
"""
from __future__ import annotations

import argparse
import math
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

MAGENTA, CYAN, VIOLET = (255, 47, 160), (46, 200, 255), (123, 92, 255)


def stars(w=3840, h=1080, seed=7) -> Image.Image:
    rnd = random.Random(seed)
    im = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    glow = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    d, g = ImageDraw.Draw(im), ImageDraw.Draw(glow)
    half = w // 2
    pts = []
    for _ in range(520):
        x, y = rnd.uniform(0, half), rnd.uniform(0, h)
        r = rnd.choice([0.8, 0.8, 1.0, 1.2, 1.6, 2.2])
        col = rnd.choice([(255, 255, 255), (255, 255, 255), CYAN, (200, 180, 255), (255, 200, 230)])
        a = int(rnd.uniform(90, 255))
        pts.append((x, y, r, col, a))
    for x, y, r, col, a in pts:              # the left half repeats in the right half: sliding by `half` is seamless
        for ox in (0, half):
            d.ellipse((x + ox - r, y - r, x + ox + r, y + r), fill=col + (a,))
            if r >= 1.6:
                g.ellipse((x + ox - r * 4, y - r * 4, x + ox + r * 4, y + r * 4), fill=col + (int(a * .45),))
    glow = glow.filter(ImageFilter.GaussianBlur(4))
    return Image.alpha_composite(glow, im)


def grid(w=1920, h=600, step=120) -> Image.Image:
    """synthwave floor: horizon at the top, lines converge to the centre; horizontal lines repeat every `step` px
    in the image's own space so a `step` px upward slide loops cleanly"""
    S = 2
    im = Image.new('RGBA', (w * S, (h + step) * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    cx = w / 2
    hh = h + step
    for k in range(-24, 25):                    # rays from the vanishing point
        x0 = cx + k * 160
        d.line(((cx + k * 6) * S, 0, (cx + (x0 - cx) * 4) * S, hh * S), fill=VIOLET + (150,), width=2 * S)
    # horizontal lines: evenly spaced in "depth", drawn perspective-free but repeating every `step` px
    for y in range(0, hh + step, step // 4):
        frac = y / hh
        a = int(40 + 180 * frac)
        d.line((0, y * S, w * S, y * S), fill=MAGENTA + (a,), width=max(1, int(1 + 3 * frac)) * S)
    im = im.resize((w, hh), Image.LANCZOS)
    glow = im.filter(ImageFilter.GaussianBlur(6))
    out = Image.alpha_composite(glow, im)
    # fade into the horizon
    mask = Image.new('L', (w, hh), 0)
    md = ImageDraw.Draw(mask)
    for y in range(hh):
        md.line((0, y, w, y), fill=int(255 * min(1, (y / hh) ** 0.9 * 1.15)))
    out.putalpha(Image.composite(out.getchannel('A'), Image.new('L', (w, hh), 0), mask))
    return out


def scan(w=1920, h=1080) -> Image.Image:
    im = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    for y in range(0, h, 3):
        d.line((0, y, w, y), fill=(0, 0, 0, 38))
    top = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    td = ImageDraw.Draw(top)
    for y in range(0, 260):
        td.line((0, y, w, y), fill=(255, 255, 255, int(16 * (1 - y / 260) ** 2)))
    return Image.alpha_composite(im, top)


def sweep(w=1920, h=160) -> Image.Image:
    im = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    for y in range(h):
        t = 1 - abs(y - h / 2) / (h / 2)
        a = int(255 * t ** 3)
        col = tuple(int(255 * .55 + c * .45) for c in CYAN)
        d.line((0, y, w, y), fill=col + (a,))
    d.line((0, h // 2, w, h // 2), fill=(255, 255, 255, 255), width=3)
    return im


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', type=Path, default=Path(__file__).resolve().parent.parent / 'layouts' / 'ArcadeMaster' / 'images')
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    for name, fn in (('fx_stars.png', stars), ('fx_grid.png', grid), ('fx_scan.png', scan), ('fx_sweep.png', sweep)):
        im = fn()
        im.save(a.out / name, 'PNG', optimize=True)
        print(f'{name}: {im.size[0]}x{im.size[1]}, {(a.out / name).stat().st_size // 1024} KB')


if __name__ == '__main__':
    main()
