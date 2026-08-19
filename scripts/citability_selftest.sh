#!/usr/bin/env bash
# citability_selftest.sh — REACHABILITY harness for the citability consumers.
#
#   scripts/citability_selftest.sh [-v]
#
# Why this exists, and why it is not a unit test
# ----------------------------------------------
# This repo has a scar: a correct condition sat in an unreachable `elif` branch and burned a
# 75-minute eval (AGENTS.md, "REASONING × SPEC-DECODE branch-order bug"). The lesson recorded
# there is that *confirming a guard's condition fires is not the same as confirming its branch is
# reachable*. Asserting on `classify_row()` in isolation would have proved nothing about that bug.
#
# So every case here runs the REAL script — promote.sh, run_experiment.sh, suite.sh, validate.sh —
# inside a throwaway repo whose children (serve.sh, smoke.sh, bench.sh, eval.sh, adapter.sh) are
# stubs that LOG their invocation and return a scripted exit code. The assertions are on the
# observable behaviour of that run: the exit code, the MEDIAN/verdict line, the contents of the
# artifact that was written, and the stub call log — i.e. on which branch actually executed.
#
# Hermetic by construction (contract §8): no docker, no server, no guidellm/lm-eval, no GPU. The
# stubs are the only "backends" involved and they are ~5 lines of bash each.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
VERBOSE=0; [ "${1:-}" = "-v" ] && VERBOSE=1
PASS=0; FAIL=0
NODE_FP=gb10-test

