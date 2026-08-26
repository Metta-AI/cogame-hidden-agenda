## Shared test helpers. Lives under tests/support/ so the `tests/*.nim` glob CI
## runs never executes it as a test program of its own.

import std/[json]
import hidden_agenda/[sim, scripted, replays]

export sim, scripted, replays

proc baseConfig*(seed: int, variant = "hidden-agenda-notalk"): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.variant = variant
  result.tokens = @["t0", "t1", "t2", "t3", "t4"]
  result.players = @[]
  for alias in Aliases:
    result.players.add(PlayerConfig(name: alias))
  result.minBatchSeconds = 0
  case variant
  of "hidden-agenda":
    result.chat = true
    result.meetingTicks = 60
    result.sayTick = 10
    result.revealTick = 24
    result.switchTick = 46
    result.resolveTick = 56
  of "hidden-agenda-blind":
    result.chat = false
    result.meetingTicks = 25
    result.sayTick = -1
    result.revealTick = 5
    result.switchTick = 18
    result.resolveTick = 23
    result.visionRadius = 5
    result.freezeCooldownTicks = 120
  else:
    result.chat = false
    result.meetingTicks = 25
    result.sayTick = -1
    result.revealTick = 5
    result.switchTick = 18
    result.resolveTick = 23
  result.validate()

const AllVariants* = ["hidden-agenda", "hidden-agenda-notalk",
  "hidden-agenda-blind"]

proc scriptedDecider*(kinds: seq[ScriptKind]): Decider =
  ## A decider that plays every seat on its declared baseline. No sockets, no
  ## clock, no network: this is what makes the whole loop testable.
  proc decide(view: var Sim, seats: seq[int], cause: string):
      seq[Decision] {.closure.} =
    var decisions: seq[Decision]
    for seat in seats:
      var kind = if seat < kinds.len: kinds[seat] else: skMiner
      if kind == skNone:
        kind = skMiner
      decisions.add(scriptedDecision(view, seat, kind, view.inMeeting))
    decisions
  decide

proc uniformKinds*(kind: ScriptKind): seq[ScriptKind] =
  for _ in 0 ..< Seats:
    result.add(kind)

proc playEpisode*(config: GameConfig, kinds: seq[ScriptKind]): Sim =
  result = initSim(config)
  result.runEpisode(scriptedDecider(kinds))
  result.finalise()

proc playAll*(seed: int, variant: string, crew, impostor: ScriptKind,
    impostorSlot = 4): Sim =
  var config = baseConfig(seed, variant)
  config.impostorSlot = impostorSlot
  var kinds = uniformKinds(crew)
  kinds[impostorSlot] = impostor
  playEpisode(config, kinds)

proc eventsOfKind*(sim: Sim, kind: string): seq[JsonNode] =
  for row in sim.log.rows:
    if row{"k"}.getStr() == kind:
      result.add(row)

proc countKind*(sim: Sim, kind: string): int =
  eventsOfKind(sim, kind).len
