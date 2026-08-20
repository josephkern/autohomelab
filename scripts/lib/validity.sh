#!/usr/bin/env bash
# validity.sh — thin bash shim over scripts/lib/validity.py (docs/validity-contract.md §1).
#
# THIS FILE IMPLEMENTS NO RULES. Every threshold, verdict, column name and encoding lives in
# validity.py; everything here is argument marshalling. If you find yourself adding an
# arithmetic comparison or a column name to this file, it belongs in validity.py instead.
#
# Usage (source it; works from any CWD):
#     source "$REPO_ROOT/scripts/lib/validity.sh"
#     printf '%s\n' "$AHL_RESULTS_HEADER"                     # the 23-column header
#     ahl_level_counts "$bundle/level_c16.json"               # -> "118/4/0"; rc 1 if unparseable
#     ahl_validity "$bundle" 1,16 "41.2,na,na,151.5,na" \
#         --node-profile "$NP" --model-gb 6.5                 # -> "<validity>\t<req_counts>\t<floor>"
#     ahl_knobs levels=1\|16 max_s=180 seed=42                # -> "levels=1|16,max_s=180,seed=42"
#     ahl_split_verdict low_sample@c1                         # -> "low_sample<TAB>1"
#
# Extra (not part of the required API, but handy): $AHL_LEGACY_HEADER, $AHL_VALIDITY_PY,
# ahl_split_verdict.
#
# Verdict tokens are LEVEL-TAGGED (`low_sample@c1`, `no_data@c32`); the row-wide
# `nonmonotonic` stays bare. Never split them by hand -- use ahl_split_verdict.
#
# Python interpreter: `uv run --project <repo>` per charter rule 4, falling back to a bare
# python3 (validity.py is stdlib-only). Override wholesale with AHL_PYTHON="..." if needed.

# Deliberately NOT setting `set -euo pipefail` here: this file is SOURCED into callers that
# set their own shell options, and flipping them underneath a caller is a footgun. Every
# function below checks its own return codes.

# Repo root from BASH_SOURCE, so sourcing works no matter what the caller's CWD is.
AHL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AHL_REPO_ROOT="$(cd "$AHL_LIB_DIR/../.." && pwd)"
AHL_VALIDITY_PY="$AHL_LIB_DIR/validity.py"
export AHL_LIB_DIR AHL_REPO_ROOT AHL_VALIDITY_PY

# ── interpreter ───────────────────────────────────────────────────────────────
_ahl_py() {  # _ahl_py <args to validity.py...>
  if [ -n "${AHL_PYTHON:-}" ]; then
    # shellcheck disable=SC2086
    $AHL_PYTHON "$AHL_VALIDITY_PY" "$@"
  elif command -v uv >/dev/null 2>&1; then
    uv run --project "$AHL_REPO_ROOT" --quiet python "$AHL_VALIDITY_PY" "$@"
  elif command -v python3 >/dev/null 2>&1; then
    python3 "$AHL_VALIDITY_PY" "$@"
  else
    echo "validity.sh: no python interpreter (set AHL_PYTHON)" >&2
    return 127
  fi
}

# ── schema (contract §2) — fetched from the library, never hard-coded here ────
AHL_RESULTS_HEADER="$(_ahl_py header)" || {
  echo "validity.sh: could not load the results.tsv header from $AHL_VALIDITY_PY" >&2
  return 1 2>/dev/null || exit 1
}
AHL_LEGACY_HEADER="$(_ahl_py header --legacy)" || {
  echo "validity.sh: could not load the legacy header from $AHL_VALIDITY_PY" >&2
  return 1 2>/dev/null || exit 1
}
export AHL_RESULTS_HEADER AHL_LEGACY_HEADER

# ── API ───────────────────────────────────────────────────────────────────────

# ahl_level_counts <level_json>
#   Prints "ok/incomplete/errored" for one GuideLLM per-level bundle.
#   Returns 1 (and prints nothing on stdout) if the file is missing or unparseable.
ahl_level_counts() {
  local json="${1:-}"
  [ -n "$json" ] || { echo "ahl_level_counts: usage: ahl_level_counts <level_json>" >&2; return 1; }
  _ahl_py level "$json"
}

