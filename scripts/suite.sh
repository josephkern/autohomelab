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
#   MAX_SECONDS   per-stage bench seconds for the chat shape (default 180).
#   MAX_SECONDS_CODER  per-stage bench seconds for the coder shape (default 600 — the coder
#                 shape drains far fewer requests per stage; 180 yields VOID non-monotonic data).
#
# Serves once, runs everything against the live endpoint, tears down. Appends results.tsv +
# accuracy.tsv rows and writes a SUITE-<cfg>.md summary. Crash-safe: bench.sh's watchdog +
# per-level isolation; evals/benches re-serve if a wedge tore the container down.
#
# The report carries an explicit SUITE VERDICT and the Gate-3 rows' `status`/`validity`/`req_counts`
# (docs/validity-contract.md). A Gate-3 measurement-validity failure is a FAIL — never a pass with a
# plausible number attached — whether it arrives as bench.sh exit 4 or as a `void`/`suspect` row.
# Exit, in the repo-wide precedence 3 > 4 > 1 > 0: 3 Gate-3 crash/hang · 4 Gate-3 numbers not
# citable · 1 any other gate failure · 0 all gates pass. A gate-1/2 failure never MASKS a
# non-citable Gate 3 — the codes latch upward, they do not overwrite.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ADAPTER="$REPO_ROOT/backends/vllm/adapter.sh"

# Charter rule 4: python via uv when available; citability.py is stdlib-only so python3 is a
# correct fallback.
ahl_py() {
  if [ -n "${AHL_PYTHON:-}" ]; then
    # shellcheck disable=SC2086
    $AHL_PYTHON "$@"
  elif command -v uv >/dev/null 2>&1; then
    uv run --project "$REPO_ROOT" --quiet python "$@"
  else
    python3 "$@"
  fi
}

RUNBOOK="${1:?usage: suite.sh <runbook.sh>}"
[ -f "$RUNBOOK" ] || { echo "not found: $RUNBOOK" >&2; exit 1; }

if [ "${FULL:-0}" = 1 ]; then unset LIMIT; else export LIMIT="${LIMIT:-100}"; fi
export MAX_SECONDS="${MAX_SECONDS:-180}"
# The coder shape (4096/1024) needs FAR longer per stage than chat: GuideLLM's
# output_tokens_per_second.successful.mean averages ONLY completed requests, so a stage that ends
# with most requests still in flight reports an average over a handful of lucky completions — which
# goes non-monotonic while still looking like data (AGENTS.md "MAX_SECONDS=180 is NOT universal").
# Measured 20260818 on Qwen3.8-27B at 180s: coder drained 3/9/12/10/2 successful across c1..c32 and
# produced c8 70.88 > c16 68.88 with c32 256.19 from TWO requests. Chat at the same setting was fine
# (12/46/72/113/136). Rule of thumb: >=20 successful per level.
export MAX_SECONDS_CODER="${MAX_SECONDS_CODER:-600}"
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

LIMLBL="${LIMIT:+limit=$LIMIT}"; LIMLBL="${LIMLBL:-FULL}"
log "=== STANDARD SUITE: $(realpath --relative-to="$REPO_ROOT" "$RUNBOOK") (cfg $CFG; eval $LIMLBL) ==="
ensure_up || { echo "serve failed; see .ahl_suite_serve.log" >&2; exit 1; }

# Reasoning models emit <think> CoT that truncates/derails GENERATIVE eval (35B gsm8k 40->90 with
# thinking off). Such models get their generative quality measured on a SECOND, thinking-OFF serve
# (chat endpoint, enable_thinking=false); the loglikelihood reference (mmlu) is thinking-agnostic and
# stays on this deployed (thinking-ON) serve. Non-reasoning models run everything on the one serve.
# Match only an ACTIVE flag, not a comment mentioning it (grep w/o anchor caught a baseline.sh
# comment "no --reasoning-parser ..." and misfired the reasoning branch on a non-reasoning model).
REASONING=0; grep -qE '^[[:space:]]*--reasoning-parser' "$RUNBOOK" && REASONING=1
# Spec-decode (MTP/ngram/EAGLE) returns NaN prompt_logprobs → loglikelihood `mmlu` 400s ("Out of range
# float values are not JSON compliant"). Spec-decode is greedy-LOSSLESS, so the GENERATIVE tasks
# (gsm8k, mmlu_pro) suffice and match the non-spec scores. Skip loglikelihood mmlu when spec-decode is on.
SPEC=0; grep -qE '^[[:space:]]*--speculative-config' "$RUNBOOK" && SPEC=1

