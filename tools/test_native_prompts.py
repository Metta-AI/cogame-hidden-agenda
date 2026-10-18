"""Full published games with five real native players and unavailable inference."""

import hashlib
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAME, PLAYER = (str(Path(arg).resolve()) for arg in sys.argv[1:3])
OUTPUT = Path(sys.argv[3]).resolve()
REVISION = sys.argv[4]
OUTPUT.mkdir(parents=True, exist_ok=False)
manifest = json.loads((ROOT / "coworld_manifest_template.json").read_text())
variants = {entry["id"]: entry["game_config"] for entry in manifest["variants"]}
cases = [(variant, "canonical") for variant in variants]
if "--smoke" not in sys.argv:
    cases += [
        ("hidden-agenda", wording)
        for wording in (
            "plain",
            "numbered",
            "questions",
            "reordered",
            "heldout-briefing",
            "heldout-reference",
            "mixed",
        )
    ]
for variant, wording in cases:
    output = OUTPUT / f"{variant}-{wording}"
    output.mkdir(mode=0o700)
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    # This socket is bound but never listens: native HTTP receives connection refusal.
    with socket.socket() as unavailable:
        unavailable.bind(("127.0.0.1", 0))
        config: dict = {
            **variants[variant],
            "seed": 7,
            "promptVariant": wording,
            "promptSeed": 3,
            "tokens": [f"t{i}" for i in range(5)],
            "players": [{"name": f"native-{i}"} for i in range(5)],
        }
        (output / "config.json").write_text(json.dumps(config))
        env = {
            **os.environ,
            "COGAME_HOST": "127.0.0.1",
            "COGAME_PORT": str(port),
            "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
            "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
            "COGAME_SAVE_REPLAY_URI": (output / "replay.json").as_uri(),
            "HIDDEN_AGENDA_HOST_TRACE": str(output / "host.jsonl"),
            "HIDDEN_AGENDA_ATTEMPT_TRACE_DIR": str(output / "attempts"),
            "HIDDEN_AGENDA_SOURCE_REVISION": REVISION,
            "COWORLD_EPISODE_ID": f"hidden-agenda-{variant}-{wording}",
            "COWORLD_GAME_VERSION": "source-validation",
            "COWORLD_SOURCE_REVISION": REVISION,
            "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{unavailable.getsockname()[1]}",
            "COWORLD_LLM_MODEL": "unavailable/validation",
            "PLAYER_PROMPT": "Private station strategy.",
            "PLAYER_SCRIPTED": "",
        }
        processes, logs = [], []
        try:
            log = (output / "game.log").open("w")
            logs.append(log)
            processes.append(
                subprocess.Popen([GAME], cwd=ROOT, env=env, stdout=log, stderr=log)
            )
            for _ in range(400):
                assert processes[0].poll() is None, (output / "game.log").read_text()
                with socket.socket() as probe:
                    if probe.connect_ex(("127.0.0.1", port)) == 0:
                        break
                time.sleep(0.05)
            else:
                raise AssertionError("game did not start")
            for seat in range(5):
                log = (output / f"player-{seat}.log").open("w")
                logs.append(log)
                player_env = {
                    **env,
                    "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
                }
                processes.append(
                    subprocess.Popen(
                        [PLAYER], cwd=ROOT, env=player_env, stdout=log, stderr=log
                    )
                )
            for process in processes:
                assert process.wait(timeout=800) == 0
            events = [
                json.loads(line)
                for line in (output / "host.jsonl").read_text().splitlines()
            ]
            assert events[0]["source_revision"] == REVISION
            assert events[-1]["event_type"] == "host_completed"
            assert events[-1]["results"]["reason"] == "complete"
            assert (output / "host.jsonl").stat().st_mode & 0o777 == 0o600
            replay = json.loads((output / "replay.json").read_text())
            orders = [event for event in replay["events"] if event["k"] == "order"]
            applied = [
                event["order"]
                for event in events
                if event["event_type"] == "action_applied"
            ]
            assert applied == orders and orders
            observed = {
                (event["decision"], event["seat"]): event
                for event in events
                if event["event_type"] == "decision_observed"
            }
            assert len(observed) == len(orders)
            systems, attempts = {}, {}
            for path in (output / "attempts").glob("*.jsonl"):
                start, finish = [
                    json.loads(line) for line in path.read_text().splitlines()
                ]
                assert path.stat().st_mode & 0o777 == 0o600
                assert (
                    start["source_revision"] == REVISION and start["origin"] == "model"
                )
                assert not finish["accepted"] and finish["normalized_action"] is None
                assert start["attempt_id"] == finish["attempt_id"]
                metadata = start["prompt_template"]
                assert metadata["variant"] == (
                    "questions" if wording == "mixed" else wording
                )
                system, user = (message["content"] for message in start["prompt"])
                seat = start["seat"]
                if seat in systems:
                    assert systems[seat] == system
                systems[seat] = system
                assert start["request"]["body"]["system"] == system
                assert start["request"]["body"]["messages"][0]["content"] == user
                assert (
                    metadata["system_sha256"]
                    == hashlib.sha256(system.encode()).hexdigest()
                )
                assert (
                    metadata["user_sha256"] == hashlib.sha256(user.encode()).hexdigest()
                )
                index = int(start["attempt_id"].rsplit("-", 1)[1])
                assert ("previous reply was invalid" in user) == (index == 1)
                attempts.setdefault((start["decision"], seat), []).append(index)
            assert len(systems) == 5
            for order in orders:
                key = (order["decision"], order["seat"])
                assert key in observed
                if order["source"] == "budget":
                    assert key not in attempts
                else:
                    assert order["source"] == "fallback"
                    assert sorted(attempts.pop(key)) == [0, 1]
            assert not attempts
            assert (
                "Private station strategy." not in (output / "replay.json").read_text()
            )
            print(
                variant,
                wording,
                len(orders),
                "applied orders and actual native retry provenance PASS",
                flush=True,
            )
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
            for log in logs:
                log.close()
