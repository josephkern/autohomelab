#!/usr/bin/env bash
# Overnight queue (vLLM 0.23.0, Qwen3-8B-NVFP4). ABLATION: each candidate = the 0.23.0 baseline +
# ONE change, measured (N=3, c1 sentinel + c16 objective) vs the same baseline. Smoke-gated per run
# (run_experiment); fp8-KV also gets a quality eval if it survives. Does NOT auto-promote — writes a
# morning report with the recommendation; promotion stays a reviewed step.
set -uo pipefail   # NOT -e: keep going past a failed candidate
cd "$(dirname "$0")/.."
RBDIR=runbooks/RedHatAI/Qwen3-8B-NVFP4
BASE="$RBDIR/baseline.sh"
RESDIR=results/gb10-1988a9714b4e/RedHatAI/Qwen3-8B-NVFP4
SUM="$RESDIR/OVERNIGHT-0.23.0.md"
DATE=20260613
export LEVELS_SET=1,16 MAX_SECONDS=180 N=3 EXP_SHAPE=chat
log(){ echo "[$(date -u +%H:%M:%S)] $*"; }
parse(){ sed -n "s/.*$1=\([^ ]*\).*/\1/p" <<<"$2"; }   # parse <key> <medianline>

mk_variant(){ # mk_variant <slug> <delta> <json-adds> <json-repls> -> echoes path
  local out="$RBDIR/${DATE}_$1_tuned.sh"
  BASE="$BASE" OUT="$out" SLUG="$1" DELTA="$2" ADDS="$3" REPLS="$4" python3 <<'PY'
import os, json
b=open(os.environ["BASE"]).read()
for a,c in json.loads(os.environ["REPLS"]): b=b.replace(a,c)
ins="".join(f"  {a}\n" for a in json.loads(os.environ["ADDS"]))
b=b.replace("  # --- functional", ins+"  # --- functional", 1)
lines=b.splitlines(keepends=True)
hdr=[lines[0], f"# TUNED VARIANT ({os.environ['SLUG']}) on vLLM 0.23.0 — base: {os.environ['BASE']}\n",
     f"# Deltas vs base: {os.environ['DELTA']}\n"]
rest=[l for l in lines[1:] if "AUTO-GENERATED" not in l]
open(os.environ["OUT"],"w").writelines(hdr+rest)
os.chmod(os.environ["OUT"],0o755)
print(os.environ["OUT"])
PY
}

declare -A RESULT   # slug -> "c16|status|note"

measure(){ # measure <rb> -> echoes MEDIAN line
  N=3 scripts/run_experiment.sh "$1" 2>&1 | grep '^MEDIAN' | tail -1
}

log "=== overnight queue start (vLLM 0.23.0) ==="
log "measuring 0.23.0 baseline (N=3, c1/c16)"
BL=$(measure "$BASE"); BASE_C16=$(parse c16 "$BL"); log "baseline: $BL"
[ -z "$BASE_C16" ] && BASE_C16=497

# slug | delta | adds(json) | repls(json) | quality_risky
run_candidate(){
  local slug="$1" delta="$2" adds="$3" repls="$4" risky="$5"
  log "--- candidate: $slug ($delta) ---"
  local rb; rb=$(mk_variant "$slug" "$delta" "$adds" "$repls")
  git add "$rb" && git commit -q -m "exp(0.23.0): $slug — $delta" 2>/dev/null
  local m c16 st; m=$(measure "$rb"); c16=$(parse c16 "$m"); st=$(parse status "$m")
  log "$slug -> $m"
  local note="vs base ${BASE_C16}"
  if [ "$st" = ok ] && [ -n "$c16" ]; then
    awk "BEGIN{exit !($c16 > $BASE_C16*1.03)}" && note="KEEP (+$(awk "BEGIN{printf \"%.1f\",($c16/$BASE_C16-1)*100}")%)" || note="discard (within noise)"
  else note="discard ($st)"; fi
  # fp8-KV is quality-risky: if it served (not crash), eval it
  if [ "$risky" = 1 ] && [ "$st" = ok ]; then
    log "$slug survived -> quality eval (LIMIT=100)"
    scripts/serve.sh "$rb" >/tmp/on_serve.log 2>&1 && { LIMIT=100 scripts/eval.sh "$rb" general >/tmp/on_eval.log 2>&1; scripts/serve.sh down >/dev/null 2>&1; }
    local sc; sc=$(tail -n +2 "$RESDIR/accuracy.tsv" | awk -F'\t' -v c="$(sha256sum "$rb"|cut -c1-8)" '$5==c{print $10}' | tail -1)
    note="$note; eval:${sc:-na}"
  fi
  RESULT[$slug]="${c16:-na}|${st:-na}|$note"
}

run_candidate batched-16k  "+ --max-num-batched-tokens 16384" \
  '["--max-num-batched-tokens 16384"]' '[]' 0
run_candidate b12x         "+ --linear-backend flashinfer_b12x + FLASHINFER env (0.23.0 b12x FP4 SM120/121)" \
  '["--linear-backend flashinfer_b12x"]' \
  '[["VLLM_ENV=()","VLLM_ENV=( \"FLASHINFER_CUDA_ARCH_LIST=12.0f\" \"FLASHINFER_DISABLE_VERSION_CHECK=1\" )"]]' 0
run_candidate kvfp8        "+ --kv-cache-dtype fp8_e4m3 (re-test; crashed on 0.22.0)" \
  '["--kv-cache-dtype fp8_e4m3"]' '[]' 1
run_candidate memutil-08   "--gpu-memory-utilization 0.5 -> 0.8" \
  '[]' '[["--gpu-memory-utilization 0.5","--gpu-memory-utilization 0.8"]]' 0
run_candidate batched-32k-util08 "+ --max-num-batched-tokens 32768 WITH util 0.8" \
  '["--max-num-batched-tokens 32768"]' '[["--gpu-memory-utilization 0.5","--gpu-memory-utilization 0.8"]]' 0

# Morning report
{
  echo "# Overnight queue — vLLM 0.23.0, Qwen3-8B-NVFP4 ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
  echo
  echo "Baseline (0.23.0 native-FP4) median c16 = **${BASE_C16}** tok/s (N=3). Keep threshold: >3%."
  echo
  echo "| candidate | c16 | status | verdict |"
  echo "|---|---|---|---|"
  for s in batched-16k b12x kvfp8 memutil-08 batched-32k-util08; do
    IFS='|' read -r c st nt <<<"${RESULT[$s]:-na|na|not run}"
    echo "| $s | $c | $st | $nt |"
  done
  echo
  echo "Recommendation: promote the best KEEP (if any) via scripts/validate.sh + scripts/promote.sh;"
  echo "else the current VLLM-23 _final stands. fp8-KV verdict includes a quality eval if it survived."
} > "$SUM"
git add -A && git commit -q -m "overnight 0.23.0 queue: ablation results + morning report" 2>/dev/null
log "=== overnight queue DONE — report: $SUM ==="
cat "$SUM"
