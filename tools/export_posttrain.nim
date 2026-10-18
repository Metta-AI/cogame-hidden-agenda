## Complete private candidates. Independent review owns admission and splits.
import std/[json, os, osproc, strutils, tables]
import hidden_agenda/[sim, scripted, llm, training, prompts, evidence, replays]

when isMainModule:
  let args = commandLineParams()
  if args.len notin [3, 5]:
    quit("usage: hidden-agenda-posttrain OUTPUT EPISODES VARIANT [PROMPT_VARIANT PROMPT_SEED]", 1)
  let output = absolutePath(args[0])
  let episodes = parseInt(args[1])
  let variant = args[2]
  let selection = promptSelection(if args.len == 5:
    %*{"promptVariant": args[3], "promptSeed": parseInt(args[4])} else: newJObject())
  doAssert selection.selectedVariant notin {pvHeldoutBriefing, pvHeldoutReference},
    "held-out wording is evaluation only"
  doAssert episodes >= 10
  doAssert not dirExists(output) and not fileExists(output)
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit qualified source before exporting pinned candidates"
  let head = execCmdEx("git rev-parse HEAD")
  doAssert head.exitCode == 0
  let revision = head.output.strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  writePrivate(output / "trajectories.jsonl", "")
  let stream = open(output / "trajectories.jsonl", fmAppend)
  var runs = newJArray()
  try:
    for seed in 1 .. episodes:
      variantConfig["seed"] = %seed
      var config = defaultGameConfig()
      config.update($variantConfig)
      var game = initSim(config)
      let family = "hidden-agenda-" & $seed
      let episode = family & "-" & variant & "-" & $selection.selectedVariant
      var records: seq[JsonNode]
      var pending = initTable[string, int]()
      proc decide(view: var Sim, seats: seq[int], cause: string):
          seq[Decision] {.closure.} =
        for seat in seats:
          let baseline = if view.cogs[seat].role == rImpostor: skLurker else: skMiner
          let teacher = scriptedDecision(view, seat, baseline, view.inMeeting)
          let proposal = teacher.decisionAction(view.config.chat)
          var accepted = view.parseReply(seat, proposal)
          doAssert accepted.plan == teacher.plan and accepted.vote == teacher.vote
          accepted.source = dsScripted
          result.add(accepted)
          let system = systemPrompt(view, seat, selection)
          let user = userPrompt(view, seat, "", cause)
          let messages = %*[{"role": "system", "content": system}, {"role": "user", "content": user}]
          let attemptId = $records.len & "-teacher"
          pending[$view.decisions & "-" & $seat] = records.len
          records.add(%*{"schema_version": "1", "event_type": "decision",
            "episode_id": episode, "decision_id": $records.len, "decision_index": records.len,
            "game": "hidden-agenda", "game_version": "source-" & revision,
            "source_revision": revision, "seat": $seat, "visibility": "private",
            "observation": {"view": seatView(view, seat, cause),
              "prompt_template": selection.promptMetadata(system, user)},
            "prompt": messages, "attempts": [{"attempt_id": attemptId,
              "policy": "scripted-miner-and-lurker", "origin": "teacher",
              "inference_mode": "text_action", "prompt": messages,
              "response": $proposal, "parsed_action": accepted.decisionAction(view.config.chat),
              "accepted": true, "rejection_reason": newJNull(), "request": newJNull(),
              "platform_call_id": newJNull(), "behavior_logprobs": newJNull()}],
            "selected_attempt_id": attemptId, "executed_action": newJNull(),
            "action_status": "accepted", "fallback_origin": newJNull(), "terminal": false})
      game.runEpisode(decide)
      game.finalise()
      doAssert game.reason == "complete"
      for event in game.log.rows:
        if event["k"].getStr() == "order":
          let key = $event["decision"].getInt() & "-" & $event["seat"].getInt()
          let index = pending[key]
          var action = %*{"plan": event["plan"], "vote": event["vote"],
            "say": event["say"], "hunch": event["hunch"], "notes": event["notes"]}
          if event["switch"].kind != JNull: action["switch"] = event["switch"]
          records[index]["executed_action"] = action
          records[index]["observation"]["applied_order"] = event
          pending.del(key)
      doAssert pending.len == 0 and records.len > 0
      records[^1]["terminal"] = %true
      for record in records: stream.writeLine($record)
      let results = game.resultsJson()
      var participants = newJObject()
      for seat in 0 ..< Seats: participants[$seat] = %*{"score": game.scores[seat]}
      stream.writeLine($(%*{"schema_version": "1", "event_type": "episode",
        "episode_id": episode, "seed_family": family, "game": "hidden-agenda",
        "game_version": "source-" & revision, "source_revision": revision,
        "status": "completed", "outcome": results, "participant_outcomes": participants}))
      writePrivate(output / (episode & ".replay.json"), replayBytes(game))
      runs.add(%*{"episode_id": episode, "seed": seed, "ticks": game.tick,
        "decisions": records.len, "scores": results["scores"], "reason": game.reason,
        "replay": episode & ".replay.json"})
  finally:
    stream.close()
  writePrivate(output / "manifest.json", pretty(%*{"schema_version": "1",
    "format": "coworld-private-candidates-v1", "game": "hidden-agenda",
    "review_required": true, "variant": variant, "source_revision": revision,
    "prompt_selection": selection.selectionMetadata(), "teacher": "miner-and-lurker",
    "runs": runs}) & "\n")
  echo "complete games=", episodes
