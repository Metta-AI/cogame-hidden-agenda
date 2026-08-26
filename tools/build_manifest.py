#!/usr/bin/env python3
"""Generates coworld_manifest_template.json.

The manifest inlines README.md, docs/RULES.md, docs/POLICIES.md and
docs/PROTOCOL.md as `game.docs` / `game.protocols` TEXT values (bullwhip's
shape, so the coworld page renders without a network fetch), which means editing
a doc without re-running this builder leaves the coworld page stale.

    python3 tools/build_manifest.py

The image placeholder is derived from `compose.yaml`'s SERVICE NAME, never
hand-written: `services.hidden_agenda` -> {{HIDDEN_AGENDA_IMAGE}}
(lantern 0.1.0, 2026-08-23 -- `coworld build` hard-fails anything else, and
`{{GAME_IMAGE}}` is not a thing). `tests/test_manifest.nim` asserts the
derivation.
"""

import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEATS = 5


def read(path):
    with open(os.path.join(ROOT, path), encoding="utf-8") as handle:
        return handle.read()


def image_placeholder():
    """{{<SERVICE>_IMAGE}}, from the one service in compose.yaml."""
    text = read("compose.yaml")
    body = text.split("services:", 1)[1]
    names = re.findall(r"^  ([A-Za-z_][A-Za-z0-9_]*):", body, re.M)
    if len(names) != 1:
        raise SystemExit(f"compose.yaml must declare exactly one service, "
                         f"found {names}")
    return "{{" + names[0].upper() + "_IMAGE}}", names[0]


def text_value(value):
    return {"type": "text", "value": value}


def ranged(kind, minimum, maximum, default, description):
    return {"type": kind, "minimum": minimum, "maximum": maximum,
            "default": default, "description": description}


IMAGE, SERVICE = image_placeholder()
SECRET_URI = f"secret://coworld/{SERVICE}/anthropic_api_key"

ALIASES = ["RED", "BLUE", "GREEN", "YELLOW", "PINK"]
PLAYERS = [{"name": alias} for alias in ALIASES]

CONFIG_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["tokens"],
    "properties": {
        "tokens": {
            "type": "array", "items": {"type": "string"},
            "minItems": 1, "maxItems": SEATS,
            "description": "One per-seat join token, in slot order.",
        },
        "players": {
            "type": "array",
            "items": {"type": "object",
                      "properties": {"name": {"type": "string"}},
                      "additionalProperties": False},
            "minItems": 1, "maxItems": SEATS,
            "description": "Per-seat display names, in slot order.",
        },
        "num_agents": ranged("integer", SEATS, SEATS, SEATS,
                             "Seats. Hidden Agenda is always five."),
        "seed": {"type": "integer",
                 "description": "Pins the episode; omit to randomise."},
        "impostorSlot": ranged("integer", -1, SEATS - 1, -1,
                               "Pins the impostor; -1 draws it from rngRole."),
        "maxTicks": ranged("integer", 240, 3000, 3000, "Episode length."),
        "depositTarget": ranged("integer", 4, 64, 32, "Deposits to win."),
        "carryCap": ranged("integer", 1, 4, 2, "Gems a cog can hold."),
        "mineTicks": ranged("integer", 12, 240, 72, "Ticks to cut one gem."),
        "seamCapacity": ranged("integer", 1, 8, 3, "Gems standing per seam."),
        "seamRegrowTicks": ranged("integer", 24, 480, 120,
                                  "Ticks between seam regrowths."),
        "moveCooldown": ranged("integer", 1, 8, 2, "Ticks between moves."),
        "freezeRange": ranged("integer", 1, 4, 2,
                              "Chebyshev radius of the freeze beam."),
        "freezeCooldownTicks": ranged("integer", 30, 600, 260,
                                      "Ticks between freezes."),
        "visionRadius": ranged("integer", 3, 14, 8,
                               "Cells seen inside the 90-degree cone."),
        "awarenessRadius": ranged("integer", 0, 4, 4,
                                  "Cells seen in every direction."),
        "sweepTicks": ranged("integer", 1, 32, 8,
                             "Ticks per quadrant of a guard's sweep."),
        "meetingCadenceTicks": ranged("integer", 50, 1000, 200,
                                      "Scheduled meeting interval."),
        "meetingTicks": ranged("integer", 10, 200, 25, "Meeting length."),
        "chat": {"type": "boolean", "default": True,
                 "description": "One statement round per meeting."},
        "sayTick": ranged("integer", -1, 200, -1,
                          "Offset at which every say is revealed; -1 = none."),
        "revealTick": ranged("integer", 1, 200, 5,
                             "Offset at which initial votes become visible."),
        "switchTick": ranged("integer", 1, 200, 18,
                             "Offset at which conditionals evaluate."),
        "resolveTick": ranged("integer", 1, 200, 23,
                              "Offset at which the tally resolves."),
        "planSteps": ranged("integer", 1, 5, 3, "Jobs per plan."),
        "llmTimeoutSeconds": ranged("integer", 5, 60, 14,
                                    "Deadline for one decision batch."),
        "minBatchSeconds": ranged("integer", 0, 60, 14,
                                  "Wall-clock floor between batch starts."),
        "maxDecisionBatches": ranged("integer", 1, 60, 20,
                                     "Hard cap on decision batches."),
        "maxOutputTokens": ranged("integer", 200, 2000, 900,
                                  "Model output cap."),
        "model": {"type": "string", "default": "claude-haiku-4-5",
                  "description": "Direct-Anthropic model id."},
        "episodeTimeoutSeconds": ranged("integer", 60, 3600, 1200,
                                        "Assumed platform episode budget."),
        "playerConnectTimeoutSeconds": ranged("integer", 5, 600, 120,
                                              "Lobby wait."),
        "shutdownGraceSeconds": ranged("integer", 0, 120, 20,
                                       "How long /healthz answers after the "
                                       "artifacts are written."),
        "showPlayerLabels": {"type": "boolean", "default": True,
                             "description": "Spectator-side name plates."},
        "variant": {"type": "string", "default": "hidden-agenda",
                    "description": "Variant id, recorded in the replay."},
    },
}