ok(){ PASS=$((PASS+1)); [ "$VERBOSE" = 1 ] && echo "  ok   $*"; return 0; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL $*"; return 0; }
check(){ # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected [$2], got [$3]"; fi; }
contains(){ # contains <desc> <needle> <file>
  if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1 — '$2' not in $3"; fi; }
lacks(){
  if grep -qF -- "$2" "$3"; then bad "$1 — '$2' IS in $3 (should not be)"; else ok "$1"; fi; }

# ── throwaway repo ────────────────────────────────────────────────────────────
# Real scripts under test + the real library; everything they SHELL OUT to is a stub.
mkrepo(){
  R="$(mktemp -d)"; trap 'rm -rf "$R"' EXIT
  mkdir -p "$R/scripts/lib" "$R/results/$NODE_FP/Org/Model" "$R/runbooks/Org/Model" \
           "$R/backends/vllm"
  cp "$REAL_REPO/scripts/citability.py" "$R/scripts/"
  cp "$REAL_REPO/scripts/lib/validity.py" "$REAL_REPO/scripts/lib/validity.sh" \
     "$REAL_REPO/scripts/lib/__init__.py" "$R/scripts/lib/" 2>/dev/null || true
  for s in promote.sh run_experiment.sh run_experiment_llamacpp.sh suite.sh validate.sh; do
    cp "$REAL_REPO/scripts/$s" "$R/scripts/"
  done
  echo '{"gpu":{"mem_bw_gbs":273}}' > "$R/results/$NODE_FP/node_profile.json"
  TSV="$R/results/$NODE_FP/Org/Model/results.tsv"
  python3 "$R/scripts/lib/validity.py" header > "$TSV"
  RB="$R/runbooks/Org/Model/candidate_tuned.sh"
  printf '#!/usr/bin/env bash\n# image v0.25.0\nMODEL=Org/Model\nSERVED_NAME=m\n' > "$RB"
  CFG="$(sha256sum "$RB" | cut -c1-8)"
  LOG="$R/stub.log"; : > "$LOG"
  export AHL_PYTHON=python3     # keep the harness off the network (no uv resolve)
}

# row <run_id> <shape> <status> <validity> <c1> <c4> <c8> <c16> <c32> [notes] [cfg]
row(){
  local rid="$1" shape="$2" st="$3" val="$4" c1="$5" c4="$6" c8="$7" c16="$8" c32="$9"
  local notes="${10:-na}" cfg="${11:-$CFG}"
  printf '%s\tabc1234\t%s\tOrg/Model\t%s\tvllm@0.25.0\t%s\trunbooks/Org/Model/candidate_tuned.sh\t' \
    "$rid" "$NODE_FP" "$shape" "$cfg" >> "$TSV"
  printf '12.0\t180\t42\t%s\t%s\t%s\t%s\t%s\tna\tna\t%s\tlevels=1|16\tmeasured_placeholder\t%s\tna\n' \
    "$c1" "$c4" "$c8" "$c16" "$c32" "$val" "$notes" >> "$TSV"
  # the status column is 21st; rewrite the placeholder we just wrote
  python3 - "$TSV" "$st" <<'PY'
import sys
p, st = sys.argv[1:3]
lines = open(p).read().splitlines()
f = lines[-1].split('\t'); f[20] = st
lines[-1] = '\t'.join(f)
open(p, 'w').write('\n'.join(lines) + '\n')
PY
}

stub(){ # stub <name> <exit_code> [extra body]
  local name="$1" rc="$2" extra="${3:-}"
  cat > "$R/scripts/$name" <<EOS
#!/usr/bin/env bash
echo "$name \$*" >> "$LOG"
$extra
exit $rc
EOS
  chmod +x "$R/scripts/$name"
}

banner(){ echo; echo "== $* =="; }

# ══════════════════════════════════════════════════════════════════════════════
# promote.sh — the objective-scoped gate (defect #7), fatal/suspect/na/crash
# blocking (#2/#3/#4) and the comment-only banner (#1)
# ══════════════════════════════════════════════════════════════════════════════
promote(){ ( cd "$R" && "$R/scripts/promote.sh" "$RB" "note" >"$R/out" 2>"$R/err"; echo $? ); }

banner "promote.sh — gate reachability"

# 1. fatal token AT the cited level blocks, whatever else is present
mkrepo
row 20260819-000001-chat 'chat(512/256)' measured ok            40 na na 400 na
row 20260819-000002-chat 'chat(512/256)' measured ok            41 na na 402 na
row 20260819-000003-chat 'chat(512/256)' discard  'no_data@c16' 42 na na 999 na
check "fatal@c16 blocks even beside 2 valid rows" 4 "$(promote)"
contains "  ...and says it is fatal" "NOT DATA at chat c16" "$R/err"
[ -e "$R/runbooks/Org/Model/VLLM-25-Org_Model_final.sh" ] && bad "blocked promote still wrote _final.sh" || ok "no artifact written when blocked"

# 2. a row that is suspect ONLY at another level does NOT block (defect #7)
mkrepo
row 20260819-000001-chat 'chat(512/256)' measured 'low_sample@c1' 40 na na 400 na
row 20260819-000002-chat 'chat(512/256)' measured ok              41 na na 402 na
check "low_sample@c1 does not block a c16 promotion" 0 "$(promote)"
contains "  ...but is reported" "flagged only elsewhere: low_sample@c1" "$R/err"

# 3. a starved CODER row does not block a chat-c16 promotion, and is recorded
mkrepo
row 20260819-000001-chat  'chat(512/256)'   measured ok 40 na na 400 na
row 20260819-000002-chat  'chat(512/256)'   measured ok 41 na na 402 na
row 20260819-000003-coder 'coder(4096/1024)' void 'no_data@c1+survivorship@c32' 9 20 30 40 50
check "starved coder row does not block chat c16" 0 "$(promote)"
contains "  ...warned on stderr" "OUTSIDE the promoted objective" "$R/err"
contains "  ...and recorded in the artifact" "20260819-000003-coder" \
         "$R/runbooks/Org/Model/VLLM-25-Org_Model_final.sh"

# 4. a row whose every cell is `na` is NOT citable (defect #3)
mkrepo
row 20260819-000001-chat 'chat(512/256)' measured na na na na na na
check "validity=na alone blocks (na is never ok)" 4 "$(promote)"

# 5. a CRASH row at the objective blocks (defect #4 / §5 "non-valid for every consumer")
mkrepo
row 20260819-000001-chat 'chat(512/256)' measured ok 40 na na 400 na
row 20260819-000002-chat 'chat(512/256)' measured ok 41 na na 402 na
row 20260819-000003-chat 'chat(512/256)' crash 'no_data@c16' 39 na na hang na
check "crash at the objective blocks" 4 "$(promote)"

# 6. suspect AT the objective, with no citable row, blocks
mkrepo
row 20260819-000001-chat 'chat(512/256)' measured 'low_sample@c16' 40 na na 400 na
check "suspect@c16 with no citable row blocks" 4 "$(promote)"
contains "  ...listed as suspect" "suspect at chat c16" "$R/err"

# 7. no supporting rows at all still blocks
mkrepo
check "zero supporting rows blocks" 4 "$(promote)"
contains "  ...with the right reason" "NO benchmark rows" "$R/err"

# 8. objective fallback: a config that only ever ran c1 is gated at c1, not refused
mkrepo
row 20260819-000001-chat 'chat(512/256)' measured ok 20 na na na na
row 20260819-000002-chat 'chat(512/256)' measured ok 21 na na na na
check "c1-only campaign is gated at c1, not blocked" 0 "$(promote)"
contains "  ...and says so" "gating on c1" "$R/err"
mkrepo
row 20260819-000001-chat 'chat(512/256)' measured 'no_data@c1' 20 na na na na
check "  ...and the fallback level still blocks on its own fatal" 4 "$(promote)"

banner "promote.sh — override forms"
setup_blocked(){ mkrepo; row 20260819-000001-chat 'chat(512/256)' measured 'low_sample@c16' 40 na na 400 na; }

setup_blocked; check "no override -> refuse" 4 "$(promote)"
setup_blocked; check "override='1' rejected (flag, not justification)" 4 \
  "$(AHL_PROMOTE_OVERRIDE=1 promote)"
contains "  ...with the flag message" "must be a JUSTIFICATION" "$R/err"
setup_blocked; check "override='yes' rejected" 4 "$(AHL_PROMOTE_OVERRIDE=yes promote)"
setup_blocked; check "override='too short' rejected" 4 "$(AHL_PROMOTE_OVERRIDE='short' promote)"
contains "  ...with the length message" "too short" "$R/err"
setup_blocked
check "a real justification is accepted" 0 \
  "$(AHL_PROMOTE_OVERRIDE='20260819 jk: c16 low_sample, adjudicated against the bundle' promote)"
FINAL="$R/runbooks/Org/Model/VLLM-25-Org_Model_final.sh"
contains "  ...greppable marker survives" "AHL_PROMOTION_OVERRIDE" "$FINAL"
contains "  ...as a COMMENT" "# AHL_PROMOTION_OVERRIDE:" "$FINAL"

banner "promote.sh — SHELL INJECTION (defect #1)"
# The exact verified exploit: the justification became `AHL_PROMOTION_OVERRIDE="<text>"` in a file
# that serve.sh/bench.sh `source`, so $(...) inside it executed at SERVE time.
setup_blocked
SENTINEL="$R/PWNED"
check "injecting justification is accepted (it is only text)" 0 \
  "$(AHL_PROMOTE_OVERRIDE="20260819 jk: pwn \$(touch $SENTINEL) here" promote)"
FINAL="$R/runbooks/Org/Model/VLLM-25-Org_Model_final.sh"
[ -e "$SENTINEL" ] && bad "sentinel created at PROMOTE time" || ok "nothing executed at promote time"
# The payload's home: source the artifact exactly as serve.sh does.
( set +u; . "$FINAL" ) >/dev/null 2>&1 || true
[ -e "$SENTINEL" ] && bad "SOURCING the promoted file EXECUTED the justification" \
                   || ok "sourcing the promoted file executes nothing"
if grep -qE '^[A-Za-z_][A-Za-z0-9_]*=' "$FINAL" | grep -q AHL_PROMOTION; then
  bad "operator text is still emitted as an assignment"; else ok "no AHL_PROMOTION_* assignment"; fi
lacks "no bare AHL_PROMOTION_OVERRIDE= assignment" 'AHL_PROMOTION_OVERRIDE="' "$FINAL"

# newline injection: a comment ends at \n, so a newline is a command on the next line
setup_blocked
SENTINEL2="$R/PWNED2"
check "newline-injecting justification accepted as text" 0 \
  "$(AHL_PROMOTE_OVERRIDE="20260819 jk: adjudicated
touch $SENTINEL2" promote)"
FINAL="$R/runbooks/Org/Model/VLLM-25-Org_Model_final.sh"
( set +u; . "$FINAL" ) >/dev/null 2>&1 || true
[ -e "$SENTINEL2" ] && bad "newline escaped the comment and ran" || ok "newline cannot escape the comment"
if grep -n -- "touch $SENTINEL2" "$FINAL" | grep -qv ':[[:space:]]*#'; then
  bad "the injected text landed on a NON-comment line"; else ok "injected text is confined to a comment"; fi

# $USER is operator-controlled too
setup_blocked
SENTINEL3="$R/PWNED3"
check "hostile \$USER accepted as text" 0 \
  "$(USER="jk\$(touch $SENTINEL3)" AHL_PROMOTE_OVERRIDE='20260819 jk: adjudicated properly' promote)"
FINAL="$R/runbooks/Org/Model/VLLM-25-Org_Model_final.sh"
( set +u; . "$FINAL" ) >/dev/null 2>&1 || true
[ -e "$SENTINEL3" ] && bad "hostile \$USER executed on source" || ok "hostile \$USER is inert"

# the free-text NOTE argument is the same class of input
mkrepo
row 20260819-000001-chat 'chat(512/256)' measured ok 40 na na 400 na
row 20260819-000002-chat 'chat(512/256)' measured ok 41 na na 402 na
SENTINEL4="$R/PWNED4"
( cd "$R" && "$R/scripts/promote.sh" "$RB" "best c16 yet
touch $SENTINEL4" >/dev/null 2>&1 ) || true
FINAL="$R/runbooks/Org/Model/VLLM-25-Org_Model_final.sh"
( set +u; . "$FINAL" ) >/dev/null 2>&1 || true
[ -e "$SENTINEL4" ] && bad "the NOTE argument escaped its comment" || ok "NOTE argument is inert"

# ══════════════════════════════════════════════════════════════════════════════
# run_experiment.sh — summarizer failure (defect #5) + median exclusions
# ══════════════════════════════════════════════════════════════════════════════
banner "run_experiment.sh — branch reachability"
runexp(){ ( cd "$R" && N=3 "$R/scripts/run_experiment.sh" "$RB" >"$R/out" 2>"$R/err"; echo $? ); }
median_line(){ grep '^MEDIAN' "$R/out" || true; }

# 3 clean benches -> cite=ok, exit 0
mkrepo; stub serve.sh 0; stub smoke.sh 0
stub bench.sh 0 'python3 - "$0" <<EOF
import os,subprocess
EOF'
# bench stub must actually write rows; do it inline instead
cat > "$R/scripts/bench.sh" <<'EOS'
#!/usr/bin/env bash
echo "bench.sh $*" >> "$STUB_LOG"
"$STUB_ROW" "$STUB_STATUS" "$STUB_VALIDITY" "$STUB_C16"
exit "${STUB_BENCH_RC:-0}"
EOS
chmod +x "$R/scripts/bench.sh"
cat > "$R/rowwriter" <<EOS
#!/usr/bin/env bash
set -e
TSV="$TSV"; CFG="$CFG"; NODE_FP="$NODE_FP"
rid="\$(date -u +%Y%m%d-%H%M%S)-\$RANDOM-chat"
printf '%s\tabc1234\t%s\tOrg/Model\tchat(512/256)\tvllm@0.25.0\t%s\trunbooks/Org/Model/candidate_tuned.sh\t' "\$rid" "\$NODE_FP" "\$CFG" >> "\$TSV"
printf '12.0\t180\t42\t40.0\tna\tna\t%s\tna\tna\tna\t%s\tlevels=1|16\t%s\t%s\tna\n' "\$3" "\$2" "\$1" "\$NOTES" >> "\$TSV"
EOS
chmod +x "$R/rowwriter"
export STUB_LOG="$LOG" STUB_ROW="$R/rowwriter"
STUB_STATUS=measured STUB_VALIDITY=ok STUB_C16=400
export STUB_STATUS STUB_VALIDITY STUB_C16
check "3 clean benches -> exit 0" 0 "$(runexp)"
case "$(median_line)" in *"cite=ok"*) ok "  ...cite=ok";; *) bad "  ...cite=ok, got: $(median_line)";; esac

# summarizer failure: the MEDIAN line must still appear, cite=error, exit 4 (NOT 1)
mkrepo; stub serve.sh 0; stub smoke.sh 0; stub bench.sh 0
cat > "$R/scripts/citability.py" <<'EOS'
import sys
sys.stderr.write("simulated summarizer crash\n")
sys.exit(9)
EOS
check "summarizer failure exits 4, not 1 (1 means 'nothing was benched')" 4 "$(runexp)"
case "$(median_line)" in
  *"cite=error"*) ok "  ...MEDIAN line still emitted, cite=error";;
  "")             bad "  ...NO MEDIAN line at all (the defect)";;
  *)              bad "  ...wrong cite: $(median_line)";;
