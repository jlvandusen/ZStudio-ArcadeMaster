#!/usr/bin/env python3
"""
New-PreviewMedia.py - lighter preview videos and per-game backdrops for the RetroFE frontend.

The game list plays the highlighted game's video in a 1040x585 frame, but the source videos are 1920x1080 at about
10 Mbps (up to 340 MB in TeknoParrot). Decoding those on every scroll is wasted work on the cabinet's i3. This tool
makes, for every collection's medium_artwork\\video\\<item>.<ext>:

  medium_artwork\\am_video\\<item>.mp4     at most 1280x720, H.264 High, yuv420p, <=30 fps, 1 s keyframes,
                                          faststart, AAC 128k stereo if the source has audio, at most 60 s.
                                          A source that is already H.264, <=1280 wide and under 4 Mbps is
                                          stream-copied (remuxed) instead, so nothing is lost.
  medium_artwork\\am_backdrop\\<item>.jpg  1920x1080 blurred, darkened, vignetted backdrop from a frame ~35% in
                                          (the most detailed of several candidate frames, so no black frames).

SAFETY: many video / roms folders in the frontend copy are NTFS junctions onto E:. This tool writes ONLY into the
two new folders am_video and am_backdrop, which it creates as real folders, and refuses any target whose folder or
any parent up to the frontend root is a junction / symlink, or that resolves onto E: or outside the frontend root.

Resumable: outputs that exist and are newer than their source are skipped (--force rebuilds). Each output is
written to a .part name and renamed, so a killed run leaves no half files.

  python tools\\New-PreviewMedia.py [--retrofe R:\\ArcadeMaster\\frontend\\LEGENDS-am] [--collections a,b]
         [--limit N] [--dry-run] [--only video|backdrop] [--force] [--jobs N] [--ffmpeg <exe or folder>]
         [--encoder auto|nvenc|x264]

Writes R:\\ArcadeMaster\\manifest\\preview-media.json and preview-media-failures.txt.
"""
from __future__ import annotations

import argparse
import io
import json
import os
import shutil
import stat
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

from PIL import Image, ImageEnhance, ImageFilter, ImageStat

DEFAULT_RETROFE = r'R:\ArcadeMaster\frontend\LEGENDS-am'
MANIFEST_DIR = r'R:\ArcadeMaster\manifest'
FFMPEG_FALLBACK = (r'C:\Users\vdfgamer\AppData\Local\Microsoft\WinGet\Packages'
                   r'\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-9.1-full_build\bin')
VIDEO_EXTS = ['.mp4', '.mkv', '.webm', '.flv', '.avi', '.mov', '.m4v', '.wmv', '.mpg', '.mpeg']
SKIP_NAMES = {'main', 'tools'}
FORBIDDEN_DRIVES = {'E:'}

MAX_W, MAX_H, MAX_FPS, MAX_SECONDS = 1280, 720, 30.0, 60
COPY_MAX_BPS = 4_000_000
BD_W, BD_H = 1920, 1080
NO_WINDOW = getattr(subprocess, 'CREATE_NO_WINDOW', 0)


# ----------------------------------------------------------------------------------------------------- safety
def is_reparse(p: str) -> bool:
    try:
        st = os.stat(p, follow_symlinks=False)
    except FileNotFoundError:
        return False
    attrs = getattr(st, 'st_file_attributes', 0)
    return bool(attrs & stat.FILE_ATTRIBUTE_REPARSE_POINT) or stat.S_ISLNK(st.st_mode)


def on_forbidden_drive(p: str) -> bool:
    return os.path.splitdrive(os.path.realpath(p))[0].upper() in FORBIDDEN_DRIVES


class Unsafe(Exception):
    pass


