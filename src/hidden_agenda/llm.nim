## Model-backed decision making for Hidden Agenda: the per-seat observation,
## the prompts, the reply schema, and ONE parallel batch per decision point.
##
## Forked from `cogame-bullwhip/src/bullwhip/llm.nim`. Hidden Agenda is a
## simultaneous-decision game with exactly two kinds of decision point — the
## episode opening and every meeting open — and at each one EVERY eligible
## seat's request goes out together in one `curly.makeRequests` batch. Seats are
## never queried sequentially; that is what blows the play budget.
##
## Prompt-model credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With none of them the client disables itself on the first discovery, every
## decision falls back instantly with no network wait, and offline
## certification still completes deterministically. That fallback is
## load-bearing.

import std/[json, os, strutils, times]
import bitworld/runtime
import curly
import sim_types, station, sim_config, sim_state, vision, kernel, sim,
  scripted

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  RetryHint = "\nYour previous reply was invalid. Respond with ONLY the " &
    "requested JSON object, using one of the listed job names, a seam id " &
    "from the list, an alias that is active right now, and a vote that is " &
    "an active alias or the word skip."

type
  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  BatchSender* = proc (batch: RequestBatch, timeoutSeconds: int):
    ResponseBatch {.closure.}
    ## The seam the tests stub. `nil` in production, where the batch goes to
    ## `client.curl.makeRequests`; a test installs one to drive a transport
    ## error, a 429, a 403 or a junk body through `decideAll` without a
    ## socket. There is no other way to reach the retry batch: a client with
    ## no credentials short-circuits to the scripted fallback before the loop.

  LlmClient* = ref object
    curl: Curly
    sendBatch*: BatchSender
    transport: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    jevEndpoint*: string
    jevKey: string
    jevModel: string
    jevTrajectoryId: string
    jevInputTokens*: int
    jevOutputTokens*: int
    model*: string
    maxOutputTokens*: int
    timeoutSeconds*: int
    disabled*: bool

proc disabledLlmClient*(): LlmClient =
  ## A client that is known to have no credentials. The production path reaches
  ## this state through `newLlmClient` when the ladder finds nothing; the tests
  ## construct it directly so no network is ever touched.
  LlmClient(transport: ltNone, disabled: true, maxOutputTokens: 900,
    timeoutSeconds: 14)

proc stubbedLlmClient*(send: BatchSender, jevEndpoint: string): LlmClient =
  ## A client whose batch transport is `send`. Nothing here opens a socket and
  ## `curl` is never touched, which is what lets tests/test_llm.nim drive
  ## `decideAll`'s retry batch, its 429 / 403 / junk-reply handling and its
  ## fallback recording. Production never calls this.
  LlmClient(transport: ltAnthropic, disabled: false, apiKey: "stub",
    model: "stub", maxOutputTokens: 900, timeoutSeconds: 14,
    jevEndpoint: jevEndpoint, jevModel: "stub-jev", sendBatch: send)

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "hidden-agenda llm: failed to fetch ANTHROPIC_API_KEY_URI: ",
      error.msg
    result = ""

proc bedrockModelIds*(): seq[string] =
  ## HAIKU ONLY. The sonnet inference profiles time out on every sidecar call
  ## and turn one throttle into a cascade of scripted fallbacks (raid round 2,
  ## 2026-08-23), so there is exactly one candidate. BEDROCK_MODEL overrides.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @["us.anthropic.claude-haiku-4-5-20251001-v1:0"]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "hidden-agenda llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds
  )
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  let captureUrl = getEnv("METTA_CAPTURE_URL").strip()
  let typesafeKey = getEnv("TYPESAFE_API_KEY").strip()
  if bedrockEndpoint.len > 0:
    result.jevEndpoint = bedrockEndpoint.strip(chars = {'/'}, leading = false)
    result.jevModel = "typesafe/jev-1.13"
  elif captureUrl.len > 0:
    result.jevEndpoint = captureUrl.strip(chars = {'/'}, leading = false)
    result.jevKey = getEnv("METTA_CAPTURE_KEY").strip()
    if result.jevKey.len == 0:
      raise newException(HiddenAgendaError, "METTA_CAPTURE_KEY is required")
    result.jevModel = "typesafe/jev-1.13"
    result.jevTrajectoryId = "hidden-agenda-jev-" & $config.seed
  elif typesafeKey.len > 0:
    result.jevEndpoint = getEnv("TYPESAFE_BASE_URL",
      "https://api.typesafe.ai").strip(chars = {'/'}, leading = false)
    result.jevKey = typesafeKey
    result.jevModel = getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "hidden-agenda llm: bedrock transport, url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "hidden-agenda llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    if result.jevEndpoint.len > 0:
      result.curl = newCurly()
      echo "hidden-agenda llm: Jev transport enabled; prompt seats scripted"
    else:
      echo "hidden-agenda llm: no LLM credentials; every seat plays scripted"

# ---------------------------------------------------------------------------
# The observation. Every number here is visible to that seat; NOTHING else is.
# No player frame ever carries another seat's role, plan, hunch or notes.
# ---------------------------------------------------------------------------

proc planJson(plan: seq[PlanStep]): JsonNode =
  result = newJArray()
  for step in plan:
    var node = %*{"job": $step.job}
    if step.at.len > 0: node["at"] = %step.at
    if step.who.len > 0: node["who"] = %step.who
    if step.room.len > 0: node["room"] = %step.room
    result.add(node)

