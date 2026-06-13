# Logbook — RedHatAI/Qwen3-8B-NVFP4 on gb10-1988a9714b4e

Narrative for this (node, model). Data rows live in `results.tsv`; raw bundles in `data/`.

## Environment (fill/confirm each session)

- node fingerprint: `gb10-1988a9714b4e`
- GPU: NVIDIA GB10 ×1, sm_121, **unified** ~121.6 GiB, ~273 GB/s
- driver 580.159.03 · CUDA 13.0 · VBIOS 9A.0B.25.00.00 · kernel 6.17.0-1021-nvidia · Ubuntu 24.04.4
- backend image: `vllm/vllm-openai@sha256:0fec…` = **vLLM 0.22.0, torch 2.11.0+cu130 (CUDA 13.0)** ✓verified
- model revision: `e391349c110709b87bfc2ad2fde3f50dc5839fd8`
- GuideLLM version: _record from first run_

## Model facts (from kv_calc.py)

36 layers, 8 kv-heads (of 32), head_dim 128, native ctx 40960. Weights **5.96 GB** (NVFP4,
quant-aware). KV @ fp16 = 144 KiB/token → at native ctx, c32 KV alone (180 GB) **overshoots** the
pool; baseline caps `--max-model-len 8192`.

## Baseline rationale

NVFP4 dense (compressed-tensors, W4A4); `--quantization` omitted (auto-detect). Baseline uses
**Marlin W4A16** (`--linear-backend marlin`, `VLLM_MARLIN_USE_ATOMIC_ADD=1`) for reliability —
native FP4 auto-select is fast but crashes on GB10 (vllm #35519/#30163). CUDA graphs kept on
(eager triggers an NVFP4 crash). See `runbooks/RedHatAI/Qwen3-8B-NVFP4/baseline.sh`.

## Tuning roadmap (ranked by expected tok/s impact — from source-level research)

1. **GEMM backend**: native FP4 (drop `--linear-backend`) vs `marlin` vs `--linear-backend flashinfer_b12x`
   (needs `FLASHINFER_CUDA_ARCH_LIST=12.0f`, `FLASHINFER_DISABLE_VERSION_CHECK=1`). Native is
   theoretically fastest, most fragile.
2. **`--kv-cache-dtype fp8_e4m3`**: halves KV → more concurrency/context; forces FlashInfer/Triton attn.
3. **`--max-num-seqs` / `--max-num-batched-tokens`**: raise to fill decode batches.
4. **`--attention-backend FLASHINFER`** (vs default FLASH_ATTN); mandatory with fp8 KV.
5. **`--async-scheduling`**: overlap CPU scheduling with GPU.
6. **`--enable-prefix-caching`**: workload-dependent (win for shared prefixes; toggle per shape).
7. **`--max-model-len`**: trade context vs KV pool (see kv_calc.py).

Calibration: NVIDIA-official Llama-3.1-8B NVFP4 decode ~38.7 tok/s @ b=1; expect similar order here.

## Sessions

<!-- YYYYMMDD: what changed, tok/s effect, keep/discard, anomalies. Run drop_caches before each. -->
