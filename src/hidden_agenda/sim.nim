## The gameplay core: the twelve numbered steps of a play tick, the M1..M6
## meeting ticks, the win check and the episode driver.
##
## Fork of `coworld-ctf/src/ctf/sim.nim`: the tick loop keeps its shape and its
## discipline (seats resolve in ascending slot order, seams in S1..S6 order, all
## reads inside a step use the state as it stood at the start of that step
## unless the step says otherwise) and the CTF gameplay core is replaced by the
## twelve steps below.
##
## The driver is deliberately separate from the websocket server, so the whole
## loop — the one-batch-per-decision-point contract, the play deadline, the
## batch cap and the fallback path — is testable against a fake decider and a
## fake clock with no sockets involved.

import std/[json]
import sim_types, station, sim_config, sim_state, events, vision, kernel,
  meeting

export sim_types, station, sim_config, sim_state, events, vision, kernel,
  meeting

type
  Decider* = proc (sim: var Sim, seats: seq[int], cause: string):
    seq[Decision] {.closure.}
  Clock* = proc (): float {.closure.}

# ---------------------------------------------------------------------------
# Frames
# ---------------------------------------------------------------------------

proc stateCode(sim: Sim, cog: Cog): int =
  case cog.state
  of csFrozen: 3
  of csEjected: 4
  of csActive:
    if sim.inMeeting: 5
    elif cog.lastAction == aMine: 1
    elif cog.lastAction == aDeposit: 2
    else: 0

proc visibilityMask*(sim: Sim, slot: int): int =
  ## Bit `i` = "slot can currently see slot i". A cog never sees itself, so its
  ## own bit is always 0.
  let cog = sim.cogs[slot]
  for other in 0 ..< Seats:
    if seesCog(sim.config, cog, sim.cogs[other]):
      result = result or (1 shl other)

proc recordFrame*(sim: var Sim) =
  var frame = Frame(t: sim.tick, d: sim.deposits, m: ord(sim.meetingPhase))
  for slot in 0 ..< Seats:
    let cog = sim.cogs[slot]
    let base = slot * 6
    frame.c[base + 0] = cog.x
    frame.c[base + 1] = cog.y
    frame.c[base + 2] = ord(cog.facing)
    frame.c[base + 3] = stateCode(sim, cog)
    frame.c[base + 4] = cog.carry
    frame.c[base + 5] = cog.mineProgress
    frame.v[slot] = visibilityMask(sim, slot)
  for seam in sim.seams:
    frame.g.add(seam.gems)
  sim.frames.add(frame)
  sim.recordRace()

# ---------------------------------------------------------------------------
# Memory (step 9)
# ---------------------------------------------------------------------------

proc noteBody(cog: var Cog, other: Cog, t: int) =
  for body in cog.bodies:
    if body.alias == Aliases[other.slot]:
      return
  cog.bodies.add(Body(alias: Aliases[other.slot], cell: [other.x, other.y],
    room: roomOf(other.x, other.y), firstSeenTick: t))

proc updateMemory(sim: var Sim) =
  for slot in 0 ..< Seats:
    if sim.cogs[slot].state != csActive:
      continue
    for other in 0 ..< Seats:
      if other == slot:
        continue
      if not seesCog(sim.config, sim.cogs[slot], sim.cogs[other]):
        continue
      let target = sim.cogs[other]
      sim.cogs[slot].lastSeen[other] = Seen(
        t: sim.tick, cell: [target.x, target.y], doing: doingOf(target),
        room: roomOf(target.x, target.y), valid: true)
      sim.cogs[slot].togetherTicks[other].inc
      if target.state == csFrozen:
        noteBody(sim.cogs[slot], target, sim.tick)
    for index, seam in SeamTable:
      if canSee(sim.config, sim.cogs[slot], seam.x, seam.y):
        var found = false
        for i in 0 ..< sim.cogs[slot].seamsSeen.len:
          if sim.cogs[slot].seamsSeen[i].id == seam.id:
            sim.cogs[slot].seamsSeen[i].gems = sim.seams[index].gems
            sim.cogs[slot].seamsSeen[i].t = sim.tick
            found = true
            break
        if not found:
          sim.cogs[slot].seamsSeen.add(SeamSeen(id: seam.id,
            gems: sim.seams[index].gems, t: sim.tick, valid: true))

