"""Check complete, seed-separated Hidden Agenda post-training episodes."""

import json
import subprocess
import sys
from pathlib import Path
from tempfile import TemporaryDirectory


for variant in ("hidden-agenda", "hidden-agenda-notalk", "hidden-agenda-blind"):
    with TemporaryDirectory() as temporary:
        output = Path(temporary) / variant
        subprocess.run([sys.argv[1], str(output), "10", variant], check=True)
        manifest = json.loads((output / "manifest.json").read_text())
        train = [json.loads(line) for line in (output / "train.jsonl").read_text().splitlines()]
        validation = [json.loads(line) for line in (output / "validation.jsonl").read_text().splitlines()]
        assert len(manifest["runs"]) == 10
        assert manifest["train_examples"] == len(train) > 0
        assert manifest["validation_examples"] == len(validation) > 0
        assert {row["seed"] for row in train}.isdisjoint({row["seed"] for row in validation})
        assert all(run["reason"] == "complete" and sum(run["scores"]) == 0 for run in manifest["runs"])
        for row in train + validation:
            assert row["game"] == "hidden-agenda"
            assert [part["role"] for part in row["prompt"]] == ["system", "user"]
            assert "DEPOSITS " in row["prompt"][1]["content"]
            reply = json.loads(row["completion"][0]["content"])
            assert 1 <= len(reply["plan"]) <= 3
            assert all("job" in step for step in reply["plan"])
            if variant != "hidden-agenda":
                assert reply["say"] == ""
        print(f"{variant}: {len(train)} train, {len(validation)} validation decisions")
