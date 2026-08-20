#!/usr/bin/env bash
# eval_validity_selftest.sh — acceptance suite for the GATE 2 validity layer (contract A9).
#
# Runs entirely on synthetic lm-eval bundles. No docker, no serve, no lm-eval, no GPU: the box is
# a shared single-GPU lab. The lm-eval harness is replaced through eval.sh's `AHL_LM_EVAL` seam
# and suite.sh's collaborators are replaced by tracing stubs, so what is tested is the SHIPPED
# code path, not a re-implementation of it (contract A8: "wiring tests EXECUTE the code path
# against a fixture bundle; a substring grep is not a test").
#
# Sections:
#   A  predicate   — the rules, against synthetic bundles including the three §0-defect-(c) shapes
#   B  eval.sh     — end to end: exit code AND the accuracy.tsv row it writes
#   C  suite.sh    — EXECUTION TRACES proving every Gate-2 branch is reachable for all four
#                    runbook variants (neither / reasoning / spec / BOTH). The repo has already
#                    shipped a guard whose condition was right and whose branch was unreachable;
#                    testing the condition is not testing the branch.
#   D  migration   — accuracy.tsv 12 -> 16 columns, legacy cells byte-identical, idempotent
#
#   scripts/eval_validity_selftest.sh              # run everything
#   AHL_SHOW_TRACE=1 scripts/eval_validity_selftest.sh   # ... and print the raw suite.sh traces
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PY="${AHL_PYTHON:-python3}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ahl-gate2-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }
chk(){ # chk <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1 -- expected [$2] got [$3]"; fi; }
chk_has(){ # chk_has <label> <needle> <haystack>
  case "$3" in *"$2"*) ok "$1" ;; *) no "$1 -- [$2] not in [$3]" ;; esac; }

# ── synthetic lm-eval bundle writer ───────────────────────────────────────────
# Emits the real lm-eval 0.4.12 layout: <bundle>/<model>/results_<ts>.json carrying `results`,
# `group_subtasks`, `n-samples` and `config`. Scenarios are named for what they reproduce.
FIXTURE="$WORK/fixture.py"
cat > "$FIXTURE" <<'PYEOF'
"""Synthetic lm-eval result bundles, in the exact on-disk shape lm-eval 0.4.12 writes."""
import json, os, sys

NAN = float("nan")

def leaf(eff, orig):
    return {"effective": eff, "original": orig}

def write(path, doc):
    d = os.path.join(path, "stub-model")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "results_2026-08-19T00-00-00.000000.json"), "w") as f:
        json.dump(doc, f)          # json.dump writes a bare NaN literal, exactly as lm-eval does

def base(limit=100.0, conc=16):
    return {"config": {"limit": limit, "model": "local-completions",
                       "model_args": {"num_concurrent": conc, "model": "stub"}},
            "group_subtasks": {}, "results": {}, "n-samples": {}}

# mmlu is 57 leaf subtasks; `--limit 100` therefore legitimately requests 5,700 of 14,042 docs.
MMLU_LEAVES = ["mmlu_t%02d" % i for i in range(57)]
MMLU_ORIG = [100 + (i % 5) * 30 for i in range(57)]   # varied, like the real corpus

def with_mmlu(doc, acc, effective_total=None, limit=100.0):
    doc["group_subtasks"]["mmlu"] = ["mmlu_stem"]
    doc["group_subtasks"]["mmlu_stem"] = MMLU_LEAVES
    req = [min(int(limit), o) if limit else o for o in MMLU_ORIG]
    total_req = sum(req)
    eff = list(req) if effective_total is None else None
    if eff is None:                       # spread a shortfall across the leaves, first-come
        eff, left = [], effective_total
        for r in req:
            take = min(r, max(0, left)); eff.append(take); left -= take
    for name, e, o in zip(MMLU_LEAVES, eff, MMLU_ORIG):
        doc["n-samples"][name] = leaf(e, o)
        doc["results"][name] = {"alias": name, "acc,none": 0.5, "acc_stderr,none": 0.01}
    doc["results"]["mmlu"] = {"alias": "mmlu", "name": "mmlu", "sample_len": sum(eff),
                              "acc,none": acc, "acc_stderr,none": 0.005}
    return doc, total_req, sum(eff)