# ---------------------------------------------------------------------------
# End conditions
# ---------------------------------------------------------------------------

proc settle*(sim: var Sim, reason, ending, winner: string) =
  if sim.done:
    return
  sim.done = true
  sim.reason = reason
  sim.ending = ending
  sim.winner = winner
  for slot in 0 ..< Seats:
    sim.scores[slot] =
      if winner == "crew":
        if sim.cogs[slot].role == rCrew: 1 else: -4
      elif winner == "impostor":
        if sim.cogs[slot].role == rCrew: -1 else: 4
      else:
        0
  sim.addBeat(sim.tick, "gameover", winner = winner)

proc endEarly*(sim: var Sim) =
  ## The play deadline fired: settle with all scores 0 rather than overrun.
  sim.settle("deadline", "deadline", "none")

proc winCheck(sim: var Sim) =
  if sim.done:
    return
  if sim.deposits >= sim.config.depositTarget:
    sim.settle("complete", "crew_deposits", "crew")
  elif sim.cogs[sim.impostorSlot].state == csEjected:
    sim.settle("complete", "impostor_ejected", "crew")
  elif sim.activeCrew() <= 1:
    sim.settle("complete", "impostor_isolation", "impostor")
  elif sim.tick >= sim.config.maxTicks:
    sim.settle("complete", "timeout", "none")

# ---------------------------------------------------------------------------
# The twelve steps of a play tick
# ---------------------------------------------------------------------------

proc stepTimers(sim: var Sim) =
  for slot in 0 ..< Seats:
    if sim.cogs[slot].moveCooldown > 0:
      sim.cogs[slot].moveCooldown.dec
    if sim.cogs[slot].freezeCooldown > 0:
      sim.cogs[slot].freezeCooldown.dec
  for index in 0 ..< sim.seams.len:
    sim.seams[index].regrow.inc
    if sim.seams[index].regrow >= sim.config.seamRegrowTicks:
      sim.seams[index].regrow = 0
      if sim.seams[index].gems < sim.config.seamCapacity:
        sim.seams[index].gems.inc
        sim.log.seamRegrew(sim.tick, SeamTable[index].id,
          sim.seams[index].gems)

proc witnessSet(sim: Sim, freezer, victim: int,
    snapX, snapY: array[Seats, int],
    snapFacing: array[Seats, Facing]): seq[int] =
  ## Every ACTIVE cog other than the impostor and the victim, evaluated with the
  ## positions and facings AS THEY STOOD AT THE START OF THAT TICK, whose FOV
  ## contains the victim's cell or the impostor's cell.
  for slot in 0 ..< Seats:
    if slot == freezer or slot == victim:
      continue
    if sim.cogs[slot].state != csActive:
      continue
    let sawFreezer = canSee(snapX[slot], snapY[slot], snapFacing[slot],
      snapX[freezer], snapY[freezer], sim.config.visionRadius,
      sim.config.awarenessRadius)
    let sawVictim = canSee(snapX[slot], snapY[slot], snapFacing[slot],
      snapX[victim], snapY[victim], sim.config.visionRadius,
      sim.config.awarenessRadius)
    if sawFreezer or sawVictim:
      result.add(slot)

