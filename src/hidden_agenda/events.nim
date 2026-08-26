## The event vocabulary: one JSON row per event, in the order they were emitted.
##
## Fork of `coworld-ctf/src/ctf/events.nim` — the same `jsonRow` / `eventsJson`
## shape and the same rule that live emission and playback read byte-identical
## rows, because the replay records these rows once and the viewer only ever
## re-reads them.

import std/json
import sim_types

type
  EventLog* = object
    rows*: seq[JsonNode]

proc add*(log: var EventLog, row: JsonNode) =
  log.rows.add(row)

proc reveal*(log: var EventLog, seat: int, alias, role, policy: string) =
  log.add(%*{"k": "reveal", "t": 0, "seat": seat, "alias": alias,
    "role": role, "policy": policy})

proc seamRegrew*(log: var EventLog, t: int, id: string, gems: int) =
  log.add(%*{"k": "seam", "t": t, "id": id, "gems": gems})

proc mined*(log: var EventLog, t, seat: int, id: string, carry: int) =
  log.add(%*{"k": "mine", "t": t, "seat": seat, "id": id, "carry": carry})

proc deposited*(log: var EventLog, t, seat, total: int) =
  log.add(%*{"k": "deposit", "t": t, "seat": seat, "total": total})

proc fakeDeposited*(log: var EventLog, t, seat: int, seenBy: seq[string]) =
  var seen = newJArray()
  for alias in seenBy:
    seen.add(%alias)
  log.add(%*{"k": "fakedeposit", "t": t, "seat": seat, "seenBy": seen})

proc froze*(log: var EventLog, t, seat: int, victim: string,
    cell: array[2, int], room: string, witnesses: seq[string]) =
  var rows = newJArray()
  for alias in witnesses:
    rows.add(%alias)
  log.add(%*{"k": "freeze", "t": t, "seat": seat, "victim": victim,
    "cell": [cell[0], cell[1]], "room": room, "witnesses": rows})

proc witnessed*(log: var EventLog, t: int, witness, freezer, victim: string,
    cell: array[2, int], sawFreezer, sawVictim: bool) =
  log.add(%*{"k": "witness", "t": t, "witness": witness, "freezer": freezer,
    "victim": victim, "cell": [cell[0], cell[1]],
    "sawFreezer": sawFreezer, "sawVictim": sawVictim})

proc caught*(log: var EventLog, t: int, freezer, victim: string,
    witnesses: seq[string]) =
  var rows = newJArray()
  for alias in witnesses:
    rows.add(%alias)
  log.add(%*{"k": "caught", "t": t, "freezer": freezer, "victim": victim,
    "witnesses": rows})

proc meetingOpened*(log: var EventLog, t, n: int, cause: string,
    active, frozen, ejected: seq[string]) =
  proc aliases(items: seq[string]): JsonNode =
    result = newJArray()
    for alias in items:
      result.add(%alias)
  log.add(%*{"k": "meeting", "t": t, "n": n, "cause": cause,
    "active": aliases(active), "frozen": aliases(frozen),
    "ejected": aliases(ejected)})

proc said*(log: var EventLog, t, seat: int, text: string) =
  log.add(%*{"k": "say", "t": t, "seat": seat, "text": text})

proc voted*(log: var EventLog, t, seat: int, target, phase: string) =
  log.add(%*{"k": "vote", "t": t, "seat": seat, "target": target,
    "phase": phase})

proc ejected*(log: var EventLog, t: int, target: JsonNode, tally: JsonNode,
    outcome: string, wasImpostor: bool) =
  log.add(%*{"k": "eject", "t": t, "target": target, "tally": tally,
    "outcome": outcome, "wasImpostor": wasImpostor})

proc ordered*(log: var EventLog, t, seat, decision: int, plan: JsonNode,
    vote, switchIf, switchTo, say, hunch, notes, source: string,
    latencyMs: int) =
  var switchNode: JsonNode = newJNull()
  if switchIf.len > 0:
    switchNode = %*{"if": switchIf, "to": switchTo}
  log.add(%*{"k": "order", "t": t, "seat": seat, "decision": decision,
    "plan": plan, "vote": vote, "switch": switchNode, "say": say,
    "hunch": hunch, "notes": notes, "source": source,
    "latencyMs": latencyMs})

proc ended*(log: var EventLog, t: int, reason, ending, winner: string,
    deposits: int, scores: array[Seats, int], roles: array[Seats, Role],
    freezes, witnessedFreezes, ejections, meetings: int) =
  var scoreRows = newJArray()
  for score in scores:
    scoreRows.add(%score)
  var roleRows = newJArray()
  for role in roles:
    roleRows.add(%($role))
  log.add(%*{"k": "end", "t": t, "reason": reason, "ending": ending,
    "winner": winner, "deposits": deposits, "scores": scoreRows,
    "roles": roleRows, "freezes": freezes,
    "witnessedFreezes": witnessedFreezes, "ejections": ejections,
    "meetings": meetings})

proc eventsJson*(log: EventLog): JsonNode =
  result = newJArray()
  for row in log.rows:
    result.add(row)
