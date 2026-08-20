#!/usr/bin/env bash
# eval.sh <runbook.sh> [suite] — Gate 2 (quality): lm-evaluation-harness against the live endpoint.
#   suite ∈ general (gsm8k,mmlu) | coder (humaneval,mbpp) | auto (infer from model name)
# Env: LIMIT (per-task sample cap; set for fast in-loop checks, unset for the full final run),
#      GEN_TOKS (default 1024 — CoT on reasoning models overruns lm-eval's stock 256),
#      CONC (eval concurrency, default 16 — now RECORDED in the row's `conc` column, so a
#      quality result finally says which point on the 1..32 curve it was measured at),
#      AHL_EVAL_MIN_SAMPLE_FRAC (default 0.99 — the completeness floor, see eval_validity.py),
#      GREEDY (default 1 — pin temperature 0 so the serving --override-generation-config doesn't
#      bleed into eval; GREEDY=0 uses the server's sampling), GEN_KWARGS (full manual gen_kwargs),
#      THINK (default on; THINK=off evals GENERATIVE tasks via the chat endpoint with thinking
#      disabled — serve the model AHL_THINK_OFF=1 to match. For reasoning models, thinking-on
#      depresses generative scores: 35B gsm8k 40->90 with thinking off),
#      TOKENIZER (client-side tokenizer HF repo when the runbook MODEL isn't a resolvable repo —
#      e.g. ds4 host-backend stubs: MODEL=antirez/DeepSeek-V4-Flash is the journal identity, the
#      real tokenizer is deepseek-ai/DeepSeek-V4-Flash; mirrors bench_ds4.sh's PROCESSOR).
# Server must be up (serve.sh). Records a row to accuracy.tsv + the raw lm-eval json in the bundle.
#
# `config_hash`: `sha256sum <runbook>` for a vLLM runbook (the runbook IS the config). For a
# HOST-PROCESS stub (`*.smoke-runbook.sh`, ds4 / llama.cpp) the stub carries no launcher settings,
# so the identity comes from the SERVED PROCESS via scripts/lib/hostcfg.sh — the same `hp3-` value
# bench_ds4.sh / bench_llamacpp.sh write, so a quality row and a throughput row can be joined. See
# the block at the CONFIG_HASH assignment below.
#
# NOTE: coder tasks EXECUTE generated code (HF_ALLOW_CODE_EVAL + --confirm_run_unsafe_code) — run
# only against models/endpoints you trust.
#
# ── Gate 2 has an ACCEPTANCE PREDICATE (docs/validity-contract.md A9) ─────────────────────────
# This script used to exit 0 whatever lm-eval returned, and suite.sh judged Gate 2 on that exit
# code alone. So `mmlu: acc = NaN`, a score over 37 of 14,042 requested samples, and a missing
# results json all wrote a row and reported PASS — §0 defect (c), unchanged. The row is now
# scored by scripts/eval_validity.py before it is written, in the throughput layer's vocabulary
# (`validity` tokens, a `status` floor of void/suspect, "not citable"), and the exit code follows
# the repo-wide precedence:
#     3  the harness died on a signal (killed / OOM / a wedge tore it down)
#     4  the row IS written but is NOT citable (non-finite score, short sample, no score)
#     1  lm-eval failed for some other reason though the numbers themselves look structurally ok
#     0  citable
# 4 means "recorded, do not quote it" — never an abort. A non-zero lm-eval exit never suppresses
# the row: the evidence must survive in the committed journal (contract §5).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
[ -f "$REPO_ROOT/.env" ] && set -a && source "$REPO_ROOT/.env" && set +a
RUNBOOK="${1:?usage: eval.sh <runbook.sh> [general|coder|auto]}"
SUITE="${2:-auto}"
TARGET="${TARGET:-http://${AHL_HOST:-127.0.0.1}:${AHL_PORT:-8000}}"
GEN_TOKS_USER="${GEN_TOKS:-}"   # capture whether the caller set it (suites may pick a bigger default)
GEN_TOKS="${GEN_TOKS:-1024}"; CONC="${CONC:-16}"

# Charter rule 4: python via uv when available; eval_validity.py is stdlib-only, so python3 is a
# correct fallback (and the one the self-test uses).
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
# The lm-eval invocation, behind one seam. `AHL_LM_EVAL` lets the self-test drive this script with
# a stub harness that emits synthetic lm-eval bundles — the ONLY way to prove, without a GPU, that
# a NaN bundle actually fails here rather than merely that a function returns the right verdict.
ahl_lm_eval() {
  if [ -n "${AHL_LM_EVAL:-}" ]; then
    # shellcheck disable=SC2086
    $AHL_LM_EVAL "$@"
  else
    uv run --project "$REPO_ROOT" lm_eval "$@"
  fi
}

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
  math)      TASKS="${TASKS:-aime24,aime25}"; CODE_ARGS=()  # competition-math gate (long-CoT reasoning models,
             # e.g. VibeThinker — the paper's headline metric). Uses the `aime` tasks because their
             # process_results PREFERS \boxed{} extraction (last_boxed_only_string), matching DeepSeek-R1-style
             # output. NOTE: minerva_math500 (Minerva "Final Answer:" regex) and hendrycks_math500 ($...$ only)
             # do NOT extract \boxed -> score ~0 for a format mismatch, NOT a real failure. 60 AIME Q total ->
             # still notable variance (temp-1.0 single-sample). gpqa_diamond_zeroshot opt-in (gated).
             [ -z "$GEN_TOKS_USER" ] && GEN_TOKS=32768 ;;  # long CoT needs room or the answer truncates -> 0
  *) echo "unknown suite $SUITE (general|coder|resistant|math)" >&2; exit 2 ;;
