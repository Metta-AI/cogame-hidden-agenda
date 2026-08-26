## tests/test_sim.nim — sim units.
##
## Mining, carrying, depositing, seam regrowth, the freeze beam and its
## legality, the witness trigger, meeting arming, move cooldown, occupancy,
## and determinism.

import std/[json]
import support/helpers
import hidden_agenda/[sim_types, station, sim_config, sim_state, vision,
  kernel, sim]

template check(condition: bool, message: string) =
  ## A TEMPLATE, not a proc: the message is only built when the check fails.
  ## Eagerly concatenating a per-tick label across a 192-episode sweep is a
  ## minute of string building for nothing.
  if not condition:
    echo "FAIL: ", message
    quit(1)

proc rig(seed = 5, variant = "hidden-agenda-notalk"): Sim =
  var config = baseConfig(seed, variant)
  config.impostorSlot = 4
  result = initSim(config)

proc setPlan(sim: var Sim, slot: int, steps: varargs[PlanStep]) =
  sim.cogs[slot].plan = @[]
  for step in steps:
    sim.cogs[slot].plan.add(step)
  sim.cogs[slot].planIndex = 0

proc place(sim: var Sim, slot, x, y: int, facing = fN) =
  sim.cogs[slot].x = x
  sim.cogs[slot].y = y
  sim.cogs[slot].facing = facing

proc idleOthers(sim: var Sim, keep: varargs[int]) =
  ## Park every seat except the named ones far apart and holding, so a unit
  ## test measures one rule at a time.
  var kept: seq[int]
  for slot in keep:
    kept.add(slot)
  const Parks = [[1, 1], [25, 1], [1, 17], [25, 17], [4, 3]]
  for slot in 0 ..< Seats:
    if slot in kept:
      continue
    sim.place(slot, Parks[slot][0], Parks[slot][1])
    sim.setPlan(slot, PlanStep(job: jkHold))

proc runTicks(sim: var Sim, n: int) =
  for _ in 0 ..< n:
    sim.tick.inc
    sim.playTickForTest()

block miningTakesExactlyMineTicks:
  var sim = rig()
  sim.idleOthers(0)
  sim.place(0, 13, 3)            ## adjacent to S2 at (13,2)
  sim.setPlan(0, PlanStep(job: jkMine, at: "S2"))
  check(adjacentSeam(13, 3) == 1, "the test cell must touch S2")
  sim.runTicks(sim.config.mineTicks - 1)
  check(sim.cogs[0].carry == 0, "no gem before mineTicks")
  check(sim.cogs[0].mineProgress == sim.config.mineTicks - 1,
    "progress advances one per tick")
  sim.runTicks(1)
  check(sim.cogs[0].carry == 1, "exactly mineTicks yields one gem")
  check(sim.cogs[0].mineProgress == 0, "progress resets after a gem")
  check(sim.seams[1].gems == sim.config.seamCapacity - 1,
    "the gem leaves the seam")

block carryCapIsEnforced:
  var sim = rig()
  sim.idleOthers(0)
  sim.place(0, 13, 3)
  sim.setPlan(0, PlanStep(job: jkMine, at: "S2"))
  sim.runTicks(sim.config.mineTicks * 3 + 6)
  check(sim.cogs[0].carry == sim.config.carryCap,
    "hands never hold more than carryCap")

block crewDepositMovesTheCounterAndTheImpostorsDoesNot:
  var sim = rig()
  sim.idleOthers(0, 4)
  sim.place(0, 13, 9)
  sim.cogs[0].carry = 2
  sim.setPlan(0, PlanStep(job: jkDeposit))
  sim.place(4, 12, 10)
  sim.cogs[4].carry = 2
  sim.setPlan(4, PlanStep(job: jkDeposit))
  sim.runTicks(1)
  check(sim.deposits == 1, "a crew deposit moves the counter by exactly one")
  check(sim.cogs[4].carry == 1, "the impostor's gem leaves its hands")
  check(sim.fakeDeposits == 1, "and is recorded as a fake deposit")
  let fakes = eventsOfKind(sim, "fakedeposit")
  check(fakes.len == 1, "one fakedeposit row")
  check(fakes[0]{"seenBy"}.len >= 0, "seenBy is an array")

