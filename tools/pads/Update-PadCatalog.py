#!/usr/bin/env python3
r"""
Update-PadCatalog.py - the list of hand-held controllers the cabinets can name: tools/pads/pads.json.

James, 2026-11-27: "add ps3 controller ps4 n64 and other controllers like the 8bit controllers that look like snes /
Genesis controllers". A controller is recognised by its USB id (VID:PID) or by a piece of the name Windows reports,
and sorted into a FAMILY: the shape and the button names it has (PlayStation, N64, SNES-style, Genesis-style ...).
The family is what the controls cards and the emulator set-up work from, so a new pad of a known shape needs no code.

The USB ids come from the public SDL controller list (github.com/mdqinc/SDL_GameControllerDB, the same list RetroArch,
Dolphin and Steam use). This script reads that list and writes pads.json again; the families and the name rules are
in this file. Run it when a pad is not recognised:

  python tools/pads/Update-PadCatalog.py                      # downloads the list
  python tools/pads/Update-PadCatalog.py --db gamecontrollerdb.txt

Only writes tools/pads/pads.json.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path

DB_URL = 'https://raw.githubusercontent.com/mdqinc/SDL_GameControllerDB/master/gamecontrollerdb.txt'
OUT = Path(__file__).with_name('pads.json')

# family -> what it is called, its shape, and its buttons in the words printed on the pad.
# "like": the console whose games it fits without thinking (used to offer it first for that system).
FAMILIES = {
    'ps3':     {'label': 'PlayStation 3 controller', 'like': ['ps3', 'psx', 'ps2'], 'sticks': 2,
                'buttons': ['Cross', 'Circle', 'Square', 'Triangle', 'L1', 'R1', 'L2', 'R2', 'Select', 'Start', 'L3', 'R3', 'PS']},
    'ps4':     {'label': 'PlayStation 4 controller', 'like': ['ps4', 'ps3', 'psx', 'ps2'], 'sticks': 2,
                'buttons': ['Cross', 'Circle', 'Square', 'Triangle', 'L1', 'R1', 'L2', 'R2', 'Share', 'Options', 'L3', 'R3', 'PS', 'Touchpad']},
    'ps5':     {'label': 'PlayStation 5 controller', 'like': ['ps4', 'ps3', 'psx', 'ps2'], 'sticks': 2,
                'buttons': ['Cross', 'Circle', 'Square', 'Triangle', 'L1', 'R1', 'L2', 'R2', 'Create', 'Options', 'L3', 'R3', 'PS', 'Touchpad', 'Mute']},
    'psx':     {'label': 'PlayStation controller', 'like': ['psx', 'ps2'], 'sticks': 2,
                'buttons': ['Cross', 'Circle', 'Square', 'Triangle', 'L1', 'R1', 'L2', 'R2', 'Select', 'Start', 'L3', 'R3']},
    'xbox':    {'label': 'Xbox controller', 'like': ['xbox', 'xbox360', 'pc'], 'sticks': 2,
                'buttons': ['A', 'B', 'X', 'Y', 'LB', 'RB', 'LT', 'RT', 'View', 'Menu', 'LS', 'RS', 'Xbox']},
    'n64':     {'label': 'Nintendo 64 controller', 'like': ['n64'], 'sticks': 1,
                'buttons': ['A', 'B', 'Z', 'L', 'R', 'Start', 'C-Up', 'C-Down', 'C-Left', 'C-Right']},
    'snes':    {'label': 'SNES-style controller', 'like': ['snes', 'sfc', 'gba', 'nes'], 'sticks': 0,
                'buttons': ['B', 'A', 'Y', 'X', 'L', 'R', 'Select', 'Start']},
    'snespro': {'label': 'SNES-style controller with sticks', 'like': ['snes', 'psx', 'gba', 'nes'], 'sticks': 2,
                'buttons': ['B', 'A', 'Y', 'X', 'L', 'R', 'L2', 'R2', 'Select', 'Start', 'L3', 'R3', 'Home']},
    'nes':     {'label': 'NES-style controller', 'like': ['nes', 'gb', 'gbc'], 'sticks': 0,
                'buttons': ['B', 'A', 'Select', 'Start']},
    'genesis': {'label': 'Genesis-style controller', 'like': ['megadrive', 'genesis', 'saturn', 'mastersystem'], 'sticks': 0,
                'buttons': ['A', 'B', 'C', 'X', 'Y', 'Z', 'L', 'R', 'Mode', 'Start']},
    'gamecube': {'label': 'GameCube controller', 'like': ['gamecube', 'wii'], 'sticks': 2,
                 'buttons': ['A', 'B', 'X', 'Y', 'Z', 'L', 'R', 'Start']},
    'switch':  {'label': 'Nintendo Switch controller', 'like': ['switch', 'wiiu', 'wii'], 'sticks': 2,
                'buttons': ['B', 'A', 'Y', 'X', 'L', 'R', 'ZL', 'ZR', 'Minus', 'Plus', 'LS', 'RS', 'Home', 'Capture']},
}

# How each family's buttons stand for the "retropad" the emulators think in (b = bottom, a = right, y = left, x = top
# of the four face buttons; tools/system_buttons.py turns retropad into each console's own names). With this a card
# can say "the console's A is your Circle".
RETROPAD = {
    'ps3':  {'b': 'Cross', 'a': 'Circle', 'y': 'Square', 'x': 'Triangle', 'l': 'L1', 'r': 'R1', 'l2': 'L2', 'r2': 'R2', 'select': 'Select', 'start': 'Start'},
    'psx':  {'b': 'Cross', 'a': 'Circle', 'y': 'Square', 'x': 'Triangle', 'l': 'L1', 'r': 'R1', 'l2': 'L2', 'r2': 'R2', 'select': 'Select', 'start': 'Start'},
    'ps4':  {'b': 'Cross', 'a': 'Circle', 'y': 'Square', 'x': 'Triangle', 'l': 'L1', 'r': 'R1', 'l2': 'L2', 'r2': 'R2', 'select': 'Share', 'start': 'Options'},
    'ps5':  {'b': 'Cross', 'a': 'Circle', 'y': 'Square', 'x': 'Triangle', 'l': 'L1', 'r': 'R1', 'l2': 'L2', 'r2': 'R2', 'select': 'Create', 'start': 'Options'},
    'xbox': {'b': 'A', 'a': 'B', 'y': 'X', 'x': 'Y', 'l': 'LB', 'r': 'RB', 'l2': 'LT', 'r2': 'RT', 'select': 'View', 'start': 'Menu'},
    'switch': {'b': 'B', 'a': 'A', 'y': 'Y', 'x': 'X', 'l': 'L', 'r': 'R', 'l2': 'ZL', 'r2': 'ZR', 'select': 'Minus', 'start': 'Plus'},
    'snes': {'b': 'B', 'a': 'A', 'y': 'Y', 'x': 'X', 'l': 'L', 'r': 'R', 'select': 'Select', 'start': 'Start'},
    'snespro': {'b': 'B', 'a': 'A', 'y': 'Y', 'x': 'X', 'l': 'L', 'r': 'R', 'l2': 'L2', 'r2': 'R2', 'select': 'Select', 'start': 'Start'},
    'nes':  {'b': 'B', 'a': 'A', 'select': 'Select', 'start': 'Start'},
    'genesis': {'y': 'A', 'b': 'B', 'a': 'C', 'l': 'X', 'x': 'Y', 'r': 'Z', 'l2': 'L', 'r2': 'R', 'select': 'Mode', 'start': 'Start'},
    'n64':  {'b': 'B', 'a': 'A', 'l': 'L', 'r': 'R', 'l2': 'Z', 'start': 'Start'},
    'gamecube': {'b': 'A', 'y': 'B', 'a': 'X', 'x': 'Y', 'r': 'Z', 'l2': 'L', 'r2': 'R', 'start': 'Start'},
}
for _f, _m in RETROPAD.items():
    FAMILIES[_f]['retropad'] = _m

# first rule that matches the list's name decides the family (order matters: "NES30 Pro" before "NES")
RULES = [
    (r'\bPS5\b|DualSense', 'ps5'),
    (r'\bPS4\b|DualShock ?4', 'ps4'),
    (r'\bPS3\b|DualShock ?3|Sixaxis', 'ps3'),
    (r'PlayStation (Classic|Adapter|Controller)|DualShock|\bPS2\b|\bPSX\b', 'psx'),
    (r'\bN64\b|Nintendo 64', 'n64'),
    (r'GameCube|\bGC\b(?! and)', 'gamecube'),
    (r'Switch|Joy-?Con', 'switch'),
    (r'8BitDo.*(Pro|Ultimate|Lite)|NES30 Pro|SN30 ?Pro|SF30 ?Pro|N30 ?Pro', 'snespro'),
    (r'\bM30\b|Genesis|Mega ?Drive|Saturn|Sega (Multi|MD)|6B Controller|3B Controller', 'genesis'),
    (r'SNES|SFC|SN30|SF30|Super (Famicom|Nintendo)', 'snes'),
    (r'\bNES\b|NES30|\bN30\b|Famicom|8BitDo Zero', 'nes'),
    (r'Xbox|XInput', 'xbox'),
]

# names Windows reports that the list does not carry word for word (checked against the cabinets' own pads)
NAME_MATCH = [
    {'match': ['8BitDo M30', 'M30 gamepad'], 'family': 'genesis'},
    {'match': ['8BitDo SN30 Pro', '8BitDo SF30 Pro', '8BitDo Pro 2', '8BitDo Pro 3', '8BitDo Ultimate'], 'family': 'snespro'},
    {'match': ['8BitDo SN30', '8BitDo SF30', '8BitDo SNES30', '8BitDo SFC30'], 'family': 'snes'},
    {'match': ['8BitDo N30', '8BitDo NES30'], 'family': 'nes'},
    {'match': ['8BitDo 64', 'N64 Controller', 'Nintendo 64'], 'family': 'n64'},
    {'match': ['DUALSHOCK 4', 'Wireless Controller'], 'family': 'ps4', 'note': 'Windows calls a PS4 pad just "Wireless Controller"'},
    {'match': ['DualSense'], 'family': 'ps5'},
    {'match': ['PLAYSTATION(R)3', 'DS3', 'Sixaxis'], 'family': 'ps3'},
    {'match': ['Retro-Bit', 'Retrobit'], 'family': 'genesis', 'note': 'most Retro-Bit USB pads on the cabinets are the Sega ones; the USB id decides when it is known'},
]


def family_of(name: str) -> str | None:
    for rx, fam in RULES:
        if re.search(rx, name, re.I):
            return fam
    return None


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--db', type=Path, help='a copy of gamecontrollerdb.txt (default: download it)')
    a = ap.parse_args(argv)
    if a.db:
        text = a.db.read_text(encoding='utf-8', errors='replace')
    else:
        with urllib.request.urlopen(DB_URL, timeout=30) as r:      # a public list; nothing about the cabinet is sent
            text = r.read().decode('utf-8', errors='replace')
    pads: dict[str, dict] = {}
    for ln in text.splitlines():
        m = re.match(r'^([0-9a-fA-F]{32}),([^,]+),', ln)
        if not m:
            continue
        g, name = m.group(1).lower(), m.group(2).strip()
        vid = (g[10:12] + g[8:10]).upper()
        pid = (g[18:20] + g[16:18]).upper()
        if vid == '0000' or vid == pid == 'FFFF':
            continue                                    # Bluetooth-name entries: no USB id in them
        fam = family_of(name)
        if not fam:
            continue
        usb = f'{vid}:{pid}'
        cur = pads.get(usb)
        if cur is None:
            pads[usb] = {'usb': usb, 'model': name, 'family': fam}
        elif cur['family'] != fam and len(name) > len(cur['model']):
            cur.update(model=name, family=fam)          # the longer name says more about the pad
    out = {
        '_help': 'Hand-held controllers the cabinets can name. Written by tools/pads/Update-PadCatalog.py from the public '
                 'SDL controller list - do not edit by hand, change the rules in that script. A pad is found by USB id '
                 '(pads), else by a piece of the name Windows reports (names; the longest match wins). family: the shape '
                 'and button names (families). A pad switched to "X-input" mode shows up as an Xbox 360 controller: '
                 'Windows cannot tell it apart, so 8BitDo pads are best left in D-input mode (hold START + B to turn on).',
        'families': FAMILIES,
        'names': NAME_MATCH,
        'pads': sorted(pads.values(), key=lambda p: p['usb']),
    }
    OUT.write_text(json.dumps(out, indent=1) + '\n', encoding='utf-8')
    by = {}
    for p in pads.values():
        by[p['family']] = by.get(p['family'], 0) + 1
    print(f'pad catalog: {len(pads)} controllers in {len(by)} families -> {OUT}')
    print('  ' + ', '.join(f'{k} {v}' for k, v in sorted(by.items())))
    return 0


if __name__ == '__main__':
    sys.exit(main())
