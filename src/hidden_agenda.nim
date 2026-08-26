## Hidden Agenda entrypoint: reads the Coworld runtime contract and starts the
## episode server.
##
## Forked from `coworld-ctf/src/ctf.nim`. Seed randomisation happens HERE,
## BEFORE `config.update` honours a pinned seed, so every seed-derived draw —
## including `rngRole`, which picks the impostor — follows the FINAL seed.

import std/[json, strutils, sysrand]
import bitworld/runtime
import hidden_agenda/[sim_types, sim_config, server]

proc randomSeed(): int =
  var buf: array[4, byte]
  if not urandom(buf):
    raise newException(HiddenAgendaError, "OS entropy source unavailable")
  (int(buf[0]) shl 24 or int(buf[1]) shl 16 or
    int(buf[2]) shl 8 or int(buf[3])) and 0x7FFF_FFFF

proc seedPinned(configText: string): bool =
  if configText.strip().len == 0:
    return false
  try:
    let node = parseJson(configText)
    node.kind == JObject and node.hasKey("seed")
  except CatchableError:
    false

when isMainModule:
  var runtimeConfig: RuntimeConfig
  try:
    runtimeConfig = readRuntimeConfig()
  except CatchableError as error:
    quit("hidden-agenda: bad runtime configuration: " & error.msg, 2)

  if runtimeConfig.config.strip().len == 0:
    quit("hidden-agenda: COGAME_CONFIG_URI is required " &
      "(no game config was given)", 2)
  var config = defaultGameConfig()
  if not seedPinned(runtimeConfig.config):
    config.seed = randomSeed()
    echo "hidden-agenda: seed not pinned; randomized to ", config.seed
  try:
    config.update(runtimeConfig.config)
  except CatchableError as error:
    quit("hidden-agenda: invalid game config: " & error.msg, 2)
  if config.tokens.len == 0:
    quit("hidden-agenda: the game config must carry one token per seat", 2)
  echo "hidden-agenda: seats=", config.numAgents,
    " variant=", config.variant,
    " chat=", config.chat,
    " maxTicks=", config.maxTicks,
    " depositTarget=", config.depositTarget,
    " meetingTicks=", config.meetingTicks,
    " visionRadius=", config.visionRadius,
    " seed=", config.seed
  try:
    runGameServer(config, runtimeConfig)
  except CatchableError as error:
    quit("hidden-agenda: " & error.msg, 2)