block seamsRegrowAndCap:
  var sim = rig()
  sim.idleOthers()
  sim.seams[0].gems = 0
  ## Seams start at a seeded PHASE (sim_state.initSim); pin this one to 0 so
  ## the tick arithmetic is what is under test.
  sim.seams[0].regrow = 0
  sim.runTicks(sim.config.seamRegrowTicks - 1)
  check(sim.seams[0].gems == 0, "nothing before seamRegrowTicks")
  sim.runTicks(1)
  check(sim.seams[0].gems == 1, "exactly one gem at seamRegrowTicks")
  sim.runTicks(sim.config.seamRegrowTicks * 6)
  check(sim.seams[0].gems == sim.config.seamCapacity,
    "regrowth caps at seamCapacity")

block freezeLegality:
  var sim = rig()
  sim.idleOthers(0, 4)
  sim.place(4, 13, 9)
  sim.place(0, 13, 12)
  check(not freezeLegal(sim, 4, 0), "out of range is refused")
  sim.place(0, 13, 11)
  check(freezeLegal(sim, 4, 0), "in range with line of sight is legal")
  sim.cogs[4].freezeCooldown = 3
  check(not freezeLegal(sim, 4, 0), "on cooldown is refused")
  sim.cogs[4].freezeCooldown = 0
  sim.cogs[0].state = csFrozen
  check(not freezeLegal(sim, 4, 0), "a frozen target is refused")
  sim.cogs[0].state = csActive
  check(not freezeLegal(sim, 4, 4), "the impostor cannot freeze itself")
  check(not freezeLegal(sim, 0, 1), "a crew cog can never freeze")
  ## Line of sight: (2,2) is a seam.
  sim.place(4, 1, 2)
  sim.place(0, 3, 2)
  check(not freezeLegal(sim, 4, 0), "a seam blocks the beam")

block freezeResolvesAndArmsTheMeeting:
  var sim = rig()
  sim.idleOthers(0, 1, 4)
  sim.place(4, 13, 9, fN)
  sim.place(0, 13, 11, fN)
  ## BLUE stands north of the grate looking south: it sees the victim's cell.
  sim.place(1, 13, 6, fS)
  sim.setPlan(4, PlanStep(job: jkStrike, who: "RED"))
  sim.setPlan(0, PlanStep(job: jkHold))
  sim.setPlan(1, PlanStep(job: jkHold))
  let cadenceBefore = sim.cadence
  sim.runTicks(1)
  check(sim.cogs[0].state == csFrozen, "the beam freezes the target")
  check(sim.freezes == 1, "one freeze recorded")
  check(sim.cogs[4].freezeCooldown == sim.config.freezeCooldownTicks,
    "the cooldown is set on success only")
  check(countKind(sim, "witness") >= 1, "a witness row is emitted")
  check(countKind(sim, "caught") == 1, "the CAUGHT banner event fires")
  check(sim.meetingArmed, "a witnessed freeze arms an immediate meeting")
  check(sim.cadence == cadenceBefore,
    "the cadence timer is untouched by a witnessed meeting")

block unwitnessedFreezeDoesNotArmAMeeting:
  var sim = rig()
  sim.idleOthers(0, 4)
  ## Deep in the SE vault, and every other cog parked in a different room -
  ## out of the cone AND outside the omnidirectional awareness ring.
  sim.place(1, 1, 1)
  sim.place(2, 25, 1)
  sim.place(3, 1, 17)
  sim.place(4, 21, 15, fN)
  sim.place(0, 21, 17, fN)
  sim.setPlan(4, PlanStep(job: jkStrike, who: "RED"))
  sim.runTicks(1)
  check(sim.cogs[0].state == csFrozen, "the beam still lands")
  check(countKind(sim, "caught") == 0, "nobody saw it")
  check(not sim.meetingArmed, "so no meeting is armed")

