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
# EXIT CODES (repo-wide ladder, docs/validity-contract.md §5): 0 promoted · 2 the INVOCATION was
# refused — no runbook, or the vLLM version cannot be derived from the pin (nothing was written;
# a usage error is not a result, so it is not 1) · 1 the promotion cannot proceed (the artifact
# already exists) · 4 the measurement-validity gate failed.
if [ "$#" -lt 1 ]; then
  echo "usage: promote.sh <winning_runbook.sh> [\"result note\"]" >&2; exit 2
fi
SRC="$1"
NOTE="${2:-}"
[ -f "$SRC" ] || { echo "not found: $SRC" >&2; exit 2; }

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
# ── vLLM minor version: derived from the PIN, never from PROSE (fixed 20260820) ───────────────
# The name `VLLM-<minor>-…` is a claim about which vLLM built the numbers behind the promotion, so
# it must come from the thing that is actually authoritative — the pinned `VLLM_IMAGE` — and it
# must REFUSE rather than guess.
#
# What it used to do: `grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' "$SRC" | head -1`, i.e. the first
# version-shaped token anywhere in the runbook TEXT. A baseline header reading
# "image v0.22.0 -> v0.23.0" therefore named a 0.23.0 config `VLLM-22-…`: the file was named after
# the version being migrated AWAY from. Workaround was `VLLM_TAG=<minor>` by hand.
#
# A TRAILING COMMENT ON THE `VLLM_IMAGE=` LINE IS PROSE TOO, and reading it back is the same bug
# in a smaller window. Verified failing input:
#     VLLM_IMAGE="vllm/vllm-openai@sha256:aaaa…9999"  # was v0.24.0; now v0.28.0
#   -> the line yields 0.24.0 and names a 0.28.0 config VLLM-24-… . It fires precisely in the
#      uncatalogued case, which is where an operator is sloppiest.
# So this reads `$VLLM_IMAGE`'s VALUE (the runbook is already sourced above, so the comment is
# gone by construction) in three steps, and stops:
#   1. VLLM_TAG=<minor>            explicit operator override
#   2. backends/vllm/image.lock    the catalog entry for this exact digest / ref
#   3. the image REF's own TAG     `…:v0.24.0` — never a comment
# A bare digest that is not in image.lock is REFUSED: add it to the catalog (where a validated
# image belongs anyway) or pass VLLM_TAG. Whatever comes out must be NUMERIC — `cut -d. -f2` on a
# catalog key like `0.23-fix` yields `23-fix`, and `VLLM_TAG=abc` yielded `VLLM-abc-…`.
VMINOR=""; VSRC=""
minor_of() {   # <version-ish token> -> its minor field, or empty
  printf '%s' "$1" | sed -n 's/^[vV]\?[0-9][0-9]*\.\([0-9][0-9]*\)\..*$/\1/p'
}
if [ -n "${VLLM_TAG:-}" ]; then
  VMINOR="$VLLM_TAG"; VSRC="VLLM_TAG"
elif [ -n "${VLLM_IMAGE:-}" ]; then
  # (2) the catalog. Look the pin up by its DIGEST when it has one (exact, unambiguous) and by
  # the whole ref otherwise; take the first version-shaped token on the matching line — which is
  # the catalog KEY (`# v0.27.1  <ref>  serve=yes`) or the default pin's `# v0.25.0` marker.
  LOCK="$REPO_ROOT/backends/vllm/image.lock"
  case "$VLLM_IMAGE" in *@sha256:*) NEEDLE="${VLLM_IMAGE#*@}" ;; *) NEEDLE="$VLLM_IMAGE" ;; esac
  if [ -f "$LOCK" ]; then
    LOCK_LINE="$(grep -F -m1 -- "$NEEDLE" "$LOCK" || true)"
    if [ -n "$LOCK_LINE" ]; then
      VMINOR="$(minor_of "$(printf '%s' "$LOCK_LINE" | grep -oE '[vV]?[0-9]+\.[0-9]+\.[0-9]+' | head -1)")"
      if [ -n "$VMINOR" ]; then VSRC="image.lock catalog entry for ${NEEDLE}"; fi
    fi
  fi
  if [ -z "$VMINOR" ]; then
    # (3) the ref's TAG only: strip any digest, then take what follows the last `:` — and only if
    # that path segment really carries one (`repo:tag`, not `host:5000/repo`).
    REF_NO_DIGEST="${VLLM_IMAGE%@*}"; LAST_SEG="${REF_NO_DIGEST##*/}"
    case "$LAST_SEG" in
      *:*) IMG_TAG="${LAST_SEG##*:}" ;;
      *)   IMG_TAG="" ;;
    esac
    if [ -n "$IMG_TAG" ]; then
      VMINOR="$(minor_of "$(printf '%s' "$IMG_TAG" | grep -oE '[vV]?[0-9]+\.[0-9]+\.[0-9]+' | head -1)")"
      if [ -n "$VMINOR" ]; then VSRC="image tag '${IMG_TAG}'"; fi
    fi
  fi
fi
if [ -z "$VMINOR" ]; then
  cat >&2 <<EOM
!! REFUSING to promote: cannot derive the vLLM minor version from the PIN.
!!   VLLM_IMAGE = ${VLLM_IMAGE:-<unset>}
!! It is not in $REPO_ROOT/backends/vllm/image.lock and its ref carries no vX.Y.Z tag, so the only
!! version strings left in the runbook are COMMENTS — and naming a promoted config after a comment
!! is the bug this derivation exists to stop (a header saying "was v0.24.0; now v0.28.0" named a
!! 0.28.0 config VLLM-24-…). Fix it at the source:
!!   * add this image to backends/vllm/image.lock (a promoted config should be on a validated,
!!     catalogued image anyway), or
!!   * re-run with VLLM_TAG=<minor>, e.g. VLLM_TAG=28
EOM
  exit 2
fi
case "$VMINOR" in
  ''|*[!0-9]*)
    echo "!! REFUSING to promote: derived vLLM minor '$VMINOR' (from $VSRC) is not numeric." >&2
    echo "!! The name is VLLM-<minor>-…; pass VLLM_TAG=<digits> if the source is a non-standard tag." >&2
    exit 2 ;;
esac
echo ">> vLLM minor: $VMINOR (from $VSRC)" >&2
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
# Journal path relative to the repo root, so the recorded command is runnable from a clone.
REL_TSV="${TSV#"$REPO_ROOT"/}"
# How a reader gets from this verdict back to the rows it was made on, without trusting a
# per-row stamp. THIS FILE is the keep verdict (contract v1.3 retired `keep` as a row status).
CITE_CMD="scripts/citability.py gate --tsv $REL_TSV --cfg $CFG --shape ${AHL_PROMOTE_SHAPE-chat} --level ${AHL_PROMOTE_LEVEL-16}"
ahl_py - "$OUT" "$SRC" "$DATE" "$NOTE" "$CFG" "$GATE_SUMMARY" "$GATE_DETAIL" "$OVERRIDE" "$GATE_IDS" "$GATE_WARN_IDS" "${USER:-unknown}" "$CITE_CMD" <<'PY'
import sys
out, src, date, note, cfg, summary, gate, override, ids, warn_ids, who, cite_cmd = sys.argv[1:13]

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
    # The row `status` column is a VALIDITY state, never a keep/discard verdict. THIS FILE is
    # the keep verdict; the line below is how a reader gets back to the supporting rows.
    f"# Re-derive those rows: {comment(cite_cmd, 300)}\n",
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
