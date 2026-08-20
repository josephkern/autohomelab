#!/usr/bin/env bash
# eval_private_selftest.sh — acceptance suite for the TIER-4 PRIVATE eval (docs/private-eval.md).
#
# Runs entirely on synthetic sets and stub servers. No docker, no serve, no lm-eval, no GPU: the
# box is a shared single-GPU lab. Sections E and G start stdlib http.servers on loopback so the
# DEFAULT urllib transport (the code path a real run takes) is executed, not just the
# `AHL_PRIVATE_TRANSPORT` seam.
#
# This repo has shipped three correct-looking guards sitting in unreachable branches (the
# reasoning x spec-decode branch-order bug; contract A10). So every check below EXECUTES the
# shipped script and reads its exit code and the row it wrote. A substring grep is not a test.
#
# READ THIS BEFORE ADDING A CHECK. An earlier version of this file passed 139/139 while an
# adversarial verifier walked twelve leakage paths through the layer it was testing — four of them
# HIGH. Every one of those paths was a shape the suite never constructed: it tested that the guard
# blocked the ONE file the guard was written against, that the loopback refusal rejected the ONE
# string it was written against, and that the bundle held no item text on the ONE code path that
# wrote it. Green meant "the examples I thought of behave", which is not what a security control
# needs to be asked. Section G is one check per closed path, each of which FAILED before its fix.
#
# Sections:
#   A  set schema     — validate accepts the example, rejects each malformed shape
#   B  graders        — exact / contains / regex / numeric / must_not_contain, incl. normalisation
#   C  eval_private.sh end to end — present, ABSENT, malformed, model answers nothing, transport
#                       failures, signal, burned items, LIMIT, the 16-column row, exit ladder
#   D  leakage        — no item text anywhere under the bundle; transcripts opt in, outside the repo
#   E  transport      — the real urllib path against a loopback stub server
#   F  guard          — the pre-commit guard blocks a staged private set and allows the example
#   G  the twelve closed leak paths — each check is red without its fix
#
#   scripts/eval_private_selftest.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PY="${AHL_PYTHON:-python3}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ahl-private-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }
chk(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 -- expected [$2] got [$3]"; fi; }
chk_has(){ case "$3" in *"$2"*) ok "$1" ;; *) no "$1 -- [$2] not in [$3]" ;; esac; }
chk_hasnt(){ case "$3" in *"$2"*) no "$1 -- [$2] IS present in [$3]" ;; *) ok "$1" ;; esac; }

CANARY="CANARY-DO-NOT-LEAK-8f31"     # stands in for a real question's text
GOODSALT="selftest-salt-0123456789abcdefghijklmnopqrstuv"

# ── synthetic set writer ──────────────────────────────────────────────────────
# Items are token-echo tasks: the prompt carries TOK%03d and the grader wants exactly that back.
# The stub model can therefore answer correctly WITHOUT the fixture and the stub sharing a table,
# and every prompt carries the canary so section D can prove no prompt text reaches the bundle.
MKSET="$WORK/mkset.py"
cat > "$MKSET" <<PYEOF
import json, os, sys
d, n, vis = sys.argv[1], int(sys.argv[2]), (sys.argv[3] if len(sys.argv) > 3 else "private")
burned = int(sys.argv[4]) if len(sys.argv) > 4 else 0
unchecked = int(sys.argv[5]) if len(sys.argv) > 5 else 0
salt = sys.argv[6] if len(sys.argv) > 6 else "$GOODSALT"
os.makedirs(d, exist_ok=True)
json.dump({"schema": "ahl-private-eval/1", "set_id": "selftest", "visibility": vis,
           "salt": salt, "authored": "20260820",
           "champion": {"model": "selftest/Fake-0B", "runbook": "runbooks/x.sh",
                        "date": "20260820"}},
          open(os.path.join(d, "manifest.json"), "w"))
with open(os.path.join(d, "items.jsonl"), "w") as f:
    f.write(json.dumps({"schema": "ahl-private-eval/1", "kind": "header",
                        "marker": "AHL-PRIVATE-EVAL-ITEMS", "visibility": vis}) + "\n")
    for i in range(1, n + 1):
        it = {"id": "S-%03d" % i,
              "prompt": "$CANARY item %d. Reply with the token TOK%03d and nothing else." % (i, i),
              "grader": {"type": "exact", "answers": ["TOK%03d" % i]}}
        if i > unchecked:
            it["checked"] = {"verdict": "pass", "date": "20260820"}
        if i <= burned:
            it["burned"] = {"date": "20260820", "reason": "selftest"}
        f.write(json.dumps(it) + "\n")
PYEOF
mkset(){ "$PY" "$MKSET" "$@"; }

# ── the stub model (AHL_PRIVATE_TRANSPORT seam) ───────────────────────────────
STUB="$WORK/stub_model.sh"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
req="$(cat)"
tok="$(printf '%s' "$req" | grep -o 'TOK[0-9][0-9][0-9]' | head -1)"
out="$tok"
extra=""
case "${AHL_STUB_MODE:-correct}" in
  correct) : ;;
  empty)   out="" ;;
  reasoning) out=""; extra=',"reasoning_content":"I thought about it at length."' ;;
  reasoning1) if [ "$tok" = TOK001 ]; then out=""; extra=',"reasoning_content":"thinking"'; fi ;;
  wrong)   out="nope" ;;
  flaky)   n="${tok#TOK}"; [ "$((10#$n))" -le 4 ] && exit 1 ;;   # 4 items never answer
  # SIGTERM the python runner itself. NOT $PPID: subprocess.run(shell=True) puts an `sh -c`
  # between us and python, so killing the parent only kills that shell and python sees a
  # transport error instead of a signal.
  # Match THIS run's set directory (mktemp-unique), not every private runner on the box: two
  # copies of this suite running at once — which is exactly what a mutation harness does — used to
  # SIGTERM each other and produce phantom exit-3 failures in unrelated checks.
  signal)  pkill -TERM -f "eval_private_set.py run --set ${AHL_PRIVATE_EVAL_DIR:-/nonexistent} " 2>/dev/null ;;
esac
printf '{"choices":[{"message":{"content":%s%s}}]}' "$(printf '%s' "$out" | "${AHL_SELFTEST_PY:-python3}" -c 'import json,sys;print(json.dumps(sys.stdin.read()))')" "$extra"
EOF
chmod +x "$STUB"

# -- fixture builder -----------------------------------------------------------
# Every item-shaped and transcript-shaped fixture below is GENERATED, never written literally into
# this file. That is not tidiness: `scripts/eval_private_set.py sniff` is supposed to recognise
# exactly these shapes, and a test file carrying 22 literal item records is indistinguishable from
# a leak. The guard blocked this very file when the fixtures were inline -- correctly -- so the
# fixtures moved out and the guard's own suite no longer trips it. (Section G7 asserts that.)
FIX="$WORK/fixtures.py"
cat > "$FIX" <<'PYFIXEOF'
import base64, json, sys

MARK = "AHL-PRIVATE-EVAL" + "-ITEMS"
SCHEMA = "ahl-private-eval/1"


def item(i, grader=None, prompt=None):
    return {"id": "F-%03d" % i, "prompt": prompt or ("a real unpublished question %d" % i),
            "grader": grader or {"type": "exact", "answers": ["x"]}}


def header(vis="private"):
    return {"schema": SCHEMA, "kind": "header", "marker": MARK, "visibility": vis}


def transcript(i, marked=True):
    r = {"id": "h1-%03d" % i, "verdict": "fail" if i % 2 else "pass",
         "prompt": "a real unpublished question %d" % i, "output": "the model answer"}
    if marked:
        r.update(schema=SCHEMA, kind="transcript", marker=MARK)
    return r


def jl(recs):
    return "".join(json.dumps(r) + "\n" for r in recs)


shape = sys.argv[1]
out = ""
if shape == "grader":                      # a single item with a named grader, for section B
    kind = sys.argv[2]
    g = {"exact": {"type": "exact", "answers": ["grelk"]},
         "num0": {"type": "numeric", "answer": 7, "tol": 0},
         "num1234": {"type": "numeric", "answer": 1234, "tol": 0},
         "regex": {"type": "regex", "pattern": r"^\s*ochre,\s*slate,\s*teal\s*$"},
         "contains": {"type": "contains", "answers": ["Barrundo"],
                      "must_not_contain": ["as an AI"]},
         "mnc": {"type": "contains", "answers": ["ok"],
                 "must_not_contain": ["SECRET-ANSWER-PHRASE"]}}[kind]
    out = json.dumps({"id": "x", "prompt": "p", "grader": g})
elif shape == "header_items_example":
    out = jl([header("example")] + [item(i) for i in range(2)])
elif shape == "prose_items":
    out = "here are the items I drafted today, keeping them for later\n" + \
          jl([item(i) for i in range(2)])
elif shape == "md_items":
    out = ("# Draft items\n\nI like these, will move them out of the tree tomorrow:\n\n" +
           "```\n" + jl([item(i) for i in range(2)]) + "```\n")
