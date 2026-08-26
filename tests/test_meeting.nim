## tests/test_meeting.nim — deliberation and the vote.

import std/[json, tables]
import support/helpers
import hidden_agenda/[sim_types, station, sim_config, sim_state, meeting, sim]

template check(condition: bool, message: string) =
  ## A TEMPLATE, not a proc: the message is only built when the check fails.
  ## Eagerly concatenating a per-tick label across a 192-episode sweep is a
  ## minute of string building for nothing.
  if not condition:
    echo "FAIL: ", message
    quit(1)

proc rig(variant: string): Sim =
  var config = baseConfig(3, variant)
  config.impostorSlot = 4
  result = initSim(config)

block tallyRule:
  var states: array[Seats, CogState]
  for slot in 0 ..< Seats:
    states[slot] = csActive
  ## m > s with a unique maximum ejects.
  var votes = ["PINK", "PINK", "PINK", "skip", "skip"]
  var outcome = resolveTally(tallyOf(votes, states))
  check(outcome.outcome == "plurality" and outcome.target == "PINK",
    "a strict plurality over the skips ejects")
  ## Two aliases tied at the top: nobody.
  votes = ["PINK", "PINK", "BLUE", "BLUE", "skip"]
  outcome = resolveTally(tallyOf(votes, states))
  check(outcome.outcome == "tie" and outcome.target == "",
    "a tie ejects nobody")
  ## Skips at least equal the top count: nobody.
  votes = ["PINK", "PINK", "skip", "skip", "skip"]
  outcome = resolveTally(tallyOf(votes, states))
  check(outcome.outcome == "skip", "a skip majority ejects nobody")
  ## Everyone skips.
  votes = ["skip", "skip", "skip", "skip", "skip"]
  check(resolveTally(tallyOf(votes, states)).outcome == "skip",
    "all skip ejects nobody")

block frozenAndEjectedCastNothing:
  var states: array[Seats, CogState]
  for slot in 0 ..< Seats:
    states[slot] = csActive
  states[2] = csFrozen
  states[3] = csEjected
  let votes = ["PINK", "PINK", "BLUE", "BLUE", "skip"]
  let tally = tallyOf(votes, states)
  check(tally.counts.getOrDefault("PINK") == 2, "two live votes for PINK")
  check(not tally.counts.hasKey("BLUE"),
    "a frozen and an ejected seat cast nothing")
  check(tally.skips == 1, "the live skip still counts")

block conditionals:
  var states: array[Seats, CogState]
  for slot in 0 ..< Seats:
    states[slot] = csActive
  let leading = tallyOf(["PINK", "PINK", "BLUE", "skip", "skip"], states)
  check(conditionHolds(leading, "PINK"), "PINK leads strictly")
  check(not conditionHolds(leading, "BLUE"), "BLUE does not")
  check(not conditionHolds(leading, "tie"), "and it is not a tie")
  let tied = tallyOf(["PINK", "BLUE", "PINK", "BLUE", "skip"], states)
  check(conditionHolds(tied, "tie"), "\"tie\" fires when nobody leads")
  check(not conditionHolds(tied, "PINK"), "and no alias condition fires")
  let allSkip = tallyOf(["skip", "skip", "skip", "skip", "skip"], states)
  check(conditionHolds(allSkip, "tie"), "the all-skip case counts as a tie")

proc runMeeting(sim: var Sim, votes, ifs, tos: openArray[string]) =
  sim.openMeetingForTest(mcCadence)
  for slot in 0 ..< Seats:
    if sim.cogs[slot].state != csActive:
      continue
    sim.votes[slot] = votes[slot]
    sim.switchIf[slot] = ifs[slot]
    sim.switchTo[slot] = tos[slot]
  for _ in 0 ..< sim.config.meetingTicks:
    sim.tick.inc
    sim.meetingTickForTest()
  sim.closeMeetingForTest()