proc stationBlock(sim: Sim): JsonNode =
  var rooms = newJArray()
  for room in RoomTable:
    rooms.add(%room.id)
  var seams = newJArray()
  for seam in SeamTable:
    seams.add(%*{"id": seam.id, "room": seam.room, "cell": [seam.x, seam.y]})
  var grate = newJArray()
  for cell in grateCells():
    grate.add(%[cell[0], cell[1]])
  %*{
    "deposits": sim.deposits, "depositTarget": sim.config.depositTarget,
    "map": "vault", "cols": MapCols, "rows": MapRows,
    "rooms": rooms, "seams": seams, "grate": grate
  }

proc meetingHistoryJson(sim: Sim): JsonNode =
  result = newJArray()
  for record in sim.meetings:
    var votes = newJObject()
    var switched = newJObject()
    var says = newJObject()
    for slot in 0 ..< Seats:
      if record.votes[slot].len > 0:
        votes[Aliases[slot]] = %record.votes[slot]
      if record.switched[slot].len > 0:
        switched[Aliases[slot]] = %record.switched[slot]
      if record.says[slot].len > 0:
        says[Aliases[slot]] = %record.says[slot]
    result.add(%*{
      "n": record.n, "t": record.t, "cause": $record.cause,
      "votes": votes, "switched": switched, "outcome": record.outcome,
      "ejected": (if record.ejected.len > 0: %record.ejected else: newJNull()),
      "say": says
    })

proc seatView*(sim: Sim, slot: int, cause: string): JsonNode =
  ## The `state` frame. A seat sees only aliases: no policy name, player name,
  ## account or model name reaches it, and no other seat's role.
  let cog = sim.cogs[slot]
  var you = %*{
    "cell": [cog.x, cog.y], "facing": $cog.facing, "carrying": cog.carry,
    "carryCap": sim.config.carryCap, "state": $cog.state,
    "mined": cog.mined, "deposited": cog.deposited,
    "lastPlan": planJson(cog.plan)
  }
  if cog.role == rImpostor:
    var canFreeze = newJArray()
    for alias in freezeTargets(sim, slot):
      canFreeze.add(%alias)
    var seenBy = newJArray()
    for alias in cog.lastFakeSeenBy:
      seenBy.add(%alias)
    you["freezeCooldown"] = %cog.freezeCooldown
    you["freezeCooldownTicks"] = %sim.config.freezeCooldownTicks
    you["freezeRange"] = %sim.config.freezeRange
    you["freezes"] = %cog.freezes
    you["fakeDeposits"] = %cog.fakeDeposits
    you["lastFakeDepositSeenBy"] = seenBy
    you["canFreezeNow"] = canFreeze

  var roster = newJArray()
  for other in 0 ..< Seats:
    roster.add(%*{"alias": Aliases[other], "state": $sim.cogs[other].state})

  var inView = newJArray()
  for other in 0 ..< Seats:
    if not seesCog(sim.config, cog, sim.cogs[other]):
      continue
    let target = sim.cogs[other]
    inView.add(%*{
      "alias": Aliases[other], "cell": [target.x, target.y],
      "facing": $target.facing, "doing": doingOf(target),
      "carrying": target.carry
    })

  var lastSeen = newJObject()
  var together = newJObject()
  for other in 0 ..< Seats:
    if other == slot:
      continue
    together[Aliases[other]] = %cog.togetherTicks[other]
    if not cog.lastSeen[other].valid:
      continue
    lastSeen[Aliases[other]] = %*{
      "t": cog.lastSeen[other].t,
      "cell": [cog.lastSeen[other].cell[0], cog.lastSeen[other].cell[1]],
      "doing": cog.lastSeen[other].doing, "room": cog.lastSeen[other].room
    }

  var bodies = newJArray()
  for body in cog.bodies:
    bodies.add(%*{"alias": body.alias,
      "cell": [body.cell[0], body.cell[1]], "room": body.room,
      "firstSeenTick": body.firstSeenTick})

  var witnessed = newJArray()
  for note in cog.witnessed:
    witnessed.add(%*{"t": note.t, "freezer": note.freezer,
      "victim": note.victim, "cell": [note.cell[0], note.cell[1]],
      "sawFreezer": note.sawFreezer, "sawVictim": note.sawVictim})

  var seamsSeen = newJArray()
  for entry in cog.seamsSeen:
    seamsSeen.add(%*{"id": entry.id, "gems": entry.gems, "t": entry.t})

  let channel =
    if sim.config.chat:
      "you get ONE short line each meeting, revealed to everyone at once"
    else:
      "there is NO chat in this variant. Your vote is your only signal."

  ## A frozen or ejected seat still receives every frame -- the socket stays
  ## open for the whole episode -- but it is in no decision batch and its reply
  ## is read by nobody. Say so IN THE FRAME rather than leaving the seat to
  ## infer it from `you.state`: docs/POLICIES.md and the manifest's policies
  ## page both promise these two flags.
  let acting = cog.state == csActive
  result = %*{
    "type": "state", "protocol": Protocol, "slot": slot,
    "role": $cog.role, "name": Aliases[slot],
    "tick": sim.tick, "maxTicks": sim.config.maxTicks,
    "decision": sim.decisions, "cause": cause,
    "phase": (if sim.inMeeting: "meeting" else: "play"),
    "canAct": acting,
    "canVote": acting and sim.inMeeting,
    "chat": sim.config.chat,
    "you": you, "station": stationBlock(sim), "roster": roster,
    "inView": inView, "lastSeen": lastSeen, "togetherTicks": together,
    "bodies": bodies, "youWitnessed": witnessed, "seamsSeen": seamsSeen,
    "meetings": meetingHistoryJson(sim),
    "notes": cog.notes,
    "vision": {
      "visionRadius": sim.config.visionRadius,
      "awarenessRadius": sim.config.awarenessRadius,
      "cone": "90 degrees on your facing",
      "facingRule": "you face where you walk; mining faces the seam; " &
        "watch faces your target; guard sweeps"
    },
    "rules": {
      "role":
        if cog.role == rImpostor:
          "you are the IMPOSTOR. The other four cogs are all crew. Your " &
          "deposits are destroyed and never move the counter."
        else:
          "you are CREW. Exactly ONE of the other four cogs is the impostor.",
      "win": "crew win at " & $sim.config.depositTarget & " deposits or by " &
        "ejecting the impostor; the impostor wins when only one crewmate is " &
        "left; tick " & $sim.config.maxTicks & " is a 0-0 tie",
      "freeze": "the impostor freezes at range " & $sim.config.freezeRange &
        " with line of sight, then cannot freeze again for " &
        $sim.config.freezeCooldownTicks & " ticks; frozen crew stay on the " &
        "map and never act again",
      "meeting": "meetings open every " & $sim.config.meetingCadenceTicks &
        " ticks and IMMEDIATELY when a freeze happens inside someone's " &
        "field of view",
      "vote": "the cog with strictly the most votes is ejected; a tie or a " &
        "skip majority ejects nobody",
      "deposit": "only a crewmate's deposit moves the counter",
      "channel": channel,
      "mineTicks": sim.config.mineTicks,
      "carryCap": sim.config.carryCap,
      "moveCooldown": sim.config.moveCooldown,
      "freezeRange": sim.config.freezeRange
    }
  }

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------