def check_write_dir(target: str, root: str) -> None:
    """Refuse a target folder unless it and every parent up to the frontend root is a real (non-junction) folder
    and it resolves inside the root and off the forbidden drives."""
    target = os.path.abspath(target)
    root = os.path.abspath(root)
    if os.path.commonpath([target.lower(), root.lower()]) != root.lower():
        raise Unsafe(f'{target} is not inside {root}')
    if on_forbidden_drive(target) or on_forbidden_drive(root):
        raise Unsafe(f'{target} resolves onto a forbidden drive')
    real_t, real_r = os.path.realpath(target), os.path.realpath(root)
    if os.path.commonpath([real_t.lower(), real_r.lower()]) != real_r.lower():
        raise Unsafe(f'{target} resolves to {real_t}, outside {real_r}')
    p = target
    while True:
        if is_reparse(p):
            raise Unsafe(f'{p} is a junction / symlink')
        if os.path.normcase(p) == os.path.normcase(root):
            break
        parent = os.path.dirname(p)
        if parent == p:
            break
        p = parent


def ensure_out_dir(target: str, root: str) -> None:
    check_write_dir(target, root)
    if not os.path.isdir(target):
        os.mkdir(target)          # parent already checked; mkdir makes a real folder
    check_write_dir(target, root)


def check_write_file(path: str, root: str) -> None:
    check_write_dir(os.path.dirname(path), root)
    if os.path.lexists(path) and is_reparse(path):
        raise Unsafe(f'{path} is a link')


# ----------------------------------------------------------------------------------------------------- tools
def find_ffmpeg(arg: str | None) -> tuple[str, str]:
    cands = []
    if arg:
        a = Path(arg)
        cands.append(a.parent if a.is_file() else a)
    w = shutil.which('ffmpeg')
    if w:
        cands.append(Path(w).parent)
    cands.append(Path(FFMPEG_FALLBACK))
    for d in cands:
        ff, fp = d / 'ffmpeg.exe', d / 'ffprobe.exe'
        if ff.is_file() and fp.is_file():
            return str(ff), str(fp)
    sys.exit('ffmpeg / ffprobe not found (use --ffmpeg <folder>)')


def run(cmd, timeout=None, capture_bytes=False):
    return subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout,
                          creationflags=NO_WINDOW, text=not capture_bytes,
                          **({} if capture_bytes else {'encoding': 'utf-8', 'errors': 'replace'}))


def nvenc_works(ffmpeg: str) -> bool:
    r = run([ffmpeg, '-hide_banner', '-encoders'])
    if 'h264_nvenc' not in r.stdout:
        return False
    t = run([ffmpeg, '-hide_banner', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=s=320x240:d=0.5',
             '-c:v', 'h264_nvenc', '-profile:v', 'high', '-f', 'null', '-'], timeout=60)
    return t.returncode == 0


def ffprobe(ffprobe_exe: str, path: str) -> dict:
    r = run([ffprobe_exe, '-v', 'error', '-show_streams', '-show_format', '-of', 'json', path], timeout=120)
    if r.returncode != 0:
        raise RuntimeError('ffprobe: ' + (r.stderr.strip().splitlines() or ['failed'])[-1])
    return json.loads(r.stdout or '{}')


def _num(x, default=None):
    try:
        v = float(x)
        return v if v == v else default
    except (TypeError, ValueError):
        return default


def _rate(s: str | None) -> float | None:
    if not s or s in ('0/0',):
        return None
    if '/' in s:
        a, b = s.split('/', 1)
        a, b = _num(a), _num(b)
        return a / b if a and b else None
    return _num(s)


