## tests/test_llm.nim — the decision layer.
##
## The transport itself is never called here: what is tested is the tolerant
## extraction, the strict reply schema, the batch shape, the wall-clock floor,
## the batch cap and the play deadline.

import std/[json, strutils, unicode]
import curly
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

block theCompactJobFormTheSystemPromptTeachesIsHonoured:
  ## The system prompt documents `mine at:<seam>` / `watch who:<cog>` /
  ## `patrol room:<r>`, so a model that writes that string into "job" is
  ## obeying our own instructions. Rejecting it burned both attempts and put
  ## the seat on the scripted baseline (hosted league 2026-08-26: 10 of round
  ## 3's 14 attempt-failures were `unknown job: mine at:s2` and the corrective
  ## `mine needs at: ... got ''`).
  var sim = rig()
  proc plan(sim: Sim, slot: int, text: string): seq[PlanStep] =
    parseReply(sim, slot, extractJsonObject(text)).plan

  let compactMine = plan(sim, 0, "{\"plan\":[{\"job\":\"mine at:S2\"}]}")
  let canonicalMine = plan(sim, 0,
    "{\"plan\":[{\"job\":\"mine\",\"at\":\"S2\"}]}")
  check(compactMine == canonicalMine,
    "mine at:S2 parses to the same plan as the sibling-key form")
  check(compactMine[0].job == jkMine and compactMine[0].at == "S2",
    "and it is mine at S2")
  check(plan(sim, 0, "{\"plan\":[{\"job\":\"mine at:s2\"}]}") == canonicalMine,
    "the compact argument is case-insensitive, like the sibling key")

  check(plan(sim, 0, "{\"plan\":[{\"job\":\"watch who:PINK\"}]}") ==
    plan(sim, 0, "{\"plan\":[{\"job\":\"watch\",\"who\":\"PINK\"}]}"),
    "watch who:PINK matches its canonical form")
  check(plan(sim, 0, "{\"plan\":[{\"job\":\"patrol room:NW\"}]}") ==
    plan(sim, 0, "{\"plan\":[{\"job\":\"patrol\",\"room\":\"NW\"}]}"),
    "patrol room:NW matches its canonical form")
  ## Slot 4 is the impostor in this rig.
  check(plan(sim, 4, "{\"plan\":[{\"job\":\"hunt who:GREEN\"}]}") ==
    plan(sim, 4, "{\"plan\":[{\"job\":\"hunt\",\"who\":\"GREEN\"}]}"),
    "hunt who:GREEN matches its canonical form")
  check(plan(sim, 4, "{\"plan\":[{\"job\":\"strike who:RED\"}]}") ==
    plan(sim, 4, "{\"plan\":[{\"job\":\"strike\",\"who\":\"RED\"}]}"),
    "strike who:RED matches its canonical form")
  check(plan(sim, 4, "{\"plan\":[{\"job\":\"lurk room:SE\"}]}") ==
    plan(sim, 4, "{\"plan\":[{\"job\":\"lurk\",\"room\":\"SE\"}]}"),
    "lurk room:SE matches its canonical form")

  ## Tolerance is only for the documented form: nothing else is loosened.
  check(not parses(sim, 0, "{\"plan\":[{\"job\":\"teleport\"}]}"),
    "a genuinely unknown job is still invalid")
  check(not parses(sim, 0, "{\"plan\":[{\"job\":\"scuttle at:S2\"}]}"),
    "and so is an unknown job carrying a compact argument")
  check(not parses(sim, 0, "{\"plan\":[{\"job\":\"mine at:S9\"}]}"),
    "a compact argument still has to name a real seam")
  check(not parses(sim, 0, "{\"plan\":[{\"job\":\"hunt who:PINK\"}]}"),
    "and crew still may not hunt in the compact form")

  ## The other half of the fix: the reply schema in the prompt now spells the
  ## sibling keys, so the model is never left to guess from `{"job":...}`.
  let hint = userPrompt(sim, 0, "", "opening")
  check("{\"job\":\"mine\",\"at\":\"S2\"}" in hint,
    "the schema hint spells mine's sibling key")
  check("{\"job\":\"patrol\",\"room\":\"NW\"}" in hint, "and patrol's")
  check("{\"job\":\"watch\",\"who\":\"BLUE\"}" in hint,
    "and watch's, naming a cog that is active now and is not this seat")
  check("{\"job\":\"lurk\",\"room\":\"SE\"}" in userPrompt(sim, 4, "",
    "opening"), "the impostor's jobs are spelled out too")
  check(not ("{\"job\":\"lurk\"" in hint),
    "and a crew seat is never shown an impostor-only job")
  check(parses(sim, 0, "{\"plan\":[{\"job\":\"watch\",\"who\":\"BLUE\"}]}"),
    "every step the hint shows is itself a valid step")

