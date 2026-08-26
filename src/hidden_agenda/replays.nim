## The replay file (`hidden_agenda.replay.v1`) and its playback runtime.
##
## Rewritten from `coworld-ctf/src/ctf/replays.nim` + `replay_runtime.nim`:
## Hidden Agenda records STATE, not inputs, so playback never re-simulates, a
## seek is an array index, and there is no native/wasm divergence to chase
## (which is also why `#mmwarn` and a mismatch tick are dropped).
##
## The bytes are self-sufficient: aliases, policy names, ROLES, body colours,
## the entire map as ASCII, every rule constant, the seed, per-tick state, the
## per-tick visibility masks, the race series, the beat timeline, every event
## and the final results. The viewer contacts no server except S3 for the file.

import std/[json, strutils, tables]
import sim_types, sim_config, sim_state, events, sim

# ---------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------

proc framesJson(sim: Sim): JsonNode =
  result = newJArray()
  for frame in sim.frames:
    var c = newJArray()
    for value in frame.c:
      c.add(%value)
    var v = newJArray()
    for value in frame.v:
      v.add(%value)
    var g = newJArray()
    for value in frame.g:
      g.add(%value)
    result.add(%*{"t": frame.t, "c": c, "v": v, "g": g, "d": frame.d,
      "ph": frame.m})

proc beatsJson(sim: Sim): JsonNode =
  result = newJArray()
  for beat in sim.beats:
    var node = %*{"t": beat.t, "k": beat.kind}
    if beat.n != 0: node["n"] = %beat.n
    if beat.who.len > 0: node["who"] = %beat.who
    if beat.winner.len > 0: node["winner"] = %beat.winner
    result.add(node)

proc replayJson*(sim: Sim): JsonNode =
  ## `roles[]` is written into the header HERE, after the episode, by the same
  ## writer that writes `results` — so no player process can ever read it.
  var names = newJArray()
  var policyNames = newJArray()
  var roles = newJArray()
  var colors = newJArray()
  for slot in 0 ..< Seats:
    names.add(%Aliases[slot])
    policyNames.add(%sim.policyNames[slot])
    roles.add(%($sim.cogs[slot].role))
    colors.add(%Colors[slot])
  var race = newJArray()
  for row in sim.raceSeries:
    race.add(%[row[0], row[1], row[2]])
  var crew = newJArray()
  for row in sim.crewSeries:
    crew.add(%[row[0], row[1]])
  %*{
    "protocol": ReplayProtocol,
    "game": GameName,
    "gameVersion": GameVersion,
    "seed": sim.config.seed,
    "tickHz": TargetFps,
    "names": names,
    "policyNames": policyNames,
    "roles": roles,
    "colors": colors,
    "config": replayConfigJson(sim.config),
    "frames": framesJson(sim),
    "series": {"race": race, "crew": crew},
    "beats": beatsJson(sim),
    "events": sim.log.eventsJson(),
    "results": sim.resultsJson()
  }

proc replayBytes*(sim: Sim): string =
  $replayJson(sim)

# ---------------------------------------------------------------------------
# Reading + playback
# ---------------------------------------------------------------------------

type
  ReplayFrame* = object
    t*: int
    c*: seq[int]
    v*: seq[int]
    g*: seq[int]
    d*: int
    ph*: int

  Replay* = object
    doc*: JsonNode
    config*: GameConfig
    names*: seq[string]
    policyNames*: seq[string]
    roles*: seq[string]
    colors*: seq[string]
    frames*: seq[ReplayFrame]
    eventsByTick*: Table[int, seq[JsonNode]]
    beats*: JsonNode
    race*: seq[array[3, int]]
    crew*: seq[array[2, int]]
    results*: JsonNode
    seed*: int

  Playback* = object
    tick*: int
    playing*: bool
    speedIndex*: int
    looping*: bool
    skipLulls*: bool
    endHoldFrames*: int

proc parseReplay*(data: string): Replay =
  let doc = parseJson(data)
  if doc{"protocol"}.getStr() != ReplayProtocol:
    raise newException(HiddenAgendaError,
      "not a " & ReplayProtocol & " replay: " & doc{"protocol"}.getStr())
  result.doc = doc
  result.seed = doc{"seed"}.getInt()
  result.config = configFromReplayJson(doc{"config"})
  for node in doc{"names"}.getElems():
    result.names.add(node.getStr())
  for node in doc{"policyNames"}.getElems():
    result.policyNames.add(node.getStr())
  for node in doc{"roles"}.getElems():
    result.roles.add(node.getStr())
  for node in doc{"colors"}.getElems():
    result.colors.add(node.getStr())
  for node in doc{"frames"}.getElems():
    var frame = ReplayFrame(t: node{"t"}.getInt(), d: node{"d"}.getInt(),
      ph: node{"ph"}.getInt())
    for value in node{"c"}.getElems():
      frame.c.add(value.getInt())
    for value in node{"v"}.getElems():
      frame.v.add(value.getInt())
    for value in node{"g"}.getElems():
      frame.g.add(value.getInt())
    result.frames.add(frame)
  if result.frames.len == 0:
    raise newException(HiddenAgendaError, "replay carries no frames")
  result.eventsByTick = initTable[int, seq[JsonNode]]()
  for node in doc{"events"}.getElems():
    let t = node{"t"}.getInt()
    if not result.eventsByTick.hasKey(t):
      result.eventsByTick[t] = @[]
    result.eventsByTick[t].add(node)
  result.beats = doc{"beats"}
  if result.beats == nil:
    result.beats = newJArray()
  let series = doc{"series"}
  if series != nil:
    for row in series{"race"}.getElems():
      let values = row.getElems()
      if values.len >= 3:
        result.race.add([values[0].getInt(), values[1].getInt(),
          values[2].getInt()])
    for row in series{"crew"}.getElems():
      let values = row.getElems()
      if values.len >= 2:
        result.crew.add([values[0].getInt(), values[1].getInt()])
  result.results = doc{"results"}
  if result.results == nil:
    result.results = newJObject()