proc jobList(role: Role): string =
  if role == rImpostor:
    "mine | deposit | watch | patrol | guard | hold | hunt | strike | lurk"
  else:
    "mine | deposit | watch | patrol | guard | hold"

proc systemPrompt*(sim: Sim, slot: int): string =
  let cog = sim.cogs[slot]
  result.add("You are " & Aliases[slot] & ", one of five cogs mining a " &
    "sealed station. Four are CREW and exactly ONE is the IMPOSTOR. ")
  if cog.role == rImpostor:
    result.add("YOU ARE THE IMPOSTOR: the other four are all crew. ")
  else:
    result.add("YOU ARE CREW: exactly one of the other four is the " &
      "impostor. ")
  result.add("You cannot see anyone else's role, ever.\n\n")
  result.add("""THE STATION. A 27x19 grid: six vault/gallery rooms each with ONE
doorway and one gem seam (S1..S6), a 3x3 GRATE in the middle, walls and seams
block movement and sight. Crew mine gems and carry at most """ &
    $sim.config.carryCap & """ to the grate. """ &
    $sim.config.depositTarget & """ deposits wins for the crew. ONLY a
crewmate's deposit moves the counter: an impostor's gem is destroyed and the
counter does not move, which anyone standing at the grate can see.

YOUR EYES. You see a 90-degree cone on your facing out to """ &
    $sim.config.visionRadius & """ cells, plus """ &
    $sim.config.awarenessRadius & """ cells in every direction. Walls and
seams block it. VISION IS NOT MUTUAL: somebody standing behind you sees you
and you do not see them. That is the risk the beam carries.

THE BEAM. The impostor freezes one crewmate at range """ &
    $sim.config.freezeRange & """ with line of sight, then cannot freeze
again for """ & $sim.config.freezeCooldownTicks & """ ticks. A frozen
crewmate stays on the floor as evidence and never acts or votes again. The
impostor wins when only ONE crewmate is left.

MEETINGS. One opens every """ & $sim.config.meetingCadenceTicks &
    """ ticks, and IMMEDIATELY when a freeze happens inside somebody's field
of view. Every active seat votes once; the cog with strictly the most votes
is ejected; a tie, or more skips than the top count, ejects nobody. Ejecting
the impostor ends the game for the crew.

HOW YOU ACT. You do NOT drive the cog tick by tick. You choose up to """ &
    $sim.config.planSteps & """ JOBS and a deterministic kernel walks them for
you, tick by tick, until the next meeting. Jobs for you: """ &
    jobList(cog.role) & """.
  mine at:<seam>   walk to that seam and mine until your hands are full
  deposit          walk to the grate and drop what you carry
  watch who:<cog>  stand 3-5 cells away and keep your cone on that cog
  patrol room:<r>  sweep a room's four corners looking for bodies
  guard            stand on the grate sweeping your cone, auditing the counter
  hold             stand still""")
  if cog.role == rImpostor:
    result.add("""
  hunt who:<cog>   close and fire only when your own view is empty
  strike who:<cog> close and fire the instant it is legal, witnesses or not
  lurk room:<r>    wait in a room's far corner facing the doorway""")
  result.add("""

The other four seats are different policies deciding SIMULTANEOUSLY: nobody
sees your plan, your vote or your line before submitting their own. Your
"hunch" is shown only to spectators and your "notes" only to you.""")
  if not sim.config.chat:
    result.add("\nTHERE IS NO CHAT IN THIS VARIANT. Your vote is your only " &
      "signal.")
  result.add("""

OUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no analysis, no
explanation, no markdown fences, no text before or after the object. Your reply
must begin with the character { and end with }.""")

