## Hidden Agenda static replay viewer, wasm side.
##
## Same structure as `coworld-ctf/replay-viewer/ctf_replay.nim`: `stampStage`,
## the load/frame/input entry points, the packet/error/stage pointer pairs and
## the `emscripten_exit_with_live_runtime()` epilogue (without it Nim's `main`
## destroys every global while JS keeps calling in). `ctf_mismatch_tick` is
## DROPPED — Hidden Agenda records state, not inputs, so there is no
## re-simulation to mismatch.
##
## The packet built by `hidden_agenda_load_replay` is the ONLY one carrying
## `meta` (aliases, policy names, roles, config); the renderer reads it directly
## and never re-derives it from a later frame (matrix-games, 2026-08-24).

import hidden_agenda/[replays, global]

var
  runtimeLoaded = false
  replay: Replay
  viewer: GlobalViewerState
  packet: string
  lastError: string

## --- Progress stage note ---
## wasm32 has no memory protection: when emscripten's malloc fails, a write
## through the nil pointer lands at address 0 and silently corrupts the
## module's own globals. The bundle is therefore linked with
## `-s ABORTING_MALLOC=1`, and this fixed buffer — stamped BEFORE each risky
## phase — stays readable from JS after the abort (aborting kills the call
## stack, not the linear memory), so the page can still report what the runtime
## was doing.
var
  stageNote: array[192, char]
  stageNoteLen: int
  currentStage: string

proc stampStage(stage: string) =
  currentStage = stage
  stageNoteLen = min(stage.len, stageNote.len)
  if stageNoteLen > 0:
    copyMem(stageNote[0].addr, stage[0].unsafeAddr, stageNoteLen)

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc hiddenAgendaLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "hidden_agenda_load_replay", cdecl.} =
  try:
    lastError = ""
    stampStage("parse replay")
    replay = parseReplay(bytesFromPointer(data, int(length)))
    stampStage("initialize replay runtime")
    viewer = initGlobalViewerState()
    runtimeLoaded = true
    stampStage("render first frame")
    ## The first packet carries `meta` and holds tick 0: `buildReplayPacket`
    ## advances, so seed the playback one frame behind and let it land on 0.
    viewer.playback.playing = false
    packet = buildReplayPacket(replay, viewer)
    viewer.playback.playing = true
    return 1
  except Exception as error:
    runtimeLoaded = false
    lastError = currentStage & ": " & $error.name & ": " & error.msg
    if lastError.len == 0:
      lastError = "unknown failure while loading the replay"
    return 0

proc hiddenAgendaInput(data: ptr uint8, length: cint)
    {.exportc: "hidden_agenda_input", cdecl.} =
  if runtimeLoaded:
    viewer.applyGlobalViewerMessage(bytesFromPointer(data, int(length)))

proc hiddenAgendaFrame(): cint {.exportc: "hidden_agenda_frame", cdecl.} =
  if not runtimeLoaded:
    return 0
  stampStage("advance replay")
  try:
    packet = buildReplayPacket(replay, viewer)
    return 1
  except Exception as error:
    lastError = "advance replay: " & $error.name & ": " & error.msg
    return -1

proc hiddenAgendaPacketPointer(): ptr uint8
    {.exportc: "hidden_agenda_packet_ptr", cdecl.} =
  if packet.len == 0: nil else: cast[ptr uint8](packet[0].addr)

proc hiddenAgendaPacketLength(): cint
    {.exportc: "hidden_agenda_packet_len", cdecl.} =
  cint(packet.len)

proc hiddenAgendaErrorPointer(): ptr uint8
    {.exportc: "hidden_agenda_error_ptr", cdecl.} =
  if lastError.len == 0: nil else: cast[ptr uint8](lastError[0].addr)

proc hiddenAgendaErrorLength(): cint
    {.exportc: "hidden_agenda_error_len", cdecl.} =
  cint(lastError.len)

proc hiddenAgendaStagePointer(): ptr uint8
    {.exportc: "hidden_agenda_stage_ptr", cdecl.} =
  ## The progress note. Unlike hidden_agenda_error_*, this stays valid after an
  ## allocation-failure abort, so JS can report what the runtime was doing when
  ## the address space ran out.
  if stageNoteLen == 0: nil else: cast[ptr uint8](stageNote[0].addr)

proc hiddenAgendaStageLength(): cint
    {.exportc: "hidden_agenda_stage_len", cdecl.} =
  cint(stageNoteLen)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  ## Nim's generated main runs every module-global destructor when it returns,
  ## freeing the replay and the packet while the wasm module stays alive and JS
  ## keeps calling hidden_agenda_load_replay / hidden_agenda_frame. Unwinding
  ## main through emscripten's live-runtime exit skips the destructor epilogue
  ## entirely, so globals stay valid for the life of the page.
  emscriptenExitWithLiveRuntime()
