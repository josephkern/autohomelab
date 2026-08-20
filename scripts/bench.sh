#!/usr/bin/env bash
# bench.sh — run GuideLLM tok/s sweeps against a live endpoint and append results.tsv row(s).
#
#   scripts/bench.sh <runbook.sh> [shape ...]
#
# shapes ∈ chat (512/256, default) | coder (4096/1024); pass several to AMORTIZE the model load
# across one serve session (server loaded once; each shape = one row with the 1/4/8/16/32 curve).
# The server must already be up (scripts/serve.sh <runbook.sh>).
#
# PER-LEVEL ISOLATION: each concurrency level is a SEPARATE GuideLLM call, so a hang at a high
# level still preserves the lower levels' numbers (GuideLLM writes its JSON only at the end of a
# call) and pinpoints exactly which level breaks. Levels run low→high; on a hang we record that
# level as `hang`, keep the completed levels, tear the container down, and stop (hangs are at high
# concurrency, so higher levels would wedge too). This mirrors running each config by hand.
#
# Monitoring per level: stall-watchdog (vLLM gen-throughput 0 with reqs running for STALL_SECS) +
# a hard timeout. GuideLLM --max-seconds only bounds *scheduling*; it drains in-flight requests,
# so a wedged engine blocks past it — hence the external guards.
#
# INTERRUPTED RUNS: emit_row runs once, at the END of a shape, so anything that killed the process
# mid-shape used to leave the bundle on disk with real level_c*.json evidence and NO row pointing at
# it — invisible to aggregate.py, to the audit and to every gate. A trap now records the partial
# shape (see "Interrupt safety" below). Untrappable deaths (SIGKILL, OOM-kill, power) are recovered
# after the fact by scripts/reconcile_bundles.py.
#
# EXACTLY ONE ROW PER SHAPE, IN BOTH DIRECTIONS. The append is the atomic unit: signals arriving
# during it are deferred, the flag clears as emit_row's last statement, and the interrupted writer
# additionally refuses a run_id the journal already carries. A shape that COMPLETES cannot lose its
# row to a signal landing between the flag and the write, and one that is interrupted cannot gain a
# second. A signal arriving after a level was already marked hung still records the CRASH row, with
# its `docker logs` artefact and its `adapter down` — the wedge record must not lose an event any
# more than it may gain a phantom one.
#
# VALIDITY (docs/validity-contract.md): every row is checked against the measurement invariants in
# scripts/lib/validity.{py,sh} before it is written. The row is ALWAYS written (the evidence must
# survive in the committed journal), but a fatal verdict downgrades `status` to `void` and a suspect
# verdict to `suspect`, and the run exits 4. Exit codes: 0 ok · 3 crash/hang · 4 validity failure ·
# 128+N when signal N interrupted the run (the partial row is written first, then the signal is
# re-raised so the operator's Ctrl-C still reads as a Ctrl-C to whatever called us).
# A crash outranks a validity failure (3 wins), and a `crash` row keeps status=crash while still
# recording its verdict in the `validity` column.
#
# FAIL CLOSED (contract v1.2 A6). If the library cannot be run, or answers with something this
# script cannot read, the row is recorded `void` and the run exits 4 — never `ok`/0. The previous
# behaviour defaulted the floor to `ok` on a library failure, so a `uv` hiccup wrote a fully
# citable row; a check that degrades into a pass is worse than no check. Same rule, same wording
# as bench_ds4.sh / bench_llamacpp.sh: "the library itself failed, so the row cannot be cited
# either way". The node profile is passed on every call, without which §4's roofline — the only
# invariant that catches a dead endpoint reporting 449,358 tok/s — is silently skipped.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ADAPTER="$REPO_ROOT/backends/vllm/adapter.sh"
[ -f "$REPO_ROOT/.env" ] && set -a && source "$REPO_ROOT/.env" && set +a
VALIDITY_LIB="$SCRIPT_DIR/lib/validity.sh"   # sourced AFTER .env so its AHL_* knobs are visible to it
[ -f "$VALIDITY_LIB" ] || { echo "missing $VALIDITY_LIB — the results header and the validity rules live there (docs/validity-contract.md §1)" >&2; exit 1; }
# shellcheck source=lib/validity.sh disable=SC1090,SC1091
source "$VALIDITY_LIB"

RUNBOOK="${1:?usage: bench.sh <runbook.sh> [shape ...]}"; shift || true
SHAPES=("$@"); [ "${#SHAPES[@]}" -eq 0 ] && SHAPES=("${SHAPE:-chat}")
[ -f "$RUNBOOK" ] || { echo "runbook not found: $RUNBOOK" >&2; exit 1; }

# Routine matrix is lean (c1 sentinel + c16 bulk objective). Full characterization sweep:
#   LEVELS_SET=1,4,8,16,32 scripts/bench.sh ...
# results.tsv always has the 5 fixed columns; unrun levels stay `na` so runs stay comparable.
IFS=',' read -ra LEVELS <<< "${LEVELS_SET:-1,16}"
col_index() { case "$1" in 1) echo 0;; 4) echo 1;; 8) echo 2;; 16) echo 3;; 32) echo 4;; *) echo -1;; esac; }
MAX_SECONDS="${MAX_SECONDS:-180}"
TARGET="${TARGET:-http://${AHL_HOST:-127.0.0.1}:${AHL_PORT:-8000}}"
CONTAINER=ahl-vllm
STALL_SECS="${STALL_SECS:-90}"
LEVEL_TIMEOUT="${LEVEL_TIMEOUT:-$(( MAX_SECONDS * 2 + 120 ))}"
SEED="${AHL_SEED:-42}"                      # fixed -> same synthetic prompts across configs (paired)

