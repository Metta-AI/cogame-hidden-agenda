## `GameConfig` lifecycle: defaults, the runtime JSON overlay, validation, and
## the fully resolved config document pinned verbatim into every replay.
##
## Fork of `coworld-ctf/src/ctf/sim_config.nim`, reduced to this game's fields
## (the schema in the design note's `## Packaging`).

import std/[json, strutils]
import sim_types, station

type
  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    numAgents*: int
    variant*: string
    impostorSlot*: int          ## -1 = draw it from rngRole
    maxTicks*: int
    depositTarget*: int
    carryCap*: int
    mineTicks*: int
    seamCapacity*: int
    seamRegrowTicks*: int
    moveCooldown*: int
    freezeRange*: int
    freezeCooldownTicks*: int
    visionRadius*: int
    awarenessRadius*: int
    sweepTicks*: int
    meetingCadenceTicks*: int
    meetingTicks*: int
    chat*: bool
    sayTick*: int
    revealTick*: int
    switchTick*: int
    resolveTick*: int
    planSteps*: int
    llmTimeoutSeconds*: int
    minBatchSeconds*: int
    maxDecisionBatches*: int
    maxOutputTokens*: int
    model*: string
    episodeTimeoutSeconds*: int
    playerConnectTimeoutSeconds*: int
    shutdownGraceSeconds*: int
    showPlayerLabels*: bool

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    numAgents: Seats,
    variant: "hidden-agenda",
    impostorSlot: -1,
    maxTicks: 3000,
    depositTarget: 32,
    carryCap: 2,
    mineTicks: 72,
    seamCapacity: 3,
    seamRegrowTicks: 120,
    moveCooldown: 2,
    freezeRange: 2,
    freezeCooldownTicks: 260,
    visionRadius: 8,
    # The design note's repair ladder names step (e) as awarenessRadius
    # 2 -> 3. Three is not enough: measured on tests/test_feasibility.nim,
    # awarenessRadius = 3 FAILS gate (c) (impostor win rate 0.38 against a
    # 0.35 ceiling, mean witnessed freezes 1.81) and FAILS gate (e)
    # (7/29 witnessed freezes convicted = 0.24 against a 0.60 floor). Four
    # passes both with margin (c: 1.62 witnessed, impostor win rate 0.00;
    # e: 16/26 = 0.62), so the ladder's own step was walked one rung further
    # in the same direction rather than reaching for a pinned constant. The
    # gate test is the enforcement; this line is only its record.
    awarenessRadius: 4,
    sweepTicks: 8,
    meetingCadenceTicks: 200,
    meetingTicks: 60,
    chat: true,
    sayTick: 10,
    revealTick: 24,
    switchTick: 46,
    resolveTick: 56,
    planSteps: 3,
    llmTimeoutSeconds: 14,
    minBatchSeconds: 14,
    maxDecisionBatches: 20,
    maxOutputTokens: 900,
    model: "claude-haiku-4-5",
    episodeTimeoutSeconds: 1200,
    playerConnectTimeoutSeconds: 120,
    shutdownGraceSeconds: 20,
    showPlayerLabels: true
  )

proc playDeadlineSeconds*(config: GameConfig): float =
  ## The wall-clock budget the episode plays inside: 60 % of
  ## `episodeTimeoutSeconds`. The game container is NOT given
  ## COWORLD_TIMEOUT_SECONDS, so 1200 is assumed unless the config says
  ## otherwise (playbook §Phase 0).
  0.6 * config.episodeTimeoutSeconds.float

