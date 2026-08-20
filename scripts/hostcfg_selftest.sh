#!/usr/bin/env bash
# hostcfg_selftest.sh — harness for the HOST-PROCESS `config_hash` (scripts/lib/hostcfg.sh).
#
#   scripts/hostcfg_selftest.sh [-v]
#
# Why this exists, and why it is not a unit test
# ----------------------------------------------
# This repo has a scar: three correct-looking guards have sat in unreachable branches, two of them
# carrying comments claiming otherwise (AGENTS.md, "A CORRECT CONDITION IN AN UNREACHABLE BRANCH" —
# confirming a guard's CONDITION fires is not the same as confirming its BRANCH is reachable).
# A config_hash is exactly the kind of thing that looks right by reading: it is an opaque 8 hex
# digits that nobody can eyeball, and the defect it is fixing (four ds4 gsm8k rows of
# 60.0/76.0/74.0/74.0 filed under one hash) was itself invisible for months.
#
# So this harness asserts on the COMPUTED VALUE, twice over:
#   Parts 1-6 drive the library against a FABRICATED /proc (AHL_PROC) — every case is a real
#            /proc/<pid>/cmdline, /proc/<pid>/environ and /proc/<pid>/exe written to a temp dir,
#            NUL-separated exactly as the kernel writes them, with REAL fixture files behind the
#            model and engine paths so the content-identity rule is exercised rather than faked.
#   Part 8   drives the REAL scripts/bench_ds4.sh, scripts/bench_llamacpp.sh **and scripts/eval.sh**
#            end-to-end inside throwaway repos, against a real background process whose argv
#            imitates the engine, with `uv`/`nvidia-smi`/`lm_eval` stubbed — and asserts on the
#            config_hash that lands in the results.tsv and accuracy.tsv ROWS, including that the
#            two journals agree. That is the reachability proof: the identity is not merely
#            correct, it is what executes and what gets written by BOTH gates.
#
# A NOTE ON THE PREVIOUS VERSION OF THIS FILE. It passed 46/46 while six defects were live, because
# every case it asked was a case the implementation was written to answer. Case 1005 went further
# and asserted a DEFECT as desired behaviour: it fed two nonexistent paths that shared a basename
# and demanded they collide, which is the same rule that made `snapshots/rev-AAAA/model.gguf` and
# `snapshots/rev-BBBB/model.gguf` — the ds4 checkpoint-refresh axis this library exists to separate
# — one config. Part 5 below is one case per defect, and each of them was negative-tested by
# reverting its fix and confirming this suite goes red.
#
# Hermetic by construction: no docker, no server, no guidellm, no real lm-eval, no GPU, no network.
# The only processes it starts are `sleep`s wearing an engine's argv.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
VERBOSE=0; [ "${1:-}" = "-v" ] && VERBOSE=1
PASS=0; FAIL=0
NODE_FP=gb10-test
DS4_RE='^(DS4_DSPARK|DS4_MTP)'
LCPP_RE='^(LLAMA_|GGML_)'
PY="${AHL_PYTHON:-python3}"

