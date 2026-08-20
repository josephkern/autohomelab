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
  # suite.sh consumes the Gate-2 predicate for its accuracy-row read-back (contract A9), so
  # eval_validity.py has to be in the throwaway repo too or the summary report never renders.
  cp "$REAL_REPO/scripts/citability.py" "$REAL_REPO/scripts/eval_validity.py" "$R/scripts/"
  cp "$REAL_REPO/scripts/lib/validity.py" "$REAL_REPO/scripts/lib/validity.sh" \
     "$REAL_REPO/scripts/lib/__init__.py" "$R/scripts/lib/" 2>/dev/null || true
  for s in promote.sh run_experiment.sh run_experiment_llamacpp.sh suite.sh validate.sh; do
    cp "$REAL_REPO/scripts/$s" "$R/scripts/"
  done
  # promote.sh derives the VLLM-<minor> in the promoted name from the image.lock CATALOG, so the
  # catalog is part of the fixture. Copying the real one (not a hand-written stand-in) is
  # deliberate: the derivation's whole job is to agree with the file the repo actually ships.
  cp "$REAL_REPO/backends/vllm/image.lock" "$R/backends/vllm/"
  echo '{"gpu":{"mem_bw_gbs":273}}' > "$R/results/$NODE_FP/node_profile.json"
  TSV="$R/results/$NODE_FP/Org/Model/results.tsv"
  python3 "$R/scripts/lib/validity.py" header > "$TSV"
  RB="$R/runbooks/Org/Model/candidate_tuned.sh"
  # A realistic runbook: a digest pin, like every runbook in the tree. v0.25.0's digest, so the
  # promoted artifact is VLLM-25-Org_Model_final.sh as the cases below assert.
  setrb "$(printf '#!/usr/bin/env bash\n# image v0.25.0\nMODEL=Org/Model\nSERVED_NAME=m\nVLLM_IMAGE="%s"\n' "$IMG_025")"
  LOG="$R/stub.log"; : > "$LOG"
  export AHL_PYTHON=python3     # keep the harness off the network (no uv resolve)
}

# setrb <full runbook text> — replace the fixture runbook and re-derive its config_hash. Rows
# added with row() key off $CFG, so this must run BEFORE them.
setrb(){ printf '%s' "$1" > "$RB"; chmod +x "$RB"; CFG="$(sha256sum "$RB" | cut -c1-8)"; }

# Digests lifted from the real backends/vllm/image.lock catalog.
IMG_022="vllm/vllm-openai@sha256:0fec7ec5f3e6bc168e54899935fb0557da908a4832a1dbc88e2debcf2f889416"
IMG_023="vllm/vllm-openai@sha256:6d8429e38e3747723ca07ee1b17972e09bb9c51c4032b266f24fb1cc3b22ed8f"
IMG_025="vllm/vllm-openai@sha256:fc56161ee42a011aeee78b65d0a81b6683c7d04402fd40503d14d4d6c98f07cb"
IMG_MTPFIX="vllm-openai:0.23.0-qwen3nextmtp-fix"
IMG_NIGHTLY="vllm/vllm-openai@sha256:3dbe092ec5b2cef63b6104d33fa75d6ce53a7870962529ada69f78bbbc38e776"

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

# ══════════════════════════════════════════════════════════════════════════════
# promote.sh — VLLM-<minor> derivation (AGENTS.md follow-up)
#
# The name is permanent, so the minor in it must come from the PIN, not from prose. The old
# code took the first `vX.Y.Z` anywhere in the file: a baseline header reading
# "image v0.22.0 -> v0.23.0" named a 0.23.0 config VLLM-22, and the standing workaround was to
# remember VLLM_TAG. Every case here promotes for real and asserts the FILENAME that appeared.
# ══════════════════════════════════════════════════════════════════════════════
banner "promote.sh — VLLM-<minor> derivation"