proc pad(text: string, width: int): string =
  result = text
  while result.len < width:
    result.add(' ')

proc userPrompt*(sim: Sim, slot: int, prompt, cause: string): string =
  let cog = sim.cogs[slot]
  var lines: seq[string]
  lines.add("DEPOSITS " & $sim.deposits & "/" & $sim.config.depositTarget &
    " \u00b7 TICK " & $sim.tick & "/" & $sim.config.maxTicks &
    (if sim.inMeeting: " \u00b7 MEETING " & $sim.meetingNumber & " (" &
      cause & ")" else: " \u00b7 OPENING PLAN"))
  lines.add("")
  var roster: seq[string]
  for other in 0 ..< Seats:
    roster.add(Aliases[other] & " " & $sim.cogs[other].state)
  lines.add("ROSTER: " & roster.join(" | "))
  lines.add("YOU: " & Aliases[slot] & " (" & $cog.role & ") at [" & $cog.x &
    "," & $cog.y & "] facing " & $cog.facing & ", carrying " & $cog.carry &
    "/" & $sim.config.carryCap & ", in " & roomName(roomOf(cog.x, cog.y)))
  if cog.role == rImpostor:
    let targets = freezeTargets(sim, slot)
    lines.add("BEAM: cooldown " & $cog.freezeCooldown & " \u00b7 legal " &
      "targets right now: " &
      (if targets.len > 0: targets.join(", ") else: "(none)"))

  lines.add("")
  lines.add("IN VIEW  | cell    | facing | doing      | carrying")
  var anyView = false
  for other in 0 ..< Seats:
    if not seesCog(sim.config, cog, sim.cogs[other]):
      continue
    anyView = true
    let target = sim.cogs[other]
    lines.add(pad(Aliases[other], 9) & "| " &
      pad("[" & $target.x & "," & $target.y & "]", 8) & "| " &
      pad($target.facing, 7) & "| " & pad(doingOf(target), 11) & "| " &
      $target.carry)
  if not anyView:
    lines.add("(nobody in your cone)")

  lines.add("")
  lines.add("LAST SEEN | tick | room             | doing      | together")
  for other in 0 ..< Seats:
    if other == slot:
      continue
    let seen = cog.lastSeen[other]
    lines.add(pad(Aliases[other], 10) & "| " &
      pad((if seen.valid: $seen.t else: "never"), 5) & "| " &
      pad((if seen.valid: roomName(seen.room) else: "-"), 17) & "| " &
      pad((if seen.valid: seen.doing else: "-"), 11) & "| " &
      $cog.togetherTicks[other])

  if cog.bodies.len > 0:
    var bodies: seq[string]
    for body in cog.bodies:
      bodies.add(body.alias & " frozen in " & roomName(body.room) & " at t" &
        $body.firstSeenTick)
    lines.add("")
    lines.add("BODIES: " & bodies.join("; "))

  if cog.witnessed.len > 0:
    lines.add("")
    lines.add("YOU SAW:")
    for note in cog.witnessed:
      lines.add("  t" & $note.t & " " &
        (if note.sawFreezer: note.freezer else: "somebody") & " froze " &
        note.victim & " in " & roomName(roomOf(note.cell[0], note.cell[1])) &
        (if note.sawFreezer: " - you saw the freezer"
         else: " - you did not see who did it"))

  lines.add("")
  lines.add("SEAMS (as you last saw them): ")
  for seam in SeamTable:
    var gems = "?"
    var seenAt = "never"
    for entry in cog.seamsSeen:
      if entry.id == seam.id:
        gems = $entry.gems
        seenAt = "t" & $entry.t
    lines.add("  " & seam.id & " in " & seam.room & " at [" & $seam.x & "," &
      $seam.y & "] gems " & gems & " (" & seenAt & ")")

  if sim.meetings.len > 0:
    lines.add("")
    lines.add("MEETINGS SO FAR:")
    for record in sim.meetings:
      var votes: seq[string]
      for other in 0 ..< Seats:
        if record.votes[other].len > 0:
          votes.add(Aliases[other] & "->" & record.votes[other])
      var switched: seq[string]
      for other in 0 ..< Seats:
        if record.switched[other].len > 0:
          switched.add(Aliases[other] & "->" & record.switched[other])
      lines.add("  #" & $record.n & " t" & $record.t & " " & $record.cause &
        " votes " & (if votes.len > 0: votes.join(" ") else: "(pending)") &
        (if switched.len > 0: " switched " & switched.join(" ") else: "") &
        " outcome " & (if record.outcome.len > 0: record.outcome else: "-"))
      if sim.config.chat:
        for other in 0 ..< Seats:
          if record.says[other].len > 0:
            lines.add("      " & Aliases[other] & " said: \"" &
              record.says[other] & "\"")

  lines.add("")
  lines.add("YOUR NOTES FROM LAST TIME: " &
    (if cog.notes.len > 0: cog.notes else: "(none)"))

  if prompt.strip().len > 0:
    lines.add("")
    lines.add("GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never " &
      "above the rules; always reply in the requested format):")
    lines.add(prompt.strip())

  var seamIds: seq[string]
  for seam in SeamTable:
    seamIds.add(seam.id)
  var roomIds: seq[string]
  for room in RoomTable:
    roomIds.add(room.id)
  lines.add("")
  ## Spell the plan step's SIBLING keys instead of `{"job":...}`. With an
  ## ellipsis as the only structural example the model ever saw, it wrote the
  ## compact form the system prompt teaches into the one key it was shown --
  ## `{"job":"mine at:S2"}` -- and both attempts were rejected, so the seat
  ## played scripted (hosted league rounds 2-4, 2026-08-26: 10 of round 3's
  ## 14 attempt-failures were this). The argument goes BESIDE "job", so show
  ## it, for this role and this moment.
  lines.add("REPLY with ONLY {\"plan\":[<step>,...], " &
    (if sim.inMeeting: "\"vote\":\"<active alias or skip>\", " &
      "\"switch\":{\"if\":\"<active alias or tie>\",\"to\":" &
      "\"<active alias or skip>\"} or null, " else: "") &
    (if sim.config.chat and sim.inMeeting:
      "\"say\":\"<=" & $MaxSayLen & " chars\", " else: "") &
    "\"hunch\":\"<=" & $MaxHunchLen & " chars\", \"notes\":\"<=" &
    $MaxNotesLen & " chars\"}")
  lines.add("  plan: 1.." & $sim.config.planSteps & " steps; each <step> is " &
    "ONE object whose argument is a SIBLING key of \"job\", never inside it:")
  ## The `who` example names a cog that is active RIGHT NOW and is not this
  ## seat, so a model that copies the shape verbatim still passes validation.
  var whoExample = Aliases[(slot + 1) mod Seats]
  for alias in sim.activeAliases():
    if alias != Aliases[slot]:
      whoExample = alias
      break
  lines.add("    {\"job\":\"mine\",\"at\":\"S2\"} {\"job\":\"deposit\"} " &
    "{\"job\":\"watch\",\"who\":\"" & whoExample & "\"} " &
    "{\"job\":\"patrol\",\"room\":\"NW\"} {\"job\":\"guard\"} " &
    "{\"job\":\"hold\"}")
  if cog.role == rImpostor:
    lines.add("    {\"job\":\"hunt\",\"who\":\"" & whoExample & "\"} " &
      "{\"job\":\"strike\",\"who\":\"" & whoExample & "\"} " &
      "{\"job\":\"lurk\",\"room\":\"SE\"}")
  lines.add("  seam ids: " & seamIds.join(" ") & " \u00b7 room ids: " &
    roomIds.join(" "))
  lines.add("  aliases ACTIVE right now: " & sim.activeAliases().join(" "))
  if cog.role == rImpostor:
    let targets = freezeTargets(sim, slot)
    lines.add("  you can freeze right now: " &
      (if targets.len > 0: targets.join(" ") else: "(nobody)"))
  lines.join("\n")

