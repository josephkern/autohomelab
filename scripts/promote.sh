#!/usr/bin/env bash
# promote.sh <winning_runbook.sh> ["result note"] — when a model's tuning campaign is complete,
# promote the chosen config to a canonical `_final.sh`. The `_tuned.sh` experiment artifacts are
# left intact (project record); the `_final.sh` is what you actually serve.
#
# Runbook file types in a model dir:
#   baseline.sh         generated start (gen_baseline.py)
#   *_tuned.sh          experiment variants (kept as artifacts)
#   *_final.sh          promoted campaign winner — the canonical config
set -euo pipefail
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
VV="$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' "$SRC" | head -1 | sed 's/^v//' || true)"
VMINOR="${VLLM_TAG:-$(printf '%s' "$VV" | cut -d. -f2)}"; : "${VMINOR:=XX}"
NAME="VLLM-${VMINOR}-${ORG}_${BASE}"; [ -n "$QUANT" ] && NAME="${NAME}_${QUANT}"
OUT="$(dirname "$SRC")/${NAME}_final.sh"
[ -e "$OUT" ] && { echo "already exists: $OUT (remove it to re-promote)" >&2; exit 1; }

cp "$SRC" "$OUT"
DATE="$(date -u +%Y-%m-%d)"
python3 - "$OUT" "$SRC" "$DATE" "$NOTE" <<'PY'
import sys
out, src, date, note = sys.argv[1:5]
lines = open(out).read().splitlines(keepends=True)
banner = [
    f"# FINAL (campaign-selected) — promoted from {src} on {date}.\n",
    (f"# Result: {note}\n" if note else "# Result: <fill in: best metric vs baseline>\n"),
    "# Canonical config to serve. The *_tuned.sh experiment artifacts are kept intact as record.\n",
]
# insert after shebang
if lines and lines[0].startswith("#!"):
    lines = lines[:1] + banner + lines[1:]
else:
    lines = banner + lines
open(out, "w").writelines(lines)
PY
chmod +x "$OUT"
echo "$OUT"
