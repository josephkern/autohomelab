#!/usr/bin/env bash
# capabilities.sh [image_ref] — snapshot the serving feature surface of a vLLM image so we KNOW
# (not guess) which flags/backends/env-gated features that pinned version supports.
#
# Writes backends/vllm/capabilities/<vllm_version>.txt (committed): full `vllm serve --help=all`,
# the choice-lists for the key multi-choice knobs, the vLLM version, and the vllm.envs var names.
# This is the authoritative per-image inventory and the DIFF TARGET when bumping images:
#   scripts/capabilities.sh <old> ; scripts/capabilities.sh <new> ; diff the two files.
# The tuning loop should enumerate candidate backends from these choice-lists, not from memory.
#
# NOTE: needs --gpus all (vLLM infers args from the device). Don't run during a benchmark — the
# extra container contends for the GPU and can skew tok/s. Run when the box is free.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/backends/vllm/image.lock"
IMG="${1:-$AHL_VLLM_DEFAULT_IMAGE}"

ver="$(docker run --rm --entrypoint python3 "$IMG" -c 'import vllm;print(vllm.__version__)' 2>/dev/null || echo unknown)"
OUT_DIR="$REPO_ROOT/backends/vllm/capabilities"; mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/${ver}.txt"
echo ">> snapshotting vLLM $ver capabilities -> ${OUT#$REPO_ROOT/}" >&2

HELP="$(docker run --rm --gpus all --entrypoint vllm "$IMG" serve --help=all 2>/dev/null || true)"
ENVS="$(docker run --rm --entrypoint python3 "$IMG" -c \
  'import vllm.envs as e; print("\n".join(sorted(k for k in dir(e) if k.isupper())))' 2>/dev/null || true)"

{
  echo "# vLLM capability snapshot"
  echo "image:   $IMG"
  echo "version: $ver"
  echo
  echo "## Key multi-choice knobs (the loop's option space) ###############################"
  for flag in linear-backend moe-backend attention-backend kv-cache-dtype quantization \
              compilation-config cudagraph-mode; do
    line="$(grep -oE -- "--$flag[ =]\{[^}]*\}" <<<"$HELP" | head -1)"
    [ -n "$line" ] && echo "$line" || echo "--$flag : (no enumerated choices; see full help)"
  done
  echo
  echo "## vllm.envs variable names (env-gated features) ##################################"
  echo "$ENVS"
  echo
  echo "## Full \`vllm serve --help=all\` ##################################################"
  echo "$HELP"
} > "$OUT"

echo ">> wrote $OUT" >&2
echo "$OUT"