esac
contains "  ...and says the rows are in results.tsv" "the bench rows ARE in" "$R/err"

# serve failure is still exit 1, and never reaches bench
mkrepo; stub serve.sh 1; stub smoke.sh 0; stub bench.sh 0
check "serve failure is exit 1 (pre-measurement)" 1 "$(runexp)"
case "$(median_line)" in *"status=serve_fail"*) ok "  ...status=serve_fail";; *) bad "  ...got $(median_line)";; esac
if grep -q '^bench.sh' "$LOG"; then bad "  ...bench ran after a failed serve"; else ok "  ...bench never ran"; fi

# smoke failure is exit 1 and tears the serve down
mkrepo; stub serve.sh 0; stub smoke.sh 1; stub bench.sh 0
check "smoke failure is exit 1" 1 "$(runexp)"
if grep -q '^bench.sh' "$LOG"; then bad "  ...bench ran after a failed smoke"; else ok "  ...bench never ran"; fi

# ══════════════════════════════════════════════════════════════════════════════
# suite.sh — exit-code precedence 3 > 4 > 1 > 0 (defect #6)
# ══════════════════════════════════════════════════════════════════════════════
banner "suite.sh — exit precedence"
suite_run(){ ( cd "$R" && SHAPES=chat "$R/scripts/suite.sh" "$RB" >"$R/out" 2>"$R/err"; echo $? ); }
suite_repo(){ # suite_repo <smoke_rc> <eval_rc> <bench_rc>
  mkrepo
  mkdir -p "$R/backends/vllm"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$R/backends/vllm/adapter.sh"; chmod +x "$R/backends/vllm/adapter.sh"
  stub serve.sh 0; stub smoke.sh "$1"; stub eval.sh "$2"
  cat > "$R/scripts/bench.sh" <<EOS
#!/usr/bin/env bash
echo "bench.sh \$*" >> "$LOG"
"$R/rowwriter" "\${STUB_STATUS:-measured}" "\${STUB_VALIDITY:-ok}" "\${STUB_C16:-400}"
exit $3
EOS
  chmod +x "$R/scripts/bench.sh"
  cat > "$R/rowwriter" <<EOS
#!/usr/bin/env bash
set -e
rid="\$(date -u +%Y%m%d-%H%M%S)-chat"
printf '%s\tabc1234\t%s\tOrg/Model\tchat(512/256)\tvllm@0.25.0\t%s\trunbooks/Org/Model/candidate_tuned.sh\t' "\$rid" "$NODE_FP" "$CFG" >> "$TSV"
printf '12.0\t180\t42\t40.0\tna\tna\t%s\tna\tna\tna\t%s\tlevels=1|16\t%s\tsuite\tna\n' "\$3" "\$2" "\$1" >> "$TSV"
EOS
  chmod +x "$R/rowwriter"
}

