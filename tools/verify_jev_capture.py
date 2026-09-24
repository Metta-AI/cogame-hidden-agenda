"""Join captured System One calls to Hidden Agenda replay orders."""

import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("traces", type=Path)
parser.add_argument("replay", type=Path)
parser.add_argument("--seat", type=int, default=0)
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
    and event["source"] in ("jev", "retry")
}

matched = set()
input_tokens = 0
output_tokens = 0
cost_usd = 0.0
latencies = []
reported_disagreements = 0
for trace_id, start in requests.items():
    end = responses[trace_id]
    assert end["status"] == 200, trace_id
    request = start["request"]
    state = json.loads(request["state"])
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

    description = criteria[choice]
    assert description.startswith("Plan ")
    plan, offset = json.JSONDecoder().raw_decode(description[5:])
    order = orders[decision]
    assert order["plan"] == plan, decision
    clauses = description[5 + offset :].split("; ")[1:]
    fields = {}
    for clause in clauses:
        for prefix in ("vote ", "conditional vote ", "say: ",
                       "private notes: "):
            if clause.startswith(prefix):
                fields[prefix.rstrip(" :")] = clause[len(prefix):]
                break
        else:
            raise ValueError(f"Unknown choice clause: {clause}")
    if "vote" in fields:
        assert order["vote"] == fields["vote"], decision
    else:
        assert order["vote"] == "", decision
    if "conditional vote" in fields:
        condition, target = fields["conditional vote"].split(" -> ")
        assert order["switch"] == {"if": condition, "to": target}, decision
    else:
        assert order["switch"] is None, decision
    if "say" in fields:
        assert order["say"] == fields["say"], decision
    else:
        assert order["say"] == "", decision
    if "private notes" in fields:
        assert order["notes"] == fields["private notes"], decision
    else:
        assert order["notes"] == "", decision

    input_tokens += usage["input_tokens"]
    output_tokens += usage["output_tokens"]
    cost_usd += usage["cost"]
    latencies.append(end["latency_ms"])

assert matched == orders.keys()
print(json.dumps({
    "matched_orders": len(matched),
    "input_tokens": input_tokens,
    "output_tokens": output_tokens,
    "cost_usd": round(cost_usd, 9),
    "mean_provider_latency_ms": round(sum(latencies) / len(latencies), 1),
    "reported_choice_disagreements": reported_disagreements,
}))
