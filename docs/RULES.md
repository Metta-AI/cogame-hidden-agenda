# Hidden Agenda — rules

## Seats, roles, aliases

Five seats, one cog each: **four crew and exactly one impostor**.

| slot | alias | colour | spawn (rotation offset 0) |
|---|---|---|---|
| 0 | `RED` | red | (13, 7) |
| 1 | `BLUE` | blue | (9, 7) |
| 2 | `GREEN` | green | (17, 7) |
| 3 | `YELLOW` | yellow | (9, 11) |
| 4 | `PINK` | pink | (17, 11) |

No two spawn cells are inside the freeze beam's reach: the closest pair is
Chebyshev 4 against `freezeRange = 2`, so a `strike` impostor cannot freeze
anybody on tick one.

Aliases are fixed to slots and never rotate, so a vote for `PINK` is
unambiguously a vote for the pink cog on screen. The **spawn list is rotated by
`seed mod 5`**, so no slot has a fixed starting cell. Each cog spawns facing
away from the grate centre.

The impostor slot is drawn uniformly by `rngRole = seededRng(seed xor
0x1DEA5EED)`, a sub-stream used for **nothing else**; every other draw comes
from `rngWorld = seededRng(seed)`. That separation is what makes the world hash
identical whichever slot ends up as the impostor. `impostorSlot` in the config
pins it (default `-1` = draw it).

**Nobody in-game sees another seat's role.** The impostor is told it is the
impostor and that the other four are crew; each crew seat is told it is crew and
that exactly one of the other four is the impostor. The spectator and the replay
see every role.

## The station

One authored map, `data/maps/vault.txt`, 27 × 19, cell 40 board-px → a fixed
1080 × 760 board that always fits the frame.

```
###########################
#.......##.......##.......#
#.S.....##...S...##.....S.#
#....#..##.#...#.##..#....#
#.......##.......##.......#
#.......#####.#####.......#
####.########.########.####
####.####.........####.####
####.####.#.GGG.#.####.####
####........GGG........####
####.####.#.GGG.#.####.####
####.####.........####.####
####.########.########.####
#.......#####.#####.......#
#.......##.......##.......#
#....#..##.#...#.##..#....#
#.S.....##...S...##.....S.#
#.......##.......##.......#
###########################
```

`#` wall (impassable, blocks sight) · `.` floor · `G` the grate (walkable, 3 × 3
at x 12..14, y 8..10) · `S` a gem seam (impassable, blocks sight, mined from any
orthogonally adjacent floor cell). 249 cells are walkable and every one is
reachable from the grate.

| room | name | seam | walk distance, grate → nearest mining cell |
|---|---|---|---|
| `NW` | NORTHWEST VAULT | `S1` (2, 2) | 17 |
| `N` | NORTH GALLERY | `S2` (13, 2) | 6 |
| `NE` | NORTHEAST VAULT | `S3` (24, 2) | 17 |
| `SW` | SOUTHWEST VAULT | `S4` (2, 16) | 17 |
| `S` | SOUTH GALLERY | `S5` (13, 16) | 6 |
| `SE` | SOUTHEAST VAULT | `S6` (24, 16) | 17 |
| `HUB` | THE GRATE | — | 0 |

Each room has exactly one doorway (`NW` (4,6), `NE` (22,6), `SW` (4,12),
`SE` (22,12), `N` (13,5), `S` (13,13)) and interior pillars that break
sightlines. The two galleries are cheap and the four vaults expensive, so a crew
that only works the cheap seams runs them dry and must eventually walk into a
vault alone.

Every sim quantity is an integer, and the RNG is a seeded stream, so a seed
reproduces a replay bit-exactly.

## Vision: a facing cone

Every cog has a `facing ∈ {N, E, S, W}`. A cell `c` is **visible** to an active
cog `p` iff **both**:

1. `los(p.cell, c)` is clear — the supercover walk crosses no `#` wall and no
   `S` seam (endpoints excluded); **and**
2. `chebyshev(p.cell, c) ≤ awarenessRadius = 4`, **or**
   `chebyshev(p.cell, c) ≤ visionRadius = 8` and `c` lies in `p`'s facing
   quadrant (`N`: `dy < 0 and abs(dx) <= -dy`, and the same wedge rotated).

Frozen bodies and ejected cogs block neither movement nor sight.