suite_repo 0 0 0; check "all gates pass -> 0" 0 "$(suite_run)"
suite_repo 0 0 4; check "bench invalid alone -> 4" 4 "$(suite_run)"
suite_repo 1 0 4; check "smoke FAIL + bench invalid -> 4 (was downgraded to 1)" 4 "$(suite_run)"
suite_repo 0 1 4; check "eval error + bench invalid -> 4" 4 "$(suite_run)"
suite_repo 1 1 3; check "everything failing + crash -> 3 (crash outranks all)" 3 "$(suite_run)"
suite_repo 1 0 0; check "smoke FAIL alone -> 1" 1 "$(suite_run)"

# a void Gate-3 row makes the report FAIL even when bench.sh exited 0
suite_repo 0 0 0
STUB_VALIDITY='no_data@c16' STUB_STATUS=measured
export STUB_VALIDITY STUB_STATUS
check "fatal-tagged Gate-3 row fails the suite despite bench exit 0" 4 "$(suite_run)"
contains "  ...report marks it" "SUITE VERDICT: FAIL" "$R/results/$NODE_FP/Org/Model/SUITE-$CFG.md"
contains "  ...as void, not merely suspect" "chat(512/256):void" "$R/results/$NODE_FP/Org/Model/SUITE-$CFG.md"
unset STUB_VALIDITY STUB_STATUS

