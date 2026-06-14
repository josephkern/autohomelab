#!/usr/bin/env bash
# eval.sh <runbook.sh> [suite] — Gate 2 (quality): lm-evaluation-harness against the live endpoint.
#   suite ∈ general (gsm8k,mmlu) | coder (humaneval,mbpp) | auto (infer from model name)
# Env: LIMIT (per-task sample cap; set for fast in-loop checks, unset for the full final run),
#      GEN_TOKS (default 1024 — CoT on reasoning models overruns lm-eval's stock 256), CONC.
# Server must be up (serve.sh). Records a row to accuracy.tsv + the raw lm-eval json in the bundle.
#
# NOTE: coder tasks EXECUTE generated code (HF_ALLOW_CODE_EVAL + --confirm_run_unsafe_code) — run
# only against models/endpoints you trust.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
[ -f "$REPO_ROOT/.env" ] && set -a && source "$REPO_ROOT/.env" && set +a
RUNBOOK="${1:?usage: eval.sh <runbook.sh> [general|coder|auto]}"
SUITE="${2:-auto}"
TARGET="${TARGET:-http://${AHL_HOST:-127.0.0.1}:${AHL_PORT:-8000}}"
GEN_TOKS="${GEN_TOKS:-1024}"; CONC="${CONC:-16}"

MODEL=""; SERVED_NAME=""
# shellcheck disable=SC1090
source "$RUNBOOK"; : "${MODEL:?runbook must set MODEL}"; : "${SERVED_NAME:=$MODEL}"
ORG="${MODEL%%/*}"; [ "$ORG" = "$MODEL" ] && ORG="_"; NAME="${MODEL##*/}"
NODE_FP="$(find "$REPO_ROOT/results" -maxdepth 2 -name node_profile.json -printf '%h\n' 2>/dev/null | head -1 | xargs -r basename)"

# Suite -> tasks (auto-infer from model name).
if [ "$SUITE" = auto ]; then
  case "$NAME" in *[Cc]oder*|*[Cc]ode*) SUITE=coder ;; *) SUITE=general ;; esac
fi
case "$SUITE" in
  general)   TASKS="${TASKS:-gsm8k,mmlu}"; CODE_ARGS=() ;;
  coder)     TASKS="${TASKS:-humaneval,mbpp}"; export HF_ALLOW_CODE_EVAL=1; CODE_ARGS=(--confirm_run_unsafe_code) ;;
  resistant) TASKS="${TASKS:-gpqa_diamond_zeroshot,mmlu_pro}"; CODE_ARGS=() ;;  # harder/cleaner, less-memorized (tier 2)
  *) echo "unknown suite $SUITE (general|coder|resistant)" >&2; exit 2 ;;
esac

RUN_ID="$(date -u +%Y%m%d-%H%M%S)-eval"
OUT_DIR="$REPO_ROOT/results/$NODE_FP/$ORG/$NAME"; BUNDLE="$OUT_DIR/data/$RUN_ID"; mkdir -p "$BUNDLE"
COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
CONFIG_HASH="$(sha256sum "$RUNBOOK" | cut -c1-8)"
SCRIPT_REL="$(realpath --relative-to="$REPO_ROOT" "$RUNBOOK")"

echo "== lm-eval $SUITE [$TASKS] limit=${LIMIT:-full} -> $SERVED_NAME ==" >&2
# local-completions hits /v1/completions (bypasses chat template/parsers — raw few-shot); the client
# tokenizer (= the HF repo) is required for loglikelihood tasks like mmlu.
uv run --project "$REPO_ROOT" lm_eval --model local-completions \
  --model_args "base_url=${TARGET}/v1/completions,model=${SERVED_NAME},tokenizer=${MODEL},num_concurrent=${CONC},max_retries=3,tokenized_requests=False" \
  --tasks "$TASKS" --gen_kwargs "max_gen_toks=${GEN_TOKS}" ${LIMIT:+--limit "$LIMIT"} \
  --output_path "$BUNDLE" "${CODE_ARGS[@]}"

# lm_eval writes results_*.json under the output dir; extract the headline metric per task.
RESJSON="$(find "$BUNDLE" -name 'results_*.json' | head -1)"
SCORES="$(python3 - "$RESJSON" "$TASKS" <<'PY'
import sys, json
f, tasks = sys.argv[1], set(sys.argv[2].split(","))
try: d = json.load(open(f))
except Exception: print("na"); sys.exit()
out = []
# Record only the requested top-level tasks/groups (gsm8k, mmlu, ...) — not the 57 mmlu_* subtasks
# (full per-subtask detail stays in the raw lm-eval json in the bundle).
for task, m in (d.get("results") or {}).items():
    if task not in tasks: continue
    for k in ("exact_match,strict-match","exact_match,flexible-extract","acc,none","pass@1,none","acc","pass@1"):
        if k in m: out.append(f"{task}={round(m[k]*100,2)}"); break
    else:
        nums = {k:v for k,v in m.items() if isinstance(v,(int,float)) and "stderr" not in k}
        if nums: out.append(f"{task}={round(next(iter(nums.values()))*100,2)}")
print(";".join(sorted(out)) or "na")
PY
)"
DATA_REL="$(realpath --relative-to="$REPO_ROOT" "$BUNDLE")"
TSV="$OUT_DIR/accuracy.tsv"
HDR=$'run_id\tcommit\tnode_fp\tmodel\tconfig_hash\tscript\tsuite\ttasks\tlimit\tscores\tdata'
[ -f "$TSV" ] || echo "$HDR" > "$TSV"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$RUN_ID" "$COMMIT" "$NODE_FP" "$MODEL" "$CONFIG_HASH" "$SCRIPT_REL" "$SUITE" "$TASKS" "${LIMIT:-full}" "$SCORES" "$DATA_REL" >> "$TSV"
echo >&2; echo "scores: $SCORES" >&2; echo "row -> $(realpath --relative-to="$REPO_ROOT" "$TSV")" >&2
