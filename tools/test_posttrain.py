"""Complete candidate exports joined to applied orders and replay evidence."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path
from tempfile import mkdtemp

root = Path(__file__).resolve().parents[1]
output = (
    Path(sys.argv[2])
    if len(sys.argv) > 2
    else Path(mkdtemp(prefix="hidden-agenda-candidates-"))
)
wordings = ["canonical", "plain", "numbered", "questions", "reordered"]
families = set()
games = 0
for variant in ("hidden-agenda", "hidden-agenda-notalk", "hidden-agenda-blind"):
    reference = None
    for wording in wordings:
        destination = output / variant / wording
        subprocess.run(
            [sys.argv[1], str(destination), "10", variant, wording, "0"],
            cwd=root,
            check=True,
        )
        manifest = json.loads((destination / "manifest.json").read_text())
        assert manifest["review_required"] and len(manifest["runs"]) == 10
        assert not (destination / "train.jsonl").exists()
        assert not (destination / "validation.jsonl").exists()
        assert (destination / "trajectories.jsonl").stat().st_mode & 0o777 == 0o600
        rows = [
            json.loads(line)
            for line in (destination / "trajectories.jsonl").read_text().splitlines()
        ]
        decisions = [row for row in rows if row["event_type"] == "decision"]
        episodes = [row for row in rows if row["event_type"] == "episode"]
        assert len(episodes) == 10 and all(
            row["status"] == "completed" for row in episodes
        )
        families.update(row["seed_family"] for row in episodes)
        orders = {}
        for run in manifest["runs"]:
            replay = json.loads((destination / run["replay"]).read_text())
            assert replay["results"]["reason"] == "complete"
            assert replay["results"]["scores"] == run["scores"]
            for event in replay["events"]:
                if event["k"] == "order":
                    orders[run["episode_id"], event["decision"], event["seat"]] = event
        comparable = []
        for row in decisions:
            system, user = (part["content"] for part in row["prompt"])
            metadata = row["observation"]["prompt_template"]
            assert (
                metadata["bank"] == "hidden-agenda-rules-v1"
                and metadata["variant"] == wording
            )
            assert (
                metadata["system_sha256"] == hashlib.sha256(system.encode()).hexdigest()
            )
            assert metadata["user_sha256"] == hashlib.sha256(user.encode()).hexdigest()
            event = row["observation"]["applied_order"]
            assert event == orders.pop(
                (row["episode_id"], event["decision"], int(row["seat"]))
            )
            action = {
                key: event[key] for key in ("plan", "vote", "say", "hunch", "notes")
            }
            if event["switch"] is not None:
                action["switch"] = event["switch"]
            assert row["executed_action"] == action
            assert row["attempts"][0]["origin"] == "teacher"
            if variant != "hidden-agenda":
                assert action["say"] == ""
            assert "roles" not in row["observation"]["view"]
            comparable.append(
                (
                    user,
                    row["observation"]["view"],
                    action,
                    system.split("YOU ARE", 1)[1],
                )
            )
        assert not orders
        if reference is None:
            reference = comparable
        else:
            assert comparable == reference
        games += len(episodes)
assert len(families) == 10
print(
    games,
    "complete candidates preserve observations and applied orders across wording;",
    len(families),
    "seed families",
)
