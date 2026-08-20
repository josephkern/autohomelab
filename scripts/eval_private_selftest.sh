#!/usr/bin/env bash
# eval_private_selftest.sh — acceptance suite for the TIER-4 PRIVATE eval (docs/private-eval.md).
#
# Runs entirely on synthetic sets and a stub model. No docker, no serve, no lm-eval, no GPU: the
# box is a shared single-GPU lab. Section E is the one exception and it is still GPU-free — it
# starts a stdlib http.server on loopback so the DEFAULT urllib transport (the code path a real
# run takes) is executed, not just the `AHL_PRIVATE_TRANSPORT` seam.
#
# This repo has shipped three correct-looking guards sitting in unreachable branches (the
# reasoning x spec-decode branch-order bug; contract A10). So every check below EXECUTES the
# shipped script and reads its exit code and the row it wrote. A substring grep is not a test.
#
# Sections:
#   A  set schema     — validate accepts the example, rejects each malformed shape
#   B  graders        — exact / contains / regex / numeric / must_not_contain, incl. normalisation
#   C  eval_private.sh end to end — present, ABSENT, malformed, model answers nothing, transport
#                       failures, signal, burned items, LIMIT, the 16-column row, exit ladder
#   D  leakage        — no item text anywhere under the bundle; transcripts opt in, outside the repo
#   E  transport      — the real urllib path against a loopback stub server
#   F  guard          — the pre-commit guard blocks a staged private set and allows the example
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

# ── synthetic set writer ──────────────────────────────────────────────────────
# Items are token-echo tasks: the prompt carries TOK%03d and the grader wants exactly that back.
# The stub model can therefore answer correctly WITHOUT the fixture and the stub sharing a table,
# and every prompt carries the canary so section D can prove no prompt text reaches the bundle.
MKSET="$WORK/mkset.py"
cat > "$MKSET" <<PYEOF
import json, os, sys
d, n, vis = sys.argv[1], int(sys.argv[2]), (sys.argv[3] if len(sys.argv) > 3 else "private")
burned = int(sys.argv[4]) if len(sys.argv) > 4 else 0
os.makedirs(d, exist_ok=True)
json.dump({"schema": "ahl-private-eval/1", "set_id": "selftest", "visibility": vis,
           "salt": "selftest-salt", "authored": "20260820"},
          open(os.path.join(d, "manifest.json"), "w"))
with open(os.path.join(d, "items.jsonl"), "w") as f:
    f.write(json.dumps({"schema": "ahl-private-eval/1", "kind": "header",
                        "marker": "AHL-PRIVATE-EVAL-ITEMS", "visibility": vis}) + "\n")
    for i in range(1, n + 1):
        it = {"id": "S-%03d" % i,
              "prompt": "$CANARY item %d. Reply with the token TOK%03d and nothing else." % (i, i),
              "grader": {"type": "exact", "answers": ["TOK%03d" % i]}}
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
case "${AHL_STUB_MODE:-correct}" in
  correct) : ;;
  empty)   out="" ;;
  wrong)   out="nope" ;;
  flaky)   n="${tok#TOK}"; [ "$((10#$n))" -le 4 ] && exit 1 ;;   # 4 items never answer
  # SIGTERM the python runner itself. NOT $PPID: subprocess.run(shell=True) puts an `sh -c`
  # between us and python, so killing the parent only kills that shell and python sees a
  # transport error instead of a signal.
  signal)  pkill -TERM -f 'eval_private_set.py run' 2>/dev/null ;;
