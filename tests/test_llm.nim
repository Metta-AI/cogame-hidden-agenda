## tests/test_llm.nim — the decision layer.
##
## The transport itself is never called here: what is tested is the tolerant
## extraction, the strict reply schema, the batch shape, the wall-clock floor,
## the batch cap and the play deadline.

import std/[json, strutils, unicode]
import support/helpers
import hidden_agenda/[sim_types, station, sim_config, sim_state, sim, llm]

template check(condition: bool, message: string) =
  if not condition:
    echo "FAIL: ", message
    quit(1)

proc rig(variant = "hidden-agenda-notalk"): Sim =
  var config = baseConfig(4, variant)
  config.impostorSlot = 4
  result = initSim(config)

proc parses(sim: Sim, slot: int, text: string): bool =
  try:
    discard parseReply(sim, slot, extractJsonObject(text))
    true
  except CatchableError:
    false

block extraction:
  let fenced = "```json\n{\"plan\":[{\"job\":\"guard\"}]}\n```"
  check(extractJsonObject(fenced){"plan"}.len == 1,
    "a fenced reply is extracted")
  let prose = "Sure! Here is my plan.\n{\"plan\":[{\"job\":\"hold\"}]}\nHope " &
    "that helps."
  check(extractJsonObject(prose){"plan"}.len == 1,
    "a prose-prefixed reply is extracted")
  var raised = false
  try:
    discard extractJsonObject("I would rather not answer that.")
  except CatchableError:
    raised = true
  check(raised, "a reply with no object at all raises")

block schema:
  var sim = rig()
  ## A crew reply containing an impostor-only job is INVALID.
  check(not parses(sim, 0, "{\"plan\":[{\"job\":\"hunt\",\"who\":\"PINK\"}]}"),
    "crew may not hunt")
  check(parses(sim, 4, "{\"plan\":[{\"job\":\"hunt\",\"who\":\"RED\"}]}"),
    "the impostor may")
  ## A plan of four steps is invalid.
  check(not parses(sim, 0, "{\"plan\":[{\"job\":\"hold\"},{\"job\":\"hold\"}," &
    "{\"job\":\"hold\"},{\"job\":\"hold\"}]}"), "four steps is too many")
  check(not parses(sim, 0, "{\"plan\":[]}"), "an empty plan is invalid")
  check(not parses(sim, 0, "{\"vote\":\"skip\"}"), "a missing plan is invalid")
  ## `mine` without `at`.
  check(not parses(sim, 0, "{\"plan\":[{\"job\":\"mine\"}]}"),
    "mine needs a seam")
  check(not parses(sim, 0, "{\"plan\":[{\"job\":\"mine\",\"at\":\"S9\"}]}"),
    "and a REAL seam")
  check(parses(sim, 0, "{\"plan\":[{\"job\":\"mine\",\"at\":\"s5\"}]}"),
    "seam ids are case-insensitive")
  ## `watch` naming a frozen cog.
  sim.cogs[2].state = csFrozen
  check(not parses(sim, 0,
    "{\"plan\":[{\"job\":\"watch\",\"who\":\"GREEN\"}]}"),
    "watch may not name a frozen cog")
  check(parses(sim, 0, "{\"plan\":[{\"job\":\"watch\",\"who\":\"PINK\"}]}"),
    "but may name an active one")
  ## Rooms.
  check(not parses(sim, 0,
    "{\"plan\":[{\"job\":\"patrol\",\"room\":\"MOON\"}]}"),
    "patrol needs a real room")
  check(parses(sim, 0, "{\"plan\":[{\"job\":\"patrol\",\"room\":\"NW\"}]}"),
    "and accepts one")

block meetingSchema:
  var sim = rig()
  sim.openMeetingForTest(mcCadence)
  sim.cogs[3].state = csEjected
  const plan = "\"plan\":[{\"job\":\"guard\"}]"
  check(not parses(sim, 0, "{" & plan & "}"),
    "a vote is required at a meeting")
  check(not parses(sim, 0, "{" & plan & ",\"vote\":\"YELLOW\"}"),
    "a vote for an ejected cog is invalid")
  check(parses(sim, 0, "{" & plan & ",\"vote\":\"skip\"}"), "skip is legal")
  check(parses(sim, 0, "{" & plan & ",\"vote\":\"PINK\"}"),
    "an active alias is legal")
  check(not parses(sim, 0, "{" & plan &
    ",\"vote\":\"PINK\",\"switch\":{\"if\":\"YELLOW\",\"to\":\"PINK\"}}"),
    "a switch naming an inactive cog is invalid")
  check(parses(sim, 0, "{" & plan &
    ",\"vote\":\"PINK\",\"switch\":{\"if\":\"tie\",\"to\":\"skip\"}}"),
    "if:tie / to:skip is legal")
  check(parses(sim, 0, "{" & plan & ",\"vote\":\"PINK\",\"switch\":null}"),
    "a null switch is no conditional at all")

block sayIsIgnoredNotRejected:
  var sim = rig("hidden-agenda-notalk")
  sim.openMeetingForTest(mcCadence)
  let reply = "{\"plan\":[{\"job\":\"guard\"}],\"vote\":\"skip\"," &
    "\"say\":\"i saw pink do it\"}"
  check(parses(sim, 0, reply),
    "a say in a no-talk variant is IGNORED, not an error")
  let decision = parseReply(sim, 0, extractJsonObject(reply))
  check(decision.say.len == 0, "and is never recorded")
  var chat = rig("hidden-agenda")
  chat.openMeetingForTest(mcCadence)
  let kept = parseReply(chat, 0, extractJsonObject(reply))
  check(kept.say == "i saw pink do it", "the chat variant keeps it")

