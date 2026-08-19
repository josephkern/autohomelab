#!/usr/bin/env bash
# promote.sh <winning_runbook.sh> ["result note"] — when a model's tuning campaign is complete,
# promote the chosen config to a canonical `_final.sh`. The `_tuned.sh` experiment artifacts are
# left intact (project record); the `_final.sh` is what you actually serve.
#
# Runbook file types in a model dir:
#   baseline.sh         generated start (gen_baseline.py)
#   *_tuned.sh          experiment variants (kept as artifacts)
#   *_final.sh          promoted campaign winner — the canonical config
#
# ── MEASUREMENT-VALIDITY GATE (docs/validity-contract.md §3/§5/§6) ────────────
# Promotion is the act of citing a measurement forever, so it refuses to run when the measurement
# it CITES is not citable — and equally when there are NO supporting rows at all. A promotion with
# nothing behind it is the same defect as one behind a bad number.
#
# WHAT IS GATED (the rule, in full, is in scripts/citability.py's `cmd_gate` comment):
#   The promotion cites ONE number — the tuning objective, chat-shape median c16 (AGENTS.md hard
#   rule 2). So the supporting rows (same config_hash) are split in two:
#     * OBJECTIVE rows (chat shape, c16 actually run) are the evidence. At least one must be
#       citable AT c16 — i.e. not `void`, not `suspect` and not `crash` at that level — and NO
#       objective row may be fatal at c16 (`no_data@c16`, `over_roofline@c16` -> `void`) or a
#       `crash` — one of those blocks absolutely, however many clean rows sit beside it.
#       A `suspect` objective row does not block on its own while a citable one exists, but it
#       is always listed.
#     * every OTHER row (another shape, or one that never ran c16) is REPORTED loudly and
#       recorded in the promoted artifact, but does not block. A starved *coder* full-sweep row
#       is a real problem and a real note in the record; it is not evidence about chat c16, and
#       blocking on it was making the gate wrong on 14 of 92 config groups — a gate that is wrong
#       that often gets switched off, and then it protects nothing.
#   Objective override: AHL_PROMOTE_SHAPE (default `chat`), AHL_PROMOTE_LEVEL (default 16, or
#   `none` for a row-wide gate). If the config never ran the objective, the gate falls back to
#   the highest level it did run and says so — the ds4 / llama.cpp launchers bench c1 only.
#
# OVERRIDE — for the case where a human has ADJUDICATED the flagged rows:
#
#   AHL_PROMOTE_OVERRIDE="20260819 jk: c32 low_sample only; objective is c16, unaffected" \
#     scripts/promote.sh <runbook.sh> "note"
#
# The variable must carry a real justification (>= 12 chars; bare 1/y/yes/true/force are REJECTED —
# an override is an argument, not a flag). It is not a bypass, it is a signature: the promoted
# `_final.sh` records the justification, the adjudicator, the date and the exact offending run_ids,
# so a config promoted over a flagged measurement is traceable forever:
#
#   grep -l AHL_PROMOTION_OVERRIDE runbooks/*/*/*_final.sh
#
# SECURITY: operator text (the justification, $USER, the note, the gate detail) is written into the
# promoted `_final.sh` as COMMENT LINES ONLY — never as a shell assignment. `_final.sh` is `source`d
# by serve.sh/bench.sh, and an assignment whose value came from an environment variable executes
# whatever `$(...)` it contains at serve time. It was verified to do so. The greppable marker is now
# `# AHL_PROMOTION_OVERRIDE:` (a comment), so `grep -l AHL_PROMOTION_OVERRIDE` still enumerates
# every promotion built on an adjudicated row, with none of the executable surface.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Charter rule 4: python goes through uv when it is available (validity.py/citability.py are
# stdlib-only, so a bare python3 is a correct fallback and keeps this runnable on a bare box).
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
SRC="${1:?usage: promote.sh <winning_runbook.sh> [\"result note\"]}"
NOTE="${2:-}"
[ -f "$SRC" ] || { echo "not found: $SRC" >&2; exit 1; }

# Derive the canonical final name: VLLM-<minor>-<HFORG>_<BASEMODEL>_<QUANT>_final.sh
MODEL=""; VLLM_IMAGE=""
# shellcheck disable=SC1090
source "$SRC"; : "${MODEL:?runbook must set MODEL}"
ORG="${MODEL%%/*}"; [ "$ORG" = "$MODEL" ] && ORG="_"; LEAF="${MODEL##*/}"
# split a known quant suffix off the model leaf (so NVFP4 is its own token)
QUANT=""; BASE="$LEAF"
for q in NVFP4 MXFP4 FP8 FP4 INT8 INT4 AWQ GPTQ W8A8 W4A16; do
  case "$LEAF" in *-"$q") QUANT="$q"; BASE="${LEAF%-$q}"; break ;; esac
