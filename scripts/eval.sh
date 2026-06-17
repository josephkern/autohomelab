#!/usr/bin/env bash
# eval.sh <runbook.sh> [suite] — Gate 2 (quality): lm-evaluation-harness against the live endpoint.
#   suite ∈ general (gsm8k,mmlu) | coder (humaneval,mbpp) | auto (infer from model name)
# Env: LIMIT (per-task sample cap; set for fast in-loop checks, unset for the full final run),
#      GEN_TOKS (default 1024 — CoT on reasoning models overruns lm-eval's stock 256), CONC,
#      GREEDY (default 1 — pin temperature 0 so the serving --override-generation-config doesn't
#      bleed into eval; GREEDY=0 uses the server's sampling), GEN_KWARGS (full manual gen_kwargs),
#      THINK (default on; THINK=off evals GENERATIVE tasks via the chat endpoint with thinking
#      disabled — serve the model AHL_THINK_OFF=1 to match. For reasoning models, thinking-on
#      depresses generative scores: 35B gsm8k 40->90 with thinking off).
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
GEN_TOKS_USER="${GEN_TOKS:-}"   # capture whether the caller set it (suites may pick a bigger default)
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
  resistant) TASKS="${TASKS:-mmlu_pro}"; CODE_ARGS=() ;;  # tier 2 harder/cleaner. mmlu_pro is OPEN;
             # gpqa_diamond_zeroshot is a GATED HF dataset — request access, then opt in with
             # TASKS=mmlu_pro,gpqa_diamond_zeroshot (one gated task otherwise aborts the whole call).
  math)      TASKS="${TASKS:-minerva_math500,aime25}"; CODE_ARGS=()  # competition-math gate (long-CoT reasoning
             # models, e.g. VibeThinker). minerva_math500 = stable 500-Q gate; aime25 = headline, 30 Q -> HIGH
             # variance (indicator, not a threshold). gpqa_diamond_zeroshot opt-in (gated, as in resistant).
             [ -z "$GEN_TOKS_USER" ] && GEN_TOKS=32768 ;;  # long CoT needs room or the answer truncates -> 0
  *) echo "unknown suite $SUITE (general|coder|resistant|math)" >&2; exit 2 ;;
esac

RUN_ID="$(date -u +%Y%m%d-%H%M%S)-eval"
OUT_DIR="$REPO_ROOT/results/$NODE_FP/$ORG/$NAME"; BUNDLE="$OUT_DIR/data/$RUN_ID"; mkdir -p "$BUNDLE"
COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
CONFIG_HASH="$(sha256sum "$RUNBOOK" | cut -c1-8)"
SCRIPT_REL="$(realpath --relative-to="$REPO_ROOT" "$RUNBOOK")"

# GREEDY eval (default on): the runbook's serving --override-generation-config (chat sampling, e.g.
# temperature 1.0 + presence_penalty) is applied server-side to lm-eval's requests too, depressing
# generative tasks (saw gsm8k 42 on the 35B, ~4% on gemma). eval.sh can't re-serve (runs against the
# live server, e.g. inside suite.sh), so we PIN greedy per-request — explicit request params win over
# the server's generation-config defaults — neutralizing temperature/top_p AND the logit penalties.
# Escape hatches: GREEDY=0 (use the server's serving sampling), or GEN_KWARGS="..." (full manual).
GREEDY="${GREEDY:-1}"
GK="max_gen_toks=${GEN_TOKS}"
[ "$GREEDY" = 1 ] && GK="${GK},temperature=0,top_p=1.0,presence_penalty=0,frequency_penalty=0"
[ -n "${GEN_KWARGS:-}" ] && GK="$GEN_KWARGS"

# THINK mode (default on): reasoning models emit <think> CoT that truncates/derails GENERATIVE eval
# (35B gsm8k 40->90 with thinking off). Thinking can only be turned off via the chat template, which
# applies on /v1/chat/completions — NOT the raw /v1/completions path. So THINK=off switches to the
# CHAT endpoint + --apply_chat_template; pair it with a server started AHL_THINK_OFF=1 (sets
# --default-chat-template-kwargs enable_thinking=false). NOTE: the chat endpoint can't do
# loglikelihood, so THINK=off is for GENERATIVE task lists (gsm8k, mmlu_pro, humaneval) — standard
# `mmlu` is loglikelihood and must stay THINK=on (it's unaffected by thinking anyway).
THINK="${THINK:-on}"
if [ "$THINK" = off ]; then
  case ",$TASKS," in *,mmlu,*) echo "WARN: THINK=off uses the chat endpoint (no loglikelihood) — 'mmlu' will fail; use mmlu_pro or THINK=on for mmlu." >&2 ;; esac
  MODEL_TYPE=local-chat-completions; ENDPOINT="${TARGET}/v1/chat/completions"; CHAT_ARGS=(--apply_chat_template)
else
  MODEL_TYPE=local-completions;      ENDPOINT="${TARGET}/v1/completions";      CHAT_ARGS=()
fi

echo "== lm-eval $SUITE [$TASKS] limit=${LIMIT:-full} sampling=$([ "$GREEDY" = 1 ] && echo greedy || echo server) think=$THINK -> $SERVED_NAME ==" >&2
# THINK=on  -> local-completions /v1/completions (raw few-shot; loglikelihood-capable).
# THINK=off -> local-chat-completions /v1/chat/completions + chat template (thinking-off; generative).
# The client tokenizer (= the HF repo) is required for loglikelihood tasks like mmlu.
uv run --project "$REPO_ROOT" lm_eval --model "$MODEL_TYPE" \
  --model_args "base_url=${ENDPOINT},model=${SERVED_NAME},tokenizer=${MODEL},num_concurrent=${CONC},max_retries=3,tokenized_requests=False" \
  --tasks "$TASKS" --gen_kwargs "$GK" ${LIMIT:+--limit "$LIMIT"} "${CHAT_ARGS[@]}" \
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
    for k in ("exact_match,strict-match","exact_match,flexible-extract","exact_match,custom-extract",
              "acc,none","acc_norm,none","pass@1,none","acc","pass@1"):
        if k in m: out.append(f"{task}={round(m[k]*100,2)}"); break
    else:
        # fallback: first real accuracy metric — skip bookkeeping fields (sample_len, alias, etc.)
        SKIP = {"sample_len", "samples"}
        nums = {k:v for k,v in m.items() if isinstance(v,(int,float)) and "stderr" not in k and k not in SKIP}
        if nums: out.append(f"{task}={round(next(iter(nums.values()))*100,2)}")
print(";".join(sorted(out)) or "na")
PY
)"
DATA_REL="$(realpath --relative-to="$REPO_ROOT" "$BUNDLE")"
TSV="$OUT_DIR/accuracy.tsv"
# `think` is appended LAST so positional readers (run-queue awk $5/$10) stay valid. It disambiguates
# rows that otherwise look contradictory (e.g. 35B gsm8k=42 think-on vs =90 think-off).
HDR=$'run_id\tcommit\tnode_fp\tmodel\tconfig_hash\tscript\tsuite\ttasks\tlimit\tscores\tdata\tthink'
[ -f "$TSV" ] || echo "$HDR" > "$TSV"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$RUN_ID" "$COMMIT" "$NODE_FP" "$MODEL" "$CONFIG_HASH" "$SCRIPT_REL" "$SUITE" "$TASKS" "${LIMIT:-full}" "$SCORES" "$DATA_REL" "$THINK" >> "$TSV"
echo >&2; echo "scores: $SCORES" >&2; echo "row -> $(realpath --relative-to="$REPO_ROOT" "$TSV")" >&2
