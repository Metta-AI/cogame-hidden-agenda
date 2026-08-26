## The `/global` spectator emitter and the replay viewer's packet builder.
##
## Fork of `coworld-ctf/src/ctf/global.nim`, heavily reduced. What is kept: the
## packet emitter, the once-only chrome smuggling (the lead series, the beats
## and the lull spans ship on the FIRST hud frame and never again), the viewer
## command channel, and `boardRenderScaleFor`. What is deleted: first-person
## PiP, articulated rig art, the gun / grenade / spray / shield / barrier sprite
## families, endzone bakes, perks and handicaps — none of them exist here.
##
## The packet is one JSON document per frame:
##   {"meta": {...} (first packet only), "b": {board frame}, "hud": {chrome}}
## `client/broadcast_core.js` parses it, draws the board, and hands `hud` to the
## page through the starter's own `onText` channel.

import std/[json, strutils, tables]
import sim_types, sim_config, sim_state, sim, broadcast, replays,
  meeting

type
  GlobalViewerState* = object
    playback*: Playback
    commands*: seq[string]
    metaSent*: bool
    leadSent*: bool
    lastTick*: int

proc initGlobalViewerState*(): GlobalViewerState =
  GlobalViewerState(playback: initPlayback(), metaSent: false,
    leadSent: false, lastTick: -1)

proc applyGlobalViewerMessage*(state: var GlobalViewerState,
    message: string) =
  ## One transport command per message: a bare character, or `s:<tick>`.
  let text = message.strip()
  if text.len > 0:
    state.commands.add(text)

proc boardRenderScaleFor*(cols, rows: int): int =
  ## The board is a FIXED 27 x 19 at 40 board-px, so it always fits the frame
  ## and there is nothing to zoom to. Kept because the chrome asks for it.
  if cols * rows <= 0: 1 else: 1

# ---------------------------------------------------------------------------
# Meta / frame / chrome assembly
# ---------------------------------------------------------------------------

proc metaJson(meta: ViewMeta): JsonNode =
  var aliases = newJArray()
  for value in meta.aliases:
    aliases.add(%value)
  var policies = newJArray()
  for value in meta.policyNames:
    policies.add(%value)
  var roles = newJArray()
  for value in meta.roles:
    roles.add(%value)
  var colors = newJArray()
  for value in meta.colors:
    colors.add(%value)
  %*{
    "aliases": aliases, "policyNames": policies, "roles": roles,
    "colors": colors, "config": meta.config,
    "cell": CellPx, "boardW": BoardW, "boardH": BoardH
  }

proc frameJson(frame: ViewFrame): JsonNode =
  var c = newJArray()
  var v = newJArray()
  for cog in frame.cogs:
    c.add(%cog.x)
    c.add(%cog.y)
    c.add(%cog.facing)
    c.add(%cog.state)
    c.add(%cog.carry)
    c.add(%cog.mineProgress)
    v.add(%cog.vis)
  var g = newJArray()
  for value in frame.gems:
    g.add(%value)
  %*{"t": frame.t, "c": c, "v": v, "g": g, "d": frame.deposits,
    "ph": frame.meetingPhase}

proc packetJson(meta: ViewMeta, frame: ViewFrame, chrome: ViewChrome,
    withMeta: bool): JsonNode =
  result = %*{
    "b": frameJson(frame),
    "hud": buildStateJson(meta, frame, chrome)
  }
  if withMeta:
    result["meta"] = metaJson(meta)

# ---------------------------------------------------------------------------
# Live spectator (/global), straight off the Sim
# ---------------------------------------------------------------------------

proc liveMeta*(sim: Sim): ViewMeta =
  for slot in 0 ..< Seats:
    result.aliases.add(Aliases[slot])
    result.policyNames.add(sim.policyNames[slot])
    result.roles.add($sim.cogs[slot].role)
    result.colors.add(Colors[slot])
  result.config = replayConfigJson(sim.config)

proc liveFrame*(sim: Sim): ViewFrame =
  result.t = sim.tick
  result.deposits = sim.deposits
  result.meetingPhase = ord(sim.meetingPhase)
  for slot in 0 ..< Seats:
    let cog = sim.cogs[slot]
    result.cogs[slot] = ViewCog(
      x: cog.x, y: cog.y, facing: ord(cog.facing),
      state: (
        case cog.state
        of csFrozen: 3
        of csEjected: 4
        else:
          if sim.inMeeting: 5
          elif cog.lastAction == aMine: 1
          elif cog.lastAction == aDeposit: 2
          else: 0),
      carry: cog.carry, mineProgress: cog.mineProgress,
      vis: sim.visibilityMask(slot))
  for seam in sim.seams:
    result.gems.add(seam.gems)