RESULTS_SCHEMA = {
    "type": "object",
    "required": ["names", "aliases", "roles", "scores", "win", "winner",
                 "reason", "ending"],
    "properties": {
        "names": {"type": "array", "items": {"type": "string"},
                  "minItems": SEATS, "maxItems": SEATS},
        "aliases": {"type": "array", "items": {"type": "string"},
                    "minItems": SEATS, "maxItems": SEATS},
        "roles": {"type": "array",
                  "items": {"type": "string",
                            "enum": ["crew", "impostor"]},
                  "minItems": SEATS, "maxItems": SEATS},
        "scores": {"type": "array", "items": {"type": "integer"},
                   "minItems": SEATS, "maxItems": SEATS},
        "win": {"type": "array", "items": {"type": "boolean"},
                "minItems": SEATS, "maxItems": SEATS},
        "winner": {"type": "string", "enum": ["crew", "impostor", "none"]},
        "deposits": {"type": "integer"},
        "depositTarget": {"type": "integer"},
        "freezes": {"type": "integer"},
        "witnessedFreezes": {"type": "integer"},
        "ejections": {"type": "integer"},
        "ejectedImpostor": {"type": "boolean"},
        "wrongEjections": {"type": "integer"},
        "fakeDeposits": {"type": "integer"},
        "meetings": {"type": "integer"},
        "ticks": {"type": "integer"},
        "reason": {"type": "string",
                   "enum": ["complete", "deadline", "forfeit"]},
        "ending": {"type": "string",
                   "enum": ["crew_deposits", "impostor_ejected",
                            "impostor_isolation", "timeout", "deadline",
                            "forfeit"]},
    },
}


def variant(vid, name, description, overrides):
    config = {
        "num_agents": SEATS,
        "players": PLAYERS,
        "maxTicks": 3000,
        "depositTarget": 32,
        "carryCap": 2,
        "mineTicks": 72,
        "seamCapacity": 3,
        "seamRegrowTicks": 120,
        "moveCooldown": 2,
        "freezeRange": 2,
        "meetingCadenceTicks": 200,
        "awarenessRadius": 4,
        "sweepTicks": 8,
        "planSteps": 3,
        "variant": vid,
    }
    config.update(overrides)
    return {"id": vid, "name": name, "description": description,
            "game_config": config}


