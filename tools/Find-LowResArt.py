#!/usr/bin/env python3
"""
Find-LowResArt.py - game art too small (or the wrong shape) to fill a 1920x1080 background.

Writes <manifest>/lowres-art.txt: one full path per line, for every fanart / am_backdrop picture narrower than
--min-width (default 1024) or taller than it is wide (a portrait flyer stretched over a TV). Set-LayoutThemes.ps1 leaves
these out of a menu's background pool whenever the menu has enough other pictures.

Only the image header is read (PIL opens lazily), so ~2,000 pictures take a few seconds. Run by Rebuild Game Menus.

  python tools/Find-LowResArt.py --retrofe R:\\ArcadeMaster\\frontend\\LEGENDS-am --manifest R:\\ArcadeMaster\\manifest
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from PIL import Image

KINDS = ('fanart', 'am_backdrop')
EXTS = ('.png', '.jpg', '.jpeg')


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--retrofe', required=True, type=Path)
    ap.add_argument('--manifest', required=True, type=Path)
    ap.add_argument('--min-width', type=int, default=1024)
    a = ap.parse_args(argv)
    cols = a.retrofe / 'collections'
    if not cols.is_dir():
        print(f'no collections folder under {a.retrofe}')
        return 1
    low, total = [], 0
    for c in sorted(os.listdir(cols)):
        for k in KINDS:
            d = cols / c / 'medium_artwork' / k
            if not d.is_dir():
                continue
            for f in os.listdir(d):
                if not f.lower().endswith(EXTS):
                    continue
                p = d / f
                total += 1
                try:
                    with Image.open(p) as im:
                        w, h = im.size
                except Exception:          # unreadable: never show it either
                    low.append(str(p))
                    continue
                if w < a.min_width or h > w:
                    low.append(str(p))
    a.manifest.mkdir(parents=True, exist_ok=True)
    out = a.manifest / 'lowres-art.txt'
    out.write_text('\n'.join(sorted(low)) + ('\n' if low else ''), encoding='utf-8')
    print(f'low-resolution or portrait art: {len(low)} of {total} pictures -> {out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
