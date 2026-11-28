#!/usr/bin/env python3
"""
New-ArcadeThemes.py - five extra ArcadeMaster layouts (themes), every picture drawn here, all original art.

Each theme is a complete RetroFE layout folder layouts/AM-<Name>/ that shows the same per-game media as the main
ArcadeMaster layout (am_video, am_backdrop, am_controls, am_hint, am_story, logo, marquee, the playlist banner and
the list position), in a different arrangement. The arrangement ideas (not their art) come from the CoinOPS / CORE
layouts on R: - see IDEAS below.

  AM-Wall     brick wall of logo tiles on the left, the selected game enlarged on the right with video, card, hint
  AM-Marquee  a whole cabinet: lit marquee on top, video in a clean screen frame, controls card on the control-panel deck
  AM-Wheel    curved logo wheel on the right, big video on the left, story ticker along the bottom
  AM-Poster   box-art carousel along the bottom over the game's full-screen backdrop
  AM-Neon     minimal centred neon text list under a huge logo: the lightest theme for weak PCs

Keys: every game list menu is orientation="vertical", so UP / DOWN move through the games and LEFT / RIGHT stay free
for the playlists (controls.conf nextPlaylist / prevPlaylist), even where the items are laid out sideways (Poster,
Wall). The main menu row stays horizontal like ArcadeMaster's, so the wheel steers it.

Background rule (James, 2026-11-22: "something related to each game as the background", no retro look): the
background is ALWAYS the game's own art - am_backdrop, with its fanart over it where it has one. The only generated
base is a plain dark gradient behind them. No generated scenes, synthwave, stars, grid floors, scanlines or CRT
effects in any theme; neon is used only for frame edges and selection highlights.

Performance rules every theme keeps:
  - each generated picture is drawn at exactly the size the layout shows it (no GPU rescale of our art)
  - full-screen layers: the plain pre-scaled JPEG gradient + the game's am_backdrop (+ its fanart if it has one);
    nothing else covers the screen
  - the video has ONE fixed size (width + maxHeight, so 4:3 and 16:9 both fit); only its alpha animates
  - animations are alpha / small moves of small pictures; no animated resizes of the video or the backdrop

  python tools/New-ArcadeThemes.py                      # (re)build layouts/AM-* in the repo
  python tools/New-ArcadeThemes.py --install R:\\ArcadeMaster\\frontend\\LEGENDS-am --manifest R:\\ArcadeMaster\\manifest
         [--only Wall,Neon] [--samples <collection medium_artwork dir>] [--no-score]

--install copies each layout into <RetroFE>\\layouts\\AM-<Name> (never onto E:, never over a folder it did not make),
adds the cabinet's own playlist banners and boot-intro cards, renders a preview mock-up (Pillow) and registers it in
<manifest>\\themes.json the same way Import-RetroFETheme.ps1 does, so Tools > Themes lists it. It does not change
settings.conf.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / 'layouts' / 'ArcadeMaster'            # the ArcadeMaster layout: boot intro, Tools screen, sounds, font
W, H = 1920, 1080
FONT = SRC / 'fonts' / 'OpenSans.ttf'
FFMPEG_FALLBACK = (r'C:\Users\vdfgamer\AppData\Local\Microsoft\WinGet\Packages'
                   r'\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-9.1-full_build\bin\ffmpeg.exe')
MARKER = 'theme.json'                              # marks a folder this script made (install never replaces others)


# ====================================================================================================== drawing kit
def rgba(c, a=255):
    return tuple(c[:3]) + (int(a),)


def blank(w, h):
    return Image.new('RGBA', (w, h), (0, 0, 0, 0))


def vgrad(w, h, top, bottom):
    """vertical gradient; colours may be RGB or RGBA"""
    top, bottom = rgba(top, top[3] if len(top) > 3 else 255), rgba(bottom, bottom[3] if len(bottom) > 3 else 255)
    col = Image.new('RGBA', (1, h))
    for y in range(h):
        t = y / max(1, h - 1)
        col.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(4)))
    return col.resize((w, h))


def radial(w, h, color, inner=0.0, power=1.6, alpha=255):
    """soft elliptical glow: full alpha in the middle, 0 at the edge"""
    m = Image.new('L', (w, h))
    px = m.load()
    cx, cy = (w - 1) / 2, (h - 1) / 2
    for y in range(h):
        dy = (y - cy) / (h / 2)
        for x in range(w):
            dx = (x - cx) / (w / 2)
            d = math.sqrt(dx * dx + dy * dy)
            v = 0 if d >= 1 else (1 if d <= inner else (1 - (d - inner) / (1 - inner)) ** power)
            px[x, y] = int(alpha * v)
    im = Image.new('RGBA', (w, h), rgba(color))
    im.putalpha(m)
    return im


def radial_fast(w, h, color, alpha=255, power=1.6):
    """same glow, computed small and scaled up (smooth anyway)"""
    s = 4
    return radial(max(8, w // s), max(8, h // s), color, power=power, alpha=alpha).resize((w, h), Image.BICUBIC)


def glow_line_layer(w, h, draw_fn, color, width, blur, ss=2, core=(255, 255, 255), core_w=None):
    """neon stroke: blurred coloured halo + the coloured line + a thin hot core. draw_fn(draw, scale, fill, width)"""
    big = blank(w * ss, h * ss)
    halo = blank(w * ss, h * ss)
    draw_fn(ImageDraw.Draw(halo), ss, rgba(color, 255), int(width * ss * 2.2))
    halo = halo.filter(ImageFilter.GaussianBlur(blur * ss))
    big = Image.alpha_composite(big, halo)
    line = blank(w * ss, h * ss)
    draw_fn(ImageDraw.Draw(line), ss, rgba(color, 255), int(width * ss))
    big = Image.alpha_composite(big, line)
    if core:
        c = blank(w * ss, h * ss)
        draw_fn(ImageDraw.Draw(c), ss, rgba(core, 220), max(1, int((core_w or width / 3) * ss)))
        big = Image.alpha_composite(big, c)
    return big.resize((w, h), Image.LANCZOS)


def rrect_fn(box, r):
    def f(d, s, fill, width):
        d.rounded_rectangle([v * s for v in box], radius=r * s, outline=fill, width=max(1, width))
    return f


def neon_frame(w, h, hole_w, hole_h, color, r=18, width=4, blur=10, fill=None, core=(255, 255, 255)):
    """neon outline around a centred hole of hole_w x hole_h (the hole stays transparent)"""
    im = blank(w, h)
    x0, y0 = (w - hole_w) / 2, (h - hole_h) / 2
    box = (x0 - width, y0 - width, x0 + hole_w + width, y0 + hole_h + width)
    if fill:
        f = blank(w, h)
        ImageDraw.Draw(f).rounded_rectangle((x0 - width * 3, y0 - width * 3, x0 + hole_w + width * 3, y0 + hole_h + width * 3), radius=r + 6, fill=fill)
        im = Image.alpha_composite(im, f)
    im = Image.alpha_composite(im, glow_line_layer(w, h, rrect_fn(box, r), color, width, blur, core=core))
    return punch(im, (x0, y0, x0 + hole_w, y0 + hole_h), r=max(0, r - width))


def punch(im, box, r=0):
    """clear a (rounded) rectangle so what is under the frame shows through"""
    m = Image.new('L', im.size, 255)
    ImageDraw.Draw(m).rounded_rectangle([int(round(v)) for v in box], radius=int(r), fill=0)
    a = ImageChops.multiply(im.getchannel('A'), m)
    im = im.copy()
    im.putalpha(a)
    return im


def plain_bg(top, bottom):
    """the only generated background: a plain dark gradient behind the game's own art (no scenes, grids or effects)"""
    return vgrad(W, H, top, bottom)


def clip_to(overlay, base):
    """overlay limited to where base is opaque (shading that must not spill past a shape's edge)"""
    overlay = overlay.copy()
    overlay.putalpha(ImageChops.multiply(overlay.getchannel('A'), base.getchannel('A')))
    return Image.alpha_composite(base, overlay)