proc playTick(sim: var Sim) =
  var snapX: array[Seats, int]
  var snapY: array[Seats, int]
  var snapFacing: array[Seats, Facing]
  for slot in 0 ..< Seats:
    snapX[slot] = sim.cogs[slot].x
    snapY[slot] = sim.cogs[slot].y
    snapFacing[slot] = sim.cogs[slot].facing

  # 1. Timers.
  sim.stepTimers()

  # 2. Kernel intent.
  var intents: array[Seats, KernelIntent]
  for slot in 0 ..< Seats:
    if sim.cogs[slot].state != csActive:
      intents[slot] = KernelIntent(action: aWait, facing: sim.cogs[slot].facing)
      continue
    advancePlan(sim, sim.cogs[slot])
    intents[slot] = kernelIntent(sim, slot)
    if intents[slot].action.isMove and sim.cogs[slot].moveCooldown > 0:
      intents[slot].action = aWait

  # 3. Freeze resolves (impostor only, at most one).
  var frozeVictim = -1
  block freezeStep:
    let slot = sim.impostorSlot
    if intents[slot].action != aFreeze:
      break freezeStep
    let victim = freezeTargetOf(sim, slot)
    if not freezeLegal(sim, slot, victim):
      intents[slot].action = aWait
      break freezeStep
    sim.cogs[victim].state = csFrozen
    sim.cogs[victim].mineProgress = 0
    sim.cogs[victim].mineSeam = -1
    sim.cogs[victim].carry = 0
    sim.cogs[slot].freezeCooldown = sim.config.freezeCooldownTicks
    sim.cogs[slot].freezes.inc
    sim.freezes.inc
    frozeVictim = victim
    sim.lastFx.add(FreezeFx(t: sim.tick, fromX: sim.cogs[slot].x,
      fromY: sim.cogs[slot].y, toX: sim.cogs[victim].x,
      toY: sim.cogs[victim].y))

  # 4. Witness check.
  if frozeVictim >= 0:
    let freezer = sim.impostorSlot
    let witnesses = witnessSet(sim, freezer, frozeVictim, snapX, snapY,
      snapFacing)
    var aliases: seq[string]
    for slot in witnesses:
      aliases.add(Aliases[slot])
    sim.log.froze(sim.tick, freezer, Aliases[frozeVictim],
      [sim.cogs[frozeVictim].x, sim.cogs[frozeVictim].y],
      roomName(roomOf(sim.cogs[frozeVictim].x, sim.cogs[frozeVictim].y)),
      aliases)
    sim.addBeat(sim.tick, "freeze", who = Aliases[frozeVictim])
    for slot in witnesses:
      let sawFreezer = canSee(snapX[slot], snapY[slot], snapFacing[slot],
        snapX[freezer], snapY[freezer], sim.config.visionRadius,
        sim.config.awarenessRadius)
      let sawVictim = canSee(snapX[slot], snapY[slot], snapFacing[slot],
        snapX[frozeVictim], snapY[frozeVictim], sim.config.visionRadius,
        sim.config.awarenessRadius)
      sim.log.witnessed(sim.tick, Aliases[slot], Aliases[freezer],
        Aliases[frozeVictim],
        [sim.cogs[frozeVictim].x, sim.cogs[frozeVictim].y],
        sawFreezer, sawVictim)
      sim.cogs[slot].witnessed.add(WitnessNote(t: sim.tick,
        freezer: Aliases[freezer], victim: Aliases[frozeVictim],
        cell: [sim.cogs[frozeVictim].x, sim.cogs[frozeVictim].y],
        sawFreezer: sawFreezer, sawVictim: sawVictim))
    if witnesses.len > 0:
      sim.witnessedFreezes.inc
      sim.log.caught(sim.tick, Aliases[freezer], Aliases[frozeVictim], aliases)
      sim.addBeat(sim.tick, "caught", who = Aliases[freezer])
      sim.meetingArmed = true
      sim.meetingCause = mcWitness

  # 5. Deposits resolve, slot order.
  for slot in 0 ..< Seats:
    if sim.cogs[slot].state != csActive or intents[slot].action != aDeposit:
      continue
    if sim.cogs[slot].carry <= 0 or not isGrate(sim.cogs[slot].x,
        sim.cogs[slot].y):
      continue
    sim.cogs[slot].carry.dec
    if sim.cogs[slot].role == rCrew:
      sim.deposits.inc
      sim.cogs[slot].deposited.inc
      sim.log.deposited(sim.tick, slot, sim.deposits)
      if sim.deposits mod 8 == 0:
        sim.addBeat(sim.tick, "deposit", n = sim.deposits)
    else:
      var seenBy: seq[string]
      for other in 0 ..< Seats:
        if other == slot or sim.cogs[other].state != csActive:
          continue
        if canSee(sim.config, sim.cogs[other], sim.cogs[slot].x,
            sim.cogs[slot].y):
          seenBy.add(Aliases[other])
          sim.cogs[other].sawFake[slot].inc
      sim.cogs[slot].fakeDeposits.inc
      sim.cogs[slot].lastFakeSeenBy = seenBy
      sim.fakeDeposits.inc
      sim.log.fakeDeposited(sim.tick, slot, seenBy)

  # 6. Mining resolves, slot order.
  for slot in 0 ..< Seats:
    if sim.cogs[slot].state != csActive:
      continue
    if intents[slot].action != aMine:
      sim.cogs[slot].mineProgress = 0
      sim.cogs[slot].mineSeam = -1
      continue
    let index = adjacentSeam(sim.cogs[slot].x, sim.cogs[slot].y)
    if index < 0 or sim.seams[index].gems <= 0 or
        sim.cogs[slot].carry >= sim.config.carryCap:
      sim.cogs[slot].mineProgress = 0
      sim.cogs[slot].mineSeam = -1
      continue
    if sim.cogs[slot].mineSeam != index:
      sim.cogs[slot].mineSeam = index
      sim.cogs[slot].mineProgress = 0
    sim.cogs[slot].mineProgress.inc
    if sim.cogs[slot].mineProgress >= sim.config.mineTicks:
      sim.seams[index].gems.dec
      sim.cogs[slot].carry.inc
      sim.cogs[slot].mined.inc
      sim.cogs[slot].mineProgress = 0
      sim.log.mined(sim.tick, slot, SeamTable[index].id, sim.cogs[slot].carry)

  # 7. Moves resolve, slot order, against the LIVE board.
  #
  # A move into a cell a lower-numbered seat has already taken this tick fails
  # and degrades to `wait`. Two refinements keep the station from gridlocking
  # on its one-wide corridors, and neither lets two cogs share a cell:
  #   * the pass repeats until nothing more can move, so a queue walking one
  #     behind another clears in ONE tick whatever order the slots are in;
  #   * two cogs each stepping into the other's cell SWAP - they step past each
  #     other in the corridor. Without this a crewmate carrying gems south and
  #     one walking north wedge the only route between a gallery and the grate
  #     until their next decision point, two hundred ticks later.
  var wantsMove: array[Seats, bool]
  var targetX: array[Seats, int]
  var targetY: array[Seats, int]
  for slot in 0 ..< Seats:
    if sim.cogs[slot].state != csActive or not intents[slot].action.isMove:
      continue
    let (dx, dy) = intents[slot].action.moveDelta()
    targetX[slot] = sim.cogs[slot].x + dx
    targetY[slot] = sim.cogs[slot].y + dy
    if walkable(targetX[slot], targetY[slot]):
      wantsMove[slot] = true
    else:
      intents[slot].action = aWait

  proc settleMove(sim: var Sim, slot: int, intents: var array[Seats,
      KernelIntent]) =
    sim.cogs[slot].x = targetX[slot]
    sim.cogs[slot].y = targetY[slot]
    sim.cogs[slot].facing =
      case intents[slot].action
      of aMoveN: fN
      of aMoveE: fE
      of aMoveS: fS
      else: fW
    sim.cogs[slot].moveCooldown = sim.config.moveCooldown
    sim.cogs[slot].mineProgress = 0
    sim.cogs[slot].mineSeam = -1
    let step = currentStep(sim.cogs[slot])
    if step.job == jkPatrol:
      advancePatrol(sim.cogs[slot], step.room)

  var progress = true
  while progress:
    progress = false
    for slot in 0 ..< Seats:
      if not wantsMove[slot]:
        continue
      var blocked = false
      for other in 0 ..< Seats:
        if other == slot or sim.cogs[other].state != csActive:
          continue
        if sim.cogs[other].x == targetX[slot] and
            sim.cogs[other].y == targetY[slot]:
          blocked = true
          break
      if blocked:
        continue
      ## Two cogs reaching for the SAME free cell: the one standing at the
      ## smaller (row, col) takes it. A slot order would hand every contested
      ## cell to the lowest-numbered seat for the whole episode, which is a
      ## measurable slot bias (tests/test_feasibility.nim gate (f)); position
      ## is the same tie-break the BFS already uses and it favours nobody.
      var yielded = false
      for other in 0 ..< Seats:
        if other == slot or not wantsMove[other]:
          continue
        if targetX[other] != targetX[slot] or targetY[other] != targetY[slot]:
          continue
        if (sim.cogs[other].y, sim.cogs[other].x) <
            (sim.cogs[slot].y, sim.cogs[slot].x):
          yielded = true
          break
      if yielded:
        continue
      wantsMove[slot] = false
      sim.settleMove(slot, intents)
      progress = true

  for a in 0 ..< Seats:
    if not wantsMove[a]:
      continue
    for b in a + 1 ..< Seats:
      if not wantsMove[b]:
        continue
      if targetX[a] == sim.cogs[b].x and targetY[a] == sim.cogs[b].y and
          targetX[b] == sim.cogs[a].x and targetY[b] == sim.cogs[a].y:
        wantsMove[a] = false
        wantsMove[b] = false
        sim.settleMove(a, intents)
        sim.settleMove(b, intents)
        break

  for slot in 0 ..< Seats:
    if wantsMove[slot]:
      intents[slot].action = aWait

  # 8. Facing (non-movers).
  for slot in 0 ..< Seats:
    if sim.cogs[slot].state != csActive:
      continue
    if currentStep(sim.cogs[slot]).job == jkGuard:
      sim.cogs[slot].sweep.inc
    if intents[slot].action.isMove:
      continue
    case intents[slot].action
    of aFaceN: sim.cogs[slot].facing = fN
    of aFaceE: sim.cogs[slot].facing = fE
    of aFaceS: sim.cogs[slot].facing = fS
    of aFaceW: sim.cogs[slot].facing = fW
    else:
      if intents[slot].setFacing:
        sim.cogs[slot].facing = intents[slot].facing

  for slot in 0 ..< Seats:
    sim.cogs[slot].lastAction =
      if sim.cogs[slot].state == csActive: intents[slot].action else: aWait

  # 9. FOV and memory.
  sim.updateMemory()

  # 10. Win check.
  sim.winCheck()

  # 11. Meeting trigger.
  if not sim.done:
    if sim.meetingArmed:
      discard        ## already armed by step 4 with cause "witness"
    else:
      sim.cadence.dec
      if sim.cadence <= 0:
        sim.meetingArmed = true
        sim.meetingCause = mcCadence