def with_gsm8k(doc, score, effective=100, original=1319, limit=100.0):
    doc["n-samples"]["gsm8k"] = leaf(effective, original)
    doc["results"]["gsm8k"] = {"name": "gsm8k", "alias": "gsm8k", "sample_len": effective,
                               "exact_match,strict-match": score,
                               "exact_match_stderr,strict-match": 0.04,
                               "exact_match,flexible-extract": score}
    return doc

def main():
    path, scenario = sys.argv[1], sys.argv[2]
    if scenario == "missing":
        # bundle dir exists, no results json in it. Clear any left by an earlier stub run that
        # landed in the same one-second RUN_ID window.
        os.makedirs(path, exist_ok=True)
        for root, _dirs, files in os.walk(path):
            for fn in files:
                if fn.startswith("results_") and fn.endswith(".json"):
                    os.remove(os.path.join(root, fn))
        return
    doc = base()
    if scenario == "healthy":                     # gsm8k + mmlu, complete, finite
        doc = with_gsm8k(doc, 0.95)
        doc, _, _ = with_mmlu(doc, 0.8182)
    elif scenario == "nan":                       # DEFECT (c): loglikelihood mmlu under spec-decode
        doc, _, _ = with_mmlu(doc, NAN)
    elif scenario == "inf":
        doc, _, _ = with_mmlu(doc, float("inf"))
    elif scenario == "short":                     # DEFECT (c): "37 of 14,042"
        doc, _, _ = with_mmlu(doc, 0.4123, effective_total=37)
    elif scenario == "zero":                      # NemotronH think-off: zero tokens generated
        doc = with_gsm8k(doc, 0.0)
    elif scenario == "thinkoff_ok":               # the LEGITIMATE think-off path (low but real)
        doc = with_gsm8k(doc, 0.62)
    elif scenario == "nosamples":                 # bundle with no n-samples at all -> fail closed
        doc = with_gsm8k(doc, 0.9); doc["n-samples"] = {}
    elif scenario == "notask":                    # requested task absent from results
        doc = with_gsm8k(doc, 0.9)
        del doc["results"]["gsm8k"]
    elif scenario == "full_ok":                   # FULL run, no limit
        doc["config"]["limit"] = None
        doc = with_gsm8k(doc, 0.9598, effective=1319, original=1319, limit=None)
    elif scenario == "onedoc_short":              # 1 doc missing out of 12,032 -> inside the 1%
        doc["config"]["limit"] = None
        doc = with_gsm8k(doc, 0.9, effective=1318, original=1319, limit=None)
    elif scenario == "conc1":
        doc["config"]["model_args"]["num_concurrent"] = 1
        doc = with_gsm8k(doc, 0.93)
    else:
        raise SystemExit("unknown scenario %s" % scenario)
    write(path, doc)

main()
PYEOF

assess(){ # assess <bundle> <tasks> [limit]  -> prints the tsv line; returns the rc
  "$PY" "$SCRIPT_DIR/eval_validity.py" assess --bundle "$1" --tasks "$2" ${3:+--limit "$3"} 2>/dev/null
}

echo "=== A. the predicate (docs/validity-contract.md A9) ==========================="
B="$WORK/b"; mkdir -p "$B"

for sc in healthy nan inf short zero thinkoff_ok nosamples notask missing full_ok onedoc_short conc1; do
  "$PY" "$FIXTURE" "$B/$sc" "$sc"
done

L="$(assess "$B/healthy" gsm8k,mmlu)"; RC=$?
chk "healthy: exit 0"            0    "$RC"
chk "healthy: validity ok"       ok   "$(echo "$L" | cut -f3)"
chk "healthy: status measured"   measured "$(echo "$L" | cut -f4)"
chk "healthy: conc read from the bundle" 16 "$(echo "$L" | cut -f5)"
chk_has "healthy: mmlu group expands to 5700 requested, not 100" "mmlu=5700/5700" "$(echo "$L" | cut -f2)"

L="$(assess "$B/nan" mmlu)"; RC=$?
chk "NaN: exit 4"                4    "$RC"
chk "NaN: scores keep the evidence" "mmlu=nan" "$(echo "$L" | cut -f1)"
chk "NaN: validity"      "nonfinite@mmlu" "$(echo "$L" | cut -f3)"
chk "NaN: status void"           void "$(echo "$L" | cut -f4)"

L="$(assess "$B/inf" mmlu)"; RC=$?
chk "Inf: exit 4"                4    "$RC"
chk "Inf: validity"      "nonfinite@mmlu" "$(echo "$L" | cut -f3)"

