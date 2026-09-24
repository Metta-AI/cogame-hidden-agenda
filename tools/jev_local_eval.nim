## Matched no-talk episode for seat 0. Run once with miner and once with jev.

import std/[json, os, strutils, times]
import hidden_agenda/[sim_types, sim_config, sim_state, sim, scripted, llm,
  replays]

proc main() =
  if paramCount() != 3:
    quit("usage: jev_local_eval <miner|jev> <seed> <crew|impostor>", 2)

  let mode = paramStr(1)
  if mode notin ["miner", "jev"]:
    quit("mode must be miner or jev", 2)
  let seed = parseInt(paramStr(2))
  let role = paramStr(3)
  if role notin ["crew", "impostor"]:
    quit("role must be crew or impostor", 2)

  var config = defaultGameConfig()
  config.update($( %*{
    "seed": seed,
    "variant": "hidden-agenda-notalk",
    "impostorSlot": (if role == "impostor": 0 else: 4),
    "chat": false,
    "meetingTicks": 25,
    "sayTick": -1,
    "revealTick": 5,
    "switchTick": 18,
    "resolveTick": 23,
    "minBatchSeconds": 0,
    "tokens": ["t0", "t1", "t2", "t3", "t4"],
    "players": [{"name": mode}, {"name": "miner-1"},
      {"name": "miner-2"}, {"name": "miner-3"},
      {"name": "miner-4"}]
  }))

  var game = initSim(config)
  let client = newLlmClient(config)
  let prompts = newSeq[string](Seats)
  var kinds = newSeq[ScriptKind](Seats)
  for seat in 0 ..< Seats:
    kinds[seat] = skMiner
  var jev = newSeq[bool](Seats)
  if mode == "jev":
    if client.jevEndpoint.len == 0:
      quit("Jev credential or endpoint is required", 2)
    kinds[0] = skNone
    jev[0] = true
  let driver = newDecisionDriver(client, config, prompts, kinds, jev)
  proc decide(view: var Sim, seats: seq[int], cause: string):
      seq[Decision] {.closure.} =
    driver.decide(view, seats, cause)
  game.runEpisode(decide)
  game.finalise()

  var calls = 0
  var fallbacks = 0
  for row in game.log.rows:
    if row{"k"}.getStr() == "order" and row{"seat"}.getInt() == 0:
      if row{"source"}.getStr() in ["jev", "retry"]:
        calls.inc
      if row{"source"}.getStr() == "fallback":
        fallbacks.inc

  let outputDir = "dist/jev-local/" & mode & "-" & $seed & "-" &
    role & "-" & $config.maxTicks & "-" &
    $int(epochTime() * 1000)
  createDir(outputDir)
  writeFile(outputDir / "results.json", $(game.resultsJson()))
  writeFile(outputDir / "replay.json", game.replayBytes())
  let summary = %*{"mode": mode, "seed": seed, "role": role,
    "score": game.scores[0], "winner": game.winner,
    "ending": game.ending, "ticks": game.tick,
    "jev_calls": calls, "fallbacks": fallbacks,
    "jev_input_tokens": client.jevInputTokens,
    "jev_output_tokens": client.jevOutputTokens,
    "artifacts": outputDir}
  writeFile(outputDir / "summary.json", $summary)
  echo $summary

main()