block bothShapesFireOnTheirOwnOffsets:
  for variant in ["hidden-agenda", "hidden-agenda-notalk"]:
    var sim = rig(variant)
    let m0 = 40
    sim.tick = m0
    sim.openMeetingForTest(mcCadence)
    check(sim.meetingPhase == mpOpen, variant & ": M1 opens the meeting")
    for slot in 0 ..< Seats:
      sim.votes[slot] = "PINK"
      sim.says[slot] = "hello"
    var sawSaid = false
    var sawVoted = false
    var sawSwitched = false
    var sawResolved = false
    for offset in 1 .. sim.config.meetingTicks:
      sim.tick = m0 + offset
      sim.meetingTickForTest()
      if offset == sim.config.sayTick:
        sawSaid = sim.meetingPhase == mpSaid
      if offset == sim.config.revealTick:
        sawVoted = sim.meetingPhase == mpVoted
      if offset == sim.config.switchTick:
        sawSwitched = sim.meetingPhase == mpSwitched
      if offset == sim.config.resolveTick:
        sawResolved = sim.meetingPhase == mpResolved
    if sim.config.chat:
      check(sawSaid, variant & ": the say step fires at sayTick")
      check(countKind(sim, "say") == Seats, variant & ": five say rows")
    else:
      check(countKind(sim, "say") == 0,
        variant & ": a no-talk variant records no say at all")
    check(sawVoted, variant & ": votes are posted at revealTick")
    check(sawSwitched, variant & ": conditionals evaluate at switchTick")
    check(sawResolved, variant & ": the tally resolves at resolveTick")
    check(countKind(sim, "eject") == 1, variant & ": exactly one eject row")

block positionsAreSavedAndRestored:
  var sim = rig("hidden-agenda-notalk")
  sim.cogs[1].state = csFrozen
  sim.cogs[1].x = 24
  sim.cogs[1].y = 15
  var before: array[Seats, array[3, int]]
  for slot in 0 ..< Seats:
    before[slot] = [sim.cogs[slot].x, sim.cogs[slot].y,
      ord(sim.cogs[slot].facing)]
  sim.openMeetingForTest(mcCadence)
  check(sim.cogs[1].x == 24 and sim.cogs[1].y == 15,
    "a frozen cog stays where it is - it IS the evidence")
  var seats = 0
  for slot in 0 ..< Seats:
    if sim.cogs[slot].state != csActive:
      continue
    seats.inc
    var atSeat = false
    for seat in MeetingSeats:
      if sim.cogs[slot].x == seat[0] and sim.cogs[slot].y == seat[1]:
        atSeat = true
    check(atSeat, "every active cog is teleported to a meeting seat")
  check(seats == Seats - 1, "the frozen cog did not teleport")
  sim.closeMeetingForTest()
  for slot in 0 ..< Seats:
    check([sim.cogs[slot].x, sim.cogs[slot].y,
      ord(sim.cogs[slot].facing)] == before[slot],
      "positions and facings are restored exactly")
  check(sim.cadence == sim.config.meetingCadenceTicks,
    "the cadence timer resets at the END of every meeting")

block switchesUseOneSnapshotAndEmitOnlyRealChanges:
  var sim = rig("hidden-agenda-notalk")
  ## RED and BLUE vote PINK; GREEN and YELLOW carry conditionals keyed on PINK
  ## leading, and PINK carries one that cannot fire.
  sim.runMeeting(
    ["PINK", "PINK", "skip", "skip", "skip"],
    ["", "", "PINK", "PINK", "BLUE"],
    ["", "", "PINK", "PINK", "RED"])
  var switched = 0
  for row in eventsOfKind(sim, "vote"):
    if row{"phase"}.getStr() == "switch":
      switched.inc
  check(switched == 2,
    "both conditionals fired against the SAME snapshot, and only they")
  let ejects = eventsOfKind(sim, "eject")
  check(ejects.len == 1, "one eject row")
  check(ejects[0]{"target"}.getStr() == "PINK",
    "4 votes for PINK against 1 skip ejects PINK")
  check(ejects[0]{"wasImpostor"}.getBool(),
    "PINK is the pinned impostor, and the row says so spectator-side")

