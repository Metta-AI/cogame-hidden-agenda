## tests/test_feasibility.nim — the oracle, as a CI precondition.
##
## Gates (a)..(g) of the design note's `## The game`, over seeds 1..16 (1..64
## for the slot-bias gate) on all three variants. Any constant change that
## breaks the race — or that makes the evidence channel useless — fails HERE
## rather than in a dead replay.
##
## Every gate prints its measurement whether it passes or fails, so one CI run
## is enough to retune a constant.

import std/[json, strformat]
import support/helpers
import hidden_agenda/[sim_types, station, sim_config, sim_state, kernel, sim]

var failures = 0

template gate(name: string, condition: bool, detail: string) =
  if condition:
    echo "  PASS ", name, ": ", detail
  else:
    echo "  FAIL ", name, ": ", detail
    failures.inc

const Seeds = 16
const SlotSeeds = 64
const DrawSeeds = 4096

proc pct(part, whole: int): float =
  if whole == 0: 0.0 else: part.float / whole.float

warmKernelCaches()

# ---------------------------------------------------------------------------
# (a) The baselines play the game, and (g) the budget.
# ---------------------------------------------------------------------------
echo "gate (a) all-miner episodes end in a real ending; (g) the budget"
for variant in AllVariants:
  var complete = 0
  var timeouts = 0
  var worstDecisions = 0
  var worstMeetings = 0
  for seed in 1 .. Seeds:
    let sim = playAll(seed, variant, skMiner, skMiner,
      impostorSlot = seed mod Seats)
    if sim.ending in ["crew_deposits", "impostor_ejected",
        "impostor_isolation"]:
      complete.inc
    if sim.ending == "timeout":
      timeouts.inc
    worstDecisions = max(worstDecisions, sim.decisions)
    worstMeetings = max(worstMeetings, sim.meetings.len)
  gate("a/" & variant, complete >= 14 and timeouts <= 2,
    &"{complete}/{Seeds} decisive, {timeouts}/{Seeds} timeouts")
  gate("g/" & variant,
    worstDecisions <= 20 and worstMeetings <= 18,
    &"worst {worstDecisions} decision batches, {worstMeetings} meetings")

# ---------------------------------------------------------------------------
# (b) Both sides can win, on the DEFAULT variant.
# ---------------------------------------------------------------------------
echo "gate (b) both sides can win"
block:
  var crewWins = 0
  for seed in 1 .. Seeds:
    let sim = playAll(seed, "hidden-agenda", skMiner, skMiner,
      impostorSlot = seed mod Seats)
    if sim.winner == "crew":
      crewWins.inc
  let rate = pct(crewWins, Seeds)
  gate("b", rate >= 0.30 and rate <= 0.70,
    &"all-miner crew win rate {rate:.2f} ({crewWins}/{Seeds})")

# ---------------------------------------------------------------------------
# (c) Recklessness is punished.
# ---------------------------------------------------------------------------
echo "gate (c) the lurker impostor gets caught"
block:
  var witnessed = 0
  var impostorWins = 0
  for seed in 1 .. Seeds:
    let sim = playAll(seed, "hidden-agenda-notalk", skMiner, skLurker,
      impostorSlot = seed mod Seats)
    witnessed += sim.witnessedFreezes
    if sim.winner == "impostor":
      impostorWins.inc
  let mean = witnessed.float / Seeds.float
  let rate = pct(impostorWins, Seeds)
  gate("c", mean >= 0.5 and rate <= 0.35,
    &"mean witnessed freezes {mean:.2f}, impostor win rate {rate:.2f}")

