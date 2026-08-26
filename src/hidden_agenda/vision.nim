## Vision: the 90-degree facing cone, the awareness ring, and the per-seat
## memory update.
##
## New module (paintbot has no equivalent; its fog is per-cell and baked). The
## whole witness mechanic rests on ONE property: `visible` is NOT symmetric
## between cogs. Somebody behind you sees you and you do not see them. That is
## the risk the freeze beam carries.
##
## Vision is evaluated ON DEMAND for objects, never per cell: the four other
## cogs, the six seams and the grate — about fifteen `los` walks per cog per
## tick, not 249.

import sim_types, station, sim_config

proc canSee*(
  observerX, observerY: int,
  facing: Facing,
  targetX, targetY: int,
  visionRadius, awarenessRadius: int
): bool =
  ## A cell is visible iff line of sight is clear AND it is either inside the
  ## omnidirectional awareness ring or inside the facing wedge within
  ## `visionRadius`.
  if observerX == targetX and observerY == targetY:
    return true
  let
    dx = targetX - observerX
    dy = targetY - observerY
    cheb = max(abs(dx), abs(dy))
  if cheb > max(visionRadius, awarenessRadius):
    return false
  if cheb > awarenessRadius and not quadrantOf(facing, dx, dy):
    return false
  if cheb > awarenessRadius and cheb > visionRadius:
    return false
  los(observerX, observerY, targetX, targetY)

proc canSee*(config: GameConfig, cog: Cog, targetX, targetY: int): bool =
  canSee(cog.x, cog.y, cog.facing, targetX, targetY,
    config.visionRadius, config.awarenessRadius)

proc seesCog*(config: GameConfig, observer, target: Cog): bool =
  ## A cog never sees itself, and an ejected cog is not on the map at all. A
  ## FROZEN cog is still visible — it is the evidence.
  if observer.slot == target.slot:
    return false
  if observer.state != csActive:
    return false
  if target.state == csEjected:
    return false
  canSee(config, observer, target.x, target.y)

proc doingOf*(cog: Cog): string =
  ## What another seat perceives this cog to be doing, in plain words.
  case cog.state
  of csFrozen: "frozen"
  of csEjected: "gone"
  of csActive:
    if cog.lastAction == aMine: "mining"
    elif cog.lastAction == aDeposit: "depositing"
    elif cog.lastAction.isMove: "walking"
    else: "standing"