# ── Identity (computed once; same for every shape in this serve session) ───────
MODEL=""; SERVED_NAME=""; VLLM_FLAGS=()
# shellcheck disable=SC1090
source "$RUNBOOK"; : "${MODEL:?runbook must set MODEL}"
ORG="${MODEL%%/*}"; [ "$ORG" = "$MODEL" ] && ORG="_"; NAME="${MODEL##*/}"
NODE_FP="$(find "$REPO_ROOT/results" -maxdepth 2 -name node_profile.json -printf '%h\n' 2>/dev/null | head -1 | xargs -r basename || true)"
: "${NODE_FP:?no node profile — run scripts/probe.sh first}"
COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
CONFIG_HASH="$(sha256sum "$RUNBOOK" | cut -c1-8)"
SCRIPT_REL="$(realpath --relative-to="$REPO_ROOT" "$RUNBOOK")"
BACKEND="$("$ADAPTER" info)"
OUT_DIR="$REPO_ROOT/results/$NODE_FP/$ORG/$NAME"
TSV="$OUT_DIR/results.tsv"
NODE_PROFILE="$REPO_ROOT/results/$NODE_FP/node_profile.json"   # §4 roofline input; see check_validity
SCHEMA_MISMATCH=0     # set by emit_row if the journal is still on the pre-migration 20-column header
# Contract §1: the header string exists in exactly one place — the library. Never re-declare it here.
HEADER="${AHL_RESULTS_HEADER:?scripts/lib/validity.sh must set AHL_RESULTS_HEADER}"

# Load tax recorded by serve.sh (same for all shapes this session).
LOAD_S="na"
if [ -f "$REPO_ROOT/.ahl_serve_state" ]; then
  RUNBOOK_SERVED=""; LOAD_S=""
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.ahl_serve_state"
  { [ "${RUNBOOK_SERVED:-}" = "$(realpath "$RUNBOOK")" ] && [ -n "$LOAD_S" ]; } || LOAD_S="na"
fi

"$ADAPTER" health >/dev/null 2>&1 || { echo "endpoint not healthy at $TARGET — run serve.sh first" >&2; exit 1; }

# GuideLLM version for the `knobs` column. Resolved ONCE per run (a local CLI call — it never
# touches the server); degrades to `na` rather than failing the bench. Not lazy: knobs_string runs
# inside a command substitution, so a cache populated there would not survive into the parent.
GUIDELLM_VER="$(timeout 120 uv run --project "$REPO_ROOT" guidellm --version 2>/dev/null \
  | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)"
: "${GUIDELLM_VER:=na}"

# emit_row writes ONE 23-column results.tsv row (docs/validity-contract.md §2). Column order is
# fixed by the contract: the three validity columns sit after peak_gb and before the preserved
# `status notes data` tail. Args are named below rather than used positionally in the printf, so
# adding a column stays a two-line change instead of a 23-way miscount.
# tsv_safe <value> [fallback]: contract §2 — "no value is ever empty (`na`), and none contains a
# tab or newline". `knobs` is normalized by the library, but `notes` is assembled here out of
# operator-supplied $NOTES and the thermal sidecar, so it is the one field that can still carry a
# tab and shift every column to its right by one. A silently misaligned journal row is precisely
# the class of defect this layer exists to stop, so squash separators rather than trusting input.
tsv_safe() {
  local s="${1-}" fallback="${2:-na}"
  s="${s//$'\t'/ }"; s="${s//$'\n'/ }"; s="${s//$'\r'/ }"
  s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"   # trim
  printf '%s' "${s:-$fallback}"
}

emit_row() {
  local run_id="$1" shape_tag="$2" data_rel="$3" status="$4" notes="$5" peak="$6" \
        req_counts="$7" validity="$8" knobs="$9" t1="${10}" t4="${11}" t8="${12}" t16="${13}" t32="${14}"
  # ── CRITICAL SECTION: the WRITE is the atomic unit, not the flag ────────────────────────────
  # The first version of the interrupt work cleared `SHAPE_IN_FLIGHT` immediately BEFORE calling
  # this function. That made a second row impossible and the FIRST row skippable: between the
  # clear and the `printf … >> "$TSV"` below there are six command boundaries (`head`, `awk`,
  # `printf|awk`, the header `echo`, two `tsv_safe` substitutions), bash runs a trap at a command
  # boundary, and the handler found the flag already down, returned, and re-raised. A fully
  # COMPLETED sweep then left its bundle on disk and NOTHING in the journal while stderr printed
  # "recording the partial shape" — the exact hole the trap exists to close, in the other
  # direction, reproducible with a slow `head` on PATH (~6 ms window per shape).
  # So: signals arriving from here to the end of this function are DEFERRED (on_signal records
  # them and returns), the row is appended, `SHAPE_IN_FLIGHT` is cleared as the LAST statement,
  # and only then is the deferred signal honoured — against a flag that is now correctly down.
  IR_CRITICAL=1
  # A pre-migration 20-column journal must never receive 23-column rows: csv.DictReader keys by
  # header, so the extra fields would land under no column at all and `status`/`notes`/`data`
  # would be read from tps cells. Refuse, and park the row beside the journal so the measurement
  # is not lost while the operator runs scripts/migrate_results_tsv.py.
  if [ -f "$TSV" ]; then
    local have want
    have="$(head -1 "$TSV" | awk -F'\t' '{print NF}')"
    want="$(printf '%s' "$HEADER" | awk -F'\t' '{print NF}')"
    if [ "$have" != "$want" ]; then
      echo "  !! $TSV has a $have-column header; this row is $want columns (docs/validity-contract.md §2)" >&2
      echo "     migrate it first:  uv run --project $REPO_ROOT python scripts/migrate_results_tsv.py" >&2
      echo "     row parked -> ${TSV}.pending-migration" >&2
      TSV="${TSV}.pending-migration"
      [ -f "$TSV" ] || echo "$HEADER" > "$TSV"
      SCHEMA_MISMATCH=1
    fi
  fi
  [ -f "$TSV" ] || echo "$HEADER" > "$TSV"
  notes="$(tsv_safe "$notes")"; knobs="$(tsv_safe "$knobs")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$run_id" "$COMMIT" "$NODE_FP" "$MODEL" "$shape_tag" "$BACKEND" "$CONFIG_HASH" "$SCRIPT_REL" \
    "${LOAD_S:-na}" "$MAX_SECONDS" "$SEED" \
    "${t1:-na}" "${t4:-na}" "${t8:-na}" "${t16:-na}" "${t32:-na}" "${peak:-na}" \
    "${req_counts:-na}" "${validity:-na}" "${knobs:-na}" \
    "$status" "${notes:-na}" "$data_rel" >> "$TSV"
  SHAPE_IN_FLIGHT=0                 # LAST statement: the shape is journalled, nothing is owed
  ir_critical_end                   # honour any signal that arrived while the row was landing
}

