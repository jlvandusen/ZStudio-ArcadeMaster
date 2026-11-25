"""New-GameStories.py - a short "background story" text for every game in a RetroFE frontend.

Writes collections/<collection>/medium_artwork/am_story/<item>.txt (UTF-8, no BOM, plain ASCII text) for the
cabinet's scrolling story box:

    <Title> (<Year>, <Manufacturer>)

    One paragraph: what the game is and how it plays.

    WHAT MADE IT SPECIAL
    - 2-5 short facts from the source's trivia (firsts, records, sequels, ports, hidden features)

Sources, first hit wins per game (trivia is merged where a later source adds it):
  1. MAME history.dat (legacy "$info=...$bio...$end" or the newer XML), parsed once into
     <manifest>/history-index.json keyed by the dat's size + mtime.
  2. Text already in the build: medium_artwork/story, medium_artwork/archives/story, and bio/description folders.
  3. <manifest>/games.json (title, year, platform, genre; matched by sources[].collection+item or variants).
  4. meta.db (table Meta): the title line, and a one-paragraph fallback built only from its facts.

Games are listed exactly as tools/New-PanelControlsArt.py lists them (Frontend.items). A game collection that merges
other collections in through <Other>.sub files shows those games with its own art folder first, so the story is
also placed in the parent's am_story folder (an NTFS hard link to the source collection's file, else a copy).

Safety: writes only under <retrofe>/collections/<c>/medium_artwork/am_story/, refuses any target whose real path is
outside the frontend root, on E:, or inside a roms/video folder.

Stdlib only.  Usage:
  python New-GameStories.py [--retrofe DIR] [--manifest DIR] [--collections a,b] [--dry-run] [--force]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
import time
import unicodedata
import xml.etree.ElementTree as ET
from pathlib import Path

DEFAULT_RETROFE = Path(r'R:\ArcadeMaster\frontend\LEGENDS-am')
DEFAULT_MANIFEST = Path(r'R:\ArcadeMaster\manifest')
INDEX_VERSION = 4
OUT_DIR = 'am_story'
MAX_LEN = 1500
PARA_MAX = 650
BULLET_MAX = 260

# RetroFE collection -> history.dat software lists (console entries are "$snes=aladdin," etc.)
SOFTLISTS = {
    'super nintendo': ['snes'], 'snes': ['snes'],
    'genesis': ['megadriv', 'segacd', 'megacd'], 'mega drive': ['megadriv'],
    'nintendo 64': ['n64'], 'playstation 1': ['psx'], 'playstation': ['psx'],
    'dreamcast': ['dc'], 'amiga cd32': ['cd32'], 'amiga': ['amigaocs_flop', 'amigaaga_flop'],
    'commodore 64': ['c64_cart', 'c64_flop', 'c64_cass'], 'game boy advance': ['gba'],
    'nes': ['nes'], 'game boy': ['gameboy'], 'game boy color': ['gbcolor'], 'master system': ['sms'],
    'game gear': ['gamegear'], 'pc engine': ['pce'], 'turbografx-16': ['tg16'], 'atari 2600': ['a2600'],
    'neo geo cd': ['neocd'], 'atari jaguar': ['jaguar'], 'atari lynx': ['lynx'],
}
# collections whose games are arcade machines: an exact title match against MAME's arcade entries is allowed
ARCADE_LIKE = {'teknoparrot', 'naomi', 'laser disc', 'pc gamer', 'atomiswave'}
PLATFORM = {
    'arcades': 'arcade', 'arcadesmini': 'arcade', 'fight': 'arcade', 'naomi': 'Sega NAOMI / Atomiswave arcade',
    'teknoparrot': 'arcade', 'laser disc': 'laserdisc arcade', 'pc gamer': 'PC', 'doom ii': 'PC',
    'pinball fx3': 'PC', 'zzzshutdown': '',
}


# ------------------------------------------------------------------ text helpers
ASCII_MAP = {
    '\u2018': "'", '\u2019': "'", '\u201a': "'", '\u201b': "'", '\u2032': "'", '\u00b4': "'", '`': "'",
    '\u201c': '"', '\u201d': '"', '\u201e': '"', '\u2033': '"', '\u00ab': '"', '\u00bb': '"',
    '\u2013': '-', '\u2014': '-', '\u2015': '-', '\u2212': '-', '\u2010': '-', '\u2011': '-',
    '\u2026': '...', '\u00a0': ' ', '\u2022': '-', '\u00b7': '-', '\u00d7': 'x', '\u00ae': '(R)',
    '\u2122': '(TM)', '\u00a9': '(c)', '\u00b0': ' degrees', '\u00bd': '1/2', '\u00bc': '1/4', '\u00be': '3/4',
    '\u00df': 'ss', '\u00e6': 'ae', '\u00c6': 'AE', '\u00f8': 'o', '\u00d8': 'O', '\u0153': 'oe',
    '\uff06': '&', '\u3000': ' ', '\u2192': '->', '\u2190': '<-',
}


def to_ascii(s: str) -> str:
    # UTF-8 that was read as Latin-1 / cp1252 somewhere upstream ("PokkÃ©n" -> "Pokkén"), before transliterating
    if re.search('[ÂÃ][\u0080-¿]', s):
        for enc in ('cp1252', 'latin-1'):
            try:
                s = s.encode(enc).decode('utf-8')
                break
            except (UnicodeEncodeError, UnicodeDecodeError):
                continue
    s = ''.join(ASCII_MAP.get(ch, ch) for ch in s)
    s = unicodedata.normalize('NFKD', s).encode('ascii', 'ignore').decode('ascii')
    s = re.sub(r'\(\s*\)|\[\s*\]', '', s)
    return s


def squash(s: str) -> str:
    return re.sub(r'\s+', ' ', s).strip()


def ascii_ratio(s: str) -> float:
    s = s.strip()
    return sum(1 for ch in s if ord(ch) < 128) / len(s) if s else 0.0


SENT_SPLIT = re.compile(r'(?<=[.!?])["\')]?\s+(?=[A-Z0-9"\'(])')
ABBREV_END = re.compile(r'(\b(?:Co|Mfg|Inc|Ltd|Corp|vs|Vol|No|Mr|Mrs|Ms|Dr|St|Jr|Sr|Prof|Bros|Lt|Sgt|Capt|Gen|Mt|'
                        r'approx|ca|U\.S|e\.g|i\.e|[A-Z])\.)$')


def sentences(text: str) -> list[str]:
    parts = SENT_SPLIT.split(squash(text))
    out: list[str] = []
    for p in parts:
        if out and ABBREV_END.search(out[-1]):
            out[-1] += ' ' + p
        else:
            out.append(p)
    return [p.strip() for p in out if p.strip()]


def clip_sentences(text: str, limit: int, min_one=True) -> str:
    out = ''
    for s in sentences(text):
        cand = (out + ' ' + s).strip()
        if len(cand) > limit:
            if not out and min_one and len(s) <= limit * 1.3:
                return s
            break
        out = cand
    return out


def norm(s: str) -> str:
    s = re.sub(r'\[.*?\]|\(.*?\)', '', str(s).lower())
    s = re.sub(r'^the\s+|,\s*the\b', '', s.strip())
    s = s.replace('&', 'and')
    return re.sub(r'[^a-z0-9]', '', s)


def norm_base(s: str) -> str:
    return norm(re.split(r'\s+-\s+|:\s', re.sub(r'\[.*?\]|\(.*?\)', '', str(s)))[0])


# ------------------------------------------------------------------ history.dat
CLASS_LINE = re.compile(r'^an?\s+[\w\-]+[- ]year[- ]old\b|^an?\s+.*\b(game|cart|cartridge|software|disk|tape|'
                        r'machine|computer|console|system)\s*\.?$', re.I)
TITLE_LINE = re.compile(r'^(?P<t>.*?)\s*\(c\)\s*(?P<y>(?:\d{4}|\d{2,3}[?x]+|\?{4}))?\s*(?P<m>.*?)\s*\.?\s*$', re.I)
SECTION = re.compile(r'^-\s*([A-Z][A-Z &/]+?)\s*-\s*$')
STUB_SENT = re.compile(r'please see|for more information|re-release/updated hardware|this entry|'
                       r'^(?:re-?release|updated hardware|bootleg|hack)\b[^.]*\.$', re.I)
REF = re.compile(r'please see (?:the )?.*?entry[,;:]?\s*"([^"]+)"', re.I)


def parse_bio(text: str) -> dict:
    """one history.dat text body -> processed fields (title, year, maker, desc, trivia, series, ports, ref)"""
    lines = [ln.rstrip() for ln in text.replace('\r', '').split('\n')]
    i, n = 0, len(lines)
    while i < n and not lines[i].strip():
        i += 1
    if i < n and CLASS_LINE.search(lines[i].strip()):
        i += 1
    while i < n and not lines[i].strip():
        i += 1
    title = year = maker = ''
    alt = ''
    if i < n and '(c)' in lines[i].lower():
        m = TITLE_LINE.match(lines[i].strip())
        if m:
            title, year, maker = m.group('t').strip(), (m.group('y') or '').strip(), m.group('m').strip()
        i += 1
        if i < n and re.match(r'^\(.+\)$', lines[i].strip()):
            alt = lines[i].strip()[1:-1]
            i += 1
    # sections
    sections: dict[str, list[str]] = {'': []}
    cur = ''
    for ln in lines[i:]:
        m = SECTION.match(ln.strip())
        if m:
            cur = m.group(1).strip().upper()
            sections.setdefault(cur, [])
            continue
        sections.setdefault(cur, []).append(ln)

    def paras(name):
        out, buf = [], []
        for ln in sections.get(name, []) + ['']:
            if ln.strip():
                buf.append(ln.strip())
            elif buf:
                out.append('\n'.join(buf))
                buf = []
        return out

    desc_paras = paras('')
    ref = ''
    desc = []
    for p in desc_paras:
        m = REF.search(squash(p))
        if m and not ref:
            ref = m.group(1)
        if re.match(r'^(here is a |a )?(list|summary) of (the )?(changes|differences)|^(changes|differences) '
                    r'(from|with|compared)', p.strip(), re.I):
            continue
        body = []
        for ln in p.split('\n'):
            s = ln.strip()
            if re.match(r'^([\*\-=>#]|\d+[.)]\s)', s):
                break                                   # a list starts: the paragraph's prose ends here
            if len(s) < 45 and s.upper() == s and re.search(r'[A-Z]', s):
                continue                                # an ALL-CAPS heading line from a flyer
            body.append(s)
        p = ' '.join(body)
        keep = [s for s in sentences(p) if not STUB_SENT.search(s)]
        while keep and keep[-1].rstrip().endswith(':'):
            keep.pop()
        if keep:
            desc.append(' '.join(keep))
    if ascii_ratio(title) < 0.6 and alt:
        title = alt
    maker = re.sub(r'\s*\[.*$', '', maker)
    return {
        'title': to_ascii(title).strip(), 'year': year, 'maker': to_ascii(maker).strip(' .,'),
        'desc': [to_ascii(squash(p)) for p in desc if ascii_ratio(p) > 0.8],
        'trivia': [to_ascii(p) for p in paras('TRIVIA') if ascii_ratio(p) > 0.8],
        'series': [to_ascii(squash(ln)) for ln in sections.get('SERIES', []) if ln.strip()],
        'ports': [to_ascii(squash(ln)) for ln in sections.get('PORTS', []) if ln.strip()],
        'ref': to_ascii(ref),
    }


def parse_history_legacy(path: Path) -> tuple[list, dict]:
    entries, keys = [], {}
    sysnames: list[tuple[str, str]] = []
    body: list[str] | None = None
    with open(path, encoding='utf-8', errors='replace') as fh:
        for ln in fh:
            if body is None:
                if ln.startswith('$bio'):
                    body = []
                elif ln.startswith('$') and '=' in ln:
                    sysn, roms = ln[1:].split('=', 1)
                    for r in roms.strip().split(','):
                        if r.strip():
                            sysnames.append((sysn.strip().lower(), r.strip().lower()))
                continue
            if ln.startswith('$end'):
                e = parse_bio(''.join(body))
                idx = len(entries)
                e['keys'] = [f'{s}:{r}' for s, r in sysnames]
                entries.append(e)
                for s, r in sysnames:
                    keys.setdefault(f'{s}:{r}', idx)
                sysnames, body = [], None
            else:
                body.append(ln)
    return entries, keys


def parse_history_xml(path: Path) -> tuple[list, dict]:
    entries, keys = [], {}
    for _ev, el in ET.iterparse(str(path), events=('end',)):
        if el.tag != 'entry':
            continue
        sysnames = []
        for s in el.iter('system'):
            if s.get('name'):
                sysnames.append(('info', s.get('name').lower()))
        for s in el.iter('item'):
            if s.get('name'):
                sysnames.append(((s.get('list') or 'info').lower(), s.get('name').lower()))
        t = el.find('text')
        if sysnames and t is not None and t.text:
            e = parse_bio(t.text)
            idx = len(entries)
            e['keys'] = [f'{a}:{b}' for a, b in sysnames]
            entries.append(e)
            for a, b in sysnames:
                keys.setdefault(f'{a}:{b}', idx)
        el.clear()
    return entries, keys


def find_history(root: Path, explicit: Path | None) -> Path | None:
    if explicit:
        return explicit if explicit.exists() else None
    for rel in ('emulators/mame/history/history.dat', 'emulators/mame/history.dat', 'emulators/mame/dats/history.dat',
                'emulators/mame/history/history.xml', 'emulators/mame/dats/history.xml'):
        p = root / rel
        if p.exists():
            return p
    mame = root / 'emulators' / 'mame'
    if mame.is_dir():
        for dp, dns, fns in os.walk(mame):
            dns[:] = [d for d in dns if d.lower() not in ('roms', 'snap', 'video', 'samples', 'artwork')
                      and not os.path.islink(os.path.join(dp, d))]
            for f in fns:
                if f.lower() in ('history.dat', 'history.xml'):
                    return Path(dp) / f
    return None


def load_history(path: Path | None, cache: Path, force: bool, log) -> tuple[list, dict, str]:
    if not path:
        return [], {}, 'none'
    st = path.stat()
    stamp = f'{st.st_size}:{int(st.st_mtime)}:{INDEX_VERSION}'
    if cache.exists() and not force:
        try:
            d = json.loads(cache.read_text(encoding='utf-8'))
            if d.get('stamp') == stamp and d.get('source', '').lower() == str(path).lower():
                return d['entries'], d['keys'], 'cache'
        except (ValueError, KeyError):
            pass
    t0 = time.time()
    with open(path, 'rb') as fh:
        head = fh.read(4096).lstrip(b'\xef\xbb\xbf').lstrip()
    fmt = 'xml' if head.startswith(b'<?xml') or head.startswith(b'<history') else 'legacy'
    entries, keys = (parse_history_xml if fmt == 'xml' else parse_history_legacy)(path)
    log(f'  parsed {path.name} ({fmt}): {len(entries)} entries, {len(keys)} keys in {time.time() - t0:.1f}s')
    cache.parent.mkdir(parents=True, exist_ok=True)
    tmp = cache.with_suffix('.tmp')
    tmp.write_text(json.dumps({'stamp': stamp, 'source': str(path), 'format': fmt, 'entries': entries,
                               'keys': keys}, separators=(',', ':')), encoding='utf-8')
    os.replace(tmp, cache)
    return entries, keys, f'parsed-{fmt}'


_CURATED = None


def curated() -> dict:
    """tools/game-stories.json: { "<item>": { title, year, maker, story, special: [...] } } keyed by the item name the
    game lists use (case-insensitive). Written by hand for games history.dat does not cover."""
    global _CURATED
    if _CURATED is None:
        p = Path(__file__).with_name('game-stories.json')
        try:
            raw = json.loads(p.read_text(encoding='utf-8')) if p.exists() else {}
        except ValueError as e:
            print(f'WARNING: {p.name} unreadable ({e}) - hand-written stories skipped')
            raw = {}
        _CURATED = {k.lower(): v for k, v in raw.items() if not k.startswith('_') and isinstance(v, dict)}
    return _CURATED


def titles_agree(a: str, b: str) -> bool:
    """the same game by name: equal, or one title inside the other ("Daytona USA" / "Daytona USA 2")"""
    na, nb = norm_base(a), norm_base(b)
    if not na or not nb:
        return False
    return na == nb or (min(len(na), len(nb)) >= 4 and (na in nb or nb in na))


class History:
    def __init__(self, entries: list, keys: dict):
        self.entries, self.keys = entries, keys
        self.by_title: dict[str, list[int]] = {}
        self.by_title_sys: dict[tuple, list[int]] = {}
        self.by_base_sys: dict[tuple, list[int]] = {}
        for i, e in enumerate(entries):
            systems = {k.split(':', 1)[0] for k in e.get('keys', [])}
            t = norm(e['title'])
            if t:
                self.by_title.setdefault(t, []).append(i)
                for s in systems:
                    self.by_title_sys.setdefault((s, t), []).append(i)
                    self.by_base_sys.setdefault((s, norm_base(e['title'])), []).append(i)

    @staticmethod
    def weight(e) -> int:
        return len(' '.join(e['desc'])) + len(' '.join(e['trivia'])) + (0 if e['ref'] else 200)

    def best(self, idxs) -> dict | None:
        if not idxs:
            return None
        return max((self.entries[i] for i in idxs), key=self.weight)

    def key(self, system: str, rom: str) -> dict | None:
        i = self.keys.get(f'{system}:{rom.lower()}')
        return self.entries[i] if i is not None else None

    def title(self, systems, title: str, base_ok=False) -> dict | None:
        t = norm(title)
        if not t:
            return None
        hits = [i for s in systems for i in self.by_title_sys.get((s, t), [])]
        if not hits and base_ok and len(norm_base(title)) >= 5:
            hits = [i for s in systems for i in self.by_base_sys.get((s, norm_base(title)), [])]
        return self.best(hits)

    def resolve_ref(self, e: dict) -> dict | None:
        """a re-release/export entry that says 'please see the original ... entry, "<title> [...]"', or one with
        next to no description of its own: the same-titled sibling entry (the original release) with the most text"""
        systems = {k.split(':', 1)[0] for k in e.get('keys', [])} or {'info'}
        hits = []
        if e.get('ref'):
            hits = [i for s in systems for i in self.by_title_sys.get((s, norm(e['ref'])), [])]
        if not hits and len(' '.join(e['desc'])) < 150:
            hits = [i for s in systems for i in self.by_title_sys.get((s, norm(e['title'])), [])]
        hits = [i for i in hits if self.entries[i] is not e]
        r = self.best(hits)
        return r if r and (r['desc'] or r['trivia']) else None


# ------------------------------------------------------------------ story assembly
TRIVIA_SKIP = re.compile(r'^(known re-?releases|note\b|see also|this (?:set|version|entry)|"|\(|edit this entry|'
                         r'contribute|sources?\b|thanks to|dip ?switch)|\bentry\b|\bdip\s?switch|\bromset\b|'
                         r'\bMAME\b|\bdumped\b|\bPCB\b|\bEPROM\b|https?://|www\.', re.I)
GOOD = re.compile(r'\b(first|only|record|best[- ]selling|sold|units|million|famous|inspir|movie|film|sequel|'
                  r'hidden|secret|easter egg|designed|created|debut|award|popular|influen|legend|cult|appear|'
                  r'world|landmark|pioneer|revolution|innovat|introduc|original|named|licen[cs]e|ported|'
                  r'released)', re.I)


def trivia_bullets(paras: list[str], limit: int) -> list[str]:
    cands = []
    for pos, p in enumerate(paras):
        lines = [ln.strip() for ln in p.split('\n') if ln.strip()]
        if not lines:
            continue
        # a list block: keep only a lead sentence that does not introduce the list
        if len(lines) > 1 and sum(1 for ln in lines if len(ln) < 90 or ln[:1] in '-*=>0123456789"') > len(lines) / 2:
            if lines[0].endswith(':') or len(lines[0]) < 40:
                continue
            p = lines[0]
        text = squash(re.sub(r'^\s*[\*\-]\s*', '', p))
        text = re.sub(r'^About [^:.]{2,40}\s:\s*', '', text)
        text = re.sub(r'\s*\((?:see|refer to|read)\b[^)]*\)', '', text, flags=re.I)
        if re.search(r'\b(?:staff|trivia|tips and tricks|series|ports) section\b', text, re.I):
            continue
        if not text or TRIVIA_SKIP.search(text) or text.endswith(':'):
            continue
        s = clip_sentences(text, BULLET_MAX, min_one=False)
        if not s or len(s) < 30 or not s[-1] in '.!?")\'' or s.endswith('...') or s.count('"') % 2 \
                or re.search(r'as follows|the following', s, re.I):
            continue
        score = len(GOOD.findall(s)) * 2 + (3 if pos == 0 else 0) - (len(text) > 1500)
        cands.append((score, pos, s))
    chosen = sorted(sorted(cands, key=lambda c: (-c[0], c[1]))[:5], key=lambda c: c[1])
    out, used = [], 0
    for _sc, _pos, s in chosen:
        if used + len(s) + 3 > limit:
            continue
        out.append(s)
        used += len(s) + 3
    return out


def series_line(series: list[str]) -> str:
    games = []
    for ln in series:
        m = re.match(r'^\d+\.\s*(.+?)\s*(?:\[.*?\])?\s*\((\d{4})[^)]*\)\s*$', ln)
        if m:
            games.append((re.sub(r'\s*\[.*?\]', '', m.group(1)).strip(), m.group(2)))
    if len(games) < 2:
        return ''
    return (f'One of {len(games)} games in its series, from {games[0][0]} ({games[0][1]}) '
            f'to {games[-1][0]} ({games[-1][1]}).')


def ports_line(ports: list[str]) -> str:
    plats = []
    for ln in ports:
        if ln.startswith('*') or ln.endswith(':'):
            continue
        ln = re.sub(r'\s*\[[^\]]*\]\s*', ' ', ln).strip()
        p = re.split(r'\s*\(|\s+\w{3}\.\s*\d|\s+"|\s+\d{4}', ln)[0].strip(' ,.')
        if p and len(p) < 40 and p.lower() not in (x.lower() for x in plats):
            plats.append(p)
    if not plats:
        return ''
    if len(plats) > 4:
        return f'Later ported to {", ".join(plats[:4])} and more.'
    if len(plats) == 1:
        return f'Later ported to {plats[0]}.'
    return f'Later ported to {", ".join(plats[:-1])} and {plats[-1]}.'


def clean_story_file(text: str) -> str:
    text = to_ascii(text.replace('\r', ''))
    keep = []
    for ln in text.split('\n'):
        s = ln.strip()
        if re.match(r'^(sources?|references?)\s*:?\s*$', s, re.I):
            break
        if re.match(r'^(sources?|references?|contribute|edit this entry|roms?|revision)\b', s, re.I) or \
                re.search(r'https?://|www\.', s):
            continue
        keep.append(s)
    return squash(' '.join(keep))


def article(word: str) -> str:
    return 'An' if word[:1].lower() in 'aeiou' and not word.lower().startswith(('one', 'uni', 'eu')) else 'A'


def players_text(p: str) -> str:
    p = (p or '').strip()
    if not p:
        return ''
    m = re.match(r'^(\d+)(?:\s*-\s*(\d+))?', p)
    if not m:
        return ''
    lo, hi = m.group(1), m.group(2)
    if hi and hi != lo:
        return f'for {lo}-{hi} players'
    if lo == '1':
        return 'for 1 player'
    return f'for 1-{lo} players' if int(lo) > 1 else ''


def fallback_paragraph(f: dict) -> str:
    genre = (f.get('genre') or '').strip()
    genre = re.split(r'\s*/\s*', genre)[0].lower() if genre else ''
    if genre and not genre.endswith('game'):
        genre = f'{genre} game'
    core = ' '.join(x for x in (f.get('year', ''), genre or 'game') if x)
    plat = f.get('platform') or ''
    s = f'{article(core)} {core}'
    if f.get('maker'):
        s += f' by {f["maker"]}'
    if plat == 'arcade':
        s += ' for arcades'
    elif plat == 'PC':
        s += ' for PC'
    elif plat and f.get('arcade'):
        s += f' for arcades ({plat} hardware)'
    elif plat:
        s += f' for the {plat}'
    pt = players_text(f.get('players', ''))
    if pt:
        s += (', ' if plat else ' ') + pt
    return s + '.'


def build_story(f: dict) -> str:
    """f: title, year, maker, para, bullets -> final text"""
    t = f['title']
    tail = ', '.join(x for x in (f.get('year'), f.get('maker')) if x)
    head = f'{t} ({tail})' if tail else t
    out = head + '\n\n' + f['para'].strip() + '\n'
    if f.get('bullets'):
        out += '\nWHAT MADE IT SPECIAL\n' + ''.join(f'- {b}\n' for b in f['bullets'])
    out = to_ascii(out)
    out = re.sub(r'[ \t]+\n', '\n', out)
    return out


def compose(title, year, maker, desc_paras, trivia, series, ports, extra_para='') -> tuple[str, list[str]]:
    para = ''
    if desc_paras:
        para = clip_sentences(' '.join(desc_paras), PARA_MAX)
    if not para and extra_para:
        para = clip_sentences(extra_para, PARA_MAX)
    head_len = len(title) + len(year) + len(maker) + 8
    budget = MAX_LEN - head_len - len(para) - 25
    bullets = trivia_bullets(trivia, budget) if trivia else []
    if len(bullets) < 5:
        for extra in (series_line(series), ports_line(ports)):
            if extra and len(bullets) < 5 and sum(len(b) + 3 for b in bullets) + len(extra) + 3 <= budget:
                bullets.append(extra)
                break
    return para, bullets


# ------------------------------------------------------------------ RetroFE collections (as New-PanelControlsArt.py)
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
SKIP_DEFAULT = re.compile(r'^(_|zzz|main$|tools$)', re.I)


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


# ------------------------------------------------------------------ safe writing
class Writer:
    def __init__(self, root: Path, dry: bool, force: bool):
        self.root = Path(os.path.realpath(root))
        self.dry, self.force = dry, force

    def check(self, p: Path):
        real = Path(os.path.realpath(p))
        rs = str(real).lower()
        if rs.startswith('e:') or not rs.startswith(str(self.root).lower() + os.sep):
            raise RuntimeError(f'refusing to write outside the frontend copy: {p} -> {real}')
        parts = [x.lower() for x in real.relative_to(self.root).parts]
        if len(parts) < 5 or parts[0] != 'collections' or parts[2] != 'medium_artwork' or parts[3] != OUT_DIR \
                or any(x in ('roms', 'video') for x in parts):
            raise RuntimeError(f'refusing to write outside collections/<c>/medium_artwork/{OUT_DIR}: {real}')

    def ensure_dir(self, d: Path):
        self.check(d / 'x.txt')
        if not self.dry:
            d.mkdir(parents=True, exist_ok=True)

    def write(self, p: Path, data: bytes) -> str:
        """'new' | 'changed' | 'same'.  Rewrites in place so hard links to the file follow."""
        self.check(p)
        old = None
        try:
            old = p.read_bytes()
        except OSError:
            pass
        if old == data and not self.force:
            return 'same'
        if not self.dry:
            with open(p, 'r+b' if old is not None else 'wb') as fh:
                fh.truncate(0)
                fh.write(data)
        return 'new' if old is None else ('same' if old == data else 'changed')

    def link(self, src: Path, dst: Path, data: bytes) -> str:
        """parent (merged list) copy: hard link to src, else a copy. 'linked' | 'copied' | 'same'"""
        self.check(dst)
        if dst.exists():
            try:
                if os.path.samefile(src, dst):
                    return 'same'
            except OSError:
                pass
            if dst.read_bytes() == data and not self.force:
                return 'same'
            if not self.dry:
                os.unlink(dst)
        if self.dry:
            return 'linked'
        try:
            os.link(src, dst)
            return 'linked'
        except OSError:
            dst.write_bytes(data)
            return 'copied'

    def remove(self, p: Path):
        self.check(p)
        if not self.dry:
            os.unlink(p)


# ------------------------------------------------------------------ main
def main(argv=None):
    ap = argparse.ArgumentParser(description='Per-game background story text (am_story) for RetroFE.')
    ap.add_argument('--retrofe', type=Path, default=DEFAULT_RETROFE)
    ap.add_argument('--manifest', type=Path, default=DEFAULT_MANIFEST)
    ap.add_argument('--history', type=Path, help='history.dat / history.xml (default: found under emulators/mame)')
    ap.add_argument('--collections', help='comma list; merged (.sub) collections expand to their sources')
    ap.add_argument('--dry-run', action='store_true', help='resolve and count only; write nothing')
    ap.add_argument('--force', action='store_true', help='re-parse history.dat and rewrite every story file')
    ap.add_argument('--show', help='print the story of these items (comma list) to stdout')
    a = ap.parse_args(argv)
    t0 = time.time()
    log = lambda m: print(m, flush=True)
    root, man = a.retrofe.resolve(), a.manifest.resolve()
    if str(root).lower().startswith('e:'):
        sys.exit('refusing to run against E: (the live frontend)')
    fe = Frontend(root)
    W = Writer(root, a.dry_run, a.force)

    # ---- history.dat
    hpath = find_history(root, a.history)
    entries, keys, how = load_history(hpath, man / 'history-index.json', a.force, log)
    hist = History(entries, keys)
    log(f'history: {hpath or "none"} ({how}, {len(entries)} entries)')

    # ---- games.json
    gj_item, gj_norm, catalog_items = {}, {}, {}
    gj = man / 'games.json'
    if gj.exists():
        for g in json.loads(gj.read_text(encoding='utf-8-sig')).get('games', []):
            for s in g.get('sources') or []:
                if s.get('collection') and s.get('item'):
                    gj_item[(s['collection'].lower(), str(s['item']).lower())] = g
                    catalog_items.setdefault(s['collection'].lower(), []).append(s['item'])
            for v in (g.get('variants') or {}).values():
                rc = v.get('retrofeCollection')
                for k in (v.get('profile'), v.get('rom')):
                    if isinstance(rc, str) and k:
                        gj_item.setdefault((rc.lower(), str(k).lower()), g)
                    if k:
                        gj_norm.setdefault(norm(k), g)
            if g.get('id'):
                gj_norm.setdefault(norm(g['id']), g)
            if g.get('title'):
                gj_norm.setdefault(norm(g['title']), g)

    # ---- meta.db
    meta, meta_names = {}, {}
    mdb = root / 'meta.db'
    if mdb.exists():
        con = sqlite3.connect(f'file:{mdb}?mode=ro', uri=True)
        con.row_factory = sqlite3.Row
        for r in con.execute('select * from Meta'):
            meta_names.setdefault(r['collectionName'].lower(), []).append(r['name'])
            meta[(r['collectionName'].lower(), r['name'].lower())] = dict(r)
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
    confs: dict[str, dict] = {}

    def conf_of(c):
        if c not in confs:
            confs[c] = read_conf(fe.cdir / c / 'settings.conf')
        return confs[c]

    def mtype_of(c):
        return conf_of(c).get('metadata.type', c).replace('%ITEM_COLLECTION_NAME%', c)

    def is_mame(c):
        cf = conf_of(c)
        return mtype_of(c).lower() == 'mame' or cf.get('launcher', '').lower() == 'mame'

    story_dirs: dict[str, list[Path]] = {}

    def story_folders(c):
        if c not in story_dirs:
            ma = fe.cdir / c / 'medium_artwork'
            found = []
            if ma.is_dir():
                for sub in ('story', 'archives/story', 'bio', 'archives/bio', 'description', 'archives/description',
                            'descriptions', 'history'):
                    p = ma / sub
                    if p.is_dir() and not os.path.islink(p):
                        found.append(p)
            story_dirs[c] = found
        return story_dirs[c]

    # ---- resolve one game -> (text, source) ; cached per (source collection, item)
    resolved: dict[tuple, tuple] = {}

    def resolve(scol: str, item: str):
        k = (scol.lower(), item.lower())
        if k in resolved:
            return resolved[k]
        mt = mtype_of(scol).lower()
        md = meta.get((mt, item.lower())) or meta.get((scol.lower(), item.lower())) or {}
        g = gj_item.get(k) or gj_norm.get(norm(item)) or {}
        mtitle = md.get('title') or g.get('title') or ''
        # 1. history.dat
        h = None
        if is_mame(scol):
            h = hist.key('info', item)
            if h is None and md.get('cloneOf'):
                h = hist.key('info', md['cloneOf'])
        if h is None:
            for sysn in SOFTLISTS.get(scol.lower(), []):
                h = hist.key(sysn, item)
                if h:
                    break
        # list items that are titles, not rom names ("AddamsFamily", "4D Sports Driving_Amiga", "After Burner Climax")
        item_title = re.sub(r'[_ ](amiga|aga|ocs|ecs|cd32|c64|snes|n64|psx)$', '', item, flags=re.I).replace('_', ' ')
        if h is None and not is_mame(scol):
            h = hist.key('info', item) if scol.lower() in ARCADE_LIKE else None
            # a TeknoParrot / PC id is not a MAME rom name: "AAA" (America's Army Arcade, 2007) hit MAME's "aaa"
            # (Ambassador, 1981). Taken by name only when the titles agree.
            if h is not None and mtitle and not titles_agree(h.get('title', ''), mtitle):
                h = None
            systems = SOFTLISTS.get(scol.lower(), [])
            for t in (mtitle, item_title):
                if h is None and t and systems:
                    h = hist.title(systems, t, base_ok=True)
                if h is None and t and scol.lower() in ARCADE_LIKE:
                    h = hist.title(['info'], t)
        if h is None and is_mame(scol):
            for t in (mtitle, item_title if re.search(r'[A-Z ]', item) else ''):
                if h is None and t:
                    h = hist.title(['info'], t)
        # the same title is not the same game: "GRID" (Codemasters, 2009) is not Midway's "The Grid" (2000), and the
        # Tomb Raider gun game is not JPM's 2002 fruit machine. A MAME rom-name hit is exact; any other hit must agree
        # with the catalog's year (within 2) when both are known.
        if h is not None and not (is_mame(scol) and hist.key('info', item) is h):
            gy = str(g.get('year') or md.get('year') or '')[:4]
            hy = str(h.get('year') or '')[:4]
            if gy.isdigit() and hy.isdigit() and abs(int(gy) - int(hy)) > 2:
                h = None
        ref = hist.resolve_ref(h) if h else None
        # 2. story files in the build (this collection's, then the ones of the collection games.json names)
        story = ''
        places = [(d, item) for d in story_folders(scol)]
        for s in g.get('sources') or []:
            if s.get('collection') and s.get('item') and s['collection'].lower() != scol.lower():
                places += [(d, s['item']) for d in story_folders(s['collection'])]
        for v in (g.get('variants') or {}).values():
            rc = v.get('retrofeCollection')
            if isinstance(rc, str) and v.get('profile') and rc.lower() != scol.lower():
                places += [(d, v['profile']) for d in story_folders(rc)]
        for d, name in places:
            p = d / f'{name}.txt'
            if p.exists():
                try:
                    raw = p.read_bytes()
                    try:
                        txt = raw.decode('utf-8-sig')
                    except UnicodeDecodeError:
                        txt = raw.decode('cp1252', errors='replace')
                    story = clean_story_file(txt)
                except OSError:
                    story = ''
                if len(story) > 40:
                    break
        # title line facts
        title = year = maker = ''
        if h:
            title, year, maker = h['title'], h['year'], h['maker']
            if ref:
                title = title or ref['title']
                year = year or ref['year']
                maker = maker or ref['maker']
        if not title:
            title = to_ascii(re.sub(r'\s*\((?:[^)]*(?:set|rev|ver|bootleg|hack|world|japan|us|europe|asia)[^)]*)\)',
                                    '', mtitle, flags=re.I)).strip() or item
        year = year or str(g.get('year') or md.get('year') or '').strip()
        maker = maker or to_ascii(str(g.get('manufacturer') or g.get('developer') or md.get('manufacturer')
                                      or md.get('developer') or '')).strip()
        if '?' in year:
            year = ''
        if maker.lower() in ('unknown', '<unknown>', 'bootleg'):
            maker = ''
        src = None
        para, bullets = '', []
        if h:
            desc = list(h['desc'])
            trivia = list(h['trivia'])
            if ref:
                if len(' '.join(desc)) < 150:
                    desc = ref['desc'] + desc if ref['desc'] else desc
                trivia = trivia + [p for p in ref['trivia'] if p not in trivia]
            para, bullets = compose(title, year, maker, desc, trivia,
                                    h['series'] or (ref or {}).get('series', []),
                                    h['ports'] or (ref or {}).get('ports', []), extra_para=story)
            if para:
                src = 'history.dat' + ('+story' if story and not desc else '')
        # 0. hand-written stories in the repo (tools/game-stories.json) win: games no database describes well
        cur = curated().get(item.lower())
        if cur:
            title = to_ascii(cur.get('title') or title)
            year = str(cur.get('year') or year)
            maker = to_ascii(cur.get('maker') or maker)
            para = to_ascii(squash(cur.get('story', '')))
            bullets = [to_ascii(squash(b)) for b in cur.get('special', []) if b]
            src = 'curated'
        if not para and story:
            para = clip_sentences(story, PARA_MAX + 250)
            src = 'story file'
        fields = {'year': year, 'maker': maker, 'genre': g.get('genre') or md.get('genre') or '',
                  'players': md.get('players') or '',
                  'platform': g.get('platform') or PLATFORM.get(scol.lower(), scol),
                  'arcade': scol.lower() in ARCADE_LIKE or is_mame(scol)}
        if not para and h and (year or maker or bullets):
            # history.dat knows the game but has no description (many console entries): facts line + its trivia
            para, src = fallback_paragraph(fields), 'history.dat (facts)'
        if not para and g and (g.get('year') or g.get('genre') or g.get('platform')):
            para, src = fallback_paragraph(fields), 'games.json'
        if not para and md and any(md.get(x) for x in ('year', 'manufacturer', 'genre', 'players')):
            para, src = fallback_paragraph(fields), 'meta.db'
        if not para:
            resolved[k] = (None, None)
            return resolved[k]
        text = build_story({'title': title, 'year': year, 'maker': maker, 'para': para, 'bullets': bullets})
        resolved[k] = (text, src)
        return resolved[k]

    # ---- plan + write
    show = {x.strip().lower() for x in (a.show or '').split(',') if x.strip()}
    shown = set()
    tot = {'new': 0, 'changed': 0, 'same': 0, 'linked': 0, 'copied': 0, 'stale': 0, 'none': 0}
    rows = []
    written_src: dict[tuple, Path] = {}       # (scol, item) -> the source collection's file (link target)
    plans = {}
    for col in cols:
        pairs, seen = [], set()
        for it in fe.items(col, meta_names, catalog_items):
            seen.add(it.lower())
            pairs.append((col, it))
        for sf in sorted((fe.cdir / col).glob('*.sub')):
            sc = sf.stem
            if sc.lower() == col.lower() or SKIP_DEFAULT.match(sc) or not (fe.cdir / sc).is_dir() \
                    or not fe.is_game_collection(sc):
                continue
            only = {x.lower() for x in read_list(sf)}
            for it in fe.items(sc, meta_names, catalog_items):
                if (not only or it.lower() in only) and it.lower() not in seen:
                    seen.add(it.lower())
                    pairs.append((sc, it))
        plans[col] = pairs
    # source collections first, so a merged parent can hard-link to the file its source wrote
    order = sorted(plans, key=lambda c: any(sc != c for sc, _ in plans[c]))
    for col in order:
        pairs = plans[col]
        adir = fe.cdir / col / 'medium_artwork' / OUT_DIR
        W.ensure_dir(adir)
        st = {'items': len(pairs), 'own': 0, 'merged': 0, 'new': 0, 'changed': 0, 'same': 0, 'linked': 0,
              'copied': 0, 'none': 0, 'src': {}, 'missing': []}
        planned = set()
        for scol, it in pairs:
            text, src = resolve(scol, it)
            if text is None:
                st['none'] += 1
                if len(st['missing']) < 6:
                    st['missing'].append(it if scol == col else f'{scol}/{it}')
                continue
            if it.lower() in show and it.lower() not in shown:
                shown.add(it.lower())
                print(f'\n----- {scol}/{it}.txt [{src}, {len(text)} chars]\n{text}-----')
            data = text.encode('utf-8')
            dst = adir / f'{it}.txt'
            planned.add(dst.name.lower())
            st['src'][src] = st['src'].get(src, 0) + 1
            if scol == col:
                st['own'] += 1
                r = W.write(dst, data)
                st[r] += 1
                written_src[(scol.lower(), it.lower())] = dst
            else:
                st['merged'] += 1
                srcf = written_src.get((scol.lower(), it.lower()))
                if srcf is None:
                    # the source collection was not part of this run: write its file there too
                    sdir = fe.cdir / scol / 'medium_artwork' / OUT_DIR
                    W.ensure_dir(sdir)
                    srcf = sdir / f'{it}.txt'
                    W.write(srcf, data)
                    written_src[(scol.lower(), it.lower())] = srcf
                if a.dry_run and not srcf.exists():
                    st['linked'] += 1
                else:
                    r = W.link(srcf, dst, data)
                    st[r if r != 'same' else 'same'] += 1
        # stale stories (an item no longer listed): this folder is ours alone
        stale = 0
        if adir.is_dir():
            for e in os.scandir(adir):
                if e.is_file() and e.name.lower().endswith('.txt') and e.name.lower() not in planned:
                    W.remove(Path(e.path))
                    stale += 1
        st['stale'] = stale
        for k2 in tot:
            tot[k2] += st.get(k2, 0)
        rows.append((col, st))

    # ---- summary
    log('')
    log(f'{"collection":<22}{"items":>6}{"merged":>7}{"new":>6}{"chg":>5}{"same":>6}{"link":>6}{"none":>6}  sources')
    for col, st in sorted(rows):
        srcs = ', '.join(f'{k}={v}' for k, v in sorted(st['src'].items(), key=lambda x: -x[1]))
        log(f'{col:<22}{st["items"]:>6}{st["merged"]:>7}{st["new"]:>6}{st["changed"]:>5}{st["same"]:>6}'
            f'{st["linked"] + st["copied"]:>6}{st["none"]:>6}  {srcs}')
        if st['missing']:
            log(f'{"":<22}no story: {", ".join(st["missing"])}{" ..." if st["none"] > len(st["missing"]) else ""}')
    log(f'\ntotal: new {tot["new"]}, changed {tot["changed"]}, unchanged {tot["same"]}, parent links '
        f'{tot["linked"]} (+{tot["copied"]} copies), stale removed {tot["stale"]}, no story {tot["none"]}'
        f'{"  [dry run: nothing written]" if a.dry_run else ""}')
    log(f'time: {time.time() - t0:.1f}s')


if __name__ == '__main__':
    main()
