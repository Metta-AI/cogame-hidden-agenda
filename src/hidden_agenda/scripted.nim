## The two scripted baselines, both role-aware, both fieldable, both league
## fillers: `miner` (the working baseline, and the fallback every failed LLM
## decision lands on) and `lurker` (the foil).
##
## New module, replacing paintbot's `src/ctf/baselines.nim`. A baseline decides
## purely from its OWN observation at each decision point — no shared state and
## no access to anything a policy could not see. Every field either baseline
## emits is inside its declared enum FOR ITS ROLE and for the current active
## roster by construction (`tests/test_baseline.nim`).

import std/[algorithm, strutils, tables]
import sim_types, station, sim_config, sim_state, vision, kernel

type
  ScriptKind* = enum
    skNone = "none", skMiner = "miner", skLurker = "lurker"

proc parseScriptKind*(text: string): ScriptKind =
  case text.strip().toLowerAscii()
  of "1", "true", "yes", "miner": skMiner
  of "lurker", "lurk": skLurker
  else: skNone

# ---------------------------------------------------------------------------
# Shared helpers — all of them read only this seat's own view.
# ---------------------------------------------------------------------------

proc staleness(sim: Sim, cog: Cog, other: int): int =
  if cog.lastSeen[other].valid: sim.tick - cog.lastSeen[other].t
  else: sim.tick + 1

proc rotation(slot, other: int): int =
  ## Every tie-break below is resolved from the SEAT'S OWN slot outward, never
  ## from slot 0. A global slot order turns "the lowest slot is always picked"
  ## into a measurable slot bias in the win rates
  ## (tests/test_feasibility.nim gate (f)).
  ((other - slot) + Seats) mod Seats

proc mostStaleActive(sim: Sim, cog: Cog): int =
  ## The active cog (never this one) with the largest `t - lastSeen[x].t`.
  ##
  ## `t - lastSeen[x].t` is only DEFINED for a cog this seat has actually seen,
  ## and -1 is returned when it has seen none: at tick 0 every seat has seen
  ## nobody, so any tie-break here would hand every seat a fixed neighbour and
  ## wire a five-node watch cycle into the opening of every episode - which is
  ## measurable as a slot bias in the win rates (tests/test_feasibility.nim
  ## gate (f)). A seat with nothing remembered simply does not spend a plan
  ## step watching.
  result = -1
  var best = -1
  for offset in 1 ..< Seats:
    let other = (cog.slot + offset) mod Seats
    if sim.cogs[other].state != csActive or not cog.lastSeen[other].valid:
      continue
    let value = staleness(sim, cog, other)
    if value > best:
      best = value
      result = other

proc seenGems(cog: Cog, id: string): int =
  ## Gems at a seam AS LAST SEEN by this seat; a seam it has never seen is
  ## assumed to hold gems (optimistic, and it is what sends it out to look).
  for entry in cog.seamsSeen:
    if entry.id == id:
      return entry.gems
  1

proc bestSeam(sim: Sim, cog: Cog, skip: int): int =
  ## `walkDistance(me, S) + 40 * (S.gems == 0 as last seen)`, ties by seam id.
  result = -1
  var best = high(int)
  for index, seam in SeamTable:
    if index == skip:
      continue
    let field = seamField(index)
    var score = field.distAt(cog.x, cog.y)
    if score >= Unreachable:
      continue
    if seenGems(cog, seam.id) <= 0:
      score += 40
    if score < best:
      best = score
      result = index
  if result < 0:
    result = 0

proc anyCogInView(sim: Sim, cog: Cog): bool =
  for other in sim.cogs:
    if other.slot == cog.slot or other.state != csActive:
      continue
    if canSee(sim.config, cog, other.x, other.y):
      return true
  false

proc lastMeetingCounts(sim: Sim): Table[string, int] =
  ## Votes cast in the PREVIOUS meeting — the last one that actually resolved.
  ##
  ## `openMeeting` appends the current meeting's record with five empty votes
  ## and `runDecisionPoint` runs immediately afterwards, so `sim.meetings[^1]`
  ## at a decision point is the meeting being voted on right now and is always
  ## empty. Reading it made the impostor's bandwagon vote dead code. Walk back
  ## to the newest record that carries an `outcome`, which is exactly the
  ## previous meeting whether the caller is inside a meeting or not.
  result = initTable[string, int]()
  var index = sim.meetings.high
  while index >= 0 and sim.meetings[index].outcome.len == 0:
    index.dec
  if index < 0:
    return
  for vote in sim.meetings[index].votes:
    if vote.len == 0 or vote == "skip":
      continue
    result[vote] = result.getOrDefault(vote) + 1

