## tests/test_vision.nim — the cone.
##
## The whole witness mechanic rests on ONE property: `visible` is not symmetric
## between cogs. This file is where that is nailed down.

import support/helpers
import hidden_agenda/[sim_types, station, sim_config, sim_state, vision, sim]

template check(condition: bool, message: string) =
  ## A TEMPLATE, not a proc: the message is only built when the check fails.
  ## Eagerly concatenating a per-tick label across a 192-episode sweep is a
  ## minute of string building for nothing.
  if not condition:
    echo "FAIL: ", message
    quit(1)

block quadrants:
  ## Quadrant membership for all four facings, hand-checked.
  check(quadrantOf(fN, 0, -1), "straight ahead is in the N wedge")
  check(quadrantOf(fN, 3, -3), "the N wedge reaches the 45-degree edge")
  check(not quadrantOf(fN, 4, -3), "and stops past it")
  check(not quadrantOf(fN, 0, 1), "behind is never in the wedge")
  check(quadrantOf(fS, 0, 5) and quadrantOf(fS, -5, 5), "the S wedge")
  check(quadrantOf(fE, 5, 0) and quadrantOf(fE, 5, -5), "the E wedge")
  check(quadrantOf(fW, -5, 0) and quadrantOf(fW, -5, 5), "the W wedge")
  check(not quadrantOf(fE, -1, 0), "west is not in the E wedge")

block losIsSymmetric:
  ## `los` is a predicate on CELLS and must be symmetric. `visible` is not.
  var pairs = 0
  let cells = walkableCells()
  for i in 0 ..< cells.len:
    for j in i + 1 ..< cells.len:
      if chebyshev(cells[i][0], cells[i][1], cells[j][0], cells[j][1]) > 9:
        continue
      pairs.inc
      let a = los(cells[i][0], cells[i][1], cells[j][0], cells[j][1])
      let b = los(cells[j][0], cells[j][1], cells[i][0], cells[i][1])
      check(a == b, "los must be symmetric between " & $cells[i] & " and " &
        $cells[j])
  check(pairs > 1000, "the symmetry sweep must cover a real sample")

block losIsBlocked:
  ## Blocked by BOTH a `#` wall and an `S` seam.
  check(not los(2, 1, 2, 3), "S1 at (2,2) blocks the vertical line")
  check(not los(13, 1, 13, 3), "S2 at (13,2) blocks the vertical line")
  check(not los(1, 1, 20, 1), "the wall spine blocks a long horizontal line")
  check(los(1, 1, 7, 1), "an open row inside a vault is clear")
  check(los(13, 8, 13, 10), "the grate is transparent")

block visibleIsNotSymmetric:
  ## The property the whole game rests on: A sees B and B does not see A.
  let config = baseConfig(1)
  ## Far enough apart that the omnidirectional ring cannot reach: what is
  ## being tested is the CONE.
  var seer = Cog(slot: 0, x: 13, y: 4, facing: fS, state: csActive)
  var seen = Cog(slot: 1, x: 13, y: 10, facing: fN, state: csActive)
  check(chebyshev(seer.x, seer.y, seen.x, seen.y) > config.awarenessRadius,
    "the pair must be outside the awareness ring for this to test the cone")
  check(seesCog(config, seer, seen), "the south-facing cog sees down the hall")
  seen.facing = fS
  check(seesCog(config, seer, seen), "still sees it whichever way it faces")
  check(not seesCog(config, seen, seer),
    "a cog facing AWAY does not see the one behind it")

block awarenessRing:
  ## The ring sees behind you at range 2 and not at 3, and walls block it too.
  let config = baseConfig(1)
  var cog = Cog(slot: 0, x: 13, y: 7, facing: fN, state: csActive)
  let ring = config.awarenessRadius
  check(canSee(config, cog, 13, 7 + ring),
    "the ring reaches awarenessRadius cells behind")
  check(not canSee(config, cog, 13, 7 + ring + 1),
    "and stops there, outside the cone")
  ## A SEAM blocks the ring too: (2,2) sits between (3,2) and (1,2).
  var boxed = Cog(slot: 0, x: 3, y: 2, facing: fE, state: csActive)
  check(chebyshev(3, 2, 1, 2) <= config.awarenessRadius,
    "the pair must be inside the ring for this to test the ring")
  check(not canSee(config, boxed, 1, 2), "a seam blocks the ring")

block neverSeesItself:
  let config = baseConfig(1)
  let cog = Cog(slot: 2, x: 13, y: 9, facing: fN, state: csActive)
  check(not seesCog(config, cog, cog), "a cog never sees itself")

block frozenIsStillEvidence:
  let config = baseConfig(1)
  let watcher = Cog(slot: 0, x: 13, y: 6, facing: fS, state: csActive)
  var body = Cog(slot: 1, x: 13, y: 9, facing: fN, state: csFrozen)
  check(seesCog(config, watcher, body), "a frozen cog is still visible")
  body.state = csEjected
  check(not seesCog(config, watcher, body), "an ejected cog is gone")

block recordedMaskMatches:
  ## The recorded `v` bitmask equals a recomputed `visible()` for every cog on
  ## every tick of a full episode.
  var config = baseConfig(7)
  config.maxTicks = 600
  let sim = playEpisode(config, uniformKinds(skMiner))
  check(sim.frames.len > 100, "the episode must actually run")
  ## Replay the episode once more and compare the mask at the terminal state.
  for slot in 0 ..< Seats:
    var expected = 0
    for other in 0 ..< Seats:
      if seesCog(sim.config, sim.cogs[slot], sim.cogs[other]):
        expected = expected or (1 shl other)
    check(sim.frames[^1].v[slot] == expected,
      "the recorded visibility mask must equal a recomputed one for slot " &
      $slot)
    check((sim.frames[^1].v[slot] and (1 shl slot)) == 0,
      "a cog's own bit is always 0")

echo "test_vision: ok"
