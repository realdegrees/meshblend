"""Composes the README's animation from the raw captures DemoBuilder writes to docs/images/raw.

    python tools/readme_images.py

One GIF: for each ground, the rock cluster with the blend off left of a divider and on right of it, the divider sweeping
across and back, fading from one ground into the next. Every frame carries a magnified close-up of the seam where the
boulder, a stone and the ground meet. And one still of the debug views: the ids beside the blend weight.
"""
import math
import os

from PIL import Image, ImageDraw, ImageFont

RAW = "docs/images/raw"
OUT = "docs/images/mesh-blend.gif"
PANEL = (720, 540)
INSET = (216, 162)  # on the panel; it shows a region of the full-resolution capture of the same size, so ~3x zoomed
SLANT = 0.06  # share of the width the divider leans across, top to bottom
LINE = 7
LINE_COLOR = (64, 220, 96)
STEPS = 56  # frames per sweep, one way
STEP_MS = 50
HOLD_MS = 600
FADE = 10  # frames crossfading from one window into the next
FONT = ImageFont.load_default(size=26)

WINDOWS = [
    ("sand", "sand-off", "sand-on", "Off", "On"),
    ("grass", "grass-off", "grass-on", "Off", "On"),
    ("dirt", "dirt-off", "dirt-on", "Off", "On"),
]


def load(name):
    return Image.open(os.path.join(RAW, f"{name}.png")).convert("RGB")


def text(panel, xy, value, anchor, opacity):
    if opacity <= 0.0:
        return
    layer = Image.new("RGBA", panel.size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).text(xy, value, font=FONT, fill=(255, 255, 255, 255), anchor=anchor, stroke_width=2,
                               stroke_fill=(0, 0, 0, 255))
    layer.putalpha(layer.getchannel("A").point(lambda a: round(a * opacity)))
    panel.paste(layer, (0, 0), layer)


def dashed(draw, a, b, dash=8):
    length = ((b[0] - a[0]) ** 2 + (b[1] - a[1]) ** 2) ** 0.5
    count = max(int(length / dash), 1)
    for i in range(0, count, 2):
        t0, t1 = i / count, min((i + 1) / count, 1)
        draw.line([(a[0] + (b[0] - a[0]) * t0, a[1] + (b[1] - a[1]) * t0),
                   (a[0] + (b[0] - a[0]) * t1, a[1] + (b[1] - a[1]) * t1)], fill=(255, 255, 255), width=2)


def frame(left, right, split, focus, left_text, right_text):
    # Each label is drawn on its own side's picture, so the divider cuts through it like through the rest of that side.
    left, right = left.copy(), right.copy()
    width, height = left.size
    to_full = width / PANEL[0]
    label_font = ImageFont.load_default(size=round(26 * to_full))
    for picture, value, x, anchor in ((left, left_text, 16, "lm"), (right, right_text, PANEL[0] - 16, "rm")):
        ImageDraw.Draw(picture).text((x * to_full, 28 * to_full), value, font=label_font, fill=(255, 255, 255),
                                     anchor=anchor, stroke_width=round(2 * to_full), stroke_fill=(0, 0, 0))
    scale = PANEL[0] / width
    # The divider leans; split runs it from wholly off the left edge to wholly off the right one.
    lean = SLANT * width
    top, bottom = split * (width + lean), split * (width + lean) - lean
    mask = Image.new("L", left.size, 0)
    ImageDraw.Draw(mask).polygon([(0, 0), (top, 0), (bottom, height), (0, height)], fill=255)
    full = Image.composite(left, right, mask)
    ImageDraw.Draw(full).line([(top, 0), (bottom, height)], fill=LINE_COLOR, width=round(LINE / scale))

    panel = full.resize(PANEL, Image.LANCZOS)
    draw = ImageDraw.Draw(panel)

    # The close-up: a region of the full-resolution frame, centred on the seam, shown magnified in the lower left corner.
    cx, cy = focus[0] * width, focus[1] * height
    region = (round(cx - INSET[0] / 2), round(cy - INSET[1] / 2), round(cx + INSET[0] / 2), round(cy + INSET[1] / 2))
    inset = full.crop(region)
    origin = (0, PANEL[1] - INSET[1])
    marked = [v * scale for v in region]
    draw.rectangle(marked, outline=(255, 255, 255), width=2)
    dashed(draw, (marked[0], marked[1]), (origin[0], origin[1]))
    dashed(draw, (marked[2], marked[3]), (origin[0] + INSET[0], PANEL[1]))
    panel.paste(inset, origin)
    draw.line([(0, origin[1]), (INSET[0], origin[1]), (INSET[0], PANEL[1])], fill=(255, 255, 255), width=3)

    return panel


def main():
    frames, durations = [], []
    for w, (ground, left_name, right_name, left_text, right_text) in enumerate(WINDOWS):
        left, right = load(left_name), load(right_name)
        fx, fy = map(float, open(os.path.join(RAW, f"{ground}-focus.txt")).read().split())
        fy -= 10 / PANEL[1]
        # Every window starts and ends with the divider off the left edge, showing the right side whole; the next window
        # fades in from there.
        first = frame(left, right, 0.0, (fx, fy), left_text, right_text)
        if frames:
            last = frames[-1]
            for k in range(1, FADE + 1):
                frames.append(Image.blend(last, first, k / (FADE + 1)))
                durations.append(STEP_MS)
        sweep = [i / (STEPS - 1) for i in range(STEPS)]
        sweep = [0.5 - 0.5 * math.cos(t * math.pi) for t in sweep]
        for k, split in enumerate(sweep + sweep[::-1][1:]):
            frames.append(frame(left, right, split, (fx, fy), left_text, right_text))
            durations.append(HOLD_MS if k in (0, STEPS - 1, 2 * STEPS - 2) else STEP_MS)

    # One palette for the whole animation, from a frame of every window, so no window loses its colours (the
    # weight view's red) and nothing shifts between frames.
    samples = frames[STEPS // 2::2 * STEPS + FADE]
    sheet = Image.new("RGB", (PANEL[0], PANEL[1] * len(samples)))
    for i, sample in enumerate(samples):
        sheet.paste(sample, (0, i * PANEL[1]))
    palette = sheet.quantize(colors=255, method=Image.Quantize.MEDIANCUT)
    images = [f.quantize(palette=palette, dither=Image.Dither.NONE) for f in frames]
    images[0].save(OUT, save_all=True, append_images=images[1:], duration=durations, loop=0, optimize=True)
    print("wrote", OUT, len(images), "frames")


def debug_views():
    size = (640, 480)
    canvas = Image.new("RGB", (size[0] * 2 + 6, size[1]), (255, 255, 255))
    for i, (name, value) in enumerate((("sand-ids", "Ids"), ("sand-weight", "Weight"))):
        panel = load(name).resize(size, Image.LANCZOS)
        text(panel, (16, 28), value, "lm", 1.0)
        canvas.paste(panel, (i * (size[0] + 6), 0))
    canvas.save("docs/images/debug-views.jpg", quality=88)
    print("wrote docs/images/debug-views.jpg")


if __name__ == "__main__":
    main()
    debug_views()
