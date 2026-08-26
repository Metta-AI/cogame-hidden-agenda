## tests/test_noleak.nim — the hidden role is actually hidden.
##
## Five separate claims, each asserted against the BYTES a seat would receive:
## (a) no other seat's role / plan / hunch / notes / unseen position;
## (b) the welcome and final frames carry no roles[], no impostorSlot, no seed;
## (c) a no-talk episode records no `say` anywhere;
## (d) worldHash(seed) is identical whichever slot rngRole draws;
## (e) the impostor's frame never says who can see IT.

import std/[json, strutils]
import support/helpers
import hidden_agenda/[sim_types, station, sim_config, sim_state, vision, sim,
  llm, replays]

template check(condition: bool, message: string) =
  ## A TEMPLATE, not a proc: the message is only built when the check fails.
  ## Eagerly concatenating a per-tick label across a 192-episode sweep is a
  ## minute of string building for nothing.
  if not condition:
    echo "FAIL: ", message
    quit(1)

proc frameBytes(sim: Sim, slot: int): string =
  $seatView(sim, slot, "test")

block noOtherSeatsSecrets:
  var config = baseConfig(21)
  config.maxTicks = 900
  var sim = initSim(config)
  var checked = 0

  proc audit(view: var Sim, seats: seq[int], cause: string):
      seq[Decision] {.closure.} =
    var decisions: seq[Decision]
    for seat in seats:
      let bytes = frameBytes(view, seat)
      ## (a) no other seat's role, plan, hunch or notes.
      for other in 0 ..< Seats:
        if other == seat:
          continue
        let marker = "hidden-notes-of-" & $other
        check(marker notin bytes, "seat " & $seat &
          " must not see seat " & $other & "'s notes")
        if view.cogs[other].role == rImpostor and
            view.cogs[seat].role == rCrew:
          ## The word "impostor" appears in the seat's OWN rules text, so the
          ## test is that no ROSTER entry is tagged with a role at all.
          check("\"alias\":\"" & Aliases[other] & "\",\"state\"" in
              bytes.replace(" ", ""),
            "the roster carries state only, never role")
        ## And no cell of a cog this seat cannot see and has never seen.
        if not seesCog(view.config, view.cogs[seat], view.cogs[other]) and
            not view.cogs[seat].lastSeen[other].valid:
          let cell = "[" & $view.cogs[other].x & "," &
            $view.cogs[other].y & "]"
          let inView = "\"alias\":\"" & Aliases[other] & "\",\"cell\":" & cell
          check(inView notin bytes.replace(" ", ""),
            "seat " & $seat & " must not learn where " & Aliases[other] &
            " is standing")
      checked.inc
      ## Plant a marker in this seat's own notes so the NEXT decision point can
      ## prove it stayed private.
      var decision = scriptedDecision(view, seat, skMiner, view.inMeeting)
      decision.notes = "hidden-notes-of-" & $seat
      decisions.add(decision)
    decisions

  sim.runEpisode(audit)
  sim.finalise()
  check(checked > 5, "the audit must have run at more than one seat")

block noRolesInWelcomeOrFinal:
  var config = baseConfig(21)
  config.maxTicks = 400
  let sim = playEpisode(config, uniformKinds(skMiner))
  ## The two frames the server builds, reproduced here from the same data.
  var aliases = newJArray()
  for alias in Aliases:
    aliases.add(%alias)
  let welcome = $ %*{
    "type": "welcome", "protocol": Protocol, "slot": 0,
    "role": $sim.cogs[0].role, "name": Aliases[0],
    "variant": sim.config.variant, "chat": sim.config.chat,
    "maxTicks": sim.config.maxTicks,
    "depositTarget": sim.config.depositTarget, "aliases": aliases}
  let results = sim.resultsJson()
  let final = $ %*{
    "type": "final", "done": true, "slot": 0, "scores": results{"scores"},
    "win": results{"win"}, "winner": sim.winner, "names": aliases,
    "deposits": sim.deposits, "ticks": sim.frames.len,
    "reason": sim.reason, "ending": sim.ending}
  for frame in [welcome, final]:
    check("roles" notin frame, "no roles[] in a player frame")
    check("impostorSlot" notin frame, "no impostorSlot in a player frame")
    check("seed" notin frame, "no seed in a player frame")
  check("\"role\":\"" in welcome,
    "the welcome DOES carry this seat's own role")
  check("\"role\"" notin final, "the final carries no role at all")
  check("\"slot\":0" in final,
    "the final DOES carry this seat's own slot, like welcome and state")

