# Logbook — RedHatAI/Qwen3.6-35B-A3B-NVFP4 on gb10-1988a9714b4e

MoE (A3B) + hybrid attention + MTP speculative head, NVFP4. Migrated from old-homelab's proven
0.22.0 serve script to vLLM 0.23.0. Data rows in `results.tsv` / `accuracy.tsv`; raw in `data/`.

## Environment
- node `gb10-1988a9714b4e` (GB10 sm_121, aarch64, ~121.6 GiB unified, driver 580.159.03, CUDA 13.0)
- backend `vllm/vllm-openai@sha256:6d8429e…` = **vLLM 0.23.0** (torch 2.11+cu130)
- model revision `e850c696e6d75f965367e816c16bc7dacd955ffa`
- weights 23.3 GB (NVFP4); served: MoE backend flashinfer_cutlass, kv fp8_e4m3, MTP (num_spec=1),
  chunked+prefix caching, tool-parser qwen3_coder, reasoning-parser qwen3, sampling temp1/top_p.95/k20/pp1.5

## 20260614 — baseline (migrated to 0.23.0)
Serves clean on 0.23.0 (~336s load). **Gate 1 smoke: PASS 4/4** (chat / JSON / tool-call / reasoning).

| shape | c1 | c4 | c8 | c16 | c32 |
|---|---|---|---|---|---|
| chat (512/256) | 56.4 | 155.6 | 237.1 | 340.6 | 470.7 |

Quality (LIMIT=100): **mmlu=78.19** (loglikelihood — trustworthy; > the 8B's ~73). **gsm8k=42.0**
⚠️ depressed: the baked chat serving sampling (`temperature 1.0` + `presence_penalty 1.5`) is
applied by the server to lm-eval's generative requests too, hurting the structured gsm8k answer
format (old-homelab flagged the same — treat gsm8k as a floor here). **mmlu is the reference.**

Notes vs the 8B: c1 is *higher* (56 vs ~40) — MTP speculative accelerates single-stream decode; but
c16/c32 are *lower* (341/471 vs 563/950) — the larger MoE + speculative overhead scales less under
batching. Migration deltas from the 0.22.0 script are in `baseline.sh` header.

## Next — tune loop (this is where we left off)
Candidate queue for the MoE: **--moe-backend auto vs flashinfer_cutlass vs marlin** (the deferred
MoE knob; could mirror the dense native-FP4 win), **MTP on/off** (num_spec_tokens / disable),
gpu-mem-util, max-num-batched-tokens, kv-dtype. Objective = median c16; quality-gate (mmlu recovery)
on numeric-risky knobs. Then validate + promote `VLLM-23-RedHatAI_Qwen3.6-35B-A3B_NVFP4_final.sh`.

## Open follow-up (eval methodology)
The serving `--override-generation-config` (chat sampling) bleeds into lm-eval → depresses
generative tasks. eval.sh should pin greedy (temperature 0) for eval, or strip the override, so
accuracy isn't config-coupled. Until then, rely on mmlu (loglikelihood) + relative recovery at
matched settings.
