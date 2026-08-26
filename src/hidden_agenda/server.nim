## The Hidden Agenda game server: the Coworld game contract over mummy.
##
## Fork of `coworld-ctf/src/ctf/server.nim`'s route / artifact / shutdown
## skeleton; the player protocol becomes bullwhip's JSON frames.
##
## Routes — hosted certification probes exactly these BEFORE the player pods
## start (lantern, 2026-08-23), so all of them serve real pages:
##   GET /healthz                     200 ok, until shutdownGraceSeconds after
##                                    the artifacts are written
##   GET /client/player?slot=&token=  the seat's HTML shell; it NEVER opens the
##                                    player socket
##   GET /client/global               the broadcast client
##
## There is deliberately NO pod route serving a replay page. A finished episode
## is watched through the STATIC wasm bundle the platform builds from
## tools/build_replay_viewer.sh (coworld_manifest_template.json declares
## "replay_viewer": {"bundle": "static-replay-viewer"}), which contacts nothing
## but S3. A pod-served replay page would keep a game container alive just to
## watch a finished episode, and tests/test_manifest.nim asserts the path is
## absent from src/, docs/, client/, the README and the manifest.
##   WS  /player?slot=N&token=T       the seat socket; a bad token is refused
##                                    with a close, never a hang
##   WS  /global                      live spectator: the packet + chrome frame
##
## Decisions are made HERE, not in the player container: the Bedrock sidecar
## credentials and the anthropic_api_key secret are injected into the GAME pod,
## and "one parallel batch per decision point" is a game-server property
## (hive, 2026-08-23).

import std/[json, locks, os, sets, strutils, tables, times, unicode]
import bitworld/runtime
import curly
import mummy
import mummy/routers
import sim_types, sim_config, sim_state, sim, scripted, llm,
  global, replays, wire_constants

const
  PlayerPage = staticRead("../../client/player.html")
  GlobalPage = staticRead("../../client/global.html")
  ChromeCommonJs = staticRead("../../client/chrome_common.js")
  BroadcastCoreJs = staticRead("../../client/broadcast_core.js")
  ChromeCommonMarker = "<!-- CHROME_COMMON -->"
  BroadcastCoreMarker = "<!-- BROADCAST_CORE -->"

type
  ServerState = object
    prompts: seq[string]
    scriptedKinds: seq[ScriptKind]
    registered: seq[bool]
    everRegistered: seq[bool]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    snapshot: string
    seats: int
    finished: bool

var
  stateLock: Lock
  shared: ServerState
  gameSim: Sim
  gameServer: Server
  gameConfig: GameConfig

initLock(stateLock)

proc splicePage(page: string): string =
  result = spliceWireConstants(page)
  result = result.replace(ChromeCommonMarker,
    "<script>" & ChromeCommonJs & "</script>")
  result = result.replace(BroadcastCoreMarker,
    "<script>" & BroadcastCoreJs & "</script>")

proc refreshSnapshotLocked() =
  shared.snapshot = globalSnapshot(gameSim)
  for socket in shared.globalSockets:
    try:
      socket.send(shared.snapshot)
    except CatchableError:
      discard

proc declarePlayerFailure(slot: int, message: string) =
  try:
    writeCogameEnv("COGAME_PLAYER_FAILURE_URI",
      $(%*{"failed_policy_index": slot, "message": message}),
      "application/json")
  except CatchableError as error:
    echo "hidden-agenda: player-failure declaration failed: ", error.msg

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError, "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc welcomeFrame(slot: int): string =
  var aliases = newJArray()
  for alias in Aliases:
    aliases.add(%alias)
  ## `role` is THIS SEAT'S OWN role and nothing else's.
  $ %*{
    "type": "welcome", "protocol": Protocol, "slot": slot,
    "role": $gameSim.cogs[slot].role, "name": Aliases[slot],
    "variant": gameConfig.variant, "chat": gameConfig.chat,
    "maxTicks": gameConfig.maxTicks,
    "depositTarget": gameConfig.depositTarget,
    "aliases": aliases
  }

proc pushStateFrames(cause: string) =
  for slot, socket in shared.playerSockets:
    if slot < 0 or slot >= Seats:
      continue
    try:
      socket.send($seatView(gameSim, slot, cause))
    except CatchableError:
      discard

proc finalFrame(slot: int): string =
  let results = gameSim.resultsJson()
  var names = newJArray()
  for alias in Aliases:
    names.add(%alias)
  ## `slot` is THIS seat's own slot, the same field the `welcome` and `state`
  ## frames carry, so a policy that multiplexes seats can tell whose buzzer
  ## this is. NO roles[], NO impostorSlot, NO seed: nobody learns the answer
  ## from the game, not even at the buzzer.
  $ %*{
    "type": "final", "done": true, "slot": slot,
    "scores": results{"scores"}, "win": results{"win"},
    "winner": gameSim.winner, "names": names,
    "deposits": gameSim.deposits, "ticks": gameSim.frames.len,
    "reason": gameSim.reason, "ending": gameSim.ending
  }

