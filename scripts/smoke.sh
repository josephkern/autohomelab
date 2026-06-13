#!/usr/bin/env bash
# smoke.sh <runbook.sh> — Gate 1 (functional): confirm the model's FEATURES work, not just that the
# endpoint is up. Sends representative requests and asserts each behaves. Fast (seconds). A config
# that fails smoke is rejected regardless of tok/s. The server must already be up (serve.sh).
#
# Checks (each model-appropriate; tool-call/reasoning only if the runbook enables the parser):
#   - chat: a coherent, non-empty chat completion
#   - structured: JSON-object response is valid JSON
#   - tool-call: a tool is selected + arguments parse as JSON   (if --tool-call-parser in runbook)
#   - reasoning: a reasoning channel is emitted                  (if --reasoning-parser in runbook)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
[ -f "$REPO_ROOT/.env" ] && set -a && source "$REPO_ROOT/.env" && set +a
RUNBOOK="${1:?usage: smoke.sh <runbook.sh>}"
TARGET="${TARGET:-http://${AHL_HOST:-127.0.0.1}:${AHL_PORT:-8000}}"

MODEL=""; SERVED_NAME=""; VLLM_FLAGS=()
# shellcheck disable=SC1090
source "$RUNBOOK"; : "${SERVED_NAME:=$MODEL}"
FLAGS="${VLLM_FLAGS[*]}"
pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1" >&2; fail=$((fail+1)); }

api() { curl -fsS "$TARGET/v1/chat/completions" -H 'Content-Type: application/json' -d "$1" 2>/dev/null; }

echo "== smoke: $SERVED_NAME @ $TARGET ==" >&2

# 1) chat coherence
R=$(api "{\"model\":\"$SERVED_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}],\"max_tokens\":16,\"temperature\":0}")
C=$(printf '%s' "$R" | python3 -c "import sys,json;print(json.load(sys.stdin)['choices'][0]['message'].get('content') or '')" 2>/dev/null || echo "")
[ -n "$C" ] && ok "chat returns non-empty content ($(printf '%s' "$C" | tr -d '\n' | cut -c1-40))" || bad "chat empty/failed"

# 2) structured / JSON output
R=$(api "{\"model\":\"$SERVED_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Return a JSON object {\\\"city\\\":\\\"Paris\\\"} and nothing else.\"}],\"max_tokens\":64,\"temperature\":0,\"response_format\":{\"type\":\"json_object\"}}")
J=$(printf '%s' "$R" | python3 -c "import sys,json;print(json.load(sys.stdin)['choices'][0]['message']['content'])" 2>/dev/null || echo "")
printf '%s' "$J" | python3 -c "import sys,json;json.loads(sys.stdin.read())" 2>/dev/null && ok "structured output is valid JSON" || bad "structured output not valid JSON ($J)"

# 3) tool-calling (only if the runbook enabled a tool-call parser)
if printf '%s' "$FLAGS" | grep -q 'tool-call-parser'; then
  TOOLS='[{"type":"function","function":{"name":"get_weather","description":"Get weather","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}]'
  R=$(api "{\"model\":\"$SERVED_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"What is the weather in Paris? Use the tool.\"}],\"tools\":$TOOLS,\"tool_choice\":\"auto\",\"max_tokens\":128,\"temperature\":0}")
  ARGS=$(printf '%s' "$R" | python3 -c "import sys,json;tc=json.load(sys.stdin)['choices'][0]['message'].get('tool_calls') or [];print(tc[0]['function']['arguments'] if tc else '')" 2>/dev/null || echo "")
  if [ -n "$ARGS" ] && printf '%s' "$ARGS" | python3 -c "import sys,json;json.loads(sys.stdin.read())" 2>/dev/null; then
    ok "tool-call selected + arguments parse as JSON"
  else bad "tool-call not produced/parseable"; fi
else echo "  skip: tool-call (no --tool-call-parser in runbook)"; fi

# 4) reasoning channel (only if the runbook enabled a reasoning parser)
if printf '%s' "$FLAGS" | grep -q 'reasoning-parser'; then
  R=$(api "{\"model\":\"$SERVED_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"What is 17*23? Think briefly.\"}],\"max_tokens\":256,\"temperature\":0}")
  RC=$(printf '%s' "$R" | python3 -c "import sys,json;print(json.load(sys.stdin)['choices'][0]['message'].get('reasoning_content') or '')" 2>/dev/null || echo "")
  [ -n "$RC" ] && ok "reasoning channel emitted" || bad "no reasoning_content despite --reasoning-parser"
else echo "  skip: reasoning (no --reasoning-parser in runbook)"; fi

echo "== smoke: $pass passed, $fail failed ==" >&2
[ "$fail" -eq 0 ]
