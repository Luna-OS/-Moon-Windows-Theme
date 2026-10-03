"""Erzeugt die Moon-Hintergrundbilder (4K) fuer das Theme.

Aufruf:  python tools/generate_wallpapers.py
Benoetigt: pip install pillow numpy
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

W, H = 3840, 2160
OUT = Path(__file__).resolve().parent.parent / "theme" / "Wallpapers"

TOP = np.array([10, 8, 24], dtype=np.float32)      # #0A0818
MID = np.array([25, 19, 58], dtype=np.float32)     # #19133A
BOTTOM = np.array([59, 45, 114], dtype=np.float32) # #3B2D72


def sky(rng, horizon_glow=True):
    y = np.linspace(0, 1, H, dtype=np.float32)[:, None, None]
    t1 = np.clip(y / 0.6, 0, 1)
    t2 = np.clip((y - 0.6) / 0.4, 0, 1)
    col = np.where(y < 0.6, TOP + (MID - TOP) * t1, MID + (BOTTOM - MID) * t2)
    img = np.broadcast_to(col, (H, W, 3)).copy()
    if horizon_glow:
        xx = np.linspace(-1, 1, W, dtype=np.float32)[None, :]
        glow = np.exp(-((y[:, :, 0] - 1.0) ** 2) / 0.05) * np.exp(-(xx ** 2) / 0.6)
        img += glow[:, :, None] * np.array([58, 44, 110], dtype=np.float32)
    img += rng.normal(0, 1.2, img.shape).astype(np.float32)  # gegen Banding
    return Image.fromarray(np.clip(img, 0, 255).astype(np.uint8))


def stars(img, rng, count):
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for _ in range(count):
        x, y = rng.uniform(0, W), rng.uniform(0, H) ** 1.0 * rng.uniform(0.2, 1.0)
        r = rng.choice([0.8, 1.0, 1.3, 1.8, 2.6], p=[0.45, 0.3, 0.15, 0.07, 0.03])
        a = int(rng.uniform(90, 255))
        tint = [(255, 255, 255), (220, 210, 255), (200, 215, 255)][rng.integers(3)]
        d.ellipse([x - r, y - r, x + r, y + r], fill=(*tint, a))
    glow = layer.filter(ImageFilter.GaussianBlur(3))
    img.paste(glow, (0, 0), glow)
    img.paste(layer, (0, 0), layer)


def moon(img, rng, cx, cy, r, phase=None):
    """Mond mit Halo, Kratern und optionaler Sichel (phase = Versatz des Schattens)."""
    halo = Image.new("RGBA", img.size, (0, 0, 0, 0))
    hd = ImageDraw.Draw(halo)
    for k, a in [(3.2, 18), (2.2, 28), (1.5, 45)]:
        hd.ellipse([cx - r * k, cy - r * k, cx + r * k, cy + r * k], fill=(160, 140, 255, a))
    halo = halo.filter(ImageFilter.GaussianBlur(r * 0.6))
    img.paste(halo, (0, 0), halo)

    size = int(r * 2)
    yy, xx = np.mgrid[-1:1:size * 1j, -1:1:size * 1j].astype(np.float32)
    rr = np.sqrt(xx ** 2 + yy ** 2)
    disc = rr <= 1
    shade = 0.82 + 0.18 * (1 - rr ** 2)  # Randabdunkelung
    base = np.array([234, 230, 250], dtype=np.float32)
    surf = base[None, None, :] * shade[:, :, None]

    # Maria (dunkle Flecken) und Krater
    for _ in range(14):
        mx, my, mr = rng.uniform(-0.7, 0.7), rng.uniform(-0.7, 0.7), rng.uniform(0.1, 0.3)
        m = np.exp(-((xx - mx) ** 2 + (yy - my) ** 2) / (mr ** 2))
        surf -= m[:, :, None] * np.array([20, 21, 19], dtype=np.float32)
    for _ in range(30):
        kx, ky, kr = rng.uniform(-0.9, 0.9), rng.uniform(-0.9, 0.9), rng.uniform(0.02, 0.08)
        dist = np.sqrt((xx - kx) ** 2 + (yy - ky) ** 2)
        ring = np.exp(-((dist - kr) ** 2) / (kr * 0.25) ** 2)
        surf += ring[:, :, None] * 6
        surf -= (dist < kr)[:, :, None] * 5
    surf += rng.normal(0, 3, surf.shape).astype(np.float32)

    alpha = np.clip((1 - rr) * size * 0.5, 0, 1)  # weiche Kante
    if phase is not None:
        sd = np.sqrt((xx - phase) ** 2 + yy ** 2)
        alpha *= np.clip((sd - 1) * size * 0.08 + 0.025, 0.025, 1)
    alpha = alpha * disc
    rgba = np.dstack([np.clip(surf, 0, 255), alpha * 255]).astype(np.uint8)
    m = Image.fromarray(rgba, "RGBA")
    img.paste(m, (int(cx - r), int(cy - r)), m)


def mountains(img, rng, layers):
    d = ImageDraw.Draw(img)
    for base_y, amp, colour in layers:
        pts = [(0, H)]
        x, y = 0, base_y
        while x <= W + 80:
            y = np.clip(y + rng.normal(0, amp), base_y - amp * 4, base_y + amp * 2)
            pts.append((x, y))
            x += rng.uniform(40, 120)
        pts.append((W, H))
        d.polygon(pts, fill=colour)


def save(img, name):
    OUT.mkdir(parents=True, exist_ok=True)
    img.save(OUT / name, quality=92, optimize=True, progressive=True)
    print("geschrieben:", OUT / name)


def main():
    rng = np.random.default_rng(1969)

    # 1) Moon Night – grosser Vollmond ueber Bergen
    img = sky(rng)
    stars(img, rng, 1400)
    moon(img, rng, W * 0.70, H * 0.33, 300)
    mountains(img, rng, [(H * 0.74, 18, (31, 24, 66)), (H * 0.82, 22, (20, 15, 45)), (H * 0.90, 16, (11, 8, 27))])
    save(img, "moon-night.jpg")

    # 2) Moon Crescent – minimalistische Sichel
    img = sky(rng, horizon_glow=False)
    stars(img, rng, 700)
    moon(img, rng, W * 0.5, H * 0.45, 360, phase=0.55)
    save(img, "moon-crescent.jpg")

    # 3) Moon Horizon – Mond geht ueber dem Horizont auf
    img = sky(rng)
    stars(img, rng, 1000)
    moon(img, rng, W * 0.30, H * 0.70, 520)
    mountains(img, rng, [(H * 0.80, 14, (23, 17, 50)), (H * 0.88, 12, (9, 7, 22))])
    save(img, "moon-horizon.jpg")


if __name__ == "__main__":
    main()
