## Hidden Agenda policy: rank ordinary plans and meeting votes from one seat view.

import std/[json, os, strutils]
import curly

proc chooseAction*(observation: JsonNode): JsonNode =
  let meeting = observation["phase"].getStr() == "meeting"
  let role = observation["role"].getStr()
  var actions = newJObject()
  let vote = if meeting: "skip" else: ""
  var productivePlan = newJArray()
  let seams = observation["station"]["seams"]
  if role == "crew":
    if observation["you"]["carrying"].getInt() > 0:
      productivePlan.add(%*{"job": "deposit"})
    if seams.len > 0:
      let here = observation["you"]["cell"]
      var bestDistance = high(int)
      var bestSeam = ""
      for seam in seams:
        let cell = seam["cell"]
        var distance = abs(here[0].getInt() - cell[0].getInt()) +
          abs(here[1].getInt() - cell[1].getInt())
        for seen in observation["seamsSeen"]:
          if seen["id"].getStr() == seam["id"].getStr() and
              seen["gems"].getInt() == 0:
            distance += 40
        if distance < bestDistance:
          bestDistance = distance
          bestSeam = seam["id"].getStr()
      productivePlan.add(%*{"job": "mine", "at": bestSeam})
      if observation["you"]["carrying"].getInt() == 0:
        productivePlan.add(%*{"job": "deposit"})
  else:
    for cog in observation["roster"]:
      let alias = cog["alias"].getStr()
      if alias != observation["name"].getStr() and
          cog["state"].getStr() == "active":
        let hunt = %*{"job": "hunt", "who": alias}
        let strike = %*{"job": "strike", "who": alias}
        actions["hunt_" & alias] = %*{"plan": [hunt], "vote": vote}
        actions["strike_" & alias] = %*{"plan": [strike], "vote": vote}
        if productivePlan.len == 0:
          productivePlan.add(hunt)
  if productivePlan.len == 0:
    productivePlan.add(%*{"job": "guard"})
  actions["advance"] = %*{"plan": productivePlan, "vote": vote}
  actions["guard"] = %*{"plan": [{"job": "guard"}], "vote": vote}
  let rooms = observation["station"]["rooms"]
  if rooms.len > 0:
    actions["patrol"] = %*{"plan": [{"job": "patrol",
      "room": rooms[0].getStr()}], "vote": vote}
    if role == "impostor":
      actions["lurk"] = %*{"plan": [{"job": "lurk",
        "room": rooms[0].getStr()}], "vote": vote}
  if meeting:
    for cog in observation["roster"]:
      let alias = cog["alias"].getStr()
      if alias != observation["name"].getStr() and
          cog["state"].getStr() == "active":
        actions["vote_" & alias] = %*{
          "plan": productivePlan, "vote": alias}

  var criteria = newJObject()
  for name, action in actions.pairs:
    let consequence =
      if name.startsWith("hunt_"):
        "Pursue and freeze only without a third cog watching. "
      elif name.startsWith("strike_"):
        "Pursue and freeze even if witnessed; a witness may get you ejected. "
      elif name == "advance" and role == "crew":
        "Mine and deposit gems to advance the crew win counter. "
      else:
        ""
    criteria[name] = %(consequence & name & ": " & $action)
  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  var endpoint: string
  var model: string
  var key: string
  if sidecar.len > 0:
    endpoint = sidecar
    model = "typesafe/jev-1.13"
  elif capture.len > 0:
    endpoint = capture
    model = getEnv("METTA_CAPTURE_MODEL", "jev-latest")
    key = getEnv("METTA_CAPTURE_KEY").strip()
  else:
    endpoint = getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
    model = getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
    key = getEnv("TYPESAFE_API_KEY").strip()
  if endpoint.len == 0 or (sidecar.len == 0 and key.len == 0):
    raise newException(ValueError,
      "Hidden Agenda Jev policy has no model transport")

  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  else:
    headers["x-coworld-player-slot"] = $observation["slot"].getInt()
  let body = %*{
    "model": model,
    "state": "You are playing Hidden Agenda. Crew win by depositing " &
      "enough gems or ejecting the impostor. Mining without depositing " &
      "does not advance the crew counter. The impostor wins by freezing " &
      "crew until only one remains; fake deposits never score. " &
      "A witnessed freeze triggers an immediate meeting and may get the " &
      "impostor ejected; hunting waits for an unwitnessed freeze. " &
      "During meetings, votes are simultaneous, and a tie or skip majority " &
      "ejects nobody. Advance your own role's score. This seat-private " &
      "observation is all you may use:\n" &
      $observation,
    "questions": {"decision": {
      "type": "choice",
      "instructions": "Choose the plan and vote that best advances your score.",
      "criteria": criteria
    }}
  }
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body, 30)
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let payload = parseJson(response.body)
  let answer = payload["answers"]["decision"]
  let probabilities = answer["probabilities"]
  if answer["type"].getStr() != "choice" or
      probabilities.len != criteria.len or
      answer["confidence"].getFloat() < 0 or
      answer["confidence"].getFloat() > 1:
    raise newException(ValueError, "Jev returned the wrong choice set")
  var best = -1.0
  var total = 0.0
  var selected = ""
  for choice, probability in probabilities.pairs:
    if not criteria.hasKey(choice):
      raise newException(ValueError, "Jev returned an unknown choice")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += value
    if value > best:
      best = value
      selected = choice
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")
  echo "Hidden Agenda Jev player: choice ", selected,
    " model ", payload{"model"}.getStr(),
    " input_tokens ", payload["usage"]{"input_tokens"}.getInt(),
    " output_tokens ", payload["usage"]{"output_tokens"}.getInt()
  result = actions[selected]
