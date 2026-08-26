## tests/test_baseline.nim — bounded orders / legality.
##
## For every baseline pairing on every variant: every plan is 1..3 steps of jobs
## inside THAT ROLE's enum, every `at` / `who` / `room` names a live seam /
## active alias / real room, every vote is an active alias or skip, every switch
## names active aliases, every per-tick action is one of the twelve vocabulary
## values, and no invariant of the board is ever broken.

import std/[json, monotimes, times]
import support/helpers
import hidden_agenda/[sim_types, station, sim_config, sim_state, kernel, sim]

template check(condition: bool, message: string) =
  ## A TEMPLATE, not a proc: the message is only built when the check fails.
  ## Eagerly concatenating a per-tick label across a 192-episode sweep is a
  ## minute of string building for nothing.
  if not condition:
    echo "FAIL: ", message
    quit(1)

const
  CrewJobs = {jkMine, jkDeposit, jkWatch, jkPatrol, jkGuard, jkHold}
  ImpostorJobs = CrewJobs + {jkHunt, jkStrike, jkLurk}

var slowest = 0.0
var decisions = 0

proc auditDecision(sim: Sim, slot: int, decision: Decision, label: string) =
  let role = sim.cogs[slot].role
  check(decision.plan.len >= 1, label & ": a plan must have at least one step")
  check(decision.plan.len <= sim.config.planSteps,
    label & ": a plan must have at most " & $sim.config.planSteps & " steps")
  for step in decision.plan:
    if role == rCrew:
      check(step.job in CrewJobs,
        label & ": crew emitted the impostor-only job " & $step.job)
    else:
      check(step.job in ImpostorJobs, label & ": unknown job " & $step.job)
    if step.job == jkMine:
      check(seamIndex(step.at) >= 0,
        label & ": mine names a real seam, got '" & step.at & "'")
    if step.job in {jkWatch, jkHunt, jkStrike}:
      check(sim.isActiveAlias(step.who),
        label & ": " & $step.job & " names an ACTIVE alias, got '" &
        step.who & "'")
      check(step.who != Aliases[slot],
        label & ": " & $step.job & " never targets itself")
    if step.job in {jkPatrol, jkLurk}:
      check(roomIndex(step.room) >= 0,
        label & ": " & $step.job & " names a real room, got '" &
        step.room & "'")
  if sim.inMeeting:
    check(decision.vote == "skip" or sim.isActiveAlias(decision.vote),
      label & ": a vote is an active alias or skip, got '" &
      decision.vote & "'")
    if decision.switchIf.len > 0:
      check(decision.switchIf == "tie" or
        sim.isActiveAlias(decision.switchIf),
        label & ": switch.if names an active alias or tie")
      check(decision.switchTo == "skip" or
        sim.isActiveAlias(decision.switchTo),
        label & ": switch.to names an active alias or skip")

proc auditingDecider(kinds: seq[ScriptKind], label: string): Decider =
  proc decide(view: var Sim, seats: seq[int], cause: string):
      seq[Decision] {.closure.} =
    var out2: seq[Decision]
    for seat in seats:
      let started = getMonoTime()
      let decision = scriptedDecision(view, seat, kinds[seat], view.inMeeting)
      let elapsed = (getMonoTime() - started).inMicroseconds.float / 1000.0
      if elapsed > slowest:
        slowest = elapsed
      decisions.inc
      auditDecision(view, seat, decision, label)
      out2.add(decision)
    out2
  decide

proc auditBoard(sim: Sim, label: string) =
  for slot in 0 ..< Seats:
    let cog = sim.cogs[slot]
    check(inBounds(cog.x, cog.y), label & ": a cog left the map")
    check(walkable(cog.x, cog.y),
      label & ": a cog is standing in a wall or a seam")
    check(cog.carry >= 0 and cog.carry <= sim.config.carryCap,
      label & ": carry is 0.." & $sim.config.carryCap)
    check(cog.freezeCooldown >= 0, label & ": a cooldown went negative")
    check(cog.lastAction in {aWait, aMoveN, aMoveE, aMoveS, aMoveW, aMine,
      aDeposit, aFreeze, aFaceN, aFaceE, aFaceS, aFaceW},
      label & ": an action outside the twelve-value vocabulary")
    if cog.state == csActive:
      for other in 0 ..< Seats:
        if other == slot or sim.cogs[other].state != csActive:
          continue
        check(not (sim.cogs[other].x == cog.x and sim.cogs[other].y == cog.y),
          label & ": two active cogs share a cell")
  for seam in sim.seams:
    check(seam.gems >= 0 and seam.gems <= sim.config.seamCapacity,
      label & ": seam gems out of range")
  check(sim.deposits >= 0, label & ": deposits went negative")

warmKernelCaches()

let pairings = [
  (skMiner, skMiner, "miner x miner"),
  (skMiner, skLurker, "miner crew x lurker impostor"),
  (skLurker, skMiner, "lurker crew x miner impostor"),
  (skLurker, skLurker, "lurker x lurker")
]

for variant in AllVariants:
  for seed in 1 .. 16:
    for pairing in pairings:
      var config = baseConfig(seed, variant)
      config.impostorSlot = (seed + 1) mod Seats
      var kinds = uniformKinds(pairing[0])
      kinds[config.impostorSlot] = pairing[1]
      let label = variant & " seed " & $seed & " " & pairing[2]
      var sim = initSim(config)
      proc watchdog(view: var Sim) {.closure.} =
        auditBoard(view, label)
      sim.runEpisode(auditingDecider(kinds, label), nil, 0.0, watchdog)
      sim.finalise()
      auditBoard(sim, label & " (final)")
      check(sim.done, label & ": the episode must settle")
      check(sim.reason in ["complete", "deadline", "forfeit"],
        label & ": reason must be one of the three legal values")
      ## The impostor never freezes on cooldown: consecutive freezes are at
      ## least freezeCooldownTicks apart.
      var previousFreeze = -1
      for row in eventsOfKind(sim, "freeze"):
        let t = row{"t"}.getInt()
        if previousFreeze >= 0:
          check(t - previousFreeze >= config.freezeCooldownTicks,
            label & ": two freezes " & $(t - previousFreeze) &
            " ticks apart, cooldown is " & $config.freezeCooldownTicks)
        previousFreeze = t

check(decisions > 500, "the sweep must have audited a real number of decisions")
check(slowest < 1.0,
  "no baseline decision may take more than 1 ms, worst was " & $slowest & " ms")
echo "test_baseline: ok (", decisions, " decisions, worst ", slowest, " ms)"
