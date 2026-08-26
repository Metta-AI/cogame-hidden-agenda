## tests/test_broadcast.nim — the chrome frame, and the page's scope discipline.

import std/[json, os, strutils]
import support/helpers
import hidden_agenda/[sim_types, station, sim_config, sim_state, sim,
  broadcast, global, replays]

template check(condition: bool, message: string) =
  if not condition:
    echo "FAIL: ", message
    quit(1)

const RepoRoot = currentSourcePath().parentDir().parentDir()

proc episode(): Sim =
  var config = baseConfig(13, "hidden-agenda-notalk")
  config.impostorSlot = 4
  config.maxTicks = 900
  var kinds = uniformKinds(skMiner)
  kinds[4] = skLurker
  playEpisode(config, kinds)

let game = episode()

block liveSnapshotShape:
  let packet = parseJson(globalSnapshot(game))
  check(packet{"meta"} != nil, "the first packet carries meta")
  check(packet{"b"} != nil, "and a board frame")
  let hud = packet{"hud"}
  check(hud != nil, "and the chrome state frame")

  ## `teams` keys are exactly crew and impostor.
  var teamKeys: seq[string]
  for key, _ in hud{"teams"}.pairs:
    teamKeys.add(key)
  check(teamKeys.len == 2, "exactly two teams")
  check("crew" in teamKeys and "impostor" in teamKeys,
    "keyed crew and impostor, got " & $teamKeys)

  ## roster: five entries carrying the ALIAS in name and the POLICY in pol.
  check(hud{"roster"}.len == Seats, "five roster entries")
  for entry in hud{"roster"}:
    let slot = entry{"s"}.getInt()
    check(entry{"name"}.getStr() == Aliases[slot],
      "roster.name is the in-game alias")
    check(entry{"pol"}.getStr() == game.policyNames[slot],
      "roster.pol is the POLICY name - both name spaces, spectator-side")
    check(entry{"team"}.getStr() in ["crew", "impostor"],
      "roster.team is a chrome team key")

  ## lead: the starter's own {teams, pts} shape, [t, crew, impostor] rows,
  ## both series bounded by depositTarget.
  let lead = hud{"lead"}
  check(lead != nil, "the lead series ships on the first HUD frame")
  check(lead{"teams"}.len == 2, "two lead series")
  check(lead{"teams"}[0].getStr() == "crew", "crew first")
  check(lead{"pts"}.len >= 1, "at least one change point")
  for row in lead{"pts"}:
    check(row.len == 3, "every row is [t, crew, impostor]")
    check(row[1].getInt() >= 0 and row[1].getInt() <= game.config.depositTarget,
      "the crew curve is bounded by depositTarget")
    check(row[2].getInt() >= 0 and row[2].getInt() <= game.config.depositTarget,
      "and so is the impostor curve, so both run 0 -> " &
      $game.config.depositTarget)

  ## The appended agenda block.
  let agenda = hud{"agenda"}
  for key in ["dep", "tgt", "crew", "imp", "cool", "roles", "m", "states"]:
    check(agenda{key} != nil, "the agenda block carries " & key)
  check(agenda{"roles"}.len == Seats, "five roles, spectator-side")
  check(agenda{"tgt"}.getInt() == game.config.depositTarget, "tgt is the target")
  check(agenda{"imp"}.getInt() == game.impostorSlot, "imp is the impostor slot")

  ## The terminal frame carries `over` with the ending string.
  check(hud{"over"} != nil, "the terminal frame carries over")
  check(hud{"over"}{"ending"}.getStr() == game.ending,
    "and it names the ending")
  check(hud{"over"}{"winner"}.getStr() == game.winner, "and the winner")

block beatsAreOnlyTheSixDeclaredKinds:
  const Declared = ["meeting", "freeze", "caught", "eject", "deposit",
    "gameover"]
  check(game.beats.len >= 2, "a real episode produces beats")
  for beat in game.beats:
    check(beat.kind in Declared,
      "the sim emitted the beat kind '" & beat.kind &
      "', which the page has no CSS for")
  var sawGameover = false
  for beat in game.beats:
    if beat.kind == "gameover":
      sawGameover = true
  check(sawGameover, "every episode ends with a gameover beat")

block replayPacketDrivesTheSameChrome:
  let replay = parseReplay(replayBytes(game))
  var viewer = initGlobalViewerState()
  let first = parseJson(buildReplayPacket(replay, viewer))
  check(first{"meta"} != nil, "the FIRST packet carries meta")
  check(first{"meta"}{"roles"}.len == Seats,
    "meta carries the roles the roster strip reveals")
  check(first{"meta"}{"policyNames"}.len == Seats, "and the policy names")
  check(first{"hud"}{"lead"} != nil, "the lead series ships once")
  check(first{"hud"}{"beats"} != nil, "and so does the beat timeline")
  check(first{"b"}{"c"}.len == Seats * 6, "the board frame is 30 integers")
  let second = parseJson(buildReplayPacket(replay, viewer))
  check(second{"meta"} == nil, "and never again")
  check(second{"hud"}{"lead"} == nil, "nor the once-only chrome")
  check(second{"b"}{"t"}.getInt() > first{"b"}{"t"}.getInt(),
    "playback advances")
  ## A seek lands exactly on the tick asked for.
  let target = min(120, replay.maxTick())
  viewer.applyGlobalViewerMessage("s:" & $target)
  let sought = parseJson(buildReplayPacket(replay, viewer))
  check(sought{"b"}{"t"}.getInt() == target, "a seek is an array index")
  ## And the meeting readout is derived from the events already played.
  viewer.applyGlobalViewerMessage("e")
  let final = parseJson(buildReplayPacket(replay, viewer))
  check(final{"hud"}{"over"} != nil, "jumping to the end shows the endcard")

