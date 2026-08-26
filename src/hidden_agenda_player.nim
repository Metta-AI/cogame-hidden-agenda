## Hidden Agenda player: a policy is just a prompt.
##
## Forked from `cogame-bullwhip/src/bullwhip_player.nim`. The container is
## deliberately thin: it connects, delivers its prompt (or its baseline name),
## and thereafter only listens. Every decision is made inside the GAME
## container, which is what makes one parallel batch per decision point
## possible.
##
## PLAYER_SCRIPTED=miner registers the seat as the built-in working baseline;
## PLAYER_SCRIPTED=lurker as the loud foil. The server plays those
## deterministically, no LLM.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <hidden-agenda-image> --name my-hidden-agenda \
##     --run /bin/hidden-agenda-player --secret-env PLAYER_PROMPT="<strategy>"

import std/[json, options, os, strutils, unicode]
import whisky

const
  ConnectAttempts = 5
  ConnectBackoffMs = 250
  MaxPromptChars = 4000
  DefaultPrompt = """
Whichever role you draw, this game is won by controlling who can see what.
AS CREW: deposits first, evidence second. Chain "mine" then "deposit" in every
plan and work the galleries S2 and S5 while they hold gems; a crewmate alone in
a vault is a free freeze. At a meeting, vote what you SAW: a witnessed freeze is
proof, then a long gap in the last-seen table that ends with a body, then
whoever was at the grate when the counter did not move. With nothing solid,
vote skip - a wrong ejection is a free kill for the impostor.
AS IMPOSTOR: be patient and be boring. Mine and deposit like everyone else, but
never fake a deposit while anything is in view. Lurk in a vault whose seam still
has gems and let a crewmate walk to you; hunt only when your own view is empty,
and remember your view is a cone - somebody behind you can see you.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  let scripted = getEnv("PLAYER_SCRIPTED").strip()
  if prompt.strip().len == 0 and scripted.len == 0:
    prompt = DefaultPrompt
  ## Rune boundaries, never bytes: this string is echoed into the game's own
  ## logs and a byte cut puts invalid UTF-8 on the wire.
  if prompt.runeLen > MaxPromptChars:
    prompt = prompt.runeSubStr(0, MaxPromptChars)

  proc promptFrame(): string =
    $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted}

  var socket: WebSocket = nil
  for attempt in 1 .. ConnectAttempts:
    try:
      socket = newWebSocket(url)
      break
    except CatchableError as error:
      echo "hidden-agenda player: connect attempt ", attempt, " failed: ",
        error.msg
      if attempt == ConnectAttempts:
        ## A bounded retry, then leave quietly: the game declares the no-show
        ## itself and plays the seat on the miner baseline.
        echo "hidden-agenda player: giving up on ", url
        quit(0)
      sleep(ConnectBackoffMs * attempt)

  socket.send(promptFrame())
  echo "hidden-agenda player: prompt delivered (", prompt.len, " chars",
    (if scripted.len > 0: ", scripted " & scripted else: ", llm"), ")"

  while true:
    ## whisky RAISES rather than returning none on both a close frame and a
    ## half-read one, and mummy's `send` only queues: the game writes its
    ## artifacts and exits, so a seat can lose the socket before its `final`
    ## frame is flushed. The episode is over either way — a player that dies
    ## here exits 1 and fails certification with `player_error` (raid
    ## 0.1.3 -> 0.1.4, 2026-08-23).
    var received: Option[Message]
    try:
      received = socket.receiveMessage()
    except CatchableError as error:
      echo "hidden-agenda player: connection ended (", error.msg, "), exiting"
      break
    if received.isNone:
      echo "hidden-agenda player: connection closed, exiting"
      break
    let message = received.get()
    if message.kind != TextMessage:
      continue
    try:
      let payload = parseJson(message.data)
      case payload{"type"}.getStr()
      of "welcome":
        echo "hidden-agenda player: seated at slot ",
          payload{"slot"}.getInt(), " as ", payload{"name"}.getStr(),
          " (", payload{"role"}.getStr(), ")"
        ## Re-deliver the prompt after the welcome, in case the first send
        ## raced the server's slot registration.
        socket.send(promptFrame())
      of "state":
        discard
      of "final":
        echo "hidden-agenda player: final scores ", payload{"scores"}
        break
      else:
        discard
    except CatchableError as error:
      echo "hidden-agenda player: ignoring bad frame: ", error.msg
  try:
    socket.close()
  except CatchableError:
    discard
  quit(0)
