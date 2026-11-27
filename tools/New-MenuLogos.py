r"""Neon main-menu logos for the entries other tools add (the makers, Arcades, Recently Played ...) in the style of
New-LayoutArt.ps1's (italic Segoe UI Black, white-to-colour fill, coloured glow, dark outline, 900x220). The ArcadeMaster
main menu draws each entry from layouts\ArcadeMaster\collections\Main\medium_artwork\logo\<entry>.png - without one the
entry shows nothing (James 2026-11-26: "missing the menu choice names, it's empty").
Existing logos are kept; --force redraws ours.
  python tools/New-MenuLogos.py --retrofe R:/ArcadeMaster/frontend/LEGENDS-am [--repo-layout layouts/ArcadeMaster]
"""
import argparse
import os

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

W, H, S = 900, 220, 2
ENTRIES = {
    "Arcades": ("ARCADES", "ff2fa0"), "Recently Played": ("RECENT", "ffe259"), "Classic Systems": ("CLASSICS", "9be7ff"),
    "Nintendo": ("NINTENDO", "ff3b3b"), "Sega": ("SEGA", "2e8bff"), "Sony": ("SONY", "9be7ff"), "Microsoft": ("MICROSOFT", "3ddc84"),
    "Atari": ("ATARI", "ff6a00"), "NEC": ("NEC", "ffb000"), "SNK": ("SNK", "2ec8ff"), "Computers": ("COMPUTERS", "7cf0c8"),
    "Arcade Boards": ("ARCADE BOARDS", "ff2fa0"), "Other Systems": ("MORE SYSTEMS", "9aa3b2"),
}


def rgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def font(px):
    for n in ("seguibli.ttf", "seguibl.ttf"):
        p = os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Fonts", n)
        if os.path.exists(p):
            return ImageFont.truetype(p, px)
    return ImageFont.load_default()


def logo(text, color, out):
    col = rgb(color)
    probe = ImageDraw.Draw(Image.new("L", (10, 10)))
    size = 120 * S
    while size > 40 * S and probe.textlength(text, font=font(size)) > (W - 60) * S:
        size -= 4 * S
    f = font(size)
    mask = Image.new("L", (W * S, H * S), 0)
    ImageDraw.Draw(mask).text((W * S / 2, H * S / 2), text, font=f, fill=255, anchor="mm")
    im = Image.new("RGBA", (W * S, H * S), (0, 0, 0, 0))
    # the coloured glow: the letters grown and blurred, three widths like New-LayoutArt's pens
    for grow, alpha in ((22, 60), (14, 110), (8, 170)):
        g = mask.filter(ImageFilter.MaxFilter(grow * S // 2 * 2 + 1)).filter(ImageFilter.GaussianBlur(grow * S / 3))
        layer = Image.new("RGBA", im.size, col + (0,))
        layer.putalpha(g.point(lambda v, a=alpha: v * a // 255))
        im = Image.alpha_composite(im, layer)
    # the dark outline, then the white-to-colour fill
    outline = mask.filter(ImageFilter.MaxFilter(3 * S + 1))
    dark = Image.new("RGBA", im.size, (26, 6, 51, 0)); dark.putalpha(outline.point(lambda v: v * 220 // 255))
    im = Image.alpha_composite(im, dark)
    grad = Image.new("RGBA", im.size)
    gd = ImageDraw.Draw(grad)
    for y in range(H * S):
        t = min(1.0, max(0.0, (y - 50 * S) / (120 * S)))
        gd.line([(0, y), (W * S, y)], fill=tuple(int(255 + (c - 255) * t) for c in col) + (255,))
    grad.putalpha(mask)
    im = Image.alpha_composite(im, grad)
    im.resize((W, H), Image.LANCZOS).save(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--retrofe", required=True)
    ap.add_argument("--repo-layout", help="also write into the repo's layout (layouts/ArcadeMaster) so updates keep them")
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()
    targets = [os.path.join(a.retrofe, "layouts", "ArcadeMaster", "collections", "Main", "medium_artwork", "logo")]
    if a.repo_layout:
        targets.append(os.path.join(a.repo_layout, "collections", "Main", "medium_artwork", "logo"))
    menu = os.path.join(a.retrofe, "collections", "Main", "menu.txt")
    wanted = [l.strip() for l in open(menu)] if os.path.exists(menu) else []
    made = 0
    for d in targets:
        os.makedirs(d, exist_ok=True)
        for name in set(wanted) | set(ENTRIES):
            if not name or name not in ENTRIES:
                continue
            p = os.path.join(d, name + ".png")
            if os.path.exists(p) and not a.force:
                continue
            logo(ENTRIES[name][0], ENTRIES[name][1], p)
            made += 1
    missing = [n for n in wanted if n and not any(os.path.exists(os.path.join(t, n + ".png")) for t in targets[:1])]
    print("menu logos: %d made%s" % (made, (", still none for: " + ", ".join(missing)) if missing else ""))


if __name__ == "__main__":
    main()