esac
printf '{"choices":[{"message":{"content":%s}}]}' "$(printf '%s' "$out" | "${AHL_SELFTEST_PY:-python3}" -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"
EOF
chmod +x "$STUB"

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
EX='{"id":"x","prompt":"p","grader":{"type":"exact","answers":["grelk"]}}'
chk "exact: bare answer"            pass:exact "$(G "$EX" 'grelk')"
chk "exact: normalises case/punct/bold" pass:exact "$(G "$EX" '**Grelk.**')"
chk "exact: last line of a chatty answer" pass:exact "$(G "$EX" 'Let me think.
grelk')"
chk "exact: wrong answer fails"      fail:exact "$(G "$EX" 'kessel')"
chk "exact: empty content fails as empty_content" fail:empty_content "$(G "$EX" '')"
NUM='{"id":"x","prompt":"p","grader":{"type":"numeric","answer":7,"tol":0}}'
chk "numeric: last number"           pass:numeric "$(G "$NUM" 'the profit is 7 credits')"
chk "numeric: prefers \\boxed"        pass:numeric "$(G "$NUM" 'first 21 then 14, so \boxed{7} credits')"
chk "numeric: thousands separators"  pass:numeric "$(G '{"id":"x","prompt":"p","grader":{"type":"numeric","answer":1234,"tol":0}}' 'answer: 1,234')"
chk "numeric: wrong number fails"    fail:numeric "$(G "$NUM" '12')"
chk "numeric: no number at all"      fail:no_number "$(G "$NUM" 'I cannot say')"
RE='{"id":"x","prompt":"p","grader":{"type":"regex","pattern":"^\\s*ochre,\\s*slate,\\s*teal\\s*$"}}'
chk "regex: matches"                 pass:regex "$(G "$RE" 'ochre, slate, teal')"
chk "regex: extra prose fails"       fail:regex "$(G "$RE" 'Sure! ochre, slate, teal')"
CON='{"id":"x","prompt":"p","grader":{"type":"contains","answers":["Barrundo"],"must_not_contain":["as an AI"]}}'
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
chk "suite column is `private`" private "$(echo "$ROW" | cut -f7)"
chk_has "tasks column carries set id + fingerprint" "private_selftest." "$(echo "$ROW" | cut -f8)"
chk_has "scores are task-tagged" "private_selftest." "$(echo "$ROW" | cut -f10)"
chk_has "score is 100" "=100.0" "$(echo "$ROW" | cut -f10)"
chk_has "samples are effective/requested" "=40/40" "$(echo "$ROW" | cut -f14)"
chk "validity ok" ok "$(echo "$ROW" | cut -f15)"
chk "status measured" measured "$(echo "$ROW" | cut -f16)"
chk "conc recorded" 1 "$(echo "$ROW" | cut -f13)"
chk "think recorded" on "$(echo "$ROW" | cut -f12)"
chk_has "even a citable row warns about n" "n is small" "$ERR"
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
chk_has "model answers nothing: score 0.0 recorded" "=0.0" "$(echo "$ROW" | cut -f10)"
chk_has "model answers nothing: zero_score, task-tagged" "zero_score@private_selftest." "$(echo "$ROW" | cut -f15)"
chk "model answers nothing: status suspect" suspect "$(echo "$ROW" | cut -f16)"
chk_has "model answers nothing: all 40 were still graded" "=40/40" "$(echo "$ROW" | cut -f14)"

# --- the model answers WRONG (a real, low, citable score) --------------------
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
chk "visibility=private INSIDE the repo: exit 2" 2 "$RC"
chk "in-repo private set: no row" "$N_BEFORE" "$(wc -l < "$TSV")"
chk_has "in-repo private set: says move it out" "inside this PUBLIC repo" "$ERR"

# --- a non-loopback TARGET is refused ---------------------------------------
N_BEFORE="$(wc -l < "$TSV")"
run_priv correct "$WORK/good" TARGET=https://api.example.com
chk "remote TARGET: exit 2 (refused)" 2 "$RC"
chk "remote TARGET: no requests, no row" "$N_BEFORE" "$(wc -l < "$TSV")"
chk_has "remote TARGET: explains WHY" "publication with extra steps" "$ERR"
run_priv correct "$WORK/good" TARGET=http://127.0.0.1:8000
chk "loopback TARGET is allowed" 0 "$RC"
run_priv correct "$WORK/good" TARGET="http://[::1]:8000"
chk "IPv6 loopback is allowed too" 0 "$RC"
run_priv correct "$WORK/good" TARGET=https://api.example.com AHL_PRIVATE_ALLOW_REMOTE=1
chk "remote TARGET with the explicit override: runs" 0 "$RC"
chk_has "remote override still warns" "could retain" "$ERR"

# --- the encrypted-at-rest path ---------------------------------------------
( cd "$WORK/good" && tar -cf "$WORK/good.tar" manifest.json items.jsonl )
RC=0
ERR="$(env AHL_PYTHON="$PY" AHL_SELFTEST_PY="$PY" AHL_PRIVATE_TRANSPORT="$STUB" AHL_STUB_MODE=correct \
    AHL_PRIVATE_EVAL_DIR="$WORK/nonexistent-set" \
    AHL_PRIVATE_EVAL_DECRYPT="cat '$WORK/good.tar'" \
    "$SBX/scripts/eval_private.sh" "$SBX/runbooks/rb.sh" 2>&1 >/dev/null)" || RC=$?
