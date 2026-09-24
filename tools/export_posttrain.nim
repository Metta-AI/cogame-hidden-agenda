## Complete native episodes with the exact hosted prompt for each active seat.

import std/[json, os, osproc, strutils]
import hidden_agenda/[sim, scripted, llm]

proc reply(decision: Decision, chat: bool): JsonNode =
  var plan = newJArray()
  for step in decision.plan:
    var order = %*{"job": $step.job}
    if step.at.len > 0: order["at"] = %step.at
    if step.who.len > 0: order["who"] = %step.who
    if step.room.len > 0: order["room"] = %step.room
    plan.add(order)
  result = %*{
    "plan": plan, "vote": decision.vote,
    "say": (if chat: decision.say else: ""),
    "hunch": decision.hunch, "notes": decision.notes
  }
  if decision.switchIf.len > 0:
    result["switch"] = %*{"if": decision.switchIf,
      "to": decision.switchTo}

when isMainModule:
  let args = commandLineParams()
  if args.len != 3:
    quit("usage: hidden-agenda-posttrain OUTPUT EPISODES VARIANT", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let variant = args[2]
  if episodes < 10: quit("at least ten games are required", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  createDir(output)
  let revision = execProcess("git rev-parse HEAD").strip()
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in 1 .. episodes:
    variantConfig["seed"] = %seed
    var config = defaultGameConfig()
    config.update($variantConfig)
    var game = initSim(config)
    var rows: seq[string]
    proc decide(view: var Sim, seats: seq[int], cause: string):
        seq[Decision] {.closure.} =
      for seat in seats:
        let baseline = if view.cogs[seat].role == rImpostor:
          skLurker else: skMiner
        let teacher = scriptedDecision(view, seat, baseline, view.inMeeting)
        let completion = reply(teacher, view.config.chat)
        var accepted = view.parseReply(seat, completion)
        doAssert accepted.plan == teacher.plan
        doAssert accepted.vote == teacher.vote
        accepted.source = dsScripted
        result.add(accepted)
        rows.add($(%*{
          "episode_id": "hidden-agenda-" & variant & "-" & $seed,
          "seed": "hidden-agenda-" & variant & "-" & $seed,
          "decision_id": rows.len,
          "prompt": [
            {"role": "system", "content": systemPrompt(view, seat)},
            {"role": "user", "content": userPrompt(view, seat, "", cause)}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "hidden-agenda",
          "action_schema_revision": "hidden-agenda-reply-v1"
        }))
    game.runEpisode(decide)
    doAssert game.reason == "complete"
    if seed mod 5 == 0: validationRows.add(rows)
    else: trainRows.add(rows)
    let results = game.resultsJson()
    runs.add(%*{
      "seed": seed, "ticks": game.tick, "decisions": rows.len,
      "scores": results["scores"], "reason": results["reason"]
    })
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "hidden-agenda", "variant": variant,
    "source_revision": revision, "teacher": "miner-and-lurker",
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len, "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