proc rankedByVotes(sim: Sim, slot: int): seq[string] =
  let counts = lastMeetingCounts(sim)
  var rows: seq[(int, int, string)]
  for alias, count in counts:
    let index = aliasIndex(alias)
    if index < 0 or index == slot or not sim.isActiveAlias(alias):
      continue
    rows.add((-count, rotation(slot, index), alias))
  rows.sort()
  for row in rows:
    result.add(row[2])

# ---------------------------------------------------------------------------
# Suspicion — the deterministic score the `miner` crew branch votes on.
# ---------------------------------------------------------------------------

proc suspicion*(sim: Sim, cog: Cog, other: int): int =
  let alias = Aliases[other]
  var score = 0
  for note in cog.witnessed:
    if note.freezer == alias and note.sawFreezer:
      score += 20
    elif not note.sawFreezer and note.sawVictim:
      ## "I know it happened here, not who did it": weigh whoever this seat
      ## last placed in that room.
      if cog.lastSeen[other].valid and
          cog.lastSeen[other].room == roomOf(note.cell[0], note.cell[1]):
        score += 8
  score += 6 * cog.sawFake[other]
  if cog.lastSeen[other].valid:
    for body in cog.bodies:
      if body.room.len > 0 and body.room == cog.lastSeen[other].room:
        score += 3
        break
  score += staleness(sim, cog, other) div 100
  score

proc suspects(sim: Sim, cog: Cog): seq[(int, string)] =
  ## Active cogs other than this one, best suspect first.
  ##
  ## Ties are broken on the RAW staleness before anything positional. The
  ## suspicion score's last term is `floor(unseen / 100)`, so two cogs the seat
  ## has not seen for 640 and 690 ticks score identically; falling straight
  ## through to a slot order would make every crew seat name a DIFFERENT cog
  ## (each its own neighbour), scatter the tally and eject nobody, and would
  ## make the ejection rate depend on which slot drew the impostor
  ## (tests/test_feasibility.nim gate (f)). Raw staleness is finer-grained,
  ## seed-dependent and slot-neutral, so the crew converge on the same suspect.
  ## The seat's own slot outward is only the final, deterministic fallback.
  var rows: seq[(int, int, int, string)]
  for other in 0 ..< Seats:
    if other == cog.slot or sim.cogs[other].state != csActive:
      continue
    rows.add((-suspicion(sim, cog, other), -staleness(sim, cog, other),
      rotation(cog.slot, other), Aliases[other]))
  rows.sort()
  for row in rows:
    result.add((row[0], row[3]))

# ---------------------------------------------------------------------------
# miner
# ---------------------------------------------------------------------------

proc minerCrewPlan(sim: Sim, cog: Cog): seq[PlanStep] =
  if cog.carry < sim.config.carryCap:
    let first = bestSeam(sim, cog, -1)
    result.add(PlanStep(job: jkMine, at: SeamTable[first].id))
    result.add(PlanStep(job: jkDeposit))
  else:
    result.add(PlanStep(job: jkDeposit))
    let next = bestSeam(sim, cog, -1)
    result.add(PlanStep(job: jkMine, at: SeamTable[next].id))
  let watch = mostStaleActive(sim, cog)
  if watch >= 0 and result.len < sim.config.planSteps:
    result.add(PlanStep(job: jkWatch, who: Aliases[watch]))

proc minerImpostorPlan(sim: Sim, cog: Cog): seq[PlanStep] =
  let targets = freezeTargets(sim, cog.slot)
  if cog.freezeCooldown == 0 and targets.len > 0 and not anyCogInView(sim, cog):
    result.add(PlanStep(job: jkHunt, who: targets[0]))
    return
  if cog.freezeCooldown == 0:
    let stale = mostStaleActive(sim, cog)
    if stale >= 0:
      let cell = lastKnownCell(cog, stale)
      var room = roomOf(cell[0], cell[1])
      if room.len == 0:
        room = "HUB"
      result.add(PlanStep(job: jkLurk, room: room))
      result.add(PlanStep(job: jkHunt, who: Aliases[stale]))
      return
  let seam = bestSeam(sim, cog, -1)
  result.add(PlanStep(job: jkMine, at: SeamTable[seam].id))
  ## A `deposit` step becomes `guard` whenever any cog was in view at the
  ## moment of planning, so the impostor never fake-deposits to an audience.
  if anyCogInView(sim, cog):
    result.add(PlanStep(job: jkGuard))
  else:
    result.add(PlanStep(job: jkDeposit))

