## The kernel: the deterministic machine that turns a plan of up to three jobs
## into the per-tick grid actions.
##
## New module. No LLM authors 3000 ticks of movement: at each decision point a
## seat submits a plan, and this walks it. Steps run in order; when a step
## completes the next begins; when the plan is exhausted the LAST step repeats
## until the next decision point.
##
## BFS is over walkable cells only, neighbours expand N, E, S, W, other cogs are
## not obstacles for path PLANNING (only for the move itself), and ties between
## equidistant targets break by (row, col) ascending — so a path is unique and
## deterministic (`station.distFrom` / `station.stepToward`).

import std/[algorithm, tables]
import sim_types, station, sim_config, sim_state, vision

var watchFieldCache = initTable[int, DistField]()

proc watchField(targetX, targetY: int): DistField =
  ## Distance to the ring of cells 3..5 walk-steps from a target cell,
  ## memoised: there are only 249 possible targets and the kernels ask for the
  ## same handful every tick.
  let key = cellIndex(targetX, targetY)
  if watchFieldCache.hasKey(key):
    return watchFieldCache[key]
  let toTarget = cellField(targetX, targetY)
  var ring: seq[array[2, int]]
  var fallback: seq[array[2, int]]
  for cell in walkableCells():
    let d = toTarget.distAt(cell[0], cell[1])
    if d >= 3 and d <= 5:
      fallback.add(cell)
      ## Never park on a doorway or in a one-wide corridor: a watcher that
      ## waits there wedges everybody behind it (station.isChokepoint).
      if not isChokepoint(cell[0], cell[1]):
        ring.add(cell)
  if ring.len == 0:
    ring = fallback
  if ring.len == 0:
    ring.add([targetX, targetY])
  let field = distFrom(ring)
  watchFieldCache[key] = field
  field

type
  KernelIntent* = object
    action*: Action
    facing*: Facing
    setFacing*: bool

proc warmKernelCaches*() =
  ## Populates every memoised distance field up front. The fields are pure
  ## functions of the one authored map, so this is a warm-up and never a
  ## behaviour change; tests time a decision AFTER it so the first call is not
  ## charged the whole map's BFS.
  discard grateField()
  for index in 0 ..< SeamTable.len:
    discard seamField(index)
  for index in 0 ..< RoomTable.len:
    discard roomCorners(index)
    discard roomFarCorner(index)
  for cell in walkableCells():
    discard cellField(cell[0], cell[1])
    discard watchField(cell[0], cell[1])

proc lastKnownCell*(cog: Cog, other: int): array[2, int] =
  if cog.lastSeen[other].valid:
    cog.lastSeen[other].cell
  else:
    [GrateCx, GrateCy]

proc currentStep*(cog: Cog): PlanStep =
  if cog.plan.len == 0:
    return PlanStep(job: jkHold)
  cog.plan[min(cog.planIndex, cog.plan.high)]

proc stepComplete(sim: Sim, cog: Cog, step: PlanStep): bool =
  ## Only `mine` and `deposit` ever complete; every other job runs until the
  ## next decision point.
  case step.job
  of jkMine:
    let index = seamIndex(step.at)
    if index < 0:
      return true
    if cog.carry >= sim.config.carryCap:
      return true
    ## "If the seam is empty on arrival, the step completes immediately."
    let field = seamField(index)
    if field.distAt(cog.x, cog.y) == 0 and sim.seams[index].gems <= 0:
      return true
    false
  of jkDeposit:
    cog.carry <= 0
  of jkLurk:
    ## "Waits for a lone crewmate to walk in": the step completes the moment
    ## one does, so the plan's next step - normally `hunt` - takes over.
    ## Without this the lurker waits in its corner forever and a plan of
    ## [lurk, hunt] never reaches the beam.
    var seen = false
    for other in sim.cogs:
      if other.slot == cog.slot or other.state != csActive:
        continue
      if canSee(sim.config, cog, other.x, other.y):
        seen = true
        break
    seen
  else:
    false