# ---------------------------------------------------------------------------
# Meetings (M1..M6)
# ---------------------------------------------------------------------------

proc openMeeting(sim: var Sim) =
  sim.inMeeting = true
  sim.meetingArmed = false
  sim.meetingNumber.inc
  sim.meetingOpenTick = sim.tick
  sim.meetingPhase = mpOpen
  for slot in 0 ..< Seats:
    sim.votes[slot] = ""
    sim.switchIf[slot] = ""
    sim.switchTo[slot] = ""
    sim.says[slot] = ""
    sim.voteSnapshot[slot] = ""
    sim.cogs[slot].mineProgress = 0
    sim.cogs[slot].mineSeam = -1
    if sim.cogs[slot].state != csActive:
      continue
    sim.cogs[slot].savedX = sim.cogs[slot].x
    sim.cogs[slot].savedY = sim.cogs[slot].y
    sim.cogs[slot].savedFacing = sim.cogs[slot].facing
  ## Every seat is CHOSEN before any cog is moved: `meetingSeatFor` reads the
  ## whole board, so teleporting one cog inside the same loop would change the
  ## seat the next cog is given.
  var seats: array[Seats, array[2, int]]
  for slot in 0 ..< Seats:
    if sim.cogs[slot].state == csActive:
      seats[slot] = meetingSeatFor(sim, slot)
  for slot in 0 ..< Seats:
    if sim.cogs[slot].state != csActive:
      continue
    sim.cogs[slot].x = seats[slot][0]
    sim.cogs[slot].y = seats[slot][1]
    sim.cogs[slot].facing =
      facingToward(seats[slot][0], seats[slot][1], GrateCx, GrateCy)
    sim.cogs[slot].lastAction = aWait
  var active, frozen, ejected: seq[string]
  for slot in 0 ..< Seats:
    case sim.cogs[slot].state
    of csActive: active.add(Aliases[slot])
    of csFrozen: frozen.add(Aliases[slot])
    of csEjected: ejected.add(Aliases[slot])
  sim.log.meetingOpened(sim.tick, sim.meetingNumber, $sim.meetingCause,
    active, frozen, ejected)
  sim.addBeat(sim.tick, "meeting", n = sim.meetingNumber)
  sim.meetings.add(MeetingRecord(n: sim.meetingNumber, t: sim.tick,
    cause: sim.meetingCause, outcome: "", ejected: ""))

