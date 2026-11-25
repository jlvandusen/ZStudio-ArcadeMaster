"""
am_guard.py - which paths the ArcadeMaster tools must never write to (the cabinet's live frontend).

Where the list comes from, first match wins:
  1. AM_PROTECTED environment variable, paths separated by ';'
  2. "ProtectedPaths" in ArcadeMaster.config.json (next to the launcher; looked for beside the manifest folder)
  3. the default: the whole E: drive (on ARCADE-PEDESTAL that holds the live E:\\CoinOPS LEGENDS 4 Max and the game
     drives the R: copy reaches through junctions)

  from am_guard import is_protected, protected_roots
  if is_protected(path): refuse
"""
from __future__ import annotations

import json
import os
from pathlib import Path

DEFAULT = ['E:\\']


def _norm(p: str) -> str:
    r = os.path.normcase(os.path.realpath(p))
    return r if r.endswith(os.sep) else r + os.sep


def _config_candidates(manifest: str | os.PathLike | None):
    if manifest:
        m = Path(manifest)
        yield m.parent / 'ArcadeMaster.config.json'
        yield m / 'ArcadeMaster.config.json'
    yield Path(r'R:\ArcadeMaster\ArcadeMaster.config.json')
    yield Path(r'D:\ArcadeMaster\ArcadeMaster.config.json')


def protected_roots(manifest: str | os.PathLike | None = None) -> list[str]:
    env = os.environ.get('AM_PROTECTED', '').strip()
    if env:
        return [_norm(p) for p in env.split(';') if p.strip()]
    for c in _config_candidates(manifest):
        try:
            cfg = json.loads(c.read_text(encoding='utf-8-sig'))
        except (OSError, ValueError):
            continue
        pp = cfg.get('ProtectedPaths')
        if isinstance(pp, list):
            return [_norm(p) for p in pp if isinstance(p, str) and p.strip()]
        break                       # a config without the key: use the default
    return [_norm(p) for p in DEFAULT]


def is_protected(path: str | os.PathLike, manifest: str | os.PathLike | None = None) -> bool:
    """True when `path` (after following junctions and links) is inside a protected root."""
    p = _norm(str(path))
    return any(p.startswith(r) for r in protected_roots(manifest))
