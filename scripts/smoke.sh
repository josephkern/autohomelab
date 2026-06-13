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
# Reasoning models spend many tokens thinking before answering — a small budget truncates them to
# an empty response. Use a generous budget and accept content OR reasoning_content as "responded".
MAXTOK="${SMOKE_MAX_TOKENS:-1024}"

echo "== smoke: $SERVED_NAME @ $TARGET (max_tokens=$MAXTOK) ==" >&2

# 1) chat coherence — pass if content OR reasoning_content is non-empty
R=$(api "{\"model\":\"$SERVED_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"What is 2+2? Answer with just the number.\"}],\"max_tokens\":$MAXTOK,\"temperature\":0}")
C=$(printf '%s' "$R" | python3 -c "import sys,json;m=json.load(sys.stdin)['choices'][0]['message'];print(((m.get('content') or '')+(m.get('reasoning_content') or '')).strip())" 2>/dev/null || echo "")
[ -n "$C" ] && ok "chat responds ($(printf '%s' "$C" | tr -d '\n' | cut -c1-40))" || bad "chat empty/failed"

# 2) structured / JSON output (content must parse as JSON)
R=$(api "{\"model\":\"$SERVED_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Return a JSON object {\\\"city\\\":\\\"Paris\\\"} and nothing else.\"}],\"max_tokens\":$MAXTOK,\"temperature\":0,\"response_format\":{\"type\":\"json_object\"}}")
J=$(printf '%s' "$R" | python3 -c "import sys,json;print(json.load(sys.stdin)['choices'][0]['message'].get('content') or '')" 2>/dev/null || echo "")
printf '%s' "$J" | python3 -c "import sys,json;json.loads(sys.stdin.read())" 2>/dev/null && ok "structured output is valid JSON" || bad "structured output not valid JSON ($J)"

# 3) tool-calling (only if the runbook enabled a tool-call parser)
if printf '%s' "$FLAGS" | grep -q 'tool-call-parser'; then
  TOOLS='[{"type":"function","function":{"name":"get_weather","description":"Get weather","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}]'
  R=$(api "{\"model\":\"$SERVED_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"What is the weather in Paris? Use the tool.\"}],\"tools\":$TOOLS,\"tool_choice\":\"auto\",\"max_tokens\":$MAXTOK,\"temperature\":0}")
  ARGS=$(printf '%s' "$R" | python3 -c "import sys,json;tc=json.load(sys.stdin)['choices'][0]['message'].get('tool_calls') or [];print(tc[0]['function']['arguments'] if tc else '')" 2>/dev/null || echo "")
  if [ -n "$ARGS" ] && printf '%s' "$ARGS" | python3 -c "import sys,json;json.loads(sys.stdin.read())" 2>/dev/null; then
    ok "tool-call selected + arguments parse as JSON"
  else bad "tool-call not produced/parseable"; fi
else echo "  skip: tool-call (no --tool-call-parser in runbook)"; fi

# 4) reasoning parser working = no raw <think> leak into content (the regression we saw without it)
if printf '%s' "$FLAGS" | grep -q 'reasoning-parser'; then
  R=$(api "{\"model\":\"$SERVED_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Briefly: is 91 prime? Show reasoning.\"}],\"max_tokens\":$MAXTOK,\"temperature\":0}")
  CC=$(printf '%s' "$R" | python3 -c "import sys,json;print(json.load(sys.stdin)['choices'][0]['message'].get('content') or '')" 2>/dev/null || echo "")
  if printf '%s' "$CC" | grep -q '<think>'; then bad "reasoning parser not routing — <think> leaked into content"
  else ok "reasoning parser routing (no <think> leak in content)"; fi
else echo "  skip: reasoning (no --reasoning-parser in runbook)"; fi

echo "== smoke: $pass passed, $fail failed ==" >&2
[ "$fail" -eq 0 ]