elif shape == "array_items":
    out = json.dumps([item(i) for i in range(2)], indent=1)
elif shape == "nested_items":
    out = json.dumps({"note": "scratch", "payload": {"items": [item(i) for i in range(2)]}})
elif shape == "csv_items":
    out = "id,prompt,answer\nh1-001,a real unpublished question,grelk\nh2,another real one,x\n"
elif shape == "b64_items":
    inner = jl([header()] + [item(i) for i in range(5)])
    out = "backup blob:\n" + base64.b64encode(inner.encode()).decode() + "\n"
elif shape == "marker_prose":
    out = "Remember the guard looks for %s in staged blobs.\n" % MARK
elif shape == "plain_prose":
    out = "The GB10 wedge is tracked upstream as vLLM issue #43885.\n"
elif shape == "one_item":
    out = json.dumps(item(0))
elif shape == "transcripts_marked":
    out = jl([transcript(i) for i in range(2)])
elif shape == "transcripts_bare":
    out = jl([transcript(i, marked=False) for i in range(2)])
elif shape == "many_items":
    out = "# notes\n\n" + jl([item(i) for i in range(12)])
elif shape == "big_items":                 # > 256 KiB: forty 4K-token long-context items
    out = jl([header()] + [item(i, prompt="q " * 4000) for i in range(40)])
elif shape == "late_items":                # evidence only AFTER the first 256 KiB
    out = ("# scratch notes\n" + ("filler line that says nothing at all\n" * 8000)
           + jl([header()] + [item(i) for i in range(5)]))
elif shape == "append_items":              # items appended to an existing file
    out = jl([item(i) for i in range(40)])
elif shape == "one_appended_item":
    out = json.dumps(item(99)) + "\n"
else:
    raise SystemExit("unknown shape %s" % shape)
sys.stdout.write(out)
PYFIXEOF
fix(){ "$PY" "$FIX" "$@"; }

echo "=== A. set schema (scripts/eval_private_set.py validate) ====================="
V(){ "$PY" "$SCRIPT_DIR/eval_private_set.py" validate --set "$1" 2>&1; }
OUT="$(V "$REPO_ROOT/evalsets/private-example")"; RC=$?
chk "committed example set validates" 0 "$RC"
chk_has "example: set_id + fingerprint reported" "set_id=example-fake" "$OUT"
chk_has "example: burned item is counted separately" "live=3 burned=1" "$OUT"
chk_has "example: warns it is below the item floor" "below AHL_PRIVATE_MIN_ITEMS" "$OUT"

mkset "$WORK/good" 40; OUT="$(V "$WORK/good")"; RC=$?
chk "40-item synthetic set validates" 0 "$RC"
chk_hasnt "40 items is above the floor: no small-n warning" "AHL_PRIVATE_MIN_ITEMS" "$OUT"

# every malformed shape must be REFUSED (exit 2), never silently partially loaded
mal(){ # mal <label> <mutation-python>
  rm -rf "$WORK/mal"; mkset "$WORK/mal" 5
  "$PY" - "$WORK/mal" <<PYEOF
import json, sys
d = sys.argv[1]
$2
PYEOF
  OUT="$(V "$WORK/mal")"; RC=$?
  chk "malformed refused: $1 (exit 2)" 2 "$RC"
  MALMSG="$OUT"
}
mal "items.jsonl line is not JSON" 'open(d+"/items.jsonl","a").write("{not json\n")'
chk_has "  ... and says which line" "items.jsonl:7" "$MALMSG"
mal "manifest is not JSON" 'open(d+"/manifest.json","w").write("{")'
mal "wrong schema version" 'm=json.load(open(d+"/manifest.json")); m["schema"]="other/9"; json.dump(m,open(d+"/manifest.json","w"))'
mal "visibility not private|example" 'm=json.load(open(d+"/manifest.json")); m["visibility"]="public"; json.dump(m,open(d+"/manifest.json","w"))'
mal "empty salt" 'm=json.load(open(d+"/manifest.json")); m["salt"]=""; json.dump(m,open(d+"/manifest.json","w"))'
mal "missing items header record" 'ls=open(d+"/items.jsonl").read().splitlines(True); open(d+"/items.jsonl","w").writelines(ls[1:])'
mal "header visibility disagrees with manifest" 'ls=open(d+"/items.jsonl").read().splitlines(True); h=json.loads(ls[0]); h["visibility"]="example"; ls[0]=json.dumps(h)+"\n"; open(d+"/items.jsonl","w").writelines(ls)'
mal "duplicate item id" 'ls=open(d+"/items.jsonl").read().splitlines(True); open(d+"/items.jsonl","a").write(ls[1])'
mal "unknown grader type" 'ls=open(d+"/items.jsonl").read().splitlines(True); r=json.loads(ls[1]); r["grader"]={"type":"llm_judge"}; ls[1]=json.dumps(r)+"\n"; open(d+"/items.jsonl","w").writelines(ls)'
mal "grader regex does not compile" 'ls=open(d+"/items.jsonl").read().splitlines(True); r=json.loads(ls[1]); r["grader"]={"type":"regex","pattern":"([a"}; ls[1]=json.dumps(r)+"\n"; open(d+"/items.jsonl","w").writelines(ls)'
mal "empty prompt" 'ls=open(d+"/items.jsonl").read().splitlines(True); r=json.loads(ls[1]); r["prompt"]="  "; ls[1]=json.dumps(r)+"\n"; open(d+"/items.jsonl","w").writelines(ls)'
mal "missing manifest.json" 'import os; os.remove(d+"/manifest.json")'
mal "no manifest.champion" 'm=json.load(open(d+"/manifest.json")); del m["champion"]; json.dump(m,open(d+"/manifest.json","w"))'
chk_has "  ... and explains why attribution is required" "attributed" "$MALMSG"
mal "champion left as a placeholder" 'm=json.load(open(d+"/manifest.json")); m["champion"]["model"]="<FILL ME>"; json.dump(m,open(d+"/manifest.json","w"))'
mal "checked.verdict is not pass|fail" 'ls=open(d+"/items.jsonl").read().splitlines(True); r=json.loads(ls[1]); r["checked"]={"verdict":"maybe"}; ls[1]=json.dumps(r)+"\n"; open(d+"/items.jsonl","w").writelines(ls)'