block aHalfWrittenSwitchDegradesRatherThanInvalidating:
  ## `switch` is optional. Throwing away a whole reply -- plan, vote and all --
  ## because the model wrote one of the two keys cost real decisions in the
  ## hosted league (round 2, 2026-08-26: `switch needs both "if" and "to"`).
  var sim = rig()
  sim.openMeetingForTest(mcCadence)
  const plan = "\"plan\":[{\"job\":\"guard\"}]"
  for half in ["{\"if\":\"tie\"}", "{\"to\":\"skip\"}", "{}"]:
    let reply = "{" & plan & ",\"vote\":\"PINK\",\"switch\":" & half & "}"
    check(parses(sim, 0, reply),
      "a one-sided switch " & half & " does not invalidate the reply")
    let decision = parseReply(sim, 0, extractJsonObject(reply))
    check(decision.switchIf.len == 0 and decision.switchTo.len == 0,
      "it degrades to no conditional at all")
    check(decision.vote == "PINK" and decision.plan.len == 1,
      "and the plan and the vote survive")

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
  let driver = newDecisionDriver(client, sim.config, prompts, kinds, newSeq[bool](Seats), clock,
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
  let driver = newDecisionDriver(client, config, prompts, kinds, newSeq[bool](Seats), clock, sleeper)
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
  let driver = newDecisionDriver(client, config, prompts, kinds, newSeq[bool](Seats), clock, sleeper)
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

block frozenAndEjectedSeatsAreToldTheyCannotAct:
  ## docs/POLICIES.md and the manifest's policies page both promise that a
  ## frozen or ejected seat receives a frame with `canAct: false`; seatView
  ## emitted no such key and left the seat to infer it from `you.state`.
  var sim = rig()
  var frame = seatView(sim, 0, "opening")
  check(frame{"canAct"}.getBool() == true,
    "an active seat in play can act")
  check(frame{"canVote"}.getBool() == false,
    "and cannot vote outside a meeting")

  sim.openMeetingForTest(mcCadence)
  frame = seatView(sim, 0, "meeting")
  check(frame{"canAct"}.getBool() and frame{"canVote"}.getBool(),
    "an active seat in a meeting can do both")

  sim.cogs[1].state = csFrozen
  sim.cogs[2].state = csEjected
  for slot in [1, 2]:
    let dead = seatView(sim, slot, "meeting")
    check(dead{"canAct"}.getBool() == false,
      "a " & $sim.cogs[slot].state & " seat is told canAct: false")
    check(dead{"canVote"}.getBool() == false, "and canVote: false")
    check(dead{"you"}{"state"}.getStr() in ["csFrozen", "csEjected",
      "frozen", "ejected"], "and still carries you.state")
  ## And that is the truth: neither seat is in the batch.
  let seats = sim.activeSeats()
  check(1 notin seats and 2 notin seats,
    "the flags agree with activeSeats()")

block theRetryBatchAndTheFallbackAreDriven:
  ## Every driver block above constructs a client with no credentials, which
  ## short-circuits to the scripted fallback BEFORE the batch loop -- so
  ## nothing exercised the retry batch, dsRetry was never produced anywhere,
  ## and the transport ladder (timeout, 429, 403, junk) was untested.
  ## `stubbedLlmClient` installs a batch sender in place of curl.

  proc reply(text: string): Response =
    Response(code: 200, body: $(%*{
      "stop_reason": "end_turn",
      "content": [{"type": "text", "text": text}]
    }))

  let good = """{"plan":[{"job":"guard"}],"vote":"skip"}"""

  ## (1) A transport error on the first batch, a good reply on the second:
  ## the seat is retried ONCE, inside the same decision point, and the
  ## decision is recorded as "retry" so phase 60 can count it.
  block:
    var sim = rig()
    var batches = 0
    var sawHint = false
    proc send(batch: RequestBatch, timeoutSeconds: int):
        ResponseBatch {.closure.} =
      batches.inc
      for i in 0 ..< batch.len:
        if "Your previous reply was invalid" in batch[i].body:
          sawHint = true
        if batches == 1:
          result.add((Response(), "connection timed out"))
        else:
          result.add((reply(good), ""))
    let client = stubbedLlmClient(send, "")
    var prompts: seq[string]
    var kinds: seq[ScriptKind]
    for _ in 0 ..< Seats:
      prompts.add("play well")
      kinds.add(skNone)
    let seats = sim.activeSeats()
    let decisions = client.decideAll(sim, seats, prompts, kinds, newSeq[bool](Seats), "opening")
    check(batches == 2, "a first-attempt failure issues exactly ONE more " &
      "batch, got " & $batches)
    check(sawHint, "and the retry batch carries the retry hint")
    check(decisions.len == seats.len, "one decision per seat")
    for decision in decisions:
      check(decision.source == dsRetry,
        "a decision won on the second attempt is recorded as retry, got " &
        $decision.source)
      check(decision.plan.len >= 1, "and is a legal plan")

  ## (2) A 429 on both attempts: two batches, then the scripted fallback,
  ## recorded as such. decideAll never raises.
  block:
    var sim = rig()
    var batches = 0
    proc send(batch: RequestBatch, timeoutSeconds: int):
        ResponseBatch {.closure.} =
      batches.inc
      for i in 0 ..< batch.len:
        result.add((Response(code: 429, body: "slow down"), ""))
    let client = stubbedLlmClient(send, "")
    var prompts: seq[string]
    var kinds: seq[ScriptKind]
    for _ in 0 ..< Seats:
      prompts.add("play well")
      kinds.add(skNone)
    let seats = sim.activeSeats()
    let decisions = client.decideAll(sim, seats, prompts, kinds, newSeq[bool](Seats), "opening")
    check(batches == 2, "a 429 is retried once and then given up on, got " &
      $batches & " batches")
    for decision in decisions:
      check(decision.source == dsFallback,
        "and the fallback is RECORDED, got " & $decision.source)
      check(decision.plan.len >= 1, "and is a legal plan")

  ## (3) A 403 disables the client outright: one batch, every seat falls back,
  ## and every LATER decision point goes straight to the fallback.
  block:
    var sim = rig()
    var batches = 0
    proc send(batch: RequestBatch, timeoutSeconds: int):
        ResponseBatch {.closure.} =
      batches.inc
      for i in 0 ..< batch.len:
        result.add((Response(code: 403, body: "no"), ""))
    let client = stubbedLlmClient(send, "")
    var prompts: seq[string]
    var kinds: seq[ScriptKind]
    for _ in 0 ..< Seats:
      prompts.add("play well")
      kinds.add(skNone)
    let seats = sim.activeSeats()
    var decisions = client.decideAll(sim, seats, prompts, kinds, newSeq[bool](Seats), "opening")
    check(batches == 1, "a 403 stops the ladder inside the first batch")
    check(client.disabled, "and disables the client")
    for decision in decisions:
      check(decision.source == dsFallback, "every seat falls back")
    decisions = client.decideAll(sim, seats, prompts, kinds, newSeq[bool](Seats), "meeting")
    check(batches == 1, "a disabled client never issues another batch")
    for decision in decisions:
      check(decision.source == dsFallback, "and every later seat is scripted")

  ## (4) Junk that is not JSON at all, twice: two batches, then the fallback.
  block:
    var sim = rig()
    var batches = 0
    proc send(batch: RequestBatch, timeoutSeconds: int):
        ResponseBatch {.closure.} =
      batches.inc
      for i in 0 ..< batch.len:
        result.add((reply("I would rather not say."), ""))
    let client = stubbedLlmClient(send, "")
    var prompts: seq[string]
    var kinds: seq[ScriptKind]
    for _ in 0 ..< Seats:
      prompts.add("play well")
      kinds.add(skNone)
    let seats = sim.activeSeats()
    let decisions = client.decideAll(sim, seats, prompts, kinds, newSeq[bool](Seats), "opening")
    check(batches == 2, "junk is retried once")
    for decision in decisions:
      check(decision.source == dsFallback,
        "and then falls back, got " & $decision.source)
      check(decision.plan.len >= 1, "with a legal plan")

  ## (5) A seat that answers on the first attempt is NOT in the retry batch:
  ## only the seats that failed are retried.
  block:
    var sim = rig()
    var sizes: seq[int]
    proc send(batch: RequestBatch, timeoutSeconds: int):
        ResponseBatch {.closure.} =
      sizes.add(batch.len)
      for i in 0 ..< batch.len:
        ## Tag is the index into `seats`; seat 0 answers immediately.
        if batch[i].tag == "0" or sizes.len > 1:
          result.add((reply(good), ""))
        else:
          result.add((Response(), "connection reset"))
    let client = stubbedLlmClient(send, "")
    var prompts: seq[string]
    var kinds: seq[ScriptKind]
    for _ in 0 ..< Seats:
      prompts.add("play well")
      kinds.add(skNone)
    let seats = sim.activeSeats()
    let decisions = client.decideAll(sim, seats, prompts, kinds, newSeq[bool](Seats), "opening")
    check(sizes == @[Seats, Seats - 1],
      "the retry batch carries only the seats that failed, got " & $sizes)
    check(decisions[0].source == dsLlm,
      "the seat that answered first time is recorded as llm")
    for index in 1 ..< decisions.len:
      check(decisions[index].source == dsRetry,
        "and the rest as retry")

block jevSharesTheParallelDecisionBatch:
  var sim = rig()
  var batches = 0
  proc send(batch: RequestBatch, timeoutSeconds: int):
      ResponseBatch {.closure.} =
    batches.inc
    check(batch.len == 2, "Jev and prompt seats share one batch")
    check(batch[0].url.endsWith("/v1/systemone"),
      "Jev uses the System One endpoint")
    check(batch[1].url.endsWith("/v1/messages"),
      "the prompt seat keeps its Anthropic endpoint")
    let jevRequest = parseJson(batch[0].body)
    let criteria = jevRequest["questions"]["decision"]["criteria"]
    check(criteria.hasKey("miner") and criteria.hasKey("guard"),
      "Jev sees complete bounded plans")
    check(parseJson(jevRequest["state"].getStr())["role"].getStr() ==
      "crew",
      "Jev receives its own role")
    var probabilities = newJObject()
    for name, _ in criteria.pairs:
      probabilities[name] = %(if name == "guard": 1.0 else: 0.0)
    result.add((Response(code: 200, body: $(%*{
      "model": "stub-jev", "usage": {"input_tokens": 10,
        "output_tokens": 2},
      "answers": {"decision": {"type": "choice", "choice": "guard",
        "confidence": 1.0, "probabilities": probabilities}}
    })), ""))
    result.add((Response(code: 200, body: $(%*{
      "stop_reason": "end_turn",
      "content": [{"type": "text",
        "text": "{\"plan\":[{\"job\":\"guard\"}]}"}]
    })), ""))
  let client = stubbedLlmClient(send, "https://jev.example")
  let seats = sim.activeSeats()
  var prompts = newSeq[string](Seats)
  var kinds = uniformKinds(skMiner)
  var jev = newSeq[bool](Seats)
  kinds[0] = skNone
  kinds[1] = skNone
  jev[0] = true
  let decisions = client.decideAll(sim, seats, prompts, kinds, jev,
    "opening")
  check(batches == 1, "one parallel batch completes both model seats")
  check(decisions[0].source == dsJev and
    decisions[0].plan[0].job == jkGuard, "Jev selects the guard plan")
  check(decisions[1].source == dsLlm, "prompt seat also resolves")

echo "test_llm: ok"
