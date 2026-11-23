"""Draws Shrink's app icon: two arrows pointing in to the middle (the "make it smaller" sign) in white
on the app's blue (its accent colour, AccentColor). Writes the 1024 px PNG the asset catalog needs (no transparency,
as the App Store requires). Run: python scripts/make-app-icon.py
"""
from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 1024
SCALE = 4  # draw big, then shrink, for smooth edges
OUT = Path(__file__).resolve().parent.parent / "ios/Shrink/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

BLUE = (37, 99, 235)  # #2563EB, the app's AccentColor
WHITE = (255, 255, 255)


def stroke(draw: ImageDraw.ImageDraw, points, width: int) -> None:
    draw.line(points, fill=WHITE, width=width, joint="curve")
    r = width / 2
    for x, y in (points[0], points[-1]):
        draw.ellipse((x - r, y - r, x + r, y + r), fill=WHITE)


def arrow(draw: ImageDraw.ImageDraw, c: float, sx: int, sy: int, s: float) -> None:
    """One arrow from a corner toward the middle. sx, sy pick the corner (+1 = right/down)."""
    gap, tail, leg, width = 70 * s, 300 * s, 200 * s, 84 * s
    tip = (c + sx * gap, c + sy * gap)
    end = (c + sx * tail, c + sy * tail)
    stroke(draw, [end, tip], round(width))
    # The arrowhead: an L whose corner is the tip, its legs pointing back out.
    stroke(draw, [(tip[0], tip[1] + sy * leg), tip, (tip[0] + sx * leg, tip[1])], round(width))


def main() -> None:
    big = SIZE * SCALE
    img = Image.new("RGB", (big, big), BLUE)
    draw = ImageDraw.Draw(img)
    c = big / 2
    arrow(draw, c, +1, -1, SCALE)  # from the top right
    arrow(draw, c, -1, +1, SCALE)  # from the bottom left
    img = img.resize((SIZE, SIZE), Image.LANCZOS).convert("RGB")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.save(OUT, optimize=True)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