echo
echo "=== B. graders =============================================================="
G(){ "$PY" -c "
import json, sys
sys.path.insert(0, '$SCRIPT_DIR')
import eval_private_set as ps
item = json.loads(sys.argv[1])
p, why = ps.grade(item, sys.argv[2])
print(('pass' if p else 'fail') + ':' + why)
" "$1" "$2"; }
EX="$(fix grader exact)"
chk "exact: bare answer"            pass:exact "$(G "$EX" 'grelk')"
chk "exact: normalises case/punct/bold" pass:exact "$(G "$EX" '**Grelk.**')"
chk "exact: last line of a chatty answer" pass:exact "$(G "$EX" 'Let me think.
grelk')"
chk "exact: wrong answer fails"      fail:exact "$(G "$EX" 'kessel')"
chk "exact: empty content fails as empty_content" fail:empty_content "$(G "$EX" '')"
NUM="$(fix grader num0)"
chk "numeric: last number"           pass:numeric "$(G "$NUM" 'the profit is 7 credits')"
chk "numeric: prefers \\boxed"        pass:numeric "$(G "$NUM" 'first 21 then 14, so \boxed{7} credits')"
chk "numeric: thousands separators"  pass:numeric "$(G "$(fix grader num1234)" 'answer: 1,234')"
chk "numeric: wrong number fails"    fail:numeric "$(G "$NUM" '12')"
chk "numeric: no number at all"      fail:no_number "$(G "$NUM" 'I cannot say')"
RE="$(fix grader regex)"
chk "regex: matches"                 pass:regex "$(G "$RE" 'ochre, slate, teal')"
chk "regex: extra prose fails"       fail:regex "$(G "$RE" 'Sure! ochre, slate, teal')"
CON="$(fix grader contains)"
chk "contains: substring"            pass:contains "$(G "$CON" 'It is Barrundo, the doubled r.')"
chk_has "must_not_contain vetoes even a correct answer" "fail:must_not_contain" "$(G "$CON" 'as an AI I should say Barrundo')"

echo
echo "=== C. eval_private.sh end to end ==========================================="
# Sandbox repo: eval_private.sh derives REPO_ROOT from its own path, so symlinking it into a fake
# tree redirects every write. Nothing touches the real results/.
SBX="$WORK/sbx"; mkdir -p "$SBX/scripts" "$SBX/results/testfp" "$SBX/runbooks"
echo '{"gpu":{"mem_bw_gbs":273}}' > "$SBX/results/testfp/node_profile.json"
for f in eval_private.sh eval_private_set.py eval_validity.py migrate_accuracy_tsv.py; do
  ln -sf "$SCRIPT_DIR/$f" "$SBX/scripts/$f"
done
printf 'MODEL="acme/Stub-7B"\nSERVED_NAME="stub"\n' > "$SBX/runbooks/rb.sh"
TSV="$SBX/results/testfp/acme/Stub-7B/accuracy.tsv"

run_priv(){ # run_priv <mode> <set-dir> [extra env ...] -> RC, ROW, ERR
  local mode="$1" setd="$2"; shift 2
  RC=0
  ERR="$(env AHL_PYTHON="$PY" AHL_SELFTEST_PY="$PY" AHL_PRIVATE_TRANSPORT="$STUB" \
      AHL_STUB_MODE="$mode" AHL_PRIVATE_EVAL_DIR="$setd" "$@" \
      "$SBX/scripts/eval_private.sh" "$SBX/runbooks/rb.sh" 2>&1 >/dev/null)" || RC=$?
  ROW="$(tail -1 "$TSV" 2>/dev/null || echo)"
}

# --- the set is PRESENT and the model answers correctly ---------------------
run_priv correct "$WORK/good"
chk "present + all correct: exit 0 (citable)" 0 "$RC"
chk "row is 16 columns" 16 "$(echo "$ROW" | awk -F'\t' '{print NF}')"
chk "header matches eval_validity.py accuracy-header EXACTLY" \
    "$("$PY" "$SCRIPT_DIR/eval_validity.py" accuracy-header)" "$(head -1 "$TSV")"
chk "suite column marks the row an ATTESTATION" private-attest "$(echo "$ROW" | cut -f7)"
chk_has "tasks column carries set id + fingerprint" "private_selftest." "$(echo "$ROW" | cut -f8)"
chk "samples are effective/requested" "private_selftest.$(echo "$ROW" | cut -f8 | cut -d. -f2)=40/40" "$(echo "$ROW" | cut -f14)"
chk "validity ok" ok "$(echo "$ROW" | cut -f15)"
chk "status measured" measured "$(echo "$ROW" | cut -f16)"
chk "conc recorded" 1 "$(echo "$ROW" | cut -f13)"
chk "think recorded" on "$(echo "$ROW" | cut -f12)"
GOODROWS="$(wc -l < "$TSV")"

# --- the set is ABSENT: the common case for anyone who clones this repo -------
N_BEFORE="$(wc -l < "$TSV")"
run_priv correct "$WORK/nonexistent-set"
chk "ABSENT set: exit 1 (fail closed, never 0)" 1 "$RC"
chk "ABSENT set: no row is written" "$N_BEFORE" "$(wc -l < "$TSV")"
chk_has "ABSENT set: explains rather than crashes" "no private eval set is installed" "$ERR"
chk_has "ABSENT set: names where it looked" "$WORK/nonexistent-set" "$ERR"
chk_has "ABSENT set: says GATE NOT RUN, never PASS" "GATE NOT RUN" "$ERR"
chk_hasnt "ABSENT set: no shell error leaks out (1/2)" "No such file or directory" "$ERR"
chk_hasnt "ABSENT set: no shell error leaks out (2/2)" "command not found" "$ERR"
# and with NO env at all it must still fail closed, not fall back to something
RC=0; ERR="$(env -u AHL_PRIVATE_EVAL_DIR AHL_PYTHON="$PY" HOME="$WORK/emptyhome" \
    XDG_DATA_HOME="$WORK/emptyhome/.local/share" \
    "$SBX/scripts/eval_private.sh" "$SBX/runbooks/rb.sh" 2>&1 >/dev/null)" || RC=$?
chk "ABSENT set (default location, unset env): exit 1" 1 "$RC"
chk_has "ABSENT set: default location is outside the repo" "/.local/share/autohomelab/private-eval" "$ERR"

# --- a MALFORMED set is refused before any request is made -------------------
rm -rf "$WORK/malrun"; mkset "$WORK/malrun" 40
printf '{"id":"broken"\n' >> "$WORK/malrun/items.jsonl"
N_BEFORE="$(wc -l < "$TSV")"
run_priv correct "$WORK/malrun"
chk "MALFORMED set: exit 2 (refused)" 2 "$RC"
chk "MALFORMED set: no row is written" "$N_BEFORE" "$(wc -l < "$TSV")"
chk_has "MALFORMED set: explains the population argument" "not a set" "$ERR"
chk "MALFORMED set: no bundle left behind" 0 "$(find "$SBX/results/testfp/acme/Stub-7B/data" -maxdepth 1 -name '*-private' -newer "$WORK/malrun/manifest.json" 2>/dev/null | wc -l)"

# --- the model answers NOTHING ----------------------------------------------
run_priv empty "$WORK/good"
chk "model answers nothing: exit 4 (row written, not citable)" 4 "$RC"
chk_has "model answers nothing: zero_score, task-tagged" "zero_score@private_selftest." "$(echo "$ROW" | cut -f15)"
chk "model answers nothing: status suspect" suspect "$(echo "$ROW" | cut -f16)"
chk_has "model answers nothing: all 40 were still graded" "=40/40" "$(echo "$ROW" | cut -f14)"

# --- the model answers WRONG (a real, low score) -----------------------------
run_priv wrong "$WORK/good"
chk "all wrong but non-empty: exit 4 (0.0 is still suspect)" 4 "$RC"
chk_has "all wrong: reason is exact-match failure, not empty" "zero_score" "$(echo "$ROW" | cut -f15)"

# --- transport failures shrink the population -------------------------------
run_priv flaky "$WORK/good"
chk "4 of 40 items never answered: exit 4" 4 "$RC"
chk_has "flaky: samples show 36/40" "=36/40" "$(echo "$ROW" | cut -f14)"
chk_has "flaky: short_sample (the SHIPPED Gate-2 rule, not a copy)" "short_sample@private_selftest." "$(echo "$ROW" | cut -f15)"
chk "flaky: status void" void "$(echo "$ROW" | cut -f16)"

# --- killed by a signal ------------------------------------------------------
N_BEFORE="$(wc -l < "$TSV")"
run_priv signal "$WORK/good"
chk "killed by SIGTERM: exit 3" 3 "$RC"
chk "killed by SIGTERM: no row (a partial private run is not a measurement)" "$N_BEFORE" "$(wc -l < "$TSV")"
chk_has "killed by SIGTERM: says so" "killed by a signal" "$ERR"

# --- burned items ------------------------------------------------------------
mkset "$WORK/burned" 40 private 6
run_priv correct "$WORK/burned"
chk "burned items excluded: exit 0" 0 "$RC"
chk_has "burned: population is the 34 live items" "=34/34" "$(echo "$ROW" | cut -f14)"
chk_has "burned: the exclusion is announced" "marked burned were excluded" "$ERR"

# --- the small example set can never mint a citable row ----------------------
run_priv correct "$REPO_ROOT/evalsets/private-example"
chk "committed EXAMPLE set: exit 4, never citable" 4 "$RC"
chk_has "example: small_n token" "small_n@private_example-fake." "$(echo "$ROW" | cut -f15)"
chk "example: status suspect" suspect "$(echo "$ROW" | cut -f16)"
chk_has "example: the n=20 SE is quoted in the reason" "binomial SE is ~11 points" "$ERR"
chk_has "example: says out loud that it is fake" "COMMITTED EXAMPLE set" "$ERR"

# --- AHL_PRIVATE_MIN_ITEMS binds (an unmoveable rule is an untested rule) ----
run_priv correct "$WORK/good" AHL_PRIVATE_MIN_ITEMS=41
chk "MIN_ITEMS=41 turns the 40-item set suspect" 4 "$RC"
chk_has "MIN_ITEMS: small_n fires" "small_n@" "$(echo "$ROW" | cut -f15)"
# small_n in isolation: a 3-item set the stub CAN answer, so nothing else fires
mkset "$WORK/tiny" 3
run_priv correct "$WORK/tiny"
chk "3-item set, all correct: exit 4 on small_n alone" 4 "$RC"
chk_has "tiny: small_n is the ONLY token" "small_n@private_selftest." "$(echo "$ROW" | cut -f15)"
chk "tiny: status suspect" suspect "$(echo "$ROW" | cut -f16)"
run_priv correct "$WORK/tiny" AHL_PRIVATE_MIN_ITEMS=1
chk "MIN_ITEMS=1 clears small_n on the same 3-item set" 0 "$RC"
chk "MIN_ITEMS=1: validity ok" ok "$(echo "$ROW" | cut -f15)"

# --- LIMIT ------------------------------------------------------------------
run_priv correct "$WORK/good" LIMIT=35 AHL_PRIVATE_MIN_ITEMS=5
chk "LIMIT=35: exit 0" 0 "$RC"
chk_has "LIMIT=35: requested count follows the limit" "=35/35" "$(echo "$ROW" | cut -f14)"
chk "LIMIT=35: the limit column records it" 35 "$(echo "$ROW" | cut -f9)"

# --- a private set INSIDE the repo is refused -------------------------------
mkdir -p "$SBX/evalsets"; mkset "$SBX/evalsets/inrepo" 40 private
N_BEFORE="$(wc -l < "$TSV")"
run_priv correct "$SBX/evalsets/inrepo"
chk "a private set INSIDE the repo: exit 2" 2 "$RC"
chk "in-repo private set: no row" "$N_BEFORE" "$(wc -l < "$TSV")"
chk_has "in-repo private set: says move it out" "inside this PUBLIC repo" "$ERR"

# --- a non-loopback TARGET is refused ---------------------------------------
N_BEFORE="$(wc -l < "$TSV")"
run_priv correct "$WORK/good" TARGET=http://93.184.216.34:8000
chk "remote TARGET: exit 2 (refused)" 2 "$RC"
chk "remote TARGET: no requests, no row" "$N_BEFORE" "$(wc -l < "$TSV")"
chk_has "remote TARGET: explains WHY" "publication with extra steps" "$ERR"
run_priv correct "$WORK/good" TARGET=http://127.0.0.1:8000
chk "loopback TARGET is allowed" 0 "$RC"
run_priv correct "$WORK/good" TARGET="http://[::1]:8000"
chk "IPv6 loopback is allowed too" 0 "$RC"
run_priv correct "$WORK/good" TARGET=http://93.184.216.34:8000 AHL_PRIVATE_ALLOW_REMOTE=1
chk "remote TARGET with the explicit override: runs" 0 "$RC"
chk_has "remote override still warns" "could retain" "$ERR"

# --- the encrypted-at-rest path ---------------------------------------------
mkdir -p "$WORK/xdgrt"
( cd "$WORK/good" && tar -cf "$WORK/good.tar" manifest.json items.jsonl )
RC=0
ERR="$(env AHL_PYTHON="$PY" AHL_SELFTEST_PY="$PY" AHL_PRIVATE_TRANSPORT="$STUB" AHL_STUB_MODE=correct \
    AHL_PRIVATE_EVAL_DIR="$WORK/nonexistent-set" XDG_RUNTIME_DIR="$WORK/xdgrt" \
    AHL_PRIVATE_EVAL_DECRYPT="cat '$WORK/good.tar'" \
    "$SBX/scripts/eval_private.sh" "$SBX/runbooks/rb.sh" 2>&1 >/dev/null)" || RC=$?
chk "AHL_PRIVATE_EVAL_DECRYPT: a tar stream is unpacked and run" 0 "$RC"
chk "decrypted set is not left on disk afterwards" 0 "$(find "$WORK/xdgrt" -maxdepth 1 -name 'ahl-private.*' 2>/dev/null | wc -l)"
RC=0
ERR="$(env AHL_PYTHON="$PY" AHL_PRIVATE_EVAL_DIR="$WORK/nonexistent-set" \
    XDG_RUNTIME_DIR="$WORK/xdgrt" AHL_PRIVATE_EVAL_DECRYPT="false" \
    "$SBX/scripts/eval_private.sh" "$SBX/runbooks/rb.sh" 2>&1 >/dev/null)" || RC=$?
chk "a FAILED decrypt fails closed (exit 1, no row)" 1 "$RC"
chk_has "failed decrypt says so" "could not be decrypted" "$ERR"

echo
echo "=== D. leakage: what reaches results/**/data/ ==============================="
run_priv correct "$WORK/good"
BUN="$SBX/$(echo "$ROW" | cut -f11)"
chk "bundle path recorded in the row exists" 1 "$([ -d "$BUN" ] && echo 1 || echo 0)"
HITS="$(grep -rl "$CANARY" "$BUN" 2>/dev/null | wc -l)"
chk "NO prompt text anywhere under the bundle" 0 "$HITS"
HITS="$(grep -rl "TOK0" "$BUN" 2>/dev/null | wc -l)"
chk "NO answer text anywhere under the bundle" 0 "$HITS"
chk_has "the bundle DOES carry the per-item verdict bitmap" '"verdict": "pass"' "$(cat "$BUN/private/items.audit.jsonl")"
chk_has "... with a salted prompt digest for provenance" '"prompt_sha"' "$(cat "$BUN/private/items.audit.jsonl")"
D1="$("$PY" -c "
import json,sys
sys.path.insert(0,'$SCRIPT_DIR'); import eval_private_set as ps
print(ps._digest('salt-a','the question'), ps._digest('salt-b','the question'))")"
chk "the digest is SALTED (same prompt, different salt -> different digest)" \
    "differ" "$(set -- $D1; [ "$1" != "$2" ] && echo differ || echo same)"
# transcripts: opt-in, outside the repo, 0600
run_priv correct "$WORK/good" AHL_PRIVATE_KEEP_TRANSCRIPT=1
BUN="$SBX/$(echo "$ROW" | cut -f11)"
TR="$WORK/good/transcripts"
chk "transcripts opt-in: written into the PRIVATE set dir" 1 "$([ -d "$TR" ] && echo 1 || echo 0)"
chk_has "transcripts contain the prompts (that is their purpose)" "$CANARY" "$(cat "$TR"/*.jsonl)"
chk "transcript file is mode 0600" 600 "$(stat -c '%a' "$TR"/*.jsonl | head -1)"
chk "transcripts are NOT inside the repo/bundle" 0 "$(grep -rl "$CANARY" "$BUN" 2>/dev/null | wc -l)"
chk_has "the bundle records only the transcript PATH" '"transcript"' "$(cat "$BUN"/stub/results_*.json)"

echo
echo "=== E. the REAL urllib transport (loopback stub server, no GPU) ============="
SRV="$WORK/server.py"
cat > "$SRV" <<'PYEOF'
import json, os, re, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

MODE = os.environ.get("AHL_SRV_MODE", "answer")
LOG = os.environ.get("AHL_SRV_LOG")

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0))).decode()
        if LOG:
            with open(LOG, "a") as f:
                f.write(self.path + "\n" + body + "\n")
        if MODE == "proxy":
            # A proxy sees an absolute-form request line. Answer plausibly so a leak is SILENT,
            # exactly as a real logging proxy would be.
            out = json.dumps({"choices": [{"message": {"content": "PROXIED"}}]}).encode()
        elif MODE == "echo400":
            # An echoing gateway: the error body contains the request. This box runs LiteLLM.
            self.send_response(400)
            self.send_header("content-type", "application/json")
            msg = json.dumps({"error": {"message": "bad request: " + body[:400]}}).encode()
            self.send_header("content-length", str(len(msg)))
            self.end_headers(); self.wfile.write(msg); return
        else:
            if self.path not in ("/v1/chat/completions",) and not self.path.endswith("/v1/chat/completions"):
                self.send_response(404); self.end_headers(); self.wfile.write(b"{}"); return
            m = re.search(r"TOK\d{3}", body)
            out = json.dumps({"choices": [{"message": {"content": m.group(0) if m else ""}}]}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(out)))
        self.end_headers(); self.wfile.write(out)

