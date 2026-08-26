#!/usr/bin/env python3
"""Deterministic Pillow art for the Hidden Agenda board.

Owns everything in `data/art` EXCEPT the cog bodies and the ice blocks:
`cog_<colour>_{front,walk,mine,carry}.png` and `frozen_<colour>.png` are
nano-banana renders of the Softmax cog and are written by
`scripts/art/split_cog_sheet.py` from the committed sheets under
`scripts/art/source/` (playbooks/art-nanobanana.md).

What this script writes:

    floor_hub.png floor_vault.png floor_gallery.png floor_corridor.png
    wall.png wall_pillar.png
    seam_3.png seam_2.png seam_1.png seam_0.png
    grate_lit.png grate_dim.png
    gem.png beam.png shatter.png vote_chip.png
    lockerroom/bg.jpg lockerroom/<colour>.png

    python3 scripts/art/gen_agenda_art.py [outdir]

Default outdir is data/art. Everything is a pure function of the constants
below: run it twice and the bytes match.
"""

import math
import os
import random
import sys

from PIL import Image, ImageDraw, ImageFilter

CELL = 40
COLOURS = {
    "red": (224, 82, 58),
    "blue": (63, 124, 196),
    "green": (69, 168, 94),
    "yellow": (221, 197, 49),
    "pink": (217, 106, 176),
}
PAPER = (242, 232, 216)
INK = (23, 18, 13)
AMBER = (232, 163, 61)
ICE = (191, 233, 247)


def new(size, fill=(0, 0, 0, 0)):
    return Image.new("RGBA", size, fill)


def rivet(draw, x, y, shade=(242, 232, 216, 40)):
    draw.rectangle([x, y, x + 2, y + 2], fill=shade)


def floor_tile(base, seed):
    """A riveted station floor plate in one room's tint."""
    img = new((CELL, CELL), base + (255,))
    draw = ImageDraw.Draw(img)
    rng = random.Random(seed)
    for _ in range(26):
        x = rng.randrange(CELL)
        y = rng.randrange(CELL)
        tone = rng.randrange(-9, 10)
        draw.point((x, y), fill=tuple(
            max(0, min(255, c + tone)) for c in base) + (255,))
    draw.rectangle([0, 0, CELL - 1, CELL - 1], outline=(242, 232, 216, 14))
    for x, y in ((4, 4), (CELL - 7, 4), (4, CELL - 7), (CELL - 7, CELL - 7)):
        rivet(draw, x, y)
    return img


def wall_tile(pillar=False):
    img = new((CELL, CELL), INK + (255,))
    draw = ImageDraw.Draw(img)
    draw.rectangle([0, 0, CELL - 1, 3], fill=(242, 232, 216, 22))
    draw.rectangle([0, CELL - 4, CELL - 1, CELL - 1], fill=(0, 0, 0, 90))
    for y in range(6, CELL - 6, 9):
        draw.line([(3, y), (CELL - 4, y)], fill=(242, 232, 216, 10))
    if pillar:
        draw.ellipse([7, 7, CELL - 8, CELL - 8], fill=(52, 42, 32, 255),
                     outline=(242, 232, 216, 40))
    for x, y in ((5, CELL - 9), (CELL - 8, CELL - 9)):
        rivet(draw, x, y, (242, 232, 216, 34))
    return img


def seam_tile(gems):
    """A gem seam in one of four richness states, 3 gems down to 0."""
    img = new((CELL, CELL), (43, 52, 58, 255))
    draw = ImageDraw.Draw(img)
    rng = random.Random(900 + gems)
    for _ in range(38):
        x = rng.randrange(CELL)
        y = rng.randrange(CELL)
        draw.point((x, y), fill=(70, 84, 92, 255))
    draw.rectangle([1, 1, CELL - 2, CELL - 2], outline=(140, 200, 220, 90))
    for i in range(gems):
        cx = 10 + i * 9
        cy = 27
        draw.polygon([(cx, cy - 6), (cx + 5, cy), (cx, cy + 6), (cx - 5, cy)],
                     fill=(143, 227, 240, 255), outline=(234, 250, 255, 255))
    return img


def grate_tile(lit):
    img = new((CELL, CELL), ((74, 60, 38) if lit else (58, 48, 32)) + (255,))
    draw = ImageDraw.Draw(img)
    bar = AMBER + (150 if lit else 70,)
    for y in range(6, CELL - 4, 8):
        draw.line([(4, y), (CELL - 5, y)], fill=bar, width=2)
    draw.rectangle([0, 0, CELL - 1, CELL - 1], outline=(242, 232, 216, 34))
    return img