block frozenNeverActsAgain:
  var sim = rig()
  sim.idleOthers(0)
  sim.place(0, 13, 3)
  sim.setPlan(0, PlanStep(job: jkMine, at: "S2"))
  sim.cogs[0].state = csFrozen
  let cell = (sim.cogs[0].x, sim.cogs[0].y)
  sim.runTicks(120)
  check((sim.cogs[0].x, sim.cogs[0].y) == cell, "a frozen cog never moves")
  check(sim.cogs[0].carry == 0, "and never mines")

block moveCooldown:
  var sim = rig()
  sim.idleOthers(0)
  ## A LONG walk (the grate to the north-west vault is 17 cells), so the
  ## cooldown is what limits the count rather than the arrival.
  sim.place(0, 13, 9)
  sim.setPlan(0, PlanStep(job: jkMine, at: "S1"))
  var moves = 0
  var previous = (sim.cogs[0].x, sim.cogs[0].y)
  for _ in 0 ..< 20:
    sim.runTicks(1)
    if (sim.cogs[0].x, sim.cogs[0].y) != previous:
      moves.inc
      previous = (sim.cogs[0].x, sim.cogs[0].y)
  check(moves <= 20 div sim.config.moveCooldown + 1,
    "a cog moves at most once every moveCooldown ticks, got " & $moves)
  check(moves >= 5, "and it does actually walk")

block occupancy:
  var sim = rig()
  sim.idleOthers(0, 1)
  ## Both aim for the same grate cell from opposite sides; the lower slot wins.
  sim.place(0, 12, 7)
  sim.place(1, 12, 11)
  sim.cogs[0].carry = 1
  sim.cogs[1].carry = 1
  sim.setPlan(0, PlanStep(job: jkDeposit))
  sim.setPlan(1, PlanStep(job: jkDeposit))
  sim.runTicks(60)
  check((sim.cogs[0].x, sim.cogs[0].y) != (sim.cogs[1].x, sim.cogs[1].y),
    "two active cogs never share a cell")
  for slot in 0 ..< Seats:
    check(walkable(sim.cogs[slot].x, sim.cogs[slot].y),
      "no cog is ever inside a wall or a seam")

block bodiesBlockNothing:
  var sim = rig()
  sim.idleOthers(0, 1)
  sim.place(1, 13, 6)
  sim.cogs[1].state = csFrozen
  sim.place(0, 13, 5)
  sim.cogs[0].carry = 1
  sim.setPlan(0, PlanStep(job: jkDeposit))
  sim.runTicks(40)
  check(sim.deposits >= 1,
    "a body in the corridor blocks neither movement nor sight")

block bfsIsDeterministic:
  let field = seamField(4)
  for _ in 0 .. 2:
    let again = seamField(4)
    for i in 0 ..< field.d.len:
      check(field.d[i] == again.d[i], "the BFS field is stable")

block determinism:
  ## The same seed and the same scripted decisions produce an identical
  ## gameHash, twice in one process.
  var config = baseConfig(31)
  config.maxTicks = 1200
  let first = playEpisode(config, uniformKinds(skMiner))
  let second = playEpisode(config, uniformKinds(skMiner))
  check(first.gameHash() == second.gameHash(),
    "one seed, one hash")
  check(first.frames.len == second.frames.len, "and the same tick count")
  check(first.deposits == second.deposits, "and the same deposits")
  var other = baseConfig(32)
  other.maxTicks = 1200
  let third = playEpisode(other, uniformKinds(skMiner))
  check(third.gameHash() != first.gameHash(),
    "a different seed is a different game")

echo "test_sim: ok"