srv = HTTPServer(("127.0.0.1", 0), H)
print(srv.server_port, flush=True)
srv.serve_forever()
PYEOF
start_srv(){ # start_srv <portfile> [env ...] -> echoes pid
  local portfile="$1"; shift
  env "$@" "$PY" "$SRV" > "$portfile" 2>/dev/null &
  local pid=$!
  for _ in $(seq 1 100); do [ -s "$portfile" ] && break; sleep 0.05; done
  echo "$pid"
}
SRV_PID="$(start_srv "$WORK/port")"
PORT="$(cat "$WORK/port" 2>/dev/null)"
if [ -n "$PORT" ]; then
  RC=0
  ERR="$(env AHL_PYTHON="$PY" AHL_PRIVATE_EVAL_DIR="$WORK/good" TARGET="http://127.0.0.1:$PORT" CONC=4 \
      "$SBX/scripts/eval_private.sh" "$SBX/runbooks/rb.sh" 2>&1 >/dev/null)" || RC=$?
  ROW="$(tail -1 "$TSV")"
  chk "default urllib transport (no seam): exit 0" 0 "$RC"
  chk_has "default transport: 40/40 answered over real HTTP" "=40/40" "$(echo "$ROW" | cut -f14)"
  chk "CONC=4 is recorded" 4 "$(echo "$ROW" | cut -f13)"
  # a dead endpoint is transport failure on every item -> no score, not a zero
  kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null
  RC=0
  ERR="$(env AHL_PYTHON="$PY" AHL_PRIVATE_EVAL_DIR="$WORK/good" TARGET="http://127.0.0.1:$PORT" \
      AHL_PRIVATE_TIMEOUT=2 "$SBX/scripts/eval_private.sh" "$SBX/runbooks/rb.sh" 2>&1 >/dev/null)" || RC=$?
  ROW="$(tail -1 "$TSV")"
  chk "dead endpoint: exit 4 (row written, not citable)" 4 "$RC"
  chk_has "dead endpoint: no_score, NOT a 0.0 quality result" "no_score@private_selftest." "$(echo "$ROW" | cut -f15)"
  chk "dead endpoint: status void" void "$(echo "$ROW" | cut -f16)"