**Why a cone.** A symmetric circle makes vision reflexive, and the impostor's
own "is anybody watching me?" check becomes a perfect witness detector — the
witnessed freeze would never fire against a competent impostor. A cone makes
vision genuinely asymmetric.

**Facing is set by the kernel, not micro-managed**: a moving cog faces its
direction of travel; a mining cog faces its seam; a `watch` cog faces its
target; a `guard` cog sweeps one quadrant clockwise every `sweepTicks = 8`.

## The gem economy

- **Seams.** 6 seams, `seamCapacity = 3` gems each, regrowing +1 every
  `seamRegrowTicks = 120` ticks up to capacity.
- **Mining.** A cog adjacent to a seam with a `mine` intent and hands not full
  advances `mineProgress`; at `mineTicks = 72` it takes one gem. Progress resets
  if the cog moves, is frozen, or a meeting opens. Any number of cogs may mine
  the same seam from different adjacent cells.
- **Carrying.** `carryCap = 2`. Hands full ⇒ `mine` degrades to `wait`.
- **Depositing.** One gem per tick on a grate cell. For crew: `deposits += 1`.
  For the impostor: the gem is destroyed, the counter does **not** move, and a
  `fakedeposit` is emitted carrying the aliases of every active cog whose FOV
  contains that grate cell.
- **`depositTarget = 32`** is an immediate crew win.

## The freeze beam

Impostor-only, legal iff **all** of: the impostor is active; `freezeCooldown ==
0`; the target is an **active crew** cog; `chebyshev ≤ freezeRange = 2`; and
line of sight is clear. Range is a Chebyshev radius, not the vision cone — you
may freeze something beside or behind you.

On success the target becomes **frozen** at its cell, permanently: it stops
acting, does not vote, and its carried gems are lost. `freezeCooldown` is set to
`freezeCooldownTicks = 260`. At most one freeze resolves per tick, and freezes
never happen during a meeting.

## The witness trigger

At the tick a freeze resolves, the witness set **W** is every **active** cog
other than the impostor and the victim, evaluated with the positions and facings
**as they stood at the start of that tick**, whose FOV contains the victim's
cell or the impostor's cell.

