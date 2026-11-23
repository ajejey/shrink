#!/usr/bin/env python3
"""Each App Store screenshot: a real screen under its job in plain words (store/screenshots.json).

    python3 scripts/store-frames.py store/screenshots.json store/raw store/framed

Raw screens are 1320 x 2868 captures from the 6.9" iPhone simulator; the framed ones are the same size,
which is what App Store Connect's 6.9" slot takes. Runs on GitHub's Mac (needs Pillow and the system's
San Francisco or Helvetica Neue font).
"""
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

W, H = 1320, 2868
TOP = (37, 99, 235)      # the app icon's blue
BOTTOM = (124, 58, 237)  # and its purple
SCREEN_SCALE = 0.82
BOTTOM_MARGIN = 64
CORNER = 66


def font(size):
    try:
        f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)
        try:
            f.set_variation_by_name("Bold")
        except Exception:
            pass
        return f
    except OSError:
        pass
    for path, index in (("/System/Library/Fonts/HelveticaNeue.ttc", 1), ("/System/Library/Fonts/Helvetica.ttc", 1)):
        try:
            return ImageFont.truetype(path, size, index=index)
        except OSError:
            continue
    return ImageFont.load_default(size)


def background():
    img = Image.new("RGB", (W, H))
    draw = ImageDraw.Draw(img)
    for y in range(H):
        t = y / (H - 1)
        draw.line([(0, y), (W, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)))
    return img


def wrap(text, f, width):
    lines, line = [], ""
    for word in text.split():
        trial = (line + " " + word).strip()
        if not line or f.getlength(trial) <= width:
            line = trial
        else:
            lines.append(line)
            line = word
    lines.append(line)
    return lines


def frame(raw_path, caption, out_path):
    canvas = background()
    screen = Image.open(raw_path).convert("RGB")
    sw = round(W * SCREEN_SCALE)
    sh = round(screen.height * sw / screen.width)
    screen = screen.resize((sw, sh), Image.LANCZOS)
    mask = Image.new("L", (sw, sh), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, sw - 1, sh - 1], radius=CORNER, fill=255)
    top = H - sh - BOTTOM_MARGIN
    canvas.paste(screen, ((W - sw) // 2, top), mask)

    # The caption: the biggest text, the job in the person's words, at most two lines.
    size = 108
    f = font(size)
    lines = wrap(caption, f, W - 150)
    while len(lines) > 2 and size > 72:
        size -= 6
        f = font(size)
        lines = wrap(caption, f, W - 150)
    line_height = round(size * 1.2)
    y = (top - line_height * len(lines)) // 2 + 10
    draw = ImageDraw.Draw(canvas)
    for line in lines:
        draw.text((W / 2, y), line, font=f, fill="white", anchor="ma")
        y += line_height
    canvas.save(out_path, "PNG")


def main():
    spec, raw_dir, out_dir = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    out_dir.mkdir(parents=True, exist_ok=True)
    for shot in json.loads(spec.read_text()):
        raw = raw_dir / f"{shot['state']}.png"
        if not raw.exists():
            sys.exit(f"missing {raw}")
        frame(raw, shot["caption"], out_dir / shot["file"])
        print("framed", shot["file"])


if __name__ == "__main__":
    main()