def gem_sprite():
    img = new((24, 24))
    draw = ImageDraw.Draw(img)
    draw.polygon([(12, 1), (22, 11), (12, 23), (2, 11)],
                 fill=(143, 227, 240, 255), outline=(234, 250, 255, 255))
    draw.polygon([(12, 1), (16, 11), (12, 15), (8, 11)],
                 fill=(206, 245, 252, 255))
    return img


def beam_sprite():
    """One horizontal beam segment; the renderer stretches it end to end."""
    img = new((64, 12))
    draw = ImageDraw.Draw(img)
    for i, alpha in enumerate((70, 140, 235, 140, 70)):
        draw.line([(0, 4 + i), (63, 4 + i)], fill=ICE + (alpha,))
    return img.filter(ImageFilter.GaussianBlur(0.6))


def shatter_sprite():
    img = new((48, 48))
    draw = ImageDraw.Draw(img)
    for i in range(12):
        angle = i * math.pi / 6
        x = 24 + math.cos(angle) * 20
        y = 24 + math.sin(angle) * 20
        draw.line([(24, 24), (x, y)], fill=ICE + (200,), width=2)
    draw.ellipse([16, 16, 32, 32], fill=(234, 250, 255, 220))
    return img


def vote_chip():
    img = new((28, 20))
    draw = ImageDraw.Draw(img)
    draw.rectangle([0, 0, 27, 19], fill=(20, 14, 9, 210),
                   outline=PAPER + (60,))
    draw.ellipse([9, 5, 18, 14], fill=AMBER + (255,))
    return img


def lockerroom_bg():
    """The station hub, seen from the airlock: the pre-load curtain plate."""
    img = Image.new("RGB", (960, 540), (22, 17, 13))
    draw = ImageDraw.Draw(img)
    for y in range(540):
        t = y / 539.0
        shade = tuple(int(a + (b - a) * t)
                      for a, b in ((22, 16), (17, 11), (13, 7)))
        draw.line([(0, y), (959, y)], fill=shade)
    # the grate, lit, at the vanishing point
    for i in range(9):
        w = 300 - i * 26
        h = 26
        x = 480 - w // 2
        y = 300 + i * 16
        draw.rectangle([x, y, x + w, y + h], outline=(232, 163, 61, 90))
    draw.ellipse([360, 250, 600, 400], fill=(58, 46, 30))
    for y in range(266, 384, 14):
        draw.line([(372, y), (588, y)], fill=(232, 163, 61), width=3)
    # bulkhead ribs
    for x in range(40, 960, 160):
        draw.rectangle([x, 60, x + 18, 470], fill=(31, 24, 18))
    return img.filter(ImageFilter.GaussianBlur(1.2))


def portrait(colour):
    img = Image.new("RGB", (160, 200), (26, 20, 15))
    draw = ImageDraw.Draw(img)
    rgb = COLOURS[colour]
    draw.ellipse([30, 40, 130, 140], fill=rgb)
    draw.rectangle([50, 66, 110, 100], fill=(20, 14, 9))
    draw.rectangle([58, 76, 74, 84], fill=(143, 227, 240))
    draw.rectangle([86, 76, 102, 84], fill=(143, 227, 240))
    draw.ellipse([44, 140, 74, 170], fill=(28, 22, 16))
    draw.ellipse([86, 140, 116, 170], fill=(28, 22, 16))
    return img


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join("data", "art")
    os.makedirs(outdir, exist_ok=True)
    os.makedirs(os.path.join(outdir, "lockerroom"), exist_ok=True)

    def save(image, name):
        image.save(os.path.join(outdir, name))

    save(floor_tile((58, 49, 40), 1), "floor_hub.png")
    save(floor_tile((46, 39, 32), 2), "floor_vault.png")
    save(floor_tile((51, 43, 35), 3), "floor_gallery.png")
    save(floor_tile((40, 33, 25), 4), "floor_corridor.png")
    save(wall_tile(False), "wall.png")
    save(wall_tile(True), "wall_pillar.png")
    for gems in range(4):
        save(seam_tile(gems), f"seam_{gems}.png")
    save(seam_tile(3), "seam.png")
    save(grate_tile(True), "grate_lit.png")
    save(grate_tile(False), "grate_dim.png")
    save(grate_tile(True), "grate.png")
    save(gem_sprite(), "gem.png")
    save(beam_sprite(), "beam.png")
    save(shatter_sprite(), "shatter.png")
    save(vote_chip(), "vote_chip.png")
    lockerroom_bg().save(os.path.join(outdir, "lockerroom", "bg.jpg"),
                         quality=86)
    for colour in COLOURS:
        portrait(colour).save(
            os.path.join(outdir, "lockerroom", f"{colour}.png"))
    print("station art written to", outdir)


if __name__ == "__main__":
    main()
