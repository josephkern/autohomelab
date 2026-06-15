#!/usr/bin/env bash
# suite.sh <runbook.sh> — the STANDARD test suite (all three gates) for a model, in ONE serve
# session (load amortized across every check). Run at BASELINE (Gate-1 stage) and at FINALIZE.
# The tuning LOOP stays lean (chat c1/c16, N=3 via run_experiment.sh) — do NOT use suite.sh
# per-candidate.
#
#   Gate 1 (works): smoke.sh                                   — functional 4-check
#   Gate 2 (good):  eval.sh general   (gsm8k, mmlu)            — in-loop quality reference
#                   eval.sh resistant (mmlu_pro, gpqa_diamond) — harder/less-memorized (tier 2)
#   Gate 3 (fast):  bench.sh chat coder                        — full 1,4,8,16,32 sweep, BOTH shapes
#
# Env:
#   FULL=1        run the FULL eval (no --limit) — use at finalize. Default: LIMIT-capped.
#   LIMIT=N       eval sample cap when not FULL (default 100, the in-loop reference setting).
#   LEVELS_SET    throughput levels (default 1,4,8,16,32 — the full characterization curve).
#   SHAPES        throughput shapes (default "chat coder").
#   MAX_SECONDS   per-stage bench seconds (default 180).
#
# Serves once, runs everything against the live endpoint, tears down. Appends results.tsv +
# accuracy.tsv rows and writes a SUITE-<cfg>.md summary. Crash-safe: bench.sh's watchdog +
# per-level isolation; evals/benches re-serve if a wedge tore the container down.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ADAPTER="$REPO_ROOT/backends/vllm/adapter.sh"

RUNBOOK="${1:?usage: suite.sh <runbook.sh>}"
[ -f "$RUNBOOK" ] || { echo "not found: $RUNBOOK" >&2; exit 1; }

if [ "${FULL:-0}" = 1 ]; then unset LIMIT; else export LIMIT="${LIMIT:-100}"; fi
export MAX_SECONDS="${MAX_SECONDS:-180}"
export LEVELS_SET="${LEVELS_SET:-1,4,8,16,32}"
SHAPES="${SHAPES:-chat coder}"

MODEL=""; SERVED_NAME=""
# shellcheck disable=SC1090
source "$RUNBOOK"; : "${MODEL:?runbook must set MODEL}"; : "${SERVED_NAME:=$MODEL}"
ORG="${MODEL%%/*}"; [ "$ORG" = "$MODEL" ] && ORG="_"; NAME="${MODEL##*/}"
NODE_FP="$(find "$REPO_ROOT/results" -maxdepth 2 -name node_profile.json -printf '%h\n' 2>/dev/null | head -1 | xargs -r basename)"
CFG="$(sha256sum "$RUNBOOK" | cut -c1-8)"
OUT_DIR="$REPO_ROOT/results/$NODE_FP/$ORG/$NAME"
REPORT="$OUT_DIR/SUITE-${CFG}.md"
DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log(){ echo "[$(date -u +%H:%M:%S)] $*" >&2; }

ensure_up(){ "$ADAPTER" health >/dev/null 2>&1 && return 0
  log "endpoint not healthy — (re)serving"
  "$SCRIPT_DIR/serve.sh" "$RUNBOOK" >/dev/null 2>"$REPO_ROOT/.ahl_suite_serve.log"; }

log "=== STANDARD SUITE: $(realpath --relative-to="$REPO_ROOT" "$RUNBOOK") (cfg $CFG; eval ${LIMIT:+limit=$LIMIT}${LIMIT:-FULL}) ==="
ensure_up || { echo "serve failed; see .ahl_suite_serve.log" >&2; exit 1; }

# Reasoning models emit <think> CoT that truncates/derails GENERATIVE eval (35B gsm8k 40->90 with
# thinking off). Such models get their generative quality measured on a SECOND, thinking-OFF serve
# (chat endpoint, enable_thinking=false); the loglikelihood reference (mmlu) is thinking-agnostic and
# stays on this deployed (thinking-ON) serve. Non-reasoning models run everything on the one serve.
REASONING=0; grep -q -- '--reasoning-parser' "$RUNBOOK" && REASONING=1

# Gate 1 — functional (deployed thinking-ON serve)
smoke=PASS; "$SCRIPT_DIR/smoke.sh" "$RUNBOOK" || smoke=FAIL; log "Gate 1 smoke: $smoke"