proc overJson*(sim: Sim): JsonNode =
  if not sim.done:
    return newJNull()
  %*{
    "winner": sim.winner, "ending": sim.ending, "reason": sim.reason,
    "deposits": sim.deposits, "depositTarget": sim.config.depositTarget,
    "freezes": sim.freezes, "witnessed": sim.witnessedFreezes,
    "ejections": sim.ejections, "wrong": sim.wrongEjections,
    "fake": sim.fakeDeposits, "meetings": sim.meetings.len,
    "results": sim.resultsJson()
  }

proc liveChrome*(sim: Sim, sendLead: bool): ViewChrome =
  result.maxTick = max(1, sim.tick)
  result.maxTicks = sim.config.maxTicks
  result.depositTarget = sim.config.depositTarget
  result.phase = if sim.done: "gameover" else: "playing"
  result.playing = true
  result.enabled = false
  result.speed = 1
  result.activeCrew = sim.activeCrew()
  result.impostorSlot = sim.impostorSlot
  result.freezeCooldown = sim.cogs[sim.impostorSlot].freezeCooldown
  result.freezeCooldownTicks = sim.config.freezeCooldownTicks
  result.meetingNumber = sim.meetingNumber
  result.meetingCause = $sim.meetingCause
  result.meetingIn =
    if sim.inMeeting:
      max(0, sim.config.resolveTick - (sim.tick - sim.meetingOpenTick))
    else:
      0
  result.votes = sim.votes
  var states: array[Seats, CogState]
  for slot in 0 ..< Seats:
    states[slot] = sim.cogs[slot].state
  result.tally = tallyJson(tallyOf(sim.votes, states))
  for row in sim.raceSeries:
    result.lead.add(row)
  result.beats = newJArray()
  result.sendLead = sendLead
  result.over = overJson(sim)
  result.events = newJArray()

proc globalSnapshot*(sim: Sim): string =
  let meta = liveMeta(sim)
  let frame = liveFrame(sim)
  let chrome = liveChrome(sim, sendLead = true)
  $packetJson(meta, frame, chrome, withMeta = true)

# ---------------------------------------------------------------------------
# Replay viewer packet
# ---------------------------------------------------------------------------

proc replayMeta*(replay: Replay): ViewMeta =
  result.aliases = replay.names
  result.policyNames = replay.policyNames
  result.roles = replay.roles
  result.colors = replay.colors
  result.config = replay.doc{"config"}
  if result.config == nil:
    result.config = newJObject()

proc replayFrame*(replay: Replay, tick: int): ViewFrame =
  let index = clamp(tick, 0, replay.frames.high)
  let frame = replay.frames[index]
  result.t = frame.t
  result.deposits = frame.d
  result.meetingPhase = frame.ph
  result.gems = frame.g
  for slot in 0 ..< Seats:
    let base = slot * 6
    if base + 5 < frame.c.len:
      result.cogs[slot] = ViewCog(
        x: frame.c[base], y: frame.c[base + 1], facing: frame.c[base + 2],
        state: frame.c[base + 3], carry: frame.c[base + 4],
        mineProgress: frame.c[base + 5],
        vis: (if slot < frame.v.len: frame.v[slot] else: 0))

proc replayOver(replay: Replay, tick: int): JsonNode =
  if tick < replay.maxTick():
    return newJNull()
  let results = replay.results
  %*{
    "winner": results{"winner"}.getStr(),
    "ending": results{"ending"}.getStr(),
    "reason": results{"reason"}.getStr(),
    "deposits": results{"deposits"}.getInt(),
    "depositTarget": results{"depositTarget"}.getInt(),
    "freezes": results{"freezes"}.getInt(),
    "witnessed": results{"witnessedFreezes"}.getInt(),
    "ejections": results{"ejections"}.getInt(),
    "wrong": results{"wrongEjections"}.getInt(),
    "fake": results{"fakeDeposits"}.getInt(),
    "meetings": results{"meetings"}.getInt(),
    "results": results
  }

