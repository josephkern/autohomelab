#!/usr/bin/env bash
# new_variant.sh <base_runbook.sh> <change-slug> — start a tuned variant for one experiment.
# Copies the base to <dir>/<YYYYMMDD>_<slug>_tuned.sh and stamps a delta header to fill in.
# Then edit its VLLM_FLAGS / VLLM_IMAGE (ONE change), commit, and run scripts/run_experiment.sh.
set -euo pipefail
BASE="${1:?usage: new_variant.sh <base_runbook.sh> <change-slug>}"
SLUG="${2:?need a change-slug, e.g. native-fp4 or maxnumseqs-512}"
[ -f "$BASE" ] || { echo "base not found: $BASE" >&2; exit 1; }
OUT="$(dirname "$BASE")/$(date -u +%Y%m%d)_${SLUG}_tuned.sh"
[ -e "$OUT" ] && { echo "already exists: $OUT" >&2; exit 1; }

cp "$BASE" "$OUT"
# Replace the AUTO-GENERATED banner with a tuned-variant delta header (one change, documented).
python3 - "$OUT" "$BASE" "$SLUG" <<'PY'
import sys
out, base, slug = sys.argv[1:4]
lines = open(out).read().splitlines(keepends=True)
hdr = [
    f"#!/usr/bin/env bash\n",
    f"# TUNED VARIANT ({slug}) — base: {base}\n",
    f"# Deltas vs base: <DESCRIBE THE ONE CHANGE, e.g. `--linear-backend marlin` REMOVED (native FP4)>\n",
    f"# Hypothesis: <why this should raise c16 tok/s>\n",
]
# drop the original shebang + AUTO-GENERATED line if present
body = lines
if body and body[0].startswith("#!"): body = body[1:]
if body and "AUTO-GENERATED" in body[0]: body = body[1:]
open(out, "w").writelines(hdr + body)
PY
chmod +x "$OUT"
echo "$OUT"