# derive <expected basename> <desc> — two clean objective rows, promote, assert the artifact name.
derive(){
  local want="$1" desc="$2" rc got
  row 20260819-000001-chat 'chat(512/256)' measured ok 40 na na 400 na
  row 20260819-000002-chat 'chat(512/256)' measured ok 41 na na 402 na
  rc="$(promote)"
  check "$desc — promotes" 0 "$rc"
  got="$(ls "$R/runbooks/Org/Model/" | grep '_final\.sh$' | tr '\n' ' ')"
  check "$desc — name" "$want " "$got"
}

# refuses <desc>: promote.sh must REFUSE to name the artifact (exit 2, contract v1.3 usage rung)
# and must leave no `_final.sh` behind. Refusing is the right answer when the pin cannot name the
# release: the artifact name is permanent, and the operator's fix is one word (VLLM_TAG=).
refuses(){
  local desc="$1" rc got
  row 20260819-000001-chat 'chat(512/256)' measured ok 40 na na 400 na
  row 20260819-000002-chat 'chat(512/256)' measured ok 41 na na 402 na
  rc="$(promote)"
  check "$desc — refuses (exit 2)" 2 "$rc"
  got="$(ls "$R/runbooks/Org/Model/" 2>/dev/null | grep -c '_final\.sh$' || true)"
  check "$desc — wrote no artifact" 0 "$got"
}

# 1. THE TRACKED BUG: a migration comment in the header, a 0.23.0 digest in the pin.
mkrepo
setrb "$(printf '#!/usr/bin/env bash\n# baseline migrated: image v0.22.0 -> v0.23.0\nMODEL=Org/Model\nVLLM_IMAGE="%s"\n' "$IMG_023")"
derive "VLLM-23-Org_Model_final.sh" "migration comment loses to the pin"
[ -e "$R/runbooks/Org/Model/VLLM-22-Org_Model_final.sh" ] && bad "the old first-vX.Y.Z name was written" \
  || ok "  ...and VLLM-22 (the old wrong name) was never written"

# 2. prose can hold ANY version and still lose to the pin
mkrepo
setrb "$(printf '#!/usr/bin/env bash\n# tried on v0.99.9, see also v0.17.1\nMODEL=Org/Model\nVLLM_IMAGE="%s"\n' "$IMG_022")"
derive "VLLM-22-Org_Model_final.sh" "unrelated prose versions lose to the pin"

# 3. the tag-pinned local build resolves through the catalog key, not a digest
mkrepo
setrb "$(printf '#!/usr/bin/env bash\nMODEL=Org/Model\nVLLM_IMAGE="%s"\n' "$IMG_MTPFIX")"
derive "VLLM-23-Org_Model_final.sh" "tag-pinned local build (0.23.0-qwen3nextmtp-fix)"

# 4. an uncatalogued DIGEST must REFUSE, even when its own line carries a version comment.
# Updated 20260820: this case previously asserted the comment was used. A verifier showed that is
# the ORIGINAL defect narrowed to one line — `VLLM_IMAGE="…@sha256:aaaa"  # was v0.24.0; now
# v0.28.0` named a 0.28.0 config VLLM-24 — and it fires exactly in the uncatalogued case where an
# operator is sloppiest. A trailing comment is prose too. The name is permanent, so refusing (and
# naming the three fixes) beats guessing.
mkrepo
setrb "$(printf '#!/usr/bin/env bash\n# migrated off v0.22.0\nMODEL=Org/Model\nVLLM_IMAGE="vllm/vllm-openai@sha256:deadbeef"   # v0.26.2\n')"
refuses "uncatalogued digest refuses rather than trusting a trailing comment"