L="$(assess "$B/short" mmlu)"; RC=$?
chk "37-of-14042: exit 4"        4    "$RC"
chk "37-of-14042: validity" "short_sample@mmlu" "$(echo "$L" | cut -f3)"
chk "37-of-14042: status void"   void "$(echo "$L" | cut -f4)"
chk_has "37-of-14042: both counts recorded" "mmlu=37/5700" "$(echo "$L" | cut -f2)"

L="$(assess "$B/missing" mmlu)"; RC=$?
chk "no results json: exit 4"    4    "$RC"
chk "no results json: validity"  no_score "$(echo "$L" | cut -f3)"
chk "no results json: status void" void "$(echo "$L" | cut -f4)"

L="$(assess "$B/notask" gsm8k)"; RC=$?
chk "task absent: exit 4"        4    "$RC"
chk "task absent: validity" "no_score@gsm8k" "$(echo "$L" | cut -f3)"

L="$(assess "$B/zero" gsm8k)"; RC=$?
chk "zero-token generation: exit 4" 4 "$RC"
chk "zero-token generation: validity" "zero_score@gsm8k" "$(echo "$L" | cut -f3)"
chk "zero-token generation: status suspect" suspect "$(echo "$L" | cut -f4)"

L="$(assess "$B/thinkoff_ok" gsm8k)"; RC=$?
chk "LEGITIMATE think-off (gsm8k 62): exit 0" 0 "$RC"
chk "LEGITIMATE think-off: validity ok" ok "$(echo "$L" | cut -f3)"

L="$(assess "$B/nosamples" gsm8k)"; RC=$?
chk "no n-samples: fails CLOSED (exit 4)" 4 "$RC"
chk "no n-samples: validity" "no_samples@gsm8k" "$(echo "$L" | cut -f3)"

L="$(assess "$B/full_ok" gsm8k)"; RC=$?
chk "FULL run (no limit): exit 0" 0 "$RC"
chk_has "FULL run: 1319/1319" "gsm8k=1319/1319" "$(echo "$L" | cut -f2)"

L="$(assess "$B/onedoc_short" gsm8k)"; RC=$?
chk "1 doc of 1319 missing is inside the 1% floor: exit 0" 0 "$RC"
chk_has "1-doc shortfall is still RECORDED" "gsm8k=1318/1319" "$(echo "$L" | cut -f2)"

L="$(assess "$B/conc1" gsm8k)"; RC=$?
chk "conc is read from the bundle, not assumed 16" 1 "$(echo "$L" | cut -f5)"

# The threshold is a knob, and moving it must move the verdict (an unmoveable rule is untested).
L="$(AHL_EVAL_MIN_SAMPLE_FRAC=0.001 assess "$B/short" mmlu)"; RC=$?
chk "AHL_EVAL_MIN_SAMPLE_FRAC actually binds" 0 "$RC"

echo
echo "=== B. eval.sh end to end (stub lm-eval through AHL_LM_EVAL) =================="
# A sandbox repo: eval.sh derives REPO_ROOT from its own path, so symlinking it into a fake tree
# is enough to redirect every write.
SBX="$WORK/sbx"
mkdir -p "$SBX/scripts" "$SBX/results/testfp" "$SBX/runbooks"
echo '{"gpu":{"mem_bw_gbs":273}}' > "$SBX/results/testfp/node_profile.json"
for f in eval.sh eval_validity.py migrate_accuracy_tsv.py; do ln -sf "$SCRIPT_DIR/$f" "$SBX/scripts/$f"; done
cat > "$SBX/runbooks/rb.sh" <<'EOF'
MODEL="acme/Stub-7B"
SERVED_NAME="stub"
EOF

# The stub harness: parses --output_path/--tasks, writes the scenario's bundle, logs the call.
cat > "$SBX/scripts/stub_lm_eval.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
out=""; tasks=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --output_path) out="\$2"; shift 2 ;;
    --tasks) tasks="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
echo "lm_eval tasks=\$tasks scenario=\${AHL_STUB_SCENARIO:-healthy}" >> "\${AHL_TRACE:-/dev/null}"
[ "\${AHL_STUB_SCENARIO:-healthy}" = "harness_signal" ] && exit 137
[ "\${AHL_STUB_SCENARIO:-healthy}" = "harness_err" ] && { "$PY" "$FIXTURE" "\$out" healthy; exit 1; }
"$PY" "$FIXTURE" "\$out" "\${AHL_STUB_SCENARIO:-healthy}"
exit 0
EOF
chmod +x "$SBX/scripts/stub_lm_eval.sh"

