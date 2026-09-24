"""Join captured System One calls to Hidden Agenda replay orders."""

import argparse
import json
import os
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("traces", type=Path)
parser.add_argument("replay", type=Path)
parser.add_argument("--seat", type=int, default=0)
parser.add_argument("--episodes-output", type=Path)
args = parser.parse_args()

requests = {}
responses = {}
with args.traces.open() as stream:
    for line_number, line in enumerate(stream, 1):
        event = json.loads(line)
        assert event["kind"] in ("request", "response"), line_number
        target = requests if event["kind"] == "request" else responses
        assert event["trace_id"] not in target, line_number
        target[event["trace_id"]] = event
assert requests.keys() == responses.keys()
assert requests, "No captured System One requests"

replay = json.loads(args.replay.read_text())
orders = {
    event["decision"]: event
    for event in replay["events"]
    if event["k"] == "order"
    and event["seat"] == args.seat
    and event["source"] == "external"
}

matched = set()
trajectories = set()
input_tokens = 0
output_tokens = 0
cost_usd = 0.0
latencies = []
reported_disagreements = 0
candidate_decisions = []
for trace_id, start in requests.items():
    end = responses[trace_id]
    assert end["status"] == 200, trace_id
    trajectories.add(start["trajectory_id"])
    request = start["request"]
    state = json.loads(request["state"].split("\n", 1)[1])
    assert state["slot"] == args.seat, trace_id
    assert "impostorSlot" not in state and "seed" not in state, trace_id
    decision = state["decision"]
    assert decision in orders and decision not in matched, decision
    matched.add(decision)

    answer = json.loads(end["body"])["answers"]["decision"]
    usage = json.loads(end["body"])["usage"]
    criteria = request["questions"]["decision"]["criteria"]
    probabilities = answer["probabilities"]
    assert answer["type"] == "choice"
    assert answer["choice"] in criteria
    assert criteria.keys() == probabilities.keys()
    assert 0 <= answer["confidence"] <= 1
    assert all(0 <= value <= 1 for value in probabilities.values())
    assert abs(sum(probabilities.values()) - 1) <= len(criteria) * 0.005 + 1e-6
    choice = max(probabilities, key=probabilities.get)
    reported_disagreements += choice != answer["choice"]

    action = json.loads(criteria[choice])
    order = orders[decision]
    assert order["plan"] == action["plan"], decision
    assert order["vote"] == action["vote"], decision

    if choice == answer["choice"]:
        candidate_decisions.append((decision, trace_id, action))

    input_tokens += usage["input_tokens"]
    output_tokens += usage["output_tokens"]
    cost_usd += usage["cost"]
    latencies.append(end["latency_ms"])

assert matched == orders.keys()
assert len(trajectories) == 1
if args.episodes_output is not None:
    assert replay["results"]["reason"] == "complete"
    episode_id = args.replay.parent.name
    episode = {
        "episode": {
            "episode_id": episode_id,
            "game": "hidden-agenda",
            "status": "completed",
            "outcome": replay["results"],
        },
        "decisions": [
            {
                "episode_id": episode_id,
                "decision_id": f"{episode_id}:{game_decision}",
                "decision_index": index,
                "game": "hidden-agenda",
                "attempts": [{
                    "attempt_id": trace_id,
                    "platform_call_id": trace_id,
                    "origin": "model",
                    "parsed_action": action,
                    "accepted": True,
                }],
                "selected_attempt_id": trace_id,
                "executed_action": action,
                "action_status": "accepted",
            }
            for index, (game_decision, trace_id, action)
            in enumerate(sorted(candidate_decisions))
        ],
    }
    descriptor = os.open(args.episodes_output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        stream.write(json.dumps(episode) + "\n")
print(json.dumps({
    "matched_orders": len(matched),
    "input_tokens": input_tokens,
    "output_tokens": output_tokens,
    "cost_usd": round(cost_usd, 9),
    "mean_provider_latency_ms": round(sum(latencies) / len(latencies), 1),
    "reported_choice_disagreements": reported_disagreements,
    "review_candidates": len(candidate_decisions),
}))
