#!/usr/bin/env bash
set -euo pipefail

seed=${1:?usage: capture_jev_local.sh seed crew|impostor}
role=${2:?role required}
: "${METTA_REPO:?Set METTA_REPO to a checkout with metta-posttrain installed}"
: "${METTA_PYTHON:?Set METTA_PYTHON to a Python environment with metta-posttrain dependencies}"
: "${OPENROUTER_API_KEY:?Set an approved OpenRouter inference key}"

mkdir -p dist/jev-local tmp/bin
artifact_dir=$(mktemp -d dist/jev-local/capture.XXXXXX)
chmod 700 "$artifact_dir"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
export METTA_CAPTURE_KEY
METTA_CAPTURE_KEY=$(openssl rand -hex 24)
export METTA_CAPTURE_URL="http://127.0.0.1:$port"

PYTHONPATH="$METTA_REPO/packages/metta-posttrain/src" \
  "$METTA_PYTHON" -m metta_posttrain.capture \
  --traces "$artifact_dir/traces.jsonl" --workload hidden-agenda \
  --schema-revision hidden-agenda-actions-v1 --port "$port" \
  > "$artifact_dir/proxy.log" 2>&1 &
proxy_pid=$!
trap 'kill "$proxy_pid" 2>/dev/null || true; wait "$proxy_pid" 2>/dev/null || true' EXIT
ready=0
for _ in {1..100}; do
  if openapi=$(curl --silent --fail "$METTA_CAPTURE_URL/openapi.json" 2>/dev/null); then
    if printf '%s' "$openapi" | python3 -c 'import json,sys; sys.exit("/v1/systemone" not in json.load(sys.stdin)["paths"])'; then
      ready=1
      break
    fi
  fi
  if ! kill -0 "$proxy_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
if [ "$ready" -ne 1 ]; then
  tail -30 "$artifact_dir/proxy.log"
  exit 1
fi

nim c --hints:off -o:tmp/bin/jev-local-eval tools/jev_local_eval.nim
env -u OPENROUTER_API_KEY -u TYPESAFE_API_KEY \
  -u ANTHROPIC_API_KEY -u ANTHROPIC_API_KEY_URI \
  -u AWS_ENDPOINT_URL_BEDROCK_RUNTIME -u AWS_BEARER_TOKEN_BEDROCK \
  tmp/bin/jev-local-eval jev "$seed" "$role" \
  > "$artifact_dir/run.log"

replay=$(python3 - "$artifact_dir/run.log" <<'PY'
import json
import sys
from pathlib import Path

summary = json.loads(Path(sys.argv[1]).read_text().splitlines()[-1])
print(Path(summary['artifacts']) / 'replay.json')
PY
)
python3 tools/verify_jev_capture.py "$artifact_dir/traces.jsonl" "$replay" \
  --episodes-output "$artifact_dir/episodes.jsonl"
PYTHONPATH="$METTA_REPO/packages/metta-posttrain/src:$METTA_REPO/packages/metta-training/src" \
  "$METTA_PYTHON" -m metta_posttrain.cli systemone-candidates \
  --traces "$artifact_dir/traces.jsonl" \
  --episodes "$artifact_dir/episodes.jsonl" \
  --output "$artifact_dir/candidates.jsonl"
echo "capture_artifacts=$artifact_dir"