proc closeMeeting(sim: var Sim) =
  for slot in 0 ..< Seats:
    if sim.cogs[slot].state != csActive:
      continue
    sim.cogs[slot].x = sim.cogs[slot].savedX
    sim.cogs[slot].y = sim.cogs[slot].savedY
    sim.cogs[slot].facing = sim.cogs[slot].savedFacing
  sim.inMeeting = false
  sim.meetingPhase = mpNone
  sim.cadence = sim.config.meetingCadenceTicks

proc currentTally(sim: Sim): Tally =
  var states: array[Seats, CogState]
  for slot in 0 ..< Seats:
    states[slot] = sim.cogs[slot].state
  tallyOf(sim.votes, states)

proc snapshotTally(sim: Sim): Tally =
  var states: array[Seats, CogState]
  for slot in 0 ..< Seats:
    states[slot] = sim.cogs[slot].state
  tallyOf(sim.voteSnapshot, states)

proc resolveMeeting(sim: var Sim) =
  let tally = sim.currentTally()
  let outcome = resolveTally(tally)
  var tallyNode = newJObject()
  for row in tallyJson(tally):
    tallyNode[row[0]] = %row[1]
  if tally.skips > 0:
    tallyNode["skip"] = %tally.skips
  var target: JsonNode = newJNull()
  var wasImpostor = false
  if outcome.outcome == "plurality":
    let slot = aliasIndex(outcome.target)
    target = %outcome.target
    wasImpostor = slot == sim.impostorSlot
    sim.cogs[slot].state = csEjected
    sim.cogs[slot].carry = 0
    sim.ejections.inc
    if wasImpostor:
      sim.ejectedImpostor = true
    else:
      sim.wrongEjections.inc
    sim.addBeat(sim.tick, "eject", who = outcome.target)
  sim.log.ejected(sim.tick, target, tallyNode, outcome.outcome, wasImpostor)
  if sim.meetings.len > 0:
    sim.meetings[^1].outcome = outcome.outcome
    sim.meetings[^1].ejected = outcome.target
  sim.meetingPhase = mpResolved
  sim.winCheck()