# ir_critical_end: leave the append's critical section and honour whatever was deferred into it.
# Split out so `emit_row` reads as one linear write; called nowhere else.
ir_critical_end() {
  IR_CRITICAL=0
  [ -n "$IR_PENDING_SIG" ] || return 0
  local sig="$IR_PENDING_SIG"; IR_PENDING_SIG=""
  on_signal "$sig"
}

# row_already_journalled <run_id>: does the CURRENT journal already carry a row for this run?
# The idempotence backstop for `emit_interrupted_row`. The deferral above should make a
# double-write unreachable, but a `set -e` abort part-way through `emit_row` reaches the EXIT
# trap with the flag still up, and a duplicate row corrupts every median taken over the journal —
# a worse outcome than the missing row this whole mechanism exists to prevent. One `awk`, so the
# check itself is a single command boundary.
row_already_journalled() {
  local rid="${1:-}"
  [ -n "$rid" ] && [ -f "$TSV" ] || return 1
  awk -F'\t' -v r="$rid" 'NR>1 && $1==r {found=1} END{exit !found}' "$TSV" 2>/dev/null
}

# ahl_kill_tree <pid> [signal]: signal a pid AND its descendants, deepest first.
# Scoped by parentage (`pgrep -P`), never by a `-f <pattern>` match: the stall-watchdog used to
# reap its guidellm with a box-wide `pkill -f 'guidellm benchmark run'`, which on a shared box
# kills whatever benchmark happens to be running — see the watchdog's own comment.
ahl_kill_tree() {
  local pid="${1:-}" sig="${2:-TERM}" child
  [ -n "$pid" ] || return 0
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do ahl_kill_tree "$child" "$sig"; done
  kill -s "$sig" "$pid" 2>/dev/null || true
}

# ── Validity plumbing (docs/validity-contract.md) ──────────────────────────────
# knobs_string <prompt> <output>: the RESOLVED knob set, not the defaults in this header. Motivating
# defect: a baseline at MAX_SECONDS=600 and a finalize at the 180 default were indistinguishable in
# the journal until someone compared curve shapes.
#
# The ENCODING is the library's (`ahl_knobs`), not this script's. Hand-formatting it here produced
# `levels=1,16` — the comma form v1.1 withdrew precisely because the pair separator is also a
# comma, so a naive split(",") read the levels list as the two pairs `levels=1` and `16`, silently
# dropping every level after the first. The library joins list values with `|`. One encoder.
knobs_string() {
  local s=""
  s="$(ahl_knobs "levels=$(IFS=,; echo "${LEVELS[*]}")" "max_s=$MAX_SECONDS" "seed=$SEED" \
                 "prompt=$1" "output=$2" "stall=$STALL_SECS" "ltimeout=$LEVEL_TIMEOUT" \
                 "gllm=$GUIDELLM_VER" 2>/dev/null)" || s=""
  # Losing the knob metadata must never abort a measurement, so degrade to the same encoding
  # by hand (`|` between list items) rather than letting set -e kill the run.
  [ -n "$s" ] || s="levels=$(IFS='|'; echo "${LEVELS[*]}"),max_s=$MAX_SECONDS,seed=$SEED,prompt=$1,output=$2,stall=$STALL_SECS,ltimeout=$LEVEL_TIMEOUT,gllm=$GUIDELLM_VER"
  printf '%s' "$s"
}