else
  no "loopback stub server did not start (section E skipped)"
  kill "$SRV_PID" 2>/dev/null
fi

echo
echo "=== F. the pre-commit guard ================================================="
GSBX="$WORK/gsbx"; mkdir -p "$GSBX/scripts" "$GSBX/evalsets"
git init -q "$GSBX" >/dev/null 2>&1
git -C "$GSBX" config user.email t@example.com; git -C "$GSBX" config user.name t
ln -sf "$SCRIPT_DIR/eval_private.sh" "$GSBX/scripts/eval_private.sh"
ln -sf "$SCRIPT_DIR/eval_private_set.py" "$GSBX/scripts/eval_private_set.py"
GUARD(){ RC=0; ERR="$(env AHL_PYTHON="$PY" "$@" "$GSBX/scripts/eval_private.sh" guard 2>&1)" || RC=$?; }
gstage(){ git -C "$GSBX" add -Af -- "$@" >/dev/null 2>&1; }
greset(){ git -C "$GSBX" reset -q >/dev/null 2>&1; }

GUARD; chk "guard with nothing staged: exit 0" 0 "$RC"

cp -r "$REPO_ROOT/evalsets/private-example" "$GSBX/evalsets/"
gstage evalsets/private-example
GUARD; chk "guard ALLOWS the blessed example set (path + digest)" 0 "$RC"

# REGRESSION: the first guard grepped for the marker string and blocked this repo's OWN docs,
# self-test and helper — all of which merely mention it. A guard that fires on its own
# documentation is one the next operator switches off.
mkdir -p "$GSBX/docs"
cp "$REPO_ROOT/docs/private-eval.md" "$GSBX/docs/" 2>/dev/null
cp "$SCRIPT_DIR/eval_private_set.py" "$SCRIPT_DIR/eval_private_selftest.sh" "$GSBX/scripts/" 2>/dev/null
git -C "$GSBX" add -A >/dev/null 2>&1
GUARD
chk "guard does NOT block docs/code that merely MENTION the marker" 0 "$RC"
greset
rm -f "$GSBX/scripts/eval_private_set.py" "$GSBX/scripts/eval_private_selftest.sh"
ln -sf "$SCRIPT_DIR/eval_private_set.py" "$GSBX/scripts/eval_private_set.py"

mkset "$GSBX/evalsets/oops" 3 private
git -C "$GSBX" add -A >/dev/null 2>&1
GUARD
chk "guard BLOCKS a staged visibility=private items file" 1 "$RC"
chk_has "guard names the manifest too" "evalsets/oops/manifest.json" "$ERR"
chk_has "guard names the offending file" "evalsets/oops/items.jsonl" "$ERR"
chk_has "guard explains that history keeps the blob" "stays in the history" "$ERR"
chk_has "guard tells you where to put it instead" ".local/share/autohomelab/private-eval" "$ERR"
chk_has "guard tells an AGENT not to reach for --no-verify" "do not retry this with" "$ERR"
GUARD AHL_PRIVATE_GUARD_ALLOW=1
chk "guard override exists and is loud" 0 "$RC"
chk_has "guard override announces itself" "OVERRIDDEN" "$ERR"

greset
: > "$GSBX/secrets.tar.age"; git -C "$GSBX" add -f secrets.tar.age >/dev/null 2>&1
GUARD; chk "guard BLOCKS a staged *.age blob by filename" 1 "$RC"

greset
RC=0; ERR="$(env AHL_PYTHON="$PY" "$GSBX/scripts/eval_private.sh" install-guard 2>&1)" || RC=$?
chk "install-guard writes the hooks" 0 "$RC"
chk "the installed pre-commit hook is executable" 1 "$([ -x "$GSBX/.git/hooks/pre-commit" ] && echo 1 || echo 0)"
chk "install-guard also writes pre-push (an agent may retry with --no-verify)" 1 \
    "$([ -x "$GSBX/.git/hooks/pre-push" ] && echo 1 || echo 0)"
mkset "$GSBX/evalsets/oops2" 3 private
git -C "$GSBX" add -A >/dev/null 2>&1
RC=0; ERR="$(cd "$GSBX" && AHL_PYTHON="$PY" git commit -m nope 2>&1)" || RC=$?
chk "the INSTALLED hook actually blocks a real commit" 1 "$RC"
chk_has "... with the guard's message" "REFUSING" "$ERR"
RC=0; ERR="$(env AHL_PYTHON="$PY" "$GSBX/scripts/eval_private.sh" install-guard 2>&1)" || RC=$?
chk "install-guard refuses to clobber an existing hook (exit 2)" 2 "$RC"
greset

echo
echo "=== G. the twelve closed leak paths ========================================="
echo "--- G1 (HIGH): http_proxy exfiltrates every prompt --------------------------"
# BEFORE: urllib.request.urlopen honours http_proxy and does NOT bypass it for loopback, and the
# refusal inspected the TARGET STRING. Every prompt landed verbatim in the proxy's log while the
# run reported success. AFTER: the opener is built with ProxyHandler({}) and the connected peer is
# re-checked, so the proxy sees nothing.
: > "$WORK/proxy.log"
PXY_PID="$(start_srv "$WORK/pxyport" AHL_SRV_MODE=proxy AHL_SRV_LOG="$WORK/proxy.log")"
PXYPORT="$(cat "$WORK/pxyport" 2>/dev/null)"
SRV_PID="$(start_srv "$WORK/port2")"
PORT2="$(cat "$WORK/port2" 2>/dev/null)"
if [ -n "$PXYPORT" ] && [ -n "$PORT2" ]; then
  RC=0
  ERR="$(env AHL_PYTHON="$PY" AHL_PRIVATE_EVAL_DIR="$WORK/good" TARGET="http://127.0.0.1:$PORT2" \
      http_proxy="http://127.0.0.1:$PXYPORT" HTTP_PROXY="http://127.0.0.1:$PXYPORT" \
      ALL_PROXY="http://127.0.0.1:$PXYPORT" \
      "$SBX/scripts/eval_private.sh" "$SBX/runbooks/rb.sh" 2>&1 >/dev/null)" || RC=$?
  ROW="$(tail -1 "$TSV")"
  chk "G1: the run still succeeds with http_proxy set" 0 "$RC"
  chk "G1: the PROXY received nothing at all" 0 "$(wc -c < "$WORK/proxy.log" | tr -d ' ')"
  chk_hasnt "G1: no prompt text in the proxy log" "$CANARY" "$(cat "$WORK/proxy.log")"
  chk_has "G1: the operator is told the proxy env is ignored" "It is IGNORED" "$ERR"
  chk_has "G1: answers came from the real endpoint, not the proxy" "=40/40" "$(echo "$ROW" | cut -f14)"
else
  no "G1: could not start the proxy/target stubs"
fi
kill "$PXY_PID" "$SRV_PID" 2>/dev/null

echo "--- G2 (HIGH): visibility:\"example\" defeated all three defences ------------"
# BEFORE: copying evalsets/private-example (which the runner's own help text told you to do) kept
# `visibility: example`, and that ONE self-declared field simultaneously disabled the in-repo
# refusal, missed every .gitignore pattern and exempted the file from the guard. 36 real items ran
# and staged with `guard: ok`. AFTER: item-shaped content is PRIVATE by default and the example is
# identified by exact path + content digest.
cp -r "$REPO_ROOT/evalsets/private-example" "$WORK/copied"
fix append_items >> "$WORK/copied/items.jsonl"
OUT="$(V "$WORK/copied")"; RC=$?
chk "G2: an edited copy of the example is REFUSED, not treated as an example" 2 "$RC"
chk_has "G2: ... and says why" "not the blessed example set" "$OUT"
# ...and the same copy, staged, is blocked by the guard
mkdir -p "$GSBX/evalsets/copied"
cp "$WORK/copied/items.jsonl" "$WORK/copied/manifest.json" "$GSBX/evalsets/copied/"
gstage evalsets/copied
GUARD; chk "G2: the guard BLOCKS a copied-and-edited example set" 1 "$RC"
greset; rm -rf "$GSBX/evalsets/copied"
# ...and an edit AT the blessed path stops being blessed
cp -r "$REPO_ROOT/evalsets/private-example" "$GSBX/evalsets/" 2>/dev/null
fix one_appended_item >> "$GSBX/evalsets/private-example/items.jsonl"
gstage evalsets/private-example
GUARD; chk "G2: one appended item to the blessed example file BLOCKS it" 1 "$RC"
chk_has "G2: ... naming the reason" "CHANGED contents" "$ERR"
greset
rm -rf "$GSBX/evalsets/private-example"
cp -r "$REPO_ROOT/evalsets/private-example" "$GSBX/evalsets/"
# ...and .gitignore now covers a brand-new directory under evalsets/
chk "G2: .gitignore ignores a NEW directory under evalsets/" "evalsets/newset/items.jsonl" \
    "$(cd "$REPO_ROOT" && git check-ignore -q evalsets/newset/items.jsonl && echo evalsets/newset/items.jsonl)"
