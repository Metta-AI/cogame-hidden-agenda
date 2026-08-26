# Wire formats

## Player protocol — `hidden_agenda.player.v1`

JSON text frames over `WS /player?slot=N&token=T`.

**game → player**

```json
{"type":"welcome","protocol":"hidden_agenda.player.v1","slot":1,"role":"crew",
 "name":"BLUE","variant":"hidden-agenda-notalk","chat":false,"maxTicks":3000,
 "depositTarget":32,"aliases":["RED","BLUE","GREEN","YELLOW","PINK"]}
```

`role` is **this seat's own role and nothing else's**.

The `state` frame (see [POLICIES.md](POLICIES.md)) at every decision point and
once at episode end, then:

```json
{"type":"final","done":true,"scores":[1,1,1,1,-4],"win":[true,true,true,true,false],
 "winner":"crew","names":["RED","BLUE","GREEN","YELLOW","PINK"],
 "deposits":32,"ticks":1832,"reason":"complete","ending":"crew_deposits"}
```

**The `final` frame carries no `roles[]` and no `impostorSlot`.** Nobody learns
the answer from the game, not even at the buzzer: a policy could otherwise log
role↔alias pairs across episodes. Spectators get roles from the replay and the
platform gets them from `results.json`.

**player → game**

```json
{"type":"prompt","prompt":"<= 4000 chars","scripted":"miner|lurker|"}
```

sent immediately on connect and again after `welcome` (the re-send guards the
slot-registration race). Any other frame is ignored with a log line.

## Routes

| route | behaviour |
|---|---|
| `GET /healthz` | `200 ok`, from process start until `shutdownGraceSeconds` after the artifacts are written |
| `GET /client/player?slot=N&token=T` | the seat's HTML shell; it **never** opens the player socket |
| `GET /client/global` | the live spectator client |
| `GET /client/replay` | the broadcast replay page |
| `WS /player?slot=N&token=T` | the seat socket; a bad token is refused with a close, never a hang |
| `WS /global` | live spectator: the board packet + the chrome frame |

Startup randomises the seed **before** `config.update`, waits up to
`playerConnectTimeoutSeconds = 120` for the five sockets, starts anyway with
whoever is there (a missing seat plays `miner`; **no** seat present →
`forfeit`), then runs the tick loop.

Shutdown, in order: `final` to all five sockets → the last global frame →
`sleep 500 ms` → `results.json` → the replay → keep `/healthz` and `/global`
answering for `shutdownGraceSeconds = 20` → `quit(0)`.

## Global / viewer packet

One JSON document per frame, out of the wasm module (or the `/global` socket):

```json
{"meta": {"aliases":[…],"policyNames":[…],"roles":[…],"colors":[…],
          "config":{…},"cell":40,"boardW":1080,"boardH":760},
 "b": {"t":812,"c":[…30 ints…],"v":[…5…],"g":[…6…],"d":21,"ph":3},
 "hud": { the chrome state frame }}
```

`meta` rides the FIRST packet only. `b.c` is six integers per cog in slot order
— `x, y, facing (0=N,1=E,2=S,3=W), state (0 active, 1 mining, 2 depositing,
3 frozen, 4 ejected, 5 in-meeting), carry, mineProgress`. `b.v` is a per-cog
5-bit mask of which cogs that cog can see (a cog never sees itself). `b.g` is
gems remaining per seam in `S1..S6` order. `b.ph` is the meeting phase
(0 none, 1 open, 2 said, 3 voted, 4 switched, 5 resolved).

`hud` is the starter's own chrome frame — `teams` (`crew` / `impostor`),
`roster` (5 entries, `name` = alias, `pol` = policy name, `s` = slot), `lead`,
`beats`, `lulls`, `over` — plus the appended `agenda` block:

