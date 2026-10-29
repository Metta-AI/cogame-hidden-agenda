"""Audit actual loopback native artifacts; synthetic receipts establish no teacher labels."""

import argparse
import base64
import hashlib
import json
from collections import Counter
from pathlib import Path

from coworld.decision_trajectory import complete_episodes, read_trajectory_jsonl

CAPTURE_FIELDS = {
    "scenario_family",
    "task_identity",
    "prompt_selection",
    "pre_native_sha256",
    "native_parsed_proposals",
    "native_requests",
    "actual_rendered_prompt_sha256",
    "batch_elapsed_ms",
    "native_execution",
    "capture_errors",
}


def digest_json(value):
    return hashlib.sha256(
        json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()
    ).hexdigest()


def audit(case):
    rows = [
        event.model_dump(mode="json")
        for event in read_trajectory_jsonl(case / "trajectory.jsonl")
    ]
    events = list(read_trajectory_jsonl(case / "trajectory.jsonl"))
    assert (
        len(list(complete_episodes(events))) == 1 and rows[-1]["status"] == "completed"
    )
    replay = json.loads((case / "replay.json").read_text())
    result = json.loads((case / "results.json").read_text())
    assert (
        rows[-1]["outcome"]["scores"] == result["scores"]
        and replay["results"] == result
    )
    calls = json.loads((case / "http.json").read_text())
    by_uuid = {call["UUID"]: call for call in calls}
    joins = []
    statuses = Counter()
    for row in rows[:-1]:
        observation = row["observation"]
        seat = int(row["seat"])
        assert observation["slot"] == seat and observation["canAct"]
        initial = {
            key: value
            for key, value in observation.items()
            if key not in CAPTURE_FIELDS
        }
        assert digest_json(initial) == observation["pre_native_sha256"]
        assert all(
            f"OPERATOR_PRIVATE_SEAT_{other}" not in json.dumps(row)
            for other in range(5)
            if other != seat
        )
        assert all(
            f"PRIVATE_NOTE_{other}" not in json.dumps(row)
            for other in range(5)
            if other != seat
        )
        assert "roles" not in observation and "impostorSlot" not in observation
        order = observation["native_execution"]["installed_order_record"]
        assert order in replay["events"] and order["seat"] == seat
        assert (
            order["decision"] == observation["decision"]
            and order["t"] == observation["tick"]
        )
        assert row["executed_action"] == {
            key: order[key]
            for key in ["plan", "vote", "switch", "say", "hunch", "notes"]
        }
        request_by_attempt = {
            value["attempt_id"]: value for value in observation["native_requests"]
        }
        for attempt in row["attempts"]:
            call = by_uuid[attempt["platform_call_id"]]
            assert call["seat"] == seat and call["status"] == attempt["http_status"]
            request = request_by_attempt[attempt["attempt_id"]]
            assert request["body_b64"] == call["request_b64"]
            assert base64.b64decode(call["request_b64"]).decode() == request["raw_body"]
            assert json.loads(request["raw_body"]) == attempt["request"]
            assert attempt["response_body_b64"] == call["response_b64"]
            assert (
                base64.b64decode(call["response_b64"]).decode()
                == attempt["raw_response"]
            )
            assert attempt["response_complete"] and attempt["response_reader_joined"]
            assert attempt["latency_ms"] is None
            assert attempt["request"]["max_tokens"] == 900
            assert "authorization" not in {key.lower() for key in request["headers"]}
            if row["selected_attempt_id"] == attempt["attempt_id"]:
                assert (
                    attempt["accepted"]
                    and attempt["parsed_action"] == row["executed_action"]
                )
            joins.append(attempt["platform_call_id"])
        statuses[(seat, row["action_status"])] += 1
    assert set(joins) == set(by_uuid) and len(joins) == len(calls)
    assert len({row["observation"]["scenario_family"] for row in rows[:-1]}) == 1
    return {
        "typed_rows": len(rows),
        "complete": 1,
        "HTTP_raw_UUID_joins": len(joins),
        "statuses": {str(key): value for key, value in statuses.items()},
        "privacy_previews_installed_order_replay_source_joins": True,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    root = args.root
    result = {case: audit(root / case) for case in ["fixed-on", "fixed-mixed"]}

    def remove_latency(value):
        if isinstance(value, dict):
            return {
                key: remove_latency(item)
                for key, item in value.items()
                if key != "latencyMs"
            }
        if isinstance(value, list):
            return [remove_latency(item) for item in value]
        return value

    original = json.loads((root / "original-red/replay.json").read_text())
    for case in ["fixed-off", "fixed-on", "fixed-sink"]:
        assert remove_latency(
            json.loads((root / case / "replay.json").read_text())
        ) == remove_latency(original)
    assert not (root / "original-red/trajectory.jsonl").exists()
    assert not (root / "fixed-off/trajectory.jsonl").exists()
    assert (root / "fixed-sink/trajectory.jsonl").read_text() == "EXISTING_PRIVATE_SINK"
    assert (
        "private capture publication failed:"
        in (root / "fixed-sink/game.stdout").read_text()
    )
    result["source_of_call_ids"] = (
        "synthetic local fixture; zero authentic provider receipts/teacher labels"
    )
    result["original_OFF_ON_sink_public_parity_excluding_only_measured_latencyMs"] = (
        True
    )
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
