## Hidden Agenda wire types and rule constants.
##
## Forked from `coworld-ctf/src/ctf/sim_types.nim`: the same discipline holds —
## FIELD ORDER IS SACRED (the replay frame encoding reads these in order), and
## `GameVersion` gates replay compatibility. Every sim quantity is an INTEGER;
## there is no float anywhere in the step path, which is what makes a seed
## reproduce a replay bit-exactly on native and under emscripten alike.

import std/[strutils, unicode]

const
  GameVersion* = "1"
    ## GV1 (hidden agenda): five cogs mine a station for a central grate, one
    ## carries a freeze beam, meetings open on a 200-tick cadence and instantly
    ## on a witnessed freeze.

  Protocol* = "hidden_agenda.player.v1"
  ReplayProtocol* = "hidden_agenda.replay.v1"
  GameName* = "hidden_agenda"

  Seats* = 5
  TargetFps* = 24
    ## Playback rate. The sim is NOT wall-clock paced; this is video tempo.

  MapCols* = 27
  MapRows* = 19
  CellPx* = 40
  BoardW* = MapCols * CellPx   ## 1080
  BoardH* = MapRows * CellPx   ## 760

  Aliases*: array[Seats, string] = ["RED", "BLUE", "GREEN", "YELLOW", "PINK"]
  Colors*: array[Seats, string] = ["red", "blue", "green", "yellow", "pink"]
  ShortAliases*: array[Seats, string] = ["RED", "BLU", "GRN", "YEL", "PNK"]

  ## Reply caps (runes, never bytes — see `cleanText` below).
  MaxSayLen* = 90
  MaxHunchLen* = 80
  MaxNotesLen* = 240
  MaxPromptLen* = 4000
  MaxErrorLen* = 200
  MaxPolicyLen* = 64

  ## Playback speeds offered by the chrome's speed chips.
  PlaybackSpeeds*: array[6, int] = [1, 2, 3, 4, 8, 16]
  BroadcastChromeSpriteId* = 65000
  FreezeFxTicks* = 6
  WitnessFlashTicks* = 24
  BannerTicks* = 48

# ---------------------------------------------------------------------------
# Rune-safe text. NEVER slice a recorded string by byte index: a byte cut puts
# invalid UTF-8 in the replay and only a strict parser finds it (bullwhip,
# 2026-08-22). This lives HERE, in the base module, so every layer that writes
# a string into the replay can reach it — including `sim_config`, which pins
# `variant` and `model` into the replay's config document.
# ---------------------------------------------------------------------------

proc cleanText*(text: string, limit: int): string =
  result = text.strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit - 1) & "\u2026"

proc oneLine*(text: string, limit: int): string =
  cleanText(text.replace("\n", " ").replace("\r", " "), limit)