proc replayChrome*(replay: Replay, state: GlobalViewerState,
    fromTick: int): ViewChrome =
  let tick = state.playback.tick
  result.maxTick = replay.maxTick()
  result.maxTicks = replay.config.maxTicks
  result.depositTarget = replay.config.depositTarget
  result.phase = if tick >= replay.maxTick(): "gameover" else: "playing"
  result.playing = state.playback.playing
  result.enabled = true
  result.speed = state.playback.speed()
  result.looping = state.playback.looping
  result.skipping = state.playback.skipLulls
  result.fastForward = state.playback.skipLulls and
    replay.isLullTick(tick)
  let frame = replayFrame(replay, tick)
  var crew = 0
  var impostor = 0
  for slot in 0 ..< Seats:
    if slot < replay.roles.len and replay.roles[slot] == "impostor":
      impostor = slot
    elif frame.cogs[slot].state notin [3, 4]:
      crew.inc
  result.activeCrew = crew
  result.impostorSlot = impostor
  result.freezeCooldownTicks = replay.config.freezeCooldownTicks
  result.meetingNumber = 0
  result.meetingCause = "cadence"
  result.lead = replay.race
  result.lulls = replay.lullSpans()
  result.beats = replay.beats
  result.sendLead = not state.leadSent
  result.over = replayOver(replay, tick)
  result.events = replay.eventsAt(fromTick, tick)
  ## The meeting readout comes from the events already played: the vote board
  ## reads `m.votes` / `m.tally` / `m.phase` and `phase` rides the frame.
  ##
  ## The two COUNTDOWNS ride the same walk. The impostor plate draws a
  ## freeze-cooldown pip bar and the vote board a `RESOLVES IN n`; neither
  ## quantity is in the frame encoding, and reporting 0 for both left the pip
  ## bar permanently full and the vote board permanently reading `RESOLVED`.
  ## Both are exact functions of the recorded rows and the recorded config:
  ## `sim.nim` sets the cooldown to `freezeCooldownTicks` at the freeze tick
  ## and decrements it once per tick from the next one (step 1), and a meeting
  ## resolves `resolveTick` ticks after the `meeting` row's tick.
  var votes: array[Seats, string]
  var meetingNumber = 0
  var cause = "cadence"
  var lastFreezeTick = -1
  var meetingOpenTick = -1
  for t in 0 .. tick:
    if not replay.eventsByTick.hasKey(t):
      continue
    for node in replay.eventsByTick[t]:
      case node{"k"}.getStr()
      of "meeting":
        meetingNumber = node{"n"}.getInt()
        cause = node{"cause"}.getStr()
        meetingOpenTick = t
        for slot in 0 ..< Seats:
          votes[slot] = ""
      of "freeze":
        lastFreezeTick = t
      of "vote":
        let slot = node{"seat"}.getInt()
        if slot >= 0 and slot < Seats:
          votes[slot] = node{"target"}.getStr()
      of "eject":
        discard
      else:
        discard
  result.meetingNumber = meetingNumber
  result.meetingCause = cause
  result.freezeCooldown =
    if lastFreezeTick < 0: 0
    else: max(0, replay.config.freezeCooldownTicks - (tick - lastFreezeTick))
  result.meetingIn =
    if frame.meetingPhase != 0 and meetingOpenTick >= 0:
      max(0, replay.config.resolveTick - (tick - meetingOpenTick))
    else:
      0
  if frame.meetingPhase == 0:
    for slot in 0 ..< Seats:
      votes[slot] = ""
  result.votes = votes
  var counts: seq[(string, int)]
  for slot in 0 ..< Seats:
    if votes[slot].len == 0 or votes[slot] == "skip":
      continue
    var found = false
    for i in 0 ..< counts.len:
      if counts[i][0] == votes[slot]:
        counts[i][1].inc
        found = true
        break
    if not found:
      counts.add((votes[slot], 1))
  result.tally = counts

proc buildReplayPacket*(replay: Replay, state: var GlobalViewerState): string =
  ## Applies queued viewer commands, advances one presentation frame, and emits
  ## the packet for it.
  let previous = state.playback.tick
  var jumped = false
  for command in state.commands:
    let before = state.playback.tick
    state.playback.applyCommand(replay, command)
    if state.playback.tick != before:
      jumped = true
  state.commands.setLen(0)
  if not jumped:
    state.playback.advance(replay)
  let fromTick =
    if jumped or state.playback.tick < previous: state.playback.tick
    else: min(previous + 1, state.playback.tick)
  let meta = replayMeta(replay)
  let frame = replayFrame(replay, state.playback.tick)
  var chrome = replayChrome(replay, state, fromTick)
  let withMeta = not state.metaSent
  state.metaSent = true
  if chrome.sendLead:
    state.leadSent = true
  state.lastTick = state.playback.tick
  $packetJson(meta, frame, chrome, withMeta)
