r"""Floating button hints for the ArcadeMaster layout (James 2026-11-26: "show hint buttons hovering over it", "hint
buttons appearing when on a game to show what button selects and launches and how to move up/down and then left/right
to change filters", letters on buttons 5 and 8).

Draws small glass chips - drawn arcade buttons / a stick plus what they do - into layouts\ArcadeMaster\images\hints\:
  hint_info.png     PAGE DOWN -> INFO        (over the video, at rest)
  hint_video.png    PAGE UP   -> VIDEO       (while the game's info is up)
  hint_play.png     button 1  -> PLAY        (at the selected game)
  hint_move.png     stick: up/down GAMES, left/right FILTERS
  hint_letters.png  button 5 <- A-Z -> button 8
The layout shows them only at rest and hides them on any move.
  python tools/New-LayoutHints.py [--out layouts/ArcadeMaster/images/hints]
"""
import argparse
import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

S = 3                                   # drawn at 3x, scaled down: smooth edges
CYAN, AMBER, MAGENTA, GREEN = (46, 200, 255), (255, 176, 0), (255, 47, 160), (61, 220, 132)
# the controls card's button colours (New-PanelControlsArt.py BTN_COLORS): button 1 magenta, 5 violet, 8 red
B1, B5, B8 = (255, 47, 160), (123, 92, 255), (255, 90, 90)
TEXT, DIM, INK = (235, 240, 248), (154, 163, 178), (8, 10, 16)


def font(size):
    for name in ("seguibl.ttf", "segoeuib.ttf"):
        p = os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Fonts", name)
        if os.path.exists(p):
            return ImageFont.truetype(p, int(size * S))
    return ImageFont.load_default()


def tri(d, cx, cy, a, way, fill):
    pts = {"up": [(cx - a, cy + a * 0.55), (cx + a, cy + a * 0.55), (cx, cy - a * 0.75)],
           "down": [(cx - a, cy - a * 0.55), (cx + a, cy - a * 0.55), (cx, cy + a * 0.75)],
           "left": [(cx + a * 0.55, cy - a), (cx + a * 0.55, cy + a), (cx - a * 0.75, cy)],
           "right": [(cx - a * 0.55, cy - a), (cx - a * 0.55, cy + a), (cx + a * 0.75, cy)]}[way]
    d.polygon(pts, fill=fill)


def button(d, cx, cy, r, colour, label=None, arrow=None):
    """a lit arcade button: dome shading, dark rim, a number or an arrow on it"""
    for k in range(r, 0, -S):
        t = k / r
        c = tuple(int(colour[i] * t + 255 * (1 - t) * 0.55) for i in range(3))
        off = (1 - t)
        d.ellipse((cx - k - S * 2 * off, cy - k - S * 3 * off, cx + k - S * 2 * off, cy + k - S * 3 * off), fill=c + (255,))
    d.ellipse((cx - r, cy - r, cx + r, cy + r), outline=(0, 0, 0, 160), width=S * 2)
    if label:
        d.text((cx, cy + S), label, font=font(r / S * 1.05), fill=INK + (255,), anchor="mm")
    if arrow:
        tri(d, cx, cy, r * 0.42, arrow, INK + (255,))


def stick(d, cx, cy, h, colour):
    """a bat-top stick seen from the side: base plate, shaft, ball"""
    d.ellipse((cx - h * 0.42, cy + h * 0.28, cx + h * 0.42, cy + h * 0.46), outline=DIM + (255,), width=S * 2)
    d.line((cx, cy + h * 0.37, cx, cy - h * 0.12), fill=DIM + (255,), width=S * 3)
    r = h * 0.22
    for k in range(int(r), 0, -S):
        t = k / r
        c = tuple(int(colour[i] * t + 255 * (1 - t) * 0.55) for i in range(3))
        d.ellipse((cx - k - S * (1 - t), cy - h * 0.2 - k - S * 2 * (1 - t), cx + k - S * (1 - t), cy - h * 0.2 + k - S * 2 * (1 - t)), fill=c + (255,))


def chip(parts, colour, path, h=60):
    """parts: ("button", label|None, arrow|None, colour) | ("stick", colour) | ("arrow", way, colour) | ("text", s, size, colour) | ("gap", px)"""
    probe = ImageDraw.Draw(Image.new("RGBA", (10, 10)))
    widths = []
    for p in parts:
        if p[0] in ("button", "stick"):
            widths.append(h - 14)
        elif p[0] == "arrow":
            widths.append(h * 0.34)
        elif p[0] == "text":
            widths.append(probe.textlength(p[1], font=font(p[2])) / S)
        elif p[0] == "gap":
            widths.append(p[1])
    w = int(sum(widths) + 10 * (len(parts) - 1) + 36)
    im = Image.new("RGBA", (w * S, h * S), (0, 0, 0, 0))
    glow = Image.new("RGBA", im.size, (0, 0, 0, 0))
    ImageDraw.Draw(glow).rounded_rectangle((6 * S, 6 * S, (w - 6) * S, (h - 6) * S), radius=(h // 2 - 4) * S, fill=colour + (90,))
    im = Image.alpha_composite(im, glow.filter(ImageFilter.GaussianBlur(5 * S)))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((8 * S, 8 * S, (w - 8) * S, (h - 8) * S), radius=(h // 2 - 6) * S, fill=(10, 12, 20, 215), outline=colour + (255,), width=2 * S)
    x, cy = 18.0, h / 2
    for p, pw in zip(parts, widths):
        if p[0] == "button":
            button(d, int((x + pw / 2) * S), int(cy * S), int((pw / 2 - 2) * S), p[3], p[1], p[2])
        elif p[0] == "stick":
            stick(d, (x + pw / 2) * S, (cy + 2) * S, pw * S, p[1])
        elif p[0] == "arrow":
            tri(d, (x + pw / 2) * S, cy * S, pw * 0.42 * S, p[1], p[2] + (255,))
        elif p[0] == "text":
            d.text((x * S, cy * S), p[1], font=font(p[2]), fill=p[3] + (255,), anchor="lm")
        x += pw + 10
    im.resize((w, h), Image.LANCZOS).save(path)
    return w, h


def main():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(here, "layouts", "ArcadeMaster", "images", "hints"))
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    o = lambda n: os.path.join(a.out, n)
    made = {
        "hint_info.png": chip([("button", None, "down", AMBER), ("text", "PAGE DOWN", 15, DIM), ("text", "INFO", 22, TEXT)], AMBER, o("hint_info.png")),
        "hint_video.png": chip([("button", None, "up", CYAN), ("text", "PAGE UP", 15, DIM), ("text", "VIDEO", 22, TEXT)], CYAN, o("hint_video.png")),
        "hint_play.png": chip([("button", "1", None, B1), ("text", "PLAY", 22, TEXT)], B1, o("hint_play.png")),
        "hint_move.png": chip([("stick", MAGENTA), ("arrow", "up", CYAN), ("arrow", "down", CYAN), ("text", "GAMES", 17, TEXT), ("gap", 6),
                               ("arrow", "left", AMBER), ("arrow", "right", AMBER), ("text", "FILTERS", 17, TEXT)], CYAN, o("hint_move.png")),
        "hint_letters.png": chip([("button", "5", None, B5), ("arrow", "left", DIM), ("text", "A - Z", 19, TEXT), ("arrow", "right", DIM), ("button", "8", None, B8)], B5, o("hint_letters.png")),
    }
    for n, (w, h) in made.items():
        print("  %-18s %dx%d" % (n, w, h))
    print("hints -> %s" % a.out)


if __name__ == "__main__":
    main()
