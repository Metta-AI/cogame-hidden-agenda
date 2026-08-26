## The broadcast frame: the chrome state JSON the inherited paintbot chrome
## reads, plus the appended `agenda` block this game adds.
##
## Fork of `coworld-ctf/src/ctf/broadcast.nim`. `BroadcastTracker` and
## `buildStateJson` keep their shape: `teams` becomes `crew` / `impostor`,
## `roster` the five cogs (alias in `name`, POLICY name in `pol` — both name
## spaces, spectator-side), `lead` the race series in the starter's own
## `{teams, pts}` shape so `ingestLeadSeries` / `renderMomentum` in
## `client/chrome_common.js` need no change at all.

import std/[json]
import sim_types

type
  ViewCog* = object
    x*, y*, facing*, state*, carry*, mineProgress*, vis*: int

  ViewMeta* = object
    aliases*: seq[string]
    policyNames*: seq[string]
    roles*: seq[string]
    colors*: seq[string]
    config*: JsonNode

  ViewFrame* = object
    t*: int
    cogs*: array[Seats, ViewCog]
    gems*: seq[int]
    deposits*: int
    meetingPhase*: int

  ViewChrome* = object
    ## Everything the HUD needs that is not per-cog board state.
    maxTick*, maxTicks*, depositTarget*: int
    phase*: string                ## lobby | playing | gameover
    playing*, looping*, skipping*, fastForward*, enabled*: bool
    speed*: int
    activeCrew*, impostorSlot*, freezeCooldown*, freezeCooldownTicks*: int
    meetingNumber*, meetingIn*: int
    meetingCause*: string
    votes*: array[Seats, string]
    tally*: seq[(string, int)]
    lead*: seq[array[3, int]]
    lulls*: seq[array[2, int]]
    beats*: JsonNode
    events*: JsonNode
    over*: JsonNode
    sendLead*: bool

  BroadcastTracker* = object
    ## Tracks what this viewer has already been sent, so the once-only chrome
    ## (the lead series, the beat timeline, the lull spans) ships exactly once.
    leadSent*: bool
    lastTick*: int

proc initBroadcastTracker*(): BroadcastTracker =
  BroadcastTracker(leadSent: false, lastTick: -1)

proc resync*(tracker: var BroadcastTracker) =
  tracker.lastTick = -1

proc stateName(code: int): string =
  case code
  of 3: "frozen"
  of 4: "ejected"
  else: "active"

proc buildStateJson*(meta: ViewMeta, frame: ViewFrame,
    chrome: ViewChrome): JsonNode =
  var roster = newJArray()
  for slot in 0 ..< Seats:
    let alive = frame.cogs[slot].state notin [3, 4]
    roster.add(%*{
      "s": slot,
      "name": (if slot < meta.aliases.len: meta.aliases[slot] else: Aliases[slot]),
      "pol": (if slot < meta.policyNames.len: meta.policyNames[slot] else: ""),
      "team": (if slot == chrome.impostorSlot: "impostor" else: "crew"),
      "alive": alive,
      "lives": 0
    })

  var teams = newJObject()
  teams["crew"] = %*{
    "lives": frame.deposits,
    "policies": newJArray()
  }
  teams["impostor"] = %*{
    "lives": chrome.activeCrew,
    "policies": newJArray()
  }

  var pts = newJArray()
  for row in chrome.lead:
    pts.add(%[row[0], row[1], row[2]])

  var votes = newJObject()
  for slot in 0 ..< Seats:
    if chrome.votes[slot].len > 0:
      votes[meta.aliases[slot]] = %chrome.votes[slot]
  var tally = newJObject()
  for row in chrome.tally:
    tally[row[0]] = %row[1]

  var wedges = newJArray()
  wedges.add(%*{
    "s": chrome.impostorSlot,
    "f": frame.cogs[chrome.impostorSlot].facing,
    "r": meta.config{"visionRadius"}.getInt(8),
    "k": "imp"
  })

  var roles = newJArray()
  for role in meta.roles:
    roles.add(%role)

  var rosterStates = newJArray()
  for slot in 0 ..< Seats:
    rosterStates.add(%stateName(frame.cogs[slot].state))

  result = %*{
    "t": frame.t,
    "st": 0,
    "mx": chrome.maxTick,
    "mt": chrome.maxTicks,
    "ph": chrome.phase,
    "en": chrome.enabled,
    "pl": chrome.playing,
    "sp": chrome.speed,
    "lp": chrome.looping,
    "sk": chrome.skipping,
    "ff": chrome.fastForward,
    "pov": -1,
    "lob": 0,
    "teams": teams,
    "roster": roster,
    "events": (if chrome.events != nil: chrome.events else: newJArray()),
    "agenda": {
      "dep": frame.deposits,
      "tgt": chrome.depositTarget,
      "crew": chrome.activeCrew,
      "imp": chrome.impostorSlot,
      "cool": chrome.freezeCooldown,
      "coolMax": chrome.freezeCooldownTicks,
      "gems": (block:
        var gems = newJArray()
        for value in frame.gems:
          gems.add(%value)
        gems),
      "states": rosterStates,
      "m": {
        "n": chrome.meetingNumber,
        "cause": chrome.meetingCause,
        "phase": frame.meetingPhase,
        "votes": votes,
        "tally": tally,
        "in": chrome.meetingIn
      },
      "roles": roles,
      "wedges": wedges
    }
  }
  if chrome.sendLead:
    result["lead"] = %*{"teams": ["crew", "impostor"], "pts": pts}
    result["beats"] = (if chrome.beats != nil: chrome.beats else: newJArray())
    var lulls = newJArray()
    for span in chrome.lulls:
      lulls.add(%[span[0], span[1]])
    result["lulls"] = lulls
  if chrome.over != nil and chrome.over.kind != JNull:
    result["over"] = chrome.over