proc validate*(config: GameConfig) =
  template need(cond: bool, msg: string) =
    if not cond:
      raise newException(HiddenAgendaError, msg)
  need(config.numAgents == Seats,
    "num_agents must be " & $Seats & ", got " & $config.numAgents)
  need(config.maxTicks >= 24, "maxTicks must be at least 24")
  need(config.depositTarget >= 1, "depositTarget must be positive")
  need(config.carryCap >= 1, "carryCap must be positive")
  need(config.mineTicks >= 1, "mineTicks must be positive")
  need(config.seamCapacity >= 1, "seamCapacity must be positive")
  need(config.seamRegrowTicks >= 1, "seamRegrowTicks must be positive")
  need(config.moveCooldown >= 1, "moveCooldown must be positive")
  need(config.freezeRange >= 1, "freezeRange must be positive")
  need(config.freezeCooldownTicks >= 1,
    "freezeCooldownTicks must be positive")
  need(config.visionRadius >= 1, "visionRadius must be positive")
  need(config.awarenessRadius >= 0, "awarenessRadius must not be negative")
  need(config.sweepTicks >= 1, "sweepTicks must be positive")
  need(config.meetingCadenceTicks >= 1,
    "meetingCadenceTicks must be positive")
  need(config.meetingTicks >= 5, "meetingTicks must be at least 5")
  need(config.planSteps >= 1 and config.planSteps <= 5,
    "planSteps must be 1..5")
  need(config.impostorSlot >= -1 and config.impostorSlot < Seats,
    "impostorSlot must be -1..4")
  need(config.revealTick >= 1 and config.revealTick < config.switchTick,
    "revealTick must be >= 1 and before switchTick")
  need(config.switchTick < config.resolveTick,
    "switchTick must be before resolveTick")
  need(config.resolveTick < config.meetingTicks,
    "resolveTick must be before meetingTicks")
  if config.chat:
    need(config.sayTick >= 1 and config.sayTick < config.revealTick,
      "a chat variant needs 1 <= sayTick < revealTick")
  need(config.maxDecisionBatches >= 1, "maxDecisionBatches must be positive")
  need(config.llmTimeoutSeconds >= 1, "llmTimeoutSeconds must be positive")
  ## The whole budget must fit inside 60 % of episodeTimeoutSeconds: every
  ## batch can cost one attempt plus one retry, plus the connect ceiling.
  let worst = config.maxDecisionBatches.float * 2.0 *
    config.llmTimeoutSeconds.float + config.playerConnectTimeoutSeconds.float
  need(worst <= playDeadlineSeconds(config) + 1.0,
    "maxDecisionBatches x 2 x llmTimeoutSeconds + connect (" & $worst &
    " s) must fit inside 60% of episodeTimeoutSeconds (" &
    $playDeadlineSeconds(config) & " s)")

proc update*(config: var GameConfig, configJson: string) =
  ## Applies the runtime JSON config on top of the defaults, then validates.
  if configJson.strip().len == 0:
    config.validate()
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(HiddenAgendaError, "config must be a JSON object")
  template intField(name: string, target: untyped) =
    if node.hasKey(name):
      target = node[name].getInt()
  template boolField(name: string, target: untyped) =
    if node.hasKey(name):
      target = node[name].getBool()
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player{"name"}.getStr()))
  ## `variant` and `model` are pinned verbatim into the replay's config
  ## document (`replayConfigJson`), so they get the same rune-safe cap as every
  ## other recorded string rather than arriving from the runtime config with
  ## whatever length and byte boundaries it likes.
  if node.hasKey("variant"):
    config.variant = cleanText(node["variant"].getStr(), MaxPolicyLen)
  if node.hasKey("model"):
    config.model = cleanText(node["model"].getStr(), MaxPolicyLen)
  intField("seed", config.seed)
  intField("num_agents", config.numAgents)
  intField("impostorSlot", config.impostorSlot)
  intField("maxTicks", config.maxTicks)
  intField("depositTarget", config.depositTarget)
  intField("carryCap", config.carryCap)
  intField("mineTicks", config.mineTicks)
  intField("seamCapacity", config.seamCapacity)
  intField("seamRegrowTicks", config.seamRegrowTicks)
  intField("moveCooldown", config.moveCooldown)
  intField("freezeRange", config.freezeRange)
  intField("freezeCooldownTicks", config.freezeCooldownTicks)
  intField("visionRadius", config.visionRadius)
  intField("awarenessRadius", config.awarenessRadius)
  intField("sweepTicks", config.sweepTicks)
  intField("meetingCadenceTicks", config.meetingCadenceTicks)
  intField("meetingTicks", config.meetingTicks)
  intField("sayTick", config.sayTick)
  intField("revealTick", config.revealTick)
  intField("switchTick", config.switchTick)
  intField("resolveTick", config.resolveTick)
  intField("planSteps", config.planSteps)
  intField("llmTimeoutSeconds", config.llmTimeoutSeconds)
  intField("minBatchSeconds", config.minBatchSeconds)
  intField("maxDecisionBatches", config.maxDecisionBatches)
  intField("maxOutputTokens", config.maxOutputTokens)
  intField("episodeTimeoutSeconds", config.episodeTimeoutSeconds)
  intField("playerConnectTimeoutSeconds", config.playerConnectTimeoutSeconds)
  intField("player_connect_timeout_seconds",
    config.playerConnectTimeoutSeconds)
  intField("shutdownGraceSeconds", config.shutdownGraceSeconds)
  boolField("chat", config.chat)
  boolField("showPlayerLabels", config.showPlayerLabels)
  config.validate()

