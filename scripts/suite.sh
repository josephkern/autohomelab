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
# The report carries an explicit SUITE VERDICT and, for Gates 2 AND 3, the rows' own
# `status`/`validity` (docs/validity-contract.md). A measurement-validity failure is a FAIL --
# never a pass with a plausible number attached -- whether it arrives as an exit 4 or as a
# `void`/`suspect` row.
#
# GATE 2 IS JUDGED THE SAME WAY GATE 3 IS (contract A9). It used to be judged on eval.sh's exit
# code alone while eval.sh exited 0 whatever lm-eval returned, so a literal `nan` score, a score
# computed over 37 of 14,042 requested samples, and a missing results json each reported PASS.
# eval.sh now scores its own bundle and exits 4 when the result is not citable; this script
# latches that, and additionally re-reads the accuracy.tsv rows it wrote so the report and the
# exit code cannot disagree.
#
# Exit, in the repo-wide precedence 3 > 4 > 1 > 0: 3 crash/hang (either gate) . 4 numbers not
# citable (either gate) . 1 any other gate failure . 0 all gates pass. A gate-1 failure never
# MASKS a non-citable Gate 2 or Gate 3 -- the codes latch upward, they do not overwrite.
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
# The report is written unconditionally at the end, including when no gate produced a row,
# so the directory has to exist before then rather than as a side effect of eval.sh/bench.sh.
mkdir -p "$OUT_DIR"
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
#
# eval.sh's exit code is now a VERDICT, not just "did the process die" (docs/validity-contract.md
# A9). Gate 2 used to be computed from that exit code alone while eval.sh exited 0 whatever came
# back, so a literal `nan`, a score over 37 of 14,042 requested samples, and a missing results
# json all reported PASS. The codes mirror Gate 3's exactly, so an operator meets ONE concept:
#   0 citable · 3 the harness was killed · 4 the row is written but NOT citable · other = error
# `run_eval` latches the worst verdict seen for its gate half, so a later clean pass can never
# overwrite an earlier failure (the same latching bug the exit ladder had at the bottom of this
# file).
_erank(){ case "$1" in ok) echo 0 ;; error|serve_fail) echo 1 ;; invalid) echo 2 ;; crash) echo 3 ;; *) echo 1 ;; esac; }
_ecode(){ case "$1" in 0) echo ok ;; 3) echo crash ;; 4) echo invalid ;; 70) echo serve_fail ;; *) echo error ;; esac; }
# run_eval <result-var> <label> <eval-suite> [ENV=VALUE ...]
run_eval(){
  local _var="$1" _label="$2" _suite="$3"; shift 3
  local _rc=0 _v
  if ensure_up; then
    env "$@" "$SCRIPT_DIR/eval.sh" "$RUNBOOK" "$_suite" || _rc=$?
  else
    _rc=70
  fi
  _v="$(_ecode "$_rc")"
  [ "$_v" = invalid ] && log "!! Gate 2 [$_label]: QUALITY RESULT NOT CITABLE (eval.sh exit 4) — row written, NOT a pass"
  [ "$(_erank "$_v")" -gt "$(_erank "${!_var}")" ] && printf -v "$_var" '%s' "$_v"
  log "Gate 2 $_label: ${!_var}"
}

gen=ok; res=ok; GATE2_PLAN=""
EVAL_SINCE="$(date -u +%Y%m%d-%H%M%S)"   # accuracy rows are run_id=<YYYYmmdd-HHMMSS>-eval;
                                         # used to report THIS session's quality rows, not a
                                         # stale row left by an earlier session for the cfg.
if [ "$REASONING" = 1 ] && [ "$SPEC" = 1 ]; then
  # BOTH reasoning AND spec-decode. These two branches used to be mutually exclusive with
  # reasoning first, so this combination silently took the reasoning path and ran loglikelihood
  # mmlu anyway — which spec-decode cannot serve (NaN prompt_logprobs -> HTTP 400 per request).
  # There is no thinking-ON quality task available for this combination: mmlu is the only
  # loglikelihood task here and spec-decode rules it out. Gate 2 is therefore entirely the
  # generative gsm8k + mmlu_pro run on the thinking-OFF serve below.
  log "Gate 2: reasoning + spec-decode -> loglikelihood mmlu SKIPPED (spec-decode NaN prompt_logprobs); Gate 2 = generative gsm8k+mmlu_pro on the think-off serve below"
  GATE2_PLAN="reasoning+spec: think-on SKIPPED; think-off gsm8k+mmlu_pro is the whole gate"