esac

RUN_ID="$(date -u +%Y%m%d-%H%M%S)-eval"
OUT_DIR="$REPO_ROOT/results/$NODE_FP/$ORG/$NAME"; BUNDLE="$OUT_DIR/data/$RUN_ID"; mkdir -p "$BUNDLE"
COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
SCRIPT_REL="$(realpath --relative-to="$REPO_ROOT" "$RUNBOOK")"

# ── config_hash — Gate 2 must use the SAME identity as Gate 3 ─────────────────
# For a vLLM runbook the runbook IS the config, so `sha256sum <runbook>` is honest and unchanged.
# For a HOST-PROCESS backend (ds4, llama.cpp) it is not: `serve.sh` never runs and the only file
# this script can hash is the `.smoke-runbook.sh` STUB, which carries MODEL / SERVED_NAME /
# PROCESSOR / parser markers and nothing else — so every ds4 config wrote the same 8 digits. That
# is the tracked defect, and its four cited rows (gsm8k 60.0 / 76.0 / 74.0 / 74.0 under
# `10b02344`) are rows in THIS journal, accuracy.tsv, written by this line. The first repair
# landed only in bench_ds4.sh/bench_llamacpp.sh, so re-running those four evals would still have
# written `10b02344` while the bench path separated them — and a host config's quality row could
# not be joined to its throughput row at all. Both gates now hash the same document, computed by
# scripts/lib/hostcfg.sh from the same SERVED PROCESS (contract: identical `hp3-` value).
#
# Applies only to a `.smoke-runbook.sh` stub (the documented host-process convention, AGENTS.md
# "HOST-PROCESS backends") AND only when a known engine is actually serving $AHL_PORT. A vLLM
# runbook never takes this path; nor does a stub whose engine cannot be found — that case writes
# `stub-<8 hex>`, the legacy stub identity, LABELLED so it can never be read as a served identity
# or grouped with an `hp3-` row. Provenance is not validity: an unidentifiable engine does not
# make the score wrong, so it warns rather than changing the exit code.
CONFIG_HASH="$(sha256sum "$RUNBOOK" | cut -c1-8)"
case "$RUNBOOK" in
  *.smoke-runbook.sh)
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/lib/hostcfg.sh"
    if read -r HC_ENGINE HC_PID HC_ERE < <(ahl_hostcfg_detect "${AHL_PORT:-8000}") && [ -n "${HC_PID:-}" ]; then
      if HC_HASH="$(ahl_hostcfg_hash "$HC_PID" "$HC_ENGINE" "$HC_ERE")"; then
        CONFIG_HASH="$HC_HASH"
        echo "config_hash: $CONFIG_HASH ($HC_ENGINE pid $HC_PID — the served process, not the stub)" >&2
      else
        CONFIG_HASH="stub-$CONFIG_HASH"
        echo "WARN: could not read /proc/$HC_PID — recording the STUB hash $CONFIG_HASH; it does" >&2
        echo "      NOT identify the launcher config (scripts/lib/hostcfg.sh)." >&2
      fi
    else
      CONFIG_HASH="stub-$CONFIG_HASH"
      echo "WARN: no ds4/llama.cpp engine found on port ${AHL_PORT:-8000}; recording the STUB hash" >&2
      echo "      $CONFIG_HASH — it does NOT identify the launcher config, and every config of" >&2
      echo "      this engine shares it (AGENTS.md: the host-process config_hash blind spot)." >&2
    fi
    ;;
esac

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
# EVAL_TIMEOUT: per-request HTTP timeout (lm-eval default 300s). Long-CoT models (e.g. VibeThinker)
# generate for many minutes per item (32K tokens @ ~tens of tok/s, slower under concurrency) and 300s
# times out -> no results. Default 1800s; raise for very long budgets / high CONC.
# lm-eval must NOT abort this script: a failed run still has to leave a row behind (contract §5,
# "a failing run is still written; the evidence must survive in the committed journal"). Capture
# the rc and keep going.
LM_RC=0
set +e
ahl_lm_eval --model "$MODEL_TYPE" \
  --model_args "base_url=${ENDPOINT},model=${SERVED_NAME},tokenizer=${TOKENIZER:-$MODEL},num_concurrent=${CONC},max_retries=3,timeout=${EVAL_TIMEOUT:-1800},tokenized_requests=False" \
  --tasks "$TASKS" --gen_kwargs "$GK" ${LIMIT:+--limit "$LIMIT"} "${CHAT_ARGS[@]}" \
  --output_path "$BUNDLE" "${CODE_ARGS[@]}"
