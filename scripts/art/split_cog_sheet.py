#!/usr/bin/env python3
"""Splits the nano-banana cog sheets into the per-colour board sprites.

`scripts/art/source/cogs_<state>.png` is a single Gemini ("nano-banana") render
of the Softmax cog in the five body colours on a flat green backdrop. This
script keys the backdrop out with an edge flood fill (so the GREEN cog's own
plating survives), splits the row into five, crops each to content, pads to a
square and writes 128 px RGBA sprites into `data/art`:

    cog_<colour>_front.png   cog_<colour>_walk.png
    cog_<colour>_mine.png    cog_<colour>_carry.png
    frozen_<colour>.png

    python3 scripts/art/split_cog_sheet.py [outdir]

Default outdir is data/art. `scripts/art/gen_agenda_art.py` owns everything
else in that directory - the station tiles, the seam, the grate, the gem, the
beam FX and the vote chip - and does NOT own these files.
"""

import os
import sys
from collections import deque

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "source")
COLOURS = ["red", "blue", "green", "yellow", "pink"]
STATES = {
    "front": "cog_{colour}_front.png",
    "walk": "cog_{colour}_walk.png",
    "mine": "cog_{colour}_mine.png",
    "carry": "cog_{colour}_carry.png",
    "frozen": "frozen_{colour}.png",
}
SIZE = 128
TOL = 52  # colour distance from the backdrop that still counts as backdrop


TOL_POCKET = 34   # the tighter tolerance the interior-pocket pass uses


def near_tight(p, bg):
    return sum((a - b) ** 2 for a, b in zip(p[:3], bg)) ** 0.5 <= TOL_POCKET


def key_background(img):
    img = img.convert("RGBA")
    w, h = img.size
    px = img.load()
    # Median of the border, which is robust to the corner smudge and to the
    # faint floor grid the model likes to draw.
    border = [px[x, y][:3] for x in range(w) for y in (0, h - 1)] + \
        [px[x, y][:3] for y in range(h) for x in (0, w - 1)]
    bg = tuple(sorted(c[i] for c in border)[len(border) // 2] for i in range(3))

    def near(p):
        return sum((a - b) ** 2 for a, b in zip(p[:3], bg)) ** 0.5 <= TOL

    seen = bytearray(w * h)
    q = deque()
    for x in range(w):
        q.append((x, 0))
        q.append((x, h - 1))
    for y in range(h):
        q.append((0, y))
        q.append((w - 1, y))
    while q:
        x, y = q.popleft()
        if x < 0 or y < 0 or x >= w or y >= h or seen[y * w + x]:
            continue
        seen[y * w + x] = 1
        if not near(px[x, y]):
            continue
        px[x, y] = (0, 0, 0, 0)
        q.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))
    # Second pass: interior pockets the flood fill cannot reach (between an
    # arm and the torso, under a raised pick) are still backdrop. A GLOBAL
    # colour key with a tighter tolerance clears them; the green cog's own
    # plating is far enough from the backdrop green to survive it.
    for y in range(h):
        for x in range(w):
            if px[x, y][3] and near_tight(px[x, y], bg):
                px[x, y] = (0, 0, 0, 0)
    return img


def columns(img, want=5):
    """Five equal slices of the content span.

    A run-of-opaque-columns split is exact when the poses are separated, but the
    frozen sheet's ice blocks overlap, so fall back to an even split of the
    content bounding box rather than mis-counting the row.
    """
    alpha = img.getchannel("A")
    w, h = img.size
    on = [any(alpha.getpixel((x, y)) for y in range(0, h, 3)) for x in range(w)]
    runs, start = [], None
    for x, lit in enumerate(on + [False]):
        if lit and start is None:
            start = x
        elif not lit and start is not None:
            if x - start > 24:
                runs.append((start, x))
            start = None
    if len(runs) == want:
        return runs
    box = img.getbbox()
    if box is None:
        raise SystemExit("the keyed sheet is entirely transparent")
    x0, _, x1, _ = box
    # The frozen sheet's ice blocks OVERLAP, so there are no empty columns to
    # cut on. Cut at the thinnest columns instead: the seam between two blocks
    # is where the opaque-pixel count dips.
    density = [sum(1 for y in range(0, h, 2) if alpha.getpixel((x, y)))
               for x in range(w)]
    step = (x1 - x0) / float(want)
    cuts = [x0]
    for i in range(1, want):
        centre = int(x0 + i * step)
        window = range(max(x0 + 4, centre - int(step * 0.28)),
                       min(x1 - 4, centre + int(step * 0.28)) + 1)
        best = min(window, key=lambda x: (density[x], abs(x - centre)))
        cuts.append(best)
    cuts.append(x1)
    return [(cuts[i], cuts[i + 1]) for i in range(want)]


def sprites(img, want=5):
    _, h = img.size
    out = []
    for x0, x1 in columns(img, want):
        part = img.crop((x0, 0, x1, h))
        box = part.getbbox()
        if box is None:
            raise SystemExit("an empty slice came out of the sheet")
        part = part.crop(box)
        side = max(part.size)
        square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
        # Anchored at the FEET: the board draws cogs anchored at their base, so
        # a pose that is taller than it is wide must not float.
        square.paste(part, ((side - part.width) // 2, side - part.height))
        out.append(square.resize((SIZE, SIZE), Image.LANCZOS))
    return out


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join("data", "art")
    os.makedirs(outdir, exist_ok=True)
    written = 0
    for state, pattern in STATES.items():
        sheet = os.path.join(SOURCE, f"cogs_{state}.png")
        if not os.path.exists(sheet):
            print("missing sheet, skipping:", sheet)
            continue
        for colour, sprite in zip(COLOURS, sprites(key_background(
                Image.open(sheet)))):
            path = os.path.join(outdir, pattern.format(colour=colour))
            sprite.save(path)
            written += 1
    print(f"{written} cog sprites written to {outdir}")


if __name__ == "__main__":
    main()