def media_info(probe: dict, size: int) -> dict:
    streams = probe.get('streams', [])
    vs = [s for s in streams if s.get('codec_type') == 'video'
          and not s.get('disposition', {}).get('attached_pic')]
    aus = [s for s in streams if s.get('codec_type') == 'audio']
    fmt = probe.get('format', {})
    if not vs:
        raise RuntimeError('no video stream')
    v = vs[0]
    dur = _num(fmt.get('duration')) or _num(v.get('duration')) or 0.0
    w, h = int(v.get('width') or 0), int(v.get('height') or 0)
    if not w or not h:
        raise RuntimeError('video stream has no size')
    sar = v.get('sample_aspect_ratio') or '1:1'
    try:
        sn, sd = (int(x) for x in sar.split(':'))
        sar_f = sn / sd if sn and sd else 1.0
    except ValueError:
        sar_f = 1.0
    fps = _rate(v.get('avg_frame_rate')) or _rate(v.get('r_frame_rate')) or 30.0
    if fps > 240:
        fps = _rate(v.get('r_frame_rate')) or 30.0
    vbr = _num(v.get('bit_rate'))
    total_br = _num(fmt.get('bit_rate')) or ((size * 8 / dur) if dur else None)
    if not vbr and total_br:
        abr = sum(_num(a.get('bit_rate'), 128000) for a in aus)
        vbr = max(total_br - abr, total_br * 0.5)
    return {
        'vcodec': v.get('codec_name'), 'pix_fmt': v.get('pix_fmt'), 'width': w, 'height': h, 'sar': sar_f,
        'fps': round(fps, 3), 'duration': round(dur, 3), 'vbitrate': int(vbr or 0), 'bitrate': int(total_br or 0),
        'vindex': v.get('index'), 'acodec': aus[0].get('codec_name') if aus else None,
        'aindex': aus[0].get('index') if aus else None,
    }


# ----------------------------------------------------------------------------------------------------- video
def target_size(info: dict) -> tuple[int, int]:
    w = info['width'] * (info['sar'] if 0.2 < info['sar'] < 5 else 1.0)   # display width (non-square pixels)
    h = info['height']
    f = min(1.0, MAX_W / w, MAX_H / h)
    tw, th = max(2, int(round(w * f / 2)) * 2), max(2, int(round(h * f / 2)) * 2)
    return min(tw, MAX_W), min(th, MAX_H)


def can_copy(info: dict) -> bool:
    return (info['vcodec'] == 'h264' and info['width'] <= MAX_W and 0 < info['vbitrate'] < COPY_MAX_BPS
            and info['pix_fmt'] in ('yuv420p', 'yuvj420p', None))


def video_cmd(ffmpeg: str, src: str, out: str, info: dict, encoder: str) -> tuple[list[str], str]:
    cmd = [ffmpeg, '-hide_banner', '-nostdin', '-v', 'error', '-y']
    copy = can_copy(info)
    if not copy and encoder == 'nvenc':
        cmd += ['-hwaccel', 'cuda']           # NVDEC decode; ffmpeg falls back to software for other codecs
    cmd += ['-i', src, '-t', str(MAX_SECONDS), '-map', f'0:{info["vindex"]}']
    if info['aindex'] is not None:
        cmd += ['-map', f'0:{info["aindex"]}']
    cmd += ['-map_metadata', '-1', '-map_chapters', '-1', '-sn', '-dn']
    if copy:
        cmd += ['-c:v', 'copy']
        mode = 'copy'
    else:
        tw, th = target_size(info)
        out_fps = min(info['fps'] or MAX_FPS, MAX_FPS)
        vf = [f'scale={tw}:{th}:flags=bicubic', 'setsar=1']
        if (info['fps'] or 0) > MAX_FPS + 0.5:
            vf.append(f'fps={int(MAX_FPS)}')
        gop = max(1, int(round(out_fps)))
        cmd += ['-vf', ','.join(vf), '-pix_fmt', 'yuv420p']
        if encoder == 'nvenc':
            cmd += ['-c:v', 'h264_nvenc', '-preset', 'p5', '-tune', 'hq', '-profile:v', 'high',
                    '-rc', 'vbr', '-cq', '26', '-b:v', '2.5M', '-maxrate', '4M', '-bufsize', '8M',
                    '-g', str(gop), '-forced-idr', '1']
        else:
            cmd += ['-c:v', 'libx264', '-preset', 'veryfast', '-crf', '24', '-profile:v', 'high',
                    '-g', str(gop), '-keyint_min', str(gop)]
        mode = encoder
    if info['aindex'] is not None:
        if copy and info['acodec'] == 'aac':
            cmd += ['-c:a', 'copy']
        else:
            cmd += ['-c:a', 'aac', '-b:a', '128k', '-ac', '2']
    else:
        cmd += ['-an']
    cmd += ['-movflags', '+faststart', '-f', 'mp4', out]
    return cmd, mode