chk "G2: ... while the blessed example stays tracked" "" \
    "$(cd "$REPO_ROOT" && git check-ignore evalsets/private-example/items.jsonl 2>/dev/null)"

echo "--- G3 (HIGH): the published example salt was the inherited default ---------"
# BEFORE: explain_absent told you to copy the example manifest, nothing rejected its published
# salt, and a 1-character salt validated. A digest was reconstructed from a guessed question with
# no access to the set at all.
rm -rf "$WORK/saltbad"; mkset "$WORK/saltbad" 40 private 0 0 "EXAMPLE-SALT-PUBLISHED-ON-PURPOSE-NEVER-REUSE-THIS"
OUT="$(V "$WORK/saltbad")"; RC=$?
chk "G3: the PUBLISHED example salt is rejected by value" 2 "$RC"
chk_has "G3: ... and names the oracle it would create" "confirmation oracle" "$OUT"
rm -rf "$WORK/saltshort"; mkset "$WORK/saltshort" 40 private 0 0 "x"
OUT="$(V "$WORK/saltshort")"; RC=$?
chk "G3: a 1-character salt is rejected" 2 "$RC"
chk_has "G3: ... with the floor stated" "the floor is 32" "$OUT"
rm -rf "$WORK/saltpad"; mkset "$WORK/saltpad" 40 private 0 0 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
chk "G3: 36 chars of padding is rejected as not-entropy" 2 "$(V "$WORK/saltpad" >/dev/null 2>&1; echo $?)"
RC=0; OUT="$(env AHL_PYTHON="$PY" "$SCRIPT_DIR/eval_private.sh" init "$WORK/inited" 2>&1)" || RC=$?
chk "G3: init creates a set" 0 "$RC"
chk "G3: init's salt is >= 32 chars" 1 \
    "$("$PY" -c "import json,sys;print(1 if len(json.load(open(sys.argv[1]))['salt'])>=32 else 0)" "$WORK/inited/manifest.json")"
chk "G3: init's manifest is mode 0600" 600 "$(stat -c '%a' "$WORK/inited/manifest.json")"
chk "G3: init never overwrites an existing set" 2 \
    "$(env AHL_PYTHON="$PY" "$SCRIPT_DIR/eval_private.sh" init "$WORK/inited" >/dev/null 2>&1; echo $?)"
chk "G3: init REFUSES a directory inside the repo" 2 \
    "$(env AHL_PYTHON="$PY" "$SCRIPT_DIR/eval_private.sh" init "$REPO_ROOT/evalsets/nope" >/dev/null 2>&1; echo $?)"
chk "G3: ... and created nothing there" 0 "$([ -e "$REPO_ROOT/evalsets/nope" ] && echo 1 || echo 0)"
chk_hasnt "G3: the absent-set help no longer says to copy the example manifest" \
    "cp evalsets/private-example" "$(env AHL_PYTHON="$PY" AHL_PRIVATE_EVAL_DIR="$WORK/nope" \
      "$SBX/scripts/eval_private.sh" "$SBX/runbooks/rb.sh" 2>&1 >/dev/null)"

echo "--- G4 (HIGH): the guard failed OPEN ---------------------------------------"
# BEFORE: sniff's stderr was discarded and ANY non-zero exit read as "not private", so
# AHL_PYTHON=/bin/false printed `guard: ok` over a verbatim staged set. And
# `git show ":$f" | head -c 262144 | sniff` killed git with SIGPIPE under `pipefail` -> exit 141
# -> "not private", so any items file over 256 KiB walked straight through.
greset
mkset "$GSBX/evalsets/oops3" 3 private
gstage evalsets/oops3
GUARD AHL_PYTHON=/bin/false
chk "G4: a broken interpreter BLOCKS the commit (fails closed)" 1 "$RC"
chk_has "G4: ... and says the guard could not start" "could not start" "$ERR"
greset; rm -rf "$GSBX/evalsets/oops3"
# a >256 KiB items file (twenty 4K-token long-context items is ~320 KB — a class the docs
# recommend authoring)
fix big_items > "$GSBX/big-items.jsonl"
chk "G4: the oversize fixture really is > 256 KiB" 1 \
    "$([ "$(wc -c < "$GSBX/big-items.jsonl")" -gt 262144 ] && echo 1 || echo 0)"
gstage big-items.jsonl
GUARD; chk "G4: a 320 KB items file is BLOCKED (no SIGPIPE truncation)" 1 "$RC"
greset; rm -f "$GSBX/big-items.jsonl"
# ...and the guard reads the WHOLE blob, not a prefix: this file is innocuous for its first
# ~300 KB and only then carries the items. A `head -c 262144` guard sees nothing at all.
fix late_items > "$GSBX/late-items.jsonl"
chk "G4: the late-evidence fixture really hides the items past 256 KiB" 1 \
    "$("$PY" -c "
import sys
d = open(sys.argv[1], 'rb').read()
print(1 if (len(d) > 262144 and b'\"grader\"' not in d[:262144]) else 0)" "$GSBX/late-items.jsonl")"
gstage late-items.jsonl
GUARD; chk "G4: evidence past the old 256 KiB cut-off is still found" 1 "$RC"
greset; rm -f "$GSBX/late-items.jsonl"

echo "--- G5 (MED): item text and HTTP bodies in the bundle -----------------------"
# BEFORE: grade() wrote `must_not_contain:<first 24 chars of the author's forbidden string>` into
# items.audit.jsonl, and _http_chat put 200 characters of the HTTP error body into the exception,
# 120 of which reached the audit. Against an echoing gateway (this box runs LiteLLM) that error
# body IS the question for a short item.
MNC="$(fix grader mnc)"
chk "G5: must_not_contain records an INDEX, not the author's string" "fail:must_not_contain:0" \
    "$(G "$MNC" 'the SECRET-ANSWER-PHRASE is ok')"
E4_PID="$(start_srv "$WORK/e4port" AHL_SRV_MODE=echo400)"
E4PORT="$(cat "$WORK/e4port" 2>/dev/null)"
if [ -n "$E4PORT" ]; then
  RC=0
  ERR="$(env AHL_PYTHON="$PY" AHL_PRIVATE_EVAL_DIR="$WORK/good" TARGET="http://127.0.0.1:$E4PORT" \
      "$SBX/scripts/eval_private.sh" "$SBX/runbooks/rb.sh" 2>&1 >/dev/null)" || RC=$?
  ROW="$(tail -1 "$TSV")"
  BUN="$SBX/$(echo "$ROW" | cut -f11)"
  AUD="$(cat "$BUN/private/items.audit.jsonl" 2>/dev/null)"
  chk_hasnt "G5: an echoing 400 body does NOT reach the audit file" "$CANARY" "$AUD"
  chk_hasnt "G5: ... not even the echoed token" "TOK0" "$AUD"
  chk_has "G5: what IS recorded is a code plus a body hash" "transport:http_400." "$AUD"
  chk_hasnt "G5: the echoed body is not printed to the terminal either" "$CANARY" "$ERR"
  chk_has "G5: the terminal says the body was withheld" "body withheld" "$ERR"
else
  no "G5: could not start the echo400 stub"
fi
kill "$E4_PID" 2>/dev/null

echo "--- G6 (MED): the guard was blind to transcripts ----------------------------"
# BEFORE: a transcript is the one artefact that is PURE item text, and sniff did not know its
# shape. Worse, AHL_PRIVATE_KEEP_TRANSCRIPT=1 was a silent no-op under the recommended
# encrypted-at-rest workflow (written into the tmpfs that is deleted on exit), which pushes an
# operator to relocate it — and the obvious place is beside the code.
fix transcripts_marked > "$GSBX/debug-notes.jsonl"
gstage debug-notes.jsonl
GUARD; chk "G6: the guard BLOCKS a transcript file" 1 "$RC"
greset; rm -f "$GSBX/debug-notes.jsonl"
# even with the schema/marker stripped, the record SHAPE is recognised
fix transcripts_bare > "$GSBX/notes.jsonl"
gstage notes.jsonl
GUARD; chk "G6: ... recognised by SHAPE alone, with no marker present" 1 "$RC"
greset; rm -f "$GSBX/notes.jsonl"
# a transcript directory inside the repo is refused outright
RC=0
ERR="$(env AHL_PYTHON="$PY" AHL_SELFTEST_PY="$PY" AHL_PRIVATE_TRANSPORT="$STUB" AHL_STUB_MODE=correct \
    AHL_PRIVATE_EVAL_DIR="$WORK/good" AHL_PRIVATE_KEEP_TRANSCRIPT=1 \
    AHL_PRIVATE_TRANSCRIPT_DIR="$REPO_ROOT/evalsets/leaky-transcripts" \
    "$SBX/scripts/eval_private.sh" "$SBX/runbooks/rb.sh" 2>&1 >/dev/null)" || RC=$?
