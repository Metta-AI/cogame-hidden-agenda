# Hidden Agenda post-training

`tools/export_posttrain.nim` plays complete native episodes for all three
certified variants. At each opening or meeting, it captures the system and
user prompts the hosted game gives each active seat. The shipped miner and
lurker policies supply replies accepted by the production parser. All seats
choose from the same pre-decision state, and whole episodes stay in one data
split. The no-talk variants leave `say` empty because the game ignores speech.

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/hidden-agenda-posttrain tools/export_posttrain.nim
python3 tools/test_posttrain.py /tmp/hidden-agenda-posttrain
/tmp/hidden-agenda-posttrain /tmp/hidden-agenda-data 10 hidden-agenda
```

The other variant IDs are `hidden-agenda-notalk` and `hidden-agenda-blind`.
Ten complete episodes yielded 100 train and 18 validation decisions for
the first two variants, and 84 train and 18 validation decisions for blind.
All 338 examples fit 4,096 tokens with a local WordLevel smoke tokenizer.
One CPU optimizer step reduced four-example validation loss from 1.72457
to 1.71932, 1.73310 to 1.72771, and 1.73310 to 1.72760 in variant order.
These runs verify the post-training path, not stronger league play.

From a Metta checkout with `metta-posttrain` installed:

```sh
uv run --package metta-posttrain --extra train python -m metta_posttrain.train \
  --dataset /tmp/hidden-agenda-data --output /tmp/hidden-agenda-adapter \
  --model Qwen/Qwen3-0.6B --max-steps 100 --max-length 4096
```

The native prompt includes the acting seat's role and limited vision. It
does not reveal another seat's role. The exporter preserves arbitrary valid
plans, meeting votes, private notes, and speech where the variant allows it.

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