# ----------------------------------------------------------------------------------------------------- backdrop
_VIGNETTE: Image.Image | None = None
_VLOCK = threading.Lock()


def vignette_mask() -> Image.Image:
    global _VIGNETTE
    with _VLOCK:
        if _VIGNETTE is None:
            g = Image.radial_gradient('L').resize((BD_W, BD_H), Image.BICUBIC)   # 0 centre .. 255 edge
            # centre 1.0, edges ~0.45: soft, starts darkening about a third of the way out
            lut = [int(255 * (1.0 - 0.55 * min(1.0, max(0.0, (v / 255 - 0.35) / 0.65)) ** 1.6)) for v in range(256)]
            _VIGNETTE = g.point(lut).filter(ImageFilter.GaussianBlur(40))
        return _VIGNETTE


def grab_frame(ffmpeg: str, src: str, t: float) -> Image.Image | None:
    cmd = [ffmpeg, '-hide_banner', '-nostdin', '-v', 'error', '-ss', f'{t:.3f}', '-i', src, '-frames:v', '1',
           '-vf', 'scale=960:-2:flags=bicubic', '-f', 'image2pipe', '-c:v', 'png', '-']
    try:
        r = run(cmd, timeout=90, capture_bytes=True)
    except subprocess.TimeoutExpired:
        return None
    if r.returncode != 0 or not r.stdout:
        return None
    try:
        im = Image.open(io.BytesIO(r.stdout))
        im.load()
        return im.convert('RGB')
    except Exception:
        return None