done
# vLLM minor version from the runbook's image comment (e.g. "v0.22.0" -> 22), override with VLLM_TAG
# NOTE: AGENTS.md tracks an open bug here (this greps the FIRST vX.Y.Z in the file, so a migration
# comment can win). Deliberately left exactly as found — fixing it is not this change's job.
VV="$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' "$SRC" | head -1 | sed 's/^v//' || true)"
VMINOR="${VLLM_TAG:-$(printf '%s' "$VV" | cut -d. -f2)}"; : "${VMINOR:=XX}"
NAME="VLLM-${VMINOR}-${ORG}_${BASE}"; [ -n "$QUANT" ] && NAME="${NAME}_${QUANT}"
OUT="$(dirname "$SRC")/${NAME}_final.sh"
[ -e "$OUT" ] && { echo "already exists: $OUT (remove it to re-promote)" >&2; exit 1; }

# ── Validity gate ─────────────────────────────────────────────────────────────
CFG="$(sha256sum "$SRC" | cut -c1-8)"
NODE_FP="$(find "$REPO_ROOT/results" -maxdepth 2 -name node_profile.json -printf '%h\n' 2>/dev/null | head -1 | xargs -r basename || true)"
TSV="$REPO_ROOT/results/${NODE_FP:-_}/$ORG/${MODEL##*/}/results.tsv"

set +e
GATE="$(ahl_py "$SCRIPT_DIR/citability.py" gate \
          --tsv "$TSV" --cfg "$CFG" \
          --shape "${AHL_PROMOTE_SHAPE-chat}" --level "${AHL_PROMOTE_LEVEL-16}")"
GATE_RC=$?
set -e
GATE_VERDICT="$(printf '%s\n' "$GATE" | head -1)"
# Detail = everything after the verdict, minus the two machine-readable id lines.
GATE_DETAIL="$(printf '%s\n' "$GATE" | tail -n +2 | grep -v '^ids=' | grep -v '^warnids=' || true)"
GATE_SUMMARY="$(printf '%s\n' "$GATE" | sed -n 2p)"
GATE_IDS="$(printf '%s\n' "$GATE" | sed -n 's/^ids=//p')"
GATE_WARN_IDS="$(printf '%s\n' "$GATE" | sed -n 's/^warnids=//p')"
# Rows outside the objective are never a refusal (see the header), but they are never silent
# either: on stderr now, and in the promoted artifact's header forever.
if [ -n "$GATE_WARN_IDS" ]; then
  echo "!! NOTE: supporting rows OUTSIDE the promoted objective are flagged (not blocking): $GATE_WARN_IDS" >&2
fi

OVERRIDE="${AHL_PROMOTE_OVERRIDE:-}"
if [ "$GATE_RC" != 0 ] || [ "$GATE_VERDICT" != ok ]; then
  echo "!! VALIDITY GATE FAILED for $(basename "$SRC") (config_hash $CFG)" >&2
  printf '%s\n' "$GATE_DETAIL" >&2
  if [ -z "$OVERRIDE" ]; then
    cat >&2 <<EOM
!! REFUSING to promote. Fix the measurement (re-bench with a stage budget that drains enough
!! requests — see AGENTS.md "MAX_SECONDS=180 is NOT universal"), or, if a human has ADJUDICATED
!! these rows, re-run with a written justification:
!!   AHL_PROMOTE_OVERRIDE="<YYYYMMDD who>: why these rows do not invalidate the promotion" \\
!!     scripts/promote.sh $SRC "note"
EOM
    exit 4
  fi
  case "${OVERRIDE,,}" in
    1|y|yes|true|force|override|ok) echo "!! AHL_PROMOTE_OVERRIDE must be a JUSTIFICATION, not a flag (got: '$OVERRIDE')" >&2; exit 4 ;;
  esac
  if [ "${#OVERRIDE}" -lt 12 ]; then
    echo "!! AHL_PROMOTE_OVERRIDE too short (${#OVERRIDE} chars) — write why the flagged rows were adjudicated" >&2
    exit 4
  fi
  echo "!! OVERRIDDEN by AHL_PROMOTE_OVERRIDE — recording the adjudication in the promoted artifact" >&2