LM_RC=$?
set -e
[ "$LM_RC" -ne 0 ] && echo "WARN: lm_eval exited $LM_RC — scoring whatever bundle it left behind" >&2

# ── Gate 2 acceptance predicate ───────────────────────────────────────────────
# scripts/eval_validity.py reads the bundle lm-eval just wrote and answers "is this a
# measurement?": a finite headline metric per requested task, over the sample count that was
# actually requested (`n-samples.effective` vs `min(limit, original)` summed across the task's
# leaf subtasks), present at all. It is a VALIDITY check, not a tolerance test — it never
# compares the value to a reference, because at LIMIT=100 the binomial SE is ~4.3 points and no
# threshold on the value could mean anything (AGENTS.md).
EV_LINE="$(ahl_py "$SCRIPT_DIR/eval_validity.py" assess --bundle "$BUNDLE" --tasks "$TASKS" \
             ${LIMIT:+--limit "$LIMIT"} --conc "$CONC" || true)"
SCORES=""; SAMPLES=""; VALIDITY=""; EV_STATUS=""; EV_CONC=""; EV_CITABLE=""
IFS=$'\t' read -r SCORES SAMPLES VALIDITY EV_STATUS EV_CONC EV_CITABLE <<<"$(printf '%s' "$EV_LINE" | tail -1)" || true
# Fail CLOSED (contract A6): if the predicate itself could not run, the row is not citable —
# a `uv` hiccup must never mint a clean quality gate.
if [ -z "${VALIDITY:-}" ]; then
  SCORES="${SCORES:-na}"; SAMPLES=na; VALIDITY=na; EV_STATUS=na; EV_CONC="$CONC"; EV_CITABLE=0
  echo "WARN: eval_validity.py produced no verdict — recording validity=na (NOT citable)" >&2
fi

DATA_REL="$(realpath --relative-to="$REPO_ROOT" "$BUNDLE")"
TSV="$OUT_DIR/accuracy.tsv"
# `think` was appended LAST so positional readers (run-queue awk $5/$10) stayed valid; the four
# validity columns (contract A9) are appended after it for the same reason.
#   conc      — the concurrency the eval ran at. Gate 2 sits at a fixed c16 while Gate 3 sweeps
#               1..32 and the two never cross (AGENTS.md follow-up); it was not even recorded.
#   samples   — task=effective/requested. The evidence behind the completeness verdict.
#   validity  — Gate-2 verdict tokens, task-tagged (`nonfinite@mmlu`), `+`-joined, `ok` if clean.
#   status    — contract §6, floored by the verdict: measured / suspect / void.
# accuracy.tsv header comes from scripts/eval_validity.py — one definition, five
# callers. Five hard-coded copies is the exact defect issue #1 opened on.
HDR="$(uv run --project "$REPO_ROOT" python "$SCRIPT_DIR/eval_validity.py" accuracy-header \
        2>/dev/null || python3 "$SCRIPT_DIR/eval_validity.py" accuracy-header)"
if [ ! -f "$TSV" ]; then
  echo "$HDR" > "$TSV"
elif [ "$(head -1 "$TSV")" != "$HDR" ]; then
  # A legacy 12-column journal: migrate it in place (append-only, backfilled from the retained
  # bundles) rather than appending a wider row onto a narrower schema.
  echo "migrating $TSV to the 16-column schema (docs/validity-contract.md A9)" >&2
  ahl_py "$SCRIPT_DIR/migrate_accuracy_tsv.py" --tsv "$TSV" --bundle-root "$REPO_ROOT" --write >&2
fi
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$RUN_ID" "$COMMIT" "$NODE_FP" "$MODEL" "$CONFIG_HASH" "$SCRIPT_REL" "$SUITE" "$TASKS" \
  "${LIMIT:-full}" "$SCORES" "$DATA_REL" "$THINK" "${EV_CONC:-$CONC}" "$SAMPLES" "$VALIDITY" \
  "$EV_STATUS" >> "$TSV"
echo >&2
echo "scores: $SCORES   samples: $SAMPLES   conc: ${EV_CONC:-$CONC}" >&2
echo "validity: $VALIDITY   status: $EV_STATUS" >&2
echo "row -> $(realpath --relative-to="$REPO_ROOT" "$TSV")" >&2

# ── Exit, in the repo-wide precedence 3 > 4 > 1 > 0 (contract §5) ─────────────
# A signal-killed harness is the Gate-2 analogue of a Gate-3 wedge: rc >= 128 means lm-eval was
# terminated (OOM killer, operator, or a teardown), not that it disagreed with the model.
rc=0
[ "$LM_RC" -ne 0 ] && rc=1
[ "${EV_CITABLE:-0}" = 1 ] || rc=4
[ "$LM_RC" -ge 128 ] && rc=3
if [ "$rc" = 4 ]; then
  echo "!! Gate 2 NOT CITABLE: validity=$VALIDITY status=$EV_STATUS — the row is written, the" >&2
  echo "   score must NOT be quoted, compared or promoted on (docs/validity-contract.md A9)." >&2
fi
exit "$rc"