# 5. VLLM_TAG still wins (the documented escape hatch is not removed)
mkrepo
row 20260819-000001-chat 'chat(512/256)' measured ok 40 na na 400 na
row 20260819-000002-chat 'chat(512/256)' measured ok 41 na na 402 na
check "VLLM_TAG overrides the catalog" 0 "$(VLLM_TAG=99 promote)"
[ -e "$R/runbooks/Org/Model/VLLM-99-Org_Model_final.sh" ] && ok "  ...and names it VLLM-99" \
  || bad "  ...but did not name it VLLM-99"

# 6. underivable -> REFUSE. `VLLM-XX-...` would be a permanent wrong claim in a filename, and
#    the promotion is otherwise perfectly valid, so this must be a refusal and not a warning.
mkrepo
setrb "$(printf '#!/usr/bin/env bash\n# image v0.25.0\nMODEL=Org/Model\nSERVED_NAME=m\n')"
row 20260819-000001-chat 'chat(512/256)' measured ok 40 na na 400 na
row 20260819-000002-chat 'chat(512/256)' measured ok 41 na na 402 na
check "no VLLM_IMAGE -> refuse (exit 2 usage rung), never VLLM-XX" 2 "$(promote)"
contains "  ...with the actionable message" "cannot derive the vLLM minor" "$R/err"
[ -z "$(ls "$R/runbooks/Org/Model/" | grep '_final\.sh$')" ] && ok "  ...and wrote no artifact" \
  || bad "  ...but wrote an artifact anyway"
check "  ...and VLLM_TAG rescues it" 0 "$(VLLM_TAG=25 promote)"

# 7. an image that appears ONLY as the catalog's DEFAULT assignment (no `# <version> <ref>` row)
#    still resolves, from that line's trailing comment
mkrepo
printf 'AHL_VLLM_DEFAULT_IMAGE="vllm/vllm-openai@sha256:cafe01"  # v0.31.0\n' \
  > "$R/backends/vllm/image.lock"
setrb "$(printf '#!/usr/bin/env bash\n# was v0.22.0\nMODEL=Org/Model\nVLLM_IMAGE="vllm/vllm-openai@sha256:cafe01"\n')"
derive "VLLM-31-Org_Model_final.sh" "catalog DEFAULT assignment resolves"

# 8. a catalog key that is not a version (`nightly`) does not become the minor
mkrepo
setrb "$(printf '#!/usr/bin/env bash\nMODEL=Org/Model\nVLLM_IMAGE="%s"\n' "$IMG_NIGHTLY")"
row 20260819-000001-chat 'chat(512/256)' measured ok 40 na na 400 na
row 20260819-000002-chat 'chat(512/256)' measured ok 41 na na 402 na
check "catalog key 'nightly' is not a version -> refuse" 2 "$(promote)"

# 9. the derivation is REPORTED, so an operator can see which rule fired
mkrepo
row 20260819-000001-chat 'chat(512/256)' measured ok 40 na na 400 na
row 20260819-000002-chat 'chat(512/256)' measured ok 41 na na 402 na
check "digest pin promotes" 0 "$(promote)"
contains "  ...and says where the minor came from" ">> vLLM minor: 25 (from image.lock" "$R/err"

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
# The status column is a VALIDITY axis, not a keep/discard verdict
#
# `keep` was in the documented vocabulary with 0 of 315 rows ever carrying it. The adjudication
# (20260820) was to keep the loop out of the verdict business entirely and record the verdict
# where it is durable — so the property under test is that a caller CANNOT get a verdict into the
# journal by asking, and that the promoted artifact points back at its evidence instead.
# ══════════════════════════════════════════════════════════════════════════════
banner "status is validity, not verdict"

