"""Import-GHubMappings.py - reads Logitech G HUB's key mappings for wheels into <manifest>\\padkeys.json, so AmPanel
(src/panel/PadKeys.cs) can type the same keys once G HUB's app is gone.

G HUB keeps its settings in %LOCALAPPDATA%\\LGHUB\\settings.db (SQLite, one JSON document in table "data"). A copy of
the database (with its -wal / -shm) is read, never the live file. Assignments come from the desktop (default)
profile: slot "g29_g24_m1" = device g29, G-key 24 (= DirectInput button 23), mode 1, not the shifted layer.
The key is either a built-in card whose id ends in 01XX00000000 (XX = the USB keyboard usage, 28 = Enter, 29 = Escape)
or a user keystroke card (macro.keystroke.code = the same usage). Cards ...0908... / ...0907... mean "the button's
own behaviour" and are skipped.

  python -I tools\\Import-GHubMappings.py --manifest D:\\ArcadeMaster\\manifest            # writes padkeys.json
  python -I tools\\Import-GHubMappings.py --manifest D:\\ArcadeMaster\\manifest --show     # prints, writes nothing
"""
import argparse, json, os, shutil, sqlite3, sys, tempfile

DEVICES = {                       # G HUB device prefix -> (vid, pid, name)
    'g29': ('046D', 'C24F', 'G29'),
    'g920': ('046D', 'C262', 'G920'),
    'g923': ('046D', 'C266', 'G923'),
}
USAGE = {40: 'ENTER', 41: 'ESC', 42: 'BACKSPACE', 43: 'TAB', 44: 'SPACE', 79: 'RIGHT', 80: 'LEFT', 81: 'DOWN', 82: 'UP',
         224: 'LCONTROL', 225: 'LSHIFT', 226: 'LALT', 228: 'RCONTROL', 229: 'RSHIFT', 230: 'RALT'}
USAGE.update({4 + i: chr(65 + i) for i in range(26)})                  # A-Z
USAGE.update({30 + i: str((i + 1) % 10) for i in range(10)})           # 1-9, 0
USAGE.update({58 + i: 'F%d' % (i + 1) for i in range(12)})             # F1-F12


def read_settings(path):
    tmp = tempfile.mkdtemp(prefix='ghub-')
    try:
        for ext in ('', '-wal', '-shm'):
            if os.path.exists(path + ext):
                shutil.copy2(path + ext, os.path.join(tmp, 'settings.db' + ext))
        con = sqlite3.connect(os.path.join(tmp, 'settings.db'))
        row = con.execute('select file from data order by _id desc limit 1').fetchone()
        con.close()
        blob = row[0]
        return json.loads(blob if isinstance(blob, str) else blob.decode('utf-8'))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def key_of(card_id, cards):
    c = cards.get(card_id)
    if c:
        ks = (c.get('macro') or {}).get('keystroke')
        if ks and not ks.get('modifiers'):
            return USAGE.get(ks.get('code'))
        return None
    tail = card_id.rsplit('-', 1)[-1]                                   # e.g. 012800000000
    if len(tail) == 12 and tail.startswith('01') and tail.endswith('00000000'):
        return USAGE.get(int(tail[2:4], 16))
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--manifest', required=True)
    ap.add_argument('--db', default=os.path.join(os.environ.get('LOCALAPPDATA', ''), 'LGHUB', 'settings.db'))
    ap.add_argument('--show', action='store_true')
    a = ap.parse_args()
    if not os.path.exists(a.db):
        print('G HUB settings not found (%s): nothing imported' % a.db)
        return 0
    s = read_settings(a.db)
    cards = {c['id']: c for c in (s.get('cards') or {}).get('cards', [])}
    apps = {x.get('applicationId'): x.get('name') for x in (s.get('applications') or {}).get('applications', [])}
    out, skipped = {}, []
    for p in (s.get('profiles') or {}).get('profiles', []):
        if apps.get(p.get('applicationId')) != 'APPLICATION_NAME_DESKTOP':
            continue                                                    # per-game profiles: not imported
        for asg in p.get('assignments', []):
            slot, card = asg.get('slotId', ''), asg.get('cardId', '')
            parts = slot.split('_')
            if len(parts) != 3 or not parts[1].startswith('g') or parts[2] != 'm1' or parts[0] not in DEVICES:
                continue                                                # shifted layer, settings cards, other devices
            if card.endswith(('090800000000', '090700000000')):
                continue                                                # the button's own behaviour
            key = key_of(card, cards)
            if not key:
                skipped.append('%s -> %s' % (slot, card)); continue
            dev = out.setdefault(parts[0], {'vid': DEVICES[parts[0]][0], 'pid': DEVICES[parts[0]][1], 'name': DEVICES[parts[0]][2], 'keys': []})
            dev['keys'].append({'button': int(parts[1][1:]) - 1, 'key': key, 'ghub': parts[1].upper()})
    doc = {'source': 'G HUB settings.db, desktop profile (tools/Import-GHubMappings.py)', 'devices': list(out.values())}
    for d in doc['devices']:
        d['keys'].sort(key=lambda k: k['button'])
        print('%s: %s' % (d['name'], ', '.join('button %d (%s) = %s' % (k['button'], k['ghub'], k['key']) for k in d['keys'])))
    for x in skipped:
        print('not imported (not a single key): ' + x)
    if not doc['devices']:
        print('no key mappings in G HUB: nothing written')
        return 0
    if a.show:
        return 0
    dst = os.path.join(a.manifest, 'padkeys.json')
    with open(dst, 'w', encoding='utf-8') as f:
        json.dump(doc, f, indent=1)
    print('written ' + dst + ' (AmPanel reads it at its next start)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