# Gate 1 — functional (deployed thinking-ON serve)
smoke=PASS; "$SCRIPT_DIR/smoke.sh" "$RUNBOOK" || smoke=FAIL; log "Gate 1 smoke: $smoke"

# Gate 2 — quality on the thinking-ON serve
gen=ok; res=ok
if [ "$REASONING" = 1 ] && [ "$SPEC" = 1 ]; then
  # BOTH reasoning AND spec-decode. These two branches used to be mutually exclusive with
  # reasoning first, so this combination silently took the reasoning path and ran loglikelihood
  # mmlu anyway — which spec-decode cannot serve (NaN prompt_logprobs -> HTTP 400 per request).
  # There is no thinking-ON quality task available for this combination: mmlu is the only
  # loglikelihood task here and spec-decode rules it out. Gate 2 is therefore entirely the
  # generative gsm8k + mmlu_pro run on the thinking-OFF serve below.
  log "Gate 2: reasoning + spec-decode -> loglikelihood mmlu SKIPPED (spec-decode NaN prompt_logprobs); Gate 2 = generative gsm8k+mmlu_pro on the think-off serve below"
elif [ "$REASONING" = 1 ]; then
  ensure_up && TASKS=mmlu "$SCRIPT_DIR/eval.sh" "$RUNBOOK" general || gen=error
  log "Gate 2 mmlu (loglikelihood, think-on): $gen   [generative gsm8k/mmlu_pro -> think-off pass below]"
elif [ "$SPEC" = 1 ]; then
  # spec-decode: generative-only (gsm8k for general, skip loglikelihood mmlu) + mmlu_pro (generative).
  ensure_up && TASKS=gsm8k "$SCRIPT_DIR/eval.sh" "$RUNBOOK" general   || gen=error; log "Gate 2 general [gsm8k only, spec-decode skips loglikelihood mmlu]: $gen"
  ensure_up &&              "$SCRIPT_DIR/eval.sh" "$RUNBOOK" resistant || res=error; log "Gate 2 resistant: $res"
else
  ensure_up && "$SCRIPT_DIR/eval.sh" "$RUNBOOK" general   || gen=error; log "Gate 2 general: $gen"
  ensure_up && "$SCRIPT_DIR/eval.sh" "$RUNBOOK" resistant || res=error; log "Gate 2 resistant: $res"
fi

# Gate 3 — throughput, full curve, both shapes (deployed config; one bench.sh call per shape)
#
# bench.sh exit codes are DISTINCT and must stay distinct here (docs/validity-contract.md §5):
#   0  ok
#   3  crash/hang — the box broke; bench.sh saved the engine log and tore the container down
#   4  validity failure — the run completed and the row WAS written, but the numbers are not
#      citable (too few completed requests, over the roofline, ...). This is the failure mode that
#      used to be invisible: a plausible number with `status=measured`. It is a Gate-3 FAILURE and
#      is reported as such — never folded into "crash" and never reported as a pass.
# `ensure_up` failing is its own case (nothing was measured at all).
bench=ok; BENCH_DETAIL=""
BENCH_SINCE="$(date -u +%Y%m%d-%H%M%S)"   # rows are run_id=<YYYYmmdd-HHMMSS>-<shape>; used to
                                          # report THIS session's rows, not a stale row for the cfg