proc replayConfigJson*(config: GameConfig): JsonNode =
  ## The resolved rule set pinned into the replay. TOKENS ARE EXCLUDED. The
  ## impostor slot IS included: the replay is spectator-side and the design
  ## pins "the spectator and the replay see every role".
  var grid = newJArray()
  for row in gridLines():
    grid.add(%row)
  var rooms = newJArray()
  for room in RoomTable:
    rooms.add(%*{
      "id": room.id, "name": room.name,
      "x0": room.x0, "x1": room.x1, "y0": room.y0, "y1": room.y1,
      "door": [room.door[0], room.door[1]]
    })
  var seams = newJArray()
  for seam in SeamTable:
    seams.add(%*{"id": seam.id, "room": seam.room, "cell": [seam.x, seam.y]})
  var grate = newJArray()
  for cell in grateCells():
    grate.add(%[cell[0], cell[1]])
  var spawns = newJArray()
  for cell in SpawnCells:
    spawns.add(%[cell[0], cell[1]])
  %*{
    "variant": config.variant,
    "chat": config.chat,
    "map": "vault",
    "cols": MapCols, "rows": MapRows, "cell": CellPx,
    "grid": grid, "rooms": rooms, "seams": seams, "grate": grate,
    "spawns": spawns,
    "maxTicks": config.maxTicks,
    "depositTarget": config.depositTarget,
    "carryCap": config.carryCap,
    "mineTicks": config.mineTicks,
    "seamCapacity": config.seamCapacity,
    "seamRegrowTicks": config.seamRegrowTicks,
    "moveCooldown": config.moveCooldown,
    "freezeRange": config.freezeRange,
    "freezeCooldownTicks": config.freezeCooldownTicks,
    "visionRadius": config.visionRadius,
    "awarenessRadius": config.awarenessRadius,
    "sweepTicks": config.sweepTicks,
    "meetingCadenceTicks": config.meetingCadenceTicks,
    "meetingTicks": config.meetingTicks,
    "sayTick": config.sayTick,
    "revealTick": config.revealTick,
    "switchTick": config.switchTick,
    "resolveTick": config.resolveTick,
    "impostorSlot": config.impostorSlot,
    "planSteps": config.planSteps
  }

proc configFromReplayJson*(node: JsonNode): GameConfig =
  ## Rebuilds the rule set from a replay's pinned config document, so the
  ## viewer draws with the constants the episode actually ran on.
  result = defaultGameConfig()
  if node == nil or node.kind != JObject:
    return
  result.variant = node{"variant"}.getStr(result.variant)
  result.chat = node{"chat"}.getBool(result.chat)
  result.maxTicks = node{"maxTicks"}.getInt(result.maxTicks)
  result.depositTarget = node{"depositTarget"}.getInt(result.depositTarget)
  result.carryCap = node{"carryCap"}.getInt(result.carryCap)
  result.mineTicks = node{"mineTicks"}.getInt(result.mineTicks)
  result.seamCapacity = node{"seamCapacity"}.getInt(result.seamCapacity)
  result.visionRadius = node{"visionRadius"}.getInt(result.visionRadius)
  result.awarenessRadius =
    node{"awarenessRadius"}.getInt(result.awarenessRadius)
  result.freezeCooldownTicks =
    node{"freezeCooldownTicks"}.getInt(result.freezeCooldownTicks)
  result.meetingTicks = node{"meetingTicks"}.getInt(result.meetingTicks)
  result.sayTick = node{"sayTick"}.getInt(result.sayTick)
  result.revealTick = node{"revealTick"}.getInt(result.revealTick)
  result.switchTick = node{"switchTick"}.getInt(result.switchTick)
  result.resolveTick = node{"resolveTick"}.getInt(result.resolveTick)
  result.impostorSlot = node{"impostorSlot"}.getInt(result.impostorSlot)
