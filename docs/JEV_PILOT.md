# Hidden Agenda Jev pilot, September 24, 2026

The current Jev policy uses the generic v2 observation and action protocol.
The game owns seat visibility, legal actions, scoring, and replay. The policy
owns the candidate menu, prompt, and model call. No production version was
published for this correction.

## Current player-side paired episodes

The native runner used the normal 3,000-tick no-talk variant, with seat 0
playing Jev or miner against four miner policies. Both arms used the same seed
and role on the same game source. The final Jev policy offers productive
mine/deposit plans to crew and stealth hunts to the impostor.

| Role / seed | Miner score | Jev score | Jev calls |
| --- | ---: | ---: | ---: |
| Crew / 7 | -1 | -1 | 5 |
| Crew / 42 | 1 | 1 | 10 |
| Crew / 1234 | 1 | -1 | 8 |
| Impostor / 7 | 4 | 4 | 9 |
| Impostor / 42 | -4 | 4 | 7 |
| Impostor / 1234 | 4 | 4 | 8 |

All 47 Jev calls produced accepted actions with zero fallback. They used
93,365 input and 4,794 output tokens. At the OpenRouter Jev list rate of
$0.042 per million input tokens, this is about $0.00392 in proxy model spend;
direct TypeSafe usage was not invoiced here. Three seeds per role cannot
establish a general performance gain. The final policy code needs a fresh
normal certification run before merge; certification passed on the previous
player-side policy commit.

Run a matched native episode with `variant` to use the normal game duration:

```bash
bash tools/local_episode.sh miner 7 crew variant
TYPESAFE_API_KEY=<approved-key> bash tools/local_episode.sh jev 7 crew variant
```

The sections below document the earlier game-hosted Jev implementation and
are historical. Their scores must not be attributed to the current policy.

## Scope

`PLAYER_JEV=1` asks System One to rank complete, legal decisions at each
decision point. The candidates contain miner, lurker, and guard plans. At
meetings, Jev can also choose a legal vote with the miner plan. The request
contains only the acting seat's `state` frame. All open model seats still share
one parallel request batch.

The player leaves an unset operator prompt empty. This avoids passing the
prompt policy's default strategy to Jev. The Jev response must name the exact
candidate set, include a valid confidence, and provide probabilities summing
to one. The game applies the highest-probability candidate. A failed call is
retried once, then falls back to miner with `source=fallback` in the replay.

## Matched local episodes

The comparison uses the full 3,000-tick no-talk variant. Seat 0 plays Jev or
miner from the same seed and role; all four opponents play miner. Scores are
the game's zero-sum terminal payoff. The rows below are the final rerun after
the candidate set and replay source label were corrected.

| Seat 0 role / seed | Miner score | Jev score | Jev calls | Input tokens | Output tokens |
| --- | ---: | ---: | ---: | ---: | ---: |
| Crew / 7 | -1 | 1 | 8 | 13,976 | 563 |
| Crew / 42 | 1 | 1 | 10 | 18,268 | 694 |
| Crew / 1234 | 1 | 1 | 10 | 17,988 | 664 |
| Impostor / 7 | 4 | 4 | 8 | 13,762 | 486 |
| Impostor / 42 | -4 | -4 | 4 | 6,144 | 232 |
| Impostor / 1234 | 4 | 4 | 7 | 11,601 | 402 |

All 47 Jev calls completed without scripted fallback. They used 81,739 input
and 3,041 output tokens. Direct TypeSafe replies did not report dollar spend.
At the earlier OpenRouter capture rate of $0.042 per million input tokens,
the calls imply about $0.00343 of **proxy** spend, not a TypeSafe invoice.
Replay order latency averaged 211 ms, with 172 ms median, 316 ms 90th
percentile, and 561 ms maximum. These are local direct TypeSafe timings.

The first run of impostor seed 1234 lost with Jev; the final rerun won. That
change shows model variability at a fixed game seed. Six pairs do not establish
a gameplay gain or social-intelligence transfer. The chat variant can only
reuse speech from scripted candidates; Jev does not generate new messages.

For current player-side paired episodes, run both arms with the same seed and
role through the game server:

```bash
bash tools/local_episode.sh miner 7 crew
TYPESAFE_API_KEY=<approved-key> bash tools/local_episode.sh jev 7 crew
```

The runner uses the real game server and five WebSocket player processes. It
retains results, replay, and player logs in ignored `tmp/episode.*` directories.

## Captured trace and action join

A separate crew seed 7 run used the OpenRouter capture proxy. It retained 16
JSONL lines: eight requests and eight responses. The verifier matched each
response's probability maximum to seat 0's applied plan and vote in the replay.
All eight HTTP responses succeeded, with zero fallback and zero reported-choice
disagreements. OpenRouter returned **$0.000586992** in provider cost for
13,976 input and 564 output tokens. Mean proxy latency was 205.5 ms. The
trace file has mode `0600` inside a `0700` directory. These raw records are
unreviewed research data, not approved training labels.

The completed-episode projection passed `metta-posttrain systemone-candidates`:
eight candidates, eight eligible, zero excluded, zero incomplete. A second
captured crew seed 42 made ten calls for $0.000767256. One response's reported
choice differed from its probability maximum. The game applied the maximum;
the candidate projection excluded that inconsistent raw answer. The importer
produced nine eligible candidates, one excluded call, and zero incomplete.
Both capture directories retain private `traces.jsonl`, `episodes.jsonl`, and
`candidates.jsonl` files with mode `0600`. None is a training label without
separate review.

The same wrapper also ran the real five-player WebSocket path for crew seed 42.
That native episode won, made nine Jev calls with zero fallback, and joined all
nine captured responses to nine applied replay orders. OpenRouter reported
$0.000675906 for 16,093 input and 630 output tokens. The importer produced
nine eligible review candidates with zero excluded or incomplete calls.

Run the capture using a Metta checkout that exports `/v1/systemone` and a
Python environment with its `metta-posttrain` dependencies:

```bash
METTA_REPO=/path/to/jev-enabled/metta \
METTA_PYTHON=/path/to/metta/.venv/bin/python \
OPENROUTER_API_KEY="$(aws secretsmanager get-secret-value --secret-id shared/openrouter/agent-inference-api-key --query SecretString --output text)" \
  bash tools/capture_jev_local.sh 7 crew native
  # Add "native" as a third argument to test the game server and five players.
```

The wrapper checks that the proxy exports `/v1/systemone` before starting the
game, removes the upstream key from the game process, and runs
`tools/verify_jev_capture.py` after the episode. It then projects the verified
episode into the existing System One candidate importer. It retains failed
captures for inspection as well as successful ones.

## Integration proof

`nim c -r --hints:off tests/test_llm.nim` passed, including a mixed Jev and
prompt seat in one parallel batch. All debug `tests/*.nim` passed. The
production Docker image built. Its five-player certification fixture completed
with every player exiting 0 and a readable replay. A native five-player Jev
episode completed on crew seed 42 with ten Jev calls, zero fallback, no player
failure, and a crew win. The native run used 18,268 input and 696 output
tokens; output counts can vary across reruns.

No production game version or player policy was uploaded for this pilot.
