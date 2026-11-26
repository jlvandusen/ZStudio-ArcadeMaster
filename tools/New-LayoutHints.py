r"""Floating button hints for the ArcadeMaster layout (James 2026-11-26: "show hint buttons hovering over it").

Draws small glass chips - a drawn arcade button plus what it does - into layouts\ArcadeMaster\images\hints\:
  hint_info.png   PAGE DOWN -> INFO     (shown over the video when the menu comes to rest)
  hint_video.png  PAGE UP   -> VIDEO    (shown while the game's info is up)
The layout shows them only at rest and hides them on any move.
  python tools/New-LayoutHints.py [--out layouts/ArcadeMaster/images/hints]
"""
import argparse
import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

S = 3                                   # drawn at 3x, scaled down: smooth edges
CYAN, AMBER, MAGENTA = (46, 200, 255), (255, 176, 0), (255, 47, 160)
TEXT, DIM = (235, 240, 248), (154, 163, 178)


def font(size, bold=True):
    for name in (("seguibl.ttf", "segoeuib.ttf") if bold else ("segoeui.ttf",)):
        p = os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Fonts", name)
        if os.path.exists(p):
            return ImageFont.truetype(p, size * S)
    return ImageFont.load_default()


def chip(arrow, key, does, colour, path):
    w, h = 400, 72
    im = Image.new("RGBA", (w * S, h * S), (0, 0, 0, 0))
    # soft glow behind the pill
    glow = Image.new("RGBA", im.size, (0, 0, 0, 0))
    ImageDraw.Draw(glow).rounded_rectangle((6 * S, 6 * S, (w - 6) * S, (h - 6) * S), radius=30 * S, fill=colour + (90,))
    im = Image.alpha_composite(im, glow.filter(ImageFilter.GaussianBlur(5 * S)))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((8 * S, 8 * S, (w - 8) * S, (h - 8) * S), radius=28 * S, fill=(10, 12, 20, 215), outline=colour + (255,), width=2 * S)
    # the arcade button: a lit dome with the arrow on it
    cx, cy, r = 44 * S, h // 2 * S, 22 * S
    for k in range(r, 0, -S):
        t = k / r
        c = tuple(int(colour[i] * t + 255 * (1 - t) * 0.55) for i in range(3))
        d.ellipse((cx - k - S * 2 * (1 - t), cy - k - S * 3 * (1 - t), cx + k - S * 2 * (1 - t), cy + k - S * 3 * (1 - t)), fill=c + (255,))
    d.ellipse((cx - r, cy - r, cx + r, cy + r), outline=(0, 0, 0, 160), width=S * 2)
    a = 9 * S
    pts = [(cx - a, cy + a * 0.45), (cx + a, cy + a * 0.45), (cx, cy - a * 0.75)] if arrow == "up" else [(cx - a, cy - a * 0.45), (cx + a, cy - a * 0.45), (cx, cy + a * 0.75)]
    d.polygon(pts, fill=(8, 10, 16, 255))
    d.text((78 * S, h // 2 * S), key, font=font(17), fill=DIM + (255,), anchor="lm")
    kw = d.textlength(key, font=font(17))
    d.text((78 * S + kw + 14 * S, h // 2 * S), does, font=font(25), fill=TEXT + (255,), anchor="lm")
    im.resize((w, h), Image.LANCZOS).save(path)


def main():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(here, "layouts", "ArcadeMaster", "images", "hints"))
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    chip("down", "PAGE DOWN", "INFO", AMBER, os.path.join(a.out, "hint_info.png"))
    chip("up", "PAGE UP", "VIDEO", CYAN, os.path.join(a.out, "hint_video.png"))
    print("hints -> %s" % a.out)


if __name__ == "__main__":
    main()
