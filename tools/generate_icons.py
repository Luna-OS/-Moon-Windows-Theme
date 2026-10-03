"""Erzeugt die Moon-Ordnersymbole (theme/Icons/*.ico).

Lila Ordner mit heller Kontur und kleiner Mondsichel, passend zu Moon Explorer.
Jede Groesse wird einzeln (4x ueberabgetastet) gezeichnet, damit auch 16 px scharf bleiben.

Aufruf:  python tools/generate_icons.py
Benoetigt: pip install pillow numpy
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageChops

OUT = Path(__file__).resolve().parent.parent / "theme" / "Icons"
SIZES = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]
SS = 4  # Supersampling

BACK_TOP, BACK_BOTTOM = (92, 74, 196), (52, 40, 132)      # hintere Lasche/Wand
FRONT_TOP, FRONT_BOTTOM = (176, 160, 255), (110, 90, 230)  # Vorderseite
OUTLINE = (214, 205, 255)
MOON = (246, 243, 255)


def gradient(size, top, bottom):
    h = size[1]
    t = np.linspace(0, 1, h, dtype=np.float32)[:, None, None]
    g = np.array(top, np.float32) + (np.array(bottom, np.float32) - np.array(top, np.float32)) * t
    g = np.broadcast_to(g, (h, size[0], 3)).astype(np.uint8)
    return Image.fromarray(g, "RGB").convert("RGBA")


def paste_shape(canvas, mask, top, bottom):
    fill = gradient(canvas.size, top, bottom)
    canvas.paste(fill, (0, 0), mask)


def draw_folder(px, opened=False):
    S = px * SS
    u = S / 32.0  # Einheit: 1/32 der Icongroesse
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    small = px <= 24
    r = (2.2 if small else 2.6) * u

    # Hintere Wand mit Lasche oben links
    back = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(back)
    d.rounded_rectangle([2 * u, 5 * u, 13 * u, 11 * u], radius=r, fill=255)          # Lasche
    d.polygon([(10 * u, 5.0 * u), (14.5 * u, 8.2 * u), (10 * u, 8.2 * u)], fill=255)  # Schraege
    d.rounded_rectangle([2 * u, 8 * u, 30 * u, 27 * u], radius=r, fill=255)
    paste_shape(img, back, BACK_TOP, BACK_BOTTOM)

    # Blatt Papier (nur bei grossen Icons)
    if not small:
        paper = Image.new("L", (S, S), 0)
        ImageDraw.Draw(paper).rounded_rectangle([5 * u, 9.5 * u, 27 * u, 22 * u], radius=1.2 * u, fill=235)
        img.paste(Image.new("RGBA", (S, S), (236, 232, 255, 255)), (0, 0), paper)

    # Vorderseite
    front = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(front)
    if opened:
        d.polygon([(6 * u, 13 * u), (31 * u, 13 * u), (27.5 * u, 27 * u), (2 * u, 27 * u)], fill=255)
    else:
        d.rounded_rectangle([2 * u, 12 * u, 30 * u, 27 * u], radius=r, fill=255)
    paste_shape(img, front, FRONT_TOP, FRONT_BOTTOM)

    # Helle Kontur oben an der Vorderseite (Glanzkante)
    edge = ImageChops.subtract(front, front.transform(front.size, Image.AFFINE, (1, 0, 0, 0, 1, -max(1, int(0.9 * u))), resample=Image.NEAREST))
    img.paste(Image.new("RGBA", (S, S), (*OUTLINE, 255)), (0, 0), edge)

    # Mondsichel auf der Vorderseite
    if px >= 32:
        cx, cy, rr = 20.5 * u, 19.8 * u, 4.6 * u
        moon = Image.new("L", (S, S), 0)
        md = ImageDraw.Draw(moon)
        md.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], fill=255)
        md.ellipse([cx - rr + 2.6 * u, cy - rr - 1.2 * u, cx + rr + 2.6 * u, cy + rr - 1.2 * u], fill=0)
        glow = moon.resize((S // 4, S // 4), Image.BILINEAR).resize((S, S), Image.BILINEAR)
        img.paste(Image.new("RGBA", (S, S), (255, 255, 255, 70)), (0, 0), glow)
        img.paste(Image.new("RGBA", (S, S), (*MOON, 255)), (0, 0), moon)
        # zwei kleine Sterne
        for sx, sy, sr in [(12.5, 17.5, 0.8), (14.8, 22.5, 0.55)]:
            ImageDraw.Draw(img).ellipse([(sx - sr) * u, (sy - sr) * u, (sx + sr) * u, (sy + sr) * u], fill=(*MOON, 230))

    return img.resize((px, px), Image.LANCZOS)


def save_ico(name, opened):
    images = [draw_folder(px, opened) for px in SIZES]
    big = images[-1]
    big.save(OUT / name, format="ICO", sizes=[(px, px) for px in SIZES], append_images=images[:-1])
    return images


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    closed = save_ico("moon-folder.ico", opened=False)
    opened = save_ico("moon-folder-open.ico", opened=True)
    # Vorschau auf dunklem und hellem Hintergrund
    sizes = [256, 96, 48, 32, 24, 16]
    width = sum(sizes) + 20 * (len(sizes) + 1)
    prev = Image.new("RGBA", (width, 2 * 300), (14, 11, 31, 255))
    ImageDraw.Draw(prev).rectangle([0, 300, width, 600], fill=(240, 238, 248, 255))
    x = 20
    for px in sizes:
        icon = closed[SIZES.index(px)]
        prev.alpha_composite(icon, (x, 22 + (256 - px)))
        icon2 = opened[SIZES.index(px)]
        prev.alpha_composite(icon2, (x, 322 + (256 - px)))
        x += px + 20
    prev.convert("RGB").save(OUT.parent.parent / "docs" / "folder-icons.png")
    print("geschrieben:", OUT)


if __name__ == "__main__":
    main()