proc advancePlan*(sim: Sim, cog: var Cog) =
  ## Called once per tick before the intent is computed.
  var guard = 0
  while cog.planIndex < cog.plan.high and
      stepComplete(sim, cog, cog.plan[cog.planIndex]) and guard < 8:
    cog.planIndex.inc
    guard.inc

proc thirdCogInView(sim: Sim, cog: Cog, victim: int): bool =
  ## The impostor's own "is anybody watching me?" check. It uses only what the
  ## impostor can see, which — because vision is a CONE — is not the same as
  ## "no witness". That fallibility is the point.
  for other in sim.cogs:
    if other.slot == cog.slot or other.slot == victim:
      continue
    if other.state != csActive:
      continue
    if canSee(sim.config, cog, other.x, other.y):
      return true
  false

proc freezeLegal*(sim: Sim, slot, victim: int): bool =
  let cog = sim.cogs[slot]
  if cog.role != rImpostor or cog.state != csActive:
    return false
  if cog.freezeCooldown > 0:
    return false
  if victim < 0 or victim >= Seats or victim == slot:
    return false
  let target = sim.cogs[victim]
  if target.role != rCrew or target.state != csActive:
    return false
  if chebyshev(cog.x, cog.y, target.x, target.y) > sim.config.freezeRange:
    return false
  los(cog.x, cog.y, target.x, target.y)

proc freezeTargets*(sim: Sim, slot: int): seq[string] =
  ## `canFreezeNow`, computed by the SAME predicate the sim's legality check
  ## applies — precomputing the legal choice set in the observation is what
  ## halved formal-output fallbacks in escrow (2026-08-23).
  ##
  ## Listed NEAREST FIRST, ties by (row, col) - never in slot order. A slot
  ## order would make "the impostor always picks the lowest slot" a real,
  ## measurable slot bias in the win rates (tests/test_feasibility.nim gate
  ## (f)), and it is the wrong answer anyway: what a policy wants at the top of
  ## `canFreezeNow` is the target it can actually reach.
  var rows: seq[(int, int, int, int)]
  for victim in 0 ..< Seats:
    if not freezeLegal(sim, slot, victim):
      continue
    rows.add((chebyshev(sim.cogs[slot].x, sim.cogs[slot].y,
      sim.cogs[victim].x, sim.cogs[victim].y),
      sim.cogs[victim].y, sim.cogs[victim].x, victim))
  rows.sort()
  for row in rows:
    result.add(Aliases[row[3]])

proc guardFacing(cog: Cog, sweepTicks: int): Facing =
  Facing((cog.sweep div max(1, sweepTicks)) mod 4)

proc occupancy(sim: Sim, slot: int): array[MapRows * MapCols, bool] =
  ## Where the other ACTIVE cogs are standing right now.
  for other in sim.cogs:
    if other.slot == slot or other.state != csActive:
      continue
    result[cellIndex(other.x, other.y)] = true