# ---------------------------------------------------------------------------
# Reply parsing. Tolerant extraction, strict validation.
# ---------------------------------------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating fences
  ## and trailing prose.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    let head = oneLine(text, 160)
    raise newException(HiddenAgendaError,
      "no JSON object in response: " & head)
  parseJson(text[start .. stop])

proc splitCompactJob(text: string): tuple[job, arg: string] =
  ## `"mine at:S2"` -> `("mine", "S2")`. The system prompt documents exactly
  ## this compact form (`mine at:<seam>`, `watch who:<cog>`, `patrol room:<r>`,
  ## and the impostor's `hunt`/`strike`/`lurk`), so a model that writes it into
  ## the "job" key is following our own instructions and is honoured rather
  ## than rejected. A bare job name comes back with an empty `arg`.
  let parts = text.splitWhitespace()
  if parts.len == 0:
    return ("", "")
  result.job = parts[0]
  if parts.len > 1:
    let rest = parts[1 .. ^1].join(" ")
    let colon = rest.find(':')
    result.arg = (if colon >= 0: rest[colon + 1 .. ^1] else: rest).strip()

proc parseReply*(sim: Sim, slot: int, payload: JsonNode): Decision =
  ## Validates against the reply schema. Anything outside it is an INVALID
  ## REPLY, which the caller retries once with the hint and then falls back.
  let role = sim.cogs[slot].role
  let planNode = payload{"plan"}
  if planNode == nil or planNode.kind != JArray or planNode.len == 0:
    raise newException(HiddenAgendaError, "plan must be a 1.." &
      $sim.config.planSteps & " step array")
  if planNode.len > sim.config.planSteps:
    raise newException(HiddenAgendaError, "plan has " & $planNode.len &
      " steps, at most " & $sim.config.planSteps & " are allowed")
  for stepNode in planNode:
    if stepNode.kind != JObject:
      raise newException(HiddenAgendaError, "each plan step must be an object")
    ## The argument is read from the sibling key first and from the compact
    ## `job` string only when that sibling is absent; the enums are upper-case
    ## either way, so the compact argument is case-insensitive too.
    let (jobText, inlineArg) = splitCompactJob(
      stepNode{"job"}.getStr().strip().toLowerAscii())
    var job: JobKind
    var known = false
    for candidate in JobKind:
      if $candidate == jobText:
        job = candidate
        known = true
        break
    if not known:
      raise newException(HiddenAgendaError, "unknown job: " & jobText)
    if role == rCrew and job in {jkHunt, jkStrike, jkLurk}:
      raise newException(HiddenAgendaError,
        "job " & jobText & " is impostor-only")
    var step = PlanStep(job: job)
    if job == jkMine:
      step.at = stepNode{"at"}.getStr().strip().toUpperAscii()
      if step.at.len == 0:
        step.at = inlineArg.toUpperAscii()
      if seamIndex(step.at) < 0:
        raise newException(HiddenAgendaError,
          "mine needs at: one of S1..S6, got '" & step.at & "'")
    if job in {jkWatch, jkHunt, jkStrike}:
      step.who = stepNode{"who"}.getStr().strip().toUpperAscii()
      if step.who.len == 0:
        step.who = inlineArg.toUpperAscii()
      if not sim.isActiveAlias(step.who) or step.who == Aliases[slot]:
        raise newException(HiddenAgendaError,
          "who: must name a cog that is active right now, got '" &
          step.who & "'")
    if job in {jkPatrol, jkLurk}:
      step.room = stepNode{"room"}.getStr().strip().toUpperAscii()
      if step.room.len == 0:
        step.room = inlineArg.toUpperAscii()
      if roomIndex(step.room) < 0:
        raise newException(HiddenAgendaError,
          "room: must be one of NW N NE SW S SE HUB, got '" & step.room & "'")
    result.plan.add(step)

  if sim.inMeeting:
    let vote = payload{"vote"}.getStr().strip().toUpperAscii()
    if vote.len == 0:
      raise newException(HiddenAgendaError, "vote is required at a meeting")
    if vote == "SKIP":
      result.vote = "skip"
    elif sim.isActiveAlias(vote):
      result.vote = vote
    else:
      raise newException(HiddenAgendaError,
        "vote must be an active alias or skip, got '" & vote & "'")
    let switchNode = payload{"switch"}
    if switchNode != nil and switchNode.kind == JObject:
      let condition = switchNode{"if"}.getStr().strip().toUpperAscii()
      let target = switchNode{"to"}.getStr().strip().toUpperAscii()
      ## A HALF-WRITTEN switch degrades to "no conditional" instead of
      ## invalidating the whole reply. The design note's reply-schema table
      ## calls a malformed switch an invalid reply, but its governing intent is
      ## degrade-never-hang, and the strict reading is what the retry-then-
      ## fallback cost is measured against: in the hosted league (round 2,
      ## 2026-08-26) `switch needs both "if" and "to"` threw away a seat's
      ## whole plan and vote over an OPTIONAL field and put it on the scripted
      ## baseline. A switch that names an inactive cog is still invalid --
      ## that one is a claim about the roster, not a missing key.
      if condition.len > 0 and target.len > 0:
        if condition != "TIE" and not sim.isActiveAlias(condition):
          raise newException(HiddenAgendaError,
            "switch.if must be an active alias or tie, got '" & condition & "'")
        if target != "SKIP" and not sim.isActiveAlias(target):
          raise newException(HiddenAgendaError,
            "switch.to must be an active alias or skip, got '" & target & "'")
        result.switchIf = if condition == "TIE": "tie" else: condition
        result.switchTo = if target == "SKIP": "skip" else: target
    elif switchNode != nil and switchNode.kind notin {JNull}:
      raise newException(HiddenAgendaError, "switch must be an object or null")

  ## `say` in a no-talk variant is IGNORED, not an error, and never recorded.
  if sim.config.chat:
    result.say = oneLine(payload{"say"}.getStr(), MaxSayLen)
  result.hunch = oneLine(payload{"hunch"}.getStr(), MaxHunchLen)
  result.notes = cleanText(payload{"notes"}.getStr(), MaxNotesLen)
  result.source = dsLlm

# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

proc jevCandidates*(sim: Sim, slot: int): seq[tuple[name: string,
    decision: Decision]] =
  let miner = scriptedDecision(sim, slot, skMiner, sim.inMeeting)
  result.add(("miner", miner))
  result.add(("lurker", scriptedDecision(sim, slot, skLurker,
    sim.inMeeting)))
  var guard = miner
  guard.plan = @[PlanStep(job: jkGuard)]
  result.add(("guard", guard))
  if sim.inMeeting:
    if miner.vote != "skip":
      var skip = miner
      skip.vote = "skip"
      result.add(("vote_skip", skip))
    for alias in Aliases:
      if alias != Aliases[slot] and sim.isActiveAlias(alias) and
          alias != miner.vote:
        var vote = miner
        vote.vote = alias
        result.add(("vote_" & alias, vote))

proc jevCriteria*(sim: Sim, slot: int): JsonNode =
  result = newJObject()
  for candidate in sim.jevCandidates(slot):
    let action = candidate.decision
    var description = "Plan " & $planJson(action.plan)
    if sim.inMeeting:
      description.add("; vote " & action.vote)
    if action.switchIf.len > 0:
      description.add("; conditional vote " & action.switchIf & " -> " &
        action.switchTo)
    if sim.config.chat and action.say.len > 0:
      description.add("; say: " & action.say)
    if action.notes.len > 0:
      description.add("; private notes: " & action.notes)
    result[candidate.name] = %description

