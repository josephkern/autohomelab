#!/usr/bin/env bash
# hostcfg_selftest.sh — harness for the HOST-PROCESS `config_hash` (scripts/lib/hostcfg.sh).
#
#   scripts/hostcfg_selftest.sh [-v]
#
# Why this exists, and why it is not a unit test
# ----------------------------------------------
# This repo has a scar: three correct-looking guards have sat in unreachable branches, two of them
# carrying comments claiming otherwise (AGENTS.md, "REASONING × SPEC-DECODE branch-order bug" —
# confirming a guard's CONDITION fires is not the same as confirming its BRANCH is reachable).
# A config_hash is exactly the kind of thing that looks right by reading: it is an opaque 8 hex
# digits that nobody can eyeball, and the defect it is fixing (four ds4 gsm8k rows of
# 60.0/76.0/74.0/74.0 filed under one hash) was itself invisible for months.
#
# So this harness asserts on the COMPUTED VALUE, twice over:
#   Part 1-4 drive the library against a FABRICATED /proc (AHL_PROC) — every case is a real
#            /proc/<pid>/cmdline and /proc/<pid>/environ written to a temp dir, NUL-separated
#            exactly as the kernel writes them.
#   Part 6   drives the REAL scripts/bench_ds4.sh and scripts/bench_llamacpp.sh end-to-end inside a
#            throwaway repo, against a real background process whose argv imitates the engine, with
#            `uv`/`nvidia-smi` stubbed to fail — and asserts on the config_hash that lands in the
#            results.tsv ROW. That is the reachability proof: the new block is not merely correct,
#            it is what executes and what gets written.
#
# Hermetic by construction: no docker, no server, no guidellm/lm-eval, no GPU, no network. The
# only process it starts is a `sleep` wearing the engine's argv.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
VERBOSE=0; [ "${1:-}" = "-v" ] && VERBOSE=1
PASS=0; FAIL=0
NODE_FP=gb10-test
DS4_RE='^(DS4_DSPARK|DS4_MTP)'
LCPP_RE='^(LLAMA_|GGML_)'

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

# ── fabricated /proc ──────────────────────────────────────────────────────────
# mkproc <pid> <env-block|NOENV> -- <argv...>
# env-block is newline-separated K=V (may be empty); NOENV omits the environ file entirely, which
# is how an unreadable environment presents to the library.
mkproc(){
  local pid="$1" envs="$2"; shift 2; [ "${1:-}" = "--" ] && shift
  local d="$WORK/proc/$pid" a kv
  rm -rf "$d"; mkdir -p "$d"
  : > "$d/cmdline"; for a in "$@"; do printf '%s\0' "$a" >> "$d/cmdline"; done
  [ "$envs" = "NOENV" ] && return 0
  : > "$d/environ"
  while IFS= read -r kv; do [ -n "$kv" ] && printf '%s\0' "$kv" >> "$d/environ"; done <<< "$envs"
  return 0
}

# The pre-fix BENCH-path identity, reproduced verbatim so the harness can show what it missed:
#   SRV_CMD="$(tr '\0' ' ' < /proc/$PID/cmdline)"; sha256sum | cut -c1-8
oldhash(){ tr '\0' ' ' < "$WORK/proc/$1/cmdline" | sha256sum | cut -c1-8; }

export AHL_PROC="$WORK/proc"

GG=/home/jk/gguf/DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix.gguf
GG0731=/home/jk/gguf/DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-0731.gguf
SUPPORT=/home/jk/gguf/DeepSeek-V4-Flash-DSpark-support.gguf
BIN=/home/jk/code/ds4/ds4-server

echo "== 1. the same config hashes the same, whatever varies around it =="
mkproc 1001 "" -- "$BIN" -m "$GG" --cuda --ctx 65536 --host 0.0.0.0 --port 8000 --cors
BASE="$(ahl_hostcfg_hash 1001 ds4@b030961 "$DS4_RE")"
matches "hash is scheme-prefixed 8 hex" '^hp2-[0-9a-f]{8}$' "$BASE"

# pid — the only thing that is guaranteed to differ between two runs of one config.
mkproc 2002 "" -- "$BIN" -m "$GG" --cuda --ctx 65536 --host 0.0.0.0 --port 8000 --cors
same "different pid" "$BASE" "$(ahl_hostcfg_hash 2002 ds4@b030961 "$DS4_RE")"

# port + bind address — benching the same config on :8001 must not mint a new config.
mkproc 1003 "" -- "$BIN" -m "$GG" --cuda --ctx 65536 --host 127.0.0.1 --port 8001 --cors
same "different host/port" "$BASE" "$(ahl_hostcfg_hash 1003 ds4@b030961 "$DS4_RE")"

# a timestamped log destination is not config
mkproc 1004 "" -- "$BIN" -m "$GG" --cuda --ctx 65536 --host 0.0.0.0 --port 8000 --cors \
       --log-file /var/log/ds4-20260820T131415Z.log
