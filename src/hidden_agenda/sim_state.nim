## Sim state: the two seeded RNG sub-streams, spawn placement, the world hash,
## rune-safe text handling, and the `Sim` object every other module reads.
##
## Fork of `coworld-ctf/src/ctf/sim_state.nim`. The one addition that matters is
## the SPLIT RNG: `rngWorld` drives everything observable (spawn rotation, seam
## order, tie-breaks) and `rngRole` draws the impostor and NOTHING else, so
## `worldHash(seed)` is identical whichever slot ends up as the impostor. That
## is what makes the design's "roles seeded" true of the BYTES, not just of the
## prose (`tests/test_noleak.nim` gate (d)).

import std/[strutils, unicode]
import sim_types, station, sim_config, events

type
  Rng* = object
    state*: uint64

  SeamState* = object
    gems*: int
    regrow*: int

  FreezeFx* = object
    t*: int
    fromX*, fromY*, toX*, toY*: int

  Sim* = object
    config*: GameConfig
    rngWorld*: Rng
    rngRole*: Rng
    tick*: int
    cogs*: array[Seats, Cog]
    seams*: array[6, SeamState]
    deposits*: int
    impostorSlot*: int
    policyNames*: array[Seats, string]
    cadence*: int
    meetingArmed*: bool
    meetingCause*: MeetingCause
    meetingNumber*: int
    meetingOpenTick*: int
    meetingPhase*: MeetingPhase
    inMeeting*: bool
    votes*: array[Seats, string]
    switchIf*: array[Seats, string]
    switchTo*: array[Seats, string]
    says*: array[Seats, string]
    voteSnapshot*: array[Seats, string]
    meetings*: seq[MeetingRecord]
    log*: EventLog
    frames*: seq[Frame]
    beats*: seq[Beat]
    raceSeries*: seq[array[3, int]]
    crewSeries*: seq[array[2, int]]
    freezes*: int
    witnessedFreezes*: int
    ejections*: int
    wrongEjections*: int
    ejectedImpostor*: bool
    fakeDeposits*: int
    decisions*: int
    done*: bool
    reason*: string
    ending*: string
    winner*: string
    scores*: array[Seats, int]
    lastFx*: seq[FreezeFx]
    lastDecisionSource*: array[Seats, DecisionSource]

# ---------------------------------------------------------------------------
# RNG — paintbot's seeded stream (splitmix64), integer only.
# ---------------------------------------------------------------------------

proc seededRng*(seed: int): Rng =
  Rng(state: cast[uint64](seed.int64) xor 0x9E3779B97F4A7C15'u64)

proc next*(rng: var Rng): uint64 =
  rng.state = rng.state + 0x9E3779B97F4A7C15'u64
  var z = rng.state
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc rand*(rng: var Rng, bound: int): int =
  ## Uniform in 0 ..< bound.
  if bound <= 1:
    return 0
  int(rng.next() mod uint64(bound))

# ---------------------------------------------------------------------------
# Rune-safe text. NEVER slice a recorded string by byte index: a byte cut puts
# invalid UTF-8 in the replay and only a strict parser finds it (bullwhip,
# 2026-08-22).
# ---------------------------------------------------------------------------

proc cleanText*(text: string, limit: int): string =
  result = text.strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit - 1) & "\u2026"

proc oneLine*(text: string, limit: int): string =
  cleanText(text.replace("\n", " ").replace("\r", " "), limit)

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

proc drawImpostor*(config: GameConfig): int =
  ## The impostor slot, from `rngRole` — a sub-stream used for NOTHING else.
  if config.impostorSlot >= 0:
    return config.impostorSlot
  var rng = seededRng(config.seed xor 0x1DEA5EED)
  rng.rand(Seats)

proc spawnRotation*(seed: int): int =
  ## The spawn list is rotated by `seed mod 5`, so no slot has a fixed cell.
  ((seed mod Seats) + Seats) mod Seats