type
  HiddenAgendaError* = object of CatchableError

  Facing* = enum
    fN = "N", fE = "E", fS = "S", fW = "W"

  Role* = enum
    rCrew = "crew", rImpostor = "impostor"

  CogState* = enum
    csActive = "active", csFrozen = "frozen", csEjected = "ejected"

  Action* = enum
    ## The complete per-tick vocabulary. Twelve values, no more.
    aWait = "wait"
    aMoveN = "move_n", aMoveE = "move_e", aMoveS = "move_s", aMoveW = "move_w"
    aMine = "mine", aDeposit = "deposit", aFreeze = "freeze"
    aFaceN = "face_n", aFaceE = "face_e", aFaceS = "face_s", aFaceW = "face_w"

  JobKind* = enum
    jkMine = "mine", jkDeposit = "deposit", jkWatch = "watch"
    jkPatrol = "patrol", jkGuard = "guard", jkHold = "hold"
    jkHunt = "hunt", jkStrike = "strike", jkLurk = "lurk"

  PlanStep* = object
    job*: JobKind
    at*: string      ## seam id, for `mine`
    who*: string     ## alias, for `watch` / `hunt` / `strike`
    room*: string    ## room id, for `patrol` / `lurk`

  DecisionSource* = enum
    dsLlm = "llm", dsJev = "jev", dsRetry = "retry",
    dsFallback = "fallback"
    dsScripted = "scripted", dsBudget = "budget"

  Decision* = object
    plan*: seq[PlanStep]
    vote*: string          ## an active alias or "skip"; "" outside a meeting
    switchIf*: string      ## "" = no conditional
    switchTo*: string
    say*: string
    hunch*: string
    notes*: string
    source*: DecisionSource
    latencyMs*: int

  Seen* = object
    t*: int
    cell*: array[2, int]
    doing*: string
    room*: string
    valid*: bool

  Body* = object
    alias*: string
    cell*: array[2, int]
    room*: string
    firstSeenTick*: int

  WitnessNote* = object
    t*: int
    freezer*: string
    victim*: string
    cell*: array[2, int]
    sawFreezer*: bool
    sawVictim*: bool

  SeamSeen* = object
    id*: string
    gems*: int
    t*: int
    valid*: bool

  Cog* = object
    slot*: int
    role*: Role
    state*: CogState
    x*, y*: int
    facing*: Facing
    carry*: int
    mineProgress*: int
    mineSeam*: int          ## seam index currently being mined, -1 = none
    moveCooldown*: int
    freezeCooldown*: int
    mined*: int
    deposited*: int
    freezes*: int
    fakeDeposits*: int
    lastFakeSeenBy*: seq[string]
    ## plan state
    plan*: seq[PlanStep]
    planIndex*: int
    patrolLeg*: int
    sweep*: int
    lastAction*: Action
    ## memory (private to this seat)
    lastSeen*: array[Seats, Seen]
    togetherTicks*: array[Seats, int]
    sawFake*: array[Seats, int]
      ## Times this seat personally watched that cog drop a gem into the grate
      ## and saw the counter fail to advance. The deposit-audit channel.
    bodies*: seq[Body]
    witnessed*: seq[WitnessNote]
    seamsSeen*: seq[SeamSeen]
    notes*: string
    lastHunch*: string
    ## meeting-restore
    savedX*, savedY*: int
    savedFacing*: Facing

  MeetingCause* = enum
    mcCadence = "cadence", mcWitness = "witness"

  MeetingPhase* = enum
    mpNone = 0, mpOpen = 1, mpSaid = 2, mpVoted = 3, mpSwitched = 4,
    mpResolved = 5

  MeetingRecord* = object
    n*: int
    t*: int
    cause*: MeetingCause
    votes*: array[Seats, string]
    switched*: array[Seats, string]
    says*: array[Seats, string]
    outcome*: string        ## plurality | tie | skip
    ejected*: string        ## alias or ""

  Frame* = object
    t*: int
    c*: array[Seats * 6, int]
    v*: array[Seats, int]
    g*: seq[int]
    d*: int
    m*: int

  Beat* = object
    t*: int
    kind*: string           ## meeting freeze caught eject deposit gameover
    n*: int
    who*: string
    winner*: string

proc facingOf*(text: string): Facing =
  case text.toUpperAscii()
  of "N": fN
  of "E": fE
  of "S": fS
  of "W": fW
  else: fN

proc facingDelta*(f: Facing): (int, int) =
  case f
  of fN: (0, -1)
  of fE: (1, 0)
  of fS: (0, 1)
  of fW: (-1, 0)

proc aliasIndex*(alias: string): int =
  ## -1 when the string names no cog.
  let up = alias.strip().toUpperAscii()
  for i, a in Aliases:
    if a == up:
      return i
  -1

proc moveActionFor*(dx, dy: int): Action =
  if dy < 0: aMoveN
  elif dy > 0: aMoveS
  elif dx > 0: aMoveE
  elif dx < 0: aMoveW
  else: aWait

proc isMove*(a: Action): bool =
  a in {aMoveN, aMoveE, aMoveS, aMoveW}

proc moveDelta*(a: Action): (int, int) =
  case a
  of aMoveN: (0, -1)
  of aMoveE: (1, 0)
  of aMoveS: (0, 1)
  of aMoveW: (-1, 0)
  else: (0, 0)