def make_backdrop(ffmpeg: str, src: str, out: str, info: dict) -> dict:
    d = info['duration']
    if d and d > 1:
        times = [d * f for f in (0.35, 0.30, 0.40, 0.25, 0.45, 0.55)]
    else:
        times = [3.0, 1.0, 0.0]
    best, best_var, best_t = None, -1.0, None
    for t in times:
        im = grab_frame(ffmpeg, src, max(0.0, min(t, d - 0.5) if d > 1 else t))
        if im is None:
            continue
        var = ImageStat.Stat(im.convert('L')).var[0]
        if var > best_var:
            best, best_var, best_t = im, var, t
    if best is None:
        raise RuntimeError('could not read any frame')
    # cover-scale to half size, blur there (radius 9 at half = ~18 at full), then up to 1920x1080
    half = cover(best, BD_W // 2, BD_H // 2)
    half = half.filter(ImageFilter.GaussianBlur(9))
    img = half.resize((BD_W, BD_H), Image.BICUBIC)
    img = ImageEnhance.Color(img).enhance(1.2)
    img = ImageEnhance.Brightness(img).enhance(0.55)
    vm = vignette_mask()
    img = Image.composite(img, Image.new('RGB', img.size, (0, 0, 0)), vm)
    img.save(out, 'JPEG', quality=85, progressive=True, optimize=True)
    return {'frame_t': round(best_t, 2), 'variance': round(best_var, 1)}


def cover(im: Image.Image, w: int, h: int) -> Image.Image:
    sw, sh = im.size
    f = max(w / sw, h / sh)
    nw, nh = max(w, int(round(sw * f))), max(h, int(round(sh * f)))
    im = im.resize((nw, nh), Image.LANCZOS)
    left, top = (nw - w) // 2, (nh - h) // 2
    return im.crop((left, top, left + w, top + h))


# ----------------------------------------------------------------------------------------------------- scan
def discover(root: str, wanted: set[str] | None) -> list[dict]:
    coll_root = os.path.join(root, 'collections')
    items = []
    for name in sorted(os.listdir(coll_root), key=str.lower):
        low = name.lower()
        if low.startswith('_') or low.startswith('zzz') or low in SKIP_NAMES:
            continue
        if wanted is not None and low not in wanted:
            continue
        vdir = os.path.join(coll_root, name, 'medium_artwork', 'video')
        if not os.path.isdir(vdir):
            continue
        by_item: dict[str, str] = {}
        for fn in os.listdir(vdir):
            base, ext = os.path.splitext(fn)
            ext = ext.lower()
            if ext not in VIDEO_EXTS:
                continue
            prev = by_item.get(base.lower())
            if prev is None or VIDEO_EXTS.index(ext) < VIDEO_EXTS.index(os.path.splitext(prev)[1].lower()):
                by_item[base.lower()] = fn
        for fn in sorted(by_item.values(), key=str.lower):
            items.append({'collection': name, 'item': os.path.splitext(fn)[0], 'src': os.path.join(vdir, fn),
                          'ma': os.path.join(coll_root, name, 'medium_artwork')})
    return items


def up_to_date(out: str, src_mtime: float) -> bool:
    try:
        return os.path.getmtime(out) >= src_mtime and os.path.getsize(out) > 0
    except OSError:
        return False


# ----------------------------------------------------------------------------------------------------- main
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--retrofe', default=DEFAULT_RETROFE)
    ap.add_argument('--collections', help='comma-separated collection names')
    ap.add_argument('--limit', type=int, default=0, help='process at most N videos')
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--only', choices=['video', 'backdrop'])
    ap.add_argument('--force', action='store_true')
    ap.add_argument('--jobs', type=int, default=0, help='parallel jobs (default 3 NVENC, 4 x264)')
    ap.add_argument('--ffmpeg', help='ffmpeg.exe or its folder')
    ap.add_argument('--encoder', choices=['auto', 'nvenc', 'x264'], default='auto')
    ap.add_argument('--manifest', default=MANIFEST_DIR)
    ap.add_argument('--max-minutes', type=float, default=0,
                    help='start no new conversion after N minutes (the rest continue next run); 0 = no limit')
    a = ap.parse_args()

    t0 = time.time()
    root = os.path.abspath(a.retrofe)
    if on_forbidden_drive(root):
        sys.exit(f'refusing: {root} resolves onto a forbidden drive')
    if on_forbidden_drive(a.manifest):
        sys.exit(f'refusing: {a.manifest} resolves onto a forbidden drive')
    ffmpeg, ffprobe_exe = find_ffmpeg(a.ffmpeg)

    if a.encoder == 'x264':
        encoder = 'x264'
    else:
        ok = nvenc_works(ffmpeg)
        if a.encoder == 'nvenc' and not ok:
            sys.exit('NVENC requested but h264_nvenc does not work here')
        encoder = 'nvenc' if ok else 'x264'
    jobs = a.jobs or (3 if encoder == 'nvenc' else 4)
    enc_label = 'h264_nvenc' if encoder == 'nvenc' else 'libx264 -preset veryfast'

    wanted = {c.strip().lower() for c in a.collections.split(',')} if a.collections else None
    items = discover(root, wanted)
    if a.limit:
        items = items[:a.limit]
    do_video = a.only in (None, 'video')
    do_bd = a.only in (None, 'backdrop')
    print(f'ffmpeg:   {ffmpeg}')
    print(f'encoder:  {enc_label}   jobs: {jobs}   videos: {len(items)}'
          f'{"   (DRY RUN)" if a.dry_run else ""}', flush=True)

    # prepare (and safety-check) the output folders
    dirs_ok: dict[str, str | None] = {}
    for ma in sorted({it['ma'] for it in items}):
        err = None
        try:
            for sub in (['am_video'] if do_video else []) + (['am_backdrop'] if do_bd else []):
                d = os.path.join(ma, sub)
                if a.dry_run:
                    check_write_dir(ma, root)
                    if os.path.lexists(d):
                        check_write_dir(d, root)
                else:
                    ensure_out_dir(d, root)
                    for fn in os.listdir(d):          # clear .part leftovers from a killed run
                        if '.part.' in fn:
                            try:
                                os.remove(os.path.join(d, fn))
                            except OSError:
                                pass
        except Unsafe as e:
            err = str(e)
            print(f'REFUSED {ma}: {err}', flush=True)
        dirs_ok[ma] = err

    # ---- stand-ins first: the layout plays am_video (type="am_video") and RetroFE cannot fall back to another video
    # type, so EVERY game needs a file there before any conversion starts. A stand-in is the original video itself:
    # a hard link (same drive, no space) or a copy (the original is on another drive, e.g. behind a junction).
    # Stand-ins have the original's size, so the conversion below still picks them up - now or on a later run.
    standins = 0
    if do_video and not a.dry_run:
        for it in items:
            if dirs_ok.get(it['ma']):
                continue
            ov = os.path.join(it['ma'], 'am_video', it['item'] + '.mp4')
            if os.path.exists(ov):
                continue
            try:
                check_write_file(ov, root)
                part = ov[:-4] + '.part.mp4'
                try:
                    os.link(it['src'], part)
                except OSError:
                    shutil.copyfile(it['src'], part)
                os.replace(part, ov)
                standins += 1
            except Exception as e:
                print(f'stand-in failed for {it["collection"]} / {it["item"]}: {e}', flush=True)
        if standins:
            print(f'stand-ins: {standins} game(s) got their original video in am_video until converted', flush=True)
    deadline = (t0 + a.max_minutes * 60) if a.max_minutes else 0

    def is_standin(ov: str, src_size: int) -> bool:
        try:
            return os.path.getsize(ov) == src_size
        except OSError:
            return False

    lock = threading.Lock()
    # --jobs caps the concurrent video encodes (NVENC sessions); two extra workers keep the CPU-side work
    # (probing, backdrop frames, Pillow) going while the encoder slots are busy.
    enc_sem = threading.Semaphore(jobs)
    workers = jobs + 2
    done_n = [0]
    results = []

    def work(it: dict) -> dict:
        rec = {'collection': it['collection'], 'item': it['item'], 'src': it['src']}
        if dirs_ok.get(it['ma']):
            rec['error'] = 'refused: ' + dirs_ok[it['ma']]
            return rec
        src = it['src']
        try:
            st = os.stat(src)
            rec['src_bytes'] = st.st_size
            ov = os.path.join(it['ma'], 'am_video', it['item'] + '.mp4')
            ob = os.path.join(it['ma'], 'am_backdrop', it['item'] + '.jpg')
            need_v = do_video and (a.force or not up_to_date(ov, st.st_mtime) or is_standin(ov, st.st_size))
            need_b = do_bd and (a.force or not up_to_date(ob, st.st_mtime))
            if deadline and time.time() > deadline and (need_v or need_b):
                rec['video'] = rec['backdrop'] = 'later'    # time budget used up: the next run continues here
                return rec
            rec['video'] = ('todo' if need_v else 'skip') if do_video else None
            rec['backdrop'] = ('todo' if need_b else 'skip') if do_bd else None
            info = None
            if need_v or need_b:                    # up to date: no probing (a re-run of 1,700 games takes seconds)
                info = media_info(ffprobe(ffprobe_exe, src), st.st_size)
                rec['src_info'] = {k: info[k] for k in ('vcodec', 'width', 'height', 'fps', 'duration',
                                                       'vbitrate', 'bitrate', 'acodec')}
                # a stand-in of a source that is already light (<=1280 wide, low bitrate) is as good as a remux
                if need_v and not a.force and info and can_copy(info) and is_standin(ov, st.st_size):
                    need_v = False
                    rec['video'] = 'skip'
            if a.dry_run:
                if need_v and info:
                    rec['video'] = 'would-copy' if can_copy(info) else f'would-encode {target_size(info)}'
                return rec
            if need_v:
                check_write_file(ov, root)
                part = ov[:-4] + '.part.mp4'
                cmd, mode = video_cmd(ffmpeg, src, part, info, encoder)
                with enc_sem:
                    r = run(cmd, timeout=1800)
                if r.returncode != 0 or not os.path.isfile(part) or os.path.getsize(part) == 0:
                    if mode == 'copy':          # remux refused (odd stream) - encode instead
                        info2 = dict(info, vcodec='force-encode')
                        cmd, mode = video_cmd(ffmpeg, src, part, info2, encoder)
                        with enc_sem:
                            r = run(cmd, timeout=1800)
                    if r.returncode != 0 or not os.path.isfile(part) or os.path.getsize(part) == 0:
                        if os.path.exists(part):
                            os.remove(part)
                        tail = ' | '.join((r.stderr or '').strip().splitlines()[-3:])
                        # the stand-in (the original video) stays in am_video, so the game still shows a video
                        raise RuntimeError(f'ffmpeg video failed (original kept as the preview): {tail}')
                os.replace(part, ov)
                rec['video'] = mode
            if need_b:
                check_write_file(ob, root)
                part = ob[:-4] + '.part.jpg'
                try:
                    rec['backdrop_info'] = make_backdrop(ffmpeg, src, part, info)
                    os.replace(part, ob)
                except Exception as e:
                    if os.path.exists(part):
                        os.remove(part)
                    raise RuntimeError(f'backdrop failed: {e}')
                rec['backdrop'] = 'made'
            if do_video and os.path.isfile(ov):
                rec['out_bytes'] = os.path.getsize(ov)
            if do_video and os.path.isfile(ov) and rec.get('video') not in ('skip', None):
                try:
                    oi = media_info(ffprobe(ffprobe_exe, ov), rec['out_bytes'])
                    rec['out_info'] = {k: oi[k] for k in ('vcodec', 'width', 'height', 'fps', 'duration',
                                                         'vbitrate', 'bitrate', 'acodec')}
                except Exception as e:
                    rec['out_info'] = {'error': str(e)}
            if do_bd and os.path.isfile(ob):
                rec['backdrop_bytes'] = os.path.getsize(ob)
        except Exception as e:
            rec['error'] = str(e)
        return rec

    try:
        with ThreadPoolExecutor(max_workers=workers) as ex:
            futs = [ex.submit(work, it) for it in items]
            for f in as_completed(futs):
                rec = f.result()
                with lock:
                    results.append(rec)
                    done_n[0] += 1
                    n = done_n[0]
                if rec.get('error') or n % 25 == 0 or n == len(items) or a.dry_run:
                    el = time.time() - t0
                    tag = 'FAIL ' + rec['error'] if rec.get('error') else f'v={rec.get("video")} b={rec.get("backdrop")}'
                    print(f'[{n}/{len(items)} {el/60:5.1f}m] {rec["collection"]} / {rec["item"]}: {tag}', flush=True)
    except KeyboardInterrupt:
        print('interrupted', flush=True)
        return 130

    elapsed = time.time() - t0
    results.sort(key=lambda r: (r['collection'].lower(), r['item'].lower()))

    # ---- summary
    per = {}
    for r in results:
        c = per.setdefault(r['collection'], {'videos': 0, 'encoded': 0, 'copied': 0, 'video_skipped': 0,
                                             'backdrops_made': 0, 'backdrop_skipped': 0, 'failed': 0,
                                             'src_bytes': 0, 'out_bytes': 0, 'backdrop_bytes': 0})
        c['videos'] += 1
        v = r.get('video')
        c['encoded'] += v in ('nvenc', 'x264')
        c['copied'] += v == 'copy'
        c['video_skipped'] += v == 'skip'
        c['backdrops_made'] += r.get('backdrop') == 'made'
        c['backdrop_skipped'] += r.get('backdrop') == 'skip'
        c['failed'] += bool(r.get('error'))
        c['src_bytes'] += r.get('src_bytes', 0)
        c['out_bytes'] += r.get('out_bytes', 0)
        c['backdrop_bytes'] += r.get('backdrop_bytes', 0)

    src_b_with_out = sum(r.get('src_bytes', 0) for r in results if r.get('out_bytes'))
    out_b = sum(r.get('out_bytes', 0) for r in results)
    out_dur = sum((r.get('out_info') or {}).get('duration') or 0 for r in results if r.get('out_bytes'))
    avg_kbps = (out_b * 8 / out_dur / 1000) if out_dur else 0
    totals = {k: sum(c[k] for c in per.values()) for k in
              ('videos', 'encoded', 'copied', 'video_skipped', 'backdrops_made', 'backdrop_skipped', 'failed',
               'src_bytes', 'out_bytes', 'backdrop_bytes')}

    print()
    hdr = f'{"collection":34} {"videos":>6} {"enc":>5} {"copy":>5} {"skipV":>5} {"bdrop":>5} {"skipB":>5} {"fail":>4} {"srcGB":>7} {"outGB":>7}'
    print(hdr)
    for name, c in sorted(per.items(), key=lambda kv: kv[0].lower()):
        print(f'{name[:34]:34} {c["videos"]:6} {c["encoded"]:5} {c["copied"]:5} {c["video_skipped"]:5} '
              f'{c["backdrops_made"]:5} {c["backdrop_skipped"]:5} {c["failed"]:4} '
              f'{c["src_bytes"]/1e9:7.2f} {c["out_bytes"]/1e9:7.2f}')
    t = totals
    print(f'{"TOTAL":34} {t["videos"]:6} {t["encoded"]:5} {t["copied"]:5} {t["video_skipped"]:5} '
          f'{t["backdrops_made"]:5} {t["backdrop_skipped"]:5} {t["failed"]:4} '
          f'{t["src_bytes"]/1e9:7.2f} {t["out_bytes"]/1e9:7.2f}')
    print(f'\nsource {src_b_with_out/1e9:.2f} GB -> preview videos {out_b/1e9:.2f} GB'
          f'  (+ backdrops {t["backdrop_bytes"]/1e9:.2f} GB)')
    print(f'average preview bitrate: {avg_kbps:.0f} kbps   encoder: {enc_label}   jobs: {jobs}'
          f'   elapsed: {elapsed/60:.1f} min')

    if a.dry_run:
        return 0

    os.makedirs(a.manifest, exist_ok=True)
    fails = [r for r in results if r.get('error')]
    with open(os.path.join(a.manifest, 'preview-media-failures.txt'), 'w', encoding='utf-8') as fh:
        fh.write(f'# New-PreviewMedia.py failures, {time.strftime("%Y-%m-%d %H:%M:%S")}, {len(fails)} item(s)\n')
        for r in fails:
            fh.write(f'{r["collection"]}\t{r["item"]}\t{r["src"]}\t{r["error"]}\n')
    report = {
        'generated': time.strftime('%Y-%m-%dT%H:%M:%S'), 'retrofe': root, 'ffmpeg': ffmpeg,
        'encoder': enc_label, 'jobs': jobs, 'elapsed_s': round(elapsed, 1),
        'args': {k: v for k, v in vars(a).items()},
        'totals': dict(totals, source_bytes_with_output=src_b_with_out, avg_out_kbps=round(avg_kbps)),
        'collections': per, 'items': results,
    }
    tmp = os.path.join(a.manifest, 'preview-media.json.part')
    with open(tmp, 'w', encoding='utf-8') as fh:
        json.dump(report, fh, indent=1)
    os.replace(tmp, os.path.join(a.manifest, 'preview-media.json'))
    print(f'failures: {len(fails)}  ->  {os.path.join(a.manifest, "preview-media-failures.txt")}')
    return 1 if fails and len(fails) == len(results) else 0


if __name__ == '__main__':
    sys.exit(main())
