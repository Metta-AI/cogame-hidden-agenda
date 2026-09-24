#!/usr/bin/env bash
set -euo pipefail

mode=${1:?usage: local_episode.sh miner|jev seed crew|impostor}
seed=${2:?seed required}
role=${3:?role required}
port=${PORT:-18118}
case "$mode" in miner|jev) ;; *) exit 2 ;; esac
case "$role" in crew|impostor) ;; *) exit 2 ;; esac

mkdir -p tmp/bin
episode_dir=$(mktemp -d tmp/episode.XXXXXX)
episode_dir="$PWD/$episode_dir"
python3 - "$seed" "$role" "$episode_dir/config.json" <<'PY'
import json
import sys
from pathlib import Path

seed, role, path = sys.argv[1:]
Path(path).write_text(json.dumps({
    'tokens': [f't{i}' for i in range(5)],
    'players': [{'name': f'P{i}'} for i in range(5)],
    'seed': int(seed),
    'variant': 'hidden-agenda-notalk',
    'impostorSlot': 0 if role == 'impostor' else 4,
    'chat': False, 'meetingTicks': 25, 'sayTick': -1,
    'revealTick': 5, 'switchTick': 18, 'resolveTick': 23,
    'minBatchSeconds': 0, 'player_connect_timeout_seconds': 10,
}))
PY
nim c --hints:off -o:tmp/bin/hidden-agenda src/hidden_agenda.nim
nim c --hints:off -o:tmp/bin/hidden-agenda-player src/hidden_agenda_player.nim

COGAME_HOST=127.0.0.1 COGAME_PORT="$port" \
  COGAME_CONFIG_URI="file://$episode_dir/config.json" \
  COGAME_RESULTS_URI="file://$episode_dir/results.json" \
  COGAME_SAVE_REPLAY_URI="file://$episode_dir/replay.json" \
  COGAME_PLAYER_FAILURE_URI="file://$episode_dir/player_failure.json" \
  tmp/bin/hidden-agenda > "$episode_dir/game.log" 2>&1 &
game=$!
players=()
cleanup() {
  kill "$game" "${players[@]}" 2>/dev/null || true
}
trap cleanup EXIT
for _ in {1..50}; do
  if curl --silent --fail "http://127.0.0.1:$port/healthz" >/dev/null; then
    break
  fi
  sleep 0.1
done
for slot in {0..4}; do
  if [ "$slot" = 0 ] && [ "$mode" = jev ]; then
    COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$port/player?slot=$slot&token=t$slot" \
      PLAYER_JEV=1 tmp/bin/hidden-agenda-player \
      > "$episode_dir/player$slot.log" 2>&1 &
  else
    COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$port/player?slot=$slot&token=t$slot" \
      PLAYER_SCRIPTED=miner tmp/bin/hidden-agenda-player \
      > "$episode_dir/player$slot.log" 2>&1 &
  fi
  players+=("$!")
done
wait "$game"
python3 - "$episode_dir" <<'PY'
import json
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
results = json.loads((path / 'results.json').read_text())
replay = json.loads((path / 'replay.json').read_text())
log = (path / 'game.log').read_text()
usage = [tuple(map(int, match)) for match in re.findall(
    r'input_tokens (\d+) output_tokens (\d+)', log)]
orders = [event for event in replay['events']
          if event['k'] == 'order' and event['seat'] == 0]
print(json.dumps({
    'artifacts': str(path), 'seat0_score': results['scores'][0],
    'winner': results['winner'], 'ending': results['ending'],
    'jev_calls': len(usage), 'input_tokens': sum(x[0] for x in usage),
    'output_tokens': sum(x[1] for x in usage),
    'seat0_fallbacks': sum(event['source'] == 'fallback' for event in orders),
    'seat0_jev_orders': sum(event['source'] == 'jev' for event in orders),
}))
PY
