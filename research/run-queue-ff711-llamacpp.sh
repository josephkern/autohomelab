#!/usr/bin/env bash
# Tune queue — DavidAU/Qwen3.6-27B-FF711 NEO-MAX GGUF on the llama.cpp host backend (20260809).
# ABLATION: each candidate = the baseline launcher config + ONE env delta, measured N=3
# (c1 sentinel + c16 objective, chat 512/256) against the SAME-SESSION baseline. Smoke-gated per
# run by run_experiment_llamacpp.sh. Does NOT auto-promote — writes a report with the
# recommendation; promotion (baking the winner into the launcher defaults) stays a reviewed step.
#
# Unlike the vLLM queues there are no runbook variants to generate: this backend's config lives in
# the launcher's env knobs (QUANT / MTP / MTP_DRAFT / NP), and bench_llamacpp.sh hashes the
# RUNNING server cmdline into config_hash, so the served config is self-documenting in results.tsv.
#
#   BASE_C16=<baseline median> research/run-queue-ff711-llamacpp.sh [slug ...]
set -uo pipefail   # NOT -e: keep going past a failed candidate
cd "$(dirname "$0")/.."

STUB=launchers/LCPP-DavidAU_Qwen3.6-27B-FF711_NEO-MAX-MTP.smoke-runbook.sh
RESDIR="results/gb10-1988a9714b4e/DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF"
SUM="$RESDIR/OVERNIGHT-llamacpp.md"
G="$HOME/gguf/Qwen3.6-27B-Fable-Fus-711-UnHeretic-NM-DAU-NEO-MAX-NEO"
BASE_C16="${BASE_C16:?set BASE_C16=<this-session baseline median c16>}"
export LEVELS_SET=1,16 MAX_SECONDS=180 N=3 EXP_SHAPE=chat

log(){ echo "[$(date -u +%H:%M:%S)] $*"; }
parse(){ sed -n "s/.*$1=\([^ ]*\).*/\1/p" <<<"$2"; }
declare -A RESULT ORDER_NOTE

# run <slug> <hypothesis> <env assignments...>
run(){
  local slug="$1" hyp="$2"; shift 2
  log "--- $slug ($hyp) [$*] ---"
  local m c16 c1 st
  m=$(env "$@" TAG="$slug" scripts/run_experiment_llamacpp.sh "$STUB" 2>&1 | grep '^MEDIAN' | tail -1)
  c16=$(parse c16 "$m"); c1=$(parse c1 "$m"); st=$(parse status "$m")
  log "$slug -> ${m:-<no MEDIAN line>}"
  local note
  if [ "${st:-}" = ok ] && [ -n "${c16:-}" ] && [ "$c16" != na ]; then
    if awk "BEGIN{exit !($c16 > $BASE_C16*1.03)}"; then
      note="KEEP (+$(awk "BEGIN{printf \"%.1f\",($c16/$BASE_C16-1)*100}")% vs base)"
    else
      note="discard ($(awk "BEGIN{printf \"%+.1f\",($c16/$BASE_C16-1)*100}")% vs base)"
    fi
  else note="discard (${st:-no-result})"; fi
  RESULT[$slug]="${c16:-na}|${c1:-na}|${st:-na}|$note"
  ORDER_NOTE[$slug]="$hyp"
}

# Candidate queue (logbook "Candidate queue" table). One axis per candidate, all vs the same base.
declare -a QUEUE=(mtp-off mtp-d1 mtp-d3 q4km q6k np32)
# want <slug> [selection...] — true if no selection was given, or the slug is in it.
# (The slug is always $1, so the "no selection" test must come AFTER the shift.)
want(){ local s="$1"; shift; [ "$#" -eq 0 ] && return 0; for a in "$@"; do [ "$a" = "$s" ] && return 0; done; return 1; }
SEL=("$@")

log "=== ff711 llama.cpp tune queue start (base c16=$BASE_C16) ==="

# 1. MTP isolation — the matched Q5_K_M pair differs ONLY by the embedded NextN tensors.
want mtp-off "${SEL[@]}" && run mtp-off "MTP off, matched regular Q5_K_M quant" \
  QUANT="$G-Q5_K_M.gguf" MTP=0
# 2. Draft depth — measured acceptance ~0.75 >> the card's 60%, so deeper drafts may pay.
want mtp-d1 "${SEL[@]}" && run mtp-d1 "MTP draft depth 1 (shallower)" \
  QUANT="$G-MTP-Q5_K_M.gguf" MTP=1 MTP_DRAFT=1
want mtp-d3 "${SEL[@]}" && run mtp-d3 "MTP draft depth 3 (deeper)" \
  QUANT="$G-MTP-Q5_K_M.gguf" MTP=1 MTP_DRAFT=3
# 3. Quant — decode is LPDDR5X-bandwidth-bound, so a smaller quant raises the ceiling.
#    A winner here is numeric-risky and must re-clear gsm8k before it can be kept.
want q4km "${SEL[@]}" && run q4km "Q4_K_M MTP (smaller = less bandwidth per token)" \
  QUANT="$G-MTP-Q4_K_M.gguf" MTP=1 MTP_DRAFT=2
want q6k "${SEL[@]}" && run q6k "Q6_K MTP (larger = quality headroom, cost check)" \
  QUANT="$G-MTP-Q6_K.gguf" MTP=1 MTP_DRAFT=2
# 4. Slots — c32 is only meaningful with NP >= 32 (llama.cpp QUEUES past -np).
#    TRAP: the launcher derives CTX=CTX_PER_SLOT*NP, so raising NP alone DOUBLES total context
#    (196608 -> 393216, ~12.6 -> ~25 GiB KV) and over-commits unified memory into swap — that is
#    two changes, not one, and it measures swapping. Hold total ctx constant by halving the
#    per-slot budget. NOTE 6144/slot only just covers coder(4096/1024); chat is unaffected.
want np32 "${SEL[@]}" && run np32 "32 slots at constant total ctx (enables a valid c32)" \
  QUANT="$G-MTP-Q5_K_M.gguf" MTP=1 MTP_DRAFT=2 NP=32 CTX_PER_SLOT=6144

{
  echo
  echo "## llama.cpp tune queue ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
  echo
  echo "Baseline (same session): Q5_K_M MTP draft=2 np=16 — **c16 $BASE_C16**. KEEP rule: c16 > +3%."
  echo
  echo "| candidate | hypothesis | c16 | c1 | status | verdict |"
  echo "|---|---|---|---|---|---|"
  for slug in "${QUEUE[@]}"; do
    want "$slug" "${SEL[@]}" || continue
    IFS='|' read -r c16 c1 st nt <<<"${RESULT[$slug]:-na|na|na|not run}"
    echo "| $slug | ${ORDER_NOTE[$slug]:-} | $c16 | $c1 | $st | $nt |"
  done
} >> "$SUM"

log "=== queue DONE ==="
sed -n '/## llama.cpp tune queue/,$p' "$SUM"