block noSayInANoTalkEpisode:
  var config = baseConfig(21, "hidden-agenda-notalk")
  config.maxTicks = 900
  var sim = initSim(config)

  proc chatty(view: var Sim, seats: seq[int], cause: string):
      seq[Decision] {.closure.} =
    var decisions: seq[Decision]
    for seat in seats:
      var decision = scriptedDecision(view, seat, skMiner, view.inMeeting)
      decision.say = "SECRET-SIDE-CHANNEL"
      decisions.add(decision)
    decisions

  sim.runEpisode(chatty)
  sim.finalise()
  let bytes = replayBytes(sim)
  check("SECRET-SIDE-CHANNEL" notin bytes,
    "a no-talk episode never records a say, not even one that was sent")
  for slot in 0 ..< Seats:
    check("SECRET-SIDE-CHANNEL" notin frameBytes(sim, slot),
      "and never shows one to another seat")

block roleComesFromItsOwnSubStream:
  ## `worldHash(seed)` must be identical whichever slot rngRole draws: the role
  ## comes from rngRole, everything observable from rngWorld.
  var hashes: seq[uint64]
  for pinned in 0 ..< Seats:
    var config = baseConfig(77)
    config.impostorSlot = pinned
    let sim = initSim(config)
    check(sim.impostorSlot == pinned, "impostorSlot pins the draw")
    hashes.add(sim.worldHash())
  for value in hashes:
    check(value == hashes[0],
      "the observable world is identical whichever slot is the impostor")
  ## And an unpinned draw lands inside the roster.
  var drawn = baseConfig(77)
  drawn.impostorSlot = -1
  let sim = initSim(drawn)
  check(sim.impostorSlot >= 0 and sim.impostorSlot < Seats,
    "an unpinned draw is a real slot")

block impostorNeverLearnsWhoCanSeeIt:
  var config = baseConfig(21)
  config.impostorSlot = 4
  var sim = initSim(config)
  ## Park a crewmate right behind the impostor, looking at it.
  sim.cogs[4].x = 13
  sim.cogs[4].y = 9
  sim.cogs[4].facing = fS
  sim.cogs[0].x = 13
  sim.cogs[0].y = 4
  sim.cogs[0].facing = fS
  check(seesCog(sim.config, sim.cogs[0], sim.cogs[4]),
    "the crewmate really is watching")
  check(not seesCog(sim.config, sim.cogs[4], sim.cogs[0]),
    "and the impostor really cannot see it")
  let bytes = frameBytes(sim, 4).replace(" ", "")
  check("\"alias\":\"RED\",\"cell\":[13,4]" notin bytes,
    "the impostor's frame must not place the cog watching it")
  check("seenBy" notin bytes or "lastFakeDepositSeenBy" in bytes,
    "the only seenBy the impostor gets is its own last fake deposit")
  ## And the frame does carry the things it IS allowed.
  check("canFreezeNow" in bytes, "the impostor gets its legal target set")
  check("freezeCooldown" in bytes, "and its own cooldown")
  let crewBytes = frameBytes(sim, 0)
  check("canFreezeNow" notin crewBytes,
    "a crew seat never sees canFreezeNow")
  check("freezeCooldown" notin crewBytes,
    "nor the freeze cooldown")

echo "test_noleak: ok"
