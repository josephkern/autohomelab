#!/usr/bin/env bash
# Runbook STUB for scripts/smoke.sh against the ds4-server host backend (not a vLLM runbook —
# ds4 has no adapter; serve with launchers/DS4-antirez_DeepSeek-V4-Flash_q2-imatrix.sh first).
# The tool-call-parser token below is a MARKER so smoke.sh exercises its tool-call check
# (ds4 does native DSML tool calling); it is never passed to any server.
MODEL="antirez/DeepSeek-V4-Flash"
SERVED_NAME="deepseek-v4-flash"
VLLM_FLAGS=( "--tool-call-parser=ds4-native-dsml" )