same "timestamped --log-file" "$BASE" "$(ahl_hostcfg_hash 1004 ds4@b030961 "$DS4_RE")"

# the SAME files under a different mount / build dir
mkproc 1005 "" -- /opt/ds4/build/ds4-server -m "/mnt/nvme/models/$(basename "$GG")" \
       --cuda --ctx 65536 --host 0.0.0.0 --port 8000 --cors
same "engine + GGUF relocated" "$BASE" "$(ahl_hostcfg_hash 1005 ds4@b030961 "$DS4_RE")"

# flag order permuted, and `--flag=value` instead of `--flag value`
mkproc 1006 "" -- "$BIN" --cors --port 8000 --host 0.0.0.0 --ctx=65536 -m "$GG" --cuda
same "flag order + --flag=value form" "$BASE" "$(ahl_hostcfg_hash 1006 ds4@b030961 "$DS4_RE")"

# environment ORDER, and environment the caller did not select for
mkproc 1007 $'DS4_DSPARK_EXEC_TIER=2\nDS4_DSPARK_SCHEDULER_DEPTH=3' -- \
       "$BIN" -m "$GG" --cuda --ctx 65536 --host 0.0.0.0 --port 8000 --cors
mkproc 1008 $'DS4_DSPARK_SCHEDULER_DEPTH=3\nDS4_DSPARK_EXEC_TIER=2' -- \
       "$BIN" -m "$GG" --cuda --ctx 65536 --host 0.0.0.0 --port 8000 --cors
same "env var order" "$(ahl_hostcfg_hash 1007 ds4@b030961 "$DS4_RE")" \
                     "$(ahl_hostcfg_hash 1008 ds4@b030961 "$DS4_RE")"
mkproc 1009 $'PWD=/home/jk/run-a\nSSH_CONNECTION=10.0.0.9 51000 10.0.0.2 22\n_=/usr/bin/nohup\nSHLVL=3' -- \
       "$BIN" -m "$GG" --cuda --ctx 65536 --host 0.0.0.0 --port 8000 --cors
same "session env outside the prefix regex" "$BASE" "$(ahl_hostcfg_hash 1009 ds4@b030961 "$DS4_RE")"

echo "== 2. the tuning ENVIRONMENT is part of the identity (the cmdline hash's blind spot) =="
differ "DS4_DSPARK_EXEC_TIER set vs unset" "$BASE" "$(ahl_hostcfg_hash 1007 ds4@b030961 "$DS4_RE")"
mkproc 1010 'DS4_DSPARK_EXEC_TIER=1' -- "$BIN" -m "$GG" --cuda --ctx 65536 --host 0.0.0.0 --port 8000 --cors
mkproc 1011 'DS4_DSPARK_EXEC_TIER=2' -- "$BIN" -m "$GG" --cuda --ctx 65536 --host 0.0.0.0 --port 8000 --cors
differ "DS4_DSPARK_EXEC_TIER=1 vs =2" "$(ahl_hostcfg_hash 1010 ds4@b030961 "$DS4_RE")" \
                                      "$(ahl_hostcfg_hash 1011 ds4@b030961 "$DS4_RE")"
same "…and the old cmdline hash could not tell them apart" "$(oldhash 1010)" "$(oldhash 1011)"
# an env the harness cannot read is a provenance defect, not an empty environment
mkproc 1012 NOENV -- "$BIN" -m "$GG" --cuda --ctx 65536 --host 0.0.0.0 --port 8000 --cors
differ "unreadable environ vs empty environ" "$BASE" "$(ahl_hostcfg_hash 1012 ds4@b030961 "$DS4_RE")"
contains_env_marker="$(AHL_PROC="$WORK/proc" ahl_hostcfg_canon 1012 ds4@b030961 "$DS4_RE" | grep -c '^env UNREADABLE$' || true)"
check "unreadable environ is marked in the document" "1" "$contains_env_marker"
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
mkproc 3001 "" -- "$BIN" -m "$GG"     --cuda --ctx 65536 --host 0.0.0.0 --port 8000 --cors
mkproc 3002 "" -- "$BIN" -m "$GG0731" --cuda --ctx 65536 --host 0.0.0.0 --port 8000 --cors
mkproc 3003 "" -- "$BIN" -m "$GG"     --cuda --ctx 65536 --host 0.0.0.0 --port 8000 --cors
mkproc 3004 "" -- "$BIN" -m "$GG"     --cuda --ctx 65536 --host 0.0.0.0 --port 8000 --cors \
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
d12="$(diff <(AHL_PROC="$WORK/proc" ahl_hostcfg_canon 3001 ds4@b030961 "$DS4_RE") \
            <(AHL_PROC="$WORK/proc" ahl_hostcfg_canon 3002 ds4@b030961 "$DS4_RE") || true)"