proc meetingTick(sim: var Sim) =
  let offset = sim.tick - sim.meetingOpenTick
  let config = sim.config
  if config.chat and config.sayTick >= 1 and offset == config.sayTick:
    for slot in 0 ..< Seats:
      if sim.cogs[slot].state != csActive:
        continue
      if sim.says[slot].len > 0:
        sim.log.said(sim.tick, slot, sim.says[slot])
        if sim.meetings.len > 0:
          sim.meetings[^1].says[slot] = sim.says[slot]
    sim.meetingPhase = mpSaid
  if offset == config.revealTick:
    for slot in 0 ..< Seats:
      if sim.cogs[slot].state != csActive:
        continue
      if sim.votes[slot].len == 0:
        sim.votes[slot] = "skip"
      sim.log.voted(sim.tick, slot, sim.votes[slot], "initial")
      if sim.meetings.len > 0:
        sim.meetings[^1].votes[slot] = sim.votes[slot]
    sim.meetingPhase = mpVoted
  if offset == config.switchTick - 1:
    sim.voteSnapshot = sim.votes
  if offset == config.switchTick:
    ## A SINGLE snapshot of the tally as it stood at switchTick - 1; every
    ## matching seat's vote changes SIMULTANEOUSLY against the same snapshot.
    let snapshot = sim.snapshotTally()
    var changed: array[Seats, bool]
    var updated = sim.votes
    for slot in 0 ..< Seats:
      if sim.cogs[slot].state != csActive or sim.switchIf[slot].len == 0:
        continue
      if not conditionHolds(snapshot, sim.switchIf[slot]):
        continue
      if sim.switchTo[slot] == sim.votes[slot]:
        continue
      updated[slot] = sim.switchTo[slot]
      changed[slot] = true
    sim.votes = updated
    for slot in 0 ..< Seats:
      if not changed[slot]:
        continue
      sim.log.voted(sim.tick, slot, sim.votes[slot], "switch")
      if sim.meetings.len > 0:
        sim.meetings[^1].switched[slot] = sim.votes[slot]
        sim.meetings[^1].votes[slot] = sim.votes[slot]
    sim.meetingPhase = mpSwitched
  if offset == config.resolveTick:
    sim.resolveMeeting()
  if not sim.done and sim.tick >= sim.config.maxTicks:
    sim.settle("complete", "timeout", "none")