# ══════════════════════════════════════════════════════════════════════════════
# validate.sh — exit precedence 4 > 1 (a failed smoke must not MASK a non-citable Gate 3)
# ══════════════════════════════════════════════════════════════════════════════
banner "validate.sh — exit precedence"
val_repo(){ # val_repo <smoke_rc>
  mkrepo
  printf '#!/usr/bin/env bash\nexit 0\n' > "$R/backends/vllm/adapter.sh"
  chmod +x "$R/backends/vllm/adapter.sh"
  stub serve.sh 0; stub smoke.sh "$1"; stub eval.sh 0
}
val_run(){ ( cd "$R" && "$R/scripts/validate.sh" "$RB" >"$R/out" 2>"$R/err"; echo $? ); }

val_repo 0; row 20260819-000001-chat 'chat(512/256)' measured ok 40 na na 400 na
check "smoke pass + citable rows -> 0" 0 "$(val_run)"
val_repo 1; row 20260819-000001-chat 'chat(512/256)' measured ok 40 na na 400 na
check "smoke FAIL alone -> 1" 1 "$(val_run)"
val_repo 0; row 20260819-000001-chat 'chat(512/256)' measured 'no_data@c16' 40 na na 400 na
check "citable-row failure alone -> 4" 4 "$(val_run)"
val_repo 1; row 20260819-000001-chat 'chat(512/256)' measured 'no_data@c16' 40 na na 400 na
check "smoke FAIL + non-citable rows -> 4 (used to report 1 and hide it)" 4 "$(val_run)"
contains "  ...report names both" "Gate 1 functional (smoke): FAIL" \
         "$R/results/$NODE_FP/Org/Model/VALIDATION-$CFG.md"