# ahl_validity <bundle_dir> <levels_csv> <tps_csv> [--node-profile P] [--model-gb G]
#   Prints ONE tab-separated line: <validity>\t<req_counts>\t<status_floor>
#   <tps_csv> is the 5 fixed tps_c* cells (c1,c4,c8,c16,c32); `na`/`hang` are accepted.
#   Returns non-zero only if the library itself failed (a *failing* validity check is a
#   normal result, reported in the fields — the caller decides on exit 4, per contract §5).
#   A non-zero return means NO VERDICT WAS REACHED: every caller must fail CLOSED on it
#   (floor the row at least `suspect` and exit 4), never fall back to `ok` — contract v1.2 A6.
#   Trailing args are passed straight through to `validity.py check`, which is how a caller
#   supplies `--node-profile` (required for the §4 roofline) and `--model-gb`. `--discover`
#   exists there too, but ONLY the audit/migration path may pass it: it scores level jsons the
#   caller did not list, which is wrong for a live bench (contract v1.2 A10).
ahl_validity() {
  local bundle="${1:-}" levels="${2:-}" tps="${3:-}"
  [ -n "$bundle" ] && [ -n "$levels" ] || {
    echo "ahl_validity: usage: ahl_validity <bundle_dir> <levels_csv> <tps_csv> [--node-profile P] [--model-gb G]" >&2
    return 2
  }
  shift 3 2>/dev/null || shift $#

  local out
  out="$(_ahl_py check --bundle "$bundle" --levels "$levels" --tps "$tps" "$@")" || return $?
  # Field extraction only — the values themselves are decided by validity.py.
  printf '%s' "$out" | _ahl_json3 || return $?
}

# Internal: turn the {"validity":..,"req_counts":..,"status_floor":..} object on stdin into
# one tab-separated line. jq is already a hard dependency of bench.sh; python is the fallback.
_ahl_json3() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '[.validity, .req_counts, .status_floor] | @tsv'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; d=json.load(sys.stdin); print("\t".join([d["validity"],d["req_counts"],d["status_floor"]]))'
  else
    echo "validity.sh: need jq or python3 to read the validity result" >&2
    return 127
  fi
}

# ahl_knobs k=v [k=v ...]
#   Prints the normalized knobs string, e.g. "levels=1|16,max_s=180,seed=42".
#   List values join with `|`, never a comma, so a naive split(",") on the result is
#   always correct. Any comma inside a value is rewritten to `|`. No pairs -> "na".
ahl_knobs() {
  _ahl_py knobs "$@"
}

# ahl_add_verdict <validity> <token> [token ...]
#   Prints `validity` with the token(s) added, canonically ordered and deduped by the library.
#   Used by the benchers to record a fact the RULES cannot compute (an interrupted run). Fails
#   closed: non-zero with empty stdout, so a caller substituting it keeps its old string rather
#   than silently dropping a verdict.
ahl_add_verdict() {
  [ "$#" -ge 2 ] || { echo "ahl_add_verdict: usage: ahl_add_verdict <validity> <token>..." >&2; return 2; }
  _ahl_py addverdict "$@"
}

# ahl_split_verdict <token>
#   Splits one verdict token into "<base><TAB><level>"; <level> is `na` for the row-wide
#   tokens (`ok`, `nonmonotonic`). e.g. `low_sample@c1` -> "low_sample<TAB>1".
ahl_split_verdict() {
  local tok="${1:-}"
  [ -n "$tok" ] || { echo "ahl_split_verdict: usage: ahl_split_verdict <token>" >&2; return 2; }
  _ahl_py split "$tok"
}

# ── Direct execution ──────────────────────────────────────────────────────────
# The shim is normally SOURCED (callers want the functions and $AHL_RESULTS_HEADER).
# When run as a program, answer the few things a non-bash caller needs, so the 23-column
# header still has exactly one definition (contract §1) no matter who is asking.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    header|--header|columns) printf '%s\n' "$AHL_RESULTS_HEADER" ;;
    validity)  shift; ahl_validity "$@" ;;
    counts)    shift; ahl_level_counts "$@" ;;
    knobs)     shift; ahl_knobs "$@" ;;
    split)     shift; ahl_split_verdict "$@" ;;
    *) echo "usage: validity.sh {header|validity|counts|knobs|split} [args...]" >&2; exit 2 ;;
  esac
fi