chk "G6: a transcript dir INSIDE the repo is refused (exit 2)" 2 "$RC"
chk_has "G6: ... and says it is pure item text" "pure item text" "$ERR"
chk "G6: ... and nothing was written there" 0 "$([ -e "$REPO_ROOT/evalsets/leaky-transcripts" ] && echo 1 || echo 0)"
# under the decrypt workflow the transcript goes somewhere DURABLE, not into the doomed tmpfs
rm -rf "$WORK/durable"
RC=0
ERR="$(env AHL_PYTHON="$PY" AHL_SELFTEST_PY="$PY" AHL_PRIVATE_TRANSPORT="$STUB" AHL_STUB_MODE=correct \
    AHL_PRIVATE_EVAL_DIR="$WORK/nonexistent-set" XDG_RUNTIME_DIR="$WORK/xdgrt" \
    XDG_DATA_HOME="$WORK/durable" AHL_PRIVATE_KEEP_TRANSCRIPT=1 \
    AHL_PRIVATE_EVAL_DECRYPT="cat '$WORK/good.tar'" \
    "$SBX/scripts/eval_private.sh" "$SBX/runbooks/rb.sh" 2>&1 >/dev/null)" || RC=$?
chk "G6: decrypt + KEEP_TRANSCRIPT still exits 0" 0 "$RC"
chk "G6: the transcript survives the tmpfs teardown (was a silent no-op)" 1 \
    "$(ls "$WORK/durable/autohomelab/private-eval-transcripts/"*.jsonl >/dev/null 2>&1 && echo 1 || echo 0)"
chk_has "G6: ... and the operator is told it is plaintext" "PLAINTEXT ITEMS" "$ERR"
chk "G6: scrub deletes it" 0 \
    "$(env AHL_PYTHON="$PY" XDG_DATA_HOME="$WORK/durable" AHL_PRIVATE_EVAL_DIR="$WORK/good" \
        "$SCRIPT_DIR/eval_private.sh" scrub >/dev/null 2>&1; ls "$WORK/durable/autohomelab/private-eval-transcripts/"*.jsonl 2>/dev/null | wc -l)"

echo "--- G7 (MED): guard coverage was 2 of 11 realistic shapes -------------------"
SNIFF(){ # SNIFF <file> <repo-relative-path> -> RC + SOUT
  SOUT="$("$PY" "$SCRIPT_DIR/eval_private_set.py" sniff --file "$1" --path "$2" 2>&1)"; SRC=$?
}
shape(){ # shape <label> <expected-tier> <path> <fixture-name>
  local label="$1" want="$2" p="$3"
  fix "$4" > "$WORK/shape.dat"
  SNIFF "$WORK/shape.dat" "$p"
  case "$want" in
    hard)  chk "G7: $label -> HARD block" 0 "$SRC"; chk_has "G7: $label tier" "PRIVATE	hard" "$SOUT" ;;
    weak)  chk "G7: $label -> weak warning" 0 "$SRC"; chk_has "G7: $label tier" "PRIVATE	weak" "$SOUT" ;;
    clean) chk "G7: $label -> clean" 1 "$SRC"; chk_has "G7: $label tier" "CLEAN" "$SOUT" ;;
  esac
}
shape "header record with visibility:example at a non-blessed path" hard "evalsets/x/items.jsonl" header_items_example
shape "one prose line prepended to an items file" hard "notes/x.jsonl" prose_items
shape "items pasted into markdown prose"          hard "research/notes.md"  md_items
shape "a JSON array of items"                     hard "research/items.json" array_items
shape "items nested under an unrelated key"       hard "research/x.json"    nested_items
shape "a CSV of prompts and answers"              weak "research/items.csv" csv_items
shape "base64-encoded items"                      hard "research/backup.txt" b64_items
chk_has "G7: ... and the base64 leg is named" "b64=True" "$SOUT"
shape "the marker string in prose"                weak "research/notes.md"  marker_prose
shape "ordinary prose"                            clean "research/notes.md" plain_prose
shape "one item-shaped object alone"              weak "research/x.json"    one_item
# the allowlist keeps the guard off its own documentation, but is not a hiding place
SNIFF "$REPO_ROOT/docs/private-eval.md" "docs/private-eval.md"
chk "G7: the shipped docs are CLEAN under the allowlist" 1 "$SRC"
SNIFF "$SCRIPT_DIR/eval_private_selftest.sh" "scripts/eval_private_selftest.sh"
chk "G7: this self-test is CLEAN under the allowlist" 1 "$SRC"
SNIFF "$SCRIPT_DIR/eval_private_set.py" "scripts/eval_private_set.py"
chk "G7: the helper module is CLEAN under the allowlist" 1 "$SRC"
fix many_items > "$WORK/hidden.md"
SNIFF "$WORK/hidden.md" "docs/hidden.md"
chk "G7: docs/ is NOT a hiding place — 12 items blocks" 0 "$SRC"
chk_has "G7: ... naming the budget" "documentation budget" "$SOUT"
# the weak tier has its own narrower override
greset
fix csv_items > "$GSBX/items.csv"
gstage items.csv
GUARD; chk "G7: weak evidence blocks by default" 1 "$RC"
GUARD AHL_PRIVATE_GUARD_SOFT_OK=1
chk "G7: ... and has a narrow override that does NOT disable the hard tier" 0 "$RC"
rm -f "$GSBX/items.csv"; greset
mkset "$GSBX/evalsets/oops4" 3 private
gstage evalsets/oops4
GUARD AHL_PRIVATE_GUARD_SOFT_OK=1
chk "G7: the soft override does NOT let a real set through" 1 "$RC"
greset; rm -rf "$GSBX/evalsets/oops4"
# pre-push, because the hook is per-clone and an agent that hits a block may retry --no-verify
mkset "$GSBX/evalsets/pushed" 3 private
gstage evalsets/pushed
git -C "$GSBX" commit -q --no-verify -m "sneaked past pre-commit" >/dev/null 2>&1
LOCAL_SHA="$(git -C "$GSBX" rev-parse HEAD)"
RC=0
ERR="$(printf 'refs/heads/main %s refs/heads/main %s\n' "$LOCAL_SHA" "0000000000000000000000000000000000000000" \
    | env AHL_PYTHON="$PY" "$GSBX/scripts/eval_private.sh" guard-push 2>&1)" || RC=$?
chk "G7: pre-push catches a set that got past pre-commit" 1 "$RC"
chk_has "G7: ... naming the file" "evalsets/pushed/items.jsonl" "$ERR"
git -C "$GSBX" reset -q --hard HEAD~1 >/dev/null 2>&1 || git -C "$GSBX" update-ref -d HEAD

echo "--- G8 (MED): loopback was matched by string prefix -------------------------"
CT(){ RC=0; ERR="$(env AHL_PYTHON="$PY" "$PY" "$SCRIPT_DIR/eval_private_set.py" check-target --target "$1" 2>&1)" || RC=$?; }
CT 'http://127.0.0.1@93.184.216.34:8000'
chk "G8: userinfo 127.0.0.1@<remote> is REFUSED (was allowed)" 2 "$RC"
CT 'http://127.0.0.1.evil.example:8000'
chk "G8: wildcard-DNS 127.0.0.1.<domain> is REFUSED (was allowed)" 2 "$RC"
CT 'http://[::ffff:127.0.0.1]:8000'
chk "G8: IPv4-mapped IPv6 loopback is ALLOWED (was refused)" 0 "$RC"
CT 'http://localhost.:8000'
chk "G8: the fully-qualified 'localhost.' is ALLOWED (was refused)" 0 "$RC"
CT 'http://LOCALHOST:8000'
chk "G8: uppercase LOCALHOST is ALLOWED (was refused)" 0 "$RC"
CT 'http://2130706433:8000'
chk "G8: the integer form of 127.0.0.1 is ALLOWED (was refused)" 0 "$RC"
CT 'http://127.0.0.1:8000'; chk "G8: plain loopback still allowed" 0 "$RC"
CT 'http://[::1]:8000';     chk "G8: ::1 still allowed" 0 "$RC"
CT 'http://93.184.216.34:8000'; chk "G8: a plain remote IP is refused" 2 "$RC"
chk_has "G8: ... explaining that the host TEXT is irrelevant" "host TEXT is irrelevant" "$ERR"
CT 'ftp://127.0.0.1/x'; chk "G8: a non-http scheme is refused" 2 "$RC"

echo "--- G9 (MED): SIGKILL leaves the decrypted set AND the salt behind ----------"
# SIGKILL cannot be trapped. What CAN be done: pin the unpack to tmpfs, record an owner pid, and
# sweep orphans on the next invocation. The residual window is documented, not hidden.
mkdir -p "$WORK/xdgrt2"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$WORK/slowstub.sh"; chmod +x "$WORK/slowstub.sh"
env AHL_PYTHON="$PY" AHL_SELFTEST_PY="$PY" AHL_PRIVATE_TRANSPORT="$WORK/slowstub.sh" \
  AHL_PRIVATE_EVAL_DIR="$WORK/nonexistent-set" XDG_RUNTIME_DIR="$WORK/xdgrt2" \
  AHL_PRIVATE_EVAL_DECRYPT="cat '$WORK/good.tar'" \
  "$SBX/scripts/eval_private.sh" "$SBX/runbooks/rb.sh" >/dev/null 2>&1 &