run_eval_sh(){ # run_eval_sh <scenario> [extra env...] -> sets RC, ROW
  local sc="$1"; shift
  RC=0
  env AHL_PYTHON="$PY" AHL_LM_EVAL="$SBX/scripts/stub_lm_eval.sh" AHL_STUB_SCENARIO="$sc" \
      LIMIT=100 "$@" "$SBX/scripts/eval.sh" "$SBX/runbooks/rb.sh" general >/dev/null 2>&1 || RC=$?
  ROW="$(tail -1 "$SBX/results/testfp/acme/Stub-7B/accuracy.tsv" 2>/dev/null || echo)"
}

TSV="$SBX/results/testfp/acme/Stub-7B/accuracy.tsv"

run_eval_sh healthy TASKS=gsm8k,mmlu
chk "eval.sh healthy: exit 0" 0 "$RC"
chk "eval.sh healthy: header is 16 columns" 16 "$(head -1 "$TSV" | awk -F'\t' '{print NF}')"
chk "eval.sh healthy: row is 16 columns" 16 "$(echo "$ROW" | awk -F'\t' '{print NF}')"
chk "eval.sh healthy: validity ok" ok "$(echo "$ROW" | cut -f15)"
chk "eval.sh healthy: status measured" measured "$(echo "$ROW" | cut -f16)"
chk "eval.sh healthy: conc recorded" 16 "$(echo "$ROW" | cut -f13)"

run_eval_sh nan TASKS=mmlu
chk "eval.sh NaN: exit 4 (was 0 = PASS)" 4 "$RC"
chk "eval.sh NaN: the row IS written" "mmlu=nan" "$(echo "$ROW" | cut -f10)"
chk "eval.sh NaN: validity" "nonfinite@mmlu" "$(echo "$ROW" | cut -f15)"
chk "eval.sh NaN: status void" void "$(echo "$ROW" | cut -f16)"

run_eval_sh short TASKS=mmlu
chk "eval.sh 37-of-14042: exit 4 (was 0 = PASS)" 4 "$RC"
chk "eval.sh 37-of-14042: samples recorded" "mmlu=37/5700" "$(echo "$ROW" | cut -f14)"
chk "eval.sh 37-of-14042: validity" "short_sample@mmlu" "$(echo "$ROW" | cut -f15)"

N_BEFORE="$(wc -l < "$TSV")"
run_eval_sh missing TASKS=mmlu
chk "eval.sh no results json: exit 4 (was 0 = PASS)" 4 "$RC"
chk "eval.sh no results json: a row is STILL written" "$((N_BEFORE+1))" "$(wc -l < "$TSV")"
chk "eval.sh no results json: scores na" na "$(echo "$ROW" | cut -f10)"
chk "eval.sh no results json: validity" no_score "$(echo "$ROW" | cut -f15)"

run_eval_sh zero TASKS=gsm8k
chk "eval.sh zero-token score: exit 4" 4 "$RC"
chk "eval.sh zero-token score: status suspect" suspect "$(echo "$ROW" | cut -f16)"

run_eval_sh thinkoff_ok TASKS=gsm8k THINK=off
chk "eval.sh legitimate think-off: exit 0" 0 "$RC"
chk "eval.sh legitimate think-off: think column" off "$(echo "$ROW" | cut -f12)"

run_eval_sh harness_signal TASKS=gsm8k
chk "eval.sh harness killed by a signal: exit 3" 3 "$RC"

run_eval_sh harness_err TASKS=gsm8k
chk "eval.sh lm-eval rc!=0 but the numbers are structurally fine: exit 1" 1 "$RC"

run_eval_sh conc1 TASKS=gsm8k CONC=1
chk "eval.sh CONC=1 is recorded (Gate 2 is no longer a fixed unrecorded c16)" 1 "$(echo "$ROW" | cut -f13)"