ok(){ PASS=$((PASS+1)); [ "$VERBOSE" = 1 ] && echo "  ok   $*"; return 0; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL $*"; return 0; }
check(){ # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected [$2], got [$3]"; fi; }
same(){ # same <desc> <a> <b>   — two hashes that MUST collide
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — hashes differ ($2 vs $3) but the config is identical"; fi; }
differ(){ # differ <desc> <a> <b> — two hashes that MUST NOT collide
  if [ "$2" != "$3" ]; then ok "$1"; else bad "$1 — COLLISION: both configs hash to $2"; fi; }
matches(){ # matches <desc> <ere> <value>
  if [[ "$3" =~ $2 ]]; then ok "$1"; else bad "$1 — [$3] does not match /$2/"; fi; }

WORK="$(mktemp -d)"
KILL_PIDS=()
cleanup(){ local p
           # Kill the wrapper's children FIRST: the fake server is a bash script whose `sleep`
           # child would otherwise be reparented to init and outlive the harness by 15 minutes.
           for p in ${KILL_PIDS[@]+"${KILL_PIDS[@]}"}; do
             pkill -P "$p" 2>/dev/null || true; kill "$p" 2>/dev/null || true
           done
           rm -rf "$WORK"; }
trap cleanup EXIT

# shellcheck disable=SC1091
source "$REAL_REPO/scripts/lib/hostcfg.sh"

# ── fixtures: REAL files, because identity is now about CONTENT ───────────────
# The pre-fix library reduced every value containing `/` to its basename, so it could be tested
# with paths that do not exist. That is precisely how it passed while collapsing two different
# checkpoints into one config. These are real files with real bytes:
#   build/a, build/b   two engine builds (different content)
#   opt/ds4-server     build/a INSTALLED SOMEWHERE ELSE — same bytes, different path
#   models/rev-AAAA/model.gguf, models/rev-BBBB/model.gguf
#                      the `huggingface-cli download` snapshot layout: SAME basename, different
#                      content. This is the ds4 round-3b checkpoint-refresh axis.
#   mnt/nvme/model.gguf  rev-AAAA relocated to another mount — same bytes, different path.
FIX="$WORK/fix"
mkdir -p "$FIX/build/a" "$FIX/build/b" "$FIX/opt" "$FIX/models/rev-AAAA" "$FIX/models/rev-BBBB" \
         "$FIX/mnt/nvme" "$FIX/llama/bin" "$FIX/llama/models"
BIN="$FIX/build/a/ds4-server";  printf 'ELF-ds4-build-b030961\n' > "$BIN"
BIN2="$FIX/build/b/ds4-server"; printf 'ELF-ds4-build-84cc882\n' > "$BIN2"
BINMOVED="$FIX/opt/ds4-server"; cp "$BIN" "$BINMOVED"
GG="$FIX/models/rev-AAAA/model.gguf";     printf 'GGUF-pre-0731-imatrix\n' > "$GG"
GG0731="$FIX/models/rev-BBBB/model.gguf"; printf 'GGUF-0731-refresh\n'     > "$GG0731"
GGMOVED="$FIX/mnt/nvme/model.gguf";       cp "$GG" "$GGMOVED"
SUPPORT="$FIX/models/support.gguf";       printf 'GGUF-dspark-support\n'   > "$SUPPORT"
LS="$FIX/llama/bin/llama-server";         printf 'ELF-llama-server\n'      > "$LS"
Q="$FIX/llama/models/Qwen3.6-27B-FF711-Q5_K_M.gguf"; printf 'GGUF-ff711-q5km\n' > "$Q"
chmod +x "$BIN" "$BIN2" "$BINMOVED" "$LS"

# ── fabricated /proc ──────────────────────────────────────────────────────────
# mkproc <pid> <env-block|NOENV> [--exe <path>] -- <argv...>
# env-block is newline-separated K=V (may be empty); NOENV omits the environ file entirely, which
# is how an unreadable environment presents to the library. --exe writes the /proc/<pid>/exe
# symlink the kernel provides; omitting it is how an exe we are not allowed to read presents.
mkproc(){
  local pid="$1" envs="$2"; shift 2
  local exe=""
  [ "${1:-}" = "--exe" ] && { exe="$2"; shift 2; }
  [ "${1:-}" = "--" ] && shift
  local d="$WORK/proc/$pid" a kv
  rm -rf "$d"; mkdir -p "$d"
  : > "$d/cmdline"; for a in "$@"; do printf '%s\0' "$a" >> "$d/cmdline"; done
  [ -n "$exe" ] && ln -sf "$exe" "$d/exe"
  [ "$envs" = "NOENV" ] && return 0
  : > "$d/environ"
  while IFS= read -r kv; do [ -n "$kv" ] && printf '%s\0' "$kv" >> "$d/environ"; done <<< "$envs"
  return 0
}

# setenvraw <pid> <entry>... — write /proc/<pid>/environ RAW: one NUL-terminated entry per
# argument, so an entry may itself contain a newline. mkproc's newline-separated block cannot
# express that, and it is exactly the shape defect D1 turns on.
setenvraw(){ local pid="$1"; shift; local d="$WORK/proc/$pid" e
             : > "$d/environ"; for e in "$@"; do printf '%s\0' "$e" >> "$d/environ"; done; }

# The pre-fix BENCH-path identity, reproduced verbatim so the harness can show what it missed:
#   SRV_CMD="$(tr '\0' ' ' < /proc/$PID/cmdline)"; sha256sum | cut -c1-8
oldhash(){ tr '\0' ' ' < "$WORK/proc/$1/cmdline" | sha256sum | cut -c1-8; }
canon(){ AHL_PROC="$WORK/proc" ahl_hostcfg_canon "$@"; }

export AHL_PROC="$WORK/proc"

echo "== 1. the same config hashes the same, whatever varies around it =="
mkproc 1001 "" --exe "$BIN" -- "$BIN" -m "$GG" --cuda --ctx 65536 --host 0.0.0.0 --port 8000 --cors
BASE="$(ahl_hostcfg_hash 1001 ds4@b030961 "$DS4_RE")"
matches "hash is scheme-prefixed 8 hex" '^hp3-[0-9a-f]{8}$' "$BASE"

# pid — the only thing that is guaranteed to differ between two runs of one config.
mkproc 2002 "" --exe "$BIN" -- "$BIN" -m "$GG" --cuda --ctx 65536 --host 0.0.0.0 --port 8000 --cors
same "different pid" "$BASE" "$(ahl_hostcfg_hash 2002 ds4@b030961 "$DS4_RE")"

# port + bind address — benching the same config on :8001 must not mint a new config.
mkproc 1003 "" --exe "$BIN" -- "$BIN" -m "$GG" --cuda --ctx 65536 --host 127.0.0.1 --port 8001 --cors
same "different host/port" "$BASE" "$(ahl_hostcfg_hash 1003 ds4@b030961 "$DS4_RE")"

# a timestamped log destination is not config
mkproc 1004 "" --exe "$BIN" -- "$BIN" -m "$GG" --cuda --ctx 65536 --host 0.0.0.0 --port 8000 --cors \
       --log-file /var/log/ds4-20260820T131415Z.log
same "timestamped --log-file" "$BASE" "$(ahl_hostcfg_hash 1004 ds4@b030961 "$DS4_RE")"

# The SAME BYTES under a different mount / install prefix. This is the case the old harness
# asserted by BASENAME (case 1005, two nonexistent paths sharing a filename); it is asserted here
# by CONTENT, with the engine binary copied to another prefix and the GGUF copied to another mount.
mkproc 1005 "" --exe "$BINMOVED" -- "$BINMOVED" -m "$GGMOVED" \
       --cuda --ctx 65536 --host 0.0.0.0 --port 8000 --cors
same "engine + GGUF relocated (same bytes)" "$BASE" "$(ahl_hostcfg_hash 1005 ds4@b030961 "$DS4_RE")"

# flag order permuted, and `--flag=value` instead of `--flag value`
mkproc 1006 "" --exe "$BIN" -- "$BIN" --cors --port 8000 --host 0.0.0.0 --ctx=65536 -m "$GG" --cuda
same "flag order + --flag=value form" "$BASE" "$(ahl_hostcfg_hash 1006 ds4@b030961 "$DS4_RE")"

# environment ORDER, and environment the caller did not select for
mkproc 1007 $'DS4_DSPARK_EXEC_TIER=2\nDS4_DSPARK_SCHEDULER_DEPTH=3' --exe "$BIN" -- \
       "$BIN" -m "$GG" --cuda --ctx 65536 --host 0.0.0.0 --port 8000 --cors
mkproc 1008 $'DS4_DSPARK_SCHEDULER_DEPTH=3\nDS4_DSPARK_EXEC_TIER=2' --exe "$BIN" -- \
       "$BIN" -m "$GG" --cuda --ctx 65536 --host 0.0.0.0 --port 8000 --cors
same "env var order" "$(ahl_hostcfg_hash 1007 ds4@b030961 "$DS4_RE")" \
                     "$(ahl_hostcfg_hash 1008 ds4@b030961 "$DS4_RE")"
mkproc 1009 $'PWD=/home/jk/run-a\nSSH_CONNECTION=10.0.0.9 51000 10.0.0.2 22\n_=/usr/bin/nohup\nSHLVL=3' \
       --exe "$BIN" -- "$BIN" -m "$GG" --cuda --ctx 65536 --host 0.0.0.0 --port 8000 --cors
same "session env outside the prefix regex" "$BASE" "$(ahl_hostcfg_hash 1009 ds4@b030961 "$DS4_RE")"

echo "== 2. the tuning ENVIRONMENT is part of the identity (the cmdline hash's blind spot) =="
differ "DS4_DSPARK_EXEC_TIER set vs unset" "$BASE" "$(ahl_hostcfg_hash 1007 ds4@b030961 "$DS4_RE")"
mkproc 1010 'DS4_DSPARK_EXEC_TIER=1' --exe "$BIN" -- "$BIN" -m "$GG" --cuda --ctx 65536 --host 0.0.0.0 --port 8000 --cors
mkproc 1011 'DS4_DSPARK_EXEC_TIER=2' --exe "$BIN" -- "$BIN" -m "$GG" --cuda --ctx 65536 --host 0.0.0.0 --port 8000 --cors
differ "DS4_DSPARK_EXEC_TIER=1 vs =2" "$(ahl_hostcfg_hash 1010 ds4@b030961 "$DS4_RE")" \
                                      "$(ahl_hostcfg_hash 1011 ds4@b030961 "$DS4_RE")"
same "…and the old cmdline hash could not tell them apart" "$(oldhash 1010)" "$(oldhash 1011)"
# an env the harness cannot read is a provenance defect, not an empty environment
mkproc 1012 NOENV --exe "$BIN" -- "$BIN" -m "$GG" --cuda --ctx 65536 --host 0.0.0.0 --port 8000 --cors
differ "unreadable environ vs empty environ" "$BASE" "$(ahl_hostcfg_hash 1012 ds4@b030961 "$DS4_RE")"
check "unreadable environ is marked in the document" "1" \
  "$(canon 1012 ds4@b030961 "$DS4_RE" | grep -c '^env UNREADABLE$' || true)"
# the knob string and the hash read the SAME selection
check "env knob is the same selection, |-joined" \
  "DS4_DSPARK_EXEC_TIER=2|DS4_DSPARK_SCHEDULER_DEPTH=3" "$(ahl_hostcfg_env_knob 1008 "$DS4_RE")"
check "env knob is empty when nothing is set" "" "$(ahl_hostcfg_env_knob 1001 "$DS4_RE")"

echo "== 3. the four historical ds4 rows (all filed under config_hash 10b02344) =="
# From results/gb10-1988a9714b4e/antirez/DeepSeek-V4-Flash/{accuracy.tsv,logbook.md}:
#   v1 20260808-153827 gsm8k 76.0  pre-0731 GGUF, target-only, engine b030961
#   v2 20260808-150310 gsm8k 60.0  0731 GGUF,     target-only, engine b030961   (round 3b DISCARD)
#   v3 20260809-210459 gsm8k 74.0  pre-0731 GGUF, target-only, engine 84cc882   (round 4 base)
#   v4 20260809-213330 gsm8k 74.0  pre-0731 GGUF, DSpark @0.7, engine 84cc882   (round 4 winner)
# v3/v4 wear the SAME argv[0] as v1 — a `make` rebuild replaces the binary in place, so the path is
# unchanged and only the bytes behind /proc/<pid>/exe move. That is precisely the case the old
# space-joined-cmdline hash could not see.
# NOTE the two GGUFs share a basename here — that is the real snapshot layout, and the pre-fix
# library therefore could not separate v1 from v2 either.
mkproc 3001 "" --exe "$BIN"  -- "$BIN"  -m "$GG"     --cuda --ctx 65536 --host 0.0.0.0 --port 8000 --cors
mkproc 3002 "" --exe "$BIN"  -- "$BIN"  -m "$GG0731" --cuda --ctx 65536 --host 0.0.0.0 --port 8000 --cors
mkproc 3003 "" --exe "$BIN2" -- "$BIN"  -m "$GG"     --cuda --ctx 65536 --host 0.0.0.0 --port 8000 --cors
mkproc 3004 "" --exe "$BIN2" -- "$BIN"  -m "$GG"     --cuda --ctx 65536 --host 0.0.0.0 --port 8000 --cors \
       --mtp "$SUPPORT" --dspark
V1="$(ahl_hostcfg_hash 3001 ds4@b030961 "$DS4_RE")"
V2="$(ahl_hostcfg_hash 3002 ds4@b030961 "$DS4_RE")"
V3="$(ahl_hostcfg_hash 3003 ds4@84cc882 "$DS4_RE")"
V4="$(ahl_hostcfg_hash 3004 ds4@84cc882 "$DS4_RE")"
differ "v1 76.0 vs v2 60.0 (the GGUF checkpoint)" "$V1" "$V2"
differ "v1 76.0 vs v3 74.0 (the engine build)"    "$V1" "$V3"
differ "v3 74.0 vs v4 74.0 (--dspark)"            "$V3" "$V4"
differ "v2 vs v3" "$V2" "$V3"; differ "v2 vs v4" "$V2" "$V4"; differ "v1 vs v4" "$V1" "$V4"
n_distinct="$(printf '%s\n%s\n%s\n%s\n' "$V1" "$V2" "$V3" "$V4" | sort -u | wc -l)"
check "all four variants separate" "4" "$n_distinct"
# …and name the field each pair separates on, so the journal entry is not just "the hash moved"
d12="$(diff <(canon 3001 ds4@b030961 "$DS4_RE") <(canon 3002 ds4@b030961 "$DS4_RE") || true)"
if printf '%s' "$d12" | grep -q '^[<>] arg -m='; then ok "v1/v2 separate on -m (the GGUF content)"
else bad "v1/v2 separate, but not on -m: $d12"; fi
d13="$(diff <(canon 3001 ds4@b030961 "$DS4_RE") <(canon 3003 ds4@84cc882 "$DS4_RE") || true)"
if printf '%s' "$d13" | grep -q '^[<>] exe='; then ok "v1/v3 separate on exe (the running binary)"
else bad "v1/v3 separate, but not on exe: $d13"; fi
d34="$(diff <(canon 3003 ds4@84cc882 "$DS4_RE") <(canon 3004 ds4@84cc882 "$DS4_RE") || true)"
if printf '%s' "$d34" | grep -q '^[<>] arg --dspark'; then ok "v3/v4 separate on --dspark"
else bad "v3/v4 separate, but not on --dspark: $d34"; fi
# the pre-fix bench-path hash: v1 and v3 are the same cmdline on two different engine builds, and
# the pre-fix EVAL-path hash was the stub file, identical for all four.
same "old cmdline hash collided v1/v3 (engine bump invisible)" "$(oldhash 3001)" "$(oldhash 3003)"

echo "== 4. llama.cpp: slot count, context and out-of-band env all separate =="
mkproc 4001 "" --exe "$LS" -- "$LS" -m "$Q" -c 196608 -np 16 -ngl 99 --host 0.0.0.0 --port 8000 -a ff711
mkproc 4002 "" --exe "$LS" -- "$LS" -m "$Q" -c 196608 -np 32 -ngl 99 --host 0.0.0.0 --port 8000 -a ff711
mkproc 4003 "" --exe "$LS" -- "$LS" -m "$Q" -c 393216 -np 32 -ngl 99 --host 0.0.0.0 --port 8000 -a ff711
L1="$(ahl_hostcfg_hash 4001 llamacpp@deadbee "$LCPP_RE")"
L2="$(ahl_hostcfg_hash 4002 llamacpp@deadbee "$LCPP_RE")"
L3="$(ahl_hostcfg_hash 4003 llamacpp@deadbee "$LCPP_RE")"
differ "np 16 vs 32"  "$L1" "$L2"
differ "ctx 192K vs 384K at np 32 (the CTX = CTX_PER_SLOT * NP trap)" "$L2" "$L3"
mkproc 4004 'GGML_CUDA_FORCE_MMQ=1' --exe "$LS" -- "$LS" -m "$Q" -c 196608 -np 16 -ngl 99 --host 0.0.0.0 --port 8000 -a ff711
differ "GGML_CUDA_FORCE_MMQ set out-of-band" "$L1" "$(ahl_hostcfg_hash 4004 llamacpp@deadbee "$LCPP_RE")"
mkproc 4005 "" --exe "$LS" -- "$LS" -m "$Q" -c 196608 -np 16 -ngl -1 --host 0.0.0.0 --port 8000 -a ff711
differ "-ngl 99 vs -ngl -1 (a negative number is a VALUE, not a flag)" \
  "$L1" "$(ahl_hostcfg_hash 4005 llamacpp@deadbee "$LCPP_RE")"
SPACED="$FIX/llama/models/Qwen3.6 27B FF711 Q5_K_M.gguf"; cp "$Q" "$SPACED"
mkproc 4006 "" --exe "$LS" -- "$LS" -m "$SPACED" -c 196608 -np 16 -ngl 99 \
       --host 0.0.0.0 --port 8000 -a ff711
check "a path containing spaces stays ONE argument" \
  "$(canon 4001 llamacpp@deadbee "$LCPP_RE" | grep -c '^arg ')" \
  "$(canon 4006 llamacpp@deadbee "$LCPP_RE" | grep -c '^arg ')"
same "…and a COPY of the same GGUF under that spaced name is the same config" \
  "$L1" "$(ahl_hostcfg_hash 4006 llamacpp@deadbee "$LCPP_RE")"

echo "== 5. one case per defect the verifier reproduced (all six were live at 46/46) =="

# ── D1: a newline in a value collided. `printf 'arg %s\n' … | sort` turned one value into two
# records that sorted independently, so `--note $'foo\narg --dspark'` forged an `arg --dspark`
# line. Reachable on the env leg by any operator `export`.
mkproc 5101 "" --exe "$BIN" -- "$BIN" -m "$GG" --note $'foo\narg --dspark'
mkproc 5102 "" --exe "$BIN" -- "$BIN" -m "$GG" --note foo --dspark
differ "D1 argv: a newline inside a value cannot forge another argument" \
  "$(ahl_hostcfg_hash 5101 ds4@b030961 "$DS4_RE")" "$(ahl_hostcfg_hash 5102 ds4@b030961 "$DS4_RE")"
check "D1 argv: the value is escaped to ONE record" "1" \
  "$(canon 5101 ds4@b030961 "$DS4_RE" | grep -cFx 'arg --note=foo\narg --dspark' || true)"
# ONE variable whose value contains a newline, against TWO real variables. hp2 read the environ
# with `tr '\0' '\n' | grep`, so both presented as the same two lines: an operator who exports
# DS4_MTP_NOTE=$'a\nDS4_MTP_FORGED=b' forged a tuning knob into somebody else's config identity.
mkproc 5103 "" --exe "$BIN" -- "$BIN" -m "$GG"
setenvraw 5103 $'DS4_MTP_NOTE=a\nDS4_MTP_FORGED=b'
mkproc 5104 "" --exe "$BIN" -- "$BIN" -m "$GG"
setenvraw 5104 'DS4_MTP_NOTE=a' 'DS4_MTP_FORGED=b'
differ "D1 env: an exported newline cannot forge another env line" \
  "$(ahl_hostcfg_hash 5103 ds4@b030961 "$DS4_RE")" "$(ahl_hostcfg_hash 5104 ds4@b030961 "$DS4_RE")"
check "D1 env: the forged value stays inside ONE record" "1" \
  "$(canon 5103 ds4@b030961 "$DS4_RE" | grep -cFx 'env DS4_MTP_NOTE=a\nDS4_MTP_FORGED=b' || true)"
mkproc 5105 "" --exe "$BIN" -- "$BIN" -m "$GG" --note $'a\tb'
mkproc 5106 "" --exe "$BIN" -- "$BIN" -m "$GG" --note 'a b'
differ "D1: a tab in a value survives as a distinct value" \
  "$(ahl_hostcfg_hash 5105 ds4@b030961 "$DS4_RE")" "$(ahl_hostcfg_hash 5106 ds4@b030961 "$DS4_RE")"

# ── D2: repeated flags were order-collapsed. llama.cpp's --override-tensor/-ot is FIRST-MATCH-WINS,
# so these two are different offload layouts — a live GB10 tuning axis — and hp2 sorted them into
# one document. Distinct flags must stay order-insensitive (asserted in part 1, case 1006).
mkproc 5201 "" --exe "$LS" -- "$LS" -m "$Q" -ot 'blk\..*ffn=CPU' -ot 'blk\.0.*=CUDA0'
mkproc 5202 "" --exe "$LS" -- "$LS" -m "$Q" -ot 'blk\.0.*=CUDA0' -ot 'blk\..*ffn=CPU'
differ "D2: -ot order is significant (first-match-wins offload layout)" \
  "$(ahl_hostcfg_hash 5201 llamacpp@deadbee "$LCPP_RE")" \
  "$(ahl_hostcfg_hash 5202 llamacpp@deadbee "$LCPP_RE")"
check "D2: repeated flags carry an occurrence ordinal" "2" \
  "$(canon 5201 llamacpp@deadbee "$LCPP_RE" | grep -c '^arg -ot#[12]=' || true)"
check "D2: a flag that occurs once carries NO ordinal" "1" \
  "$(canon 4001 llamacpp@deadbee "$LCPP_RE" | grep -c '^arg -np=16$' || true)"
mkproc 5203 "" --exe "$LS" -- "$LS" -m "$Q" -ot 'blk\..*ffn=CPU' -ot 'blk\..*ffn=CPU'
differ "D2: the same override twice is not the same as once" \
  "$(ahl_hostcfg_hash 5203 llamacpp@deadbee "$LCPP_RE")" \
  "$(ahl_hostcfg_hash 5201 llamacpp@deadbee "$LCPP_RE")"
mkproc 5204 "" --exe "$BIN" -- "$BIN" -m "$GG" pos-a pos-b
mkproc 5205 "" --exe "$BIN" -- "$BIN" -m "$GG" pos-b pos-a
differ "D2: positional order is significant too" \
  "$(ahl_hostcfg_hash 5204 ds4@b030961 "$DS4_RE")" "$(ahl_hostcfg_hash 5205 ds4@b030961 "$DS4_RE")"

# ── D3: every value containing `/` was basenamed, not just paths. Two separate failures.
mkproc 5301 "" --exe "$BIN" -- "$BIN" -m "$GG" --chat-template-kwargs '{"a": "x/y"}'
mkproc 5302 "" --exe "$BIN" -- "$BIN" -m "$GG" --chat-template-kwargs '{"b": "z/y"}'
differ "D3: a JSON blob containing / is not a path and is not basenamed" \
  "$(ahl_hostcfg_hash 5301 ds4@b030961 "$DS4_RE")" "$(ahl_hostcfg_hash 5302 ds4@b030961 "$DS4_RE")"
# The one that matters: the HF snapshot layout. Same basename, different bytes.
mkproc 5303 "" --exe "$BIN" -- "$BIN" -m "$GG"
mkproc 5304 "" --exe "$BIN" -- "$BIN" -m "$GG0731"
differ "D3: snapshots/rev-AAAA/model.gguf vs rev-BBBB/model.gguf (the checkpoint axis)" \
  "$(ahl_hostcfg_hash 5303 ds4@b030961 "$DS4_RE")" "$(ahl_hostcfg_hash 5304 ds4@b030961 "$DS4_RE")"
same "D3: …while the SAME bytes at another path is still one config" \
  "$(ahl_hostcfg_hash 5303 ds4@b030961 "$DS4_RE")" \
  "$(mkproc 5305 "" --exe "$BIN" -- "$BIN" -m "$GGMOVED"; ahl_hostcfg_hash 5305 ds4@b030961 "$DS4_RE")"
check "D3: a model file is identified by size and content, never by name" "1" \
  "$(canon 5303 ds4@b030961 "$DS4_RE" | grep -cE '^arg -m=file:[0-9]+:[0-9a-f]{16}$' || true)"
# A value that is a DIRECTORY, or a path that does not exist, is kept verbatim — fail closed.
mkproc 5306 "" --exe "$BIN" -- "$BIN" --lora-dir "$FIX/models/rev-AAAA"
mkproc 5307 "" --exe "$BIN" -- "$BIN" --lora-dir "$FIX/models/rev-BBBB"
differ "D3: two directories sharing nothing but a parent stay distinct" \
  "$(ahl_hostcfg_hash 5306 ds4@b030961 "$DS4_RE")" "$(ahl_hostcfg_hash 5307 ds4@b030961 "$DS4_RE")"

# ── D4: engine identity came from a source tree (`git -C $DS4_DIR rev-parse`), not the binary.
mkproc 5401 "" --exe "$BIN" -- "$BIN" -m "$GG" --cuda
same "D4: a git pull between two benches of one running server does not mint a new config" \
  "$(ahl_hostcfg_hash 5401 ds4@b030961 "$DS4_RE")" "$(ahl_hostcfg_hash 5401 ds4@84cc882 "$DS4_RE")"
same "D4: an unset DS4_DIR (engine label 'unknown') does not mint a third one" \
  "$(ahl_hostcfg_hash 5401 ds4@b030961 "$DS4_RE")" "$(ahl_hostcfg_hash 5401 ds4@unknown "$DS4_RE")"
mkproc 5402 "" --exe "$BIN2" -- "$BIN" -m "$GG" --cuda
differ "D4: a different BINARY behind an identical argv and label is a different config" \
  "$(ahl_hostcfg_hash 5401 ds4@b030961 "$DS4_RE")" "$(ahl_hostcfg_hash 5402 ds4@b030961 "$DS4_RE")"
mkproc 5403 "" --exe "$BINMOVED" -- "$BIN" -m "$GG" --cuda
same "D4: the same binary installed at another prefix is the same config" \
  "$(ahl_hostcfg_hash 5401 ds4@b030961 "$DS4_RE")" "$(ahl_hostcfg_hash 5403 ds4@b030961 "$DS4_RE")"
mkproc 5404 "" -- "$BIN" -m "$GG" --cuda         # no exe link: unreadable /proc/<pid>/exe
check "D4: an unidentifiable binary is recorded as such, not silently skipped" "1" \
  "$(canon 5404 ds4@b030961 "$DS4_RE" | grep -c '^exe=UNREADABLE$' || true)"
differ "D4: …and does not collide with an identified one" \
  "$(ahl_hostcfg_hash 5401 ds4@b030961 "$DS4_RE")" "$(ahl_hostcfg_hash 5404 ds4@b030961 "$DS4_RE")"
mkproc 5405 "" -- "$BIN2" -m "$GG" --cuda        # also no exe link, different argv[0]
differ "D4: two unidentifiable binaries fall back to argv[0] rather than collapsing" \
  "$(ahl_hostcfg_hash 5404 ds4@b030961 "$DS4_RE")" "$(ahl_hostcfg_hash 5405 ds4@b030961 "$DS4_RE")"
check "D4: the engine label's git sha never enters the document" "0" \
  "$(canon 5401 ds4@b030961 "$DS4_RE" | grep -c 'b030961' || true)"

# ── D5: three documented invariants were false. Each is now either true or documented honestly.
# (a) flag ORDER. Order-insensitivity holds for valued flags; a VALUELESS flag adjacent to a
#     positional binds it, so moving it changes the document. The header now says so, and this
#     asserts the documented behaviour rather than the claim that used to be written down.
mkproc 5501 "" --exe "$BIN" -- "$BIN" --cuda --ctx 65536 -m "$GG"
mkproc 5502 "" --exe "$BIN" -- "$BIN" -m "$GG" --ctx 65536 --cuda
same "D5a: reordering VALUED flags is order-insensitive" \
  "$(ahl_hostcfg_hash 5501 ds4@b030961 "$DS4_RE")" "$(ahl_hostcfg_hash 5502 ds4@b030961 "$DS4_RE")"
mkproc 5503 "" --exe "$BIN" -- "$BIN" --cors extra-positional
mkproc 5504 "" --exe "$BIN" -- "$BIN" extra-positional --cors
differ "D5a: a valueless flag adjacent to a positional binds it — documented FALSE SEPARATION" \
  "$(ahl_hostcfg_hash 5503 ds4@b030961 "$DS4_RE")" "$(ahl_hostcfg_hash 5504 ds4@b030961 "$DS4_RE")"
# (b) "the hash and the knob can never disagree" — it failed exactly when /proc/<pid>/environ was
#     unreadable: the document said `env UNREADABLE` while the knobs column said `ds4_env=none`,
#     i.e. "we could not tell" was recorded as "nothing was set".
check "D5b: an unreadable environ renders as 'unreadable' in the knob, never as empty/none" \
  "unreadable" "$(ahl_hostcfg_env_knob 1012 "$DS4_RE" 2>/dev/null)"
check "D5b: …and an environ that is readable but empty still renders empty" \
  "" "$(ahl_hostcfg_env_knob 1001 "$DS4_RE")"
# (c) `=`-form ≡ space-form. hp2's numeric test was ^-[0-9]+([.][0-9]+)?$, so every other form an
#     engine accepts was read as a flag and the two spellings hashed differently.
i=0
for numv in -1 -0.5 -.5 -1e-3 -2.5E+4 -inf -Inf -nan; do
  i=$((i+1))
  mkproc "56$i" "" --exe "$BIN" -- "$BIN" --temp "$numv"
  mkproc "57$i" "" --exe "$BIN" -- "$BIN" "--temp=$numv"
  same "D5c: --temp $numv == --temp=$numv" \
    "$(ahl_hostcfg_hash "56$i" ds4@b030961 "$DS4_RE")" \
    "$(ahl_hostcfg_hash "57$i" ds4@b030961 "$DS4_RE")"
done
mkproc 5581 "" --exe "$BIN" -- "$BIN" --quality --cuda
check "D5c: a real flag after a valueless flag is still a flag, not its value" "1" \
  "$(canon 5581 ds4@b030961 "$DS4_RE" | grep -c '^arg --quality$' || true)"

# ── D6: AHL_HOSTCFG_VOLATILE_FLAGS was operator-overridable and appeared in no row, so a hash was
# not re-derivable without knowing the shell it was computed in. The list is now a constant AND it
# is printed into the document, together with the sample size and the env regex.
V_BEFORE="$(ahl_hostcfg_hash 1001 ds4@b030961 "$DS4_RE")"
V_AFTER="$(AHL_HOSTCFG_VOLATILE_FLAGS='--cuda --ctx' ahl_hostcfg_hash 1001 ds4@b030961 "$DS4_RE")"
same "D6: AHL_HOSTCFG_VOLATILE_FLAGS set at CALL time changes nothing" "$V_BEFORE" "$V_AFTER"
# …and at SOURCE time, which is the way an operator's exported shell variable actually reaches a
# sourced library. Asserting only the call-time form is the mistake AGENTS.md records from the
# ten-worktree merge: a harness applied its overrides across the import while the library read its
# env at call time, so every override silently did nothing and the test passed regardless.
V_SRC="$(AHL_HOSTCFG_VOLATILE_FLAGS='--cuda --ctx' \
         bash -c 'source "$1"; ahl_hostcfg_hash "$2" ds4@b030961 "$3"' _ \
                 "$REAL_REPO/scripts/lib/hostcfg.sh" 1001 "$DS4_RE")"
same "D6: …and set before the library is SOURCED, changes nothing either" "$V_BEFORE" "$V_SRC"
check "D6: the document records the volatile-flag list" "1" \
  "$(canon 1001 ds4@b030961 "$DS4_RE" | grep -c '^scheme volatile=--host,--log-file,--logfile,--port$' || true)"
check "D6: the document records the content-sample size" "1" \
  "$(canon 1001 ds4@b030961 "$DS4_RE" | grep -c '^scheme sample_bytes=[0-9]\+$' || true)"
check "D6: the document records the env regex it selected with" "1" \
  "$(canon 1001 ds4@b030961 "$DS4_RE" | grep -c "^scheme env_re=\^(DS4_DSPARK|DS4_MTP)\$" || true)"
differ "D6: selecting a different env regex is a different document, not a silent one" \
  "$(ahl_hostcfg_hash 1007 ds4@b030961 "$DS4_RE")" "$(ahl_hostcfg_hash 1007 ds4@b030961 '^DS4_')"
# the dead API is gone: `ahl_hostcfg_argv` was public, exported and called by nobody.
if declare -F ahl_hostcfg_argv >/dev/null; then bad "D6: ahl_hostcfg_argv still exists with no caller"
else ok "D6: the uncalled ahl_hostcfg_argv export is gone"; fi
if [ -n "${AHL_HOSTCFG_VOLATILE_FLAGS+x}" ] && [ "${AHL_HOSTCFG_VOLATILE_FLAGS-}" != '--cuda --ctx' ]; then
  bad "D6: sourcing the library still defines AHL_HOSTCFG_VOLATILE_FLAGS"
else ok "D6: sourcing the library defines no overridable knob"; fi

echo "== 6. one engine table, and the benchers agree with it =="
for pair in "ds4:$DS4_RE" "llamacpp:$LCPP_RE"; do
  eng="${pair%%:*}"; want="${pair#*:}"
  check "ahl_hostcfg_env_re $eng" "$want" "$(ahl_hostcfg_env_re "$eng")"
done
check "ahl_hostcfg_env_re rejects an unknown engine" "1" \
  "$( { ahl_hostcfg_env_re nosuch >/dev/null; } ; echo $?)"
# Gate 2 (eval.sh, via the library's table) and Gate 3 (the benchers, via their own constant) must
# select the SAME environment or they would hash different documents for one process.
for pair in "ds4:bench_ds4.sh" "llamacpp:bench_llamacpp.sh"; do
  eng="${pair%%:*}"; f="$REAL_REPO/scripts/${pair#*:}"
  bre="$(sed -n "s/^HOSTCFG_ENV_RE='\(.*\)'$/\1/p" "$f" | head -1)"
  check "$(basename "$f") env regex == the library's table for $eng" "$(ahl_hostcfg_env_re "$eng")" "$bre"
done

echo "== 7. the two benchers still share byte-identical blocks =="
extract(){ sed -n "/$2/,/$3/p" "$1"; }
for pair in \
  'config_hash|^# ── config_hash — scheme|^SRV_ENV=' \
  'validity|^  # Validity: rules live in the library|^  elif \[ "\$floor" != ok \]' \
  'crash|^  if \[ "\$status" = crash \]; then$|^    break$' ; do
  IFS='|' read -r nm a b <<< "$pair"
  x="$(extract "$REAL_REPO/scripts/bench_ds4.sh" "$a" "$b")"
  y="$(extract "$REAL_REPO/scripts/bench_llamacpp.sh" "$a" "$b")"
  if [ -z "$x" ]; then bad "$nm block: marker did not match in bench_ds4.sh"
  elif [ "$x" = "$y" ]; then ok "$nm block byte-identical in both benchers ($(printf '%s\n' "$x" | wc -l) lines)"
  else bad "$nm block DIVERGED between the two benchers"; fi
done

echo "== 8. reachability: the REAL benchers AND the REAL eval.sh write the REAL hash =="
unset AHL_PROC                       # from here on the library reads the true /proc
mkdir -p "$WORK/stubbin"
printf '#!/usr/bin/env bash\necho "uv stub: refusing to run guidellm in a selftest" >&2\nexit 1\n' \
  > "$WORK/stubbin/uv"
printf '#!/usr/bin/env bash\necho "nvidia-smi stub: the GPU is off limits here" >&2\nexit 1\n' \
  > "$WORK/stubbin/nvidia-smi"
chmod +x "$WORK/stubbin/uv" "$WORK/stubbin/nvidia-smi"

R="$WORK/repo"
mkdir -p "$R/scripts/lib" "$R/results/$NODE_FP" "$R/launchers"
cp "$REAL_REPO/scripts/bench_ds4.sh" "$REAL_REPO/scripts/bench_llamacpp.sh" "$R/scripts/"
cp "$REAL_REPO/scripts/lib/validity.py" "$REAL_REPO/scripts/lib/validity.sh" \
   "$REAL_REPO/scripts/lib/hostcfg.sh" "$R/scripts/lib/"
cp "$REAL_REPO/scripts/lib/__init__.py" "$R/scripts/lib/" 2>/dev/null || true
echo '{"gpu":{"mem_bw_gbs":273}}' > "$R/results/$NODE_FP/node_profile.json"
printf 'name = "guidellm"\nversion = "0.6.0"\n' > "$R/uv.lock"
printf 'MODEL=DavidAU/Selftest-GGUF\nSERVED_NAME=selftest\nPROCESSOR=DavidAU/Selftest\n' \
  > "$R/launchers/selftest.smoke-runbook.sh"

# A background process wearing the engine's argv. It is `sleep`; it serves nothing. Ports are in
# the 18xxx range so the pgrep can never latch onto a real engine on :8000.
# Sets FAKESRV_PID. It must NOT return the pid on stdout: a `$(fakesrv …)` would run the whole
# function in a SUBSHELL, so the KILL_PIDS registration would be discarded and the harness would
# leak a 900-second process per case (observed, then fixed — the trap looked correct and was
# simply never given the pids).
fakesrv(){ # fakesrv <engine-binary-name> <argv...>
  local name="$1"; shift
  mkdir -p "$WORK/bin"
  printf '#!/bin/bash\nsleep 900\n' > "$WORK/bin/$name"; chmod +x "$WORK/bin/$name"
  "$WORK/bin/$name" "$@" >/dev/null 2>&1 </dev/null &
  FAKESRV_PID=$!
  KILL_PIDS+=("$FAKESRV_PID")
}

run_bencher(){ # run_bencher <script> <port> <env-assignments...> -- <script args>
  local script="$1" port="$2"; shift 2
  local -a envs=(); while [ "${1:-}" != "--" ] && [ "$#" -gt 0 ]; do envs+=("$1"); shift; done; shift || true
  set +e
  ( cd "$R" && env TAG=selftest AHL_PORT="$port" LEVELS_SET=1 MAX_SECONDS=5 LEVEL_TIMEOUT=10 \
       AHL_KILL_ON_CRASH=0 AHL_PYTHON=python3 PATH="$WORK/stubbin:$PATH" \
       ${envs[@]+"${envs[@]}"} bash "scripts/$script" "$@" ) >"$WORK/$script.out" 2>&1
  RC=$?
  set -e
}

# ── ds4 ──
fakesrv ds4-server -m "$GG" --cuda --ctx 65536 --host 127.0.0.1 --port 18000 --cors --dspark
DPID="$FAKESRV_PID"
sleep 0.3
run_bencher bench_ds4.sh 18000 "DS4_DIR=$REAL_REPO" -- chat
check "bench_ds4.sh exits 3 (guidellm stub fails => crash path)" "3" "$RC"
DTSV="$R/results/$NODE_FP/antirez/DeepSeek-V4-Flash/results.tsv"
if [ ! -f "$DTSV" ]; then bad "bench_ds4.sh wrote no results.tsv — see $WORK/bench_ds4.sh.out"
else
  DROW="$(tail -1 "$DTSV")"
  DCFG="$(printf '%s' "$DROW" | cut -f7)"; DBACKEND="$(printf '%s' "$DROW" | cut -f6)"
  matches "ds4 row carries an hp3 config_hash" '^hp3-[0-9a-f]{8}$' "$DCFG"
  check "ds4 row's hash is the library's hash of the SERVED process" \
    "$(ahl_hostcfg_hash "$DPID" "$DBACKEND" "$DS4_RE")" "$DCFG"
  # `unknown` is the legitimate fallback when DS4_DIR is not a git checkout, so the assertion is
  # on the SHAPE of the engine identity — it is still the row's provenance, it is simply no longer
  # what the hash is computed from.
  matches "ds4 backend carries the engine identity" '^ds4@([0-9a-f]+|unknown)$' "$DBACKEND"
  if printf '%s' "$DROW" | cut -f20 | grep -q 'ds4_env='; then ok "ds4 knobs keep the ds4_env knob"
  else bad "ds4 knobs lost ds4_env: $(printf '%s' "$DROW" | cut -f20)"; fi
fi

# The same config re-served under a NEW pid and a NEW port must land on the SAME hash — the whole
# point of the scheme, asserted through the real script rather than the library.
fakesrv ds4-server -m "$GG" --cuda --ctx 65536 --host 0.0.0.0 --port 18002 --cors --dspark
sleep 0.3
run_bencher bench_ds4.sh 18002 "DS4_DIR=$REAL_REPO" -- chat
DCFG2="$(tail -1 "$DTSV" | cut -f7)"
same "re-served on a new pid and port => same config_hash" "${DCFG:-x}" "$DCFG2"

# D4 through the real script: the engine identity must not follow $DS4_DIR. Same running server,
# three different answers from `git -C $DS4_DIR rev-parse` — one config.
git init -q "$WORK/othergit"
( cd "$WORK/othergit" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m x )
run_bencher bench_ds4.sh 18002 "DS4_DIR=$WORK/othergit" -- chat
same "D4 via bench_ds4.sh: a different DS4_DIR sha does not move the hash" \
  "${DCFG:-x}" "$(tail -1 "$DTSV" | cut -f7)"
run_bencher bench_ds4.sh 18002 "DS4_DIR=$WORK/nonexistent" -- chat
same "D4 via bench_ds4.sh: an unset/bogus DS4_DIR (ds4@unknown) does not move it either" \
  "${DCFG:-x}" "$(tail -1 "$DTSV" | cut -f7)"

# A different config must land on a DIFFERENT hash, again through the real script. The two GGUFs
# share a basename and differ only in content — the ds4 round-3b checkpoint refresh, end to end.
fakesrv ds4-server -m "$GG0731" --cuda --ctx 65536 --host 0.0.0.0 --port 18003 --cors --dspark
sleep 0.3
run_bencher bench_ds4.sh 18003 "DS4_DIR=$REAL_REPO" -- chat
DCFG3="$(tail -1 "$DTSV" | cut -f7)"
differ "0731 GGUF (same basename, different bytes) => different config_hash" "${DCFG:-x}" "$DCFG3"

# ── llama.cpp ──
fakesrv llama-server -m "$Q" -c 196608 -np 16 -ngl 99 --host 127.0.0.1 --port 18001 -a selftest
LPID="$FAKESRV_PID"
sleep 0.3
run_bencher bench_llamacpp.sh 18001 "LCPP_DIR=$REAL_REPO" -- launchers/selftest.smoke-runbook.sh chat
check "bench_llamacpp.sh exits 3 (guidellm stub fails => crash path)" "3" "$RC"
LTSV="$R/results/$NODE_FP/DavidAU/Selftest-GGUF/results.tsv"
if [ ! -f "$LTSV" ]; then bad "bench_llamacpp.sh wrote no results.tsv — see $WORK/bench_llamacpp.sh.out"
else
  LROW="$(tail -1 "$LTSV")"
  LCFG="$(printf '%s' "$LROW" | cut -f7)"; LBACKEND="$(printf '%s' "$LROW" | cut -f6)"
  matches "llamacpp row carries an hp3 config_hash" '^hp3-[0-9a-f]{8}$' "$LCFG"
  check "llamacpp row's hash is the library's hash of the SERVED process" \
    "$(ahl_hostcfg_hash "$LPID" "$LBACKEND" "$LCPP_RE")" "$LCFG"
  if printf '%s' "$LROW" | cut -f20 | grep -q 'lcpp_env='; then ok "llamacpp knobs carry lcpp_env"
  else bad "llamacpp knobs lost lcpp_env: $(printf '%s' "$LROW" | cut -f20)"; fi
  differ "ds4 and llamacpp configs do not collide" "${DCFG:-x}" "$LCFG"
fi

# No row from either engine may look like a legacy bare-hex hash: that is the migration guarantee.
legacy=0
for t in "$DTSV" "$LTSV"; do
  [ -f "$t" ] || continue
  n="$(tail -n +2 "$t" | cut -f7 | grep -cE '^[0-9a-f]{8}$' || true)"
  legacy=$((legacy + n))
done
check "no new row is indistinguishable from a pre-fix row" "0" "$legacy"

echo "== 9. THE HEADLINE: eval.sh (Gate 2) writes the SAME identity as the bencher (Gate 3) =="
# The tracked defect's four rows live in accuracy.tsv, which eval.sh writes — and eval.sh hashed
# the `.smoke-runbook.sh` STUB. A fix that lands only in the benchers leaves the cited rows
# colliding: re-running those four evals today would still have written `10b02344`.
SBX="$WORK/evalrepo"
mkdir -p "$SBX/scripts/lib" "$SBX/results/$NODE_FP" "$SBX/launchers"
for f in eval.sh eval_validity.py migrate_accuracy_tsv.py; do ln -sf "$REAL_REPO/scripts/$f" "$SBX/scripts/$f"; done
cp "$REAL_REPO/scripts/lib/hostcfg.sh" "$SBX/scripts/lib/"
echo '{"gpu":{"mem_bw_gbs":273}}' > "$SBX/results/$NODE_FP/node_profile.json"
STUB="$SBX/launchers/DS4-antirez_DeepSeek-V4-Flash_q2-imatrix.smoke-runbook.sh"
printf 'MODEL="antirez/DeepSeek-V4-Flash"\nSERVED_NAME="deepseek-v4-flash"\n' > "$STUB"

# A stub lm-eval that writes a structurally healthy gsm8k bundle, so eval.sh reaches the row it
# writes rather than bailing early. It never touches a model, a GPU or the network.
cat > "$SBX/scripts/stub_lm_eval.sh" <<STUBEOF
#!/usr/bin/env bash
set -uo pipefail
out=""
while [ \$# -gt 0 ]; do case "\$1" in --output_path) out="\$2"; shift 2 ;; *) shift ;; esac; done
"$PY" - "\$out" <<'PYEOF'
import json, os, sys
d = os.path.join(sys.argv[1], "stub-model"); os.makedirs(d, exist_ok=True)
doc = {"config": {"limit": 100.0, "model": "local-completions",
                  "model_args": {"num_concurrent": 16, "model": "deepseek-v4-flash"}},
       "group_subtasks": {}, "n-samples": {"gsm8k": {"effective": 100, "original": 1319}},
       "results": {"gsm8k": {"alias": "gsm8k", "exact_match,strict-match": 0.74,
                             "exact_match_stderr,strict-match": 0.04,
                             "exact_match,flexible-extract": 0.74}}}
json.dump(doc, open(os.path.join(d, "results_2026-08-20T00-00-00.000000.json"), "w"))
PYEOF
exit 0
STUBEOF
chmod +x "$SBX/scripts/stub_lm_eval.sh"

run_eval(){ # run_eval <port> -> sets ERC, EROW
  ERC=0
  env AHL_PYTHON="$PY" AHL_LM_EVAL="$SBX/scripts/stub_lm_eval.sh" LIMIT=100 TASKS=gsm8k \
      AHL_PORT="$1" PATH="$WORK/stubbin:$PATH" \
      "$SBX/scripts/eval.sh" "$STUB" general >"$WORK/eval.$1.out" 2>&1 || ERC=$?
  EROW="$(tail -1 "$SBX/results/$NODE_FP/antirez/DeepSeek-V4-Flash/accuracy.tsv" 2>/dev/null || echo)"
}

# The ds4 fake server from part 8 is still on :18002 — eval it, and compare with the row the
# BENCHER wrote for that very process.
run_eval 18002
check "eval.sh exits 0 on a healthy stub bundle" "0" "$ERC"
ECFG="$(printf '%s' "$EROW" | cut -f5)"
matches "accuracy.tsv row carries an hp3 config_hash, not the stub's 8 hex" '^hp3-[0-9a-f]{8}$' "$ECFG"
check "Gate 2 and Gate 3 record the SAME identity for one process (the rows can be joined)" \
  "${DCFG:-x}" "$ECFG"
STUBHASH="$(sha256sum "$STUB" | cut -c1-8)"
differ "…and it is NOT the hash of the .smoke-runbook.sh stub" "$STUBHASH" "$ECFG"

# The 0731 checkpoint on :18003 is a different config, and Gate 2 must say so — this is the
# 60.0-vs-76.0 pair from the tracked defect, separated in the journal that recorded them.
run_eval 18003
ECFG3="$(printf '%s' "$EROW" | cut -f5)"
differ "two ds4 checkpoints no longer share an accuracy.tsv config_hash" "$ECFG" "$ECFG3"
check "…and Gate 3 agrees about the second one too" "${DCFG3:-y}" "$ECFG3"

# No engine on the port: the stub identity is the honest answer, but it must be LABELLED, never
# written as a bare 8 hex that groups with a served row or with a vLLM runbook hash.
run_eval 18099
ECFGX="$(printf '%s' "$EROW" | cut -f5)"
check "no engine found => the row records the stub identity, labelled" "stub-$STUBHASH" "$ECFGX"
if grep -q 'WARN: no ds4/llama.cpp engine found' "$WORK/eval.18099.out"; then
  ok "…and eval.sh says so on stderr"
else bad "eval.sh recorded a stub hash silently — see $WORK/eval.18099.out"; fi

# A vLLM runbook must be untouched by any of this: same file, same 8 hex, no /proc anywhere.
VRB="$SBX/launchers/vllm-runbook.sh"
printf 'MODEL="acme/Stub-7B"\nSERVED_NAME="stub"\nVLLM_IMAGE="vllm/vllm-openai@sha256:dead"\n' > "$VRB"
ERC=0
env AHL_PYTHON="$PY" AHL_LM_EVAL="$SBX/scripts/stub_lm_eval.sh" LIMIT=100 TASKS=gsm8k \
    AHL_PORT=18002 PATH="$WORK/stubbin:$PATH" \
    "$SBX/scripts/eval.sh" "$VRB" general >"$WORK/eval.vllm.out" 2>&1 || ERC=$?
VROW="$(tail -1 "$SBX/results/$NODE_FP/acme/Stub-7B/accuracy.tsv" 2>/dev/null || echo)"
check "a vLLM runbook still hashes the RUNBOOK, even with an engine on the port" \
  "$(sha256sum "$VRB" | cut -c1-8)" "$(printf '%s' "$VROW" | cut -f5)"

echo
echo "hostcfg selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