proc jevDecision*(sim: Sim, slot: int, payload, criteria: JsonNode): Decision =
  let answer = payload["answers"]["decision"]
  let probabilities = answer["probabilities"]
  let reported = answer["choice"].getStr()
  if answer["type"].getStr() != "choice" or
      not criteria.hasKey(reported) or probabilities.len != criteria.len:
    raise newException(HiddenAgendaError, "Jev returned the wrong choice set")
  let confidence = answer["confidence"].getFloat()
  if confidence < 0 or confidence > 1:
    raise newException(HiddenAgendaError, "Jev confidence is outside [0, 1]")
  var total = 0.0
  var best = -1.0
  var choice = ""
  for name, probability in probabilities.pairs:
    if not criteria.hasKey(name):
      raise newException(HiddenAgendaError, "Jev returned an unknown choice")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(HiddenAgendaError, "Jev probability is outside [0, 1]")
    total += value
    if value > best:
      best = value
      choice = name
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(HiddenAgendaError, "Jev probabilities do not sum to one")
  for candidate in sim.jevCandidates(slot):
    if candidate.name == choice:
      result = candidate.decision
      result.source = dsJev
      break
  echo "hidden-agenda jev: choice ", choice, " reported ", reported,
    " confidence ", confidence, " model ", payload{"model"}.getStr(),
    " input_tokens ", payload["usage"]{"input_tokens"}.getInt(),
    " output_tokens ", payload["usage"]{"output_tokens"}.getInt()