_rank(){ case "$1" in ok) echo 0 ;; error|serve_fail) echo 1 ;; invalid) echo 2 ;; crash) echo 3 ;; *) echo 1 ;; esac; }
# Per-shape stage time — one bench.sh call per shape so coder gets its own (longer) budget.
for _shape in $SHAPES; do
  case "$_shape" in
    coder) _ms="$MAX_SECONDS_CODER" ;;
    *)     _ms="$MAX_SECONDS" ;;
  esac
  _rc=0
  if ensure_up; then
    MAX_SECONDS="$_ms" STATUS=measured NOTES="suite full-sweep" \
      "$SCRIPT_DIR/bench.sh" "$RUNBOOK" "$_shape" || _rc=$?
  else
    _rc=70
  fi
  case "$_rc" in
    0)  _v=ok ;;
    3)  _v=crash ;;
    4)  _v=invalid ;;
    70) _v=serve_fail ;;
    *)  _v=error ;;
  esac
  [ "$_v" = invalid ] && log "!! Gate 3 [$_shape]: MEASUREMENT INVALID (bench.sh exit 4) — row written, NOT citable"
  BENCH_DETAIL="${BENCH_DETAIL:+$BENCH_DETAIL }$_shape=$_v"
  [ "$(_rank "$_v")" -gt "$(_rank "$bench")" ] && bench="$_v"
  log "Gate 3 throughput [$_shape @ ${_ms}s/level]: $_v"
done
log "Gate 3 throughput ($SHAPES): $bench [$BENCH_DETAIL]"
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
ahl_py - "$OUT_DIR" "$CFG" "$REPORT" "$DATE" "$smoke" "$gen" "$res" "$bench" "${LIMIT:-FULL}" \
        "$(realpath --relative-to="$REPO_ROOT" "$RUNBOOK")" "$BENCH_DETAIL" "$BENCH_SINCE" \
        "$SCRIPT_DIR" <<'PY'
import sys, csv, os
out_dir, cfg, report, date, smoke, gen, res, bench, lim, rb, bench_detail, since, scripts_dir = sys.argv[1:14]
sys.path.insert(0, scripts_dir)   # this heredoc runs as `python -`, so scripts/ must be added
# Row citability — docs/validity-contract.md §3/§5/§6. ONE implementation, in
# scripts/citability.py, shared with promote.sh / validate.sh / run_experiment*.sh. The copy that
# used to live here had all three of the family's defects: it tested level-TAGGED tokens against a
# bare {'no_data','over_roofline'} set (so no fatal row ever graded `void`), it dropped `na`
# alongside `ok` (so an unevaluable row read as citable), and `crash` reached `valid` whenever the
# status column had been left alone. suite.sh judges rows ROW-WIDE (level=None): it is a
# characterization report over the full 1..32 sweep, not a claim about one level.
from citability import classify_row, VALID
def classify(r):
    return classify_row(r)
def rows(p):
    try: return list(csv.DictReader(open(p), delimiter='\t'))
    except FileNotFoundError: return []
# Throughput rows for this cfg. Prefer rows written by THIS suite run (run_id >= since); a stale row
# from an earlier session must not be presented as this run's Gate-3 evidence.
tps, stale = {}, {}
for r in rows(os.path.join(out_dir,'results.tsv')):
    if r.get('config_hash')!=cfg: continue
    (tps if (r.get('run_id','') >= since) else stale)[r.get('shape','?')]=r
for shape,r in stale.items():
    tps.setdefault(shape, dict(r, _stale='1'))
# latest accuracy row per (suite, tasks, think) for this cfg — keep think-on/off rows distinct
acc={}
for r in rows(os.path.join(out_dir,'accuracy.tsv')):
    if r.get('config_hash')==cfg:
        acc[(r.get('suite','?'), r.get('tasks',''), r.get('think','on'))]=r

bad_rows = {s: classify(r) for s,r in tps.items() if classify(r)!=VALID}
gate3_pass = (bench=='ok') and not bad_rows
gate1_pass = (smoke=='PASS')
gate2_pass = (gen=='ok' and res=='ok')
verdict = 'PASS' if (gate1_pass and gate2_pass and gate3_pass) else 'FAIL'
why=[]
if not gate1_pass: why.append('Gate 1 smoke')
if not gate2_pass: why.append(f'Gate 2 quality (general={gen}, resistant={res})')
if not gate3_pass:
    detail = bench if bench!='ok' else 'row validity'
    if bad_rows: detail += ' — ' + ', '.join(f'{s}:{v}' for s,v in sorted(bad_rows.items()))
    why.append(f'Gate 3 throughput ({detail})')

