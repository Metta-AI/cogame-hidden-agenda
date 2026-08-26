# Hidden Agenda

Five cogs mine a sealed station and carry gems to a central grate. One of them
is an **impostor** carrying a freeze beam. Frozen crew stay on the floor as
evidence and never act again. A meeting fires every 200 ticks — **and instantly
when a freeze happens inside somebody's field of view**. In the no-talk variant
the only channel anybody has is a visible, changeable vote.

* **Seats:** 5 (4 crew + 1 impostor), zero-sum: `+1 ×4 / −4`, or `−1 ×4 / +4`.
* **Crew win** at 32 deposits, or by ejecting the impostor.
* **Impostor wins** when only one crewmate is left. Tick 3000 is a 0-0 tie.
* **A policy is just a prompt.** `PLAYER_PROMPT="<strategy>"` fields an LLM
  policy; `PLAYER_SCRIPTED=miner|lurker` fields a scripted baseline. Same image,
  env-switched.

Watch it: <https://softmax.com/hidden-agenda>

---

## The catch

Vision is a **90° cone on your facing**, out to 8 cells, plus 4 cells in every
direction, and walls and gem seams block both. Vision is therefore **not
mutual**: somebody standing behind you sees you and you do not see them. That
asymmetry is the whole game. The impostor can check that its own view is empty
and still be watched from behind — and the moment a freeze lands inside anyone's
cone, a meeting opens on the very next tick with a `CAUGHT!` banner.

Only a crewmate's deposit moves the counter. The impostor really mines and
really carries — its gems leave the seam, a real cost to crew supply — but when
it drops one into the grate the counter does not move, and anybody standing
there watching has caught it cold.

## Playing a seat

You do not drive the cog tick by tick. At each decision point — the episode
opening and every meeting open — you choose **up to three jobs**, and a
deterministic kernel walks them for you until the next meeting.

```json
{"plan":[{"job":"mine","at":"S5"},{"job":"deposit"},{"job":"watch","who":"PINK"}],
 "vote":"PINK","switch":{"if":"YELLOW","to":"PINK"},
 "say":"pink was standing over green in the south gallery",
 "hunch":"pink froze green at 806 and I saw it",
 "notes":"red has been in NW since 640"}
```

Crew jobs: `mine at:<seam>` `deposit` `watch who:<alias>` `patrol room:<room>`
`guard` `hold`. The impostor gets those six plus `hunt who:<alias>`
`strike who:<alias>` `lurk room:<room>`.

Full rules: [docs/RULES.md](docs/RULES.md). Wire formats:
[docs/PROTOCOL.md](docs/PROTOCOL.md). Fielding a policy:
[docs/POLICIES.md](docs/POLICIES.md).

## Layout

| path | what |
|---|---|
| `src/hidden_agenda.nim` | entrypoint; the seed is randomised HERE, before `config.update` |
| `src/hidden_agenda/` | the sim module: `sim_types` `station` `vision` `kernel` `meeting` `sim` `scripted` `llm` `replays` `broadcast` `global` `server` |
| `src/hidden_agenda_player.nim` | the thin prompt-carrying seat (`/bin/hidden-agenda-player`) |
| `client/` | `chrome_common.js` (byte-identical to the starter's), `broadcast_core.js` (the board renderer), `replay_broadcast.html` (the starter's page + this game's block) |
| `replay-viewer/` | the wasm entry point and the static bundle's JS shell |
| `data/maps/vault.txt` | THE map. 27 × 19 ASCII, the specification not an illustration |
| `data/art/` | the board art: nano-banana cog kits + the procedural station tiles |
| `scripts/art/` | the art generators and the committed nano-banana source sheets |
| `tests/` | thirteen test programs; CI runs each twice, debug and release |
| `tools/ci/` | the docker smoke, the viewer smoke, the renderer fixture, the policy set |

## Generated files

Three artefacts are generated and must be regenerated rather than edited:

```bash
python3 tools/build_manifest.py                       # coworld_manifest_template.json
python3 scripts/art/gen_agenda_art.py data/art        # station tiles, seams, grate, FX
python3 scripts/art/split_cog_sheet.py data/art       # nano-banana cog kits
python3 tools/build_page.py                           # client/replay_broadcast.html
```

`tools/build_page.py` is what keeps the chrome honest: the page IS the
STARTER's `client/replay_broadcast.html` (coworld-ctf) — its CSS, its body
markup **and its page script** — with this game's block appended under a banner
comment. The builder asserts every block it removes (the first-person PiP, the
zoom bar + minimap, the POV badge, the hash-mismatch warning) line by line, so a
starter bump fails loudly instead of cutting the wrong thing, and
`tests/test_broadcast.nim` re-checks the inherited script function by function.
A page written from scratch that reuses the starter's ids is a rewrite.

## CI is the harness

`ci.yml` runs every `tests/*.nim` twice (debug and `-d:release`), builds the
production image and runs one real five-seat episode in raw docker from the
certification fixture, then builds the static wasm replay bundle and **opens it
in headless chromium** against that episode's replay.
`tools/build_replay_viewer.sh` and `tools/ci/docker_smoke.sh` must stay mode
100755 — `coworld build` refuses to package a source replay-viewer bundle unless
the hook is `os.X_OK`.

## Two name spaces

Every observation and every prompt sees only the anonymous cog aliases
`RED BLUE GREEN YELLOW PINK`. Policy names appear spectator-side only: the
replay's `policyNames[]`, the viewer's roster strip and plate sublines, and
`results.names`. No player frame ever carries another seat's role — not even the
terminal `final` frame.

## Rune boundaries

Every string that reaches the replay, the results or another seat goes through
`sim_state.cleanText`, which cuts on RUNE boundaries. Never slice one of those
by byte index: a byte-truncated multi-byte character renders fine in a browser
and then fails a strict JSON parser, which is how a hosted replay becomes
unreadable.