proc kernelIntent*(sim: Sim, slot: int): KernelIntent =
  ## This tick's action for one active cog, from its current plan step.
  let cog = sim.cogs[slot]
  result = KernelIntent(action: aWait, facing: cog.facing, setFacing: false)
  if cog.state != csActive:
    return
  let taken = occupancy(sim, slot)
  let step = currentStep(cog)
  case step.job
  of jkHold:
    return

  of jkGuard:
    let field = grateField()
    if field.distAt(cog.x, cog.y) > 0:
      result.action = field.stepToward(cog.x, cog.y, taken)
    else:
      result.facing = guardFacing(cog, sim.config.sweepTicks)
      result.setFacing = true

  of jkDeposit:
    let field = grateField()
    if field.distAt(cog.x, cog.y) > 0:
      result.action = field.stepToward(cog.x, cog.y, taken)
    else:
      result.action = if cog.carry > 0: aDeposit else: aWait
      result.facing = facingToward(cog.x, cog.y, GrateCx, GrateCy)
      result.setFacing = true

  of jkMine:
    let index = seamIndex(step.at)
    if index < 0:
      return
    let field = seamField(index)
    if field.distAt(cog.x, cog.y) > 0:
      result.action = field.stepToward(cog.x, cog.y, taken)
    else:
      result.action =
        if cog.carry < sim.config.carryCap and sim.seams[index].gems > 0:
          aMine
        else:
          aWait
      result.facing = facingToward(cog.x, cog.y,
        SeamTable[index].x, SeamTable[index].y)
      result.setFacing = true

  of jkWatch:
    let who = aliasIndex(step.who)
    if who < 0:
      return
    let target = lastKnownCell(cog, who)
    ## Stand 3..5 cells from the target's last known cell and look at it. This
    ## is the deliberate act of buying vision at the cost of throughput.
    let field = watchField(target[0], target[1])
    if field.distAt(cog.x, cog.y) > 0:
      result.action = field.stepToward(cog.x, cog.y, taken)
    result.facing = facingToward(cog.x, cog.y, target[0], target[1])
    result.setFacing = true

  of jkPatrol:
    let index = roomIndex(step.room)
    if index < 0:
      return
    let corners = roomCorners(index)
    let door = RoomTable[index].door
    let inRoom = roomOf(cog.x, cog.y) == step.room
    let target =
      if inRoom: corners[cog.patrolLeg mod 4]
      else: [door[0], door[1]]
    let field = cellField(target[0], target[1])
    if field.distAt(cog.x, cog.y) > 0:
      result.action = field.stepToward(cog.x, cog.y, taken)

  of jkLurk:
    let index = roomIndex(step.room)
    if index < 0:
      return
    let corner = roomFarCorner(index)
    let door = RoomTable[index].door
    let field = cellField(corner[0], corner[1])
    if field.distAt(cog.x, cog.y) > 0:
      result.action = field.stepToward(cog.x, cog.y, taken)
    else:
      result.facing = facingToward(cog.x, cog.y, door[0], door[1])
      result.setFacing = true

  of jkHunt, jkStrike:
    let who = aliasIndex(step.who)
    if who < 0:
      return
    let mayFire =
      freezeLegal(sim, slot, who) and
        (step.job == jkStrike or not thirdCogInView(sim, cog, who))
    if mayFire:
      result.action = aFreeze
      result.facing = facingToward(cog.x, cog.y,
        sim.cogs[who].x, sim.cogs[who].y)
      result.setFacing = true
      return
    let target =
      if sim.cogs[who].state == csActive and
          canSee(sim.config, cog, sim.cogs[who].x, sim.cogs[who].y):
        [sim.cogs[who].x, sim.cogs[who].y]
      else:
        lastKnownCell(cog, who)
    let field = cellField(target[0], target[1])
    if field.distAt(cog.x, cog.y) > 0:
      result.action = field.stepToward(cog.x, cog.y, taken)
    else:
      result.facing = facingToward(cog.x, cog.y, target[0], target[1])
      result.setFacing = true

proc freezeTargetOf*(sim: Sim, slot: int): int =
  ## The victim a `freeze` intent names this tick, or -1.
  let step = currentStep(sim.cogs[slot])
  if step.job notin {jkHunt, jkStrike}:
    return -1
  aliasIndex(step.who)

proc advancePatrol*(cog: var Cog, room: string) =
  ## Called after a successful move: a patrol leg completes when the cog stands
  ## on its waypoint.
  let index = roomIndex(room)
  if index < 0:
    return
  let corners = roomCorners(index)
  let target = corners[cog.patrolLeg mod 4]
  if cog.x == target[0] and cog.y == target[1]:
    cog.patrolLeg = (cog.patrolLeg + 1) mod 4
