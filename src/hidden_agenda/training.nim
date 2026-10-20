## Normalized complete replies shared by native training interfaces.
import std/json
import sim_types

proc decisionAction*(decision: Decision, chat: bool): JsonNode =
  var plan = newJArray()
  for step in decision.plan:
    var order = %*{"job": $step.job}
    if step.at.len > 0: order["at"] = %step.at
    if step.who.len > 0: order["who"] = %step.who
    if step.room.len > 0: order["room"] = %step.room
    plan.add(order)
  result = %*{
    "plan": plan, "vote": decision.vote,
    "say": (if chat: decision.say else: ""),
    "hunch": decision.hunch, "notes": decision.notes
  }
  if decision.switchIf.len > 0:
    result["switch"] = %*{"if": decision.switchIf,
      "to": decision.switchTo}

