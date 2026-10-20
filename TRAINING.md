# Hidden Agenda post-training

Five training rule presentations (`canonical`, `plain`, `numbered`, `questions`,
`reordered`) and two evaluation presentations (`heldout-briefing`,
`heldout-reference`) vary station objectives, asymmetric visibility, freezing,
and voting. The `hidden-agenda-rules-v2` bank keeps role assignments, job syntax,
reply format, and sampled rule values intact. Canonical messages remain exact.

`mixed` requires an independent nonnegative `promptSeed` and selects seed modulo
five. Selection remains fixed throughout an episode. The native host and both
bridge modes share selection; training resets reject held-out presentations.
Private observations include hashes of the actual rendered messages.

## Complete teacher exports

The existing exporter runs complete published games using miner/lurker teachers
and the production reply parser. It retains train.jsonl, validation.jsonl, and
manifest.json. Every fifth game is validation. Families use `hidden-agenda-SEED`
across modes and wordings, preventing replicas from crossing splits. Mixed
exports cycle wordings independently within training and validation. Episode IDs
include wording to distinguish matched collections. Held-out training exports
are rejected.

```sh
nim c -d:release --path:src -o:/tmp/hidden-agenda-posttrain tools/export_posttrain.nim
/tmp/hidden-agenda-posttrain /tmp/hidden-agenda-dataset 10 hidden-agenda mixed 0
```

The other variants are `hidden-agenda-notalk` and `hidden-agenda-blind`; both
disable speech. Complete replies preserve the normalized no-chat action.
All seats decide against the same state before the game applies orders.

```sh
python3 tools/test_prompt_games.py /absolute/train_bridge
python3 tools/test_posttrain.py /absolute/export_posttrain
```

Deterministic checks establish preserved behavior, not better learned play.
Compare canonical-only and mixed training with identical initialization,
optimizer, decision budget, opponents, and scenario families. Freeze training
choices before held-out evaluation. Report score spread, invalid plans,
fallbacks, incomplete games, and private-information failures.

## Numeric reinforcement learning

`tools/train_bridge.nim` exposes 74 numeric values from the acting seat's
role, position, memory, and public state. It does not read other seats' roles
or private memories. One action head chooses the shipped miner or lurker
strategy; a second chooses a legal meeting vote. The bridge collects all
active seats' choices against one pre-decision state, then advances the
production simulator to the next opening or meeting. The text exporter above
retains the full plan and speech vocabulary.

```sh
nim c -d:release --path:src -o:/tmp/hidden-agenda-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/hidden-agenda-train-bridge
```

From a Metta checkout with the Coworld training stack, pass the absolute
bridge and manifest paths to `recipes.external.coworld.train` for native
PufferLib, or `recipes.external.coworld_metta_rl.train` for Metta RL. Use
`players=5`, `max_decisions=200`, a timestep limit, and one of the three
variant IDs above. The bridge also publishes the hosted prompts as
`messages` and `semantic_view`.

## Local reinforcement learning proof

Metta RL completed 512 timesteps on each certified variant through the
numeric bridge. Native PufferLib trained 4,096 CUDA timesteps per variant,
then reloaded checkpoints for four games on held-out seeds 101 and 102:

| Variant | Seed 101 score / performance | Seed 102 score / performance | Checkpoint SHA-256 |
| --- | --- | --- | --- |
| hidden-agenda | 0 / 0.5 | 0.75 / 0.59375 | `38c0bc3d454f0b9a0fc4c1dac606546aa88bb972b5c6969bb5fb6ffab285a255` |
| hidden-agenda-notalk | -0.5 / 0.4375 | 0.75 / 0.59375 | `a74c20942c29f869cfaba27a6449df20fb8e6c2966eda4baf269c254027cd9f2` |
| hidden-agenda-blind | -0.333333 / 0.458333 | 0.285714 / 0.535714 | `7a924e7499fbbd436122817eeb450b29fef23a6b47248a31010f46e2183c6505` |

These short pilots verify training, checkpoint reload, and evaluation. They do
not establish competitive policies.