contains "  ...and the Gate-3 failure" "NOT citable" \
         "$R/results/$NODE_FP/Org/Model/VALIDATION-$CFG.md"
val_repo 0
check "no throughput rows -> NOT RUN, exit 0 (Gates 1+2 only)" 0 "$(val_run)"
contains "  ...labelled NOT RUN" "NOT RUN" "$R/results/$NODE_FP/Org/Model/VALIDATION-$CFG.md"

# ══════════════════════════════════════════════════════════════════════════════
# run_experiment_llamacpp.sh — the same summarizer guard on the host backend
# (RESTART=0 SKIP_SMOKE=1 keeps the launcher and curl out of it entirely)
# ══════════════════════════════════════════════════════════════════════════════
banner "run_experiment_llamacpp.sh"
mkrepo
STUB="$R/runbooks/Org/Model/launcher.smoke-runbook.sh"
printf '#!/usr/bin/env bash\nMODEL=Org/Model\nSERVED_NAME=m\n' > "$STUB"
stub bench_llamacpp.sh 0
cp "$R/scripts/citability.py" "$R/scripts/citability.py.bak"
cat > "$R/scripts/citability.py" <<'EOS'
import sys
sys.exit(9)
EOS
rc=$( cd "$R" && TAG=t N=2 RESTART=0 SKIP_SMOKE=1 "$R/scripts/run_experiment_llamacpp.sh" "$STUB" \
        >"$R/out" 2>"$R/err"; echo $? )
check "summarizer failure -> 4, not 1" 4 "$rc"
case "$(grep '^MEDIAN' "$R/out" || true)" in
  *"cite=error"*) ok "  ...MEDIAN line still emitted";;
  *)              bad "  ...no cite=error MEDIAN line: $(grep '^MEDIAN' "$R/out" || echo NONE)";;
esac
mv "$R/scripts/citability.py.bak" "$R/scripts/citability.py"
rc=$( cd "$R" && TAG=t N=2 RESTART=0 SKIP_SMOKE=1 "$R/scripts/run_experiment_llamacpp.sh" "$STUB" \
        >"$R/out" 2>"$R/err"; echo $? )
check "no rows at all -> 4 (no_valid_data), not a crash" 4 "$rc"

# the two runners must keep ONE rule: the summarizer block is byte-identical
a="$(sed -n '/^SUMMARIZE_RC=0$/,/^fi$/p' "$REAL_REPO/scripts/run_experiment.sh")"
b="$(sed -n '/^SUMMARIZE_RC=0$/,/^fi$/p' "$REAL_REPO/scripts/run_experiment_llamacpp.sh")"
check "both runners share the identical summarizer block" "$a" "$b"

echo
echo "citability_selftest: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