if printf '%s' "$d12" | grep -q '^[<>] arg -m='; then ok "v1/v2 separate on -m (the GGUF)"
else bad "v1/v2 separate, but not on -m: $d12"; fi
d34="$(diff <(AHL_PROC="$WORK/proc" ahl_hostcfg_canon 3003 ds4@84cc882 "$DS4_RE") \
            <(AHL_PROC="$WORK/proc" ahl_hostcfg_canon 3004 ds4@84cc882 "$DS4_RE") || true)"
if printf '%s' "$d34" | grep -q '^[<>] arg --dspark'; then ok "v3/v4 separate on --dspark"
else bad "v3/v4 separate, but not on --dspark: $d34"; fi
# the pre-fix bench-path hash: v1 and v3 are the same cmdline on two different engine builds
same "old cmdline hash collided v1/v3 (engine bump invisible)" "$(oldhash 3001)" "$(oldhash 3003)"

echo "== 4. llama.cpp: slot count, context and out-of-band env all separate =="
LS=/home/jk/code/llama.cpp/build/bin/llama-server
Q=/home/jk/gguf/Qwen3.6-27B-FF711-Q5_K_M.gguf
mkproc 4001 "" -- "$LS" -m "$Q" -c 196608 -np 16 -ngl 99 --host 0.0.0.0 --port 8000 -a ff711
mkproc 4002 "" -- "$LS" -m "$Q" -c 196608 -np 32 -ngl 99 --host 0.0.0.0 --port 8000 -a ff711
mkproc 4003 "" -- "$LS" -m "$Q" -c 393216 -np 32 -ngl 99 --host 0.0.0.0 --port 8000 -a ff711
L1="$(ahl_hostcfg_hash 4001 llamacpp@deadbee "$LCPP_RE")"
L2="$(ahl_hostcfg_hash 4002 llamacpp@deadbee "$LCPP_RE")"
L3="$(ahl_hostcfg_hash 4003 llamacpp@deadbee "$LCPP_RE")"
differ "np 16 vs 32"  "$L1" "$L2"
differ "ctx 192K vs 384K at np 32 (the CTX = CTX_PER_SLOT * NP trap)" "$L2" "$L3"
mkproc 4004 'GGML_CUDA_FORCE_MMQ=1' -- "$LS" -m "$Q" -c 196608 -np 16 -ngl 99 --host 0.0.0.0 --port 8000 -a ff711
differ "GGML_CUDA_FORCE_MMQ set out-of-band" "$L1" "$(ahl_hostcfg_hash 4004 llamacpp@deadbee "$LCPP_RE")"
mkproc 4005 "" -- "$LS" -m "$Q" -c 196608 -np 16 -ngl -1 --host 0.0.0.0 --port 8000 -a ff711
differ "-ngl 99 vs -ngl -1 (a negative number is a VALUE, not a flag)" \
  "$L1" "$(ahl_hostcfg_hash 4005 llamacpp@deadbee "$LCPP_RE")"
mkproc 4006 "" -- "$LS" -m "/srv/models/Qwen3.6-27B FF711 Q5_K_M.gguf" -c 196608 -np 16 -ngl 99 \
       --host 0.0.0.0 --port 8000 -a ff711
n_args="$(AHL_PROC="$WORK/proc" ahl_hostcfg_canon 4006 llamacpp@deadbee "$LCPP_RE" | grep -c '^arg ')"
check "a path containing spaces stays ONE argument" \
  "$(AHL_PROC="$WORK/proc" ahl_hostcfg_canon 4001 llamacpp@deadbee "$LCPP_RE" | grep -c '^arg ')" "$n_args"

echo "== 5. the two benchers still share byte-identical blocks =="
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

echo "== 6. reachability: the REAL benchers write the REAL hash into the row =="
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
  matches "ds4 row carries an hp2 config_hash" '^hp2-[0-9a-f]{8}$' "$DCFG"
  check "ds4 row's hash is the library's hash of the SERVED process" \
    "$(ahl_hostcfg_hash "$DPID" "$DBACKEND" "$DS4_RE")" "$DCFG"
  # `unknown` is the legitimate fallback when DS4_DIR is not a git checkout, so the assertion is
  # on the SHAPE of the engine identity — that is what feeds the hash — not on git being present.
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

# A different config must land on a DIFFERENT hash, again through the real script.
fakesrv ds4-server -m "$GG0731" --cuda --ctx 65536 --host 0.0.0.0 --port 18003 --cors --dspark
sleep 0.3
run_bencher bench_ds4.sh 18003 "DS4_DIR=$REAL_REPO" -- chat
DCFG3="$(tail -1 "$DTSV" | cut -f7)"
differ "0731 GGUF => different config_hash" "${DCFG:-x}" "$DCFG3"

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
  matches "llamacpp row carries an hp2 config_hash" '^hp2-[0-9a-f]{8}$' "$LCFG"
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

echo
echo "hostcfg selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