block aSwitchThatChangesNothingEmitsNoRow:
  var sim = rig("hidden-agenda-notalk")
  sim.runMeeting(
    ["PINK", "PINK", "PINK", "skip", "skip"],
    ["", "", "PINK", "", ""],
    ["", "", "PINK", "", ""])
  for row in eventsOfKind(sim, "vote"):
    check(row{"phase"}.getStr() != "switch",
      "a switch onto the vote you already cast emits nothing")

block ejectingTheImpostorEndsTheEpisode:
  var sim = rig("hidden-agenda-notalk")
  sim.runMeeting(
    ["PINK", "PINK", "PINK", "PINK", "skip"],
    ["", "", "", "", ""], ["", "", "", "", ""])
  check(sim.done, "ejecting the impostor ends it")
  check(sim.ending == "impostor_ejected", "with the right ending")
  check(sim.winner == "crew", "and the crew win")

block ejectingTheLastButOneCrewEndsItTheOtherWay:
  var sim = rig("hidden-agenda-notalk")
  sim.cogs[1].state = csFrozen
  sim.cogs[2].state = csFrozen
  sim.runMeeting(
    ["skip", "", "", "RED", "RED"],
    ["", "", "", "", ""], ["", "", "", "", ""])
  check(sim.done, "removing the third crewmate ends it")
  check(sim.ending == "impostor_isolation", "with the right ending")
  check(sim.winner == "impostor", "and the impostor wins")

block aFailedReplyCastsSkip:
  var sim = rig("hidden-agenda-notalk")
  sim.openMeetingForTest(mcCadence)
  ## Nobody's vote is installed at all.
  for offset in 1 .. sim.config.meetingTicks:
    sim.tick = sim.meetingOpenTick + offset
    sim.meetingTickForTest()
  for row in eventsOfKind(sim, "vote"):
    check(row{"target"}.getStr() == "skip",
      "a seat with no valid reply casts skip")
  check(eventsOfKind(sim, "eject")[0]{"outcome"}.getStr() == "skip",
    "five skips eject nobody")

block theImpostorBandwagonsOnThePreviousMeeting:
  ## The `miner` impostor's vote is "the active cog, other than itself, with
  ## the most votes in the PREVIOUS meeting", and its switch names the
  ## second-most. `openMeeting` appends the CURRENT meeting's record with five
  ## empty votes before the decision point runs, so a reader of
  ## `sim.meetings[^1]` finds an empty table forever and the bandwagon never
  ## fires (it fell through to the stale-cog fallback with switch "skip").
  var sim = rig("hidden-agenda-notalk")

  ## Meeting 1: RED and GREEN draw votes, BLUE draws one.
  sim.openMeetingForTest(mcCadence)
  let votes1 = ["BLUE", "RED", "RED", "GREEN", "GREEN"]
  for slot in 0 ..< Seats:
    var decision = Decision(plan: @[PlanStep(job: jkHold)], vote: votes1[slot])
    sim.applyDecision(slot, decision, true)
  for offset in 1 .. sim.config.meetingTicks:
    sim.tick = sim.meetingOpenTick + offset
    sim.meetingTickForTest()
  sim.closeMeetingForTest()
  check(sim.meetings.len == 1 and sim.meetings[0].outcome.len > 0,
    "meeting 1 must have resolved")

  ## Meeting 2 opens; the impostor decides at its opening decision point, with
  ## the current meeting's record already appended and empty.
  sim.tick = sim.meetingOpenTick + sim.config.meetingTicks + 1
  sim.openMeetingForTest(mcCadence)
  check(sim.meetings.len == 2 and sim.meetings[1].votes[0].len == 0,
    "the current meeting's record is appended before the decision point " &
    "and is empty")
  let decision = scriptedDecision(sim, sim.impostorSlot, skMiner, true)
  check(decision.vote in ["RED", "GREEN"],
    "the impostor bandwagons onto a leader of the PREVIOUS meeting, got '" &
    decision.vote & "'")
  check(decision.switchTo in ["RED", "GREEN"] and
        decision.switchTo != decision.vote,
    "and its switch names the runner-up, not the 'skip' the dead path " &
    "always produced, got '" & decision.switchTo & "'")
  check(decision.switchIf == Aliases[sim.impostorSlot],
    "the switch is conditional on a vote landing on itself")

echo "test_meeting: ok"