proc requestFor(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## No `output_config.effort`: Haiku 4.5 rejects the whole request with a
    ## 400 if it is present, and haiku is the only model this game ships.
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf*(client: LlmClient, response: Response, error, url: string):
    string =
  if error.len > 0:
    raise newException(HiddenAgendaError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    let detail = cleanText(response.body, 200)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(HiddenAgendaError,
        "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(HiddenAgendaError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    discard client.tryNextBedrockModel("throttled")
    raise newException(HiddenAgendaError,
      "llm throttled (429): " & cleanText(response.body, 200))
  if response.code < 200 or response.code >= 300:
    raise newException(HiddenAgendaError, "anthropic error " & $response.code &
      ": " & cleanText(response.body, 200))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(HiddenAgendaError, "anthropic refusal")
  let content = payload{"content"}
  if content != nil and content.kind == JArray:
    for contentBlock in content:
      if contentBlock{"type"}.getStr() == "text":
        result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(HiddenAgendaError,
      "reply cut off at max_tokens before any JSON: " & cleanText(result, 160))

proc decideAll*(
  client: LlmClient,
  sim: var Sim,
  seats: seq[int],
  prompts: seq[string],
  scriptedKinds: seq[ScriptKind],
  jev: seq[bool],
  cause: string
): seq[Decision] =
  ## One decision per seat in `seats`, in order. NEVER raises: any failure falls
  ## back to the `miner` decision so the episode always advances. `prompts` and
  ## `scriptedKinds` are indexed by SEAT.
  result = newSeq[Decision](seats.len)
  var open: seq[int]
  for index, seat in seats:
    let kind = scriptedKinds[seat]
    if kind != skNone:
      result[index] = scriptedDecision(sim, seat, kind, sim.inMeeting)
      result[index].source = dsScripted
    elif client == nil or (client.disabled and not jev[seat]) or
        (jev[seat] and client.jevEndpoint.len == 0):
      result[index] = scriptedDecision(sim, seat, skMiner, sim.inMeeting)
      result[index].source = dsFallback
    else:
      open.add(index)
  for attempt in 0 .. 1:
    if client.disabled:
      var enabled: seq[int]
      for index in open:
        if jev[seats[index]]:
          enabled.add(index)
        else:
          result[index] = scriptedDecision(sim, seats[index], skMiner,
            sim.inMeeting)
          result[index].source = dsFallback
      open = enabled
    if open.len == 0:
      break
    var batch: RequestBatch
    for index in open:
      let seat = seats[index]
      if jev[seat]:
        var headers: HttpHeaders
        headers["content-type"] = "application/json"
        if client.jevKey.len > 0:
          headers["authorization"] = "Bearer " & client.jevKey
        else:
          headers["x-coworld-player-slot"] = $seat
        if client.jevTrajectoryId.len > 0:
          headers["x-metta-trajectory-id"] =
            client.jevTrajectoryId & "-" & $seat
        let body = %*{
          "model": client.jevModel,
          "state": $sim.seatView(seat, cause),
          "questions": {"decision": {
            "type": "choice",
            "instructions": "Choose the complete plan and, at a meeting, vote " &
              "that maximizes your team's chance of winning. Crew must " &
              "deposit gems or eject the impostor. The impostor must " &
              "avoid detection while stopping the crew. Judge only the " &
              "information visible to this seat. " & prompts[seat],
            "criteria": sim.jevCriteria(seat)
          }}
        }
        batch.post(client.jevEndpoint & "/v1/systemone", headers, $body,
          $index)
      else:
        var user = userPrompt(sim, seat, prompts[seat], cause)
        if attempt > 0:
          user.add(RetryHint)
        let request = client.requestFor(systemPrompt(sim, seat), user)
        batch.post(request.url, request.headers, request.body, $index)
    ## ONE parallel batch for every open seat. Never a loop of single calls.
    let started = epochTime()
    let responses =
      if client.sendBatch != nil:
        client.sendBatch(batch, client.timeoutSeconds)
      else:
        client.curl.makeRequests(batch, client.timeoutSeconds)
    let latency = int((epochTime() - started) * 1000.0)
    var stillOpen: seq[int]
    for position, index in open:
      let seat = seats[index]
      try:
        var decision: Decision
        if jev[seat]:
          let response = responses[position].response
          let error = responses[position].error
          if error.len > 0 or response.code < 200 or response.code >= 300:
            raise newException(HiddenAgendaError, "Jev transport failed: " &
              error & " HTTP " & $response.code)
          let payload = parseJson(response.body)
          decision = sim.jevDecision(seat, payload, sim.jevCriteria(seat))
          client.jevInputTokens += payload["usage"]{"input_tokens"}.getInt()
          client.jevOutputTokens += payload["usage"]{"output_tokens"}.getInt()
        else:
          let text = client.textOf(responses[position].response,
            responses[position].error, batch[position].url)
          decision = parseReply(sim, seat, extractJsonObject(text))
        decision.source =
          if attempt > 0: dsRetry
          elif jev[seat]: dsJev
          else: dsLlm
        decision.latencyMs = latency
        result[index] = decision
      except CatchableError as error:
        echo "hidden-agenda llm: seat ", seat, " attempt ", attempt + 1,
          " failed: ", cleanText(error.msg, MaxErrorLen)
        stillOpen.add(index)
    open = stillOpen
  for index in open:
    let seat = seats[index]
    echo "hidden-agenda llm: seat ", seat, " falling back to scripted decision"
    result[index] = scriptedDecision(sim, seat, skMiner, sim.inMeeting)
    result[index].source = dsFallback

# ---------------------------------------------------------------------------
# The decision driver: the batch cadence, the wall-clock floor, the batch cap
# and the play deadline. Separated from the websocket server so the whole
# policy is testable against a fake clock with no sockets involved.
# ---------------------------------------------------------------------------

type
  DecisionDriver* = ref object
    client*: LlmClient
    prompts*: seq[string]
    scriptedKinds*: seq[ScriptKind]
    jev*: seq[bool]
    minBatchSeconds*: int
    maxBatches*: int
    batches*: int
    lastBatchAt*: float
    deadline*: float
    clock*: proc (): float {.closure.}
    sleeper*: proc (seconds: float) {.closure.}
    previous*: array[Seats, Decision]
    hasPrevious*: array[Seats, bool]
    deadlineHit*: bool
    batchSizes*: seq[int]

proc newDecisionDriver*(client: LlmClient, config: GameConfig,
    prompts: seq[string], scriptedKinds: seq[ScriptKind], jev: seq[bool],
    clock: proc (): float {.closure.} = nil,
    sleeper: proc (seconds: float) {.closure.} = nil): DecisionDriver =
  DecisionDriver(
    client: client,
    prompts: prompts,
    scriptedKinds: scriptedKinds,
    jev: jev,
    minBatchSeconds: config.minBatchSeconds,
    maxBatches: config.maxDecisionBatches,
    batches: 0,
    lastBatchAt: -1.0e9,
    deadline: playDeadlineSeconds(config),
    clock: clock,
    sleeper: sleeper
  )

proc elapsed(driver: DecisionDriver): float =
  if driver.clock == nil: 0.0 else: driver.clock()

proc pastDeadline*(driver: DecisionDriver): bool =
  driver.clock != nil and driver.elapsed() >= driver.deadline

proc decide*(driver: DecisionDriver, sim: var Sim, seats: seq[int],
    cause: string): seq[Decision] =
  ## One batch for every eligible seat at this decision point. Never raises.
  result = newSeq[Decision](seats.len)
  ## Budget cap: after the last permitted batch every subsequent meeting
  ## reuses each seat's PREVIOUS decision, recorded as source "budget".
  if driver.batches >= driver.maxBatches or driver.pastDeadline():
    if driver.pastDeadline():
      driver.deadlineHit = true
    for index, seat in seats:
      result[index] =
        if driver.hasPrevious[seat]:
          driver.previous[seat]
        else:
          scriptedDecision(sim, seat, skMiner, sim.inMeeting)
      result[index].source = dsBudget
      result[index].latencyMs = 0
    return
  ## `minBatchSeconds` floors the spacing between batch STARTS, so the episode
  ## stays under the Bedrock sidecar's 30 rpm per-episode ceiling (raid,
  ## 2026-08-23).
  if driver.minBatchSeconds > 0 and driver.clock != nil and
      driver.batches > 0:
    let wait = driver.minBatchSeconds.float -
      (driver.elapsed() - driver.lastBatchAt)
    if wait > 0.0 and driver.sleeper != nil:
      driver.sleeper(wait)
  driver.lastBatchAt = driver.elapsed()
  driver.batches.inc
  driver.batchSizes.add(seats.len)
  result = decideAll(driver.client, sim, seats, driver.prompts,
    driver.scriptedKinds, driver.jev, cause)
  for index, seat in seats:
    driver.previous[seat] = result[index]
    driver.hasPrevious[seat] = true