# check_validity <bundle> <levels_csv> <tps_csv>
#   Delegates every rule to scripts/lib/validity.sh (contract §1: this file must not re-implement
#   any of them). Sets VALIDITY / REQ_COUNTS / STATUS_FLOOR (one of ok|suspect|void).
#   <tps_csv> is positionally aligned with <levels_csv> and MAY contain the non-numeric literals
#   `na` / `hang`; nothing here does arithmetic on it, so a hung level cannot blow up under set -e.
#
#   The library's contract is ONE tab-separated line on stdout: "<validity>\t<req_counts>\t<floor>".
#   That is the only channel. (There was a second branch here reading AHL_VALIDITY/AHL_STATUS_FLOOR
#   "globals the shim may set" — nothing in the repo has ever set them, and the two lines above the
#   branch cleared them unconditionally, so it was dead on arrival while carrying a comment saying
#   it was live. This repo has already paid 75 minutes of eval time for one correct-looking guard in
#   an unreachable branch; a second one is not a style question. Deleted.)
#
#   FAIL CLOSED: rc != 0, no output, or an unreadable floor ⇒ no verdict was reached, so the row
#   cannot be cited either way. `void` matches bench_ds4.sh / bench_llamacpp.sh exactly.
check_validity() {
  local bundle="$1" levels_csv="$2" tps_csv="$3" out err rc=0
  # STATUS_FLOOR starts EMPTY, not `void`: the `*)` arm below is what turns an unreadable answer
  # into `void` AND prints why. Pre-seeding it with a valid value would satisfy the case and skip
  # the diagnostic — the same unreachable-branch shape this rewrite exists to remove.
  VALIDITY="na"; REQ_COUNTS="na"; STATUS_FLOOR=""
  # The bundle directory is EVIDENCE. Scratch files belong outside it, or every run mutates the
  # very thing a later audit reads (and `.validity.err` from a failed run outlives its cause).
  out="$(mktemp -t ahl-validity-out.XXXXXX)"; err="$(mktemp -t ahl-validity-err.XXXXXX)"
  ahl_validity "$bundle" "$levels_csv" "$tps_csv" \
      --node-profile "$NODE_PROFILE" >"$out" 2>"$err" || rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$out" ]; then
    IFS=$'\t' read -r VALIDITY REQ_COUNTS STATUS_FLOOR < "$out" || true
    VALIDITY="${VALIDITY:-na}"; REQ_COUNTS="${REQ_COUNTS:-na}"; STATUS_FLOOR="${STATUS_FLOOR:-}"
  fi
  case "$STATUS_FLOOR" in
    ok|suspect|void) ;;
    *) STATUS_FLOOR="void"
       echo "  !! validity: scripts/lib/validity.sh gave no usable verdict (rc=$rc) — row is NOT citable" >&2
       sed -n '1,5p' "$err" | sed 's/^/     /' >&2 || true
       echo "     recorded as status=void validity=${VALIDITY:-na}; re-run the check by hand:" >&2
       echo "     scripts/lib/validity.sh validity '$bundle' '$levels_csv' '$tps_csv' --node-profile '$NODE_PROFILE'" >&2 ;;
  esac
  rm -f "$out" "$err"
}

# ── Interrupt safety: an interrupted shape must still leave a journal row ──────
# THE HOLE. `emit_row` is called once, AFTER the level loop. Anything that ended the process
# mid-shape — an operator Ctrl-C, a session/CI timeout, `kill`, a reboot, an OOM that took the
# script rather than the engine — left the `data/<run_id>/` bundle on disk holding REAL
# `level_c*.json` evidence that no journal row referenced. Two such orphans exist on this node
# today. Evidence outside the committed record is evidence nothing can audit, cite or refuse.
#
# WHAT THE PARTIAL ROW SAYS, and why each field is that value and not a nicer one:
#   status=suspect  Never `measured`: since v1.2 that means "the invariants passed", i.e. valid
#                   data, and this is not a completed sweep. Never `crash`: that is the
#                   engine-wedge signal, counted in this node's wedge audit (10 events, upstream
#                   vLLM #43885) — an operator's Ctrl-C is not a wedge and must not enter that
#                   record. Not `void` either: `void` means "not data", and a level that ran to
#                   completion is real data — voiding it would be the same lie in the opposite
#                   direction. `suspect` is precisely "real numbers, an open question, not
#                   citable until a human records an adjudication" (docs/validity-contract.md §6).
#                   A FATAL verdict from the library still outranks it and floors the row `void`.
#   validity        The library's verdict over the levels that COMPLETED — computed by the same
#                   check_validity() the normal path uses, never hand-made here (§1).
#   tps_c<in-flight> `na` (= level not run), never `hang`. `hang` claims a wedge.
#   peak_gb=na      The run never reached the peakmem probe. Not recovered — not a default.
#   notes           `interrupted(SIGINT)@c16`, so the reason survives in the committed journal.
#
# EXACTLY ONCE, IN BOTH DIRECTIONS. The write is the atomic unit: `emit_row` opens a critical
# section, appends, and clears `SHAPE_IN_FLIGHT` as its LAST statement; a signal arriving inside
# that section is deferred and honoured afterwards, against a flag that is by then correctly
# down. `emit_interrupted_row` additionally refuses to write a run_id the journal already carries.
# So a completed shape writes exactly one row (never zero, never two) and an interrupted one
# writes exactly one — a duplicate would corrupt every median taken over the journal, and a
# missing row is the hole this whole mechanism exists to close.
SHAPE_IN_FLIGHT=0
IR_CRITICAL=0            # 1 while a row is being appended: a signal here is DEFERRED, not acted on
IR_PENDING_SIG=""        # the signal that arrived during a critical section, replayed on exit from it
IR_HANDLING=0            # 1 while on_signal/on_exit is recording — blocks re-entry
IR_RUN_ID=""; IR_SHAPE_TAG=""; IR_BUNDLE=""; IR_DATA_REL=""; IR_LEVEL=""
IR_PROMPT=""; IR_OUTPUT=""; IR_SAMPLER_PID=""; IR_LEVEL_PID=""; IR_WATCHDOG_PID=""
IR_TPS=(na na na na na); IR_RAN_LEVELS=(); IR_RAN_TPS=()
IR_CRASHED=0; IR_CRASH_LEVEL=""; IR_CRASH_TEARDOWN_DONE=0

# HANDLER WORK IS BOUNDED. Every child the handler starts runs under `timeout`: `metrics_sampler
# --summary`, `ahl_knobs` and `ahl_validity` all shell out, the last two through `uv`, which can
# block on a uv lock the live bench is holding. An unbounded handler is a handler a supervisor
# escalates past, which loses the row.
IR_HANDLER_TIMEOUT="${IR_HANDLER_TIMEOUT:-20}"

