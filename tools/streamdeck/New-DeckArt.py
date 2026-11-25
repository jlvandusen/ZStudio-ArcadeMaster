#!/usr/bin/env python3
"""
New-DeckArt.py
==============
Generates animated APNG key art for the ArcadeMaster Stream Deck.
Neon synthwave style on black.  Pillow only, fully deterministic.

Usage
-----
    python New-DeckArt.py                        # art/ at 72px
    python New-DeckArt.py --out art --size 72
    python New-DeckArt.py --preview sheet.png    # + 2x and 1x contact sheets
"""
from __future__ import annotations

import argparse
import math
import os
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageFilter

# ═══════════════════════════════════════════════════════════════════════════
#  PATHS
# ═══════════════════════════════════════════════════════════════════════════
SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT  = SCRIPT_DIR.parent.parent
FONT_PATH  = str(REPO_ROOT / "layouts" / "ArcadeMaster" / "fonts" / "OpenSans.ttf")
LOGO_PATH  = str(REPO_ROOT / "layouts" / "ArcadeMaster" / "images" / "studio_realz.png")

# ═══════════════════════════════════════════════════════════════════════════
#  PALETTE
# ═══════════════════════════════════════════════════════════════════════════
P1  = (255,  59,  59)
P2  = ( 46, 139, 255)
P3  = ( 61, 220, 132)
P4  = (255, 204,   0)
MAG = (255,  43, 214)
CYN = ( 46, 200, 255)
ORA = (255, 138,   0)
GRY = (154, 164, 178)
RED = (255,  77,  77)
BLU = ( 74, 168, 255)
BLK = (0, 0, 0)
PLAYERS = {1: P1, 2: P2, 3: P3, 4: P4}

# ═══════════════════════════════════════════════════════════════════════════
#  HELPERS
# ═══════════════════════════════════════════════════════════════════════════
def rgba(rgb, alpha=255):
    return (*rgb, int(alpha))

def lerp(a, b, t):
    return a + (b - a) * t

def ease(t):
    return (math.sin(t * 2 * math.pi - math.pi / 2) + 1) / 2

_fonts: dict = {}
def fnt(sz):
    if sz not in _fonts:
        try:    _fonts[sz] = ImageFont.truetype(FONT_PATH, sz)
        except: _fonts[sz] = ImageFont.load_default()
    return _fonts[sz]

def twh(d, txt, f):
    bb = d.textbbox((0, 0), txt, font=f)
    return bb[2] - bb[0], bb[3] - bb[1]

