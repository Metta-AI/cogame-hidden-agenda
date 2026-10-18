# Hidden Agenda post-training

The game has five training introductions (`canonical`, `plain`, `numbered`,
`questions`, `reordered`) and two evaluation-only introductions
(`heldout-briefing`, `heldout-reference`). `mixed` selects one training wording
using `promptSeed % 5`. Selection stays outside simulation state and remains
fixed throughout an episode. Role-specific rules and action grammar stay exact.

The native host and both bridge modes accept `promptVariant` and `promptSeed`.
Bridge reset rejects held-out wording when `split` is `train`. Exact system/user
SHA-256 hashes accompany private observations. No model-quality improvement is
established by deterministic checks.

## Private candidates

`tools/export_posttrain.nim` runs complete games using the shipped miner/lurker
teachers and production reply parser. It writes private `trajectories.jsonl`,
per-game replay files, and a manifest requiring independent review. Each decision
joins its private pre-decision observation to the actual applied order. All seats
choose against the same pre-decision state. Candidate generation requires a
clean committed checkout and at least ten games.

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/hidden-agenda-posttrain tools/export_posttrain.nim
/tmp/hidden-agenda-posttrain /tmp/hidden-agenda-candidates 10 hidden-agenda mixed 3
```

Other variants are `hidden-agenda-notalk` and `hidden-agenda-blind`; both disable
speech. A `hidden-agenda-SEED` family groups variants and wordings for downstream
split isolation. Candidates have no automatic success label or train/validation
assignment. Review and admission through the shared Coworld importer precede
training. Historical direct `train.jsonl` exports are not this candidate format.

## Native evidence

Set `HIDDEN_AGENDA_ATTEMPT_TRACE_DIR`, `HIDDEN_AGENDA_HOST_TRACE`, and
`HIDDEN_AGENDA_SOURCE_REVISION` for private local capture. Destinations must be
new: files use exclusive creation and owner-only permissions. Actual model calls
record prepared request bodies, exact prompts, responses, retries and normalized
replies. The host separately records pre-decision observations and applied orders.
Budget reuse and fallback orders retain their source; they are not fresh samples.
These artifacts must not be published as spectator or player data.

## Text actions

Append `--language` to the bridge command for full JSON plans, votes, conditional
votes, notes, hunches and permitted speech. The production parser validates each
reply. It collects the whole active-seat batch before advancing the simulator.
The numeric bridge retains its original encoding and strategy/vote heads.

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
