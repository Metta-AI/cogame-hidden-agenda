# Fielding a policy

A Hidden Agenda player can register a prompt, scripted baseline, or external
action policy. The game batches prompt model requests. External policies receive
their own seat observation and return an ordinary plan and vote. They can run
Jev, another model, or programmatic code in the player container.

```bash
coworld upload-policy coworld-hidden-agenda:latest \
  --name my-hidden-agenda \
  --run /bin/hidden-agenda-player \
  --secret-env PLAYER_PROMPT="<your strategy, both roles>" \
  --secret-env USE_BEDROCK=true
```

`USE_BEDROCK=true` is not optional for an LLM policy: the platform gates the
player pod's Bedrock sidecar on it, and without it the seat silently plays
scripted.

To field the bounded Jev policy, set `PLAYER_JEV=1` and enable the hosted
Bedrock sidecar. The player ranks ordinary plans and legal meeting votes from
its seat observation. The game validates its selected plan and vote.

```bash
coworld upload-policy coworld-hidden-agenda:latest \
  --name my-hidden-agenda-jev \
  --run /bin/hidden-agenda-player \
  --secret-env PLAYER_JEV=1 \
  --use-bedrock
```

The Jev policy ranks fixed actions. It does not generate chat speech or notes.

A scripted baseline is the same image with a different env:

```bash
--secret-env PLAYER_SCRIPTED=miner     # the working baseline
--secret-env PLAYER_SCRIPTED=lurker    # the loud foil
```

**Write custom prompts for BOTH roles.** The impostor slot is redrawn from the
seed every episode. A policy is seated as crew four times in five and as the
impostor once. A prompt for crew alone throws away a fifth of its score.

## What your seat sees

One `state` frame per decision point (and once more at episode end). Everything
in it is visible to that seat; **nothing else is**.

```json
{"type":"state","protocol":"hidden_agenda.player.v2","slot":1,"role":"crew",
 "name":"BLUE","tick":812,"maxTicks":3000,"decision":4,"cause":"witness",
 "phase":"meeting","chat":false,
 "you":{"cell":[13,15],"facing":"N","carrying":1,"carryCap":2,"state":"active",
        "mined":6,"deposited":5,"lastPlan":[{"job":"mine","at":"S5"}]},
 "station":{"deposits":21,"depositTarget":32,"map":"vault","cols":27,"rows":19,
            "rooms":["NW","N","NE","SW","S","SE","HUB"],
            "seams":[{"id":"S1","room":"NW","cell":[2,2]}],
            "grate":[[12,8]]},
 "roster":[{"alias":"RED","state":"active"}],
 "inView":[{"alias":"PINK","cell":[13,14],"facing":"S","doing":"walking",
            "carrying":1}],
 "lastSeen":{"RED":{"t":640,"cell":[4,3],"doing":"mining","room":"NW"}},
 "togetherTicks":{"RED":118,"GREEN":204},
 "bodies":[{"alias":"GREEN","cell":[13,16],"room":"S","firstSeenTick":806}],
 "youWitnessed":[{"t":806,"freezer":"PINK","victim":"GREEN","cell":[13,16],
                  "sawFreezer":true,"sawVictim":true}],
 "seamsSeen":[{"id":"S5","gems":1,"t":806}],
 "meetings":[{"n":3,"t":600,"cause":"cadence","votes":{},"switched":{},
              "outcome":"skip","ejected":null,"say":{}}],
 "notes":"red has been in NW since 640",
 "vision":{"visionRadius":8,"awarenessRadius":4,
           "cone":"90 degrees on your facing"},
 "rules":{"role":"you are CREW. Exactly ONE of the other four cogs is the impostor."}}
```

**Visible to a crew seat:** its own cell/facing/carry/state and counters; the
full static map; the public deposit counter; the public roster of who is
active/frozen/ejected; every cog currently in its own FOV; its own memory of
everyone else; its own `youWitnessed`; the complete public meeting history; its
own notes; and the rules.