def save_png(im, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    im.save(path, 'PNG', optimize=True)


def save_jpg(im, path, q=88):
    path.parent.mkdir(parents=True, exist_ok=True)
    im.convert('RGB').save(path, 'JPEG', quality=q, optimize=True, progressive=False)


def font(size, bold=False):
    for f in ([r'C:\Windows\Fonts\segoeuib.ttf'] if bold else []) + [str(FONT), r'C:\Windows\Fonts\segoeui.ttf']:
        try:
            return ImageFont.truetype(f, size)
        except OSError:
            pass
    return ImageFont.load_default()


# =========================================================================================== XML snippets (shared)
def fade(alpha_to, dur='.3', delay=None, alg='easeOutCubic'):
    pre = f'<set duration="{delay}"><animate type="nop"/></set>' if delay else ''
    return f'{pre}<set duration="{dur}"><animate type="alpha" to="{alpha_to}" algorithm="{alg}"/></set>'


HIDE_ON_SCROLL = '<onMenuScroll><set duration=".05"><animate type="alpha" to="0"/></set></onMenuScroll>'
HIDE_ON_EXIT = '<onMenuExit><set duration=".1"><animate type="alpha" to="0"/></set></onMenuExit>'
HIDE_ON_GAME = '<onGameEnter><set duration=".15"><animate type="alpha" to="0"/></set></onGameEnter>'


def x_sounds(prefix=''):
    return (f'  <sound type="select"    src="{prefix}sounds/select.wav"/>\n'
            f'  <sound type="highlight" src="{prefix}sounds/highlight.wav"/>\n'
            f'  <sound type="load"      src="{prefix}sounds/load.wav"/>\n')


def x_image(src, x, y, w, h, layer, alpha=1, origin=True, inner=''):
    o = ' xOrigin="center" yOrigin="center"' if origin else ''
    body = f'>\n{inner}\n  </image>' if inner else '/>'
    return f'  <image src="{src}" x="{x}" y="{y}"{o} width="{w}" height="{h}" alpha="{alpha}" layer="{layer}"{body}\n'


def x_backdrop(alpha, layer=1):
    """the background IS the game's own art: its am_backdrop (New-PreviewMedia, a frame of its video), with its real
    fanart drawn over it where the game has one. Full screen, pre-scaled 1920x1080, NO resize animation."""
    return ''.join(f'  <reloadableImage type="{kind}" x="0" y="0" width="{W}" height="{H}" alpha="0" layer="{layer}">\n'
                   f'    <onMenuScroll><set duration=".08"><animate type="alpha" to="0"/></set></onMenuScroll>\n'
                   f'    <onMenuIdle>{fade(alpha, ".45")}</onMenuIdle>\n'
                   f'    {HIDE_ON_EXIT}\n  </reloadableImage>\n' for kind in ('am_backdrop', 'fanart'))


def x_video(x, y, w, mh, layer, delay='.3'):
    """ONE fixed size: width + maxHeight keeps 4:3 and 16:9 games right; only alpha animates"""
    return (f'  <reloadableVideo type="am_video" imageType="logo" x="{x}" y="{y}" xOrigin="center" yOrigin="center" '
            f'width="{w}" maxHeight="{mh}" alpha="0" layer="{layer}">\n'
            f'    {HIDE_ON_SCROLL}\n'
            f'    <onMenuIdle>{fade(1, ".25", delay)}</onMenuIdle>\n'
            f'    {HIDE_ON_EXIT}\n  </reloadableVideo>\n')


def x_controls(x, y, w, h, layer, delay='.9'):
    return (f'  <reloadableImage type="am_controls" x="{x}" y="{y}" xOrigin="center" yOrigin="center" width="{w}" height="{h}" alpha="0" layer="{layer}">\n'
            f'    <onMenuScroll><set duration=".06"><animate type="alpha" to="0"/></set></onMenuScroll>\n'
            f'    <onMenuIdle>{fade(1, ".35", delay)}</onMenuIdle>\n'
            f'    {HIDE_ON_GAME}\n    {HIDE_ON_EXIT}\n  </reloadableImage>\n')


def x_hint(x, y, w, h, layer, delay='1.1', nudge=10):
    """special-control reminder (only games that need one have an am_hint): drops in, then breathes"""
    return (f'  <reloadableImage type="am_hint" x="{x}" y="{y - nudge}" xOrigin="center" yOrigin="center" width="{w}" height="{h}" alpha="0" layer="{layer}">\n'
            f'    <onMenuScroll><set duration=".05"><animate type="alpha" to="0"/><animate type="y" to="{y - nudge}"/></set></onMenuScroll>\n'
            f'    <onMenuIdle><set duration="{delay}"><animate type="nop"/></set>'
            f'<set duration=".25"><animate type="alpha" to="1" algorithm="easeOutCubic"/><animate type="y" to="{y}" algorithm="easeOutBounce"/></set></onMenuIdle>\n'
            f'    <onIdle><set duration="1.2"><animate type="alpha" to=".8" algorithm="easeInOutSine"/></set>'
            f'<set duration="1.2"><animate type="alpha" to="1" algorithm="easeInOutSine"/></set></onIdle>\n'
            f'    {HIDE_ON_GAME}\n    {HIDE_ON_EXIT}\n  </reloadableImage>\n')


def x_story(x, y, w, h, size, layer, color='e6e9f0', delay='1.5', direction='vertical', speed=16, alpha=1):
    """am_story (New-GameStories.py -> medium_artwork/am_story/<item>.txt)"""
    return (f'  <reloadableScrollingText type="am_story" menuScrollReload="true" x="{x}" y="{y}" width="{w}" height="{h}" '
            f'fontSize="{size}" loadFontSize="{size}" fontColor="{color}" alignment="left" direction="{direction}" '
            f'scrollingSpeed="{speed}" startPosition="0" startTime="4" endTime="4" alpha="0" layer="{layer}">\n'
            f'    {HIDE_ON_SCROLL}\n'
            f'    <onMenuIdle>{fade(alpha, ".5", delay)}</onMenuIdle>\n'
            f'    {HIDE_ON_GAME}\n    {HIDE_ON_EXIT}\n  </reloadableScrollingText>\n')


def x_text(kind, x, y, size, color, layer, origin='center', alpha=1):
    return (f'  <reloadableText type="{kind}" menuScrollReload="true" x="{x}" y="{y}" xOrigin="{origin}" yOrigin="center" '
            f'fontSize="{size}" loadFontSize="{size}" fontColor="{color}" alpha="0" layer="{layer}">\n'
            f'    <onMenuIdle><set duration=".2"><animate type="alpha" to="{alpha}"/></set></onMenuIdle>\n'
            f'    {HIDE_ON_SCROLL}\n    {HIDE_ON_EXIT}\n  </reloadableText>\n')


def x_playlist(x, y, w, h, layer, ix, iy, isize=24, icolor='9aa3b2', iorigin='center', crumb=None, hints='below'):
    """the active playlist banner (LEFT / RIGHT switch it) + 'position / count' in the list"""
    return (f'  <reloadableImage type="playlist" mode="commonlayout" x="{x}" y="{y}" xOrigin="center" yOrigin="center" width="{w}" height="{h}" alpha="1" layer="{layer}">\n'
            f'    <onPlaylistEnter><set duration=".08"><animate type="alpha" to=".4"/></set>'
            f'<set duration=".25"><animate type="alpha" to="1" algorithm="easeOutCubic"/></set></onPlaylistEnter>\n'
            f'  </reloadableImage>\n'
            f'  <reloadableText type="collectionIndexSize" menuScrollReload="true" x="{ix}" y="{iy}" xOrigin="{iorigin}" yOrigin="center" '
            f'fontSize="{isize}" loadFontSize="{isize}" fontColor="{icolor}" alpha=".9" layer="{layer}"/>\n'
            + x_nav(x, y, w, h, layer, ix, iorigin, crumb, hints))


def x_nav(x, y, w, h, layer, ix, iorigin, crumb=None, hints='below'):
    """ArcadeMaster's nav header (2026-11-27, James: "show breadcrumbs ... and nav buttons to move back and forth"), placed
    round this theme's filter bar: where you are (MAIN > NINTENDO > ALL GAMES), the BACK / FILTERS hints under the bar,
    and touch zones on the bar's arrows and on BACK."""
    left, right, top, bottom = x - w // 2, x + w // 2, y - h // 2, y + h // 2
    # the breadcrumb right of the bar (past a counter that sits there), or top left when the bar is on the right half
    cx = (ix + 170 if iorigin == 'left' and ix > right else right + 40) if right < 1300 else 40
    cy = y if right < 1300 else 34
    cs = 28
    if crumb:                                  # the theme's own place, where the default would cover its art
        cx, cy, cs = crumb
    if hints == 'left':
        # no room under the bar (Box Art: the video frame starts there): BACK sits left of the bar, the bar's own arrows
        # are the filter hint
        hint = (f'  <text value="&lt; BACK" x="{left - 16}" y="{y}" xOrigin="right" yOrigin="center" fontSize="22" loadFontSize="22" fontColor="ff2fa0" alpha=".9" layer="{layer}"/>\n'
                f'  <image src="images/touch_hit.png" touchAction="back" x="{left - 130}" y="{top}" width="120" height="{h}" layer="{layer + 1}"/>\n')
    else:
        hint = (f'  <text value="&lt; BACK" x="{left + 8}" y="{bottom + 22}" yOrigin="center" fontSize="20" loadFontSize="20" fontColor="ff2fa0" alpha=".9" layer="{layer}"/>\n'
                f'  <text value="&lt; &gt;  FILTERS" x="{right - 8}" y="{bottom + 22}" xOrigin="right" yOrigin="center" fontSize="20" loadFontSize="20" fontColor="2ec8ff" alpha=".9" layer="{layer}"/>\n'
                f'  <image src="images/touch_hit.png" touchAction="back" x="{left}" y="{bottom + 4}" width="130" height="40" layer="{layer + 1}"/>\n')
    return (f'  <reloadableText type="am_breadcrumb" x="{cx}" y="{cy}" yOrigin="center" fontSize="{cs}" loadFontSize="{cs}" fontColor="e6e9f0" alpha=".95" layer="{layer}"/>\n'
            + hint +
            f'  <image src="images/touch_hit.png" touchAction="prevPlaylist" x="{left}" y="{top}" width="110" height="{h}" layer="{layer + 1}"/>\n'
            f'  <image src="images/touch_hit.png" touchAction="nextPlaylist" x="{right - 110}" y="{top}" width="110" height="{h}" layer="{layer + 1}"/>\n')


def x_loading(prefix=''):
    """the LOADING - PLEASE WAIT card from the moment a choice is made (James 2026-11-27: "delays with a please wait ... to
    not press into games by accident"); same as ArcadeMaster's am-loading-card"""
    ev = ('    <onMenuExit><set duration=".12"><animate type="alpha" to="{a}"/></set></onMenuExit>\n'
          '    <onExit><set duration=".12"><animate type="alpha" to="{a}"/></set></onExit>\n'
          '    <onMenuEnter><set duration=".2"><animate type="alpha" to="0"/></set></onMenuEnter>\n'
          '    <onEnter><set duration=".2"><animate type="alpha" to="0"/></set></onEnter>\n')
    return (f'  <image src="{prefix}images/black.png" x="0" y="0" width="{W}" height="{H}" alpha="0" layer="19">\n' + ev.format(a='.7') + '  </image>\n'
            f'  <text value="LOADING - PLEASE WAIT" x="{W // 2}" y="{H // 2}" xOrigin="center" yOrigin="center" fontSize="64" loadFontSize="64" '
            f'fontColor="ffe259" alpha="0" layer="19">\n' + ev.format(a='1') + '  </text>\n')


def x_launch(prefix=''):
    """game launch: blackout, the logo punches in (small, cheap)"""
    return (f'  <image src="{prefix}images/black.png" x="0" y="0" width="{W}" height="{H}" alpha="0" layer="18">\n'
            f'    <onGameEnter><set duration=".2"><animate type="nop"/></set><set duration=".45"><animate type="alpha" to="1"/></set></onGameEnter>\n'
            f'    <onGameExit><set duration=".6"><animate type="alpha" to="0"/></set></onGameExit>\n  </image>\n'
            f'  <reloadableImage type="logo" x="center" y="center" xOrigin="center" yOrigin="center" width="700" maxHeight="360" alpha="0" layer="19">\n'
            f'    <onGameEnter><set duration=".35"><animate type="alpha" to="1" algorithm="easeOutCubic"/></set>'
            f'<set duration="1"><animate type="nop"/></set><set duration=".3"><animate type="alpha" to="0"/></set></onGameEnter>\n'
            f'    <onGameExit><set duration=".01"><animate type="alpha" to="0"/></set></onGameExit>\n  </reloadableImage>\n'
            + x_loading(prefix))


def x_head(comment, monitor=None, min_show=True):
    mon = f' monitor="{monitor}"' if monitor is not None else ''
    ms = ' minShowTime="0"' if min_show else ''
    return (f'<!--\n{comment.rstrip()}\n-->\n'
            f'<layout{mon} width="{W}" height="{H}" font="fonts/OpenSans.ttf" loadFontSize="48" fontColor="ffffff"{ms}>\n')


# ============================================================================================== the themes
class Theme:
    name = ''          # folder name after AM-
    p = ''             # art file prefix
    label = ''
    about = ''
    idea = ''
    keys = 'UP / DOWN: games   LEFT / RIGHT: playlists   SELECT: play   BACK: main menu'
    accent = (255, 255, 255)
    accent2 = (46, 200, 255)
    bg_dark = (8, 8, 12)

    @property
    def folder(self):
        return f'AM-{self.name}'

    # ---- art every theme has: background, second-screen marquee frame, main-menu band + selection
    def art(self, img: Path):
        raise NotImplementedError

    def art_common(self, img: Path):
        save_png(neon_frame(1660, 530, 1600, 488, self.accent, r=14, width=4, blur=12, fill=(0, 0, 0, 170)), img / f'{self.p}_m2_frame.png')
        band = vgrad(W, 400, (0, 0, 0, 0), rgba(self.bg_dark, 235))
        band = Image.alpha_composite(band, glow_line_layer(W, 400, lambda dd, s, f, w: dd.line((0, 92 * s, W * s, 92 * s), fill=f, width=w), self.accent, 2, 6))
        save_png(band, img / f'{self.p}_band.png')
        save_png(radial_fast(760, 200, self.accent, alpha=150), img / f'{self.p}_main_sel.png')

    # ---- layouts
    def game_xml(self) -> str:
        raise NotImplementedError

    def screen2_xml(self) -> str:
        """second screen (monitor 1): marquee in the theme's frame, logo under it, the touch bar from ArcadeMaster"""
        return (x_head(f'  {self.folder} - SECOND SCREEN (RetroFE monitor 1), game lists: the game\'s marquee (type="marquee") lit in\n'
                       f'  the theme\'s frame, its logo under it, and ArcadeMaster\'s touch bar in row 3 of 3\n'
                       f'  (BACK | PREV | START | NEXT | RANDOM, controls.conf touch1Column<n>of5Row3of3). Art: tools/New-ArcadeThemes.py\n'
                       f'  Enable with settings.conf: numScreens = 2, screenNum1 = <display index>, fullscreen1 = yes', monitor=1, min_show=False)
                + x_image(f'images/{self.p}_bg.jpg', 0, 0, W, H, 0, origin=False)
                + x_backdrop(.6, 1)
                + x_image(f'images/{self.p}_m2_frame.png', 960, 268, 1660, 530, 4)
                + '  <reloadableImage type="marquee" x="960" y="268" xOrigin="center" yOrigin="center" width="1600" maxHeight="488" alpha="0" layer="3">\n'
                  f'    <onMenuScroll><set duration=".06"><animate type="alpha" to=".25"/></set></onMenuScroll>\n'
                  f'    <onMenuIdle>{fade(1, ".3")}<set duration="2.4"><animate type="alpha" to=".86" algorithm="easeInOutSine"/></set>'
                  f'<set duration="2.4"><animate type="alpha" to="1" algorithm="easeInOutSine"/></set></onMenuIdle>\n'
                  '  </reloadableImage>\n'
                + '  <reloadableImage type="logo" x="960" y="610" xOrigin="center" yOrigin="center" width="560" maxHeight="140" alpha="0" layer="5">\n'
                  f'    <onMenuScroll><set duration=".06"><animate type="alpha" to=".25"/></set></onMenuScroll>\n'
                  f'    <onMenuIdle>{fade(1, ".3")}</onMenuIdle>\n  </reloadableImage>\n'
                + x_text('title', 960, 698, 26, 'c9ced8', 5)
                + x_image('images/ui_touchbar.png', 0, 720, W, 360, 7, origin=False)
                + x_image('images/studio_realz.png', 1760, 20, 110, 110, 8, alpha='.85', origin=False)
                + x_launch()
                + '</layout>\n')

    def main_deco(self) -> str:
        return ''

    def main_xml(self) -> str:
        """main menu: the theme's background, the highlighted collection's big logo, the collection row (steered with
        the wheel / LEFT RIGHT like ArcadeMaster's main menu)"""
        P = '../../../'
        return (x_head(f'  {self.folder} MAIN MENU (c) The Real Z Studios - art: tools/New-ArcadeThemes.py\n'
                       f'  Collection logos: {self.folder}/collections/Main/medium_artwork/logo/<Collection>.png (mode="layout"), the\n'
                       f'  same neon logos as ArcadeMaster. Row is horizontal: the wheel / LEFT RIGHT pick a collection.', min_show=False)
                + x_sounds(P)
                + x_image(f'{P}images/{self.p}_bg.jpg', 0, 0, W, H, 0, origin=False)
                + self.main_deco()
                + '  <reloadableImage type="logo" mode="layout" x="960" y="330" xOrigin="center" yOrigin="center" width="1100" height="269" alpha="0" layer="5">\n'
                  '    <onMenuScroll><set duration=".06"><animate type="alpha" to="0"/><animate type="y" to="350"/></set></onMenuScroll>\n'
                  '    <onMenuIdle><set duration=".35"><animate type="alpha" to="1" algorithm="easeOutCubic"/><animate type="y" to="330" algorithm="easeOutCubic"/></set></onMenuIdle>\n'
                  '  </reloadableImage>\n'
                + x_image(f'{P}images/{self.p}_band.png', 0, 680, W, 400, 10, origin=False)
                + f'  <image src="{P}images/{self.p}_main_sel.png" x="960" y="912" xOrigin="center" yOrigin="center" width="760" height="200" alpha=".55" layer="11">\n'
                  '    <onMenuScroll><set duration=".06"><animate type="alpha" to="1"/></set></onMenuScroll>\n'
                  '    <onMenuIdle><set duration=".5"><animate type="alpha" to=".55" algorithm="easeOutCubic"/></set></onMenuIdle>\n  </image>\n'
                + '  <menu type="custom" mode="layout" imageType="logo" scrollTime=".18" scrollAcceleration=".04" orientation="horizontal">\n'
                  '    <itemDefaults x="center" y="912" xOrigin="center" yOrigin="center" width="600" height="120" alpha="0" layer="12" fontColor="ffffff" fontSize="72" loadFontSize="72"/>\n'
                  '    <item xOffset="-1260" width="300" height="60" alpha="0"/>\n'
                  '    <item xOffset="-910" width="340" height="68" alpha=".3"/>\n'
                  '    <item xOffset="-530" width="420" height="84" alpha=".6"/>\n'
                  '    <item selected="true" width="600" height="120" alpha="1"/>\n'
                  '    <item xOffset="530" width="420" height="84" alpha=".6"/>\n'
                  '    <item xOffset="910" width="340" height="68" alpha=".3"/>\n'
                  '    <item xOffset="1260" width="300" height="60" alpha="0"/>\n'
                  '  </menu>\n'
                + x_image(f'{P}images/studio_realz.png', 40, 20, 160, 160, 18, alpha='.9', origin=False)
                + '</layout>\n')

    def main2_xml(self) -> str:
        P = '../../../'
        return (x_head(f'  {self.folder} - SECOND SCREEN, MAIN MENU: the highlighted collection\'s logo in the theme\'s frame, plus\n'
                       '  ArcadeMaster\'s touch bar (BACK | PREV | START = open | NEXT | RANDOM).', monitor=1, min_show=False)
                + x_image(f'{P}images/{self.p}_bg.jpg', 0, 0, W, H, 0, origin=False)
                + x_image(f'{P}images/{self.p}_m2_frame.png', 960, 300, 1660, 530, 4)
                + '  <reloadableImage type="logo" mode="layout" x="960" y="300" xOrigin="center" yOrigin="center" width="1300" height="318" alpha="0" layer="5">\n'
                  '    <onMenuScroll><set duration=".06"><animate type="alpha" to=".3"/></set></onMenuScroll>\n'
                  '    <onMenuIdle><set duration=".3"><animate type="alpha" to="1" algorithm="easeOutCubic"/></set></onMenuIdle>\n  </reloadableImage>\n'
                + x_image(f'{P}images/ui_touchbar.png', 0, 720, W, 360, 7, origin=False)
                + '</layout>\n')

    # ---- preview mock-up (same geometry as game_xml)
    def preview(self, s: 'Samples') -> Image.Image:
        raise NotImplementedError


# ------------------------------------------------------------------------------------------------- AM-Wall
class Wall(Theme):
    name, p = 'Wall', 'wall'
    label = 'Tile Wall'
    ENTRANCE = 'drop'        # main menu: characters fall in from above
    about = 'a brick wall of logo tiles; the chosen game opens big with its video, controls card and hint'
    idea = ('CoinOPS "Wall" / "Night Wall" (a wall of game screens with the chosen one in front) - here a staggered '
            'two-column tile wall that scrolls with UP / DOWN')
    accent, accent2, bg_dark = (255, 176, 0), (46, 200, 255), (12, 13, 18)
    WX, WY = 380, 590           # wall centre line / selected row
    STEP_Y, HALF_X = 80, 160    # brick step down / half the column gap
    TILE = (300, 100)
    PANEL = (40, 110, 680, 960)  # x, y, w, h of the baked tile panel

    def slot(self, j):
        return self.WX + (-self.HALF_X if j % 2 == 0 else self.HALF_X), self.WY + j * self.STEP_Y

    def art(self, img):
        save_jpg(plain_bg((22, 24, 32), (10, 10, 14)), img / 'wall_bg.jpg')
        # the tile panel: every slot's empty tile, baked into ONE picture (the logos fly between fixed tiles)
        px, py, pw, ph = self.PANEL
        panel = blank(pw, ph)
        back = blank(pw, ph)
        ImageDraw.Draw(back).rounded_rectangle((0, 0, pw - 1, ph - 1), radius=26, fill=(6, 7, 10, 150))
        panel = Image.alpha_composite(panel, back)
        tw, th = self.TILE
        for j in range(-5, 6):
            cx, cy = self.slot(j)
            cx, cy = cx - px, cy - py
            fade_ = max(0.25, 1 - abs(j) * 0.14)
            t = blank(pw, ph)
            td = ImageDraw.Draw(t)
            box = (cx - tw / 2, cy - th / 2, cx + tw / 2, cy + th / 2)
            td.rounded_rectangle(box, radius=14, fill=(24, 26, 34, int(215 * fade_)), outline=rgba(self.accent, int(120 * fade_)), width=2)
            td.line((box[0] + 16, box[1] + 3, box[2] - 16, box[1] + 3), fill=(255, 255, 255, int(40 * fade_)), width=2)
            for rx, ry in ((box[0] + 9, box[1] + 9), (box[2] - 9, box[1] + 9), (box[0] + 9, box[3] - 9), (box[2] - 9, box[3] - 9)):
                td.ellipse((rx - 2.5, ry - 2.5, rx + 2.5, ry + 2.5), fill=(160, 140, 100, int(170 * fade_)))
            panel = Image.alpha_composite(panel, t)
        save_png(panel, img / 'wall_tiles.png')
        sel = neon_frame(380, 140, 320, 108, self.accent, r=16, width=4, blur=9)
        save_png(sel, img / 'wall_sel.png')
        vf = neon_frame(1100, 645, 1040, 585, self.accent, r=10, width=3, blur=10, fill=(0, 0, 0, 200))
        d = ImageDraw.Draw(vf)
        for (x, y, sx, sy) in ((14, 14, 1, 1), (1086, 14, -1, 1), (14, 631, 1, -1), (1086, 631, -1, -1)):   # corner brackets
            d.line((x, y, x + 60 * sx, y), fill=rgba(self.accent2, 230), width=4)
            d.line((x, y, x, y + 40 * sy), fill=rgba(self.accent2, 230), width=4)
        save_png(vf, img / 'wall_video_frame.png')
        info = blank(1100, 56)
        ImageDraw.Draw(info).rounded_rectangle((0, 0, 1099, 55), radius=10, fill=(8, 9, 12, 190), outline=rgba(self.accent, 90), width=1)
        save_png(info, img / 'wall_info.png')
        self.art_common(img)

    def menu(self):
        items = []
        for j in range(-6, 7):
            x, y = self.slot(j)
            a = 0 if abs(j) == 6 else (1 if j == 0 else round(max(.25, .9 - abs(j) * .13), 2))
            w, mh = (330, 92) if j == 0 else (260, 76)
            sel = ' selected="true"' if j == 0 else ''
            items.append(f'    <item{sel} xOffset="{x - self.WX}" yOffset="{y - self.WY}" width="{w}" maxHeight="{mh}" alpha="{a}"/>')
        return ('  <menu type="custom" imageType="logo" scrollTime=".14" scrollAcceleration=".035" orientation="vertical">\n'
                f'    <itemDefaults x="{self.WX}" y="{self.WY}" xOrigin="center" yOrigin="center" width="260" maxHeight="76" alpha="0" layer="10" fontColor="ffffff" fontSize="34" loadFontSize="34"/>\n'
                + '\n'.join(items) + '\n  </menu>\n')

    def game_xml(self):
        sx, sy = self.slot(0)
        px, py, pw, ph = self.PANEL
        return (x_head('  AM-Wall - GAME LIST (c) The Real Z Studios - all art drawn by tools/New-ArcadeThemes.py\n'
                       '  Idea: a wall of games (CoinOPS Wall), rebuilt as a staggered two-column tile wall that scrolls with UP / DOWN;\n'
                       '  the chosen game opens big on the right: video, title, controls card, special-control hint, story.\n'
                       '  Keys: UP / DOWN games, LEFT / RIGHT playlists (menu is orientation="vertical").\n'
                       '  Fast: tiles are ONE baked picture, the logos move between fixed tiles; video has one fixed size.')
                + x_sounds()
                + x_image('images/wall_bg.jpg', 0, 0, W, H, 0, origin=False)
                + x_backdrop(.7, 1)
                + x_image('images/wall_tiles.png', px, py, pw, ph, 3, origin=False)
                + f'  <image src="images/wall_sel.png" x="{sx}" y="{sy}" xOrigin="center" yOrigin="center" width="380" height="140" alpha="1" layer="9">\n'
                  '    <onMenuScroll><set duration=".05"><animate type="alpha" to=".5"/></set></onMenuScroll>\n'
                  '    <onMenuIdle><set duration=".15"><animate type="alpha" to="1"/></set>'
                  '<set duration="1.1"><animate type="alpha" to=".6" algorithm="easeInOutSine"/></set>'
                  '<set duration="1.1"><animate type="alpha" to="1" algorithm="easeInOutSine"/></set></onMenuIdle>\n  </image>\n'
                + self.menu()
                + x_playlist(380, 46, 600, 58, 11, 380, 92)
                + x_image('images/wall_video_frame.png', 1330, 365, 1100, 645, 5)
                + x_video(1330, 365, 1040, 585, 6)
                + x_image('images/wall_info.png', 1330, 700, 1100, 56, 7)
                + x_text('title', 800, 700, 34, 'ffffff', 10, 'left')
                + x_text('year', 1868, 700, 28, 'ffb000', 10, 'right')
                + x_text('manufacturer', 1740, 700, 26, '2ec8ff', 10, 'right')
                # story: after 6 s on one game a dark glass covers the video and the story scrolls
                + '  <image src="images/black.png" x="1330" y="365" xOrigin="center" yOrigin="center" width="1040" height="585" alpha="0" layer="8">\n'
                  f'    {HIDE_ON_SCROLL}\n    <onMenuIdle>{fade(".84", ".6", "6")}</onMenuIdle>\n    {HIDE_ON_GAME}\n    {HIDE_ON_EXIT}\n  </image>\n'
                + x_story(840, 100, 980, 530, 30, 9, delay='6.2')
                + x_hint(1330, 110, 980, 92, 17)
                + x_controls(1330, 905, 1100, 300, 12)
                + x_launch()
                + '</layout>\n')

    def main_deco(self):
        return x_image('../../../images/wall_tiles.png', 1240, 20, 680, 960, 2, alpha='.35', origin=False)

    def preview(self, s):
        c = s.base(self, backdrop_alpha=.7)
        px, py, pw, ph = self.PANEL
        s.paste(c, self.img('wall_tiles.png'), px, py, pw, ph, origin=False)
        s.paste(c, self.img('wall_sel.png'), *self.slot(0), 380, 140)
        for j in range(-5, 6):
            x, y = self.slot(j)
            w, mh = (330, 92) if j == 0 else (260, 76)
            a = 1 if j == 0 else max(.25, .9 - abs(j) * .13)
            s.fit(c, s.logo(j), x, y, w, mh, alpha=a)
        s.playlist(c, 380, 46, 600, 58)
        s.text(c, s.index, 380, 92, 24, (154, 163, 178))
        s.fit(c, s.video, 1330, 365, 1040, 585)
        s.paste(c, self.img('wall_video_frame.png'), 1330, 365, 1100, 645)
        s.paste(c, self.img('wall_info.png'), 1330, 700, 1100, 56)
        s.text(c, s.title, 800, 700, 34, (255, 255, 255), anchor='lm')
        s.text(c, s.year, 1868, 700, 28, (255, 176, 0), anchor='rm')
        s.text(c, s.maker, 1740, 700, 26, (46, 200, 255), anchor='rm')
        s.paste(c, s.hint, 1330, 110, 980, 92)
        s.paste(c, s.controls, 1330, 905, 1100, 300)
        return c


# ----------------------------------------------------------------------------------------------- AM-Marquee
class Marquee(Theme):
    name, p = 'Marquee', 'marq'
    label = 'Cabinet'
    ENTRANCE = 'rise'        # main menu: characters come up from below
    about = "a cabinet frame over the game's own art: lit marquee, framed screen, controls card on the control panel"
    idea = ('CoinOPS "Marquee" / "Marquee + Bezel" (marquee art beside a bezel-framed screen) - here the screen IS the '
            'cabinet: marquee lightbox on top, video in a clean modern screen frame, the controls card on the panel deck')
    accent, accent2, bg_dark = (255, 70, 70), (255, 210, 80), (14, 6, 9)

    def art(self, img):
        save_jpg(plain_bg((20, 12, 16), (6, 4, 6)), img / 'marq_bg.jpg')
        # cabinet side panels (left: list, right: info + story): smoked glass over the game's art, a clean edge line
        for side in ('l', 'r'):
            sp = Image.new('RGBA', (420, H), (8, 8, 10, 175))
            edge = glow_line_layer(420, H, lambda dd, s, f, w: dd.line((416 * s, 0, 416 * s, H * s), fill=f, width=w),
                                   self.accent, 2, 4)
            sp = Image.alpha_composite(sp, edge)
            if side == 'r':
                sp = sp.transpose(Image.FLIP_LEFT_RIGHT)
            save_png(sp, img / f'marq_side_{side}.png')
        # marquee lightbox: chrome frame around a 984x300 window
        lb = blank(1060, 340)
        ImageDraw.Draw(lb).rounded_rectangle((0, 0, 1059, 339), radius=18, fill=(30, 30, 36, 255))
        lb = clip_to(vgrad(1060, 340, (210, 214, 222, 90), (60, 60, 70, 60)), lb)
        lb = punch(lb, (38, 20, 1022, 320), r=6)
        lb = Image.alpha_composite(lb, glow_line_layer(1060, 340, rrect_fn((36, 18, 1024, 322), 7), self.accent2, 2, 5))
        lb = punch(lb, (38, 20, 1022, 320), r=6)
        save_png(lb, img / 'marq_lightbox.png')
        # screen frame: a clean modern cabinet frame (dark, rounded, thin accent edge) around the 768x432 video
        save_png(neon_frame(880, 480, 768, 432, self.accent, r=16, width=3, blur=6, fill=(14, 14, 18, 235), core=None), img / 'marq_bezel.png')
        # control-panel deck behind the controls card
        dk = blank(1180, 310)
        ImageDraw.Draw(dk).polygon([(40, 0), (1140, 0), (1180, 310), (0, 310)], fill=(22, 22, 28, 235))
        dk = clip_to(vgrad(1180, 310, (255, 255, 255, 30), (0, 0, 0, 0)), dk)
        dk = Image.alpha_composite(dk, glow_line_layer(1180, 310, lambda d2, s, f, w: d2.line((40 * s, 2 * s, 1140 * s, 2 * s), fill=f, width=w), (200, 205, 215), 3, 3))
        save_png(dk, img / 'marq_deck.png')
        save_png(neon_frame(380, 124, 344, 100, self.accent, r=14, width=3, blur=8), img / 'marq_sel.png')
        self.art_common(img)

    LX, LY, LSTEP = 205, 620, 100

    def game_xml(self):
        items = []
        for j in range(-5, 6):
            a = 0 if abs(j) == 5 else (1 if j == 0 else round(.85 - abs(j) * .17, 2))
            w, mh = (340, 96) if j == 0 else (290, 78)
            sel = ' selected="true"' if j == 0 else ''
            items.append(f'    <item{sel} yOffset="{j * self.LSTEP}" width="{w}" maxHeight="{mh}" alpha="{a}"/>')
        menu = ('  <menu type="custom" imageType="logo" scrollTime=".14" scrollAcceleration=".035" orientation="vertical">\n'
                f'    <itemDefaults x="{self.LX}" y="{self.LY}" xOrigin="center" yOrigin="center" width="290" maxHeight="78" alpha="0" layer="10" fontColor="ffffff" fontSize="34" loadFontSize="34"/>\n'
                + '\n'.join(items) + '\n  </menu>\n')
        return (x_head('  AM-Marquee - GAME LIST (c) The Real Z Studios - all art drawn by tools/New-ArcadeThemes.py\n'
                       '  Idea: CoinOPS Marquee / Marquee+Bezel put marquee art beside a bezel screen; here the whole screen is a\n'
                       '  cabinet over the game\'s own art: lit marquee (type="marquee") on top, video in a clean screen frame,\n'
                       '  controls card on the panel deck,'
                       ' no CRT / scanline effects,\n'
                       '  logo list on the left side panel, title + story on the right side panel.\n'
                       '  Keys: UP / DOWN games, LEFT / RIGHT playlists (menu is orientation="vertical").')
                + x_sounds()
                + x_image('images/marq_bg.jpg', 0, 0, W, H, 0, origin=False)
                + x_backdrop(.6, 1)
                + x_image('images/marq_side_l.png', 0, 0, 420, H, 2, origin=False)
                + x_image('images/marq_side_r.png', 1500, 0, 420, H, 2, origin=False)
                # marquee art in its chrome lightbox
                + '  <reloadableImage type="marquee" x="960" y="170" xOrigin="center" yOrigin="center" width="984" maxHeight="300" alpha="0" layer="4">\n'
                  '    <onMenuScroll><set duration=".05"><animate type="alpha" to=".2"/></set></onMenuScroll>\n'
                  f'    <onMenuIdle>{fade(1, ".25", ".1")}</onMenuIdle>\n    {HIDE_ON_EXIT}\n  </reloadableImage>\n'
                + x_image('images/marq_lightbox.png', 960, 170, 1060, 340, 5)
                # the screen
                + x_image('images/marq_bezel.png', 960, 560, 880, 480, 6)
                + x_video(960, 560, 768, 432, 5)
                + x_hint(960, 380, 760, 71, 17)
                # control panel
                + x_image('images/marq_deck.png', 960, 928, 1180, 310, 8)
                + x_controls(960, 928, 1100, 300, 9)
                # left side panel: playlist + list
                + x_playlist(205, 52, 380, 37, 11, 205, 92, 22, crumb=(1500, 16, 17))
                + f'  <image src="images/marq_sel.png" x="{self.LX}" y="{self.LY}" xOrigin="center" yOrigin="center" width="380" height="124" alpha="1" layer="9">\n'
                  '    <onMenuScroll><set duration=".05"><animate type="alpha" to=".4"/></set></onMenuScroll>\n'
                  '    <onMenuIdle><set duration=".15"><animate type="alpha" to="1"/></set></onMenuIdle>\n  </image>\n'
                + menu
                # right side panel: title, maker, year, story (always on, scrolls slowly)
                + x_text('title', 1710, 70, 34, 'ffffff', 10)
                + x_text('manufacturer', 1710, 118, 26, 'ffd250', 10)
                + x_text('year', 1710, 156, 26, 'ff4646', 10)
                + x_story(1525, 210, 370, 840, 24, 10, delay='.8', speed=14)
                + x_launch()
                + '</layout>\n')

    def main_deco(self):
        P = '../../../'
        return (x_image(f'{P}images/marq_side_l.png', 0, 0, 420, H, 2, origin=False)
                + x_image(f'{P}images/marq_side_r.png', 1500, 0, 420, H, 2, origin=False))

    def preview(self, s):
        c = s.base(self, backdrop_alpha=.6)
        s.paste(c, self.img('marq_side_l.png'), 0, 0, 420, H, origin=False)
        s.paste(c, self.img('marq_side_r.png'), 1500, 0, 420, H, origin=False)
        s.fit(c, s.marquee, 960, 170, 984, 300)
        s.paste(c, self.img('marq_lightbox.png'), 960, 170, 1060, 340)
        s.fit(c, s.video, 960, 560, 768, 432)
        s.paste(c, self.img('marq_bezel.png'), 960, 560, 880, 480)
        s.paste(c, s.hint, 960, 380, 760, 71)
        s.paste(c, self.img('marq_deck.png'), 960, 928, 1180, 310)
        s.paste(c, s.controls, 960, 928, 1100, 300)
        s.playlist(c, 205, 52, 380, 37)
        s.text(c, s.index, 205, 92, 22, (154, 163, 178))
        s.paste(c, self.img('marq_sel.png'), self.LX, self.LY, 380, 124)
        for j in range(-4, 5):
            w, mh = (340, 96) if j == 0 else (290, 78)
            s.fit(c, s.logo(j), self.LX, self.LY + j * self.LSTEP, w, mh, alpha=1 if j == 0 else .85 - abs(j) * .17)
        s.text(c, s.title, 1710, 70, 34, (255, 255, 255))
        s.text(c, s.maker, 1710, 118, 26, (255, 210, 80))
        s.text(c, s.year, 1710, 156, 26, (255, 70, 70))
        s.story_box(c, 1525, 210, 370, 840, 24)
        return c


# ------------------------------------------------------------------------------------------------- AM-Wheel
class Wheel(Theme):
    name, p = 'Wheel', 'whl'
    label = 'Spin Wheel'
    ENTRANCE = 'spin'        # main menu: characters spin in on the spot
    about = 'curved logo wheel on the right, a big video on the left, the story as a ticker'
    idea = ('CoinOPS "Wheel Ani" and CORE "TYPE R" (logos on a curved, tilted wheel at the screen edge) - here a neon arc '
            'on the right with a glass band under the logos, the video big on the left and the story running as a ticker')
    accent, accent2, bg_dark = (255, 47, 160), (46, 200, 255), (14, 6, 26)
    CX, CY, R, STEP = 2420, 540, 920, 7.5       # arc centre (off screen right), radius, degrees per slot
    SEL = (1500, 540)
    ARC_X = 1160

    def slot(self, j):
        t = math.radians(j * self.STEP)
        return self.CX - self.R * math.cos(t), self.CY + self.R * math.sin(t), -j * self.STEP

    def art(self, img):
        save_jpg(plain_bg((24, 12, 32), (6, 4, 12)), img / 'whl_bg.jpg')
        # the arc: glass band under the logos + neon rims + a tick per slot
        aw = W - self.ARC_X
        cx, cy = self.CX - self.ARC_X, self.CY
        ss = 2
        band = blank(aw * ss, H * ss)
        bd = ImageDraw.Draw(band)
        ro, ri = self.R + 230, self.R - 230
        bd.ellipse(((cx - ro) * ss, (cy - ro) * ss, (cx + ro) * ss, (cy + ro) * ss), fill=(10, 4, 24, 170))
        bd.ellipse(((cx - ri) * ss, (cy - ri) * ss, (cx + ri) * ss, (cy + ri) * ss), fill=(0, 0, 0, 0))
        band = band.resize((aw, H), Image.LANCZOS)
        rims = glow_line_layer(aw, H, lambda d, s, f, w: (d.ellipse(((cx - ro) * s, (cy - ro) * s, (cx + ro) * s, (cy + ro) * s), outline=f, width=w)),
                               self.accent, 4, 10)
        rims2 = glow_line_layer(aw, H, lambda d, s, f, w: d.ellipse(((cx - ri) * s, (cy - ri) * s, (cx + ri) * s, (cy + ri) * s), outline=f, width=w),
                                self.accent2, 2, 6)
        arc = Image.alpha_composite(Image.alpha_composite(band, rims), rims2)
        td = ImageDraw.Draw(arc)
        for j in range(-7, 8):
            t = math.radians(j * self.STEP)
            x1, y1 = cx - (ro - 4) * math.cos(t), cy + (ro - 4) * math.sin(t)
            x2, y2 = cx - (ro + 22) * math.cos(t), cy + (ro + 22) * math.sin(t)
            td.line((x1, y1, x2, y2), fill=rgba(self.accent2 if j == 0 else (255, 255, 255), 230 if j == 0 else 110), width=4 if j == 0 else 2)
        save_png(arc, img / 'whl_arc.png')
        # selection: a glow under the chosen logo and a pointer on the rim
        sel = radial_fast(520, 190, self.accent, alpha=150)
        sel = Image.alpha_composite(sel, glow_line_layer(520, 190, lambda d, s, f, w: d.polygon([(6 * s, 75 * s), (34 * s, 95 * s), (6 * s, 115 * s)], outline=f, width=w), self.accent2, 3, 5))
        save_png(sel, img / 'whl_sel.png')
        save_png(neon_frame(1180, 690, 1120, 630, self.accent, r=12, width=4, blur=12, fill=(0, 0, 0, 210)), img / 'whl_video_frame.png')
        tk = vgrad(1240, 36, (20, 6, 34, 230), (8, 2, 16, 240))
        tk = Image.alpha_composite(tk, glow_line_layer(1240, 36, lambda d, s, f, w: d.line((0, 1 * s, 1240 * s, 1 * s), fill=f, width=w), self.accent2, 2, 3))
        save_png(tk, img / 'whl_ticker.png')
        top = vgrad(W, 78, (0, 0, 0, 200), (0, 0, 0, 0))
        save_png(top, img / 'whl_top.png')
        self.art_common(img)

    def game_xml(self):
        items = []
        for j in range(-6, 7):
            x, y, ang = self.slot(j)
            a = 0 if abs(j) == 6 else (1 if j == 0 else round(.85 - abs(j) * .12, 2))
            w, mh = (440, 170) if j == 0 else (330, 118)
            sel = ' selected="true" layer="16"' if j == 0 else ''
            items.append(f'    <item{sel} xOffset="{round(x - self.SEL[0])}" yOffset="{round(y - self.SEL[1])}" angle="{round(ang, 1)}" width="{w}" maxHeight="{mh}" alpha="{a}"/>')
        menu = ('  <menu type="custom" imageType="logo" scrollTime=".16" scrollAcceleration=".035" minScrollTime=".05" orientation="vertical">\n'
                f'    <itemDefaults x="{self.SEL[0]}" y="{self.SEL[1]}" xOrigin="center" yOrigin="center" width="330" maxHeight="118" alpha="0" layer="15" fontColor="ffffff" fontSize="36" loadFontSize="36"/>\n'
                + '\n'.join(items) + '\n  </menu>\n')
        return (x_head('  AM-Wheel - GAME LIST (c) The Real Z Studios - all art drawn by tools/New-ArcadeThemes.py\n'
                       '  Idea: the curved, tilted logo wheel of CoinOPS Wheel Ani / CORE TYPE R, on a neon arc at the right with a\n'
                       '  glass band under the logos; the video big on the left; am_story runs as a ticker along the bottom.\n'
                       '  Keys: UP / DOWN games, LEFT / RIGHT playlists (menu is orientation="vertical").')
                + x_sounds()
                + x_image('images/whl_bg.jpg', 0, 0, W, H, 0, origin=False)
                + x_backdrop(.65, 1)
                + x_image('images/whl_top.png', 0, 0, W, 78, 2, origin=False)
                + f'  <image src="images/whl_arc.png" x="{self.ARC_X}" y="0" width="{W - self.ARC_X}" height="{H}" alpha="1" layer="3">\n'
                  '    <onMenuScroll><set duration=".05"><animate type="x" to="1150"/></set></onMenuScroll>\n'
                  f'    <onMenuIdle><set duration=".3"><animate type="x" to="{self.ARC_X}" algorithm="easeOutBounce"/></set></onMenuIdle>\n  </image>\n'
                + f'  <image src="images/whl_sel.png" x="{self.SEL[0] - 20}" y="{self.SEL[1]}" xOrigin="center" yOrigin="center" width="520" height="190" alpha=".8" layer="14">\n'
                  '    <onMenuScroll><set duration=".05"><animate type="alpha" to="1"/></set></onMenuScroll>\n'
                  '    <onMenuIdle><set duration="1.2"><animate type="alpha" to=".5" algorithm="easeInOutSine"/></set>'
                  '<set duration="1.2"><animate type="alpha" to=".9" algorithm="easeInOutSine"/></set></onMenuIdle>\n  </image>\n'
                + menu
                + x_playlist(330, 38, 560, 54, 11, 640, 38, 24, iorigin='left', crumb=(640, 86, 20))
                + x_text('title', 1180, 38, 32, 'ffffff', 11, 'right')
                + x_image('images/whl_video_frame.png', 640, 420, 1180, 690, 5)
                + x_video(640, 420, 1120, 630, 6)
                + x_hint(640, 150, 980, 92, 17)
                + x_controls(650, 892, 1100, 300, 12)
                + x_text('year', 40, 1062, 22, 'ff2fa0', 13, 'left')
                + x_image('images/whl_ticker.png', 0, 1044, 1240, 36, 12, origin=False)
                + x_story(110, 1046, 1110, 32, 22, 13, color='e6e9f0', delay='1.2', direction='horizontal', speed=90)
                + x_launch()
                + '</layout>\n')

    def main_deco(self):
        return x_image(f'../../../images/whl_arc.png', self.ARC_X, 0, W - self.ARC_X, H, 2, alpha='.45', origin=False)

    def preview(self, s):
        c = s.base(self, backdrop_alpha=.65)
        s.paste(c, self.img('whl_top.png'), 0, 0, W, 78, origin=False)
        s.paste(c, self.img('whl_arc.png'), self.ARC_X, 0, W - self.ARC_X, H, origin=False)
        s.paste(c, self.img('whl_sel.png'), self.SEL[0] - 20, self.SEL[1], 520, 190, alpha=.8)
        for j in range(-5, 6):
            x, y, ang = self.slot(j)
            w, mh = (440, 170) if j == 0 else (330, 118)
            s.fit(c, s.logo(j), x, y, w, mh, alpha=1 if j == 0 else .85 - abs(j) * .12, angle=ang)
        s.playlist(c, 330, 38, 560, 54)
        s.text(c, s.index, 640, 38, 24, (154, 163, 178), anchor='lm')
        s.text(c, s.title, 1180, 38, 32, (255, 255, 255), anchor='rm')
        s.fit(c, s.video, 640, 420, 1120, 630)
        s.paste(c, self.img('whl_video_frame.png'), 640, 420, 1180, 690)
        s.paste(c, s.hint, 640, 150, 980, 92)
        s.paste(c, s.controls, 650, 892, 1100, 300)
        s.paste(c, self.img('whl_ticker.png'), 0, 1044, 1240, 36, origin=False)
        s.text(c, s.year, 40, 1062, 22, (255, 47, 160), anchor='lm')
        s.text(c, ' '.join(s.story_lines[2:6])[:120] + ' ...', 110, 1062, 22, (230, 233, 240), anchor='lm')
        return c


# ------------------------------------------------------------------------------------------------ AM-Poster
class Poster(Theme):
    name, p = 'Poster', 'pst'
    label = 'Box Art'
    about = 'a box-art carousel along the bottom over the game\'s full-screen backdrop'
    idea = ('CoinOPS "Poster" and "Bottom Spin" (a cover carousel with tilted neighbours along the bottom) - here over the '
            'game\'s own full-bleed backdrop, scrolled with UP / DOWN so LEFT / RIGHT keep the playlists')
    keys = 'UP / DOWN: previous / next box (the row is sideways, the menu is vertical)   LEFT / RIGHT: playlists'
    accent, accent2, bg_dark = (255, 200, 90), (255, 255, 255), (6, 6, 10)
    PX, PY = 960, 845
    SLOTS = {0: (0, 0, 300, 280, 0, 1), 1: (300, 18, 230, 215, 4, .9), 2: (540, 32, 200, 185, 6, .7),
             3: (750, 44, 175, 160, 8, .5), 4: (935, 54, 150, 140, 10, .3), 5: (1110, 60, 150, 140, 12, 0)}

    def art(self, img):
        save_jpg(plain_bg((24, 22, 28), (6, 6, 9)), img / 'pst_bg.jpg')
        save_png(vgrad(W, 560, (0, 0, 0, 0), (0, 0, 0, 235)), img / 'pst_shade.png')
        save_png(vgrad(W, 300, (0, 0, 0, 200), (0, 0, 0, 0)), img / 'pst_top.png')
        save_png(radial_fast(760, 220, (255, 214, 150), alpha=120), img / 'pst_spot.png')
        vf = neon_frame(808, 472, 768, 432, self.accent, r=6, width=3, blur=6, fill=(0, 0, 0, 200), core=(255, 245, 220))
        d = ImageDraw.Draw(vf)
        for (x, y) in ((10, 10), (798, 10), (10, 462), (798, 462)):     # corner studs
            d.ellipse((x - 6, y - 6, x + 6, y + 6), fill=rgba(self.accent, 255), outline=(255, 245, 220, 255))
        save_png(vf, img / 'pst_video_frame.png')
        rail = glow_line_layer(W, 16, lambda d2, s, f, w: d2.line((120 * s, 8 * s, (W - 120) * s, 8 * s), fill=f, width=w), self.accent, 2, 4)
        save_png(rail, img / 'pst_rail.png')
        sb = blank(768, 150)
        ImageDraw.Draw(sb).rounded_rectangle((0, 0, 767, 149), radius=8, fill=(0, 0, 0, 170), outline=rgba(self.accent, 80), width=1)
        save_png(sb, img / 'pst_story.png')
        self.art_common(img)

    def game_xml(self):
        items = []
        for j in range(-5, 6):
            dx, dy, w, mh, ang, a = self.SLOTS[abs(j)]
            sg = -1 if j < 0 else 1
            sel = ' selected="true"' if j == 0 else ''
            items.append(f'    <item{sel} xOffset="{dx * sg}" yOffset="{dy}" angle="{ang * sg}" width="{w}" maxHeight="{mh}" alpha="{a}" layer="{14 - abs(j)}"/>')
        menu = ('  <menu type="custom" imageType="cover" scrollTime=".2" scrollAcceleration=".04" minScrollTime=".06" orientation="vertical">\n'
                f'    <itemDefaults x="{self.PX}" y="{self.PY}" xOrigin="center" yOrigin="center" width="200" maxHeight="185" alpha="0" layer="10" fontColor="ffffff" fontSize="30" loadFontSize="30"/>\n'
                + '\n'.join(items) + '\n  </menu>\n')
        return (x_head('  AM-Poster - GAME LIST (c) The Real Z Studios - all art drawn by tools/New-ArcadeThemes.py\n'
                       '  Idea: the cover carousel of CoinOPS Poster / Bottom Spin (tilted neighbours, the chosen box in front), over the\n'
                       '  game\'s own full-bleed backdrop (am_backdrop at full strength), video top right, controls card top left.\n'
                       '  KEYS: the row is laid out sideways but the menu is orientation="vertical": UP / DOWN = previous / next box,\n'
                       '  LEFT / RIGHT stay on the playlists. Games without a cover show their title as text.')
                + x_sounds()
                + x_image('images/pst_bg.jpg', 0, 0, W, H, 0, origin=False)
                + x_backdrop(1, 1)
                + x_image('images/pst_top.png', 0, 0, W, 300, 2, origin=False)
                + x_image('images/pst_shade.png', 0, 520, W, 560, 2, origin=False)
                + f'  <image src="images/pst_spot.png" x="{self.PX}" y="985" xOrigin="center" yOrigin="center" width="760" height="220" alpha=".8" layer="3">\n'
                  '    <onMenuScroll><set duration=".05"><animate type="alpha" to=".35"/></set></onMenuScroll>\n'
                  '    <onMenuIdle><set duration=".4"><animate type="alpha" to=".8" algorithm="easeOutCubic"/></set></onMenuIdle>\n  </image>\n'
                + x_image('images/pst_rail.png', 0, 990, W, 16, 4, origin=False)
                + menu
                + x_text('title', self.PX, 1040, 30, 'ffffff', 12)
                + x_playlist(1500, 38, 600, 58, 11, 1500, 548, 22, hints='left')
                + '  <reloadableImage type="logo" x="565" y="170" xOrigin="center" yOrigin="center" width="500" maxHeight="150" alpha="0" layer="6">\n'
                  '    <onMenuScroll><set duration=".05"><animate type="alpha" to="0"/><animate type="x" to="535"/></set></onMenuScroll>\n'
                  '    <onMenuIdle><set duration=".35"><animate type="alpha" to="1" algorithm="easeOutCubic"/><animate type="x" to="565" algorithm="easeOutCubic"/></set></onMenuIdle>\n'
                  f'    {HIDE_ON_EXIT}\n  </reloadableImage>\n'
                + x_image('images/pst_video_frame.png', 1500, 300, 808, 472, 5)
                + x_video(1500, 300, 768, 432, 6)
                + x_image('images/pst_story.png', 1500, 645, 768, 150, 5)
                + x_story(1126, 578, 740, 134, 22, 7, delay='1.4', speed=12)
                + x_controls(565, 410, 1100, 300, 12)
                + x_hint(565, 615, 980, 92, 17)
                + x_launch()
                + '</layout>\n')

    def main_deco(self):
        return x_image('../../../images/pst_shade.png', 0, 520, W, 560, 2, origin=False)

    def preview(self, s):
        c = s.base(self, backdrop_alpha=1)
        s.paste(c, self.img('pst_top.png'), 0, 0, W, 300, origin=False)
        s.paste(c, self.img('pst_shade.png'), 0, 520, W, 560, origin=False)
        s.paste(c, self.img('pst_spot.png'), self.PX, 985, 760, 220, alpha=.8)
        s.paste(c, self.img('pst_rail.png'), 0, 990, W, 16, origin=False)
        for j in sorted(range(-4, 5), key=lambda v: -abs(v)):
            dx, dy, w, mh, ang, a = self.SLOTS[abs(j)]
            sg = -1 if j < 0 else 1
            s.fit(c, s.cover(j), self.PX + dx * sg, self.PY + dy, w, mh, alpha=a, angle=ang * sg)
        s.text(c, s.title, self.PX, 1040, 30, (255, 255, 255))
        s.playlist(c, 1500, 38, 600, 58)
        s.text(c, s.index, 1500, 548, 22, (154, 163, 178))
        s.fit(c, s.logo(0), 565, 170, 500, 150)
        s.fit(c, s.video, 1500, 300, 768, 432)
        s.paste(c, self.img('pst_video_frame.png'), 1500, 300, 808, 472)
        s.paste(c, self.img('pst_story.png'), 1500, 645, 768, 150)
        s.story_box(c, 1126, 578, 740, 134, 22)
        s.paste(c, s.controls, 565, 410, 1100, 300)
        s.paste(c, s.hint, 565, 615, 980, 92)
        return c


# -------------------------------------------------------------------------------------------------- AM-Neon
class Neon(Theme):
    name, p = 'Neon', 'neon'
    label = 'Neon Lite'
    about = 'a centred neon text list under a huge logo: the lightest theme, for weak PCs'
    idea = ('CoinOPS "Vertical" / "Fast" (a plain list, little else) - here a centred neon TEXT list (no list pictures to '
            'load), one huge logo, the fewest layers of all five themes')
    accent, accent2, bg_dark = (0, 240, 255), (255, 40, 200), (2, 2, 8)
    LX, LY, STEP = 960, 520, 56

    def art(self, img):
        save_jpg(plain_bg((8, 8, 16), (0, 0, 3)), img / 'neon_bg.jpg')
        rule = glow_line_layer(1300, 30, lambda d, s, f, w: d.line((30 * s, 15 * s, 1270 * s, 15 * s), fill=f, width=w), self.accent, 3, 6)
        rd = ImageDraw.Draw(rule)
        rd.ellipse((644, 9, 656, 21), fill=rgba(self.accent2, 255))
        save_png(rule, img / 'neon_rule.png')
        save_png(neon_frame(720, 84, 660, 50, self.accent2, r=24, width=3, blur=8), img / 'neon_bar.png')
        save_png(neon_frame(660, 380, 600, 338, self.accent, r=10, width=3, blur=9, fill=(0, 0, 0, 200)), img / 'neon_video_frame.png')
        self.art_common(img)

    def game_xml(self):
        items = []
        for j in range(-5, 6):
            a = 0 if abs(j) >= 4 else (1 if j == 0 else round(.75 - abs(j) * .17, 2))   # rows +-4 would touch the rule
            if j == 0:
                items.append(f'    <item selected="true" fontSize="46" fontColor="ffffff" alpha="1"/>')
            else:
                items.append(f'    <item yOffset="{j * self.STEP}" alpha="{a}"/>')
        menu = ('  <!-- imageType "am_text" has no pictures on purpose: textFallback draws each game\'s title as text (nothing to load) -->\n'
                '  <menu type="custom" imageType="am_text" textFallback="true" scrollTime=".12" scrollAcceleration=".035" minScrollTime=".04" orientation="vertical">\n'
                f'    <itemDefaults x="{self.LX}" y="{self.LY}" xOrigin="center" yOrigin="center" width="640" maxWidth="640" alpha="0" layer="10" fontColor="7fefff" fontSize="36" loadFontSize="46"/>\n'
                + '\n'.join(items) + '\n  </menu>\n')
        return (x_head('  AM-Neon - GAME LIST (c) The Real Z Studios - all art drawn by tools/New-ArcadeThemes.py\n'
                       '  Idea: CoinOPS Vertical / Fast (a plain list) made neon: a centred TEXT list, one huge logo, a small video.\n'
                       '  The lightest theme: one opaque background, the backdrop at low strength, no list pictures to load,\n'
                       '  no motion except fades and a pulsing selection bar. For weak PCs.\n'
                       '  Keys: UP / DOWN games, LEFT / RIGHT playlists (menu is orientation="vertical").')
                + x_sounds()
                + x_image('images/neon_bg.jpg', 0, 0, W, H, 0, origin=False)
                + x_backdrop(.45, 1)
                + '  <reloadableImage type="logo" x="960" y="150" xOrigin="center" yOrigin="center" width="800" maxHeight="240" alpha="0" layer="5">\n'
                  f'    {HIDE_ON_SCROLL}\n    <onMenuIdle>{fade(1, ".3")}</onMenuIdle>\n    {HIDE_ON_EXIT}\n  </reloadableImage>\n'
                + x_image('images/neon_rule.png', 960, 290, 1300, 30, 4)
                + f'  <image src="images/neon_bar.png" x="{self.LX}" y="{self.LY}" xOrigin="center" yOrigin="center" width="720" height="84" alpha="1" layer="9">\n'
                  '    <onMenuIdle><set duration="1"><animate type="alpha" to=".55" algorithm="easeInOutSine"/></set>'
                  '<set duration="1"><animate type="alpha" to="1" algorithm="easeInOutSine"/></set></onMenuIdle>\n  </image>\n'
                + menu
                + x_playlist(330, 40, 500, 49, 11, 330, 84, 22, '7fefff')
                + x_text('year', 1880, 40, 26, 'ff28c8', 11, 'right')
                + x_text('manufacturer', 1880, 80, 24, '7fefff', 11, 'right')
                + x_image('images/neon_video_frame.png', 330, 520, 660, 380, 5)
                + x_video(330, 520, 600, 338, 6, delay='.4')
                + x_hint(330, 725, 600, 56, 17)
                + x_story(1300, 350, 590, 340, 24, 10, color='bfefff', delay='1')
                + x_controls(960, 905, 1100, 300, 12)
                + x_launch()
                + '</layout>\n')

    def main_deco(self):
        return x_image('../../../images/neon_rule.png', 960, 560, 1300, 30, 4)

    def preview(self, s):
        c = s.base(self, backdrop_alpha=.45)
        s.fit(c, s.logo(0), 960, 150, 800, 240)
        s.paste(c, self.img('neon_rule.png'), 960, 290, 1300, 30)
        s.paste(c, self.img('neon_bar.png'), self.LX, self.LY, 720, 84)
        for j in range(-3, 4):
            a = 1 if j == 0 else max(.12, .75 - abs(j) * .17)
            col = (255, 255, 255) if j == 0 else (127, 239, 255)
            s.text(c, s.name_of(j), self.LX, self.LY + j * self.STEP, 46 if j == 0 else 36, col, alpha=a)
        s.playlist(c, 330, 40, 500, 49)
        s.text(c, s.index, 330, 84, 22, (127, 239, 255))
        s.text(c, s.year, 1880, 40, 26, (255, 40, 200), anchor='rm')
        s.text(c, s.maker, 1880, 80, 24, (127, 239, 255), anchor='rm')
        s.fit(c, s.video, 330, 520, 600, 338)
        s.paste(c, self.img('neon_video_frame.png'), 330, 520, 660, 380)
        s.paste(c, s.hint, 330, 725, 600, 56)
        s.story_box(c, 1300, 350, 590, 340, 24, (191, 239, 255))
        s.paste(c, s.controls, 960, 905, 1100, 300)
        return c


# ------------------------------------------------------------------- rich pieces shared by Showcase and Arcade Hall
# (James 2026-11-27 on Box Art / Neon Lite: "We need something very graphical and elaborate like the default") - the
# default's own moving parts: the game's fanart drifting (Ken Burns), the per-system burst on every scroll (shared
# system_artwork, New-MenuHeroArt.py links it), the story glass, the launch sweep with the game's art and controls card.
def x_kenburns():
    return ('  <image src="images/bg_neutral.png" x="0" y="0" width="1920" height="1080" layer="0"/>\n'
            '  <reloadableImage type="am_backdrop" x="960" y="540" xOrigin="center" yOrigin="center" width="1920" height="1080" alpha="0" layer="1">\n'
            '    <onMenuScroll><set duration=".08"><animate type="alpha" to="0"/></set></onMenuScroll>\n'
            '    <onMenuIdle><set duration=".5"><animate type="alpha" from="0" to="1" algorithm="easeOutCubic"/></set>'
            '<set duration="16"><animate type="width" to="2060" algorithm="easeInOutSine"/><animate type="height" to="1159" algorithm="easeInOutSine"/></set>'
            '<set duration="16"><animate type="width" to="1920" algorithm="easeInOutSine"/><animate type="height" to="1080" algorithm="easeInOutSine"/></set></onMenuIdle>\n'
            f'    {HIDE_ON_EXIT}\n  </reloadableImage>\n'
            '  <reloadableImage type="fanart" x="960" y="540" xOrigin="center" yOrigin="center" width="1920" height="1080" alpha="0" layer="1">\n'
            '    <onMenuScroll><set duration=".08"><animate type="alpha" to="0"/></set></onMenuScroll>\n'
            '    <onMenuIdle><set duration=".45"><animate type="alpha" from="0" to="1" algorithm="easeOutCubic"/></set>'
            '<set duration="14"><animate type="width" to="2090" algorithm="easeInOutSine"/><animate type="height" to="1176" algorithm="easeInOutSine"/><animate type="x" to="900" algorithm="easeInOutSine"/><animate type="y" to="520" algorithm="easeInOutSine"/></set>'
            '<set duration="14"><animate type="width" to="1932" algorithm="easeInOutSine"/><animate type="height" to="1087" algorithm="easeInOutSine"/><animate type="x" to="1000" algorithm="easeInOutSine"/><animate type="y" to="550" algorithm="easeInOutSine"/></set>'
            '<set duration="10"><animate type="width" to="2040" algorithm="easeInOutSine"/><animate type="height" to="1148" algorithm="easeInOutSine"/><animate type="x" to="960" algorithm="easeInOutSine"/><animate type="y" to="540" algorithm="easeInOutSine"/></set></onMenuIdle>\n'
            '    <onGameEnter><set duration="1.2"><animate type="width" to="2600" algorithm="easeInCubic"/><animate type="height" to="1463" algorithm="easeInCubic"/></set></onGameEnter>\n'
            '    <onGameExit><set duration=".6"><animate type="width" to="1920"/><animate type="height" to="1080"/><animate type="x" to="960"/><animate type="y" to="540"/></set></onGameExit>\n'
            f'    {HIDE_ON_EXIT}\n  </reloadableImage>\n')


def x_burst_fx():
    return ('  <reloadableImage type="am_burst" mode="systemlayout" x="center" y="center" xOrigin="center" yOrigin="center" width="1920" height="1080" alpha="0" layer="15">\n'
            '    <onMenuScroll><set duration=".05"><animate type="alpha" to=".55"/><animate type="width" to="2200"/><animate type="height" to="1238"/></set></onMenuScroll>\n'
            '    <onMenuIdle><set duration=".45"><animate type="alpha" to="0" algorithm="easeOutCubic"/><animate type="width" to="1920"/><animate type="height" to="1080"/></set></onMenuIdle>\n'
            '    <onGameEnter><set duration=".8"><animate type="alpha" to="1"/><animate type="width" to="3000"/><animate type="height" to="1688"/></set></onGameEnter>\n'
            '    <onGameExit><set duration=".3"><animate type="alpha" to="0"/><animate type="width" to="1920"/><animate type="height" to="1080"/></set></onGameExit>\n'
            '  </reloadableImage>\n'
            '  <image src="images/fx_vignette.png" x="0" y="0" width="1920" height="1080" alpha=".4" layer="16"/>\n')


def x_story_glass(cx, cy, w, h):
    """after 8 s on one game a dark glass covers the video and the game's story scrolls (the default's behaviour)"""
    return (f'  <image src="images/black.png" x="{cx}" y="{cy}" xOrigin="center" yOrigin="center" width="{w}" height="{h}" alpha="0" layer="8">\n'
            '    <onMenuScroll><set duration=".05"><animate type="alpha" to="0"/></set></onMenuScroll>\n'
            '    <onMenuIdle><set duration="8"><animate type="nop"/></set><set duration=".6"><animate type="alpha" to=".84" algorithm="easeOutCubic"/></set></onMenuIdle>\n'
            f'    {HIDE_ON_GAME}\n    {HIDE_ON_EXIT}\n  </image>\n'
            f'  <reloadableScrollingText type="am_story" menuScrollReload="true" x="{cx - w // 2 + 40}" y="{cy - h // 2 + 30}" width="{w - 80}" height="{h - 60}" fontSize="28" loadFontSize="28" '
            'fontColor="e6e9f0" alignment="left" direction="vertical" scrollingSpeed="16" startPosition="0" startTime="10" endTime="5" alpha="0" layer="9">\n'
            '    <onMenuScroll><set duration=".05"><animate type="alpha" to="0"/></set></onMenuScroll>\n'
            '    <onMenuIdle><set duration="8.2"><animate type="nop"/></set><set duration=".6"><animate type="alpha" to="1" algorithm="easeOutCubic"/></set></onMenuIdle>\n'
            f'    {HIDE_ON_GAME}\n    {HIDE_ON_EXIT}\n  </reloadableScrollingText>\n')


def x_launch_rich():
    """the default's launch: a sweep down the screen, blackout, then the game's art, logo and controls card while it loads"""
    return ('  <image src="images/fx_sweep.png" x="0" y="-160" width="1920" height="160" alpha="0" layer="18">\n'
            '    <onGameEnter><set duration=".01"><animate type="alpha" to="1"/><animate type="y" to="-160"/></set>'
            '<set duration=".42"><animate type="y" to="1080" algorithm="easeInQuadratic"/></set><set duration=".01"><animate type="alpha" to="0"/></set></onGameEnter>\n  </image>\n'
            '  <image src="images/black.png" x="0" y="0" width="1920" height="1080" alpha="0" layer="18">\n'
            '    <onGameEnter><set duration=".35"><animate type="nop"/></set><set duration=".5"><animate type="alpha" to="1"/></set></onGameEnter>\n'
            '    <onGameExit><set duration=".6"><animate type="alpha" to="0"/></set></onGameExit>\n  </image>\n'
            '  <reloadableImage type="fanart" x="960" y="540" xOrigin="center" yOrigin="center" width="1920" height="1080" alpha="0" layer="19">\n'
            '    <onGameEnter><set duration=".55"><animate type="nop"/></set><set duration=".45"><animate type="alpha" to=".55" algorithm="easeOutCubic"/><animate type="width" to="1960"/><animate type="height" to="1103"/></set>'
            '<set duration="1.6"><animate type="width" to="2060" algorithm="easeInOutSine"/><animate type="height" to="1159" algorithm="easeInOutSine"/></set></onGameEnter>\n'
            '    <onGameExit><set duration=".01"><animate type="alpha" to="0"/><animate type="width" to="1920"/><animate type="height" to="1080"/></set></onGameExit>\n  </reloadableImage>\n'
            '  <reloadableImage type="logo" x="center" y="400" xOrigin="center" yOrigin="center" width="600" maxHeight="340" alpha="0" layer="19">\n'
            '    <onGameEnter><set duration=".35"><animate type="alpha" to="1" algorithm="easeOutCubic"/><animate type="width" to="900" algorithm="easeOutCubic"/></set><set duration="2.2"><animate type="nop"/></set></onGameEnter>\n'
            '    <onGameExit><set duration=".01"><animate type="alpha" to="0"/><animate type="width" to="600"/></set></onGameExit>\n  </reloadableImage>\n'
            '  <reloadableImage type="am_controls" x="960" y="840" xOrigin="center" yOrigin="center" width="1100" height="300" alpha="0" layer="19">\n'
            '    <onGameEnter><set duration=".8"><animate type="nop"/></set><set duration=".35"><animate type="alpha" to="1" algorithm="easeOutCubic"/><animate type="y" from="880" to="840" algorithm="easeOutCubic"/></set></onGameEnter>\n'
            '    <onGameExit><set duration=".01"><animate type="alpha" to="0"/></set></onGameExit>\n  </reloadableImage>\n'
            + x_loading())


def x_sparks(prefix, spots, layer=4, root=''):
    """sparks drifting up through the scene, each on its own slow loop (alpha / y only: cheap)"""
    out = ''
    for i, (x, y0, y1, size, dur, delay) in enumerate(spots):
        out += (f'  <image src="{root}images/{prefix}_spark.png" x="{x}" y="{y0}" xOrigin="center" yOrigin="center" width="{size}" height="{size}" alpha="0" layer="{layer}">\n'
                f'    <onIdle><set duration="{delay}"><animate type="nop"/></set>'
                f'<set duration=".6"><animate type="alpha" from="0" to=".9"/><animate type="y" from="{y0}" to="{y0 - (y0 - y1) // 6}"/></set>'
                f'<set duration="{dur}"><animate type="y" to="{y1}" algorithm="easeOutSine"/><animate type="alpha" to="0" algorithm="easeInQuadratic"/></set></onIdle>\n  </image>\n')
    return out


def beam_png(w, h, color, strength=.62):
    m = Image.new('L', (w, h))
    ImageDraw.Draw(m).polygon([(w // 2 - 24, 0), (w // 2 + 24, 0), (w, h), (0, h)], fill=255)
    m = m.filter(ImageFilter.GaussianBlur(34))
    fade_down = ImageChops.invert(Image.linear_gradient('L').resize((w, h)))
    a = ImageChops.multiply(m, fade_down).point(lambda v: int(v * strength))
    im = Image.new('RGBA', (w, h), rgba(color, 0))
    im.putalpha(a)
    return im


def spark_png(size, color):
    im = blank(size, size)
    d = ImageDraw.Draw(im)
    c = size // 2
    d.line((c, 4, c, size - 4), fill=rgba(color, 220), width=2)
    d.line((4, c, size - 4, c), fill=rgba(color, 220), width=2)
    glow = radial_fast(size, size, color, alpha=200, power=2.2)
    im = Image.alpha_composite(glow, im.filter(ImageFilter.GaussianBlur(1)))
    ImageDraw.Draw(im).ellipse((c - 3, c - 3, c + 3, c + 3), fill=(255, 255, 255, 255))
    return im


# ---------------------------------------------------------------------------------------------- AM-Showcase
class Showcase(Theme):
    name, p = 'Showcase', 'shw'
    label = 'Showcase'
    ENTRANCE = 'drop'        # main menu: characters fall in from above
    about = ('a stage: light beams sweep over the game\'s drifting fanart, its video glows in a double neon frame with a '
             'passing glint, the logo drops in, box art fans out on a lit floor')
    idea = 'a game reveal on a stage - spotlights, a big screen, the boxes lined up in front'
    keys = 'UP / DOWN: previous / next box (the row is sideways, the menu is vertical)   LEFT / RIGHT: playlists'
    accent, accent2, bg_dark = (255, 47, 160), (46, 200, 255), (8, 8, 14)
    VX, VY, VW, VH = 1060, 420, 1040, 585       # the video
    PX, PY = 560, 930                           # the box-art row
    SLOTS = {0: (0, 0, 230, 260, 0, 1), 1: (200, 14, 175, 205, 6, .85), 2: (360, 26, 150, 175, 10, .6),
             3: (490, 36, 130, 150, 14, .35), 4: (600, 42, 120, 140, 16, 0)}

    def art(self, img):
        save_jpg(plain_bg((22, 16, 34), (6, 6, 10)), img / 'shw_bg.jpg')
        shade = Image.new('RGBA', (W, H))
        top, mid = vgrad(W, 300, (0, 0, 0, 170), (0, 0, 0, 30)), vgrad(W, 480, (0, 0, 0, 30), (0, 0, 0, 230))
        shade.alpha_composite(top, (0, 0)); shade.alpha_composite(mid, (0, 600))
        save_png(shade, img / 'shw_shade.png')
        save_png(beam_png(720, 1300, (190, 230, 255)), img / 'shw_beam.png')
        save_png(beam_png(720, 1300, (255, 150, 220)), img / 'shw_beam2.png')
        fw, fh = self.VW + 90, self.VH + 90
        outer = neon_frame(fw, fh, self.VW + 40, self.VH + 40, self.accent2, r=20, width=3, blur=16)
        inner = neon_frame(fw, fh, self.VW, self.VH, self.accent, r=12, width=5, blur=12, fill=(0, 0, 0, 200))
        save_png(Image.alpha_composite(outer, inner), img / 'shw_frame.png')
        g = Image.new('L', (220, 900))
        ImageDraw.Draw(g).rectangle((80, 0, 140, 900), fill=150)
        g = g.filter(ImageFilter.GaussianBlur(22)).rotate(-22, expand=True)
        glint = Image.new('RGBA', g.size, (255, 255, 255, 0)); glint.putalpha(g)
        save_png(glint, img / 'shw_glint.png')
        save_png(radial_fast(1300, 240, self.accent, alpha=150), img / 'shw_floor.png')
        save_png(radial_fast(440, 440, (255, 255, 255), alpha=120), img / 'shw_sel.png')
        save_png(glow_line_layer(W, 16, lambda d2, s, f, w: d2.line((60 * s, 8 * s, (W - 60) * s, 8 * s), fill=f, width=w), self.accent2, 2, 5), img / 'shw_rail.png')
        panel = blank(430, 400)
        ImageDraw.Draw(panel).rounded_rectangle((0, 0, 429, 399), radius=18, fill=(6, 8, 16, 170), outline=rgba(self.accent2, 140), width=2)
        save_png(panel, img / 'shw_info.png')
        save_png(spark_png(48, self.accent2), img / 'shw_spark.png')
        self.art_common(img)

    def game_xml(self):
        items = []
        for j in range(-4, 5):
            dx, dy, w, mh, ang, a = self.SLOTS[abs(j)]
            sg = -1 if j < 0 else 1
            sel = ' selected="true"' if j == 0 else ''
            items.append(f'    <item{sel} xOffset="{dx * sg}" yOffset="{dy}" angle="{ang * sg}" width="{w}" maxHeight="{mh}" alpha="{a}" layer="{14 - abs(j)}"/>')
        menu = ('  <menu type="custom" imageType="cover" scrollTime=".18" scrollAcceleration=".04" minScrollTime=".06" orientation="vertical">\n'
                f'    <itemDefaults x="{self.PX}" y="{self.PY}" xOrigin="center" yOrigin="center" width="175" maxHeight="205" alpha="0" layer="10" fontColor="ffffff" fontSize="26" loadFontSize="26"/>\n'
                + '\n'.join(items) + '\n  </menu>\n')
        VX, VY = self.VX, self.VY
        beams = ''
        for src, x, a0, a1 in (('shw_beam.png', 330, 14, -8), ('shw_beam2.png', 1800, -14, 8)):
            beams += (f'  <image src="images/{src}" x="{x}" y="-40" xOrigin="center" yOrigin="top" width="720" height="1300" angle="{a0}" alpha=".75" layer="3">\n'
                      f'    <onIdle><set duration="7"><animate type="angle" to="{a1}" algorithm="easeInOutSine"/></set>'
                      f'<set duration="7"><animate type="angle" to="{a0}" algorithm="easeInOutSine"/></set></onIdle>\n'
                      '    <onMenuScroll><set duration=".05"><animate type="alpha" to="1"/></set></onMenuScroll>\n'
                      '    <onMenuIdle><set duration=".8"><animate type="alpha" to=".75" algorithm="easeOutCubic"/></set></onMenuIdle>\n  </image>\n')
        return (x_head('  AM-Showcase - GAME LIST (c) The Real Z Studios - art: tools/New-ArcadeThemes.py\n'
                       '  A stage: two light beams sweep over the game\'s own drifting fanart, the video glows in a double neon frame\n'
                       '  with a glint passing over it, the logo drops in, the box art fans out on a lit floor. KEYS: the row is sideways\n'
                       '  but the menu is vertical (UP / DOWN = previous / next box), LEFT / RIGHT = playlists.')
                + x_sounds()
                + x_kenburns()
                + x_image('images/shw_shade.png', 0, 0, W, H, 2, origin=False)
                + beams
                + x_sparks('shw', [(160, 1000, 380, 30, 7, 0), (760, 1040, 300, 22, 8, 2.5), (1300, 1000, 420, 26, 6.5, 1.2),
                                   (1700, 1040, 260, 34, 9, 3.6), (1880, 980, 500, 20, 7.5, 5), (420, 1030, 520, 18, 6, 4.4)])
                # the screen
                + x_image('images/shw_frame.png', VX, VY, self.VW + 90, self.VH + 90, 6)
                + (f'  <reloadableVideo type="am_video" imageType="logo" menuScrollReload="true" x="{VX}" y="{VY}" xOrigin="center" yOrigin="center" width="{self.VW}" maxHeight="{self.VH}" alpha="0" layer="5">\n'
                   f'    <onMenuScroll><set duration=".05"><animate type="alpha" to="0"/><animate type="width" to="{self.VW + 100}"/></set></onMenuScroll>\n'
                   f'    <onMenuIdle><set duration=".3"><animate type="nop"/></set><set duration=".3"><animate type="alpha" to="1" algorithm="easeOutCubic"/><animate type="width" to="{self.VW}" algorithm="easeOutCubic"/></set></onMenuIdle>\n'
                   f'    {HIDE_ON_EXIT}\n    <onGameEnter><set duration=".15"><animate type="alpha" to="0"/></set></onGameEnter>\n'
                   '    <onGameExit><set duration=".3"><animate type="alpha" to="1"/></set></onGameExit>\n  </reloadableVideo>\n')
                + (f'  <image src="images/shw_glint.png" x="{VX - self.VW // 2 - 150}" y="{VY}" xOrigin="center" yOrigin="center" width="540" height="960" alpha="0" layer="7">\n'
                   f'    <onIdle><set duration="2.5"><animate type="nop"/></set>'
                   f'<set duration=".01"><animate type="x" to="{VX - self.VW // 2 - 150}"/><animate type="alpha" to=".55"/></set>'
                   f'<set duration="1.1"><animate type="x" to="{VX + self.VW // 2 + 150}" algorithm="easeInOutSine"/></set>'
                   '<set duration=".01"><animate type="alpha" to="0"/></set><set duration="4"><animate type="nop"/></set></onIdle>\n'
                   f'    {HIDE_ON_GAME}\n  </image>\n')
                + x_story_glass(VX, VY, self.VW, self.VH)
                + x_hint(VX, VY - self.VH // 2 + 70, 900, 85, 17)
                + x_text('title', VX, 785, 34, 'ffffff', 10)
                # left: the logo drops in, what the game is
                + x_image('images/shw_info.png', 255, 420, 430, 400, 7)
                + ('  <reloadableImage type="logo" x="255" y="170" xOrigin="center" yOrigin="center" width="390" maxHeight="170" alpha="0" layer="9">\n'
                   '    <onMenuScroll><set duration=".05"><animate type="alpha" to="0"/><animate type="y" to="110"/></set></onMenuScroll>\n'
                   '    <onMenuIdle><set duration=".15"><animate type="nop"/></set><set duration=".45"><animate type="alpha" to="1" algorithm="easeOutCubic"/><animate type="y" to="250" algorithm="easeOutBounce"/></set></onMenuIdle>\n'
                   f'    {HIDE_ON_EXIT}\n  </reloadableImage>\n')
                + x_text('year', 255, 390, 64, 'ffe259', 9)
                + x_text('manufacturer', 255, 460, 32, '2ec8ff', 9)
                + x_text('genre', 255, 515, 24, 'c9ced8', 9)
                + x_playlist(300, 40, 520, 54, 11, 300, 92, 22, crumb=(600, 40, 24))
                # the floor and the boxes
                + x_image('images/shw_rail.png', 0, 812, W, 16, 4, origin=False)
                + (f'  <image src="images/shw_floor.png" x="{self.PX}" y="1010" xOrigin="center" yOrigin="center" width="1300" height="240" alpha=".85" layer="4">\n'
                   '    <onIdle><set duration="2.2"><animate type="alpha" to=".55" algorithm="easeInOutSine"/></set><set duration="2.2"><animate type="alpha" to=".85" algorithm="easeInOutSine"/></set></onIdle>\n  </image>\n')
                + (f'  <image src="images/shw_sel.png" x="{self.PX}" y="{self.PY}" xOrigin="center" yOrigin="center" width="440" height="440" alpha=".8" layer="5">\n'
                   '    <onMenuScroll><set duration=".05"><animate type="width" to="500"/><animate type="height" to="500"/></set></onMenuScroll>\n'
                   '    <onMenuIdle><set duration=".3"><animate type="width" to="440" algorithm="easeOutCubic"/><animate type="height" to="440" algorithm="easeOutCubic"/></set></onMenuIdle>\n  </image>\n')
                + menu
                + x_controls(1490, 935, 760, 207, 12)
                + x_burst_fx()
                + x_launch_rich()
                + '</layout>\n')

    def main_extras(self):
        """main menu: the stage's two light beams sweep over the hero show (under the characters, layer 11)"""
        out = ''
        for src, x, a0, a1 in (('shw_beam.png', 300, 16, -6), ('shw_beam2.png', 1700, -16, 6)):
            out += (f'  <image src="../../../images/{src}" x="{x}" y="-40" xOrigin="center" yOrigin="top" width="720" height="1300" angle="{a0}" alpha=".6" layer="11">\n'
                    f'    <onIdle><set duration="8"><animate type="angle" to="{a1}" algorithm="easeInOutSine"/></set>'
                    f'<set duration="8"><animate type="angle" to="{a0}" algorithm="easeInOutSine"/></set></onIdle>\n  </image>\n')
        return out

    def preview(self, s):
        c = s.base(self, backdrop_alpha=1)
        s.paste(c, self.img('shw_shade.png'), 0, 0, W, H, origin=False)
        s.paste(c, self.img('shw_beam.png'), 330, 610, 720, 1300, alpha=.75, angle=6)
        s.paste(c, self.img('shw_beam2.png'), 1800, 610, 720, 1300, alpha=.75, angle=-6)
        s.fit(c, s.video, self.VX, self.VY, self.VW, self.VH)
        s.paste(c, self.img('shw_frame.png'), self.VX, self.VY, self.VW + 90, self.VH + 90)
        s.text(c, s.title, self.VX, 785, 34, (255, 255, 255))
        s.paste(c, self.img('shw_info.png'), 255, 420, 430, 400)
        s.fit(c, s.logo(0), 255, 250, 390, 170)
        s.paste(c, self.img('shw_floor.png'), self.PX, 1010, 1300, 240, alpha=.85)
        s.paste(c, self.img('shw_sel.png'), self.PX, self.PY, 440, 440, alpha=.8)
        for j in sorted(range(-3, 4), key=lambda v: -abs(v)):
            dx, dy, w, mh, ang, a = self.SLOTS[abs(j)]
            sg = -1 if j < 0 else 1
            s.fit(c, s.cover(j), self.PX + dx * sg, self.PY + dy, w, mh, alpha=a, angle=ang * sg)
        s.paste(c, s.controls, 1490, 935, 760, 207)
        s.playlist(c, 300, 40, 520, 54)
        return c


# ------------------------------------------------------------------------------------------- AM-ArcadeHall
class Hall(Theme):
    name, p = 'ArcadeHall', 'hal'
    label = 'Arcade Hall'
    ENTRANCE = 'rise'        # main menu: characters come up from below
    about = ('a games room: the chosen game in a lit arcade cabinet (its marquee flickering on top, its video on the screen, '
             'its controls on the deck), the list a stack of glowing marquees, the default\'s gauges and sparks')
    idea = 'walking down a row of cabinets: every game is a lit marquee, the chosen one is the cabinet in front of you'
    accent, accent2, bg_dark = (255, 176, 0), (255, 47, 160), (10, 8, 14)
    CX, CY, CW, CH = 560, 570, 1080, 1020                 # the cabinet
    LX, LY = 1500, 540                                     # the marquee stack
    ROWS = {0: (0, 640, 170, 1), 1: (185, 540, 140, .75), 2: (340, 470, 120, .45), 3: (470, 420, 110, 0)}

    def art(self, img):
        save_jpg(plain_bg((26, 16, 22), (6, 5, 8)), img / 'hal_bg.jpg')
        shade = Image.new('RGBA', (W, H))
        shade.alpha_composite(vgrad(W, 1080, (0, 0, 0, 120), (0, 0, 0, 200)), (0, 0))
        save_png(shade, img / 'hal_shade.png')
        cw, ch = self.CW, self.CH
        cab = blank(cw, ch)
        d = ImageDraw.Draw(cab)
        d.rounded_rectangle((10, 0, cw - 10, ch - 1), radius=28, fill=(16, 14, 22, 240))
        d.rounded_rectangle((40, 730, cw - 40, ch - 6), radius=16, fill=(30, 28, 40, 245))       # the control deck
        cab = punch(cab, (40, 25, cw - 40, 175), 10)                                                 # marquee window
        cab = punch(cab, (100, 205, cw - 100, 700), 10)                                              # the screen
        rim = glow_line_layer(cw, ch, rrect_fn((12, 2, cw - 12, ch - 3), 28), self.accent, 3, 14)    # T-molding
        bez = glow_line_layer(cw, ch, rrect_fn((96, 201, cw - 96, 704), 12), self.accent2, 3, 10)    # screen bezel
        mq = glow_line_layer(cw, ch, rrect_fn((36, 21, cw - 36, 179), 12), self.accent, 2, 8)        # marquee rim
        save_png(cab, img / 'hal_cab.png')
        save_png(Image.alpha_composite(Image.alpha_composite(rim, bez), mq), img / 'hal_glow.png')
        g = Image.new('L', (880, 495))
        ImageDraw.Draw(g).polygon([(0, 0), (380, 0), (120, 495), (0, 495)], fill=26)
        g = g.filter(ImageFilter.GaussianBlur(30))
        glass = Image.new('RGBA', g.size, (255, 255, 255, 0)); glass.putalpha(g)
        save_png(glass, img / 'hal_glass.png')
        save_png(neon_frame(700, 210, 660, 175, self.accent, r=14, width=4, blur=12, fill=(0, 0, 0, 150)), img / 'hal_sel.png')
        save_png(radial_fast(820, 260, self.accent, alpha=110), img / 'hal_selglow.png')
        save_png(spark_png(48, self.accent), img / 'hal_spark.png')
        self.art_common(img)

    def game_xml(self):
        rows = []
        for j in range(-3, 4):
            dy, w, mh, a = self.ROWS[abs(j)]
            sg = -1 if j < 0 else 1
            sel = ' selected="true"' if j == 0 else ''
            rows.append(f'    <item{sel} yOffset="{dy * sg}" width="{w}" maxHeight="{mh}" alpha="{a}" layer="{14 - abs(j)}"/>')
        menu = ('  <menu type="custom" imageType="marquee" scrollTime=".16" scrollAcceleration=".035" orientation="vertical">\n'
                f'    <itemDefaults x="{self.LX}" y="{self.LY}" xOrigin="center" yOrigin="center" width="540" maxHeight="140" alpha="0" layer="10" fontColor="ffffff" fontSize="34" loadFontSize="34"/>\n'
                + '\n'.join(rows) + '\n  </menu>\n')
        CX, CY = self.CX, self.CY
        mx, my = CX, CY - self.CH // 2 + 100          # marquee window centre
        sx, sy = CX, CY - self.CH // 2 + 452          # screen centre
        dx, dy = CX, CY - self.CH // 2 + 872          # deck centre
        flicker = ('    <onIdle><set duration="3.4"><animate type="alpha" to="1"/></set><set duration=".06"><animate type="alpha" to=".55"/></set>'
                   '<set duration=".05"><animate type="alpha" to="1"/></set><set duration=".08"><animate type="alpha" to=".7"/></set>'
                   '<set duration=".1"><animate type="alpha" to="1"/></set><set duration="2.6"><animate type="alpha" to=".92" algorithm="easeInOutSine"/></set>'
                   '<set duration="2"><animate type="alpha" to="1" algorithm="easeInOutSine"/></set></onIdle>\n')
        gauges = ''
        for gx, face, over, span in ((1230, 'am_gauge_face', 'am_gauge_over', 112), (1770, 'am_gauge2_face', 'am_gauge2_over', 128)):
            gauges += (f'  <reloadableImage type="{face}" mode="systemlayout" x="{gx}" y="985" xOrigin="center" yOrigin="center" width="190" height="190" layer="12"/>\n'
                       f'  <reloadableImage type="{over}" mode="systemlayout" x="{gx}" y="985" xOrigin="center" yOrigin="center" width="190" height="190" angle="-135" layer="13">\n'
                       f'    <onMenuScroll><set duration=".14"><animate type="angle" to="{span}" algorithm="easeOutQuadratic"/></set></onMenuScroll>\n'
                       '    <onMenuIdle><set duration=".5"><animate type="angle" to="-70" algorithm="easeOutCubic"/></set><set duration=".35"><animate type="angle" to="-104" algorithm="easeOutCubic"/></set>'
                       '<set duration="1.6"><animate type="angle" to="-98" algorithm="easeInOutSine"/></set></onMenuIdle>\n  </reloadableImage>\n')
        return (x_head('  AM-ArcadeHall - GAME LIST (c) The Real Z Studios - art: tools/New-ArcadeThemes.py\n'
                       '  A games room: the chosen game is the lit cabinet in front of you (its marquee flickering in the top window, its\n'
                       '  video on the screen, its controls card on the deck); the list is a stack of glowing marquees; the default\'s\n'
                       '  gauges answer every scroll. UP / DOWN = games, LEFT / RIGHT = playlists.')
                + x_sounds()
                + x_kenburns()
                + x_image('images/hal_shade.png', 0, 0, W, H, 2, origin=False)
                + x_sparks('hal', [(1160, 1060, 360, 30, 7, 0), (1880, 1040, 260, 24, 8.5, 2), (1320, 1000, 480, 20, 6, 3.3),
                                   (1650, 1060, 200, 28, 9, 1.1), (70, 1040, 300, 22, 7.5, 4.2)])
                # the cabinet
                + x_image('images/hal_cab.png', CX, CY, self.CW, self.CH, 5)
                + (f'  <image src="images/hal_glow.png" x="{CX}" y="{CY}" xOrigin="center" yOrigin="center" width="{self.CW}" height="{self.CH}" alpha="1" layer="6">\n'
                   + flicker + '  </image>\n')
                + (f'  <reloadableImage type="marquee" x="{mx}" y="{my}" xOrigin="center" yOrigin="center" width="1000" maxHeight="150" alpha="0" layer="4">\n'
                   '    <onMenuScroll><set duration=".05"><animate type="alpha" to=".25"/></set></onMenuScroll>\n'
                   '    <onMenuIdle><set duration=".3"><animate type="alpha" to="1" algorithm="easeOutCubic"/></set></onMenuIdle>\n'
                   + flicker.replace('to="1"/>', 'to="1"/>') + f'    {HIDE_ON_EXIT}\n  </reloadableImage>\n')
                + (f'  <reloadableVideo type="am_video" imageType="logo" menuScrollReload="true" x="{sx}" y="{sy}" xOrigin="center" yOrigin="center" width="880" maxHeight="495" alpha="0" layer="4">\n'
                   '    <onMenuScroll><set duration=".05"><animate type="alpha" to="0"/></set></onMenuScroll>\n'
                   '    <onMenuIdle><set duration=".3"><animate type="nop"/></set><set duration=".3"><animate type="alpha" to="1" algorithm="easeOutCubic"/></set></onMenuIdle>\n'
                   f'    {HIDE_ON_EXIT}\n    <onGameEnter><set duration=".15"><animate type="alpha" to="0"/></set></onGameEnter>\n'
                   '    <onGameExit><set duration=".3"><animate type="alpha" to="1"/></set></onGameExit>\n  </reloadableVideo>\n')
                + x_image('images/hal_glass.png', sx, sy, 880, 495, 7)
                + x_story_glass(sx, sy, 880, 495)
                + x_hint(sx, sy - 180, 820, 78, 17)
                + x_controls(dx, dy, 990, 270, 8)
                # the marquee stack
                + (f'  <image src="images/hal_selglow.png" x="{self.LX}" y="{self.LY}" xOrigin="center" yOrigin="center" width="820" height="260" alpha=".7" layer="8">\n'
                   '    <onIdle><set duration="1.4"><animate type="alpha" to=".4" algorithm="easeInOutSine"/></set><set duration="1.4"><animate type="alpha" to=".75" algorithm="easeInOutSine"/></set></onIdle>\n  </image>\n')
                + (f'  <image src="images/hal_sel.png" x="{self.LX}" y="{self.LY}" xOrigin="center" yOrigin="center" width="700" height="210" alpha="1" layer="9">\n'
                   '    <onMenuScroll><set duration=".06"><animate type="width" to="740"/><animate type="height" to="222"/></set></onMenuScroll>\n'
                   '    <onMenuIdle><set duration=".2"><animate type="width" to="700" algorithm="easeOutCubic"/><animate type="height" to="210" algorithm="easeOutCubic"/></set></onMenuIdle>\n  </image>\n')
                + menu
                + x_text('title', self.LX, 965, 32, 'ffffff', 12)
                + x_text('year', self.LX - 110, 1025, 30, 'ffb000', 12)
                + x_text('manufacturer', self.LX + 110, 1025, 28, 'ff2fa0', 12)
                + gauges
                + x_playlist(1500, 40, 560, 52, 11, 1500, 92, 22, crumb=(40, 28, 22))
                + x_burst_fx()
                + x_launch_rich()
                + '</layout>\n')

    def main_extras(self):
        """main menu: the hall's sparks drift up through the hero show"""
        return x_sparks('hal', [(200, 1060, 300, 32, 7, 0), (900, 1040, 240, 24, 8.5, 1.8), (1250, 1000, 420, 22, 6, 3.1),
                                (1650, 1060, 200, 30, 9, 1), (1860, 1020, 380, 20, 7, 4.4)], layer=11, root='../../../')

    def preview(self, s):
        c = s.base(self, backdrop_alpha=1)
        s.paste(c, self.img('hal_shade.png'), 0, 0, W, H, origin=False)
        CX, CY = self.CX, self.CY
        s.fit(c, s.marquee or s.logo(0), CX, CY - self.CH // 2 + 100, 1000, 150)
        s.fit(c, s.video, CX, CY - self.CH // 2 + 452, 880, 495)
        s.paste(c, self.img('hal_cab.png'), CX, CY, self.CW, self.CH)
        s.paste(c, self.img('hal_glow.png'), CX, CY, self.CW, self.CH)
        s.paste(c, s.controls, CX, CY - self.CH // 2 + 872, 990, 270)
        s.paste(c, self.img('hal_selglow.png'), self.LX, self.LY, 820, 260, alpha=.7)
        s.paste(c, self.img('hal_sel.png'), self.LX, self.LY, 700, 210)
        for j in range(-2, 3):
            dy, w, mh, a = self.ROWS[abs(j)]
            s.fit(c, s.logo(j), self.LX, self.LY + dy * (-1 if j < 0 else 1), w, mh, alpha=a)
        s.text(c, s.title, self.LX, 965, 32, (255, 255, 255))
        s.playlist(c, 1500, 40, 560, 52)
        return c


# Box Art (Poster) and Neon Lite are retired (James 2026-11-27: "I don't like" them); Showcase and Arcade Hall take
# their place. Their classes stay above so an old install can still be rebuilt on purpose (--only Poster,Neon).
THEMES = [Wall(), Marquee(), Wheel(), Showcase(), Hall()]
RETIRED = {'Poster': Poster(), 'Neon': Neon()}


# ======================================================================================== preview mock-ups (Pillow)
class Samples:
    """sample media from a CoinOPS collection, used ONLY to draw the preview mock-up (never copied into a layout)"""

    def __init__(self, art: Path, playlist_dir: Path | None, layout_root: Path):
        self.art, self.layout_root = art, layout_root
        logos = sorted(p.stem for p in (art / 'logo').glob('*.png'))
        have = [n for n in logos if (art / 'cover' / f'{n}.jpg').exists() or (art / 'cover' / f'{n}.png').exists()]
        pick = [n for n in ('1942', 'sf2') if n in logos]
        rest = [n for n in have if n not in pick][:12]
        # list order: 6 before the chosen game, the chosen game (1942), then sf2 and the rest
        self.names = rest[:6] + pick + rest[6:]
        self.sel = self.names.index(pick[0]) if pick else 0
        self.selname = self.names[self.sel]
        g = self.selname
        self.controls = self._open('am_controls', g)
        self.hint = self._open('am_hint', g) or self._open('am_hint', 'centiped') or next((Image.open(p).convert('RGBA') for p in sorted((art / 'am_hint').glob('*.png'))[:1]), None)
        self.marquee = self._open('marquee', g)
        self.backdrop = self._open('am_backdrop', g)
        self.video = self._frame(art / 'am_video' / f'{g}.mp4') or self.backdrop
        st = art / 'am_story' / f'{g}.txt'
        self.story_lines = st.read_text(encoding='utf-8', errors='replace').splitlines() if st.exists() else [g]
        head = self.story_lines[0] if self.story_lines else g
        self.title, self.year, self.maker = head.split(' (')[0], '', ''
        if '(' in head and ',' in head:
            inner = head[head.index('(') + 1:head.rindex(')')]
            self.year, self.maker = [v.strip() for v in inner.split(',', 1)]
        self.index = f'{self.sel + 1} / {len(logos)}'
        self.pl = None
        if playlist_dir and (playlist_dir / 'all.png').exists():
            self.pl = Image.open(playlist_dir / 'all.png').convert('RGBA')

    def _open(self, kind, name):
        for ext in ('.png', '.jpg'):
            p = self.art / kind / f'{name}{ext}'
            if p.exists():
                return Image.open(p).convert('RGBA')
        return None

    def _frame(self, mp4: Path):
        ff = shutil.which('ffmpeg') or (FFMPEG_FALLBACK if Path(FFMPEG_FALLBACK).exists() else None)
        if not ff or not mp4.exists():
            return None
        with tempfile.TemporaryDirectory() as td:
            out = Path(td) / 'f.png'
            subprocess.run([ff, '-v', 'error', '-ss', '6', '-i', str(mp4), '-frames:v', '1', str(out)], timeout=60)
            return Image.open(out).convert('RGBA') if out.exists() else None

    def name_of(self, j):
        i = self.sel + j
        return self.names[i] if 0 <= i < len(self.names) else ''

    def logo(self, j):
        n = self.name_of(j)
        return self._open('logo', n) if n else None

    def cover(self, j):
        n = self.name_of(j)
        return self._open('cover', n) if n else None

    # ---- drawing in layout coordinates (1920x1080), mirroring RetroFE's width / maxHeight / origin rules
    def base(self, theme: Theme, backdrop_alpha):
        self.theme = theme
        c = Image.open(self.layout_root / theme.folder / 'images' / f'{theme.p}_bg.jpg').convert('RGBA')
        if self.backdrop:
            self.paste(c, self.backdrop, 0, 0, W, H, origin=False, alpha=backdrop_alpha)
        return c

    def paste(self, c, im, x, y, w, h, origin=True, alpha=1.0, angle=0):
        if im is None or alpha <= 0:
            return
        im = im.resize((int(round(w)), int(round(h))), Image.LANCZOS)
        if angle:
            im = im.rotate(-angle, resample=Image.BICUBIC, expand=True)
        if alpha < 1:
            im.putalpha(im.getchannel('A').point(lambda v: int(v * alpha)))
        px, py = (x - im.width / 2, y - im.height / 2) if origin else (x, y)
        layer = blank(W, H)
        layer.paste(im, (int(round(px)), int(round(py))))
        c.alpha_composite(layer)

    def fit(self, c, im, x, y, w, mh, alpha=1.0, angle=0):
        """RetroFE width + maxHeight: scale to the width, then down to maxHeight if taller (aspect kept)"""
        if im is None:
            return
        s = w / im.width
        if im.height * s > mh:
            s = mh / im.height
        self.paste(c, im, x, y, im.width * s, im.height * s, alpha=alpha, angle=angle)

    def playlist(self, c, x, y, w, h):
        if self.pl:
            self.paste(c, self.pl, x, y, w, h)
        else:
            self.text(c, 'ALL GAMES', x, y, int(h * .6), (255, 255, 255))

    def text(self, c, s, x, y, size, color, anchor='mm', alpha=1.0):
        if not s:
            return
        layer = blank(W, H)
        ImageDraw.Draw(layer).text((x, y), s, font=font(size), fill=rgba(color, int(255 * alpha)), anchor=anchor)
        c.alpha_composite(layer)

    def story_box(self, c, x, y, w, h, size, color=(230, 233, 240)):
        f = font(size)
        layer = blank(W, H)
        d = ImageDraw.Draw(layer)
        yy = y
        for para in self.story_lines[2:]:
            words, line = para.split(), ''
            for wd in words:
                t = (line + ' ' + wd).strip()
                if d.textlength(t, font=f) > w:
                    d.text((x, yy), line, font=f, fill=rgba(color))
                    yy += int(size * 1.3)
                    line = wd
                else:
                    line = t
                if yy > y + h - size:
                    break
            if yy > y + h - size:
                break
            d.text((x, yy), line, font=f, fill=rgba(color))
            yy += int(size * 1.3)
        c.alpha_composite(layer)

    def render(self, theme: Theme) -> Image.Image:
        c = theme.preview(self)
        d = ImageDraw.Draw(c)                                   # small caption so the picker card says what it is
        d.rounded_rectangle((20, H - 70, 620, H - 16), radius=10, fill=(0, 0, 0, 170))
        d.text((40, H - 43), f'{theme.folder}  -  {theme.label}', font=font(30, bold=True), fill=(255, 255, 255, 255), anchor='lm')
        return c.convert('RGB').resize((960, 540), Image.LANCZOS)


def _img(self, name):
    return Image.open(self.root / self.folder / 'images' / name).convert('RGBA')


Theme.img = _img


# ================================================================================================= build / install
SUPPORT_IMAGES = ['black.png', 'fx_sun_glow.png', 'studio_realz.png', 'fx_vignette.png', 'bg_neutral.png',
                  'fx_scrim_gamelist.png', 'ui_select_frame.png', 'ui_touchbar.png']


def write(path: Path, text: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding='utf-8', newline='\n')
    ET.parse(path)                                   # every layout must be well-formed XML


def main_variant(xml: str, theme) -> str:
    """The shared hero main menu, given the theme's own character entrance and extras. The default slides each character
    in from the right (x 2200 -> 1480) and back out; a theme can make them
      drop - fall in from above with a bounce, leave upwards      rise - come up from below, sink back down
      spin - spin in on the spot, spin out
    and add its own layers (Showcase's light beams, Arcade Hall's sparks) via main_extras()."""
    style = getattr(theme, 'ENTRANCE', '')
    if style in ('drop', 'rise'):
        start = '-420' if style == 'drop' else '1560'
        easing = 'easeOutBounce' if style == 'drop' else 'easeOutBack'
        xml = xml.replace('x="2200" y="775"', f'x="1480" y="{start}"')
        xml = xml.replace('<animate type="x" from="2200" to="1480" algorithm="easeOutBack"/>',
                          f'<animate type="y" from="{start}" to="775" algorithm="{easing}"/>')
        xml = xml.replace('<animate type="x" to="2200" algorithm="easeInBack"/>', f'<animate type="y" to="{start}" algorithm="easeInBack"/>')
    elif style == 'spin':
        xml = xml.replace('x="2200" y="775"', 'x="1480" y="775"')
        xml = xml.replace('<animate type="x" from="2200" to="1480" algorithm="easeOutBack"/>',
                          '<animate type="angle" from="-200" to="0" algorithm="easeOutBack"/>')
        xml = xml.replace('<animate type="x" to="2200" algorithm="easeInBack"/>', '<animate type="angle" to="200" algorithm="easeInBack"/>')
    extra = theme.main_extras() if hasattr(theme, 'main_extras') else ''
    if extra:
        xml = xml.replace('</layout>', extra + '</layout>')
    return xml


def copy_named_files(xml: Path, src_root: Path, dst_root: Path):
    """every file a layout names (src="images/..", font="fonts/..", sound="sounds/..") that is in the source layout,
    copied to the same place in the theme. Paths in a RetroFE layout are relative to the layout folder; per-game media
    (reloadableImage types) are not files and are skipped."""
    text = xml.read_text(encoding='utf-8')
    for m in re.finditer(r'(?:src|font|sound)="([^"]+\.(?:png|jpg|jpeg|gif|ttf|otf|wav|mp3|ogg))"', text, re.I):
        rel = m.group(1).replace('\\', '/')
        s = src_root / rel
        if s.is_file():
            d = dst_root / rel
            d.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(s, d)


def build(theme: Theme, root: Path):
    out = root / theme.folder
    img = out / 'images'
    img.mkdir(parents=True, exist_ok=True)
    theme.root = root
    theme.art(img)
    write(out / 'layout.xml', theme.game_xml())
    write(out / 'layout - 1.xml', theme.screen2_xml())
    write(out / 'collections' / 'Main' / 'layout' / 'layout.xml', theme.main_xml())
    write(out / 'collections' / 'Main' / 'layout' / 'layout - 1.xml', theme.main2_xml())
    # ArcadeMaster's own pieces, so the theme is complete on its own: boot intro, Tools screen, sounds, font, the
    # main-menu collection logos (all ArcadeMaster art; git stores identical files once)
    shutil.copy2(SRC / 'splash.xml', out / 'splash.xml')
    tools = out / 'collections' / 'Tools' / 'layout'
    tools.mkdir(parents=True, exist_ok=True)
    shutil.copy2(SRC / 'collections' / 'Tools' / 'layout' / 'layout.xml', tools / 'layout.xml')
    for f in SUPPORT_IMAGES:
        shutil.copy2(SRC / 'images' / f, img / f)
    shutil.copytree(SRC / 'images' / 'intro', img / 'intro', dirs_exist_ok=True)
    shutil.copytree(SRC / 'sounds', out / 'sounds', dirs_exist_ok=True)
    shutil.copytree(SRC / 'fonts', out / 'fonts', dirs_exist_ok=True)
    shutil.copytree(SRC / 'collections' / 'Main' / 'medium_artwork' / 'logo', out / 'collections' / 'Main' / 'medium_artwork' / 'logo', dirs_exist_ok=True)
    # the parts every theme shares with ArcadeMaster (James 2026-11-27, "all themes delivered"): the touch screen (SEARCH,
    # breadcrumbs, panels, list touch) and the hero main menu - copied with every picture / font they name
    for rel in ('layout - 1.xml', 'collections/Main/layout/layout.xml', 'collections/Main/layout/layout - 1.xml'):
        dst = out / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(SRC / rel, dst)
        copy_named_files(SRC / rel, SRC, out)
    # each theme's own main-menu personality over the shared hero show (backlog 1b: "different character entrances")
    mm = out / 'collections' / 'Main' / 'layout' / 'layout.xml'
    mm.write_text(main_variant(mm.read_text(encoding='utf-8'), theme), encoding='utf-8', newline='\n')
    ET.parse(mm)
    for f in ('touch_hit.png', 'black.png'):
        if (SRC / 'images' / f).exists():
            shutil.copy2(SRC / 'images' / f, img / f)
    copy_named_files(out / 'layout.xml', SRC, out)    # the default's own pictures a theme's game list uses (vignette, sweep ...)
    meta = {'name': theme.folder, 'label': theme.label, 'about': theme.about, 'idea': theme.idea, 'keys': theme.keys,
            'madeBy': 'tools/New-ArcadeThemes.py', 'resolution': f'{W}x{H}', 'monitors': 2}
    (out / MARKER).write_text(json.dumps(meta, indent=2) + '\n', encoding='utf-8', newline='\n')
    for x in out.rglob('*.xml'):
        ET.parse(x)
    size = sum(f.stat().st_size for f in img.glob(f'{theme.p}_*')) / 1e6
    print(f'built {theme.folder:<11} {theme.label:<11} own art {size:.1f} MB')


def guard(p: Path):
    r = p.resolve()
    sys.path.insert(0, str(Path(__file__).resolve().parent / 'lib'))
    from am_guard import is_protected      # the live frontend: ProtectedPaths in the config, else E:
    if is_protected(r):
        sys.exit(f'refusing to write inside the live frontend (ProtectedPaths, default E:): {r}')


def install(theme: Theme, root: Path, retrofe: Path, manifest: Path, samples: Samples | None):
    src, dst = root / theme.folder, retrofe / 'layouts' / theme.folder
    guard(dst)
    guard(manifest)
    if dst.exists():
        if not (dst / MARKER).exists():
            print(f'skip  {theme.folder}: {dst} exists and was not made by this script')
            return None
        # the theme holds folder links to the default theme's art (New-MenuHeroArt.py): unlink those first, so the
        # delete can never reach the real pictures (older Pythons' rmtree could follow a junction)
        for dp, dns, _ in os.walk(dst, topdown=True):
            for dn in list(dns):
                p = os.path.join(dp, dn)
                if os.path.realpath(p) != os.path.normpath(p):
                    os.rmdir(p)
                    dns.remove(dn)
        shutil.rmtree(dst)
    shutil.copytree(src, dst)
    am = retrofe / 'layouts' / 'ArcadeMaster'
    pl = am / 'collections' / '_common' / 'medium_artwork' / 'playlist'      # this cabinet's playlist banners
    if pl.is_dir():
        shutil.copytree(pl, dst / 'collections' / '_common' / 'medium_artwork' / 'playlist', dirs_exist_ok=True)
    if (am / 'images' / 'intro').is_dir():                                    # this cabinet's boot title card
        shutil.copytree(am / 'images' / 'intro', dst / 'images' / 'intro', dirs_exist_ok=True)
    for x in dst.rglob('*.xml'):
        ET.parse(x)
    preview = None
    if samples:
        pv = samples.render(theme)
        pv.save(dst / 'preview.png', 'PNG', optimize=True)
        (manifest / 'themes').mkdir(parents=True, exist_ok=True)
        preview = manifest / 'themes' / f'{theme.folder}.png'
        pv.save(preview, 'PNG', optimize=True)
    print(f'installed {theme.folder} -> {dst}' + (f'  preview {preview}' if preview else ''))
    return preview


def register(entries: list[tuple[Theme, Path | None]], manifest: Path, retrofe: Path):
    """record the themes in <manifest>/themes.json, the list Tools > Themes reads (same fields as Import-RetroFETheme)"""
    reg = manifest / 'themes.json'
    data = json.loads(reg.read_text(encoding='utf-8-sig')) if reg.exists() else {'themes': []}
    themes = data.get('themes') or []
    if isinstance(themes, dict):
        themes = [themes]
    for theme, preview in entries:
        old = next((t for t in themes if t.get('name') == theme.folder), {})
        themes = [t for t in themes if t.get('name') != theme.folder]
        themes.append({'name': theme.folder, 'source': 'tools/New-ArcadeThemes.py', 'imported': dt.datetime.now().strftime('%Y-%m-%dT%H:%M:%S'),
                       'resolution': f'{W}x{H}', 'monitors': 2, 'score': old.get('score', 0), 'coverage': old.get('coverage', {}),
                       'gaps': old.get('gaps', []), 'fixes': [], 'preview': str(preview) if preview else old.get('preview'),
                       'label': theme.label, 'about': theme.about, 'keys': theme.keys})
    data['themes'] = themes
    reg.write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8-sig')
    print(f'themes registry: {reg} ({len(themes)} theme(s))')


def score(names: list[str], retrofe: Path, manifest: Path):
    """artwork coverage per theme, by Import-RetroFETheme's own in-place registration (keeps our preview)"""
    ps1 = REPO / 'tools' / 'Import-RetroFETheme.ps1'
    for n in names:              # one call each: -File passes "a,b" as ONE string, not a list
        subprocess.run(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(ps1), '-Source', str(retrofe),
                        '-Layout', n, '-RetroFE', str(retrofe), '-ManifestDir', str(manifest), '-NoPreview'], check=False)
    # Import-RetroFETheme keeps only its own fields: put label / about / keys back
    reg = manifest / 'themes.json'
    data = json.loads(reg.read_text(encoding='utf-8-sig'))
    by = {t.folder: t for t in THEMES}
    for t in data.get('themes', []):
        if t.get('name') in by and t.get('name') in names:
            th = by[t['name']]
            t.update({'label': th.label, 'about': th.about, 'keys': th.keys})
    reg.write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8-sig')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out', default=str(REPO / 'layouts'), help='where the AM-* layout folders are written')
    ap.add_argument('--only', default='', help='comma list of theme names (Wall,Marquee,Wheel,Poster,Neon)')
    ap.add_argument('--install', metavar='RETROFE', help='RetroFE root to install into (its layouts\\AM-*)')
    ap.add_argument('--manifest', help='manifest folder holding themes.json (with --install)')
    ap.add_argument('--samples', help='medium_artwork folder for the preview mock-ups (default <RetroFE>\\collections\\Arcades\\medium_artwork)')
    ap.add_argument('--no-build', action='store_true', help='install what is already built')
    ap.add_argument('--no-score', action='store_true', help='skip the artwork-coverage score (Import-RetroFETheme)')
    a = ap.parse_args()
    root = Path(a.out)
    guard(root)
    want = {n.strip().lower() for n in a.only.split(',') if n.strip()}
    themes = [t for t in THEMES if not want or t.name.lower() in want]
    for t in themes:
        t.root = root
        if not a.no_build:
            build(t, root)
    if not a.install:
        return
    if not a.manifest:
        sys.exit('--install needs --manifest')
    retrofe, manifest = Path(a.install), Path(a.manifest)
    art = Path(a.samples) if a.samples else retrofe / 'collections' / 'Arcades' / 'medium_artwork'
    samples = Samples(art, retrofe / 'layouts' / 'ArcadeMaster' / 'collections' / '_common' / 'medium_artwork' / 'playlist', root) if (art / 'logo').is_dir() else None
    if not samples:
        print(f'no sample media at {art}: previews skipped')
    done = [(t, install(t, root, retrofe, manifest, samples)) for t in themes]
    done = [(t, p) for t, p in done if (retrofe / 'layouts' / t.folder / MARKER).exists()]
    register(done, manifest, retrofe)
    if not a.no_score:
        score([t.folder for t, _ in done], retrofe, manifest)


if __name__ == '__main__':
    main()