# ir_bound_python: put the handler's library calls under that bound. `scripts/lib/validity.sh`'s
# `_ahl_py` expands `$AHL_PYTHON` UNQUOTED, so prefixing it with `timeout` bounds both `ahl_knobs`
# and `ahl_validity` without re-implementing or re-sourcing either (contract §1 — the handler must
# not grow its own copy of the rules). Only ever called on the abort path, so the normal bench is
# untouched. Assumes no spaces in the interpreter path, which is already `_ahl_py`'s assumption.
ir_bound_python() {
  local base="${AHL_PYTHON:-}"
  if [ -z "$base" ]; then
    if command -v uv >/dev/null 2>&1; then base="uv run --project $AHL_REPO_ROOT --quiet python"
    else base="python3"; fi
  fi
  case "$base" in timeout\ *) return 0 ;; esac       # already bounded
  AHL_PYTHON="timeout $IR_HANDLER_TIMEOUT $base"
}

# crash_teardown: preserve the engine log, then release the GPU. IDEMPOTENT, and reachable from
# the signal path as well as the normal one. bench.sh argues at length that a Ctrl-C must not
# ENTER this node's wedge record; the opposite — a real wedge silently LEAVING it — was
# unguarded: a signal in the ~0.5 s between "c$N hung" and the crash row wrote the interrupted
# row instead, skipped `docker logs > vllm_crash.log` (the one artefact the vLLM #43885 protocol
# asks for) and skipped `adapter down`, leaving a wedged container holding the GPU.
crash_teardown() {
  [ "$IR_CRASHED" = 1 ] || return 0
  [ "$IR_CRASH_TEARDOWN_DONE" = 1 ] && return 0
  IR_CRASH_TEARDOWN_DONE=1
  timeout "$IR_HANDLER_TIMEOUT" docker logs "$CONTAINER" >"$IR_BUNDLE/vllm_crash.log" 2>&1 || true
  echo "  saved engine logs -> $(realpath --relative-to="$REPO_ROOT" "$IR_BUNDLE" 2>/dev/null || echo "$IR_BUNDLE")/vllm_crash.log" >&2
  timeout "$IR_HANDLER_TIMEOUT" "$ADAPTER" down || true
}

# emit_interrupted_row <reason>: write the row for a shape that never finished. Runs inside a
# trap, so every step that could fail is guarded — losing the row to `set -e` in the handler
# would reopen the exact hole this closes.
emit_interrupted_row() {
  [ "$SHAPE_IN_FLIGHT" = 1 ] || return 0
  # The journal, not the flag, is the record. If this run_id is already there, the shape landed.
  row_already_journalled "$IR_RUN_ID" && { SHAPE_IN_FLIGHT=0; return 0; }
  local reason="${1:-interrupted}" thermal knobs levels_csv tps_csv status notes where
  ir_bound_python                         # every library call below now runs under a hard bound
  # Stop the children first: the GuideLLM level still hammering the endpoint (its `timeout`
  # wrapper forwards the signal on), the stall-watchdog, and the metrics sampler — each of which
  # would otherwise outlive us.
  #
  # THE WATCHDOG IS NOT OPTIONAL HERE. It used to live only in `run_level`'s `local wd`, killed on
  # the normal path and never on this one, so an interrupt orphaned it with PPID 1. It then went
  # on polling `docker logs ahl-vllm` every 15 s forever (this path deliberately does not
  # `adapter down`, so the container keeps serving and its loop never ends) and, the first time a
  # LATER run genuinely stalled, fired its kill at the CURRENT run's GuideLLM. That run records
  # `status=crash notes=hang@cN` and a PHANTOM WEDGE enters this node's wedge record — the record
  # that feeds research/upstream/vllm-43885-gb10-wedge.md. For a project whose thesis is evidence
  # integrity that is the worst available failure, and it was live: 12 orphans were found running
  # on this box, leaked one per interrupt test.
  [ -n "$IR_WATCHDOG_PID" ] && { ahl_kill_tree "$IR_WATCHDOG_PID" TERM; \
                                 wait "$IR_WATCHDOG_PID" 2>/dev/null || true; IR_WATCHDOG_PID=""; }
  [ -n "$IR_LEVEL_PID" ] && { ahl_kill_tree "$IR_LEVEL_PID" TERM; }
  [ -n "$IR_SAMPLER_PID" ] && { ahl_kill_tree "$IR_SAMPLER_PID" TERM; \
                                wait "$IR_SAMPLER_PID" 2>/dev/null || true; IR_SAMPLER_PID=""; }
  thermal="$(timeout "$IR_HANDLER_TIMEOUT" "$SCRIPT_DIR/metrics_sampler.sh" --summary "$IR_BUNDLE/gpu_metrics.csv" 2>/dev/null || echo thermal=na)"
  knobs="$(knobs_string "$IR_PROMPT" "$IR_OUTPUT" 2>/dev/null || echo na)"
  levels_csv="$(IFS=,; echo "${IR_RAN_LEVELS[*]:-}")"; tps_csv="$(IFS=,; echo "${IR_RAN_TPS[*]:-}")"
  check_validity "$IR_BUNDLE" "$levels_csv" "$tps_csv" || true
  # `suspect` is the floor for an unfinished run; a fatal library verdict raises it to `void`.
  status="suspect"; [ "$STATUS_FLOOR" = "void" ] && status="void"
  where="${IR_LEVEL:+@c$IR_LEVEL}"
  notes="${NOTES:+$NOTES; }interrupted(${reason})${where}; partial shape, not a completed measurement; $thermal"
  # A WEDGE THAT WAS ALREADY DETECTED STAYS A WEDGE. If the level loop had already marked this
  # shape crashed, the signal arrived while the crash row was being assembled: `crash` is the
  # engine-wedge signal and this shape earned it. Contract §5 — crash outranks a validity floor.
  if [ "$IR_CRASHED" = 1 ]; then
    status="crash"
    notes="${NOTES:+$NOTES; }hang@c$IR_CRASH_LEVEL; interrupted(${reason}) while recording the wedge; $thermal"
  fi
  # ── Seam for the row-wide `incomplete_run` verdict (contract §1) ────────────────────────────
  # This row is a partial sweep and every consumer should be able to see that from `validity`
  # alone — `citability.py` scopes to level-tagged verdicts and ignores `status`, so an
  # interrupted row currently reads as citable at the levels that did land. The verdict must come
  # from scripts/lib/validity.py (a hand-assembled string here would be exactly the second
  # implementation §1 forbids). When the library exposes it, the ONE line to add is:
  #     VALIDITY="$(ahl_add_verdict "$VALIDITY" incomplete_run)"
  # placed here, before emit_row. Nothing else in this file changes.
  emit_row "$IR_RUN_ID" "$IR_SHAPE_TAG" "$IR_DATA_REL" "$status" "$notes" "na" \
    "$REQ_COUNTS" "$VALIDITY" "$knobs" \
    "${IR_TPS[0]}" "${IR_TPS[1]}" "${IR_TPS[2]}" "${IR_TPS[3]}" "${IR_TPS[4]}" || true
  echo "  !! INTERRUPTED (${reason})${where} — partial row recorded: status=$status validity=$VALIDITY" >&2
  echo "     c1=${IR_TPS[0]} c4=${IR_TPS[1]} c8=${IR_TPS[2]} c16=${IR_TPS[3]} c32=${IR_TPS[4]}  counts: $REQ_COUNTS" >&2
  echo "     row -> $(realpath --relative-to="$REPO_ROOT" "$TSV" 2>/dev/null || echo "$TSV")" >&2
}