**Hidden from a crew seat:** every other seat's role, plan, hunch and notes; the
position of any cog not currently in its FOV (it gets only its own remembered
`lastSeen`); the gem count of any seam it cannot see; the freeze cooldown; the
seed; the impostor slot; and anything about the league or the other policies.

**The impostor seat** additionally gets `freezeCooldown`, `freezeRange`, its own
`freezes` / `fakeDeposits` counters, `lastFakeDepositSeenBy`, and
**`canFreezeNow`** — the precomputed set of legal targets right now, computed by
the same predicate the sim's legality check applies. What it does **not** get is
who can currently see *it*. That is the risk it is taking.

A **frozen or ejected** seat receives a frame with `canAct: false` and
`canVote: false`, and is not included in any decision batch. Its socket stays
open until `final`. An active seat carries `canAct: true`, and `canVote: true`
only while a meeting is open.

## What you reply with

Exactly one JSON object whose first character is `{`.

```json
{"plan":[{"job":"mine","at":"S5"},{"job":"deposit"},{"job":"watch","who":"PINK"}],
 "vote":"PINK","switch":{"if":"YELLOW","to":"PINK"},
 "say":"pink was standing over green in the south gallery",
 "hunch":"pink froze green at 806 and I saw it",
 "notes":"red has been in NW since 640"}
```

| field | type | cap / range | on violation |
|---|---|---|---|
| `plan` | array of steps | **1..3** | missing, empty, > 3, or not an array → invalid |
| `plan[].job` | enum | crew: `mine` `deposit` `watch` `patrol` `guard` `hold`; impostor: those plus `hunt` `strike` `lurk` | not in **this role's** enum → invalid |
| `plan[].at` | enum | `S1`..`S6` | required for `mine`; missing/unknown → invalid |
| `plan[].who` | enum | an alias `active` **now** | required for `watch`/`hunt`/`strike` |
| `plan[].room` | enum | `NW` `N` `NE` `SW` `S` `SE` `HUB` | required for `patrol`/`lurk` |
| `vote` | enum | an active alias, or `"skip"` | **required at a meeting** |
| `switch` | object or null | `{"if": <alias>\|"tie", "to": <alias>\|"skip"}` | naming an inactive cog → invalid; missing one of the two keys → no conditional |
| `say` | string | **90 chars**, truncated | chat variant only; ignored elsewhere |
| `hunch` | string | **80 chars**, truncated | spectator-only |
| `notes` | string | **240 chars**, truncated | private to you |

Extra keys are ignored. Truncation is on **rune** boundaries. A step's argument
may also be written compactly inside `job` — `{"job":"mine at:S2"}` is read as
`{"job":"mine","at":"S2"}`, and likewise `watch who:`, `patrol room:`,
`hunt who:`, `strike who:`, `lurk room:` — because that is the form the system
prompt teaches. The sibling key wins when both are present.

An invalid reply is retried **once** in the same decision point's batch with a
hint. Still failing → that seat plays the `miner` decision for that decision
point, recorded on the `order` event as `"source":"fallback"`. `decideAll` never
raises; the episode always advances.

## The scripted baselines

**`miner`** — the working baseline, and the fallback every failed LLM decision
lands on. As crew it chains `mine` → `deposit` → `watch` on whoever it has gone
longest without seeing, and votes a deterministic suspicion score (a witnessed
freeze is worth 20, a body in someone's last-seen room 3, a fake deposit it
personally saw 6, plus one per hundred ticks unseen), voting `skip` under 6. As
impostor it hunts when its own view is empty, lurks where somebody was last
seen, and otherwise mines — replacing its `deposit` step with `guard` whenever
anything is in view, so it never fake-deposits to an audience.

**`lurker`** — the foil. As crew it works one fixed seam all episode, never
watches, and votes `skip` unless it personally witnessed a freeze. As impostor
it `strike`s: it closes on the nearest crewmate and fires the instant the freeze
is legal, witnesses or not. It is loud, it gets caught, and that is deliberate —
it is what guarantees the all-scripted certification replay contains a witnessed
freeze and a `CAUGHT!` banner.
