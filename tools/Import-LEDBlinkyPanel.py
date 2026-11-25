#!/usr/bin/env python3
"""
Import-LEDBlinkyPanel.py - learn a cabinet's control panel from its LEDBlinky setup.

Any cabinet whose buttons are lit by LEDBlinky already describes its panel in two files:
  LEDBlinkyInputMap.xml   every LED port: the button's label (P1B1, P2START, P1B1JOY, LEFTMOUSE, LFLIPPER ...) and the
                          key / mouse button it sends (inputCodes)
  <layout>.lay            [Layout] label=x,y,... : where each button sits on the panel (LEDBlinky Animation Editor)
From them this writes <manifest>/panel.json - the file New-PanelControlsArt.py draws the button cards from:
  players[]      per position: buttons, rows x cols (from the real positions), start / coin, every button's key + x/y
  flightStick    the buttons next to the analog sticks (PnB1JOY ...)
  trackball      the rollerball and its buttons (P1TRACKBALL + LEFTMOUSE / RIGHTMOUSE / MIDDLEMOUSE)
  spinner        the dial and its buttons when the map names them (SPINNER / DIAL / P1DIAL ...)
  pinball        flippers, tilt, nudge, launch
  admin          pause / exit / service / test / setup / paging buttons
  clashes        two buttons that send the same key (e.g. P1B4 and LFLIPPER both on Left Shift)
Hand-made entries (twinStick, names) in an existing panel.json are kept; "learned" ones are replaced.

  python tools/Import-LEDBlinkyPanel.py --retrofe <RetroFE root> --manifest <manifest> [--ledblinky <folder>]
         [--dry-run] [--picture panel.png]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ADMIN = {'PAUSE', 'EXIT', 'SERVICE', 'TEST', 'SETUP', 'PAGEUP', 'PAGEDOWN', 'LED', 'MENU', 'ESC', 'ENTER'}


def read_conf(p: Path) -> dict:
    out = {}
    if p.exists():
        for line in p.read_text(encoding='utf-8', errors='replace').splitlines():
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                k, v = line.split('=', 1)
                out[k.strip().lower()] = v.strip()
    return out


def find_ledblinky(root: Path, given: str | None) -> Path | None:
    cands = []
    if given:
        cands.append(Path(given))
    lb = read_conf(root / 'settings.conf').get('ledblinkydirectory')
    if lb:
        cands.append(Path(lb) if Path(lb).is_absolute() else root / lb)
    cands.append(root / 'LEDBlinky')
    for c in cands:
        if (c / 'LEDBlinkyInputMap.xml').exists():
            return c
    return None


def key_name(codes: str) -> str:
    """'KEYCODE_LCONTROL|KEYCODE_CONTROL' -> 'LCONTROL'; 'MOUSECODE_1_BUTTON1' -> 'MOUSE1'"""
    first = (codes or '').split('|')[0].strip()
    m = re.match(r'MOUSECODE_\d+_BUTTON(\d+)', first)
    if m:
        return f'MOUSE{m.group(1)}'
    return first.replace('KEYCODE_', '').replace('JOYCODE_', 'JOY ')


def read_inputs(lb: Path) -> dict:
    """label -> key (one entry per button; each RGB button has three ports with the same label)"""
    keys = {}
    for p in ET.parse(lb / 'LEDBlinkyInputMap.xml').iter('port'):
        lab = (p.get('label') or '').strip().upper()
        if lab and lab not in keys:
            keys[lab] = key_name(p.get('inputCodes') or '')
    return keys


def read_layout(lb: Path) -> tuple[dict, Path | None]:
    s = lb / 'Settings.ini'
    lay = None
    if s.exists():
        for line in s.read_text(encoding='latin-1').splitlines():
            m = re.match(r'^\s*\w*Layout\w*\s*=\s*(.+\.lay)\s*$', line, re.I)
            if m and (lb / Path(m.group(1)).name).exists():
                lay = lb / Path(m.group(1)).name
                break
    if lay is None:
        lay = lb / 'DefaultLayout.lay' if (lb / 'DefaultLayout.lay').exists() else next(iter(sorted(lb.glob('*.lay'))), None)
    pos = {}
    if lay:
        txt = lay.read_text(encoding='latin-1')
        body = txt.split('[Layout]', 1)[1] if '[Layout]' in txt else ''
        for line in body.splitlines():
            m = re.match(r'^\s*([^=;\[]+?)\s*=\s*(-?\d+)\s*,\s*(-?\d+)', line)
            if m:
                pos[m.group(1).upper()] = (int(m.group(2)), int(m.group(3)))
    return pos, lay


def grid_of(points: list[tuple[int, int]]) -> tuple[int, int]:
    """rows x cols from button positions (rows = distinct y within a tolerance)"""
    if not points:
        return 0, 0
    ys = sorted(y for _, y in points)
    rows = [[ys[0]]]
    for y in ys[1:]:
        if y - rows[-1][-1] > 12:
            rows.append([y])
        else:
            rows[-1].append(y)
    return len(rows), max(len(r) for r in rows)


def learn(keys: dict, pos: dict) -> dict:
    labels = set(keys) | set(pos)
    players = []
    for n in range(1, 9):
        btn = sorted((l for l in labels if re.fullmatch(fr'P{n}B\d+', l)), key=lambda l: int(l[len(f'P{n}B'):]))
        if not btn and f'P{n}START' not in labels:
            continue
        pts = [pos[b] for b in btn if b in pos]
        rows, cols = grid_of(pts)
        if rows * cols < len(btn):      # positions missing: assume 2 rows
            rows, cols = (2, (len(btn) + 1) // 2) if len(btn) > 3 else (1, len(btn))
        players.append({
            'position': f'P{n}', 'buttons': len(btn), 'rows': rows, 'cols': cols,
            'start': f'P{n}START' in labels, 'coin': f'P{n}COIN' in labels,
            'keys': {b: keys.get(b, '') for b in btn} | {k: keys.get(k, '') for k in (f'P{n}START', f'P{n}COIN') if k in labels},
            'pos': {b: pos[b] for b in btn if b in pos},
        })
    fs = sorted(l for l in labels if re.fullmatch(r'P\dB\d+JOY', l))
    flight = None
    if fs:
        per = {}
        for l in fs:
            per.setdefault(l[:2], []).append(l)
        flight = {'name': 'Flight stick', 'buttons': max(len(v) for v in per.values()), 'count': len(per),
                  'players': sorted(per), 'keys': {l: keys.get(l, '') for l in fs}}
    tb = None
    if any('TRACKBALL' in l for l in labels):
        tbb = [l for l in ('LEFTMOUSE', 'RIGHTMOUSE', 'MIDDLEMOUSE') if l in labels]
        tb = {'name': 'Rollerball', 'buttons': len(tbb), 'keys': {l: keys.get(l, '') for l in tbb}}
    dial_lab = [l for l in labels if re.search(r'SPINNER|DIAL', l)]
    spinner = None
    if dial_lab:
        db = [l for l in dial_lab if re.search(r'B\d|BUTTON', l)]
        spinner = {'name': 'Dial', 'buttons': len(db), 'keys': {l: keys.get(l, '') for l in db}}
    pin = {l: keys.get(l, '') for l in sorted(labels) if re.search(r'FLIPPER|TILT|NUDGE|LAUNCH|PLUNGER', l)}
    admin = {l: keys.get(l, '') for l in sorted(labels) if l in ADMIN}
    # two different buttons sending the same key
    by_key = {}
    for l, k in keys.items():
        if k and not k.startswith('MOUSE') and k != 'TRACKBALL':
            by_key.setdefault(k, []).append(l)
    clashes = [{'key': k, 'buttons': sorted(v)} for k, v in sorted(by_key.items()) if len(v) > 1]
    return {'players': players, 'flightStick': flight, 'trackball': tb, 'spinner': spinner,
            'pinball': pin or None, 'admin': admin or None, 'clashes': clashes}


def picture(learned: dict, pos: dict, keys: dict, out: Path):
    from PIL import Image, ImageDraw, ImageFont
    S = 2.2
    W = int(max(x for x, _ in pos.values()) * S + 160)
    H = int(max(y for _, y in pos.values()) * S + 90)
    im = Image.new('RGB', (W, H), (18, 20, 28))
    d = ImageDraw.Draw(im)
    fonts = Path(r'C:\Windows\Fonts')
    f = ImageFont.truetype(str(fonts / 'segoeuib.ttf'), 15)
    f2 = ImageFont.truetype(str(fonts / 'segoeui.ttf'), 13)
    col = {'P1': (255, 59, 59), 'P2': (46, 139, 255), 'P3': (61, 220, 132), 'P4': (255, 204, 0)}
    clash = {b for c in learned['clashes'] for b in c['buttons']}
    for lab, (x, y) in pos.items():
        cx, cy = x * S + 40, y * S + 30
        c = col.get(lab[:2], (200, 200, 210))
        d.ellipse((cx - 20, cy - 20, cx + 20, cy + 20), fill=c, outline=(255, 90, 90) if lab in clash else None,
                  width=4)
        d.text((cx, cy - 30), lab, font=f, fill=(235, 235, 240), anchor='mm')
        d.text((cx, cy + 32), keys.get(lab, ''), font=f2, fill=(255, 120, 120) if lab in clash else (160, 170, 185),
               anchor='mm')
    out.parent.mkdir(parents=True, exist_ok=True)
    im.save(out)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--retrofe', required=True, type=Path)
    ap.add_argument('--manifest', required=True, type=Path)
    ap.add_argument('--ledblinky')
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--picture', type=Path, help='also draw the learned panel (default <manifest>/panel-ledblinky.png)')
    a = ap.parse_args(argv)
    lb = find_ledblinky(a.retrofe, a.ledblinky)
    if not lb:
        print('no LEDBlinky input map found - panel not learned (panel.json left as it is)')
        return 0
    keys = read_inputs(lb)
    pos, lay = read_layout(lb)
    learned = learn(keys, pos)
    # What LEDBlinky drives on this cabinet: lit BUTTONS (LED boards whose ports name player buttons) and / or an RGB
    # MARQUEE (Pixelcade, Settings.ini UsePixelcade=1). Only the buttons describe the control panel.
    drives = []
    if any(p['buttons'] for p in learned['players']):
        drives.append('buttons')
    st = (lb / 'Settings.ini').read_text(encoding='latin-1') if (lb / 'Settings.ini').exists() else ''
    if re.search(r'^\s*UsePixelcade\s*=\s*1', st, re.M | re.I):
        drives.append('marquee')
    boards = sorted({(c.get('name') or c.get('type') or '?') for c in ET.parse(lb / 'LEDBlinkyInputMap.xml').iter('ledController')})
    print(f"LEDBlinky drives: {' + '.join(drives) or 'nothing it can describe'} (LED boards: {', '.join(boards) or 'none'})")
    if 'buttons' not in drives:
        print('  its map names no player buttons, so it says nothing about the control panel - panel.json left as it '
              'is. Learn the buttons another way: the I-PAC / Ultimarc board config, or press each button once '
              '(button capture).')
        return 0
    learned['_drives'] = drives
    pf = a.manifest / 'panel.json'
    cur = {}
    if pf.exists():
        try:
            cur = json.loads(pf.read_text(encoding='utf-8-sig'))
        except ValueError:
            cur = {}
    drives = learned.pop('_drives', [])
    out = {k: v for k, v in cur.items() if k not in learned and k != '_learned'}   # keep hand-made keys (twinStick ...)
    for k, v in learned.items():
        if v is None:
            continue
        if isinstance(v, dict) and isinstance(cur.get(k), dict) and 'name' in cur[k]:
            v = {**v, 'name': cur[k]['name']}         # a name James gave wins over the default
        out[k] = v
    out['_learned'] = {'from': str(lb), 'drives': drives, 'inputMap': 'LEDBlinkyInputMap.xml', 'layout': str(lay) if lay else None,
                       'note': 'written by tools/Import-LEDBlinkyPanel.py; keys other than these are kept on re-runs'}
    ps = learned['players']
    print(f'LEDBlinky: {lb}')
    print('players: ' + ', '.join(f"{p['position']} {p['buttons']} buttons ({p['rows']}x{p['cols']})" for p in ps))
    if learned['flightStick']:
        f = learned['flightStick']
        print(f"flight sticks: {f['count']} x {f['buttons']} buttons ({', '.join(f['players'])})")
    if learned['trackball']:
        print(f"rollerball: {learned['trackball']['buttons']} buttons")
    print(f"dial: {learned['spinner']['buttons']} buttons" if learned['spinner'] else 'dial: not in the LEDBlinky map')
    if learned['pinball']:
        print('pinball: ' + ', '.join(learned['pinball']))
    for c in learned['clashes']:
        print(f"CLASH: {' and '.join(c['buttons'])} both send {c['key']}")
    if a.dry_run:
        return 0
    a.manifest.mkdir(parents=True, exist_ok=True)
    pf.write_text(json.dumps(out, indent=1), encoding='utf-8')
    print(f'panel -> {pf}')
    if pos:
        pic = a.picture or (a.manifest / 'panel-ledblinky.png')
        try:
            picture(learned, pos, keys, pic)
            print(f'picture -> {pic}')
        except Exception as ex:  # Pillow missing / fonts: the panel file is what matters
            print(f'picture skipped: {ex}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