mkrepo; stub serve.sh 0; stub smoke.sh 0
cat > "$R/rowwriter" <<EOS
#!/usr/bin/env bash
set -e
TSV="$TSV"; CFG="$CFG"; NODE_FP="$NODE_FP"
rid="\$(date -u +%Y%m%d-%H%M%S)-\$RANDOM-chat"
printf '%s\tabc1234\t%s\tOrg/Model\tchat(512/256)\tvllm@0.25.0\t%s\trunbooks/Org/Model/candidate_tuned.sh\t' "\$rid" "\$NODE_FP" "\$CFG" >> "\$TSV"
printf '12.0\t180\t42\t40.0\tna\tna\t%s\tna\tna\tna\t%s\tlevels=1|16\t%s\t%s\tna\n' "\$3" "\$2" "\$1" "\${NOTES:-na}" >> "\$TSV"
EOS
chmod +x "$R/rowwriter"
export STUB_LOG="$LOG" STUB_ROW="$R/rowwriter"
cat > "$R/scripts/bench.sh" <<'EOS'
#!/usr/bin/env bash
echo "bench.sh $*" >> "$STUB_LOG"
echo "STATUS=${STATUS:-<unset>}" >> "$STUB_LOG"
"$STUB_ROW" "${STATUS:-measured}" ok 400
exit 0
EOS
chmod +x "$R/scripts/bench.sh"

# 1. a caller's verdict is REFUSED, not silently overridden — an ignored variable is how an
#    operator comes to believe the journal recorded a decision it never recorded.
check "STATUS=keep is REFUSED (retired, v1.3)" 2 "$(STATUS=keep runexp)"
contains "  ...naming where a keep IS recorded" "logbook" "$R/err"
if grep -q '^serve.sh' "$LOG"; then bad "  ...but it served first"; else ok "  ...before serving anything"; fi
check "STATUS=discard is REFUSED too (orchestrator adjudication, not a loop verdict)" 2 "$(STATUS=discard runexp)"

# 2. a validity state is not a verdict, and still works
check "STATUS=measured is accepted (it is a validity state)" 0 "$(STATUS=measured runexp)"

# 3. every bench the loop drives is told `measured`, and no verdict reaches the column
if grep -q '^STATUS=measured$' "$LOG"; then ok "  ...every bench is invoked with STATUS=measured"
else bad "  ...bench saw: $(grep '^STATUS=' "$LOG" | sort -u | tr '\n' ' ')"; fi
if awk -F'\t' 'NR>1 && ($21=="keep" || $21=="discard"){f=1} END{exit !f}' "$TSV"; then
  bad "  ...a verdict reached the status column"; else ok "  ...no verdict reached the status column"; fi

# 4. the same answer from the host-backend runner (bench_llamacpp.sh does not even read STATUS,
#    so this guard is what keeps the two runners from answering a caller differently)
mkrepo
STUB2="$R/runbooks/Org/Model/launcher.smoke-runbook.sh"
printf '#!/usr/bin/env bash\nMODEL=Org/Model\nSERVED_NAME=m\n' > "$STUB2"
rc=$( cd "$R" && STATUS=keep TAG=t N=2 RESTART=0 SKIP_SMOKE=1 \
        "$R/scripts/run_experiment_llamacpp.sh" "$STUB2" >"$R/out" 2>"$R/err"; echo $? )
check "llama.cpp runner refuses STATUS=keep identically" 2 "$rc"
contains "  ...with the same reason" "is RETIRED" "$R/err"

# 5. the promoted artifact carries the pointer back to its evidence — the replacement for a
#    per-row `keep` stamp, at the grain the decision was actually made on.
mkrepo
row 20260819-000001-chat 'chat(512/256)' measured ok 40 na na 400 na
row 20260819-000002-chat 'chat(512/256)' measured ok 41 na na 402 na
check "clean promotion" 0 "$(promote)"
FINAL="$R/runbooks/Org/Model/VLLM-25-Org_Model_final.sh"
contains "  ...records how to re-derive the supporting rows" "# Re-derive those rows:" "$FINAL"
contains "  ...pointing at this model's journal" "results/$NODE_FP/Org/Model/results.tsv" "$FINAL"
contains "  ...at this config_hash" "--cfg $CFG" "$FINAL"
contains "  ...and the objective it cites" "--shape chat --level 16" "$FINAL"

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