```json
{"dep":21,"tgt":32,"crew":3,"imp":4,"cool":180,
 "gems":[3,1,2,0,3,2],"states":["active","active","frozen","active","active"],
 "m":{"n":4,"cause":"witness","phase":3,
      "votes":{"RED":"PINK"},"tally":{"PINK":2},"in":5},
 "roles":["crew","crew","crew","crew","impostor"],
 "wedges":[{"s":4,"f":2,"r":8,"k":"imp"}]}
```

The static bundle is opened as `index.html?replay=<s3 url>`. It contacts no
server except S3 for the `.replay` file.

## Replay — `hidden_agenda.replay.v1`

Strict UTF-8 JSON, one document. Hidden Agenda records **state**, not inputs, so
playback never re-simulates, a seek is an array index, and there is no
native/wasm divergence to chase.

```json
{"protocol":"hidden_agenda.replay.v1","game":"hidden_agenda","gameVersion":"1",
 "seed":1234567,"tickHz":24,
 "names":["RED","BLUE","GREEN","YELLOW","PINK"],
 "policyNames":[…],"roles":["crew","crew","crew","crew","impostor"],
 "colors":["red","blue","green","yellow","pink"],
 "config":{…the whole rule set, the map as ASCII, the rooms, seams, grate…},
 "frames":[{"t":0,"c":[…30…],"v":[…5…],"g":[…6…],"d":0,"ph":0}],
 "series":{"race":[[0,0,0]],"crew":[[0,4]]},
 "beats":[{"t":200,"k":"meeting","n":1}],
 "events":[…],
 "results":{…the results.json object verbatim…}}
```

`roles[]` is written into the header **after** the episode, by the same writer
that writes `results`, so no player process can ever read it.

### Event vocabulary

| `k` | fields | when |
|---|---|---|
| `reveal` | `t (=0), seat, alias, role, policy` | five rows at tick 0, spectator-side |
| `seam` | `t, id, gems` | step 1, a seam regrew |
| `mine` | `t, seat, id, carry` | step 6 |
| `deposit` | `t, seat, total` | step 5, a **crew** deposit |
| `fakedeposit` | `t, seat, seenBy[]` | step 5, the counter did not move |
| `freeze` | `t, seat, victim, cell, witnesses[]` | step 3 |
| `witness` | `t, witness, freezer, victim, cell, sawFreezer, sawVictim` | step 4, one row per witness |
| `caught` | `t, freezer, victim, witnesses[]` | step 4, iff W is non-empty |
| `meeting` | `t, n, cause, active[], frozen[], ejected[]` | M1 |
| `say` | `t, seat, text` | M2, chat variant only |
| `vote` | `t, seat, target, phase` | M3 and M4 |
| `eject` | `t, target, tally, outcome, wasImpostor` | M5 |
| `order` | `t, seat, decision, plan, vote, switch, say, hunch, notes, source, latencyMs` | one per eligible seat per decision point |
| `end` | `t, reason, ending, winner, deposits, scores[5], roles[5], freezes, witnessedFreezes, ejections, meetings` | terminal |

## `results.json`

```json
{"names":["hidden-agenda-sleuth","hidden-agenda-shadow","hidden-agenda-miner",
          "hidden-agenda-miner","hidden-agenda-lurker"],
 "aliases":["RED","BLUE","GREEN","YELLOW","PINK"],
 "roles":["crew","crew","crew","crew","impostor"],
 "scores":[1,1,1,1,-4],"win":[true,true,true,true,false],"winner":"crew",
 "deposits":32,"depositTarget":32,
 "freezes":2,"witnessedFreezes":1,"ejections":1,"ejectedImpostor":true,
 "wrongEjections":0,"fakeDeposits":3,"meetings":5,"ticks":1832,
 "reason":"complete","ending":"crew_deposits"}
```

Arrays are indexed by **slot** and are always length 5. `names` are POLICY names
(platform side); `aliases` go to the players and into the replay's `names[]`.
`scores[i]` is the zero-sum result (the five always sum to 0);
`win[i] = scores[i] > 0`.