Each `w ∈ W` gets a `witness` row (`sawFreezer` distinguishes "I know who did
it" from "I know it happened here"). If W is non-empty, a **`caught`** event
fires — the banner — and a meeting opens **immediately**, at the end of that
same tick, with `cause: "witness"`. No cooldown, no cadence check.

## Meetings, deliberation, the vote

Meetings open on exactly two causes: the `meetingCadenceTicks = 200` timer
reaching 0 (reset at the end of every meeting), and a witnessed freeze. There is
**no report button and no emergency button**.

On open, all active cogs are saved and teleported to five fixed seats around the
grate — (11,8) (15,8) (11,10) (15,10) (13,11) — assigned among the active
seats by where each cog was **standing** when the meeting opened, sorted by
`(row, col)`, each facing the grate centre. Deliberately not slot order: the
decision batch is issued after the teleport, so a slot-ordered assignment would
plan slot 0 from (11,8) and slot 4 from (13,11) at every meeting of every
episode and make the crew-win rate depend on which slot drew the impostor. Frozen cogs stay where they are. Positions and facings
are restored exactly at the end.

| offset from `m0` | `hidden-agenda` (chat, 60) | `-notalk` / `-blind` (25) |
|---|---|---|
| 0 | meeting opens; teleport; the decision batch is issued and awaited | same |
| `sayTick` | **10** — every `say` revealed simultaneously | — (no chat) |
| `revealTick` | **24** — all initial votes posted simultaneously | **5** |
| `switchTick` | **46** — conditionals evaluated | **18** |
| `resolveTick` | **56** — tally, ejection | **23** |
| `meetingTicks` | **60** — restore, reset the cadence, resume | **25** |

**Votes are visible and changeable, on one LLM call.** A reply carries `vote`
and an optional one-shot conditional `switch = {"if": X, "to": Y}`. At
`switchTick` a **single snapshot** of the tally as it stood at `switchTick − 1`
is taken; for each seat with a `switch`, the condition holds iff `X` is the
**unique** strictly-highest cog (or, for `X == "tie"`, iff nobody leads
strictly). Every matching seat's vote changes **simultaneously** against that
same snapshot. Only seats whose vote actually changed emit a row.

**Tally.** Let `m` be the highest count among aliases and `s` the number of
skips. Every active seat casts exactly one vote (a failed reply casts `skip`);
frozen and ejected seats cast nothing.

- `m > s` and exactly one alias has `m` → that cog is **ejected** (`plurality`).
- `m > s` and two or more tie at `m` → nobody (`tie`).
- `s >= m` → nobody (`skip`).

An ejected cog is removed from the map entirely — no body, no evidence.

## Jobs

`move_n` · `move_e` · `move_s` · `move_w` · `mine` · `deposit` · `freeze` ·
`face_n` · `face_e` · `face_s` · `face_w` · `wait` is the whole per-tick
vocabulary. `move_*` is legal only every `moveCooldown = 2` ticks and only into
a floor or grate cell not occupied by another active cog.

At each decision point a seat submits a plan of up to `planSteps = 3` jobs and a
deterministic kernel turns it into the per-tick action stream. Steps run in
order; when a step completes the next begins; when the plan is exhausted the
last step repeats. BFS is over walkable cells, neighbours expand N, E, S, W,
other cogs are not obstacles for planning, ties break by (row, col) ascending.

**Crew jobs** (the impostor may use all six, to blend):

1. `mine at:<seam>` — walk to the nearest cell adjacent to that seam and mine.
   Completes when hands are full or the seam is empty.
2. `deposit` — walk to the nearest grate cell and deposit. Completes when hands
   are empty.
3. `watch who:<alias>` — stand 3..5 cells from that cog's last known cell and
   wait, facing it, re-targeting as it moves. Never mines.
4. `patrol room:<room>` — walk to the doorway, then the four corners in a cycle.
5. `guard` — stand on the grate and sweep one quadrant every `sweepTicks`.
6. `hold` — wait in place.

**Impostor-only:**

7. `hunt who:<alias>` — close, and fire when the freeze is legal **and no third
   active cog is inside the impostor's own FOV**. That check uses only what the
   impostor can see, which — because vision is a cone — is not the same as "no
   witness".
8. `strike who:<alias>` — as `hunt`, but fires the instant it is legal.
9. `lurk room:<room>` — wait in the room's far corner facing the doorway.

## The twelve steps of a play tick

Seats resolve in ascending slot order, seams in `S1..S6` order.

1. **Timers.** Move cooldowns, the freeze cooldown, seam regrowth.
2. **Kernel intent.** Each active cog's action from its current plan step.
3. **Freeze resolves** (impostor only, at most one).
4. **Witness check**, from start-of-tick positions and facings. Emits `witness`
   rows and, if W is non-empty, `caught` — and arms an immediate meeting.
5. **Deposits resolve.**
6. **Mining resolves.**
7. **Moves resolve** against the live board, in a multi-pass sweep that repeats
   until nothing more can move. A contested free cell goes to the cog standing
   at the smaller `(row, col)` — not the lower slot — and a final pass lets two
   cogs whose targets are each other's cells **swap**. A move that still cannot
   land degrades to `wait`. The sweep is what stops two cogs deadlocking a
   corridor for the rest of an episode; it is deterministic, but the realised
   step depends on where the other cogs stand, not on the map alone.
8. **Facing** for non-movers, per the job rule.
9. **FOV and memory**: `lastSeen`, `bodies`, `togetherTicks`, `youWitnessed`.
10. **Win check**, in order: 32 deposits → crew; the impostor ejected → crew;
    active crew ≤ 1 → impostor; tick 3000 → tie.
11. **Meeting trigger**: the armed witnessed meeting, else the cadence timer.
12. **Record** the frame, its events and the series rows.

## Scoring and end conditions

Zero-sum, higher is better; the five always sum to 0.

```
winner "crew"     -> +1 for each of the 4 crew seats,  -4 for the impostor
winner "impostor" -> -1 for each of the 4 crew seats,  +4 for the impostor
winner "none"     ->  0 for all five
```

Crew who were frozen or ejected still receive the crew result — it is a team
game, and being frozen is the impostor's success, not the victim's failure.
There is no partial credit for deposits.

| condition | `reason` | `ending` | winner |
|---|---|---|---|
| `deposits >= 32` | `complete` | `crew_deposits` | crew |
| the impostor is ejected | `complete` | `impostor_ejected` | crew |
| active crew ≤ 1 | `complete` | `impostor_isolation` | impostor |
| tick 3000 | `complete` | `timeout` | none |
| the play deadline (0.6 × `episodeTimeoutSeconds` = 720 s) | `deadline` | `deadline` | none |
| no seat connected within 120 s | `forfeit` | `forfeit` | none |
