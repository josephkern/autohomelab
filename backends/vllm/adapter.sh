#!/usr/bin/env bash
# vLLM backend adapter for autohomelab. Implements the contract in backends/adapter.md.
#
# The AUTHORITATIVE image pin lives in the RUNBOOK (VLLM_IMAGE, by digest) — same discipline
# as the hand-written serve scripts, because image version is a per-model tuning dimension.
# image.lock only supplies a default for runbooks that don't pin one.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONTAINER=ahl-vllm

# shellcheck disable=SC1091
source "$SCRIPT_DIR/image.lock"                 # AHL_VLLM_DEFAULT_IMAGE / _ENTRYPOINT_SERVE
[ -f "$REPO_ROOT/.env" ] && set -a && source "$REPO_ROOT/.env" && set +a
: "${AHL_PORT:=8000}"; : "${AHL_HOST:=127.0.0.1}"

cmd_up() {
  local runbook="${1:?usage: adapter.sh up <runbook.sh> [node_profile.json]}"
  [ -f "$runbook" ] || { echo "runbook not found: $runbook" >&2; exit 1; }

  # Runbook contract: MODEL (req), SERVED_NAME, MODEL_REVISION, VLLM_IMAGE, VLLM_ENTRYPOINT_SERVE,
  # VLLM_FLAGS=( ... ), and optional VLLM_ENV=( "KEY=VAL" ... ) passed to the container.
  MODEL=""; SERVED_NAME=""; MODEL_REVISION=""; VLLM_FLAGS=(); VLLM_ENV=()
  VLLM_IMAGE="${AHL_VLLM_DEFAULT_IMAGE}"; VLLM_ENTRYPOINT_SERVE="${AHL_VLLM_DEFAULT_ENTRYPOINT_SERVE}"
  # shellcheck disable=SC1090
  source "$runbook"
  : "${MODEL:?runbook must set MODEL}"; : "${SERVED_NAME:=$MODEL}"

  docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER" && {
    echo "removing existing $CONTAINER" >&2; docker rm -f "$CONTAINER" >/dev/null; }

  local env_args=(-e "HF_TOKEN=${HF_TOKEN:-}")
  local kv; for kv in "${VLLM_ENV[@]}"; do env_args+=(-e "$kv"); done
  local rev_args=(); [ -n "$MODEL_REVISION" ] && rev_args=(--revision "$MODEL_REVISION")

  # Thinking-OFF serve (eval): AHL_THINK_OFF=1 sets the chat template's enable_thinking=false
  # server-side, so reasoning models don't emit CoT (which truncates/derails generative eval — gsm8k
  # 40->90 on the 35B). Only effective on the chat endpoint; eval.sh THINK=off pairs with this.
  [ "${AHL_THINK_OFF:-0}" = 1 ] && VLLM_FLAGS+=(--default-chat-template-kwargs '{"enable_thinking": false}')

  # `vllm/vllm-openai` ENTRYPOINT is already `vllm serve` -> pass MODEL positionally.
  # NGC/shell-entrypoint images need it prepended (runbook sets VLLM_ENTRYPOINT_SERVE=false).
  local serve_prefix=(); [ "${VLLM_ENTRYPOINT_SERVE}" != "true" ] && serve_prefix=(vllm serve)

  echo "image:  $VLLM_IMAGE" >&2
  echo "model:  $MODEL ${MODEL_REVISION:+@$MODEL_REVISION}" >&2
  docker run -d --name "$CONTAINER" --ipc=host --gpus all \
    -p "${AHL_PORT}:8000" "${env_args[@]}" \
    -v "${HF_HOME:-$HOME/.cache/huggingface}:/root/.cache/huggingface" \
    "$VLLM_IMAGE" "${serve_prefix[@]}" "$MODEL" \
      --served-model-name "$SERVED_NAME" "${rev_args[@]}" "${VLLM_FLAGS[@]}" >/dev/null

  echo "waiting for health (up to ~20 min for first weight load)..." >&2
  local i
  for i in $(seq 1 240); do
    cmd_health >/dev/null 2>&1 && { echo "http://${AHL_HOST}:${AHL_PORT}"; return 0; }
    [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ] && {
      echo "container exited; last logs:" >&2; docker logs --tail 60 "$CONTAINER" >&2; exit 1; }
    sleep 5
  done
  echo "timed out; last logs:" >&2; docker logs --tail 60 "$CONTAINER" >&2; exit 1
}

cmd_health() { curl -fsS "http://${AHL_HOST}:${AHL_PORT}/v1/models" >/dev/null; }
cmd_down()   { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }

cmd_info() {  # backend string for results.tsv: vllm@<ver>(img:sha256:<short>)
  # Read the image from the RUNNING container (info is called standalone, so VLLM_IMAGE — only set
  # during `up` from the runbook — isn't in scope here). Fall back to the registry default.
  local ver="unknown" digest
  digest="$(docker inspect -f '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || true)"
  [ -z "$digest" ] && digest="${VLLM_IMAGE:-$AHL_VLLM_DEFAULT_IMAGE}"
  [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = "true" ] &&
    ver="$(docker exec "$CONTAINER" python3 -c 'import vllm;print(vllm.__version__)' 2>/dev/null || echo unknown)"
  local short; short="$(grep -m1 -oE 'sha256:[0-9a-f]{12}' <<<"$digest" || true)"
  [ -z "$short" ] && short="$digest"
  echo "vllm@${ver}(img:${short})"
}

# Best-effort peak memory (GB). On discrete GPUs: GPU memory.used. On UNIFIED-memory nodes
# (GB10) nvidia-smi reports N/A, so fall back to SYSTEM used memory (MemTotal-MemAvailable) —
# the weights+KV live in the shared pool. That proxy is confounded by the OS/other processes,
# so treat peak_gb on unified nodes as approximate. (read < <(...) avoids SIGPIPE under pipefail.)
cmd_peakmem() {
  local m=""; IFS= read -r m < <(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null) || true
  m="${m// /}"
  if [[ "$m" =~ ^[0-9]+$ ]]; then
    awk -v x="$m" 'BEGIN{printf "%.1f", x/1024}'
  else
    awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf "%.1f",(t-a)/1048576}' /proc/meminfo
  fi
}

case "${1:-}" in
  up) shift; cmd_up "$@" ;;
  health) cmd_health && echo ok ;;
  down) cmd_down ;;
  info) cmd_info ;;
  peakmem) cmd_peakmem ;;
  *) echo "usage: adapter.sh {up <runbook.sh> [node_profile.json]|health|down|info|peakmem}" >&2; exit 2 ;;
esac