block capsAreRuneSafe:
  var sim = rig("hidden-agenda")
  sim.openMeetingForTest(mcCadence)
  var long = "{\"plan\":[{\"job\":\"guard\"}],\"vote\":\"skip\",\"say\":\""
  for _ in 0 ..< 300:
    long.add("\\u00e9")
  long.add("\",\"hunch\":\"")
  for _ in 0 ..< 300:
    long.add("\\u4e2d")
  long.add("\",\"notes\":\"")
  for _ in 0 ..< 400:
    long.add("\\u2026")
  long.add("\"}")
  let decision = parseReply(sim, 0, extractJsonObject(long))
  check(decision.say.runeLen <= MaxSayLen, "say is capped in runes")
  check(decision.hunch.runeLen <= MaxHunchLen, "hunch is capped in runes")
  check(decision.notes.runeLen <= MaxNotesLen, "notes is capped in runes")
  check(validateUtf8(decision.notes) == -1, "and the cut is never mid-rune")

block oneBatchCarriesEveryEligibleSeat:
  ## With no credentials the client disables itself, so every seat falls back
  ## instantly and the DRIVER's bookkeeping is what is under test: one batch
  ## per decision point, every eligible seat in it, frozen seats excluded.
  var sim = rig()
  let client = disabledLlmClient()
  var prompts: seq[string]
  var kinds: seq[ScriptKind]
  for _ in 0 ..< Seats:
    prompts.add("")
    kinds.add(skNone)
  var now = 0.0
  var slept = 0.0
  proc clock(): float {.closure.} = now
  proc sleeper(seconds: float) {.closure.} =
    slept += seconds
    now += seconds
  let driver = newDecisionDriver(client, sim.config, prompts, kinds, clock,
    sleeper)
  var seats = sim.activeSeats()
  check(seats.len == Seats, "five seats at the opening")
  var decisions = driver.decide(sim, seats, "opening")
  check(decisions.len == Seats, "one decision per seat")
  for decision in decisions:
    check(decision.source == dsFallback,
      "with no credentials every seat falls back to the scripted decision")
    check(decision.plan.len >= 1, "and the fallback is a legal plan")
  sim.cogs[2].state = csFrozen
  seats = sim.activeSeats()
  check(seats.len == Seats - 1, "a frozen seat is not in the batch")
  decisions = driver.decide(sim, seats, "meeting")
  check(decisions.len == Seats - 1, "the batch shrinks with the roster")
  check(driver.batchSizes == @[Seats, Seats - 1],
    "exactly two batches were issued, of 5 then 4 requests")

block minBatchSecondsFloorsTheSpacing:
  var sim = rig()
  var config = sim.config
  config.minBatchSeconds = 14
  let client = disabledLlmClient()
  var prompts: seq[string]
  var kinds: seq[ScriptKind]
  for _ in 0 ..< Seats:
    prompts.add("")
    kinds.add(skNone)
  var now = 0.0
  proc clock(): float {.closure.} = now
  proc sleeper(seconds: float) {.closure.} = now += seconds
  let driver = newDecisionDriver(client, config, prompts, kinds, clock, sleeper)
  let seats = sim.activeSeats()
  discard driver.decide(sim, seats, "opening")
  let first = now
  discard driver.decide(sim, seats, "meeting")
  check(now - first >= 14.0,
    "batch STARTS are floored " & $config.minBatchSeconds & " s apart, got " &
    $(now - first))

block maxDecisionBatchesCaps:
  var sim = rig()
  var config = sim.config
  config.minBatchSeconds = 0
  config.maxDecisionBatches = 3
  let client = disabledLlmClient()
  var prompts: seq[string]
  var kinds: seq[ScriptKind]
  for _ in 0 ..< Seats:
    prompts.add("")
    kinds.add(skNone)
  proc clock(): float {.closure.} = 0.0
  proc sleeper(seconds: float) {.closure.} = discard
  let driver = newDecisionDriver(client, config, prompts, kinds, clock, sleeper)
  let seats = sim.activeSeats()
  for round in 0 ..< 3:
    discard driver.decide(sim, seats, "meeting")
  check(driver.batchSizes.len == 3, "three batches were issued")
  let after = driver.decide(sim, seats, "meeting")
  check(driver.batchSizes.len == 3, "and never a fourth")
  for decision in after:
    check(decision.source == dsBudget,
      "past the cap every seat reuses its previous decision as \"budget\"")

block theDeadlineSettlesEarly:
  var config = baseConfig(4)
  config.impostorSlot = 4
  var sim = initSim(config)
  var now = 0.0
  proc clock(): float {.closure.} = now
  proc decide(view: var Sim, seats: seq[int], cause: string):
      seq[Decision] {.closure.} =
    var decisions: seq[Decision]
    now += 30.0
    for seat in seats:
      decisions.add(scriptedDecision(view, seat, skMiner, view.inMeeting))
    decisions
  sim.runEpisode(decide, clock, 10.0)
  sim.finalise()
  check(sim.reason == "deadline", "the play deadline settles the episode")
  check(sim.ending == "deadline", "with the deadline ending")
  for score in sim.scores:
    check(score == 0, "and all scores 0")

echo "test_llm: ok"
