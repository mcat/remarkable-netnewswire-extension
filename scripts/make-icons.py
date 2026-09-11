#!/usr/bin/env python3
"""Generates the app icon set (App/Assets.xcassets/AppIcon.appiconset) with Pillow."""
import json
import os
from PIL import Image, ImageDraw

ROOT = os.path.join(os.path.dirname(__file__), "..", "App", "Assets.xcassets", "AppIcon.appiconset")
SIZES = [16, 32, 128, 256, 512]


def draw_icon(size: int) -> Image.Image:
    scale = 8
    px = size * scale
    img = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # Rounded charcoal tile, inset like macOS Big Sur icons.
    inset = px * 0.08
    radius = px * 0.2
    d.rounded_rectangle([inset, inset, px - inset, px - inset], radius=radius, fill=(43, 43, 43, 255))

    # A white page with folded corner.
    left, top = px * 0.28, px * 0.2
    right, bottom = px * 0.72, px * 0.8
    fold = px * 0.1
    page = [(left, top), (right - fold, top), (right, top + fold), (right, bottom), (left, bottom)]
    d.polygon(page, fill=(245, 245, 245, 255))
    d.polygon([(right - fold, top), (right - fold, top + fold), (right, top + fold)], fill=(200, 200, 200, 255))

    # Handwritten-looking lines on the page.
    line_w = max(1, int(px * 0.028))
    y = top + px * 0.2
    for i, width in enumerate([0.30, 0.26, 0.32, 0.20]):
        d.line([(left + px * 0.06, y), (left + px * 0.06 + px * width, y)], fill=(60, 60, 60, 255), width=line_w)
        y += px * 0.1

    # RSS dot, the NetNewsWire side of the bridge.
    r = px * 0.075
    cx, cy = px * 0.24, px * 0.76
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(245, 130, 32, 255))

    return img.resize((size, size), Image.LANCZOS)


def main() -> None:
    os.makedirs(ROOT, exist_ok=True)
    images = []
    cache = {}
    for size in SIZES:
        for scale in (1, 2):
            pixels = size * scale
            if pixels not in cache:
                cache[pixels] = draw_icon(pixels)
            name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
            cache[pixels].save(os.path.join(ROOT, name), "PNG")
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{size}x{size}"})
    with open(os.path.join(ROOT, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