# ---------------------------------------------------------------------------
# Step handles for the unit tests. The tick loop below is the only production
# caller; these exist so tests/test_sim.nim and tests/test_meeting.nim can drive
# ONE step at a time against a hand-built board.
# ---------------------------------------------------------------------------

proc playTickForTest*(sim: var Sim) = sim.playTick()
proc meetingTickForTest*(sim: var Sim) = sim.meetingTick()
proc closeMeetingForTest*(sim: var Sim) = sim.closeMeeting()

proc openMeetingForTest*(sim: var Sim, cause = mcCadence) =
  sim.meetingCause = cause
  sim.openMeeting()

# ---------------------------------------------------------------------------
# Decisions
# ---------------------------------------------------------------------------

proc applyDecision*(sim: var Sim, slot: int, decision: Decision,
    inMeeting: bool) =
  sim.cogs[slot].plan = decision.plan
  sim.cogs[slot].planIndex = 0
  sim.cogs[slot].patrolLeg = 0
  sim.cogs[slot].notes = decision.notes
  sim.cogs[slot].lastHunch = decision.hunch
  sim.lastDecisionSource[slot] = decision.source
  if inMeeting:
    sim.votes[slot] =
      if decision.vote.len > 0 and
          (decision.vote == "skip" or sim.isActiveAlias(decision.vote)):
        decision.vote
      else:
        "skip"
    if decision.switchIf.len > 0 and
        (decision.switchIf == "tie" or sim.isActiveAlias(decision.switchIf)) and
        (decision.switchTo == "skip" or sim.isActiveAlias(decision.switchTo)):
      sim.switchIf[slot] = decision.switchIf
      sim.switchTo[slot] = decision.switchTo
    if sim.config.chat:
      sim.says[slot] = decision.say

proc recordOrder*(sim: var Sim, slot: int, decision: Decision) =
  var plan = newJArray()
  for step in decision.plan:
    var node = %*{"job": $step.job}
    if step.at.len > 0: node["at"] = %step.at
    if step.who.len > 0: node["who"] = %step.who
    if step.room.len > 0: node["room"] = %step.room
    plan.add(node)
  sim.log.ordered(sim.tick, slot, sim.decisions, plan,
    (if sim.inMeeting: sim.votes[slot] else: ""),
    sim.switchIf[slot], sim.switchTo[slot],
    (if sim.config.chat and sim.inMeeting: sim.says[slot] else: ""),
    decision.hunch, decision.notes, $decision.source, decision.latencyMs)

proc runDecisionPoint*(sim: var Sim, decide: Decider, cause: string) =
  let seats = sim.activeSeats()
  if seats.len == 0:
    return
  let decisions = decide(sim, seats, cause)
  for index, slot in seats:
    if index >= decisions.len:
      continue
    sim.applyDecision(slot, decisions[index], sim.inMeeting)
  for index, slot in seats:
    if index >= decisions.len:
      continue
    sim.recordOrder(slot, decisions[index])
  sim.decisions.inc

