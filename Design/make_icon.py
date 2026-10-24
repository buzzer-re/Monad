#!/usr/bin/env python3
"""Monad's app icon: drawn from signed distance fields, so every size is
rendered directly (crisp edges at 16 px and 1024 px alike) and an SVG with
the same geometry is written as the vector source.

Geometry is in units of the 1024 x 1024 macOS icon canvas: an 824 x 824
rounded square body (continuous-corner radius ~185) with a drop shadow,
holding the monad: a slim heavy ring around a centre that falls away to
near black, and the point. Needs Pillow and numpy (a development tool,
not part of the app): python3 Design/make_icon.py iconset ember
Monad/Assets.xcassets/AppIcon.appiconset
"""
import json
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image

C = 512.0
BODY_HALF, BODY_RADIUS = 412.0, 185.0
RING_MID, RING_HALF = 280.0, 24.0
DOT_R = 34.0


def hex_rgb(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)], dtype=np.float64)


VARIANTS = {
    # name: (core color, glow color, glow strength)
    "ember": ("#FF5A1F", "#FF5A1F", 0.55),
}


def rounded_box_sdf(x, y, half, radius):
    qx = np.abs(x - C) - (half - radius)
    qy = np.abs(y - C) - (half - radius)
    outside = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0))
    inside = np.minimum(np.maximum(qx, qy), 0)
    return outside + inside - radius


def coverage(sdf, px):
    """Anti-aliased coverage of the region sdf < 0, one pixel = px units."""
    return np.clip(0.5 - sdf / px, 0.0, 1.0)


def over(dst, color, alpha):
    a = alpha[..., None]
    dst[..., :3] = dst[..., :3] * (1 - a) + color * a
    dst[..., 3] = dst[..., 3] * (1 - alpha) + alpha


def render(size, variant="ember", small=None):
    """The chosen design: a flat point in a slim heavy ring over a dark
    centre that falls away to near black (depth: the infinite)."""
    small = size <= 64 if small is None else small
    core = hex_rgb(VARIANTS[variant][0])
    px = 1024.0 / size
    ys, xs = np.mgrid[0:size, 0:size].astype(np.float64)
    x = (xs + 0.5) * px
    y = (ys + 0.5) * px
    img = np.zeros((size, size, 4))
    body_sdf = rounded_box_sdf(x, y, BODY_HALF, BODY_RADIUS)
    body_a = coverage(body_sdf, px)
    shadow_sdf = rounded_box_sdf(x, y - 10.0, BODY_HALF, BODY_RADIUS)
    over(img, np.zeros(3), np.clip(0.28 * np.exp(-np.maximum(shadow_sdf, 0) / 14.0), 0, 1) * (1 - body_a))
    t = np.clip((y - (C - BODY_HALF)) / (2 * BODY_HALF), 0, 1)[..., None]
    over(img, hex_rgb("#25282E") * (1 - t) + hex_rgb("#0B0C0E") * t, body_a)
    r = np.hypot(x - C, y - C)
    half = RING_HALF * (1.3 if small else 1.0)
    inner = RING_MID - half
    depth = np.clip(1 - (r / inner) ** 2, 0, 1) * 0.85
    over(img, hex_rgb("#030304"), depth * coverage(r - inner, px))
    theta = np.arctan2(y - C, x - C)
    sheen = 0.5 + 0.5 * np.cos(theta - math.radians(-130))
    ring = np.clip(hex_rgb("#F2EEE6") * (0.78 + 0.22 * sheen)[..., None], 0, 1)
    over(img, ring, coverage(np.abs(r - RING_MID) - half, px))
    if not small:
        rim = coverage(np.abs(body_sdf + 2.0) - 1.5, px) * np.clip(1.2 - t[..., 0] * 1.6, 0, 1) * 0.14
        over(img, np.ones(3), rim * body_a)
    over(img, core, coverage(r - DOT_R * (1.4 if small else 1.0), px))
    return Image.fromarray((np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA")


def svg(variant="ember"):
    core = VARIANTS[variant][0]
    side = BODY_HALF * 2
    o = C - BODY_HALF
    inner = RING_MID - RING_HALF
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <linearGradient id="body" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#25282E"/><stop offset="1" stop-color="#0B0C0E"/>
    </linearGradient>
    <radialGradient id="depth" cx="512" cy="512" r="{inner}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#030304" stop-opacity="0.85"/><stop offset="1" stop-color="#030304" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="ring" x1="0.15" y1="0.1" x2="0.85" y2="0.9">
      <stop offset="0" stop-color="#F2EEE6"/><stop offset="1" stop-color="#BDBAB4"/>
    </linearGradient>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="10" stdDeviation="14" flood-color="#000" flood-opacity="0.28"/>
    </filter>
  </defs>
  <rect x="{o}" y="{o}" width="{side}" height="{side}" rx="{BODY_RADIUS}" fill="url(#body)" filter="url(#shadow)"/>
  <circle cx="512" cy="512" r="{inner}" fill="url(#depth)"/>
  <circle cx="512" cy="512" r="{RING_MID}" fill="none" stroke="url(#ring)" stroke-width="{RING_HALF * 2}"/>
  <circle cx="512" cy="512" r="{DOT_R}" fill="{core}"/>
</svg>
"""


SLOTS = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]


def write_iconset(variant, folder):
    folder = Path(folder)
    images = []
    for size, scale in SLOTS:
        px = size * scale
        name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
        render(px, variant).save(folder / name)
        images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{size}x{size}"})
    (folder / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}},
                                                     indent=2) + "\n")


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "preview":
        out = Path(sys.argv[2])
        for v in ["ember"]:
            render(1024, v).save(out / f"preview-{v}.png")
            # Dock-like strip: 512, 128, 64, 32, 16 on a light and a dark ground.
            strip = Image.new("RGBA", (1100, 300), (236, 236, 236, 255))
            dark = Image.new("RGBA", (1100, 300), (30, 30, 30, 255))
            xpos = 10
            for s in (256, 128, 64, 32, 16):
                im = render(s, v)
                strip.alpha_composite(im, (xpos, 20))
                dark.alpha_composite(im, (xpos, 20))
                xpos += s + 30
            sheet = Image.new("RGBA", (1100, 600))
            sheet.paste(strip, (0, 0))
            sheet.paste(dark, (0, 300))
            sheet.save(out / f"sizes-{v}.png")
    elif cmd == "iconset":
        write_iconset(sys.argv[2], sys.argv[3])
    elif cmd == "svg":
        Path(sys.argv[3]).write_text(svg(sys.argv[2]))
