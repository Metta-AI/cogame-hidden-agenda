#!/usr/bin/env python3
"""Generates the Hidden Agenda cog sheets with nano-banana (Gemini image gen).

FIVE sheets, one per cog STATE, each carrying all five body colours in one
render so the style stays consistent across the roster:

    front  walk  mine  carry  frozen

Each sheet is a single row of five Softmax cogs on a flat chroma backdrop;
`scripts/art/split_cog_sheet.py` keys the backdrop out, splits the row and
writes `data/art/cog_<colour>_<state>.png` (and `frozen_<colour>.png`).

    GEMINI_API_KEY=... python3 scripts/art/gen_cog_sheets.py [state ...]

The key is NEVER printed, written to a file or passed as a URL parameter: it
rides the `x-goog-api-key` header only (playbooks/art-nanobanana.md).
The generated sheets are COMMITTED under scripts/art/source/ so the sprites are
reproducible; CI never regenerates art.
"""

import base64
import json
import os
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "source")
ENDPOINT = ("https://generativelanguage.googleapis.com/v1beta/models/"
            "gemini-2.5-flash-image:generateContent")

# The canonical Softmax cog, used as an inline style anchor so every sheet
# renders the SAME character in five liveries.
REFERENCE = os.path.join(SOURCE, "cog_reference.png")

COMMON = """Using this robot character ("cog") as the exact character design
reference, draw FIVE of these cogs side by side in one row, evenly spaced, the
same size, the same clean flat cartoon rendering, viewed from a slightly raised
front three-quarter angle so they read as game sprites on a top-down board.
They are mining robots in a sealed space station.
From LEFT to RIGHT the body plating colours are, exactly:
1. RED (#e0523a)  2. BLUE (#3f7cc4)  3. GREEN (#45a85e)
4. YELLOW (#ddc531)  5. PINK (#d96ab0)
Every cog keeps the reference's wheeled base, cyan screen face and riveted
shoulders; only the plating colour differs between them.
Background: perfectly flat, solid, uniform pure bright green (#00FF00), no
shadows, no gradients, no floor, no text, no labels - it will be chroma-keyed
out.
"""

STATES = {
    "front": COMMON + """POSE: standing still, facing the viewer, arms relaxed
at the sides, empty handed.""",
    "walk": COMMON + """POSE: mid-stride, leaning slightly forward, one arm
swung ahead of the body, wheels blurred with motion, as if rolling briskly to
the left of frame.""",
    "mine": COMMON + """POSE: swinging a short steel mining pick over one
shoulder toward an unseen wall, body twisted into the swing, sparks at the pick
head. The pick is the same steel for every cog; only the body plating colour
differs.""",
    "carry": COMMON + """POSE: standing, holding a single large glowing cyan
crystal gem in both hands in front of the chest. The gem is the same bright cyan
for every cog; only the body plating colour differs.""",
    "frozen": COMMON + """POSE: each cog is completely encased in a solid block
of pale blue translucent ice - a tall rounded ice block with the coloured cog
clearly visible frozen inside it, arms up, screen face dark. The ice is the same
pale blue for every one; only the trapped cog's plating colour differs.""",
}


def generate(state: str) -> None:
    prompt = STATES[state]
    parts = []
    if os.path.exists(REFERENCE):
        with open(REFERENCE, "rb") as handle:
            parts.append({"inline_data": {
                "mime_type": "image/png",
                "data": base64.b64encode(handle.read()).decode()}})
    parts.append({"text": prompt})
    body = {
        "contents": [{"parts": parts}],
        "generationConfig": {"responseModalities": ["IMAGE"]},
    }
    request = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(body).encode(),
        headers={"x-goog-api-key": os.environ["GEMINI_API_KEY"],
                 "content-type": "application/json"})
    with urllib.request.urlopen(request) as response:
        payload = json.load(response)
    candidates = payload.get("candidates") or []
    if not candidates:
        raise SystemExit(f"{state}: no candidate in the response: "
                         f"{json.dumps(payload)[:400]}")
    for part in candidates[0]["content"]["parts"]:
        if "inlineData" in part:
            os.makedirs(SOURCE, exist_ok=True)
            out = os.path.join(SOURCE, f"cogs_{state}.png")
            with open(out, "wb") as handle:
                handle.write(base64.b64decode(part["inlineData"]["data"]))
            print("wrote", out)
            return
    raise SystemExit(f"{state}: the response carried no image")


def main() -> None:
    wanted = sys.argv[1:] or list(STATES)
    for state in wanted:
        if state not in STATES:
            raise SystemExit(f"unknown state {state!r}; "
                             f"one of {', '.join(STATES)}")
        generate(state)


if __name__ == "__main__":
    main()