block feedRowsAreCapped:
  ## Every string that can reach a feed row is capped at its declared length.
  for row in game.log.rows:
    case row{"k"}.getStr()
    of "say":
      check(row{"text"}.getStr().len <= MaxSayLen * 4,
        "a say never exceeds its rune cap in bytes")
    of "order":
      check(row{"hunch"}.getStr().len <= MaxHunchLen * 4, "hunch cap")
      check(row{"notes"}.getStr().len <= MaxNotesLen * 4, "notes cap")
    else:
      discard

block pageProvenance:
  ## The page is the STARTER's, not a lookalike: it must still carry every id
  ## the shared chrome reaches for, must NOT carry the four element families
  ## the design note removes, and must carry the banner comment that separates
  ## the inherited chrome from this game's block.
  let page = readFile(RepoRoot / "client" / "replay_broadcast.html")
  for id in ["stage", "viewport", "board", "chrome", "scorebug", "plates-l",
      "plates-r", "clock", "clock-time", "clock-caption", "tick-clock",
      "bannerlane", "killfeed", "grain", "lightpool", "speedchips",
      "ffwd-chip", "ffwd-mini", "win-chip", "transport", "btn-restart",
      "btn-back", "btn-play", "btn-fwd", "btn-skip", "btn-end", "btn-loop",
      "btn-spoilers", "scrub", "momentum", "scrub-fill", "lulls", "scrub-win",
      "scrub-head", "endcard", "ec-headline", "ec-how", "ec-teams",
      "ec-wincond", "ec-replay", "status", "lockerroom"]:
    check(("id=\"" & id & "\"") in page,
      "the inherited chrome element #" & id & " must survive")
  for id in ["viewpanel", "minimap", "minimap-canvas", "zoombar", "zoom-out",
      "zoom-slider", "zoom-in", "zoom-read", "fpv", "fpv-canvas", "fpv-hud",
      "fpv-name", "fpv-hp", "fpv-gear", "fpv-map", "fpv-map-canvas",
      "fpv-cap", "fpv-grip", "povBadge", "mmwarn"]:
    check(("id=\"" & id & "\"") notin page,
      "#" & id & " is removed by the design note and must be gone")
  check("HIDDEN-AGENDA additions to the inherited coworld-ctf chrome" in page,
    "the appended game block must carry its banner comment")
  ## The game block's own ids.
  for id in ["rosterstrip", "voteboard", "vb-head", "vb-rows", "vb-count",
      "ec-roles"]:
    check(("id=\"" & id & "\"") in page,
      "the appended block must carry #" & id)
  ## Transport rules.
  check("--band" in page and "--hudscale" in page and "--topband" in page,
    "relayout() sets --hudscale, --band and --topband on :root")
  check("RACE TO WIN" in page, "the momentum strip is re-lettered")
  check("Deposits" in page and "Crew left" in page,
    "the two plate labels are re-lettered")
  check("#lockerroom { pointer-events: none; }" in page,
    "the pre-load curtain must not swallow transport clicks")
  for kind in ["meeting", "freeze", "caught", "eject", "deposit", "gameover"]:
    check((".beat-marker." & kind) in page,
      "there must be CSS for the beat kind " & kind)
  check("button.beat-marker" in page,
    "scrubber beats are buttons, not divs")
  check("flex: 1 1 auto;" in page and "min-width: 3.2em;" in page,
    "the plate name must survive a 360px featured-match iframe")

block noScopeDuplication:
  ## A game-block `function markBeat` is HOISTED over the chrome alias block's
  ## `var markBeat = C.markBeat` and silently kills every scrubber beat
  ## (cogame-tandem, 2026-08-23). Assert that no game-block function name
  ## collides with any name the page aliases out of the shared chrome.
  let script = readFile(RepoRoot / "client" / "replay_broadcast.html")
  var aliases: seq[string]
  for raw in script.splitLines():
    let line = raw.strip()
    if line.startsWith("var ") and " = C." in line and line.endsWith(";"):
      let name = line["var ".len ..< line.find(" = C.")]
      aliases.add(name.strip())
  check(aliases.len >= 5,
    "the alias block must actually alias the shared chrome, found " &
    $aliases.len)
  check("markBeat" in aliases, "markBeat is one of them")
  var declared: seq[string]
  for raw in script.splitLines():
    let line = raw.strip()
    if not line.startsWith("function "):
      continue
    let rest = line["function ".len .. ^1]
    let stop = rest.find('(')
    if stop > 0 and rest[0 ..< stop].strip().len > 0:
      declared.add(rest[0 ..< stop].strip())
  check(declared.len >= 10, "the game block declares real functions")
  for name in declared:
    check(name notin aliases,
      "the game block declares `function " & name & "`, which is hoisted " &
      "over the chrome alias `var " & name & " = C." & name & "`")
  check("buildAgendaBeats" in declared,
    "the beat builder must be named buildAgendaBeats, never markBeat")

echo "test_broadcast: ok"
