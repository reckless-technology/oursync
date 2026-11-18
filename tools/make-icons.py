#!/usr/bin/env python3
"""Regenerate icons/ from the source artwork.

    python3 tools/make-icons.py

The artwork in icons/source/ is a dark circle on a white background with a soft glow around it.
Shipping that as-is would carry a white square into every dark menu and notification it appears
in, so the circle is located by where the dark pixels are and everything outside it is made
transparent. Only run this when the artwork changes; the PNGs it writes are committed, so a
package build needs no Python and no Pillow.

Needs Pillow.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "icons" / "source" / "oursync-logo.jpg"
OUT = ROOT / "icons"

# The sizes the package installs into the hicolor theme, and nothing else: an icon in a directory
# whose name does not match its size is a lintian error, and an unused size is dead weight.
SIZES = [16, 32, 48, 64, 128, 256, 512]


def main() -> int:
    if not SOURCE.exists():
        print(f"no artwork at {SOURCE}", file=sys.stderr)
        return 1
    src = Image.open(SOURCE).convert("RGB")

    # Where is the circle? The background is white and the logo is dark, so threshold on luminance
    # and take the bounding box of what is left. The glow is faint enough not to move it.
    mask = src.convert("L").point(lambda v: 255 if v < 200 else 0)
    box = mask.getbbox()
    if box is None:
        print("no dark pixels found - is this the right artwork?", file=sys.stderr)
        return 1
    left, top, right, bottom = box
    centre_x, centre_y = (left + right) / 2, (top + bottom) / 2
    radius = max(right - left, bottom - top) / 2
    print(f"{SOURCE.name}: {src.size[0]}x{src.size[1]}, "
          f"circle at ({centre_x:.0f},{centre_y:.0f}) radius {radius:.0f}")

    side = int(round(radius * 2))
    x0, y0 = int(round(centre_x - radius)), int(round(centre_y - radius))
    crop = src.crop((x0, y0, x0 + side, y0 + side)).convert("RGBA")

    # The mask is drawn at four times the size and shrunk, so the edge of the circle is smooth
    # rather than a staircase. At 16 pixels a hard edge is the first thing the eye catches.
    supersample = 4
    alpha = Image.new("L", (side * supersample, side * supersample), 0)
    ImageDraw.Draw(alpha).ellipse(
        (0, 0, side * supersample - 1, side * supersample - 1), fill=255)
    crop.putalpha(alpha.resize((side, side), Image.LANCZOS))

    for size in SIZES:
        path = OUT / f"oursync-{size}.png"
        crop.resize((size, size), Image.LANCZOS).save(path, "PNG", optimize=True)
        print(f"wrote {path.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
