## Persistent numeric decision bridge over the native Hidden Agenda simulator.

import std/[json, os]
import hidden_agenda/[sim, scripted, llm]

const Variants = ["hidden-agenda", "hidden-agenda-notalk", "hidden-agenda-blind"]

var
  game: Sim
  seats: seq[int]
  cursor: int
  decisionId: int
  cause: string
  actions: array[Seats, JsonNode]
  variant: string

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc voteChoices(seat: int): JsonNode =
  result = %*["skip"]
  for other in 0 ..< Seats:
    result.add(if game.inMeeting and other != seat and
      game.cogs[other].state == csActive: %Aliases[other] else: newJNull())

proc heads(seat: int): JsonNode =
  %*[
    {"name": "strategy", "choices": ["miner", "lurker"]},
    {"name": "vote", "choices": voteChoices(seat)}
  ]

proc currentDecision(): JsonNode =
  let seat = seats[cursor]
  let system = systemPrompt(game, seat)
  let user = userPrompt(game, seat, "", cause)
  var properties = newJObject()
  for head in heads(seat):
    var legal = newJArray()
    for choice in head["choices"]:
      if choice.kind != JNull: legal.add(choice)
    properties[head["name"].getStr()] = %*{"enum": legal}
  %*{"kind": "decision", "game": "hidden-agenda",
    "decision_id": decisionId, "seat": seat, "engine_seat": seat,
    "turn": game.tick, "semantic_view": {"system": system, "user": user},
    "inbox": [], "messages": [
      {"role": "system", "content": system},
      {"role": "user", "content": user}],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": properties,
      "required": ["strategy", "vote"]}, "typed_question": newJNull()}

proc encoding(): JsonNode =
  let seat = seats[cursor]
  let cog = game.cogs[seat]
  var values = newJArray()
  for name in Variants:
    values.add(%(if variant == name: 1 else: 0))
  for other in 0 ..< Seats:
    values.add(%(if other == seat: 1 else: 0))
  values.add(%(if cog.role == rImpostor: 1 else: 0))
  values.add(%(if game.inMeeting: 1 else: 0))
  values.add(%(float(game.tick) / float(game.config.maxTicks)))
  values.add(%(float(game.deposits) / float(game.config.depositTarget)))
  values.add(%(float(cog.x) / float(MapCols)))
  values.add(%(float(cog.y) / float(MapRows)))
  for facing in Facing:
    values.add(%(if cog.facing == facing: 1 else: 0))
  values.add(%(float(cog.carry) / float(game.config.carryCap)))
  values.add(%(float(cog.freezeCooldown) /
    float(game.config.freezeCooldownTicks)))
  for other in 0 ..< Seats:
    let target = game.cogs[other]
    for state in CogState:
      values.add(%(if target.state == state: 1 else: 0))
    let seen = cog.lastSeen[other]
    values.add(%(if seen.valid: 1 else: 0))
    values.add(%(if seen.valid: float(game.tick - seen.t) /
      float(game.config.maxTicks) else: 1.0))
    values.add(%(if seen.valid: float(seen.cell[0]) /
      float(MapCols) else: 0.0))
    values.add(%(if seen.valid: float(seen.cell[1]) /
      float(MapRows) else: 0.0))
    values.add(%(float(cog.sawFake[other]) / 4.0))
  for seam in SeamTable:
    var gems = -1
    var age = game.config.maxTicks
    for seen in cog.seamsSeen:
      if seen.id == seam.id:
        gems = seen.gems
        age = game.tick - seen.t
    values.add(%(float(gems) / float(game.config.seamCapacity)))
    values.add(%(float(age) / float(game.config.maxTicks)))
  values.add(%(float(cog.bodies.len) / float(Seats - 1)))
  values.add(%(float(cog.witnessed.len) / float(Seats - 1)))
  doAssert values.len == 74
  %*{"decision_id": decisionId, "values": values,
    "action_heads": heads(seat)}

proc reset(request: JsonNode, manifestPath: string): JsonNode =
  doAssert request["players"].getInt() == Seats
  let manifest = parseFile(manifestPath)
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  variantConfig["seed"] = %seedOf(request["seed"].getStr())
  var config = defaultGameConfig()
  config.update($variantConfig)
  game = initSim(config)
  game.startEpisode()
  seats = game.activeSeats()
  cursor = 0
  decisionId = 0
  cause = "opening"
  currentDecision()

proc teacher(): JsonNode =
  let seat = seats[cursor]
  let chosen = scriptedDecision(game, seat, skMiner, game.inMeeting)
  %*{"response": $(%*{"strategy": "miner",
    "vote": (if game.inMeeting and chosen.vote.len > 0:
      chosen.vote else: "skip")})}

proc step(request: JsonNode): JsonNode =
  doAssert request["decision_id"].getInt() == decisionId
  let action = parseJson(request["response"].getStr())
  for head in heads(seats[cursor]):
    let name = head["name"].getStr()
    doAssert action[name] in head["choices"], "action is masked: " & name
  actions[seats[cursor]] = action
  inc cursor
  inc decisionId
  if cursor == seats.len:
    proc decide(view: var Sim, active: seq[int], at: string):
        seq[Decision] {.closure.} =
      doAssert active == seats and at == cause
      for seat in active:
        let action = actions[seat]
        let kind = if action["strategy"].getStr() == "miner":
          skMiner else: skLurker
        var decision = scriptedDecision(view, seat, kind, view.inMeeting)
        if view.inMeeting:
          decision.vote = action["vote"].getStr()
        result.add(decision)
    game.runDecisionPoint(decide, cause)
    cause = game.advanceEpisode()
    seats = game.activeSeats()
    cursor = 0
  let observation = if game.done:
    var scores = newJObject()
    var utilities = newJObject()
    for seat in 0 ..< Seats:
      scores[$seat] = %game.scores[seat]
      utilities[$seat] = %(float(game.scores[seat]) / 4.0)
    %*{"kind": "terminal", "scores": scores,
      "utilities": utilities}
  else: currentDecision()
  %*{"kind": "accepted", "action": action,
    "observation": observation}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2:
    quit("usage: hidden-agenda-train-bridge MANIFEST VARIANT", 1)
  let manifestPath = absolutePath(args[0])
  variant = args[1]
  doAssert variant in Variants
  for line in stdin.lines:
    let request = parseJson(line)
    let response = case request["kind"].getStr()
      of "reset": reset(request, manifestPath)
      of "encode": encoding()
      of "teacher": teacher()
      of "step": step(request)
      else: raise newException(ValueError, "unknown command")
    stdout.writeLine($response)
    stdout.flushFile()