proc initSim*(config: GameConfig): Sim =
  result.config = config
  result.rngWorld = seededRng(config.seed)
  result.rngRole = seededRng(config.seed xor 0x1DEA5EED)
  result.impostorSlot = drawImpostor(config)
  result.cadence = config.meetingCadenceTicks
  let rotation = spawnRotation(config.seed)
  for slot in 0 ..< Seats:
    let cell = SpawnCells[(slot + rotation) mod Seats]
    var cog = Cog(
      slot: slot,
      role: if slot == result.impostorSlot: rImpostor else: rCrew,
      state: csActive,
      x: cell[0], y: cell[1],
      facing: spawnFacing(cell[0], cell[1]),
      mineSeam: -1,
      planIndex: 0,
      lastAction: aWait
    )
    for other in 0 ..< Seats:
      cog.lastSeen[other] = Seen(t: -1, valid: false)
    result.cogs[slot] = cog
    result.policyNames[slot] =
      if slot < config.players.len and config.players[slot].name.len > 0:
        config.players[slot].name
      else:
        Aliases[slot]
  ## Every seam stands full at tick 0 (the design's 18 gems), but they do NOT
  ## regrow in lockstep: each starts at its own seeded PHASE, drawn from
  ## `rngWorld` in S1..S6 order. Without it the spawn rotation is the only
  ## thing a seed changes, five seeds exhaust the whole space of episodes, and
  ## the slot-bias oracle has five samples wearing sixty-four labels
  ## (tests/test_feasibility.nim gate (f)).
  for i in 0 ..< result.seams.len:
    result.seams[i] = SeamState(
      gems: config.seamCapacity,
      regrow: result.rngWorld.rand(config.seamRegrowTicks))
  result.reason = ""
  result.ending = ""
  result.winner = ""
  ## Five spectator-side role reveals at tick 0. They live in the replay and
  ## in `results`; they are NEVER sent to any seat.
  for slot in 0 ..< Seats:
    result.log.reveal(slot, Aliases[slot], $result.cogs[slot].role,
      result.policyNames[slot])

proc worldHash*(sim: Sim): uint64 =
  ## A digest of everything OBSERVABLE — deliberately excluding roles, so the
  ## hash is identical whichever slot `rngRole` drew.
  var h = 1469598103934665603'u64
  template mix(value: int) =
    h = (h xor uint64(value and 0xFFFF)) * 1099511628211'u64
  mix(sim.tick)
  mix(sim.deposits)
  for cog in sim.cogs:
    mix(cog.x)
    mix(cog.y)
    mix(ord(cog.facing))
    mix(ord(cog.state))
    mix(cog.carry)
    mix(cog.mineProgress)
  for seam in sim.seams:
    mix(seam.gems)
    mix(seam.regrow)
  h

proc gameHash*(sim: Sim): uint64 =
  ## The full state digest, roles included. Determinism tests compare this.
  var h = sim.worldHash()
  h = (h xor uint64(sim.impostorSlot)) * 1099511628211'u64
  h = (h xor uint64(sim.meetings.len)) * 1099511628211'u64
  h = (h xor uint64(sim.freezes)) * 1099511628211'u64
  h

proc activeCrew*(sim: Sim): int =
  for cog in sim.cogs:
    if cog.role == rCrew and cog.state == csActive:
      result.inc

proc activeSeats*(sim: Sim): seq[int] =
  for cog in sim.cogs:
    if cog.state == csActive:
      result.add(cog.slot)

proc activeAliases*(sim: Sim): seq[string] =
  for cog in sim.cogs:
    if cog.state == csActive:
      result.add(Aliases[cog.slot])

proc isActiveAlias*(sim: Sim, alias: string): bool =
  let index = aliasIndex(alias)
  index >= 0 and sim.cogs[index].state == csActive

proc impostorProgress*(sim: Sim): int =
  ## The impostor's race position on the same 0 -> depositTarget axis the crew
  ## climb: three removals is a win, so each removal is a third of the way.
  let removed = 4 - sim.activeCrew()
  (removed * sim.config.depositTarget) div 3

proc addBeat*(sim: var Sim, t: int, kind: string, n = 0, who = "",
    winner = "") =
  sim.beats.add(Beat(t: t, kind: kind, n: n, who: who, winner: winner))

proc recordRace*(sim: var Sim) =
  let row = [sim.tick, sim.deposits, sim.impostorProgress()]
  if sim.raceSeries.len == 0 or
      sim.raceSeries[^1][1] != row[1] or sim.raceSeries[^1][2] != row[2]:
    sim.raceSeries.add(row)
  let crewRow = [sim.tick, sim.activeCrew()]
  if sim.crewSeries.len == 0 or sim.crewSeries[^1][1] != crewRow[1]:
    sim.crewSeries.add(crewRow)