# on_signal <SIGNAME>: record, then re-raise with the default disposition so the exit status is
# the conventional 128+N. Deliberately NOT exit 4: "the row is written but not citable, continue"
# is the wrong instruction to give a caller whose operator just pressed Ctrl-C.
#
# IT DOES NOT DISARM ITSELF. The first version ran `trap - INT TERM HUP EXIT` on entry and then
# spent several hundred ms in metrics_sampler / ahl_knobs / ahl_validity, so anything escalating
# in that window — SIGINT then SIGTERM, or SIGTERM twice, i.e. ordinary process-manager behaviour,
# not an insistent human — killed the script with the row unwritten. Instead the further signals
# are IGNORED for the duration of a now-BOUNDED handler (IR_HANDLER_TIMEOUT caps every child it
# starts), and the original signal is re-raised at the end with its default disposition, so the
# caller still sees 128+N. The trade-off is deliberate and small: a second Ctrl-C no longer aborts
# the write, it merely arrives a fraction of a second early.
on_signal() {
  local sig="${1:-TERM}"
  # Mid-append: the row is landing right now. Note the signal and let `emit_row` finish.
  if [ "$IR_CRITICAL" = 1 ]; then IR_PENDING_SIG="$sig"; return 0; fi
  # Already recording: the first signal owns the write.
  if [ "$IR_HANDLING" = 1 ]; then IR_PENDING_SIG="$sig"; return 0; fi
  IR_HANDLING=1
  trap '' INT TERM HUP                    # ignored, not defaulted: an escalation must not win here
  trap - EXIT
  echo >&2; echo "== SIG$sig received — recording the shape in flight, if any, before exiting ==" >&2
  emit_interrupted_row "SIG$sig" || true
  crash_teardown || true                  # a detected wedge is still torn down and still logged
  trap - INT TERM HUP                     # back to the default disposition so the re-raise lands
  kill -s "$sig" $$ 2>/dev/null || true
  exit 1                                  # only reached if the signal is somehow ignored
}

# The EXIT arm covers the non-signal aborts: `set -e` on an unexpected failure, an untrapped
# signal (SIGPIPE, SIGUSR1) whose default action still runs this trap, or a caller that closed the
# shell. It is a no-op after a completed shape, because emit_row clears the flag.
on_exit() {
  local rc=$?
  [ "$IR_HANDLING" = 1 ] && return 0
  IR_HANDLING=1
  IR_CRITICAL=0                # an abort INSIDE the append must still be able to write the row
  # `rc=0` here does NOT mean a clean finish — a shape is in flight, so the shell simply had no
  # failing command to report (an untrapped SIGPIPE gets here with $? already reset). Say
  # "unfinished" so the journal never reads as a clean exit that somehow left a partial row.
  emit_interrupted_row "abort rc=$rc, shape unfinished" || true
  crash_teardown || true
  return 0
}
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP' HUP
trap on_exit EXIT

# watchdog <hit_file> <level_pid>: trip when vLLM reports zero generation throughput with
# requests still running, and reap ONLY the level it was started to guard.
#
# It takes the pid deliberately. The kill used to be `pkill -f 'guidellm benchmark run'` — an
# unscoped pattern match across the whole box. Combined with the orphaning bug above that is how
# a previous run's watchdog kills a current run's GuideLLM and manufactures a wedge event; even
# without it, this box is shared and a pattern kill hits whatever else is benching. `kill -0` on
# the guarded pid is also the loop's exit condition, so the watchdog cannot outlive its level
# even if nobody reaps it.
watchdog() {  # watchdog <hit_file> <level_pid>
  local hit="$1" victim="${2:-}" z=0
  while sleep 15; do
    [ -n "$victim" ] && { kill -0 "$victim" 2>/dev/null || return 0; }
    if docker logs --since 25s "$CONTAINER" 2>&1 | grep -E 'generation throughput' | tail -1 \
         | grep -qE 'generation throughput: 0\.0.*Running: [1-9]'; then
      z=$((z + 15)); [ "$z" -ge "$STALL_SECS" ] && {
        echo "stalled ${z}s (gen=0, reqs running)" >"$hit"
        ahl_kill_tree "$victim" TERM
        return; }
    else z=0; fi
  done
}