proc broadcastFinal() =
  var allowance = epochTime()
  for slot, socket in shared.playerSockets:
    allowance += 3.0
    if epochTime() > allowance:
      echo "hidden-agenda: final broadcast past budget; skipping slot ", slot
      continue
    try:
      socket.send(finalFrame(slot))
    except CatchableError as error:
      echo "hidden-agenda: final frame to slot ", slot, " failed: ", error.msg

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    if shared.finished:
      return
    shared.finished = true
    gameSim.finalise()
    results = gameSim.resultsJson()
    replayData = replayBytes(gameSim)
    ## Final frames to the players BEFORE the artifacts: the hosted worker
    ## tears player pods down as soon as results.json exists.
    broadcastFinal()
    refreshSnapshotLocked()
  sleep(500)
  echo "hidden-agenda: writing results and replay (", replayData.len,
    " bytes)"
  writeArtifact(runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD")
  writeArtifact(runtimeConfig.replayUri, replayData, "application/json",
    "COGAME_SAVE_REPLAY_METHOD")
  echo "hidden-agenda: episode complete (", gameSim.reason, "/",
    gameSim.ending, ", winner ", gameSim.winner, ") after ",
    gameSim.frames.len, " ticks, ", gameSim.deposits, " deposits, ",
    gameSim.freezes, " freezes (", gameSim.witnessedFreezes, " witnessed), ",
    gameSim.meetings.len, " meetings"

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = gameConfig
    let gameStart = epochTime()
    let connectDeadline = gameStart +
      config.playerConnectTimeoutSeconds.float
    while epochTime() < connectDeadline:
      var allConnected = false
      withLock stateLock:
        allConnected = shared.playerSockets.len >= shared.seats
      if allConnected:
        break
      sleep(200)
    ## Give a connected-but-silent seat a moment to send its prompt frame.
    let registerDeadline = min(epochTime() + 3.0, connectDeadline + 3.0)
    while epochTime() < registerDeadline:
      var allRegistered = true
      withLock stateLock:
        for slot in 0 ..< shared.seats:
          if shared.playerSockets.hasKey(slot) and not shared.registered[slot]:
            allRegistered = false
      if allRegistered:
        break
      sleep(100)

    var connected = 0
    var noShow = -1
    withLock stateLock:
      connected = shared.playerSockets.len
      for slot in 0 ..< shared.seats:
        if not shared.everRegistered[slot]:
          if noShow < 0:
            noShow = slot
          ## A seat that never connects does NOT end the episode: it plays
          ## `miner` and the game runs.
          shared.scriptedKinds[slot] = skMiner
      echo "hidden-agenda: starting with ", connected, "/", shared.seats,
        " players connected"
      refreshSnapshotLocked()
    if noShow >= 0:
      declarePlayerFailure(noShow,
        "player slot " & $noShow & " never registered; the seat played the " &
        "miner baseline")

    if connected == 0:
      echo "hidden-agenda: no seat connected; forfeiting"
      gameSim.settle("forfeit", "forfeit", "none")
      finishEpisode(runtimeConfig)
      sleep(config.shutdownGraceSeconds * 1000)
      quit(0)

    var prompts: seq[string]
    var kinds: seq[ScriptKind]
    withLock stateLock:
      prompts = shared.prompts
      kinds = shared.scriptedKinds
    let client = newLlmClient(config)
    proc clock(): float {.closure.} = epochTime() - gameStart
    proc sleeper(seconds: float) {.closure.} =
      sleep(int(seconds * 1000.0))
    let driver = newDecisionDriver(client, config, prompts, kinds,
      clock, sleeper)

    proc decide(view: var Sim, seats: seq[int], cause: string):
        seq[Decision] {.closure.} =
      withLock stateLock:
        pushStateFrames(cause)
        ## Re-read live: a seat whose socket died mid-episode has already been
        ## demoted to `miner` by the close handler.
        driver.prompts = shared.prompts
        driver.scriptedKinds = shared.scriptedKinds
      result = driver.decide(view, seats, cause)

    proc onTick(view: var Sim) {.closure.} =
      if view.tick mod 24 == 0 or view.done:
        withLock stateLock:
          refreshSnapshotLocked()

    gameSim.runEpisode(decide, clock, playDeadlineSeconds(config), onTick)
    withLock stateLock:
      pushStateFrames("final")
    finishEpisode(runtimeConfig)
    ## As cogame-lantern taught, /healthz and /global keep answering for
    ## shutdownGraceSeconds before quit(0), because hosted certification pings
    ## the global websocket AFTER the player pods start.
    echo "hidden-agenda: holding /healthz and /global for ",
      config.shutdownGraceSeconds, "s"
    sleep(config.shutdownGraceSeconds * 1000)
    quit(0)

var gameThread: Thread[RuntimeConfig]

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc respondHtml(request: Request, body: string) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html; charset=utf-8"
  request.respond(200, headers, body)

proc playerPageHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    respondHtml(request, splicePage(PlayerPage))

proc globalPageHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    respondHtml(request, splicePage(GlobalPage))

proc clientAssetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    var headers: HttpHeaders
    headers["Content-Type"] = "application/javascript; charset=utf-8"
    case name
    of "chrome_common.js": request.respond(200, headers, ChromeCommonJs)
    of "broadcast_core.js": request.respond(200, headers, BroadcastCoreJs)
    of "wire_constants.js": request.respond(200, headers, WireConstantsJs)
    else: request.respond(404)

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    var duplicate = false
    withLock stateLock:
      authorized = slot >= 0 and slot < gameConfig.tokens.len and
        gameConfig.tokens[slot] == token
      duplicate = authorized and shared.playerSockets.hasKey(slot)
    if not authorized:
      request.respond(403)
      return
    if duplicate:
      request.respond(409)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      shared.playerSockets[slot] = websocket
      shared.socketSlots[websocket] = slot
      echo "hidden-agenda: player slot ", slot, " connected (",
        shared.playerSockets.len, "/", shared.seats, ")"
      try:
        websocket.send(welcomeFrame(slot))
      except CatchableError:
        discard

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      shared.globalSockets.incl(websocket)
      if shared.snapshot.len > 0:
        try:
          websocket.send(shared.snapshot)
        except CatchableError:
          discard

proc websocketHandler(websocket: WebSocket, event: WebSocketEvent,
    message: Message) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application; the certifier pings
      ## /global to check the game is alive, so an unanswered ping fails
      ## certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = shared.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() != "prompt":
          echo "hidden-agenda: ignoring player frame of type '",
            payload{"type"}.getStr(), "'"
          return
        var prompt = payload{"prompt"}.getStr()
        if prompt.runeLen > MaxPromptLen:
          prompt = cleanText(prompt, MaxPromptLen)
        let node = payload{"scripted"}
        var kind =
          if node == nil or node.kind == JNull: skNone
          elif node.kind == JBool: (if node.getBool(): skMiner else: skNone)
          else: parseScriptKind(node.getStr())
        if prompt.strip().len == 0 and kind == skNone:
          kind = skMiner
        withLock stateLock:
          shared.prompts[slot] = prompt
          shared.scriptedKinds[slot] = kind
          shared.registered[slot] = true
          shared.everRegistered[slot] = true
        echo "hidden-agenda: slot ", slot, " registered (", prompt.len,
          " prompt chars", (if kind != skNone: ", scripted " & $kind
            else: ", llm"), ")"
      except CatchableError as error:
        echo "hidden-agenda: ignoring bad player frame: ", error.msg
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in shared.socketSlots:
          let slot = shared.socketSlots[websocket]
          shared.socketSlots.del(websocket)
          if shared.playerSockets.getOrDefault(slot) == websocket:
            shared.playerSockets.del(slot)
          ## A seat whose socket dies mid-episode plays `miner` for the rest
          ## of it; the episode never blocks on a socket.
          if shared.scriptedKinds[slot] == skNone:
            shared.scriptedKinds[slot] = skMiner
        shared.globalSockets.excl(websocket)

proc buildRouter(): Router =
  ## The two /client pages are registered BEFORE the asset route, so neither
  ## is shadowed by it. There is no replay page route: the replay viewer is
  ## the static bundle, never a pod path.
  result.get("/healthz", healthzHandler)
  result.get("/client/player", playerPageHandler)
  result.get("/client/global", globalPageHandler)
  result.get("/client/@name", clientAssetHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/player", playerUpgradeHandler)

proc stopServer*() =
  if gameServer != nil:
    gameServer.close()

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.numAgents:
    raise newException(HiddenAgendaError,
      "tokens must name exactly num_agents seats")
  gameConfig = config
  gameSim = initSim(config)
  shared.seats = config.numAgents
  shared.prompts = newSeq[string](shared.seats)
  shared.scriptedKinds = newSeq[ScriptKind](shared.seats)
  shared.registered = newSeq[bool](shared.seats)
  shared.everRegistered = newSeq[bool](shared.seats)
  shared.snapshot = globalSnapshot(gameSim)
  let router = buildRouter()
  gameServer = newServer(router, websocketHandler, workerThreads = 4)
  createThread(gameThread, runGame, runtimeConfig)
  echo "hidden-agenda: serving on ", runtimeConfig.host, ":",
    runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
