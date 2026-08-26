## tests/test_replay.nim — end to end, plus a STRICT UTF-8 parse.
##
## Plays a full scripted episode headless, writes `results.json` and the replay,
## then re-reads the replay BYTES.

import std/[json, strutils, tables, unicode]
import support/helpers
import hidden_agenda/[sim_types, station, sim_config, sim_state, sim, replays]

template check(condition: bool, message: string) =
  if not condition:
    echo "FAIL: ", message
    quit(1)

proc utf8Valid(text: string): bool =
  validateUtf8(text) == -1

block endToEnd:
  ## An all-`miner` episode: it mines, deposits, meets and votes, which is
  ## what the event assertions below are for. (The CAUGHT!-banner path is
  ## covered by the certification fixture in tests/test_manifest.nim.)
  var config = baseConfig(9, "hidden-agenda-notalk")
  config.impostorSlot = 4
  let sim = playEpisode(config, uniformKinds(skMiner))
  let bytes = replayBytes(sim)

  check(utf8Valid(bytes), "the replay bytes must be STRICT valid UTF-8")
  check(bytes.len < 8 * 1024 * 1024,
    "the replay must be under 8 MiB, got " & $bytes.len)

  let doc = parseJson(bytes)
  check(doc{"protocol"}.getStr() == ReplayProtocol,
    "the protocol string is pinned")
  check(doc{"game"}.getStr() == GameName, "the game name is pinned")
  check(doc{"gameVersion"}.getStr() == GameVersion, "the version is pinned")
  check(doc{"tickHz"}.getInt() == TargetFps, "the tick rate is pinned")

  let ticksPlayed = doc{"results"}{"ticks"}.getInt()
  let frames = doc{"frames"}
  check(frames.len == ticksPlayed,
    "frames.len (" & $frames.len & ") must equal results.ticks (" &
    $ticksPlayed & ")")
  for frame in frames:
    check(frame{"c"}.len == Seats * 6,
      "every frame's c array has exactly 30 integers")
    check(frame{"v"}.len == Seats, "and v exactly 5")
    check(frame{"g"}.len == SeamTable.len, "and one gem count per seam")

  let roles = doc{"roles"}
  check(roles.len == Seats, "roles.len == 5")
  var impostors = 0
  for role in roles:
    check(role.getStr() in ["crew", "impostor"], "each role is in the enum")
    if role.getStr() == "impostor":
      impostors.inc
  check(impostors == 1, "exactly one impostor")
  check(doc{"policyNames"}.len == Seats, "five policy names")
  check(doc{"names"}.len == Seats, "five aliases")
  check(doc{"colors"}.len == Seats, "five body colours")

  let grid = doc{"config"}{"grid"}
  check(grid.len == MapRows, "config.grid is 19 strings")
  for row in grid:
    check(row.getStr().len == MapCols, "each 27 characters wide")

  var kinds2 = initCountTable[string]()
  for row in doc{"events"}:
    let t = row{"t"}.getInt()
    check(t >= 0 and t <= ticksPlayed,
      "every event tick is inside 0..ticksPlayed, got " & $t)
    kinds2.inc(row{"k"}.getStr())
  check(kinds2["reveal"] == Seats, "exactly five reveal rows")
  for row in doc{"events"}:
    if row{"k"}.getStr() == "reveal":
      check(row{"t"}.getInt() == 0, "every reveal row is at tick 0")
  check(kinds2["mine"] >= 1, "at least one mine")
  check(kinds2["deposit"] >= 1, "at least one deposit")
  check(kinds2["meeting"] >= 1, "at least one meeting")
  check(kinds2["vote"] >= 1, "at least one vote")
  check(kinds2["end"] == 1, "exactly one end row")
  check(kinds2["order"] >= Seats, "at least one order row per seat")

  let results = doc{"results"}
  check(results{"scores"}.len == Seats, "five scores")
  var total = 0
  for score in results{"scores"}:
    total += score.getInt()
  check(total == 0, "the scores must sum to exactly 0, got " & $total)
  check(results{"reason"}.getStr() in ["complete", "deadline", "forfeit"],
    "results.reason is one of the three legal values")
  check(results{"ending"}.getStr() in ["crew_deposits", "impostor_ejected",
    "impostor_isolation", "timeout", "deadline", "forfeit"],
    "results.ending is one of the six legal values")
  check(results{"winner"}.getStr() in ["crew", "impostor", "none"],
    "results.winner is one of the three legal values")
  check(results{"names"}.len == Seats and results{"aliases"}.len == Seats,
    "results carries both name spaces")

  ## The bundle reads this back with the same parser the wasm module uses.
  let replay = parseReplay(bytes)
  check(replay.frames.len == frames.len, "the parser sees every frame")
  check(replay.roles.len == Seats, "and every role")
  check(replay.maxTick() == frames.len - 1, "maxTick is the last index")

block runeTruncation:
  ## A seat is fed a say / hunch / notes of MULTI-BYTE runes exactly at the
  ## caps, and the recorded strings must be valid UTF-8 and no longer than the
  ## cap in RUNES. A byte cut put invalid UTF-8 into a replay once and only a
  ## strict parser found it (bullwhip, 2026-08-22).
  var config = baseConfig(9, "hidden-agenda")
  config.maxTicks = 700
  config.impostorSlot = 4
  var sim = initSim(config)

  proc runic(count: int): string =
    for _ in 0 ..< count:
      result.add("\u00e9\u4e2d\u2026")

  proc noisy(view: var Sim, seats: seq[int], cause: string):
      seq[Decision] {.closure.} =
    var decisions: seq[Decision]
    for seat in seats:
      var decision = scriptedDecision(view, seat, skMiner, view.inMeeting)
      decision.say = cleanText(runic(200), MaxSayLen)
      decision.hunch = cleanText(runic(200), MaxHunchLen)
      decision.notes = cleanText(runic(200), MaxNotesLen)
      check(decision.say.runeLen <= MaxSayLen, "say is capped in runes")
      check(decision.hunch.runeLen <= MaxHunchLen, "hunch is capped in runes")
      check(decision.notes.runeLen <= MaxNotesLen, "notes is capped in runes")
      decisions.add(decision)
    decisions

  sim.runEpisode(noisy)
  sim.finalise()
  let bytes = replayBytes(sim)
  check(utf8Valid(bytes),
    "multi-byte runes at the cap must leave the replay valid UTF-8")
  let doc = parseJson(bytes)
  var sawSay = false
  for row in doc{"events"}:
    case row{"k"}.getStr()
    of "say":
      sawSay = true
      let text = row{"text"}.getStr()
      check(text.runeLen <= MaxSayLen, "a recorded say is capped in runes")
      check(utf8Valid(text), "and is valid UTF-8")
    of "order":
      check(row{"hunch"}.getStr().runeLen <= MaxHunchLen, "hunch cap")
      check(row{"notes"}.getStr().runeLen <= MaxNotesLen, "notes cap")
    else:
      discard
  check(sawSay, "the chat variant must actually record a say")

block cleanTextIsRuneSafe:
  let text = "\u00e9\u00e9\u00e9\u00e9\u00e9"
  check(cleanText(text, 3).runeLen == 3, "cut to exactly the cap in runes")
  check(utf8Valid(cleanText(text, 3)), "and never mid-rune")
  check(cleanText("short", 40) == "short", "under the cap is untouched")
  check(oneLine("a\nb", 40) == "a b", "newlines become spaces")

echo "test_replay: ok"