# run_level <bundle> <level> <data>: sets TPS_OUT; returns 0 ok / 3 crash. JSON kept per level.
#
# GuideLLM runs in the BACKGROUND and we `wait` for it, rather than running it in the foreground.
# The difference is the whole interrupt story: bash defers a trap until the current FOREGROUND
# command finishes, so a targeted `kill -TERM $(pgrep bench.sh)` — a session limit, a CI timeout,
# a supervisor — would not reach the handler until the level ended or LEVEL_TIMEOUT (default
# max_s*2+120) expired, by which time the killer has usually followed up with SIGKILL and the row
# is lost anyway. `wait` is interruptible: the handler runs at once. (A terminal Ctrl-C signals
# the whole foreground process group and never had this problem, which is exactly why it would
# have been easy to ship the trap believing it worked.)
run_level() {
  local bundle="$1" level="$2" data="$3" hit="$1/.wd_c$2" json="$1/level_c$2.json"; rm -f "$hit"; TPS_OUT="hang"
  set +e
  ( cd "$bundle" && timeout "$LEVEL_TIMEOUT" uv run --project "$REPO_ROOT" guidellm benchmark run \
      --target "$TARGET" --model "$SERVED_NAME" --processor "${PROCESSOR:-$MODEL}" --random-seed "$SEED" \
      --profile concurrent --rate "$level" \
      --data "$data" --max-seconds "$MAX_SECONDS" --output-path "$json" ) >"$bundle/level_c$level.log" 2>&1 &
  IR_LEVEL_PID=$!
  # The watchdog starts AFTER the level so it can be told which pid it guards (its first act is a
  # 15 s sleep, so nothing is lost by the ordering). Its pid is a GLOBAL, not a `local wd`: the
  # interrupt path never reaches the `kill` below, and a watchdog that outlives its bench goes on
  # to kill someone else's — see the watchdog comment above.
  watchdog "$hit" "$IR_LEVEL_PID" &
  IR_WATCHDOG_PID=$!
  wait "$IR_LEVEL_PID"
  local rc=$?
  IR_LEVEL_PID=""
  set -e
  # Reap the TREE: the watchdog's own `sleep 15` survives a kill aimed at the shell alone, and an
  # orphaned `sleep` holding a pipe is what made the test harness leak a process per run.
  ahl_kill_tree "$IR_WATCHDOG_PID" TERM; wait "$IR_WATCHDOG_PID" 2>/dev/null || true
  IR_WATCHDOG_PID=""
  { [ -f "$hit" ] || [ "$rc" -ne 0 ] || [ ! -f "$json" ]; } && return 3
  TPS_OUT="$(jq -r '.benchmarks[0].metrics.output_tokens_per_second.successful.mean | (.*100|round)/100' "$json")"
  return 0
}

