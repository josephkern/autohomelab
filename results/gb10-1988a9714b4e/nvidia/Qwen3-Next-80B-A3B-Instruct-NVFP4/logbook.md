# Logbook — nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4 (node gb10-1988a9714b4e)

## Environment (AGENTS rule #3)
- node: GB10 (DGX Spark), sm_121, aarch64, ~121.6 GiB unified LPDDR5X; driver 580.159.03, CUDA 13.0
- vLLM: **0.23.0 PATCHED** — `vllm-openai:0.23.0-qwen3nextmtp-fix` (id 628a16cc; base @sha256:6d8429e3).
  Patches unblock qwen3_next MTP on NVFP4/GB10 (vLLM #35031 + @alkari): #1 qwen3_next_mtp gate_up_proj
  mapping; #3 pynvml NVML_ERROR_UNINITIALIZED tolerance (in image); #2 checkpoint quant-ignore "mtp.*"
  (scripts/patch_qwen3next_mtp_ignore.py). Image is byte-identical to stock 0.23.0 for the non-MTP baseline.
- GuideLLM 0.6.0; lm-eval for Gate 2
- model revision: `8fb2682f136cf94d932a498f18cb1e428832a912`
- branch: `autoresearch/qwen3-next-80b`

## Model
`Qwen3NextForCausalLM` / `qwen3_next` — hybrid Gated-DeltaNet linear-attn + sparse MoE, **80B-A3B**
(3B active), ModelOpt **NVFP4** (~48 GB), 262K ctx, 512 exp/10-per-tok. **Native MTP head present**
(1553 mtp.* tensors, bf16). Instruct, non-thinking: **hermes** tool parser, sampling t0.7/p0.8/k20.
Chosen to land the MTP lever that Coder-Next's NVFP4 (MTP-stripped) couldn't test.

## 2026-06-21 — Baseline (cfg 5dab2e11) — GREEN, all gates. Current best (pre-MTP).
gpu-mem-util 0.50 (48 GB weights fit); max-model-len 8192. Patched image (non-MTP path ≡ stock).
- **Gate 1 smoke: PASS 3/3.**
- **Gate 2:** gsm8k=**96.0**, mmlu=**84.88** (loglikelihood), mmlu_pro=**71.93** — all think-on, healthy. limit=100.
- **Gate 3:** chat c1=38.99 c4=112.45 c8=166.8 **c16=237.15** c32=322.22; coder c16=167.83 c32=167.38.

## Tune loop (objective = median c16 chat, N=3, KEEP if >+3%)

### cand — `20260621_mtp-n1_tuned.sh` (num_spec=1) — **KEEP** (c16 +12.4%, c1 +29.9%)
+ `--speculative-config '{"method":"qwen3_next_mtp","num_speculative_tokens":1}'`. Smoke 3/3.
- N=3 (264.13, 267.77, 266.52) median **c16=266.52 (+12.4% vs 237.15)**; c1=50.63 (**+29.9%** vs 38.99).
- The MTP lever lands: native single-token draft, greedy-lossless (target verifies → quality == baseline,
  no eval needed). Biggest lift at c1 (single-stream, bandwidth-bound) as expected; still clears +3% at c16
  despite spec-decode's max_num_scheduled_tokens=2048 cap. Required the 3-patch unblock (see env block).
  **Current best.** (Next: mtp-n2 num_spec=2 — expect lower per the "n>1 reuses 1 MTP layer" warning.)