# ---------------------------------------------------------------------------
# Episode driver
# ---------------------------------------------------------------------------

proc startEpisode*(sim: var Sim) =
  sim.tick = 0
  sim.recordFrame()

proc advanceEpisode*(sim: var Sim, now: Clock = nil,
    deadlineSeconds = 0.0, onTick: proc (sim: var Sim) {.closure.} = nil):
    string =
  ## Continue until the next simultaneous decision or the terminal state.
  ## A newly opened meeting pauses before its first tick, so policies observe
  ## the same meeting state as the hosted episode driver.
  if sim.pendingMeetingTick:
    sim.pendingMeetingTick = false
    sim.meetingTick()
    sim.recordFrame()
    if onTick != nil:
      onTick(sim)
    if sim.tick >= sim.config.maxTicks and not sim.done:
      sim.settle("complete", "timeout", "none")
  while not sim.done:
    if now != nil and deadlineSeconds > 0.0 and now() > deadlineSeconds:
      sim.endEarly()
      break
    sim.tick.inc
    if sim.meetingArmed and not sim.inMeeting:
      sim.openMeeting()
      if now != nil and deadlineSeconds > 0.0 and now() > deadlineSeconds:
        sim.endEarly()
        sim.recordFrame()
        break
      sim.pendingMeetingTick = true
      return "meeting"
    elif sim.inMeeting and
        sim.tick - sim.meetingOpenTick >= sim.config.meetingTicks:
      sim.closeMeeting()
    if sim.inMeeting:
      sim.meetingTick()
    else:
      sim.playTick()
    sim.recordFrame()
    if onTick != nil:
      onTick(sim)
    if sim.tick >= sim.config.maxTicks and not sim.done:
      sim.settle("complete", "timeout", "none")

proc runEpisode*(sim: var Sim, decide: Decider, now: Clock = nil,
    deadlineSeconds = 0.0, onTick: proc (sim: var Sim) {.closure.} = nil) =
  ## Drives the episode to an end condition. `decide` is called at most once per
  ## decision point, with every ACTIVE seat in ONE call, so a
  ## simultaneous-decision game can batch them.
  sim.startEpisode()
  sim.runDecisionPoint(decide, "opening")
  while not sim.done:
    let cause = sim.advanceEpisode(now, deadlineSeconds, onTick)
    if cause.len > 0:
      sim.runDecisionPoint(decide, cause)

proc finalise*(sim: var Sim) =
  ## The terminal `end` row, written once the episode has settled.
  if sim.reason.len == 0:
    sim.settle("complete", "timeout", "none")
  var roles: array[Seats, Role]
  for slot in 0 ..< Seats:
    roles[slot] = sim.cogs[slot].role
  sim.log.ended(sim.tick, sim.reason, sim.ending, sim.winner, sim.deposits,
    sim.scores, roles, sim.freezes, sim.witnessedFreezes, sim.ejections,
    sim.meetings.len)

proc resultsJson*(sim: Sim): JsonNode =
  var names = newJArray()
  var aliases = newJArray()
  var roles = newJArray()
  var scores = newJArray()
  var wins = newJArray()
  for slot in 0 ..< Seats:
    names.add(%sim.policyNames[slot])
    aliases.add(%Aliases[slot])
    roles.add(%($sim.cogs[slot].role))
    scores.add(%sim.scores[slot])
    wins.add(%(sim.scores[slot] > 0))
  %*{
    "names": names, "aliases": aliases, "roles": roles,
    "scores": scores, "win": wins, "winner": sim.winner,
    "deposits": sim.deposits, "depositTarget": sim.config.depositTarget,
    "freezes": sim.freezes, "witnessedFreezes": sim.witnessedFreezes,
    "ejections": sim.ejections, "ejectedImpostor": sim.ejectedImpostor,
    "wrongEjections": sim.wrongEjections, "fakeDeposits": sim.fakeDeposits,
    "meetings": sim.meetings.len, "ticks": sim.frames.len,
    "reason": sim.reason, "ending": sim.ending
  }