KILLME=$!
for _ in $(seq 1 100); do
  [ -n "$(find "$WORK/xdgrt2" -maxdepth 1 -name 'ahl-private.*' 2>/dev/null)" ] && break; sleep 0.05
done
kill -9 "$KILLME" 2>/dev/null; wait "$KILLME" 2>/dev/null
LEFT="$(find "$WORK/xdgrt2" -maxdepth 1 -name 'ahl-private.*' 2>/dev/null | wc -l)"
chk "G9: SIGKILL does leave the decrypted set behind (honest, documented)" 1 "$LEFT"
chk "G9: the orphan records an owner pid so it can be swept" 1 \
    "$(find "$WORK/xdgrt2" -maxdepth 2 -name '.owner-pid' | wc -l)"
env AHL_PYTHON="$PY" XDG_RUNTIME_DIR="$WORK/xdgrt2" AHL_PRIVATE_EVAL_DIR="$WORK/good" \
  "$SCRIPT_DIR/eval_private.sh" scrub >/dev/null 2>&1
chk "G9: the next invocation SWEEPS the orphaned plaintext set (and its salt)" 0 \
    "$(find "$WORK/xdgrt2" -maxdepth 1 -name 'ahl-private.*' 2>/dev/null | wc -l)"
RC=0
ERR="$(env AHL_PYTHON="$PY" AHL_PRIVATE_EVAL_DIR="$WORK/nonexistent-set" \
    AHL_PRIVATE_EVAL_DECRYPT="cat '$WORK/good.tar'" \
    env -u XDG_RUNTIME_DIR "$SBX/scripts/eval_private.sh" "$SBX/runbooks/rb.sh" 2>&1 >/dev/null)" || RC=$?
chk "G9: with no XDG_RUNTIME_DIR the decrypt REFUSES rather than unpacking to disk" 1 "$RC"
chk_has "G9: ... and says why" "ORDINARY DISK" "$ERR"
chk_has "G9: the SIGKILL residue is documented" "SIGKILL" "$(cat "$REPO_ROOT/docs/private-eval.md")"

echo "--- G10: the authority problem ----------------------------------------------"
# BEFORE: an absolute percentage was computed automatically, printed as the headline, and written
# into column 10 of a COMMITTED, PUBLIC accuracy.tsv, while the correct paired reading required
# hand-counting discordants out of a file nothing in the repo read. A number that exists is quoted.
run_priv correct "$WORK/good"
chk "G10: column 10 is na -- the absolute score is not committed" na "$(echo "$ROW" | cut -f10)"
chk_hasnt "G10: the percentage is not printed as a headline either" "100.0" "$ERR"
chk_has "G10: the row is labelled an attestation, not a measurement" "ATTESTATION" "$ERR"
chk_has "G10: the operator is pointed at compare" "eval_private.sh compare" "$ERR"
BUN_A="$SBX/$(echo "$ROW" | cut -f11)"
run_priv correct "$WORK/good"
BUN_B="$SBX/$(echo "$ROW" | cut -f11)"
RC=0; OUT="$(env AHL_PYTHON="$PY" "$SCRIPT_DIR/eval_private.sh" compare "$BUN_A" "$BUN_B" 2>&1)" || RC=$?
chk "G10: compare on two identical runs: no break" 0 "$RC"
chk_has "G10: ... and prints the one-sentence verdict" "no class-level break against the champion" "$OUT"
chk_has "G10: ... with b/c and p" "b/c = 0/0" "$OUT"
# a class-sized, one-directional break
"$PY" - "$BUN_B/private/items.audit.jsonl" <<'PYEOF'
import json, sys
p = sys.argv[1]
rows = [json.loads(l) for l in open(p) if l.strip()]
for r in rows[:6]:
    r["verdict"] = "fail"; r["reason"] = "exact"
open(p, "w").write("".join(json.dumps(r, sort_keys=True) + "\n" for r in rows))
PYEOF
RC=0; OUT="$(env AHL_PYTHON="$PY" "$SCRIPT_DIR/eval_private.sh" compare "$BUN_A" "$BUN_B" 2>&1)" || RC=$?
chk "G10: 6-vs-0 discordants: compare reports a BREAK (exit 4)" 4 "$RC"
chk_has "G10: ... with the exact p" "p = 0.031" "$OUT"
chk_has "G10: ... and the direction caveat the docs got wrong" "6/1 is p=0.125" "$OUT"
"$PY" - "$BUN_B/private/items.audit.jsonl" <<'PYEOF'
import json, sys
p = sys.argv[1]
rows = [json.loads(l) for l in open(p) if l.strip()]
rows[-1]["verdict"] = "fail"
open(p, "w").write("".join(json.dumps(r, sort_keys=True) + "\n" for r in rows))
PYEOF
"$PY" - "$BUN_A/private/items.audit.jsonl" <<'PYEOF'
import json, sys
p = sys.argv[1]
rows = [json.loads(l) for l in open(p) if l.strip()]
rows[-1]["verdict"] = "fail"
open(p, "w").write("".join(json.dumps(r, sort_keys=True) + "\n" for r in rows))
PYEOF
"$PY" - "$BUN_A/private/items.audit.jsonl" <<'PYEOF'
import json, sys
p = sys.argv[1]
rows = [json.loads(l) for l in open(p) if l.strip()]
rows[7]["verdict"] = "fail"          # one discordant the OTHER way -> 6 vs 1
open(p, "w").write("".join(json.dumps(r, sort_keys=True) + "\n" for r in rows))
PYEOF
RC=0; OUT="$(env AHL_PYTHON="$PY" "$SCRIPT_DIR/eval_private.sh" compare "$BUN_A" "$BUN_B" 2>&1)" || RC=$?
chk "G10: 6-vs-1 is NOT significant — direction matters, not count (exit 0)" 0 "$RC"
chk_has "G10: ... p = 0.125" "p = 0.125" "$OUT"
chk "G10: the exact McNemar p is right for 8 vs 2" "0.1094" \
    "$("$PY" -c "import sys;sys.path.insert(0,'$SCRIPT_DIR');import eval_private_set as ps;print('%.4f'%ps._mcnemar_exact_p(8,2))")"
chk "G10: ... and for 6 vs 0" "0.0312" \
    "$("$PY" -c "import sys;sys.path.insert(0,'$SCRIPT_DIR');import eval_private_set as ps;print('%.4f'%ps._mcnemar_exact_p(6,0))")"
chk_has "G10: the docs state the direction rule" "6-vs-1" "$(cat "$REPO_ROOT/docs/private-eval.md")"

echo "--- G11: the gate cannot be debugged by its only worker ---------------------"
DOC="$(cat "$REPO_ROOT/docs/private-eval.md")"
chk_has "G11: the agent-operator conflict is stated, not left as an unobeyable warning" \
    "operated by AI agents" "$DOC"
chk_has "G11: ... and named as structural" "structural conflict" "$DOC"

echo "--- G12: nobody can check the ground truth ----------------------------------"
chk_has "G12: the docs say the row is an ATTESTATION, not a measurement" "attestation" "$DOC"
chk_has "G12: ... and give guidance for a WRONG item, not just a burned one" "wrong item" "$DOC"
rm -rf "$WORK/unchecked"; mkset "$WORK/unchecked" 40 private 0 40
run_priv correct "$WORK/unchecked"
chk "G12: a set with no champion verdicts is NOT citable" 4 "$RC"
chk_has "G12: ... via the unchecked token" "unchecked@private_selftest." "$(echo "$ROW" | cut -f15)"
chk_has "G12: ... and says why attribution matters" "attributed" "$ERR"
rm -rf "$WORK/regress"; mkset "$WORK/regress" 40
run_priv wrong "$WORK/regress"
chk_has "G12: items the champion passed that now fail are named" "the champion passed at authoring now fail" "$ERR"
# grading `content` only: a model routing into reasoning_content scores 0 on everything, which is
# a serving defect masquerading as a quality regression
run_priv reasoning "$WORK/good"
chk "G12: an all-reasoning_content run is VOID, not a 0.0 quality result" 4 "$RC"
chk_has "G12: ... via reasoning_routed" "reasoning_routed@private_selftest." "$(echo "$ROW" | cut -f15)"
chk "G12: ... status void" void "$(echo "$ROW" | cut -f16)"
chk_has "G12: ... and names it a serving/template defect" "serving/template defect" "$ERR"
# ...but ONE empty answer that happens to carry reasoning is a truncation, not a routing defect
run_priv reasoning1 "$WORK/good"
chk_hasnt "G12: a SINGLE empty-with-reasoning answer does not void the run" \
    "reasoning_routed" "$(echo "$ROW" | cut -f15)"

echo
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