chk "AHL_PRIVATE_EVAL_DECRYPT: a tar stream is unpacked and run" 0 "$RC"
chk "decrypted set is not left on disk afterwards" 0 "$(find "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}" -maxdepth 1 -name 'ahl-private.*' 2>/dev/null | wc -l)"
RC=0
ERR="$(env AHL_PYTHON="$PY" AHL_PRIVATE_EVAL_DIR="$WORK/nonexistent-set" \
    AHL_PRIVATE_EVAL_DECRYPT="false" \
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
import json, re, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0))).decode()
        if self.path != "/v1/chat/completions":
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
"$PY" "$SRV" > "$WORK/port" 2>/dev/null &
SRV_PID=$!
for _ in $(seq 1 100); do [ -s "$WORK/port" ] && break; sleep 0.05; done
PORT="$(cat "$WORK/port" 2>/dev/null)"
if [ -n "$PORT" ]; then
  RC=0
  ERR="$(env AHL_PYTHON="$PY" AHL_PRIVATE_EVAL_DIR="$WORK/good" TARGET="http://127.0.0.1:$PORT" CONC=4 \
      "$SBX/scripts/eval_private.sh" "$SBX/runbooks/rb.sh" 2>&1 >/dev/null)" || RC=$?
  ROW="$(tail -1 "$TSV")"
  chk "default urllib transport (no seam): exit 0" 0 "$RC"
  chk_has "default transport: 40/40 answered over real HTTP" "=40/40" "$(echo "$ROW" | cut -f14)"
  chk_has "default transport: score 100" "=100.0" "$(echo "$ROW" | cut -f10)"
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
GUARD(){ RC=0; ERR="$("$GSBX/scripts/eval_private.sh" guard 2>&1)" || RC=$?; }

GUARD; chk "guard with nothing staged: exit 0" 0 "$RC"

cp -r "$REPO_ROOT/evalsets/private-example" "$GSBX/evalsets/"
git -C "$GSBX" add evalsets/private-example >/dev/null 2>&1
GUARD; chk "guard ALLOWS the visibility=example set" 0 "$RC"

# REGRESSION: the first guard grepped for the marker string and blocked this repo's OWN docs,
# self-test and helper — all of which merely mention it. A guard that fires on its own
# documentation is one the next operator switches off.
mkdir -p "$GSBX/docs"
cp "$REPO_ROOT/docs/private-eval.md" "$GSBX/docs/" 2>/dev/null
cp "$SCRIPT_DIR/eval_private_set.py" "$SCRIPT_DIR/eval_private_selftest.sh" "$GSBX/scripts/" 2>/dev/null
git -C "$GSBX" add -A >/dev/null 2>&1
GUARD
chk "guard does NOT block docs/code that merely MENTION the marker" 0 "$RC"
git -C "$GSBX" reset -q >/dev/null 2>&1
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
RC=0; ERR="$(AHL_PRIVATE_GUARD_ALLOW=1 "$GSBX/scripts/eval_private.sh" guard 2>&1)" || RC=$?
chk "guard override exists and is loud" 0 "$RC"
chk_has "guard override announces itself" "OVERRIDDEN" "$ERR"

git -C "$GSBX" reset -q >/dev/null 2>&1
: > "$GSBX/secrets.tar.age"; git -C "$GSBX" add -f secrets.tar.age >/dev/null 2>&1
GUARD; chk "guard BLOCKS a staged *.age blob by filename" 1 "$RC"

git -C "$GSBX" reset -q >/dev/null 2>&1
RC=0; ERR="$("$GSBX/scripts/eval_private.sh" install-guard 2>&1)" || RC=$?
chk "install-guard writes the hook" 0 "$RC"
chk "the installed hook is executable" 1 "$([ -x "$GSBX/.git/hooks/pre-commit" ] && echo 1 || echo 0)"
mkset "$GSBX/evalsets/oops2" 3 private
git -C "$GSBX" add -A >/dev/null 2>&1
RC=0; ERR="$(cd "$GSBX" && git commit -m nope 2>&1)" || RC=$?
chk "the INSTALLED hook actually blocks a real commit" 1 "$RC"
chk_has "... with the guard's message" "REFUSING THE COMMIT" "$ERR"
RC=0; ERR="$("$GSBX/scripts/eval_private.sh" install-guard 2>&1)" || RC=$?
chk "install-guard refuses to clobber an existing hook (exit 2)" 2 "$RC"

echo
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