# ---------------------------------------------------------------------------
# (d) Watching has a real cost: a crew that only watches loses.
# ---------------------------------------------------------------------------
echo "gate (d) mining is what wins"
block:
  ## A TEST-ONLY crew kernel: every crew seat watches its nearest neighbour and
  ## nobody mines.
  proc watcherDecider(impostorSlot: int): Decider =
    proc decide(view: var Sim, seats: seq[int], cause: string):
        seq[Decision] {.closure.} =
      var out2: seq[Decision]
      for seat in seats:
        if seat == impostorSlot:
          out2.add(scriptedDecision(view, seat, skMiner, view.inMeeting))
          continue
        var target = -1
        var best = high(int)
        for other in 0 ..< Seats:
          if other == seat or view.cogs[other].state != csActive:
            continue
          let d = walkDistance(view.cogs[seat].x, view.cogs[seat].y,
            view.cogs[other].x, view.cogs[other].y)
          if d < best:
            best = d
            target = other
        var decision = Decision(source: dsScripted)
        if target >= 0:
          decision.plan.add(PlanStep(job: jkWatch, who: Aliases[target]))
        else:
          decision.plan.add(PlanStep(job: jkGuard))
        if view.inMeeting:
          decision.vote = "skip"
        out2.add(decision)
      out2
    decide

  var losses = 0
  for seed in 1 .. Seeds:
    var config = baseConfig(seed, "hidden-agenda-notalk")
    config.impostorSlot = seed mod Seats
    var sim = initSim(config)
    sim.runEpisode(watcherDecider(config.impostorSlot))
    sim.finalise()
    if sim.winner != "crew":
      losses.inc
  let rate = pct(losses, Seeds)
  gate("d", rate >= 0.85,
    &"an all-watching crew fails to win in {rate:.2f} of seeds")

# ---------------------------------------------------------------------------
# (e) The evidence channel carries: a witnessed freeze convicts.
# ---------------------------------------------------------------------------
echo "gate (e) spatial evidence alone convicts"
block:
  ## One CASE per witnessed freeze: every `caught` event is an opportunity, and
  ## the meeting immediately following it either ejects the impostor or does
  ## not. (Counting one case per EPISODE instead would throw away every freeze
  ## after the first, which is where the crew's evidence is strongest.)
  var opportunities = 0
  var convictions = 0
  for seed in 1 .. Seeds:
    let sim = playAll(seed, "hidden-agenda-notalk", skMiner, skLurker,
      impostorSlot = seed mod Seats)
    for caught in eventsOfKind(sim, "caught"):
      let caughtAt = caught{"t"}.getInt()
      opportunities.inc
      for row in eventsOfKind(sim, "eject"):
        if row{"t"}.getInt() < caughtAt:
          continue
        if row{"wasImpostor"}.getBool():
          convictions.inc
        break
  let rate = pct(convictions, opportunities)
  gate("e", opportunities == 0 or rate >= 0.60,
    &"{convictions}/{opportunities} witnessed freezes convicted ({rate:.2f})")

# ---------------------------------------------------------------------------
# (f) No slot bias.
# ---------------------------------------------------------------------------
echo "gate (f) no slot bias"
block:
  ## The DRAW costs no episodes, so it is measured over `DrawSeeds` rather than
  ## the 64 the win-rate half uses. At 64 samples a +-20 % band is only +-1.6
  ## standard deviations and a perfectly uniform stream fails it about a third
  ## of the time; at 4096 it is +-6.4 sigma, so +-20 % is a real claim about
  ## the sub-stream instead of a coin flip about the sample.
  var drawn: array[Seats, int]
  for seed in 1 .. DrawSeeds:
    var config = baseConfig(seed)
    config.impostorSlot = -1
    drawn[drawImpostor(config)].inc
  let expected = DrawSeeds.float / Seats.float
  var worst = 0.0
  for count in drawn:
    worst = max(worst, abs(count.float - expected) / expected)
  gate("f/uniform", worst <= 0.20,
    &"drawn {drawn} over {DrawSeeds} seeds, worst deviation {worst:.2f} " &
    "of uniform")

  var rates: array[Seats, float]
  for pinned in 0 ..< Seats:
    var crewWins = 0
    for seed in 1 .. SlotSeeds:
      let sim = playAll(seed, "hidden-agenda-notalk", skMiner, skMiner,
        impostorSlot = pinned)
      if sim.winner == "crew":
        crewWins.inc
    rates[pinned] = pct(crewWins, SlotSeeds)
  var lo = 1.0
  var hi = 0.0
  for rate in rates:
    lo = min(lo, rate)
    hi = max(hi, rate)
  gate("f/slots", hi - lo <= 0.10 + 1e-9,
    &"crew win rate per pinned slot {rates}, spread {hi - lo:.2f}")

if failures > 0:
  echo "test_feasibility: ", failures, " gate(s) failed"
  quit(1)
echo "test_feasibility: ok"
