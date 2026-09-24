"""Exercise complete Hidden Agenda games through the numeric bridge."""

import json
import random
import subprocess
import sys
from pathlib import Path


manifest = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"
for variant in ("hidden-agenda", "hidden-agenda-notalk", "hidden-agenda-blind"):
    for policy in ("teacher", "random"):
        with subprocess.Popen(
            [sys.argv[1], str(manifest), variant],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        ) as bridge:
            assert bridge.stdin is not None and bridge.stdout is not None

            def request(payload):
                bridge.stdin.write(json.dumps(payload) + "\n")
                bridge.stdin.flush()
                return json.loads(bridge.stdout.readline())

            observation = request({"kind": "reset", "seed": f"{variant}-{policy}", "players": 5})
            rng = random.Random(42)
            decisions = 0
            while observation["kind"] == "decision":
                assert observation["messages"][0]["content"].startswith("You are ")
                assert "LAST SEEN" in observation["messages"][1]["content"]
                encoded = request({"kind": "encode"})
                assert encoded["decision_id"] == observation["decision_id"]
                assert len(encoded["values"]) == 74
                assert [len(head["choices"]) for head in encoded["action_heads"]] == [2, 6]
                if policy == "teacher":
                    action = json.loads(request({"kind": "teacher"})["response"])
                else:
                    action = {
                        head["name"]: rng.choice([value for value in head["choices"] if value is not None])
                        for head in encoded["action_heads"]
                    }
                assert all(action[head["name"]] in head["choices"] for head in encoded["action_heads"])
                result = request(
                    {"kind": "step", "decision_id": observation["decision_id"], "response": json.dumps(action)}
                )
                assert result["kind"] == "accepted" and result["action"] == action
                observation = result["observation"]
                decisions += 1
            assert 5 <= decisions <= 50
            assert set(observation["scores"]) == {"0", "1", "2", "3", "4"}
            assert sorted(observation["scores"].values()) in ([0] * 5, [-4, 1, 1, 1, 1], [-1, -1, -1, -1, 4])
            bridge.stdin.close()
            assert bridge.wait() == 0
        print(f"{variant} {policy}: {decisions} decisions, 74 values")