# Gate 2 — quality on the thinking-ON serve
gen=ok; res=ok
if [ "$REASONING" = 1 ]; then
  ensure_up && TASKS=mmlu "$SCRIPT_DIR/eval.sh" "$RUNBOOK" general || gen=error
  log "Gate 2 mmlu (loglikelihood, think-on): $gen   [generative gsm8k/mmlu_pro -> think-off pass below]"
else
  ensure_up && "$SCRIPT_DIR/eval.sh" "$RUNBOOK" general   || gen=error; log "Gate 2 general: $gen"
  ensure_up && "$SCRIPT_DIR/eval.sh" "$RUNBOOK" resistant || res=error; log "Gate 2 resistant: $res"
fi

# Gate 3 — throughput, full curve, both shapes (deployed config; one bench.sh call)
bench=ok
ensure_up && STATUS=measured NOTES="suite full-sweep" "$SCRIPT_DIR/bench.sh" "$RUNBOOK" $SHAPES || bench=crash
log "Gate 3 throughput ($SHAPES): $bench"
"$SCRIPT_DIR/serve.sh" down >/dev/null 2>&1 || true

# Gate 2 (generative, thinking-OFF) — reasoning models only: separate serve with enable_thinking=false.
if [ "$REASONING" = 1 ]; then
  log "reasoning model -> thinking-OFF generative eval (gsm8k + mmlu_pro, chat endpoint)"
  if AHL_THINK_OFF=1 "$SCRIPT_DIR/serve.sh" "$RUNBOOK" >/dev/null 2>"$REPO_ROOT/.ahl_suite_serve.log"; then
    THINK=off TASKS=gsm8k "$SCRIPT_DIR/eval.sh" "$RUNBOOK" general   || gen=error
    THINK=off             "$SCRIPT_DIR/eval.sh" "$RUNBOOK" resistant || res=error
    "$SCRIPT_DIR/serve.sh" down >/dev/null 2>&1 || true
    log "Gate 2 generative (think-off): gsm8k+mmlu_pro done"
  else res=error; log "thinking-OFF serve failed (see .ahl_suite_serve.log)"; fi
fi

# ── Summary report ────────────────────────────────────────────────────────────
python3 - "$OUT_DIR" "$CFG" "$REPORT" "$DATE" "$smoke" "$gen" "$res" "$bench" "${LIMIT:-FULL}" "$(realpath --relative-to="$REPO_ROOT" "$RUNBOOK")" <<'PY'
import sys, csv, os
out_dir, cfg, report, date, smoke, gen, res, bench, lim, rb = sys.argv[1:11]
def rows(p):
    try: return list(csv.DictReader(open(p), delimiter='\t'))
    except FileNotFoundError: return []
# latest throughput row per shape for this cfg
tps={}
for r in rows(os.path.join(out_dir,'results.tsv')):
    if r.get('config_hash')==cfg:
        tps[r.get('shape','?')]=r
# latest accuracy row per (suite, tasks, think) for this cfg — keep think-on/off rows distinct
acc={}
for r in rows(os.path.join(out_dir,'accuracy.tsv')):
    if r.get('config_hash')==cfg:
        acc[(r.get('suite','?'), r.get('tasks',''), r.get('think','on'))]=r
L=[]
L.append(f"# Standard suite — {rb}")
L.append(f"- date: {date}    config_hash: {cfg}    eval cap: {lim}")
L.append(f"- **Gate 1 functional (smoke): {smoke}**")
L.append(f"- **Gate 2 quality:** general={gen}, resistant={res}")
for key,r in sorted(acc.items()):
    L.append(f"    - {r.get('suite','?')} [{r.get('tasks','')}] limit={r.get('limit','')} think={r.get('think','on')}: `{r.get('scores','')}`")
L.append(f"- **Gate 3 throughput ({bench}):** full sweep, tok/s")
if tps:
    L.append("")
    L.append("| shape | c1 | c4 | c8 | c16 | c32 |")
    L.append("|---|---|---|---|---|---|")
    for shape,r in sorted(tps.items()):
        L.append(f"| {shape} | {r.get('tps_c1','')} | {r.get('tps_c4','')} | {r.get('tps_c8','')} | {r.get('tps_c16','')} | {r.get('tps_c32','')} |")
L.append("")
L.append("Compare quality to the model card's recovery reference; throughput objective = median c16 (chat).")
open(report,'w').write("\n".join(L)+"\n")
print(report)
PY
log "=== SUITE DONE — report: $(realpath --relative-to="$REPO_ROOT" "$REPORT") ==="
cat "$REPORT" >&2