proc maxTick*(replay: Replay): int =
  replay.frames.high

proc initPlayback*(): Playback =
  Playback(tick: 0, playing: true, speedIndex: 0, looping: false,
    skipLulls: false, endHoldFrames: 0)

proc speed*(playback: Playback): int =
  PlaybackSpeeds[clamp(playback.speedIndex, 0, PlaybackSpeeds.high)]

proc seek*(playback: var Playback, replay: Replay, tick: int) =
  playback.tick = clamp(tick, 0, replay.maxTick())
  playback.endHoldFrames = 0

proc applyCommand*(playback: var Playback, replay: Replay, command: string) =
  ## The transport vocabulary the inherited chrome sends, unchanged: a bare
  ## character for play/pause/speed/loop/skip/step, `s:<tick>` for a scrub.
  if command.len == 0:
    return
  if command.startsWith("s:"):
    let tick = try: parseInt(command[2 .. ^1]) except ValueError: -1
    if tick >= 0:
      playback.seek(replay, tick)
    return
  for ch in command:
    case ch
    of ' ':
      playback.playing = not playback.playing
    of 'p':
      playback.playing = true
    of 'P':
      playback.playing = false
    of '1': playback.speedIndex = 0
    of '2': playback.speedIndex = 1
    of '3': playback.speedIndex = 2
    of '4': playback.speedIndex = 3
    of '8': playback.speedIndex = 4
    of '6': playback.speedIndex = 5
    of '+', '=':
      playback.speedIndex = min(playback.speedIndex + 1, PlaybackSpeeds.high)
    of '-', '_':
      playback.speedIndex = max(playback.speedIndex - 1, 0)
    of ',', '<':
      playback.playing = false
      playback.seek(replay, 0)
    of 'b':
      playback.playing = false
      playback.seek(replay, playback.tick - 1)
    of 'e':
      playback.playing = false
      playback.seek(replay, replay.maxTick())
    of '.', '>':
      playback.playing = false
      playback.seek(replay, playback.tick + TargetFps * 5)
    of 'r':
      playback.looping = not playback.looping
    of 'f':
      playback.skipLulls = not playback.skipLulls
    else:
      discard

proc beatTicks*(replay: Replay): seq[int] =
  for node in replay.beats.getElems():
    result.add(node{"t"}.getInt())

proc lullSpans*(replay: Replay): seq[array[2, int]] =
  ## Stretches of at least 4 seconds with no beat in them. Shipped once on the
  ## first HUD frame so the scrubber shades what `f` skips before it is used.
  let ticks = replay.beatTicks()
  var marks = @[0]
  for t in ticks:
    marks.add(t)
  marks.add(replay.maxTick())
  var sorted = marks
  for i in 1 ..< sorted.len:
    var j = i
    while j > 0 and sorted[j] < sorted[j - 1]:
      swap(sorted[j], sorted[j - 1])
      j.dec
  for i in 1 ..< sorted.len:
    if sorted[i] - sorted[i - 1] >= TargetFps * 4:
      result.add([sorted[i - 1] + 1, sorted[i] - 1])

proc isLullTick*(replay: Replay, tick: int): bool =
  for span in replay.lullSpans():
    if tick >= span[0] and tick <= span[1]:
      return true
  false

proc advance*(playback: var Playback, replay: Replay) =
  ## One presentation frame. A looping replay does NOT restart the moment
  ## playback stops: the final frame holds for two seconds first.
  if not playback.playing:
    return
  if playback.tick >= replay.maxTick():
    if playback.looping:
      if playback.endHoldFrames < TargetFps * 2:
        playback.endHoldFrames.inc
      else:
        playback.endHoldFrames = 0
        playback.tick = 0
    return
  var steps = playback.speed()
  if playback.skipLulls and replay.isLullTick(playback.tick):
    steps *= 8
  playback.tick = min(playback.tick + steps, replay.maxTick())

proc eventsAt*(replay: Replay, fromTick, toTick: int): JsonNode =
  result = newJArray()
  if toTick < fromTick:
    return
  for t in fromTick .. toTick:
    if replay.eventsByTick.hasKey(t):
      for node in replay.eventsByTick[t]:
        result.add(node)
