#!/usr/bin/env bash
# Runbook STUB for the llama.cpp host backend serving DavidAU's Qwen3.6-27B Fable-Fusion-711
# NEO-MAX imatrix GGUFs. NOT a vLLM runbook — llama.cpp has no adapter; serve it first with
# launchers/LCPP-DavidAU_Qwen3.6-27B-FF711_NEO-MAX-MTP.sh.
#
# One stub, all three gates (suite.sh can't drive this backend — it calls the vLLM serve.sh):
#   scripts/smoke.sh            <this stub>                       # Gate 1
#   TOKENIZER=$TOKENIZER \
#     scripts/eval.sh           <this stub> general                # Gate 2
#   TAG=<slug> scripts/bench_llamacpp.sh <this stub> chat coder     # Gate 3
#
# The VLLM_FLAGS entries are MARKERS, never passed to any server — they tell smoke.sh which
# feature checks apply. Both are real llama-server capabilities, enabled by the launcher:
#   tool-call-parser  <- --jinja                       (chat-template-driven tool calling)
#   reasoning-parser  <- --reasoning-format deepseek   (<think> routed to reasoning_content)

# Journal identity: the GGUF repo actually being served (lands in the results.tsv model column).
MODEL="DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF"
SERVED_NAME="ff711-27b"          # must match the launcher's -a/--alias

# GGUF repos ship no tokenizer.json, so anything needing a real tokenizer must point at the
# unquantized source repo: GuideLLM synthetic text (bench_llamacpp.sh PROCESSOR) and lm-eval's
# client-side tokenizer for loglikelihood tasks like mmlu (eval.sh TOKENIZER). Same pattern as
# bench_ds4.sh. Export TOKENIZER when invoking eval.sh; bench reads PROCESSOR from here.
PROCESSOR="DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-MTP"
TOKENIZER="$PROCESSOR"

VLLM_FLAGS=( "--tool-call-parser=llamacpp-jinja" "--reasoning-parser=llamacpp-deepseek" )