elif [ "$REASONING" = 1 ]; then
  run_eval gen "mmlu (loglikelihood, think-on)" general TASKS=mmlu
  log "  [generative gsm8k/mmlu_pro -> think-off pass below]"
  GATE2_PLAN="reasoning: think-on mmlu + think-off gsm8k/mmlu_pro"
elif [ "$SPEC" = 1 ]; then
  # spec-decode: generative-only (gsm8k for general, skip loglikelihood mmlu) + mmlu_pro (generative).
  run_eval gen "general [gsm8k only, spec-decode skips loglikelihood mmlu]" general TASKS=gsm8k
  run_eval res "resistant" resistant
  GATE2_PLAN="spec-decode: think-on gsm8k + mmlu_pro (loglikelihood mmlu skipped)"
else
  run_eval gen "general" general
  run_eval res "resistant" resistant
  GATE2_PLAN="plain: think-on general + resistant"
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
    # This is the pass that catches a think-off serve generating ZERO tokens: NemotronH renders a
    # pre-closed `<think></think>` from `enable_thinking=false` and scores gsm8k 0.0 (AGENTS.md;
    # fixed per-model with AHL_THINK_OFF_KWARGS). eval.sh's predicate now flags an exactly-0.0
    # score as `zero_score` -> status suspect -> exit 4, so that no longer reads as a PASS.
    run_eval gen "generative gsm8k (think-off)"    general   THINK=off TASKS=gsm8k
    run_eval res "generative mmlu_pro (think-off)" resistant THINK=off
    "$SCRIPT_DIR/serve.sh" down >/dev/null 2>&1 || true
    log "Gate 2 generative (think-off): gsm8k+mmlu_pro done"
  else
    [ "$(_erank serve_fail)" -gt "$(_erank "$res")" ] && res=serve_fail
    log "thinking-OFF serve failed (see .ahl_suite_serve.log)"
  fi
fi

# ── Summary report ────────────────────────────────────────────────────────────
ahl_py - "$OUT_DIR" "$CFG" "$REPORT" "$DATE" "$smoke" "$gen" "$res" "$bench" "${LIMIT:-FULL}" \
        "$(realpath --relative-to="$REPO_ROOT" "$RUNBOOK")" "$BENCH_DETAIL" "$BENCH_SINCE" \
        "$SCRIPT_DIR" "$GATE2_PLAN" "$EVAL_SINCE" <<'PY'
import sys, csv, os
(out_dir, cfg, report, date, smoke, gen, res, bench, lim, rb, bench_detail, since,
 scripts_dir, gate2_plan, eval_since) = sys.argv[1:16]
sys.path.insert(0, scripts_dir)   # this heredoc runs as `python -`, so scripts/ must be added
# Row citability — docs/validity-contract.md §3/§5/§6. ONE implementation, in
# scripts/citability.py, shared with promote.sh / validate.sh / run_experiment*.sh. The copy that
# used to live here had all three of the family's defects: it tested level-TAGGED tokens against a
# bare {'no_data','over_roofline'} set (so no fatal row ever graded `void`), it dropped `na`
# alongside `ok` (so an unevaluable row read as citable), and `crash` reached `valid` whenever the
# status column had been left alone. suite.sh judges rows ROW-WIDE (level=None): it is a
# characterization report over the full 1..32 sweep, not a claim about one level.
from citability import classify_row, VALID
# Gate 2's acceptance predicate — the SAME module eval.sh scored the row with, so this report can
# never disagree with the exit code it is summarizing (docs/validity-contract.md A9).
from eval_validity import citable as acc_citable
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
# Latest accuracy row per (suite, tasks, think, conc) for this cfg. `think` keeps the think-on and
# think-off passes distinct (35B gsm8k=42 think-on vs =90 think-off); `conc` is in the key because
# Gate 2 no longer has to be a single unrecorded point at c16 — two rows differing only in
# concurrency are two different measurements, not a duplicate.
# Rows from THIS run are preferred, exactly as the throughput table does it: a stale accuracy row
# left by an earlier session must not be presented as this run's Gate-2 evidence.
acc, acc_stale = {}, {}
for r in rows(os.path.join(out_dir,'accuracy.tsv')):
    if r.get('config_hash')!=cfg: continue
    key=(r.get('suite','?'), r.get('tasks',''), r.get('think','on'), r.get('conc','na'))
    (acc if (r.get('run_id','') >= eval_since) else acc_stale)[key]=r
