"""Complete published games through production bridges, including private notes."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path
from typing import TextIO, cast

ROOT = Path(__file__).resolve().parents[1]
TRAIN = ["canonical", "plain", "numbered", "questions", "reordered"]
WORDINGS = TRAIN + ["heldout-briefing", "heldout-reference"]


def play(binary, variant, wording, seed, language, prompt_seed=0, original=False):
    config = next(
        entry["game_config"]
        for entry in json.loads((ROOT / "coworld_manifest_template.json").read_text())[
            "variants"
        ]
        if entry["id"] == variant
    )
    process = subprocess.Popen(
        [
            str(binary),
            str(ROOT / "coworld_manifest_template.json"),
            variant,
            *(["--language"] if language else []),
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    )
    stdin = cast(TextIO, process.stdin)
    stdout = cast(TextIO, process.stdout)

    def request(payload):
        stdin.write(json.dumps(payload) + "\n")
        stdin.flush()
        line = stdout.readline()
        assert line, process.poll()
        return json.loads(line)

    rows, systems = [], {}
    try:
        observation = request(
            {
                "kind": "reset",
                "players": 5,
                "seed": seed,
                "promptVariant": wording,
                "promptSeed": prompt_seed,
                "split": "evaluation",
            }
        )
        while observation["kind"] == "decision":
            system, user = (message["content"] for message in observation["messages"])
            seat = observation["seat"]
            view = observation["semantic_view"]
            if not original:
                metadata = view.pop("prompt_template")
                assert metadata["bank"] == "hidden-agenda-rules-v1"
                assert metadata["variant"] == (
                    TRAIN[prompt_seed % 5] if wording == "mixed" else wording
                )
                assert (
                    metadata["system_sha256"]
                    == hashlib.sha256(system.encode()).hexdigest()
                )
                assert (
                    metadata["user_sha256"] == hashlib.sha256(user.encode()).hexdigest()
                )
            assert view.pop("system") == system
            if seat in systems:
                assert systems[seat] == system
            systems[seat] = system
            encoding = request({"kind": "encode"})
            assert len(encoding["values"]) == 74
            assert [len(head["choices"]) for head in encoding["action_heads"]] == [2, 6]
            action = json.loads(request({"kind": "teacher"})["response"])
            if language:
                action.update(
                    notes=f"Private mémoire {seat} turn {observation['turn']}",
                    hunch="Watching the grate",
                    say="Watch the grate" if config["chat"] else "",
                )
            result = request(
                {
                    "kind": "step",
                    "decision_id": observation["decision_id"],
                    "response": json.dumps(action),
                }
            )
            assert result["kind"] == "accepted" and result["action"] == action, (
                language,
                action,
                result["action"],
            )
            rows.append((view, user, encoding, result["action"]))
            observation = result["observation"]
        assert observation["kind"] == "terminal" and rows and len(rows) <= 120
        assert sorted(observation["scores"].values()) in (
            [0] * 5,
            [-4, 1, 1, 1, 1],
            [-1, -1, -1, -1, 4],
        )
        return rows, observation, systems
    finally:
        stdin.close()
        stdout.close()
        assert process.wait(timeout=10) == 0


if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    count = 0
    for variant in ("hidden-agenda", "hidden-agenda-notalk", "hidden-agenda-blind"):
        for language in (False, True):
            for seed in ("wording-1", "wording-2"):
                reference = play(binary, variant, "canonical", seed, language)
                count += 1
                if len(sys.argv) == 3 and not language:
                    assert reference == play(
                        Path(sys.argv[2]).resolve(),
                        variant,
                        "canonical",
                        seed,
                        False,
                        original=True,
                    )
                for wording in WORDINGS[1:]:
                    actual = play(binary, variant, wording, seed, language)
                    assert actual[:2] == reference[:2]
                    assert actual[2] != reference[2]
                    for seat in actual[2]:
                        assert (
                            actual[2][seat].split("YOU ARE", 1)[1]
                            == reference[2][seat].split("YOU ARE", 1)[1]
                        )
                    count += 1
                for prompt_seed in range(5):
                    actual = play(binary, variant, "mixed", seed, language, prompt_seed)
                    assert actual[:2] == reference[:2]
                    count += 1
    print(count, "complete games preserve role rules, notes, actions and outcomes")