proc minerDecision*(sim: Sim, slot: int, inMeeting: bool): Decision =
  let cog = sim.cogs[slot]
  result.source = dsScripted
  result.plan =
    if cog.role == rImpostor: minerImpostorPlan(sim, cog)
    else: minerCrewPlan(sim, cog)
  if result.plan.len == 0:
    result.plan.add(PlanStep(job: jkHold))
  if result.plan.len > sim.config.planSteps:
    result.plan.setLen(sim.config.planSteps)
  if not inMeeting:
    return
  if cog.role == rImpostor:
    let ranked = rankedByVotes(sim, slot)
    if ranked.len > 0:
      result.vote = ranked[0]
    else:
      let stale = mostStaleActive(sim, cog)
      result.vote = if stale >= 0: Aliases[stale] else: "skip"
    result.switchIf = Aliases[slot]
    result.switchTo = if ranked.len > 1: ranked[1] else: "skip"
    result.hunch = "bandwagon " & result.vote
    result.say = "keeping my head down"
  else:
    let ranked = suspects(sim, cog)
    if ranked.len > 0 and -ranked[0][0] >= 6:
      result.vote = ranked[0][1]
      result.hunch = "susp " & ranked[0][1] & " " & $(-ranked[0][0])
      let stale = aliasIndex(ranked[0][1])
      result.say =
        if stale >= 0:
          ranked[0][1] & " unseen " & $staleness(sim, cog, stale) & " ticks"
        else:
          "nothing solid"
    else:
      result.vote = "skip"
      result.hunch = "nothing solid"
      result.say = "nothing solid"
    result.switchIf = Aliases[slot]
    result.switchTo = if ranked.len > 1: ranked[1][1] else: "skip"
  if result.switchTo != "skip" and not sim.isActiveAlias(result.switchTo):
    result.switchTo = "skip"

# ---------------------------------------------------------------------------
# lurker
# ---------------------------------------------------------------------------

const LurkerSeamTag = "seam="

proc lurkerSeam(sim: Sim, cog: Cog): int =
  ## The ONE seam this head-down crew cog works for the whole episode: the
  ## nearest at tick 0, remembered in its own private notes (the only place a
  ## baseline is allowed to keep anything between decision points).
  let marker = cog.notes
  if marker.startsWith(LurkerSeamTag):
    let index = seamIndex(marker[LurkerSeamTag.len .. ^1])
    if index >= 0:
      return index
  bestSeam(sim, cog, -1)

proc lurkerDecision*(sim: Sim, slot: int, inMeeting: bool): Decision =
  let cog = sim.cogs[slot]
  result.source = dsScripted
  if cog.role == rImpostor:
    ## `strike`: close on the nearest active crew cog and fire the instant the
    ## freeze is legal, witnesses or not. Loud, and caught — deliberately, so
    ## the all-scripted certification replay contains a witnessed freeze and a
    ## CAUGHT! banner.
    var target = -1
    var best = high(int)
    for offset in 1 ..< Seats:
      let other = (slot + offset) mod Seats
      if sim.cogs[other].role != rCrew or
          sim.cogs[other].state != csActive:
        continue
      let cell =
        if canSee(sim.config, cog, sim.cogs[other].x, sim.cogs[other].y):
          [sim.cogs[other].x, sim.cogs[other].y]
        else:
          lastKnownCell(cog, other)
      let d = walkDistance(cog.x, cog.y, cell[0], cell[1])
      if d < best:
        best = d
        target = other
    if target >= 0:
      result.plan.add(PlanStep(job: jkStrike, who: Aliases[target]))
    else:
      result.plan.add(PlanStep(job: jkGuard))
    result.hunch = "striking"
  else:
    let seam = lurkerSeam(sim, cog)
    result.notes = LurkerSeamTag & SeamTable[seam].id
    result.plan.add(PlanStep(job: jkMine, at: SeamTable[seam].id))
    result.plan.add(PlanStep(job: jkDeposit))
    result.hunch = "head down at " & SeamTable[seam].id
  if not inMeeting:
    return
  result.vote = "skip"
  for note in cog.witnessed:
    if note.sawFreezer and sim.isActiveAlias(note.freezer):
      result.vote = note.freezer
      result.hunch = "i saw " & note.freezer
      break
  result.say =
    if result.vote == "skip": "i was mining" else: "i saw " & result.vote

proc scriptedDecision*(sim: Sim, slot: int, kind: ScriptKind,
    inMeeting: bool): Decision =
  case kind
  of skLurker: lurkerDecision(sim, slot, inMeeting)
  else: minerDecision(sim, slot, inMeeting)