for key,r in acc_stale.items():
    acc.setdefault(key, dict(r, _stale='1'))

bad_rows = {s: classify(r) for s,r in tps.items() if classify(r)!=VALID}
gate3_pass = (bench=='ok') and not bad_rows
gate1_pass = (smoke=='PASS')
# Gate 2 is judged the way Gate 3 is: the exit codes AND the rows they wrote. A row whose
# `validity` is anything but `ok` (or whose `status` is void/suspect) is written but not citable,
# and a not-citable quality result is a Gate-2 FAILURE — never a pass with a plausible number
# attached. Legacy rows predating the schema carry no `validity` cell at all; those read as `na`,
# which A5 says is never `ok`, so they are reported rather than silently believed.
bad_acc = {k: (r.get('validity','na'), r.get('status','na'))
           for k,r in acc.items()
           if not r.get('_stale') and not acc_citable(r.get('validity',''), r.get('status',''))}
gate2_pass = (gen=='ok' and res=='ok') and not bad_acc
verdict = 'PASS' if (gate1_pass and gate2_pass and gate3_pass) else 'FAIL'
why=[]
if not gate1_pass: why.append('Gate 1 smoke')
if not gate2_pass:
    d=f'general={gen}, resistant={res}'
    if bad_acc: d += ' — not citable: ' + ', '.join(
        f"{k[0]}[{k[1]}] think={k[2]} c{k[3]}: {v[0]}/{v[1]}" for k,v in sorted(bad_acc.items()))
    why.append(f'Gate 2 quality ({d})')
if not gate3_pass:
    detail = bench if bench!='ok' else 'row validity'
    if bad_rows: detail += ' — ' + ', '.join(f'{s}:{v}' for s,v in sorted(bad_rows.items()))
    why.append(f'Gate 3 throughput ({detail})')

L=[]
L.append(f"# Standard suite — {rb}")
L.append(f"- date: {date}    config_hash: {cfg}    eval cap: {lim}")
L.append(f"- **SUITE VERDICT: {verdict}**" + (f" — failed: {'; '.join(why)}" if why else ""))
L.append(f"- **Gate 1 functional (smoke): {smoke}**")
L.append(f"- **Gate 2 quality: {'PASS' if gate2_pass else 'FAIL'}** (general={gen}, resistant={res})"
         + (f" \u2014 plan: {gate2_plan}" if gate2_plan else ""))
if acc:
    L.append("")
    L.append("| suite | tasks | limit | think | conc | scores | samples eff/req | status | validity |")
    L.append("|---|---|---|---|---|---|---|---|---|")
    for key,r in sorted(acc.items()):
        v = acc_citable(r.get('validity',''), r.get('status',''))
        mark = '' if v else ' \u26a0'
        label = r.get('suite','?') + mark + (' _(stale)_' if r.get('_stale') else '')
        L.append(f"| {label} | {r.get('tasks','')} | {r.get('limit','')} | {r.get('think','on')} | "
                 f"{r.get('conc','na')} | `{r.get('scores','')}` | {r.get('samples','na')} | "
                 f"{r.get('status','na')} | {r.get('validity','na')} |")
if bad_acc:
    L.append("")
    L.append("**Gate 2 FAILURE** (docs/validity-contract.md A9): the quality row(s) above marked "
             "\u26a0 are not a measurement \u2014 a non-finite score, a score computed over fewer "
             "samples than were requested, no score at all, or a score of exactly 0.0 (check the "
             "serve emitted tokens: AGENTS.md records NemotronH generating none under "
             "`enable_thinking=false`). These numbers must NOT be quoted, compared, or used to "
             "promote. `samples` is `effective/requested` from the bundle's own `n-samples`.")
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

# Gate 2 rides the SAME ladder as Gate 3 (docs/validity-contract.md A9). "The quality score is
# not a measurement" is exactly as corrosive as "the throughput number is not a measurement", and
# it used to be unreportable: eval.sh always exited 0. A Gate-2 `invalid` now latches 4, so it can
# never be flattened into the generic 1 by a smoke failure that happens to land beside it.
for _g2 in "$gen" "$res" "$bench"; do
  case "$_g2" in
    crash)   latch 3 ;;
    invalid) latch 4 ;;
  esac
done
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