echo
echo "=== C. suite.sh Gate-2 branch reachability, by EXECUTION TRACE ================"
# Four runbook variants. For each, suite.sh is run in a sandbox whose smoke/eval/bench/serve are
# tracing stubs, and the trace is compared against the invocations that branch MUST make. This is
# the check the repo lacked when reasoning+spec-decode fell into an unreachable branch: the guard
# condition was right, the branch was dead, and 56,168 NaN requests ground for 75 minutes.
S2="$WORK/sbx2"
mkdir -p "$S2/scripts" "$S2/results/testfp" "$S2/runbooks" "$S2/backends/vllm"
echo '{"gpu":{"mem_bw_gbs":273}}' > "$S2/results/testfp/node_profile.json"
for f in suite.sh citability.py eval_validity.py; do ln -sf "$SCRIPT_DIR/$f" "$S2/scripts/$f"; done
ln -sf "$SCRIPT_DIR/lib" "$S2/scripts/lib"

cat > "$S2/scripts/smoke.sh" <<'EOF'
#!/usr/bin/env bash
echo "smoke" >> "${AHL_TRACE:?}"; exit 0
EOF
cat > "$S2/scripts/serve.sh" <<'EOF'
#!/usr/bin/env bash
echo "serve think_off=${AHL_THINK_OFF:-0} arg=$1" >> "${AHL_TRACE:?}"; exit 0
EOF
cat > "$S2/scripts/bench.sh" <<'EOF'
#!/usr/bin/env bash
echo "bench shape=$2" >> "${AHL_TRACE:?}"; exit 0
EOF
# The eval stub records EXACTLY the axes the branches differ on, and nothing else.
cat > "$S2/scripts/eval.sh" <<'EOF'
#!/usr/bin/env bash
echo "eval suite=$2 tasks=${TASKS:-<default>} think=${THINK:-on}" >> "${AHL_TRACE:?}"
exit "${AHL_EVAL_RC:-0}"
EOF
cat > "$S2/backends/vllm/adapter.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in health) exit 0 ;; info) echo "stub-backend" ;; esac
EOF
chmod +x "$S2/scripts/smoke.sh" "$S2/scripts/serve.sh" "$S2/scripts/bench.sh" \
         "$S2/scripts/eval.sh" "$S2/backends/vllm/adapter.sh"

mk_runbook(){ # mk_runbook <name> <reasoning 0|1> <spec 0|1>
  local f="$S2/runbooks/$1.sh"
  {
    echo 'MODEL="acme/Stub-7B"'
    echo 'SERVED_NAME="stub"'
    echo 'VLLM_FLAGS=('
    echo '  --served-model-name stub'
    # a COMMENT mentioning the flag must not fire the branch (a real past misfire)
    echo '  # no --reasoning-parser here, and no --speculative-config either'
    [ "$2" = 1 ] && echo '  --reasoning-parser qwen3'
    [ "$3" = 1 ] && echo '  --speculative-config {"method":"mtp"}'
    echo ')'
  } > "$f"
  echo "$f"
}

trace_suite(){ # trace_suite <name> <reasoning> <spec> -> TRACE holds the eval lines; SRC the rc
  local rb; rb="$(mk_runbook "$1" "$2" "$3")"
  local t="$WORK/trace-$1.log"; : > "$t"
  SRC=0
  env AHL_PYTHON="$PY" AHL_TRACE="$t" LIMIT=100 SHAPES=chat LEVELS_SET=1 \
      "$S2/scripts/suite.sh" "$rb" >/dev/null 2>&1 || SRC=$?
  TRACE="$(grep '^eval ' "$t" || true)"
  FULLTRACE="$(cat "$t")"
  if [ "${AHL_SHOW_TRACE:-0}" = 1 ]; then
    printf '\n  --- EXECUTION TRACE: variant %s (reasoning=%s spec=%s) -> suite.sh rc=%s ---\n' \
      "$1" "$2" "$3" "$SRC"
    sed 's/^/      /' "$t"
  fi
}

expect_trace(){ # expect_trace <label> <expected multiline> <actual>
  if [ "$2" = "$3" ]; then ok "$1"
  else no "$1"; printf '       expected:\n%s\n       actual:\n%s\n' \
       "$(echo "$2" | sed 's/^/         /')" "$(echo "$3" | sed 's/^/         /')"; fi; }

# --- variant 1: neither reasoning nor spec-decode ---
trace_suite plain 0 0
expect_trace "variant NEITHER: think-on general + resistant, no think-off pass" \
"eval suite=general tasks=<default> think=on
eval suite=resistant tasks=<default> think=on" "$TRACE"
chk "variant NEITHER: no think-off serve" "" "$(echo "$FULLTRACE" | grep 'think_off=1' || true)"