run_shape() {
  local shape="$1" prompt output
  case "$shape" in
    chat)  prompt="${PROMPT:-512}";  output="${OUTPUT:-256}" ;;
    coder) prompt="${PROMPT:-4096}"; output="${OUTPUT:-1024}" ;;
    *)     prompt="${PROMPT:?set PROMPT for custom shape}"; output="${OUTPUT:?set OUTPUT}" ;;
  esac
  local run_id shape_tag bundle data_rel data
  run_id="$(date -u +%Y%m%d-%H%M%S)-$shape"
  shape_tag="${shape}(${prompt}/${output})"
  bundle="$OUT_DIR/data/$run_id"; mkdir -p "$bundle"
  data_rel="$(realpath --relative-to="$REPO_ROOT" "$bundle")"
  data="prompt_tokens=${prompt},prompt_tokens_stdev=$((prompt/4)),prompt_tokens_min=$((prompt/2)),prompt_tokens_max=$((prompt*2)),"
  data+="output_tokens=${output},output_tokens_stdev=$((output/4)),output_tokens_min=$((output/4)),output_tokens_max=$((output*2))"

  # The sweep state is GLOBAL, not local: the interrupt trap has to be able to write the row for
  # whatever this shape had reached, and a `local` would be invisible to it. From the assignment
  # of SHAPE_IN_FLIGHT below until the row is emitted, this bundle is unreferenced evidence.
  IR_RUN_ID="$run_id"; IR_SHAPE_TAG="$shape_tag"; IR_BUNDLE="$bundle"; IR_DATA_REL="$data_rel"
  IR_PROMPT="$prompt"; IR_OUTPUT="$output"; IR_LEVEL=""; IR_SAMPLER_PID=""; IR_WATCHDOG_PID=""
  IR_TPS=(na na na na na); IR_RAN_LEVELS=(); IR_RAN_TPS=()
  IR_CRASHED=0; IR_CRASH_LEVEL=""; IR_CRASH_TEARDOWN_DONE=0
  SHAPE_IN_FLIGHT=1

  echo "== $shape (p$prompt/o$output) per-level sweep @ c${LEVELS[*]} (max_s=$MAX_SECONDS, seed=$SEED, stall=$STALL_SECS) ==" >&2
  # Sidecar: sample GPU power/temp/util for the whole shape sweep (thermal is a tok/s confounder).
  local sp=""; "$SCRIPT_DIR/metrics_sampler.sh" "$bundle/gpu_metrics.csv" 5 >/dev/null 2>&1 & sp=$!
  IR_SAMPLER_PID="$sp"
  # The crash state is the IR_* globals, not `local crashed=0 crash_level=""`: from the moment a
  # level is marked hung there is ~0.5 s of peakmem + thermal + knobs + validity work before the
  # crash row lands, and a signal in that window must still produce a CRASH row with its
  # forensics, not an interrupted one. A `local` would be invisible to the handler.
  local level idx
  for level in "${LEVELS[@]}"; do
    idx="$(col_index "$level")"; [ "$idx" -lt 0 ] && { echo "  skip invalid level $level" >&2; continue; }
    echo "  -- c$level --" >&2
    IR_LEVEL="$level"          # the level in flight — named by the trap, cleared once it lands
    if run_level "$bundle" "$level" "$data"; then
      IR_TPS[$idx]="$TPS_OUT"; IR_RAN_LEVELS+=("$level"); IR_RAN_TPS+=("$TPS_OUT"); IR_LEVEL=""
      echo "     c$level tok/s=$TPS_OUT" >&2
    else
      IR_TPS[$idx]="hang"; IR_RAN_LEVELS+=("$level"); IR_RAN_TPS+=("hang"); IR_LEVEL=""
      IR_CRASHED=1; IR_CRASH_LEVEL="$level"
      echo "  !! c$level hung/crashed — keeping lower levels, tearing down" >&2; break
    fi
  done

  ahl_kill_tree "$sp" TERM; wait "$sp" 2>/dev/null || true; IR_SAMPLER_PID=""
  local peak status notes thermal
  peak="$("$ADAPTER" peakmem 2>/dev/null || echo na)"
  thermal="$("$SCRIPT_DIR/metrics_sampler.sh" --summary "$bundle/gpu_metrics.csv" 2>/dev/null || echo thermal=na)"
  if [ "$IR_CRASHED" = 1 ]; then status="crash"; notes="${NOTES:+$NOTES; }hang@c$IR_CRASH_LEVEL; $thermal"
  else status="${STATUS:-measured}"; notes="${NOTES:+$NOTES; }$thermal"; fi

  # ── Validity (contract §5): record and flag, exit non-zero. The row is written either way. ──
  local knobs levels_csv tps_csv invalid=0
  knobs="$(knobs_string "$prompt" "$output")"
  levels_csv="$(IFS=,; echo "${IR_RAN_LEVELS[*]:-}")"; tps_csv="$(IFS=,; echo "${IR_RAN_TPS[*]:-}")"
  check_validity "$bundle" "$levels_csv" "$tps_csv"
  if [ "$STATUS_FLOOR" != "ok" ]; then
    invalid=1
    if [ "$IR_CRASHED" = 1 ]; then   # a crash outranks: keep status=crash, still record the verdict
      echo "  !! VALIDITY $VALIDITY (floor=$STATUS_FLOOR) — status stays crash; counts: $REQ_COUNTS" >&2
    else
      echo "  !! VALIDITY FAILURE: $VALIDITY — invariant(s) fired, status $status -> $STATUS_FLOOR" >&2
      echo "     counts (ok/incomplete/errored): $REQ_COUNTS" >&2
      echo "     knobs: $knobs" >&2
      echo "     this row is NOT citable — see docs/validity-contract.md §3" >&2
      status="$STATUS_FLOOR"
    fi
  fi

  # Hand the shape over to the normal writer. `emit_row` owns the handover: it defers signals for
  # the duration of the append and clears SHAPE_IN_FLIGHT as its last statement, so this shape can
  # neither lose its row to a signal arriving mid-write nor gain a second one afterwards.
  emit_row "$run_id" "$shape_tag" "$data_rel" "$status" "$notes" "$peak" \
    "$REQ_COUNTS" "$VALIDITY" "$knobs" \
    "${IR_TPS[0]}" "${IR_TPS[1]}" "${IR_TPS[2]}" "${IR_TPS[3]}" "${IR_TPS[4]}"
  echo "  $shape -> c1=${IR_TPS[0]} c4=${IR_TPS[1]} c8=${IR_TPS[2]} c16=${IR_TPS[3]} c32=${IR_TPS[4]}  [$status] validity=$VALIDITY" >&2
  if [ "$IR_CRASHED" = 1 ]; then
    crash_teardown        # idempotent, and reachable from the signal path too — see its comment
    return 3
  fi
  { [ "$invalid" = 1 ] || [ "$SCHEMA_MISMATCH" = 1 ]; } && return 4
  return 0
}

# Exit-code precedence across shapes: 3 (crash) > 4 (validity) > 0. A validity failure in shape 1
# must still be reported after a clean shape 2, so rc_all latches and is never lowered.
rc_all=0
for shape in "${SHAPES[@]}"; do
  rc=0; run_shape "$shape" || rc=$?
  case "$rc" in
    0) ;;
    3) rc_all=3; echo "stopping remaining shapes — server torn down after crash" >&2; break ;;
    4) [ "$rc_all" -eq 3 ] || rc_all=4 ;;
    *) [ "$rc_all" -eq 0 ] && rc_all="$rc" ;;
  esac
done
echo >&2; echo "row(s) -> $(realpath --relative-to="$REPO_ROOT" "$TSV")  (load ${LOAD_S}s)" >&2
[ "$SCHEMA_MISMATCH" = 1 ] && { [ "$rc_all" -eq 3 ] || rc_all=4; \
  echo "EXIT 4: the journal is pre-migration — rows were parked, not appended (see above)" >&2; }
[ "$rc_all" -eq 4 ] && echo "EXIT 4: one or more rows failed the measurement-validity invariants — do not cite them" >&2
exit $rc_all