else
  echo ">> validity gate: ok ($GATE_SUMMARY)" >&2
  printf '%s\n' "$GATE_DETAIL" | sed -n '2,$p' >&2   # notes/warnings; the summary is above
  OVERRIDE=""   # a clean gate never records an override, even if the var was set
fi

cp "$SRC" "$OUT"
DATE="$(date -u +%Y-%m-%d)"
# The promoted file is SOURCED by serve.sh/bench.sh. Operator-supplied text (justification, note,
# $USER, the gate detail) is therefore written as COMMENTS ONLY — never as a shell assignment.
ahl_py - "$OUT" "$SRC" "$DATE" "$NOTE" "$CFG" "$GATE_SUMMARY" "$GATE_DETAIL" "$OVERRIDE" "$GATE_IDS" "$GATE_WARN_IDS" "${USER:-unknown}" <<'PY'
import sys
out, src, date, note, cfg, summary, gate, override, ids, warn_ids, who = sys.argv[1:12]

# ── SECURITY (defect #1) ──────────────────────────────────────────────────────────────────────
# This banner used to emit `AHL_PROMOTION_OVERRIDE="<operator text>"` with only `"` neutralized.
# `_final.sh` is `source`d at serve time, so a justification containing $(...) or `...` EXECUTED
# then — verified, not theoretical. Nothing operator-controlled is emitted as an assignment any
# more; every such value goes out as a comment line, where $(...) is inert. `comment()` is the
# only door: it strips control characters (a newline would end the comment and start a command),
# collapses whitespace to a single line, and caps the length so one variable cannot bury the file.
MAX = 400


def comment(s, limit=MAX):
    """Operator text -> one safe, single-line comment payload."""
    flat = ' '.join((s or '').split())              # kills \n, \r, \t and runs of spaces
    flat = ''.join(ch for ch in flat if ch.isprintable())   # kills \x00, escapes, ANSI, etc.
    if len(flat) > limit:
        flat = flat[:limit - 1] + '…'
    return flat or 'na'


banner = [
    f"# FINAL (campaign-selected) — promoted from {comment(src)} on {date}.\n",
    (f"# Result: {comment(note)}\n" if note else "# Result: <fill in: best metric vs baseline>\n"),
    "# Canonical config to serve. The *_tuned.sh experiment artifacts are kept intact as record.\n",
    f"# Supporting benchmark rows (results.tsv config_hash={comment(cfg, 64)}): {comment(summary)}\n",
]
# Non-blocking problems outside the promoted objective are part of the permanent record too:
# the promotion did not cite them, but a reader of this file should know they exist.
if warn_ids.strip():
    banner += [
        "# NOTE: supporting rows OUTSIDE the promoted objective are flagged (they did not block\n",
        "#       this promotion because it does not cite them, but the campaign record is thin):\n",
        f"#       {comment(warn_ids)}\n",
    ]
if override:
    banner += [
        "#\n",
        "# !! PROMOTED OVER A FAILED MEASUREMENT-VALIDITY GATE (docs/validity-contract.md).\n",
        "# !! The supporting benchmark rows were flagged and a human adjudicated them.\n",
        f"# !! adjudicated by : {comment(who, 120)} on {date}\n",
        f"# !! justification  : {comment(override)}\n",
    ]
    for line in gate.splitlines():
        if line.startswith('ids=') or line.startswith('warnids='):
            continue
        banner.append(f"# !! gate           : {comment(line)}\n")
    banner += [
        "# !! Numbers cited for this config MUST carry this caveat.\n",
        "#\n",
        "# Greppable marker — this promotion was NOT supported by a clean measurement:\n",
        "#   grep -l AHL_PROMOTION_OVERRIDE runbooks/*/*/*_final.sh\n",
        "# It is a COMMENT, deliberately: this file is sourced at serve time, and operator text\n",
        "# in an assignment is operator text that runs (see promote.sh's header).\n",
        f"# AHL_PROMOTION_OVERRIDE: {comment(override)}\n",
        f"# AHL_PROMOTION_OVERRIDE_ROWS: {comment(ids)}\n",
        f"# AHL_PROMOTION_OVERRIDE_BY: {comment(who, 120)} {date}\n",
    ]
lines = open(out).read().splitlines(keepends=True)
# insert after shebang
if lines and lines[0].startswith("#!"):
    lines = lines[:1] + banner + lines[1:]
else:
    lines = banner + lines
open(out, "w").writelines(lines)
PY
chmod +x "$OUT"
echo "$OUT"