# --- variant 2: reasoning only ---
trace_suite reasoning 1 0
expect_trace "variant REASONING: think-on loglikelihood mmlu + think-off gsm8k/mmlu_pro" \
"eval suite=general tasks=mmlu think=on
eval suite=general tasks=gsm8k think=off
eval suite=resistant tasks=<default> think=off" "$TRACE"
chk_has "variant REASONING: a think-off serve happened" "serve think_off=1" "$FULLTRACE"

# --- variant 3: spec-decode only ---
trace_suite spec 0 1
expect_trace "variant SPEC: gsm8k (generative) + mmlu_pro, loglikelihood mmlu SKIPPED" \
"eval suite=general tasks=gsm8k think=on
eval suite=resistant tasks=<default> think=on" "$TRACE"
chk "variant SPEC: loglikelihood mmlu never ran" "" "$(echo "$TRACE" | grep 'tasks=mmlu ' || true)"

# --- variant 4: BOTH — the branch that used to be unreachable ---
trace_suite both 1 1
expect_trace "variant BOTH (reasoning x spec): NO think-on eval at all; the whole gate is think-off" \
"eval suite=general tasks=gsm8k think=off
eval suite=resistant tasks=<default> think=off" "$TRACE"
chk "variant BOTH: loglikelihood mmlu never ran (the 56,168-NaN run)" "" \
    "$(echo "$TRACE" | grep 'tasks=mmlu think=on' || true)"
chk_has "variant BOTH: the think-off serve is reached" "serve think_off=1" "$FULLTRACE"

# --- the branch guards must be reachable in BOTH directions: a Gate-2 failure must propagate ---
mkrb(){ mk_runbook "$1" "$2" "$3" >/dev/null; echo "$S2/runbooks/$1.sh"; }
for v in "plain 0 0" "reasoning 1 0" "spec 0 1" "both 1 1"; do
  set -- $v
  rb="$(mkrb "$1" "$2" "$3")"; t="$WORK/trace-fail-$1.log"; : > "$t"
  rc=0
  env AHL_PYTHON="$PY" AHL_TRACE="$t" AHL_EVAL_RC=4 LIMIT=100 SHAPES=chat LEVELS_SET=1 \
      "$S2/scripts/suite.sh" "$rb" >/dev/null 2>&1 || rc=$?
  chk "variant ${1}: an eval.sh exit 4 makes suite.sh exit 4 (not 0, not 1)" 4 "$rc"
  # every variant writes its own SUITE-<cfg>.md into the same directory, so address it by cfg
  rep="$S2/results/testfp/acme/Stub-7B/SUITE-$(sha256sum "$rb" | cut -c1-8).md"
  chk_has "variant ${1}: the report says Gate 2 FAIL" "Gate 2 quality: FAIL" "$(cat "$rep")"
done
# The `both` variant runs NO think-on eval, so its only evals are the think-off pair: if that pass
# were unreachable, AHL_EVAL_RC=4 could not reach the exit code at all. The assertion above is
# therefore also a reachability proof for the think-off branch under reasoning x spec-decode.

echo
echo "=== D. accuracy.tsv migration (12 -> 16 columns) =============================="
MIG="$WORK/mig"; mkdir -p "$MIG/results/testfp/acme/Stub-7B"
MTSV="$MIG/results/testfp/acme/Stub-7B/accuracy.tsv"
BUND="results/testfp/acme/Stub-7B/data/20260101-000000-eval"
mkdir -p "$MIG/$BUND"
"$PY" "$FIXTURE" "$MIG/$BUND" healthy
printf 'run_id\tcommit\tnode_fp\tmodel\tconfig_hash\tscript\tsuite\ttasks\tlimit\tscores\tdata\tthink\n' > "$MTSV"
printf '20260101-000000-eval\tabc1234\ttestfp\tacme/Stub-7B\tdeadbeef\trunbooks/rb.sh\tgeneral\tgsm8k,mmlu\t100\tgsm8k=95.0;mmlu=81.82\t%s\ton\n' "$BUND" >> "$MTSV"
printf '20260102-000000-eval\tabc1234\ttestfp\tacme/Stub-7B\tdeadbeef\trunbooks/rb.sh\tgeneral\tgsm8k\t100\tgsm8k=99.0\tresults/testfp/acme/Stub-7B/data/20260102-000000-eval\toff\n' >> "$MTSV"
BUND4="results/testfp/acme/Stub-7B/data/20260103-000000-eval"
mkdir -p "$MIG/$BUND4"
"$PY" "$FIXTURE" "$MIG/$BUND4" conc1                 # a bundle that did NOT run at 16
printf '20260103-000000-eval\tabc1234\ttestfp\tacme/Stub-7B\tdeadbeef\trunbooks/rb.sh\tgeneral\tgsm8k\t100\tgsm8k=93.0\t%s\toff\n' "$BUND4" >> "$MTSV"
BEFORE="$(cut -f1-12 "$MTSV" | md5sum)"