MANIFEST = {
    "$schema": "https://softmax.com/schemas/coworld-manifest.json",
    "tags": ["social-deduction", "hidden-role", "grid", "fog-of-war",
             "llm-driven", "melting-pot", "five-player"],
    "episode_timeout_minutes": 20,
    "game": {
        "name": SERVICE,
        "owner": "daveey",
        "description": (
            "Five cogs mine a sealed station for a central grate. One of them "
            "is an impostor with a freeze beam, frozen crew stay on the floor "
            "as evidence, and a meeting fires the instant a freeze happens "
            "inside somebody's field of view."),
        "runnable": {
            "type": "game",
            "image": IMAGE,
            "run": ["/bin/hidden-agenda"],
            "env": {"ANTHROPIC_API_KEY_URI": SECRET_URI},
            "source_url":
                "https://github.com/Metta-AI/cogame-hidden-agenda/tree/main",
        },
        "replay_viewer": {"bundle": "static-replay-viewer"},
        "config_schema": CONFIG_SCHEMA,
        "results_schema": RESULTS_SCHEMA,
        "docs": {
            "readme": text_value(read("README.md")),
            "pages": [
                {"id": "rules.md", "title": "Rules",
                 "content": text_value(read("docs/RULES.md"))},
                {"id": "policies.md", "title": "Fielding a policy",
                 "content": text_value(read("docs/POLICIES.md"))},
            ],
        },
        "protocols": {
            "player": text_value(read("docs/PROTOCOL.md")),
            "global": text_value(
                "The /global websocket and the static replay bundle share ONE "
                "packet shape - see the \"Global / viewer packet\" section "
                "below. The bundle is opened as index.html?replay=<s3 url> and "
                "contacts no server except S3 for the .replay file.\n\n" +
                read("docs/PROTOCOL.md")),
        },
    },
    "player": [
        {
            "id": "hidden-agenda-miner",
            "type": "player",
            "name": "Hidden Agenda miner",
            "description": ("The working baseline: mine, deposit, watch "
                            "whoever you have gone longest without seeing, and "
                            "vote a deterministic suspicion score. As the "
                            "impostor it hunts only when its own view is "
                            "empty."),
            "image": IMAGE,
            "run": ["/bin/hidden-agenda-player"],
            "env": {"PLAYER_SCRIPTED": "miner"},
            "resources": {"requests": {"cpu": "100m", "memory": "64Mi"},
                          "limits": {"cpu": "1"}},
        },
        {
            "id": "hidden-agenda-lurker",
            "type": "player",
            "name": "Hidden Agenda lurker",
            "description": ("The foil: head-down crew that works one seam all "
                            "episode, and an impostor that fires the instant "
                            "the beam is legal, witnesses or not."),
            "image": IMAGE,
            "run": ["/bin/hidden-agenda-player"],
            "env": {"PLAYER_SCRIPTED": "lurker"},
            "resources": {"requests": {"cpu": "100m", "memory": "64Mi"},
                          "limits": {"cpu": "1"}},
        },
    ],
    "variants": [
        variant("hidden-agenda", "Hidden Agenda",
                ("The default: one statement round per meeting, revealed "
                 "simultaneously, plus a conditional vote switch. 60-tick "
                 "meetings."),
                {"chat": True, "meetingTicks": 60, "sayTick": 10,
                 "revealTick": 24, "switchTick": 46, "resolveTick": 56,
                 "visionRadius": 8, "freezeCooldownTicks": 260}),
        variant("hidden-agenda-notalk", "Hidden Agenda (no talk)",
                ("The pure spatial-evidence mode: no chat at all. 25 ticks of "
                 "visible, changeable votes are the only channel anybody has."),
                {"chat": False, "meetingTicks": 25, "sayTick": -1,
                 "revealTick": 5, "switchTick": 18, "resolveTick": 23,
                 "visionRadius": 8, "freezeCooldownTicks": 260}),
        variant("hidden-agenda-blind", "Hidden Agenda (narrow eyes)",
                ("Tighter cones and a shorter beam cooldown: witnessed freezes "
                 "become rare, absence-evidence and the deposit counter "
                 "dominate, and the impostor can press."),
                {"chat": False, "meetingTicks": 25, "sayTick": -1,
                 "revealTick": 5, "switchTick": 18, "resolveTick": 23,
                 "visionRadius": 5, "freezeCooldownTicks": 120}),
    ],
    "certification": {
        "game_config": {
            "num_agents": SEATS,
            "seed": 5,
            "impostorSlot": 4,
            "variant": "hidden-agenda-notalk",
            "chat": False,
            "meetingTicks": 25,
            "sayTick": -1,
            "revealTick": 5,
            "switchTick": 18,
            "resolveTick": 23,
            "maxTicks": 900,
            "depositTarget": 12,
            # The soak in ci.yml's wasm-viewer job plays the replay this
            # fixture produces for 10 s at 1x, so a replay barely longer than
            # the soak reports a FINISHED playback as a frozen one (ecos,
            # 2026-08-23). At the shipped 260-tick cooldown the lurker's second
            # freeze lands at t=318 and the episode ends at 343 ticks = 14.3 s,
            # a 4.3 s margin. 500 pushes the second freeze out to t=558: 608
            # ticks = 25.3 s, still ending impostor_ejected with 2 witnessed
            # freezes, 4 meetings and 15 votes, so every headline surface is
            # still exercised with 2.5x the soak window.
            # tests/test_manifest.nim plays it and asserts the length.
            "freezeCooldownTicks": 500,
            "minBatchSeconds": 0,
            "playerConnectTimeoutSeconds": 120,
            "players": PLAYERS,
        },
        "players": [
            {"player_id": "hidden-agenda-miner"},
            {"player_id": "hidden-agenda-miner"},
            {"player_id": "hidden-agenda-miner"},
            {"player_id": "hidden-agenda-miner"},
            {"player_id": "hidden-agenda-lurker"},
        ],
    },
}


def main():
    out = os.path.join(ROOT, "coworld_manifest_template.json")
    with open(out, "w", encoding="utf-8") as handle:
        json.dump(MANIFEST, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    print("wrote", out)


if __name__ == "__main__":
    main()
