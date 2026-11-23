#!/usr/bin/env python3
"""
Find-DuplicateFiles.py - READ-ONLY scan for identical files across the frontend builds on one drive.

The cleanup plan for a cabinet with many CoinOPS / CORE / RetroBat builds: identical files (the same ROM, the same
emulator, the same video in five builds) can become NTFS hard links of one copy. Every build keeps its own paths
and keeps working; the space of the extra copies comes back. This script only MEASURES - it changes nothing.

Candidates are grouped by (size, file name); each group is then confirmed with a quick fingerprint (first + last
1 MB + size). Run with --verify to fully hash the confirmed groups (slow) before any linking step.

  python tools/Find-DuplicateFiles.py --root R:\\ --out R:\\ArcadeMaster\\manifest\\duplicates
         [--min-mb 1] [--skip "R:\\repos,R:\\ArcadeMaster"] [--verify]

Writes <out>.json (every group) and <out>.md (summary per build and per kind of file).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
from collections import defaultdict
from pathlib import Path

CHUNK = 1 << 20


def kind_of(rel: str) -> str:
    r = rel.lower().replace('/', '\\')
    for k, keys in (('video', ('\\video', '\\videos', '.mp4', '.mkv', '.avi', '.flv')),
                    ('roms', ('\\roms', '.zip', '.7z', '.chd', '.iso', '.cue', '.bin', '.gdi', '.cdi', '.rvz', '.wbfs')),
                    ('emulators', ('\\emulators\\',)),
                    ('artwork', ('artwork', '.png', '.jpg')),):
        if any(x in r for x in keys):
            return k
    return 'other'


def quick_print(p: str, size: int) -> str | None:
    try:
        h = hashlib.blake2b(digest_size=16)
        with open(p, 'rb') as f:
            h.update(f.read(CHUNK))
            if size > 2 * CHUNK:
                f.seek(-CHUNK, 2)
                h.update(f.read(CHUNK))
        h.update(str(size).encode())
        return h.hexdigest()
    except OSError:
        return None


def full_hash(p: str) -> str | None:
    try:
        h = hashlib.blake2b(digest_size=20)
        with open(p, 'rb') as f:
            while b := f.read(8 * CHUNK):
                h.update(b)
        return h.hexdigest()
    except OSError:
        return None


def walk(top: str, skip: set, min_size: int, files: list, stats: dict):
    stack = [top]
    while stack:
        d = stack.pop()
        try:
            it = os.scandir(d)
        except OSError:
            stats['unreadable'] += 1
            continue
        with it:
            for e in it:
                try:
                    if e.is_dir(follow_symlinks=False):
                        # never follow junctions / symlinks: they point at files counted elsewhere (or on E:)
                        if e.is_junction() if hasattr(e, 'is_junction') else (e.stat(follow_symlinks=False).st_file_attributes & 0x400):
                            stats['junctions'] += 1
                            continue
                        if e.path.lower().rstrip('\\') in skip or e.name in ('$RECYCLE.BIN', 'System Volume Information'):
                            continue
                        stack.append(e.path)
                    elif e.is_file(follow_symlinks=False):
                        st = e.stat(follow_symlinks=False)
                        stats['files'] += 1
                        stats['bytes'] += st.st_size
                        if st.st_size >= min_size:
                            files.append((e.path, st.st_size, st.st_ino, e.name.lower()))
                except OSError:
                    stats['unreadable'] += 1


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', required=True)
    ap.add_argument('--out', required=True, type=Path)
    ap.add_argument('--min-mb', type=float, default=1.0)
    ap.add_argument('--skip', default='')
    ap.add_argument('--verify', action='store_true')
    a = ap.parse_args(argv)
    t0 = time.time()
    root = os.path.abspath(a.root)
    skip = {s.strip().lower().rstrip('\\') for s in a.skip.split(',') if s.strip()}
    stats = defaultdict(int)
    files: list = []
    tops = [e.path for e in os.scandir(root) if e.is_dir(follow_symlinks=False)
            and e.name not in ('$RECYCLE.BIN', 'System Volume Information') and e.path.lower().rstrip('\\') not in skip]
    for t in tops:
        t1 = time.time()
        n0 = len(files)
        walk(t, skip, int(a.min_mb * CHUNK), files, stats)
        print(f'scanned {t}: {len(files) - n0} files >= {a.min_mb} MB in {time.time() - t1:.0f}s', flush=True)
    t_scan = time.time()

    # files already hard-linked together count once
    by_key = defaultdict(list)
    seen_ino = set()
    for p, size, ino, name in files:
        if ino in seen_ino:
            stats['already_linked'] += 1
            continue
        seen_ino.add(ino)
        by_key[(size, name)].append(p)
    cand = {k: v for k, v in by_key.items() if len(v) > 1}
    print(f'{len(cand)} candidate groups by size+name; fingerprinting ...', flush=True)

    groups = []
    for (size, name), paths in sorted(cand.items(), key=lambda kv: -kv[0][0] * (len(kv[1]) - 1)):
        fp = defaultdict(list)
        for p in paths:
            q = quick_print(p, size)
            if q:
                fp[q].append(p)
        for q, ps in fp.items():
            if len(ps) < 2:
                continue
            if a.verify:
                fh = defaultdict(list)
                for p in ps:
                    h = full_hash(p)
                    if h:
                        fh[h].append(p)
                for h, ps2 in fh.items():
                    if len(ps2) > 1:
                        groups.append({'size': size, 'hash': h, 'verified': True, 'paths': sorted(ps2)})
            else:
                groups.append({'size': size, 'hash': q, 'verified': False, 'paths': sorted(ps)})
    t_fp = time.time()

    # summary: what each build would get back, by kind of file
    def build_of(p):
        rel = os.path.relpath(p, root)
        return rel.split(os.sep)[0]
    save_total = 0
    per_build = defaultdict(lambda: [0, 0])      # build -> [extra copies, bytes saved]
    per_kind = defaultdict(lambda: [0, 0])
    pair = defaultdict(int)                      # (build kept, build linked) -> bytes
    for g in groups:
        keep, extra = g['paths'][0], g['paths'][1:]
        save = g['size'] * len(extra)
        save_total += save
        k = kind_of(os.path.relpath(keep, root))
        per_kind[k][0] += len(extra)
        per_kind[k][1] += save
        for p in extra:
            b = build_of(p)
            per_build[b][0] += 1
            per_build[b][1] += g['size']
            pair[(build_of(keep), b)] += g['size']

    gb = lambda n: f'{n / 1024 ** 3:,.1f} GB'
    a.out.parent.mkdir(parents=True, exist_ok=True)
    report = {'root': root, 'minMB': a.min_mb, 'verified': a.verify, 'scanned_files': stats['files'],
              'scanned_bytes': stats['bytes'], 'junctions_skipped': stats['junctions'],
              'already_linked': stats['already_linked'], 'unreadable': stats['unreadable'],
              'groups': len(groups), 'reclaimable_bytes': save_total,
              'per_build': {k: {'extra_copies': v[0], 'bytes': v[1]} for k, v in per_build.items()},
              'per_kind': {k: {'extra_copies': v[0], 'bytes': v[1]} for k, v in per_kind.items()},
              'duplicates': groups}
    a.out.with_suffix('.json').write_text(json.dumps(report, indent=1), encoding='utf-8')
    md = [f'# Duplicate files on {root}', '',
          f'Read-only scan, {time.strftime("%Y-%m-%d %H:%M")}. Nothing was changed.', '',
          f'- Scanned: {stats["files"]:,} files, {gb(stats["bytes"])} (junctions not followed: {stats["junctions"]})',
          f'- Identical groups (files of {a.min_mb} MB or more): {len(groups):,}'
          + ('' if a.verify else ' - matched by size, name and a first/last-MB fingerprint; full hashes come before any change'),
          f'- **Space a hard-link cleanup would give back: {gb(save_total)}**', '',
          '## By kind of file', '', '| Kind | Extra copies | Space |', '|---|---:|---:|']
    for k, v in sorted(per_kind.items(), key=lambda kv: -kv[1][1]):
        md.append(f'| {k} | {v[0]:,} | {gb(v[1])} |')
    md += ['', '## By build (copies that would become links)', '', '| Build | Extra copies | Space |', '|---|---:|---:|']
    for k, v in sorted(per_build.items(), key=lambda kv: -kv[1][1]):
        md.append(f'| {k} | {v[0]:,} | {gb(v[1])} |')
    md += ['', '## Biggest groups', '', '| Size | Copies | First copy |', '|---:|---:|---|']
    for g in groups[:40]:
        md.append(f'| {gb(g["size"])} | {len(g["paths"])} | {g["paths"][0]} |')
    a.out.with_suffix('.md').write_text('\n'.join(md) + '\n', encoding='utf-8')
    print(f'groups {len(groups):,}, reclaimable {gb(save_total)}; scan {t_scan - t0:.0f}s, fingerprint {t_fp - t_scan:.0f}s')
    print(f'report: {a.out.with_suffix(".md")}')


if __name__ == '__main__':
    sys.exit(main())
