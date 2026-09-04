#!/usr/bin/env python3
"""Generate AiNotetaker app icons (build-time only; not needed at runtime).

Design: a deep indigo→violet gradient with a white audio waveform and a small
sparkle — voice notes + AI — deliberately unlike Apple's yellow Notes icon.
Run:  .venv/bin/python scripts/gen_icons.py
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
WEB = ROOT / "web" / "icons"
IOS = ROOT / "ios" / "AiNotetaker" / "Assets.xcassets" / "AppIcon.appiconset"
WEB.mkdir(parents=True, exist_ok=True)
IOS.mkdir(parents=True, exist_ok=True)

TOP = (67, 56, 202)      # indigo
BOTTOM = (124, 58, 237)  # violet
SS = 3                   # supersample for smooth edges


def gradient(c: int) -> Image.Image:
    t = np.linspace(0.0, 1.0, c, dtype=np.float32)[:, None]
    top = np.array(TOP, dtype=np.float32)[None, :]
    bot = np.array(BOTTOM, dtype=np.float32)[None, :]
    col = top * (1 - t) + bot * t                      # (c, 3)
    img = np.repeat(col[:, None, :], c, axis=1)         # (c, c, 3)
    rgb = Image.fromarray(img.astype(np.uint8), "RGB")
    # soft highlight top-left
    glow = Image.new("L", (c, c), 0)
    ImageDraw.Draw(glow).ellipse([-c * 0.35, -c * 0.45, c * 0.75, c * 0.55], fill=110)
    glow = glow.filter(ImageFilter.GaussianBlur(c * 0.18))
    white = Image.new("RGB", (c, c), (255, 255, 255))
    return Image.composite(white, rgb, glow.point(lambda v: int(v * 0.35)))


def draw_art(img: Image.Image, c: int, inset: float) -> None:
    """Waveform + sparkle. `inset` grows for full-bleed (maskable) variants."""
    d = ImageDraw.Draw(img, "RGBA")
    scale = 1.0 - inset
    heights = [0.30, 0.52, 0.74, 0.92, 0.74, 0.52, 0.30]
    bar_w = c * 0.072 * scale
    gap = c * 0.034 * scale
    max_h = c * 0.50 * scale
    total = len(heights) * bar_w + (len(heights) - 1) * gap
    x = (c - total) / 2
    cy = c * 0.545
    for h in heights:
        bh = max_h * h
        d.rounded_rectangle([x, cy - bh / 2, x + bar_w, cy + bh / 2],
                            radius=bar_w / 2, fill=(255, 255, 255, 238))
        x += bar_w + gap
    # four-point sparkle, top-right
    sx, sy, r = c * 0.775, c * 0.235, c * 0.085 * scale
    pts = []
    for i in range(8):
        ang = np.pi / 4 * i - np.pi / 2
        rad = r if i % 2 == 0 else r * 0.34
        pts.append((sx + rad * np.cos(ang), sy + rad * np.sin(ang)))
    d.polygon(pts, fill=(255, 255, 255, 245))


def render(size: int, rounded: bool, inset: float = 0.0) -> Image.Image:
    c = size * SS
    base = gradient(c).convert("RGBA")
    draw_art(base, c, inset)
    if rounded:
        mask = Image.new("L", (c, c), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, c - 1, c - 1], radius=int(c * 0.225), fill=255)
        base.putalpha(mask)
    return base.resize((size, size), Image.LANCZOS)


def opaque(img: Image.Image) -> Image.Image:
    bg = Image.new("RGB", img.size, TOP)
    bg.paste(img, mask=img.split()[3])
    return bg


def main() -> None:
    render(192, rounded=True).save(WEB / "icon-192.png")
    render(512, rounded=True).save(WEB / "icon-512.png")
    opaque(render(512, rounded=False, inset=0.12)).save(WEB / "icon-maskable-512.png")
    opaque(render(180, rounded=False, inset=0.06)).save(WEB / "apple-touch-icon.png")
    opaque(render(1024, rounded=False, inset=0.06)).save(IOS / "AppIcon.png")
    print("wrote web/icons/* and ios AppIcon.png")


if __name__ == "__main__":
    main()