L=[]
L.append(f"# Standard suite — {rb}")
L.append(f"- date: {date}    config_hash: {cfg}    eval cap: {lim}")
L.append(f"- **SUITE VERDICT: {verdict}**" + (f" — failed: {'; '.join(why)}" if why else ""))
L.append(f"- **Gate 1 functional (smoke): {smoke}**")
L.append(f"- **Gate 2 quality:** general={gen}, resistant={res}")
for key,r in sorted(acc.items()):
    L.append(f"    - {r.get('suite','?')} [{r.get('tasks','')}] limit={r.get('limit','')} think={r.get('think','on')}: `{r.get('scores','')}`")
L.append(f"- **Gate 3 throughput: {'PASS' if gate3_pass else 'FAIL'}** (bench {bench}; {bench_detail or 'na'}) — full sweep, tok/s")
if tps:
    L.append("")
    L.append("| shape | c1 | c4 | c8 | c16 | c32 | status | validity | req_counts |")
    L.append("|---|---|---|---|---|---|---|---|---|")
    for shape,r in sorted(tps.items()):
        v = classify(r)
        mark = '' if v==VALID else ' ⚠'
        label = shape + mark + (' _(stale — not from this run)_' if r.get('_stale') else '')
        L.append(f"| {label} | {r.get('tps_c1','')} | {r.get('tps_c4','')} | {r.get('tps_c8','')} | "
                 f"{r.get('tps_c16','')} | {r.get('tps_c32','')} | {r.get('status','na')} | "
                 f"{r.get('validity','na')} | {r.get('req_counts','na')} |")
if bad_rows:
    L.append("")
    L.append("**Gate 3 FAILURE** (docs/validity-contract.md): the row(s) above marked ⚠ are `void` (not data), "
             "`suspect` (not citable) or `crash` (engine wedge). These numbers must NOT be quoted, compared, "
             "or used to promote — re-bench with a per-level stage budget that drains enough requests "
             '(AGENTS.md: "MAX_SECONDS=180 is NOT universal"; want >=20 successful per level).')
L.append("")
L.append("Compare quality to the model card's recovery reference; throughput objective = median c16 (chat).")
open(report,'w').write("\n".join(L)+"\n")
print(report)
PY
log "=== SUITE DONE — report: $(realpath --relative-to="$REPO_ROOT" "$REPORT") ==="
cat "$REPORT" >&2

# ── Exit code — the repo-wide precedence, LATCHED (docs/validity-contract.md §5) ──
#   3 (crash: the box broke) > 4 (the row is written but not citable) > 1 (a gate failed) > 0
# This used to protect only rc 3: `[ "$rc_suite" = 3 ] || rc_suite=1` DOWNGRADED a Gate-3 exit 4
# to 1 whenever any other gate also failed, so "the throughput numbers are not data" was reported
# to the caller as an ordinary gate failure — the quieter, more corrosive signal lost to the
# louder one. `latch` can only ever move the code UP the precedence, so no later branch can undo
# an earlier verdict, whatever order the branches run in.
_prec(){ case "$1" in 3) echo 3 ;; 4) echo 2 ;; 0) echo 0 ;; *) echo 1 ;; esac; }
rc_suite=0
latch(){ [ "$(_prec "$1")" -gt "$(_prec "$rc_suite")" ] && rc_suite="$1"; return 0; }

case "$bench" in
  crash)   latch 3 ;;
  invalid) latch 4 ;;
esac
if [ "$smoke" != PASS ] || [ "$gen" != ok ] || [ "$res" != ok ] || [ "$bench" = error ] || [ "$bench" = serve_fail ]; then
  latch 1
fi
# Backstop: the report is the artifact humans read, so a FAIL verdict there must never leave a 0
# exit behind. It only fires when nothing else latched — a verdict already on the ladder is more
# specific than "the report says FAIL", and this must never PROMOTE a 1 into a 4.
if ! grep -q '^- \*\*SUITE VERDICT: PASS\*\*' "$REPORT"; then
  [ "$rc_suite" = 0 ] && latch 4
fi
exit "$rc_suite"