"$PY" "$SCRIPT_DIR/migrate_accuracy_tsv.py" --tsv "$MTSV" --bundle-root "$MIG" --write >/dev/null 2>&1
chk "migration: header is 16 columns" 16 "$(head -1 "$MTSV" | awk -F'\t' '{print NF}')"
chk "migration: every legacy cell is byte-identical" "$BEFORE" "$(cut -f1-12 "$MTSV" | md5sum)"
chk "migration: row count unchanged" 4 "$(wc -l < "$MTSV")"
chk "migration: conc backfilled from the BUNDLE" 16 "$(sed -n 2p "$MTSV" | cut -f13)"
chk "migration: samples backfilled" "gsm8k=100/100;mmlu=5700/5700" "$(sed -n 2p "$MTSV" | cut -f14)"
chk "migration: validity backfilled" ok "$(sed -n 2p "$MTSV" | cut -f15)"
chk "migration: a row with NO bundle is na, never guessed as 16" na "$(sed -n 3p "$MTSV" | cut -f13)"
chk "migration: a row with no bundle is not citable" na "$(sed -n 3p "$MTSV" | cut -f15)"
# The claim "every accuracy row was c16" is FALSE on the real record -- two ds4 rows ran at c4.
# conc must therefore come from each bundle, and this is the fixture that proves it does.
chk "migration: a non-16 bundle backfills its OWN conc, not 16" 1 "$(sed -n 4p "$MTSV" | cut -f13)"
AFTER="$(md5sum < "$MTSV")"
"$PY" "$SCRIPT_DIR/migrate_accuracy_tsv.py" --tsv "$MTSV" --bundle-root "$MIG" --write >/dev/null 2>&1
chk "migration: idempotent" "$AFTER" "$(md5sum < "$MTSV")"

# The repo's own scar: "the schema changed and the reference did not follow", silently, for
# months, because four scripts hard-coded the header and agreed with each other. Six scripts write
# accuracy.tsv; every one of them must carry the SAME 16-column header, and the reference doc must
# name it too.
echo
echo "=== E. no accuracy.tsv header drift =========================================="
# The header now has ONE definition (eval_validity.py ACCURACY_HEADER). The anti-drift property
# is therefore no longer "every script carries the same literal" — it is "no script carries a
# literal at all, and what each one actually emits equals the one definition". Asserting the
# literal is present is a static word-presence check that a correct refactor breaks, which is the
# same trap that let a green suite hide a critical defect in the throughput layer.
ONE_HDR="$(uv run --project "$REPO_ROOT" python "$SCRIPT_DIR/eval_validity.py" accuracy-header 2>/dev/null \
           || python3 "$SCRIPT_DIR/eval_validity.py" accuracy-header)"
chk "the one definition is 16 columns" 16 "$(printf '%s' "$ONE_HDR" | awk -F'\t' '{print NF}')"
for f in eval.sh eval_bfcl.sh eval_live.sh eval_livebench.sh eval_livecodebench.sh; do
  lit="$(grep -cE "HDR=\\$'run_id" "$SCRIPT_DIR/$f" || true)"
  chk "$f hard-codes NO header literal" 0 "$lit"
  # what it would actually write: run its HDR assignment in isolation.
  # Extract exactly the HDR assignment (it spans a continuation line) and run it in isolation.
  asn="$(sed -n '/^HDR=/,/)"$/p' "$SCRIPT_DIR/$f")"
  got="$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" REPO_ROOT="$REPO_ROOT" \
         bash -c "$asn; printf '%s' \"\$HDR\"" 2>/dev/null)"
  chk "$f emits the one definition" "$ONE_HDR" "$got"
done
chk_has "AGENTS.md documents the 16-column schema" "conc samples" "$(cat "$REPO_ROOT/AGENTS.md")"

echo
echo "=============================================================================="
printf 'GATE 2 SELFTEST: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
