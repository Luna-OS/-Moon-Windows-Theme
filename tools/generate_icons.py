"""Erzeugt die Moon-Ordnersymbole (theme/Icons/*.ico).

Lila Ordner mit heller Kontur und kleiner Mondsichel, passend zu Moon Explorer.
Jede Groesse wird einzeln (4x ueberabgetastet) gezeichnet, damit auch 16 px scharf bleiben.

Aufruf:  python tools/generate_icons.py
Benoetigt: pip install pillow numpy
"""
import io
import struct
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

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


def _bmp_entry(img):
    """32-Bit-DIB (BGRA, von unten nach oben) plus 1-Bit-AND-Maske, wie es die
    Windows-Shell fuer kleine Icon-Groessen erwartet."""
    w, h = img.size
    px = np.asarray(img.convert("RGBA"), dtype=np.uint8)
    bgra = px[::-1, :, [2, 1, 0, 3]].tobytes()
    header = struct.pack("<IiiHHIIiiII", 40, w, h * 2, 1, 32, 0, len(bgra), 0, 0, 0, 0)
    row_bytes = ((w + 31) // 32) * 4
    mask = bytearray()
    for y in range(h - 1, -1, -1):
        row = bytearray(row_bytes)
        for x in range(w):
            if px[y, x, 3] == 0:
                row[x // 8] |= 0x80 >> (x % 8)
        mask += row
    return header + bgra + bytes(mask)


def _png_entry(img):
    buf = io.BytesIO()
    img.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def write_ico(path, images):
    """ICO-Datei: BMP-Eintraege fuer < 256 px, PNG nur fuer 256 px (Windows-Standard)."""
    entries = [(_png_entry(im) if im.size[0] >= 256 else _bmp_entry(im), im.size[0]) for im in images]
    out = bytearray(struct.pack("<HHH", 0, 1, len(entries)))
    offset = 6 + 16 * len(entries)
    for data, size in entries:
        dim = 0 if size >= 256 else size
        out += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
    for data, _ in entries:
        out += data
    Path(path).write_bytes(bytes(out))


def save_ico(name, opened):
    images = [draw_folder(px, opened) for px in SIZES]
    write_ico(OUT / name, images)
    return images


def draw_start_logo(px=256):
    """Moon-Logo fuer den Start-Button der Taskleiste: leuchtende Mondsichel
    mit zwei Sternen, ca. 48 % der Flaeche (wie das Windows-Logo)."""
    S = px * SS
    c = S / 2
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # Mondsichel: grosser Kreis minus versetzter Kreis
    r = S * 0.235
    moon = Image.new("L", (S, S), 0)
    md = ImageDraw.Draw(moon)
    md.ellipse([c - r, c - r, c + r, c + r], fill=255)
    md.ellipse([c - r + 0.62 * r, c - r - 0.30 * r, c + r + 0.62 * r, c + r - 0.30 * r], fill=0)

    # Weicher Schein
    glow = moon.filter(ImageFilter.GaussianBlur(S * 0.035))
    img.paste(Image.new("RGBA", (S, S), (184, 171, 255, 150)), (0, 0), glow)

    # Verlauf weiss -> lila von oben links nach unten rechts
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
    t = np.clip(((xx + yy) / (2 * S) - 0.3) / 0.4, 0, 1)[:, :, None]
    top, bottom = np.array([250, 248, 255], np.float32), np.array([168, 150, 255], np.float32)
    grad = (top + (bottom - top) * t).astype(np.uint8)
    img.paste(Image.fromarray(np.dstack([grad, np.full((S, S), 255, np.uint8)]), "RGBA"), (0, 0), moon)

    # Zwei kleine Sterne rechts oben
    sd = ImageDraw.Draw(img)
    for sx, sy, sr in [(0.66, 0.36, 0.022), (0.72, 0.52, 0.014)]:
        x, y, rr = sx * S, sy * S, sr * S
        sd.polygon([(x, y - rr * 2.2), (x + rr * 0.5, y - rr * 0.5), (x + rr * 2.2, y), (x + rr * 0.5, y + rr * 0.5),
                    (x, y + rr * 2.2), (x - rr * 0.5, y + rr * 0.5), (x - rr * 2.2, y), (x - rr * 0.5, y - rr * 0.5)],
                   fill=(246, 243, 255, 255))
    return img.resize((px, px), Image.LANCZOS)


# Start-Kacheln fuer die Matter-Taskleiste: Logo auf der Kachelfarbe des jeweiligen Zustands.
# (Die Glas-Kachel liegt ueber dem Button-Hintergrund, deshalb muss das Logo auf der Kachel sitzen.)
START_TILES = {
    "moon-start-tile.png": (26, 21, 53, 115),         # normal
    "moon-start-tile-hover.png": (184, 171, 255, 70),  # Maus darueber
    "moon-start-tile-active.png": (142, 124, 255, 105), # Startmenue offen
}


def draw_start_tile(rgba, px=256):
    tile = Image.new("RGBA", (px, px), rgba)
    tile.alpha_composite(draw_start_logo(px))
    return tile


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    draw_start_logo().save(OUT / "moon-start.png", optimize=True)
    for name, rgba in START_TILES.items():
        draw_start_tile(rgba).save(OUT / name, optimize=True)
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
