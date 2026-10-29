## Re-simulate a local native fixture from its installed orders using production rules.
## This checks realized transitions, not the quality or authenticity of a teacher.
import std/[json, os, strutils, tables]
import hidden_agenda/[sim, llm, replays]

let root = paramStr(1)
let supplied = parseJson(readFile(root / "config.json"))
var config = defaultGameConfig()
config.update($supplied)
# Component clocks are accepted by the actual production parser. The public
# replay deliberately omits these clocks, so do not infer them from that file.
for pair in [("llmTimeoutSeconds", config.llmTimeoutSeconds),
    ("minBatchSeconds", config.minBatchSeconds),
    ("maxDecisionBatches", config.maxDecisionBatches),
    ("episodeTimeoutSeconds", config.episodeTimeoutSeconds),
    ("playerConnectTimeoutSeconds", config.playerConnectTimeoutSeconds),
    ("shutdownGraceSeconds", config.shutdownGraceSeconds)]:
  if supplied.hasKey(pair[0]):
    doAssert supplied[pair[0]].getInt() == pair[1], pair[0]
let original = parseJson(readFile(root / "replay.json"))
var orders = initTable[string, JsonNode]()
for event in original["events"]:
  if event["k"].getStr() == "order":
    let seat = event["seat"].getInt()
    doAssert seat >= 0 and seat < Seats
    let key = $event["decision"].getInt() & ":" & $seat
    doAssert key notin orders
    orders[key] = event
var consumed = 0
var previous: array[Seats, Decision]
var hasPrevious: array[Seats, bool]
proc decide(view: var Sim, seats: seq[int], cause: string): seq[Decision] =
  for seat in seats:
    let key = $view.decisions & ":" & $seat
    doAssert key in orders, key
    let order = orders[key]
    doAssert order["t"].getInt() == view.tick
    let source = parseEnum[DecisionSource](order["source"].getStr())
    var decision: Decision
    if source == dsBudget:
      doAssert hasPrevious[seat]
      decision = previous[seat]
    else:
      decision = view.parseReply(seat, order)
      previous[seat] = decision
      hasPrevious[seat] = true
    decision.source = source
    decision.latencyMs = order["latencyMs"].getInt()
    result.add(decision)
    inc consumed
var reproduced = initSim(config)
reproduced.runEpisode(decide)
reproduced.finalise()
let replay = parseJson(replayBytes(reproduced))
doAssert consumed == orders.len
for key in ["frames", "events", "results", "series", "beats", "roles", "config"]:
  doAssert replay[key] == original[key], "native replay mismatch: " & key
doAssert original["results"] == parseJson(readFile(root / "results.json"))
echo "PASS source-native parser/clocks/orders/frames/events/results: ", consumed, " orders"