# ═══════════════════════════════════════════════════════════════════════════
#  FRAME COMPOSITION  (labels: 13-14 px, bright, 1 px dark outline)
# ═══════════════════════════════════════════════════════════════════════════
def build_frame(S, color, icon_fn, *, label=None, label2=None,
                glow_r=4, glow_boost=1.4, lbl_sz=None, border=True):
    if lbl_sz is None:
        lbl_sz = max(12, int(S * 0.18))          # 13 at S=72
    bg = Image.new("RGBA", (S, S), (*BLK, 255))
    # -- glow --
    gl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    icon_fn(ImageDraw.Draw(gl), S, color)
    gl = gl.filter(ImageFilter.GaussianBlur(glow_r))
    if glow_boost != 1.0:
        r, g, b, a = gl.split()
        a = a.point(lambda x: min(255, int(x * glow_boost)))
        gl = Image.merge("RGBA", (r, g, b, a))
    bg = Image.alpha_composite(bg, gl)
    # -- crisp --
    cr = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    icon_fn(ImageDraw.Draw(cr), S, color)
    bg = Image.alpha_composite(bg, cr)
    # -- border --
    if border:
        br = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        ImageDraw.Draw(br).rounded_rectangle(
            [2, 2, S - 3, S - 3], radius=max(4, S // 9),
            outline=rgba(color, 100), width=max(1, S // 36))
        bg = Image.alpha_composite(bg, br)
    # -- label with dark outline for readability --
    if label:
        tl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        td = ImageDraw.Draw(tl)
        f = fnt(lbl_sz)
        def _out(text, tx, ty):
            for dx, dy in [(-1,0),(1,0),(0,-1),(0,1)]:
                td.text((tx+dx, ty+dy), text, fill=rgba(BLK, 220), font=f)
            td.text((tx, ty), text, fill=rgba(color, 255), font=f)
        if label2:
            w1, h1 = twh(td, label, f)
            w2, h2 = twh(td, label2, f)
            y0 = S - h1 - h2 - max(4, S // 16)
            _out(label,  (S - w1) // 2, y0)
            _out(label2, (S - w2) // 2, y0 + h1 + 1)
        else:
            wt, ht = twh(td, label, f)
            ty = S - ht - max(3, S // 18)
            _out(label, (S - wt) // 2, ty)
        tg = tl.filter(ImageFilter.GaussianBlur(2))
        bg = Image.alpha_composite(bg, tg)
        bg = Image.alpha_composite(bg, tl)
    return bg

# ═══════════════════════════════════════════════════════════════════════════
#  SAVE / OPTIMISE
# ═══════════════════════════════════════════════════════════════════════════
def _quant(frame, colors=64):
    rgb = frame.convert("RGB").quantize(colors, method=Image.Quantize.MEDIANCUT).convert("RGB")
    out = rgb.convert("RGBA"); out.putalpha(frame.split()[3])
    return out

def save_apng(frames, path, duration, quant_colors=64):
    path = str(path)
    qf = [_quant(f, quant_colors) for f in frames]
    if len(qf) == 1:
        qf[0].save(path, "PNG", optimize=True)
    else:
        qf[0].save(path, save_all=True, append_images=qf[1:],
                    duration=duration, loop=0, optimize=True)

def save_opt(frames, path, duration, max_kb=25):
    save_apng(frames, path, duration, 64)
    if os.path.getsize(str(path)) > max_kb * 1024:
        save_apng(frames, path, duration, 32)
    if os.path.getsize(str(path)) > max_kb * 1024:
        save_apng(frames, path, duration, 20)

def dim_frames(frames, factor=0.35):
    f = frames[0].copy()
    r, g, b, a = f.split()
    r = r.point(lambda x: int(x * factor))
    g = g.point(lambda x: int(x * factor))
    b = b.point(lambda x: int(x * factor))
    return [Image.merge("RGBA", (r, g, b, a))]

# ═══════════════════════════════════════════════════════════════════════════
#  SHAPE PRIMITIVES  (stroke width 4 px at S=72)
# ═══════════════════════════════════════════════════════════════════════════
SW = lambda s: max(4, s // 18)                    # stroke width helper

def thick_poly(d, pts, color, width=4):
    for i in range(len(pts)):
        d.line([pts[i], pts[(i + 1) % len(pts)]], fill=color, width=width)

def gear_pts(cx, cy, r_out, r_in, n, ang_off=0):
    pts = []
    for i in range(n):
        a0 = ang_off + i * 2 * math.pi / n
        step = 2 * math.pi / n
        pts.append((cx + r_in * math.cos(a0), cy + r_in * math.sin(a0)))
        a1 = a0 + step * 0.2
        pts.append((cx + r_out * math.cos(a1), cy + r_out * math.sin(a1)))
        a2 = a0 + step * 0.5
        pts.append((cx + r_out * math.cos(a2), cy + r_out * math.sin(a2)))
        a3 = a0 + step * 0.7
        pts.append((cx + r_in * math.cos(a3), cy + r_in * math.sin(a3)))
    return [(int(x), int(y)) for x, y in pts]

def draw_speaker(d, cx, cy, s, color, w):
    bw = max(5, int(s * 0.08))
    bh = max(8, int(s * 0.13))
    lx = cx - int(s * 0.24)
    d.rectangle([lx, cy - bh, lx + 2 * bw, cy + bh], fill=rgba(color, 255))
    cone_end = lx + 2 * bw + int(s * 0.19)
    cone_h = int(s * 0.19)
    d.polygon([(lx + 2 * bw, cy - bh), (cone_end, cy - cone_h),
               (cone_end, cy + cone_h), (lx + 2 * bw, cy + bh)],
              fill=rgba(color, 200))
    return cone_end

def draw_waves(d, x0, cy, s, color, w, count=3):
    for i in range(count):
        r = int(s * 0.09) * (i + 1) + int(s * 0.03)
        al = max(80, 255 - i * 50)
        d.arc([x0 + 3, cy - r, x0 + 3 + 2 * r, cy + r], -50, 50,
              fill=rgba(color, al), width=w)

_ECG = [(0,.0),(.35,.0),(.38,.15),(.42,.0),(.45,.0),(.47,-.12),
        (.49,.95),(.52,-.28),(.55,.0),(.62,.0),(.65,.2),(.72,.0),(1,.0)]
def ecg_y(x):
    x = x % 1.0
    for i in range(len(_ECG) - 1):
        x0, y0 = _ECG[i]; x1, y1 = _ECG[i + 1]
        if x0 <= x < x1:
            t2 = (x - x0) / (x1 - x0) if x1 > x0 else 0
            return y0 + (y1 - y0) * t2
    return 0.0

# ═══════════════════════════════════════════════════════════════════════════
#  ICON GENERATORS   -- each returns (frames, duration)
#  All icons fill ~80 % of the key.  Stroke width 4 px at S=72.
# ═══════════════════════════════════════════════════════════════════════════

# -- logo ------------------------------------------------------------------
def gen_logo(S):
    nf = 9
    try:
        logo_src = Image.open(LOGO_PATH).convert("RGBA")
    except Exception:
        return _logo_fallback(S)
    mx = int(S * 0.88)
    logo_src.thumbnail((mx, mx), Image.LANCZOS)
    lw, lh = logo_src.size
    ox, oy = (S - lw) // 2, (S - lh) // 2
    frames = []
    for i in range(nf):
        frame = Image.new("RGBA", (S, S), (*BLK, 255))
        frame.paste(logo_src, (ox, oy), logo_src)
        if i >= 5:
            sp = int(lerp(-25, S + 25, (i - 5) / 4))
            sw = Image.new("RGBA", (S, S), (0, 0, 0, 0))
            ImageDraw.Draw(sw).line([(sp + 25, 0), (0, sp + 25)],
                                    fill=(255, 255, 255, 70), width=14)
            sw = sw.filter(ImageFilter.GaussianBlur(6))
            frame = Image.alpha_composite(frame, sw)
        br = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        ImageDraw.Draw(br).rounded_rectangle(
            [2, 2, S - 3, S - 3], radius=max(4, S // 9),
            outline=rgba(CYN, 80), width=max(1, S // 36))
        frame = Image.alpha_composite(frame, br)
        frames.append(frame)
    return frames, [400] * 5 + [80] * 4

def _logo_fallback(S):
    def draw(d, s, c):
        f = fnt(max(14, int(s * 0.32)))
        w, h = twh(d, "RZ", f)
        d.text(((s - w) // 2, (s - h) // 2), "RZ", fill=rgba(c, 255), font=f)
    return [build_frame(S, CYN, draw)], 100

# -- themes (3 clearly fanned overlapping cards) --------------------------
def gen_themes(S):
    nf = 10; color = MAG; frames = []
    for i in range(nf):
        t = i / nf
        fan = 18 + 10 * math.sin(t * 2 * math.pi)   # always fanned 8-28 deg
        def draw(d, s, c, _fan=fan):
            cx, cy = s // 2, int(s * 0.34)
            cw = int(s * 0.13); ch = int(s * 0.23)   # card half-dims
            w = SW(s)
            for idx, angle in enumerate([-_fan, 0, _fan]):
                rad = math.radians(angle)
                al = 140 + idx * 55
                ox = int(8 * math.sin(rad))
                corners = []
                for dx, dy in [(-cw, -ch), (cw, -ch), (cw, ch), (-cw, ch)]:
                    rx = int(dx * math.cos(rad) - dy * math.sin(rad))
                    ry = int(dx * math.sin(rad) + dy * math.cos(rad))
                    corners.append((cx + ox + rx, cy + ry))
                thick_poly(d, corners, rgba(c, al), w)
                # Content hint lines inside front card
                if idx == 2 and abs(angle) < 22:
                    for li in range(-1, 2):
                        ly = cy + li * 6
                        hw = int(cw * 0.5)
                        d.line([(cx + ox - hw, ly), (cx + ox + hw, ly)],
                               fill=rgba(c, al // 3), width=1)
        frames.append(build_frame(S, color, draw, label="THEMES"))
    return frames, 100

# -- screen2 ---------------------------------------------------------------
def gen_screen2(S):
    nf = 10; color = CYN; frames = []
    for i in range(nf):
        t = i / nf; a2 = int(60 + 195 * ease(t))
        def draw(d, s, c, _a2=a2):
            cy = int(s * 0.32); w = SW(s)
            mw, mh = int(s * 0.24), int(s * 0.20)
            gap = int(s * 0.03)
            x1 = s // 2 - gap - mw
            d.rounded_rectangle([x1, cy - mh, x1 + mw, cy + mh], radius=2,
                                outline=rgba(c, 255), width=w)
            d.line([(x1 + mw // 2, cy + mh), (x1 + mw // 2, cy + mh + 5)],
                   fill=rgba(c, 255), width=w)
            x2 = s // 2 + gap
            d.rounded_rectangle([x2, cy - mh, x2 + mw, cy + mh], radius=2,
                                outline=rgba(c, _a2), width=w)
            d.line([(x2 + mw // 2, cy + mh), (x2 + mw // 2, cy + mh + 5)],
                   fill=rgba(c, _a2), width=w)
        frames.append(build_frame(S, color, draw, label="2ND SCR"))
    return frames, 100

# -- shuffle ---------------------------------------------------------------
def gen_shuffle(S):
    nf = 10; color = P4; frames = []
    for i in range(nf):
        t = i / nf
        offset = math.sin(t * 2 * math.pi) * int(S * 0.16)
        def draw(d, s, c, _off=offset):
            cy = int(s * 0.34); w = SW(s)
            fw, fh = int(s * 0.17), int(s * 0.21)
            cx = s // 2
            ax = int(cx - int(s * 0.08) + _off)
            bx = int(cx + int(s * 0.08) - _off)
            ay_off = int(abs(_off) * 0.3)
            d.rounded_rectangle([ax - fw, cy - fh - ay_off, ax + fw, cy + fh - ay_off],
                                radius=3, outline=rgba(c, 255), width=w)
            d.line([(ax - fw + 4, cy - 4 - ay_off), (ax + fw - 4, cy - 4 - ay_off)],
                   fill=rgba(c, 100), width=1)
            d.rounded_rectangle([bx - fw, cy - fh + ay_off, bx + fw, cy + fh + ay_off],
                                radius=3, outline=rgba(c, 200), width=w)
        frames.append(build_frame(S, color, draw, label="SHUFFLE"))
    return frames, 100

# -- restart ---------------------------------------------------------------
def gen_restart(S):
    nf = 12; color = ORA; frames = []
    for i in range(nf):
        ao = i * 30
        def draw(d, s, c, _ao=ao):
            cx, cy = s // 2, int(s * 0.35)
            r = int(s * 0.24); w = SW(s)
            start = _ao + 40; end = _ao + 320
            d.arc([cx - r, cy - r, cx + r, cy + r], start, end,
                  fill=rgba(c, 255), width=w)
            er = math.radians(end)
            ex, ey = cx + r * math.cos(er), cy + r * math.sin(er)
            tng = er - math.pi / 2
            al = int(s * 0.10)
            for sp in [-0.5, 0.5]:
                bx = ex + al * math.cos(tng + math.pi + sp)
                by = ey + al * math.sin(tng + math.pi + sp)
                d.line([(int(ex), int(ey)), (int(bx), int(by))],
                       fill=rgba(c, 255), width=w)
        frames.append(build_frame(S, color, draw, label="RESTART"))
    return frames, 80

# -- volume ----------------------------------------------------------------
def gen_volume(S, mode="down"):
    color = GRY; nf = 8; frames = []
    for i in range(nf):
        t = i / nf
        def draw(d, s, c, _t=t, _mode=mode):
            cx_spk = s // 2 - int(s * 0.08)
            cy = int(s * 0.34); w = SW(s)
            wav_x = draw_speaker(d, cx_spk, cy, s, c, w)
            if _mode == "down":
                draw_waves(d, wav_x, cy, s, c, w, max(0, int(2.5 - 2 * ease(_t))))
            elif _mode == "up":
                draw_waves(d, wav_x, cy, s, c, w, int(1 + 2 * ease(_t)))
            else:
                xsz = int(s * 0.12)
                pulse = 1.0 + 0.15 * math.sin(_t * 2 * math.pi)
                xs = int(xsz * pulse)
                xc = wav_x + int(s * 0.14)
                d.line([(xc - xs, cy - xs), (xc + xs, cy + xs)],
                       fill=rgba(RED, 255), width=w + 1)
                d.line([(xc + xs, cy - xs), (xc - xs, cy + xs)],
                       fill=rgba(RED, 255), width=w + 1)
        lbl = {"down": "VOL -", "up": "VOL +", "mute": "MUTE"}[mode]
        frames.append(build_frame(S, color, draw, label=lbl))
    return frames, 120

# -- light -----------------------------------------------------------------
def gen_light(S):
    nf = 10; color = GRY; frames = []
    for i in range(nf):
        t = i / nf
        rl = 1.0 + 0.4 * math.sin(t * 2 * math.pi)
        def draw(d, s, c, _rl=rl):
            cx, cy = s // 2, int(s * 0.33)
            r = int(s * 0.12); w = SW(s)
            d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=rgba(c, 255), width=w)
            for j in range(8):
                ang = j * math.pi / 4
                x1 = cx + int((r + 3) * math.cos(ang))
                y1 = cy + int((r + 3) * math.sin(ang))
                rr = int(s * 0.10 * _rl)
                x2 = cx + int((r + 3 + rr) * math.cos(ang))
                y2 = cy + int((r + 3 + rr) * math.sin(ang))
                d.line([(x1, y1), (x2, y2)], fill=rgba(c, 230), width=w)
        frames.append(build_frame(S, color, draw, label="LIGHT"))
    return frames, 100

# -- ingame ----------------------------------------------------------------
def gen_ingame(S):
    nf = 8; color = P3; frames = []
    for i in range(nf):
        t = i / nf; tilt = math.sin(t * 2 * math.pi) * 5
        def draw(d, s, c, _tilt=tilt):
            cx, cy = s // 2 - int(s * 0.06), int(s * 0.32)
            w = SW(s)
            bw, bh = int(s * 0.18), int(s * 0.07)
            d.ellipse([cx - bw, cy + 10 - bh, cx + bw, cy + 10 + bh],
                      outline=rgba(c, 200), width=w)
            d.line([(cx + int(_tilt), cy + 10 - bh),
                    (cx + int(_tilt * 0.3), cy - int(s * 0.18))],
                   fill=rgba(c, 255), width=w)
            br2 = int(s * 0.07)
            bx = cx + int(_tilt * 0.3)
            by = cy - int(s * 0.18) - br2
            d.ellipse([bx - br2, by - br2, bx + br2, by + br2],
                      fill=rgba(c, 200), outline=rgba(c, 255), width=w)
            # Arrow
            ax = cx + int(s * 0.26); ay = cy
            al = int(s * 0.10)
            d.line([(ax - al, ay), (ax + al, ay)], fill=rgba(c, 180), width=w)
            d.line([(ax + al - 5, ay - 5), (ax + al, ay)], fill=rgba(c, 180), width=w)
            d.line([(ax + al - 5, ay + 5), (ax + al, ay)], fill=rgba(c, 180), width=w)
        frames.append(build_frame(S, color, draw, label="KEYS"))
    return frames, 100

# -- detect ----------------------------------------------------------------
def gen_detect(S):
    nf = 10; color = CYN; frames = []
    for i in range(nf):
        t = i / nf; rp = t
        def draw(d, s, c, _rp=rp):
            cx, cy = s // 2, int(s * 0.34); w = SW(s)
            br2 = int(s * 0.05)
            d.ellipse([cx - br2 * 3, cy + 7 - br2, cx + br2 * 3, cy + 7 + br2],
                      outline=rgba(c, 180), width=w)
            d.line([(cx, cy + 7 - br2), (cx, cy - int(s * 0.12))],
                   fill=rgba(c, 255), width=w)
            d.ellipse([cx - br2 - 1, cy - int(s * 0.12) - br2 * 2,
                       cx + br2 + 1, cy - int(s * 0.12)], fill=rgba(c, 220))
            for j in range(3):
                rt = (_rp + j * 0.33) % 1.0
                rr = int(s * 0.10 + s * 0.20 * rt)
                al = int(200 * (1 - rt))
                if al > 10:
                    d.ellipse([cx - rr, cy - 2 - rr, cx + rr, cy - 2 + rr],
                              outline=rgba(c, al), width=max(2, w - 1))
        frames.append(build_frame(S, color, draw, label="DETECT"))
    return frames, 100

# -- rebuild (menus) -------------------------------------------------------
def gen_rebuild(S):
    nf = 10; color = CYN; frames = []
    for i in range(nf):
        progress = ((i + 7) % nf + 1) / nf
        def draw(d, s, c, _p=progress):
            cx = s // 2; cy_base = int(s * 0.12)
            w = max(3, s // 22)
            row_h = int(s * 0.10); row_w = int(s * 0.65)
            n_rows = 4; visible = _p * n_rows
            for j in range(n_rows):
                if j >= visible: break
                frac = min(1.0, visible - j)
                al = int(255 * frac)
                y = cy_base + j * (row_h + 4)
                x0 = cx - row_w // 2
                slide = int((1 - frac) * s * 0.3)
                d.rounded_rectangle([x0 + slide, y, x0 + row_w + slide, y + row_h],
                                    radius=2, outline=rgba(c, al), width=w)
                inner_w = int(row_w * (0.4 + j * 0.1))
                d.line([(x0 + 4 + slide, y + row_h // 2),
                        (x0 + 4 + inner_w + slide, y + row_h // 2)],
                       fill=rgba(c, al // 2), width=1)
        frames.append(build_frame(S, color, draw, label="MENUS"))
    return frames, 100

# -- health ----------------------------------------------------------------
def gen_health(S):
    nf = 12; color = P3; frames = []
    for i in range(nf):
        sc = i / nf
        def draw(d, s, c, _sc=sc):
            cx, cy = s // 2, int(s * 0.34)
            w = SW(s); tw2 = int(s * 0.82); th = int(s * 0.30)
            x0 = cx - tw2 // 2
            pts = []
            for px in range(tw2):
                xn = (px / tw2 + _sc) % 1.0
                pts.append((x0 + px, int(cy - ecg_y(xn) * th)))
            if len(pts) > 1:
                d.line(pts, fill=rgba(c, 255), width=w)
        frames.append(build_frame(S, color, draw, label="HEALTH"))
    return frames, 80

# -- perf ------------------------------------------------------------------
def gen_perf(S):
    nf = 10; color = GRY; frames = []
    for i in range(nf):
        t = i / nf
        def draw(d, s, c, _t=t):
            cy_bottom = int(s * 0.58); w_bar = max(6, int(s * 0.09))
            gap = max(2, int(s * 0.03)); n_bars = 5
            total_w = n_bars * w_bar + (n_bars - 1) * gap
            x0 = (s - total_w) // 2; max_h = int(s * 0.44)
            for j in range(n_bars):
                h = int(max_h * (0.3 + 0.7 * ease((_t + j * 0.18) % 1.0)))
                bx = x0 + j * (w_bar + gap)
                d.rectangle([bx, cy_bottom - h, bx + w_bar, cy_bottom],
                            fill=rgba(c, 200), outline=rgba(c, 255), width=1)
        frames.append(build_frame(S, color, draw, label="PERF"))
    return frames, 100

# -- coin (big coin + slot + player number on face) ------------------------
def gen_coin(S, player=1):
    color = PLAYERS[player]; nf = 10; frames = []
    for i in range(nf):
        t = i / nf
        squash = max(0.12, abs(math.cos(t * 2 * math.pi)))
        y_bob = int(3 * (1 - squash))
        def draw(d, s, c, _sq=squash, _yb=y_bob, _p=player):
            cx = s // 2; cy = int(s * 0.30) + _yb
            w = SW(s); ry = int(s * 0.24); rx = max(3, int(ry * _sq))
            d.ellipse([cx - rx, cy - ry, cx + rx, cy + ry],
                      outline=rgba(c, 255), width=w)
            # Slot below coin
            slot_y = cy + ry + 4; slot_w = int(s * 0.17)
            d.line([(cx - slot_w, slot_y), (cx + slot_w, slot_y)],
                   fill=rgba(c, 150), width=max(2, w - 1))
            # Player number on face when visible
            if _sq > 0.5:
                f2 = fnt(max(14, int(s * 0.24)))
                txt = f"{_p}P"
                tw2, th2 = twh(d, txt, f2)
                al = int(255 * min(1.0, (_sq - 0.5) * 4))
                d.text((cx - tw2 // 2, cy - th2 // 2), txt,
                       fill=rgba(c, al), font=f2)
            if _sq < 0.3:
                d.line([(cx, cy - ry + 2), (cx, cy + ry - 2)],
                       fill=rgba(c, 200), width=w)
        frames.append(build_frame(S, color, draw, label="COIN"))
    return frames, 80

# -- start -----------------------------------------------------------------
def gen_start(S, player=1):
    color = PLAYERS[player]; nf = 10; frames = []
    for i in range(nf):
        t = i / nf
        pulse = 1.0 + 0.12 * math.sin(t * 2 * math.pi)
        press = max(0, math.sin(t * 2 * math.pi))
        def draw(d, s, c, _pulse=pulse, _press=press, _p=player):
            cx, cy = s // 2, int(s * 0.34)
            r = int(s * 0.24 * _pulse); w = SW(s)
            d.ellipse([cx - r, cy - r, cx + r, cy + r],
                      outline=rgba(c, 255), width=w)
            d.ellipse([cx - r + 4, cy - r + 4, cx + r - 4, cy + r - 4],
                      fill=rgba(c, int(40 + 80 * _press)))
            f2 = fnt(max(13, int(s * 0.22)))
            txt = f"{_p}P"; tw2, th2 = twh(d, txt, f2)
            d.text((cx - tw2 // 2, cy - th2 // 2), txt,
                   fill=rgba(c, 240), font=f2)
        frames.append(build_frame(S, color, draw, label="START"))
    return frames, 100

# -- pause -----------------------------------------------------------------
def gen_pause(S):
    nf = 10; color = BLU; frames = []
    for i in range(nf):
        t = i / nf; sc = 1.0 + 0.08 * math.sin(t * 2 * math.pi)
        def draw(d, s, c, _sc=sc):
            cx, cy = s // 2, int(s * 0.35)
            bw = max(7, int(s * 0.10 * _sc))
            bh = max(14, int(s * 0.28 * _sc))
            gap = max(5, int(s * 0.08 * _sc))
            d.rounded_rectangle([cx - gap - bw, cy - bh, cx - gap, cy + bh],
                                radius=2, fill=rgba(c, 220))
            d.rounded_rectangle([cx + gap, cy - bh, cx + gap + bw, cy + bh],
                                radius=2, fill=rgba(c, 220))
        frames.append(build_frame(S, color, draw, label="PAUSE"))
    return frames, 100

# -- exit (X always visible, glow pulses) ----------------------------------
def gen_exit(S):
    nf = 10; color = RED; frames = []
    for i in range(nf):
        t = i / nf
        gp = 1.0 + 0.8 * math.sin(t * 2 * math.pi)
        def draw(d, s, c):
            cx, cy = s // 2, int(s * 0.35)
            r = int(s * 0.21); w = SW(s)
            d.line([(cx - r, cy - r), (cx + r, cy + r)], fill=rgba(c, 255), width=w)
            d.line([(cx + r, cy - r), (cx - r, cy + r)], fill=rgba(c, 255), width=w)
        frames.append(build_frame(S, color, draw, label="EXIT",
                                  glow_boost=max(0.5, gp)))
    return frames, 100

# -- save / load -----------------------------------------------------------
def gen_floppy(S, mode="save"):
    color = GRY; nf = 8; frames = []
    for i in range(nf):
        t = i / nf; ao = int(4 * math.sin(t * 2 * math.pi))
        def draw(d, s, c, _ao=ao, _mode=mode):
            cx, cy = s // 2, int(s * 0.31)
            w = SW(s); hw, hh = int(s * 0.21), int(s * 0.23)
            d.rounded_rectangle([cx - hw, cy - hh, cx + hw, cy + hh],
                                radius=3, outline=rgba(c, 255), width=w)
            nw2 = int(hw * 0.4)
            d.line([(cx + hw - nw2, cy - hh), (cx + hw - nw2, cy - hh + 5)],
                   fill=rgba(c, 140), width=max(2, w - 1))
            d.line([(cx + hw - nw2, cy - hh + 5), (cx + hw, cy - hh + 5)],
                   fill=rgba(c, 140), width=max(2, w - 1))
            ax = cx; al = int(s * 0.13)
            if _mode == "save":
                ay = cy + _ao
                d.line([(ax, ay - al), (ax, ay + al)], fill=rgba(c, 240), width=w)
                d.line([(ax - 5, ay + al - 5), (ax, ay + al)], fill=rgba(c, 240), width=w)
                d.line([(ax + 5, ay + al - 5), (ax, ay + al)], fill=rgba(c, 240), width=w)
            else:
                ay = cy - _ao
                d.line([(ax, ay + al), (ax, ay - al)], fill=rgba(c, 240), width=w)
                d.line([(ax - 5, ay - al + 5), (ax, ay - al)], fill=rgba(c, 240), width=w)
                d.line([(ax + 5, ay - al + 5), (ax, ay - al)], fill=rgba(c, 240), width=w)
        frames.append(build_frame(S, color, draw, label="SAVE" if mode == "save" else "LOAD"))
    return frames, 100

# -- service (gear) --------------------------------------------------------
def gen_service(S):
    nf = 10; color = GRY; frames = []
    for i in range(nf):
        ang = i * (2 * math.pi / 6) / nf
        def draw(d, s, c, _ang=ang):
            cx, cy = s // 2, int(s * 0.34)
            r_out = int(s * 0.26); r_in = int(s * 0.18); w = SW(s)
            thick_poly(d, gear_pts(cx, cy, r_out, r_in, 6, _ang), rgba(c, 255), w)
            cr2 = int(s * 0.06)
            d.ellipse([cx - cr2, cy - cr2, cx + cr2, cy + cr2],
                      outline=rgba(c, 200), width=w)
        frames.append(build_frame(S, color, draw, label="SERVICE"))
    return frames, 100

# -- test (wrench) ---------------------------------------------------------
def gen_test(S):
    nf = 8; color = GRY; frames = []
    for i in range(nf):
        t = i / nf; wb = math.sin(t * 2 * math.pi) * 15
        def draw(d, s, c, _wb=wb):
            cx, cy = s // 2, int(s * 0.35); w = SW(s)
            rad = math.radians(_wb); hl = int(s * 0.36)
            cr, sr = math.cos(rad), math.sin(rad)
            hbx, hby = cx - int(hl * 0.4 * sr), cy + int(hl * 0.4 * cr)
            htx, hty = cx + int(hl * 0.6 * sr), cy - int(hl * 0.6 * cr)
            d.line([(hbx, hby), (htx, hty)], fill=rgba(c, 255), width=w + 1)
            jr = int(s * 0.09)
            d.arc([htx - jr, hty - jr, htx + jr, hty + jr],
                  math.degrees(rad) - 60, math.degrees(rad) + 240,
                  fill=rgba(c, 255), width=w + 1)
            d.ellipse([hbx - 3, hby - 3, hbx + 3, hby + 3], fill=rgba(c, 180))
        frames.append(build_frame(S, color, draw, label="TEST"))
    return frames, 100

# -- chevron ---------------------------------------------------------------
def gen_chevron(S, direction="left", label=None):
    color = MAG; nf = 8; frames = []
    for i in range(nf):
        t = i / nf; sl = int(S * 0.05 * math.sin(t * 2 * math.pi))
        def draw(d, s, c, _sl=sl, _dir=direction, _lbl=label):
            cx = s // 2
            cy = int(s * 0.35) if _lbl else int(s * 0.46)
            w = SW(s)
            ch2 = int(s * 0.21) if _lbl else int(s * 0.28)
            cw2 = int(s * 0.13) if _lbl else int(s * 0.16)
            ox = _sl if _dir == "right" else -_sl
            if _dir == "left":
                d.line([(cx + cw2 + ox, cy - ch2), (cx - cw2 + ox, cy)],
                       fill=rgba(c, 255), width=w)
                d.line([(cx - cw2 + ox, cy), (cx + cw2 + ox, cy + ch2)],
                       fill=rgba(c, 255), width=w)
            else:
                d.line([(cx - cw2 + ox, cy - ch2), (cx + cw2 + ox, cy)],
                       fill=rgba(c, 255), width=w)
                d.line([(cx + cw2 + ox, cy), (cx - cw2 + ox, cy + ch2)],
                       fill=rgba(c, 255), width=w)
        frames.append(build_frame(S, color, draw, label=label))
    return frames, 100

# ═══════════════════════════════════════════════════════════════════════════
#  MANIFEST
# ═══════════════════════════════════════════════════════════════════════════
def build_manifest(S):
    m = {}
    m["logo"] = gen_logo(S)
    m["themes"] = gen_themes(S)
    m["screen2"] = gen_screen2(S)
    m["shuffle"] = gen_shuffle(S)
    m["restart"] = gen_restart(S)
    m["vol_down"] = gen_volume(S, "down")
    m["vol_up"] = gen_volume(S, "up")
    m["mute"] = gen_volume(S, "mute")
    m["light"] = gen_light(S)
    m["ingame"] = gen_ingame(S)
    m["detect"] = gen_detect(S)
    m["rebuild"] = gen_rebuild(S)
    m["health"] = gen_health(S)
    m["perf"] = gen_perf(S)
    for p in range(1, 5):
        m[f"coin_p{p}"] = gen_coin(S, p)
        m[f"start_p{p}"] = gen_start(S, p)
    m["pause"] = gen_pause(S)
    m["exit"] = gen_exit(S)
    m["save"] = gen_floppy(S, "save")
    m["load"] = gen_floppy(S, "load")
    m["service"] = gen_service(S)
    m["test"] = gen_test(S)
    m["menu_back"] = gen_chevron(S, "left", "MENU")
    m["more"] = gen_chevron(S, "right", None)
    m["back"] = gen_chevron(S, "left", None)
    m["screen2_on"] = m["screen2"]
    m["screen2_off"] = (dim_frames(m["screen2"][0]), 100)
    m["perf_on"] = m["perf"]
    m["perf_off"] = (dim_frames(m["perf"][0]), 100)
    return m

# ═══════════════════════════════════════════════════════════════════════════
#  CONTACT SHEET
# ═══════════════════════════════════════════════════════════════════════════
def make_preview(manifest, path, S, scale=2):
    cell = S * scale
    name_w = max(90 * scale, cell + 10)
    max_frames = max(len(v[0]) for v in manifest.values())
    W = name_w + max_frames * cell
    H = len(manifest) * cell
    sheet = Image.new("RGB", (W, H), (20, 20, 20))
    d = ImageDraw.Draw(sheet)
    f = fnt(max(9, 9 * scale))
    for row, name in enumerate(sorted(manifest.keys())):
        frames, _ = manifest[name]
        y = row * cell
        if row % 2:
            d.rectangle([0, y, W, y + cell], fill=(28, 28, 28))
        d.text((4, y + cell // 2 - 7 * scale), name, fill=(180, 180, 180), font=f)
        for col, frame in enumerate(frames):
            x = name_w + col * cell
            scaled = frame.resize((cell, cell), Image.NEAREST)
            sheet.paste(scaled, (x, y))
    sheet.save(str(path), "PNG", optimize=True)

# ═══════════════════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════════════════
def main():
    ap = argparse.ArgumentParser(description="Generate Stream Deck APNG art")
    ap.add_argument("--out", default=str(SCRIPT_DIR / "art"),
                    help="Output directory (default: art/)")
    ap.add_argument("--size", type=int, default=72, help="Key size in px")
    ap.add_argument("--preview", default=None,
                    help="Write 2x contact sheet PNG to this path")
    args = ap.parse_args()

    S = args.size
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    print(f"Generating Stream Deck art ({S}x{S}) ...")
    manifest = build_manifest(S)

    total_bytes = 0
    for name in sorted(manifest.keys()):
        frames, duration = manifest[name]
        path = out / f"{name}.png"
        save_opt(frames, path, duration)
        sz = os.path.getsize(str(path))
        total_bytes += sz
        print(f"  {name + '.png':<22s} {len(frames):>2d} frames  {sz / 1024:>6.1f} KB")
    print(f"\nDone. {len(manifest)} files, {total_bytes / 1024:.1f} KB total.")

    if args.preview:
        pp = Path(args.preview)
        pp.parent.mkdir(parents=True, exist_ok=True)
        make_preview(manifest, pp, S, scale=2)
        print(f"Preview (2x): {pp}")
        pp1 = pp.with_stem(pp.stem + "_1x")
        make_preview(manifest, pp1, S, scale=1)
        print(f"Preview (1x): {pp1}")

if __name__ == "__main__":
    main()
