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

### 20260613 — baseline bring-up + first hang

- Harness validated end-to-end (30s/stage): Marlin path confirmed (`MarlinNvFp4LinearKernel`,
  compressed-tensors auto, FLASH_ATTN, KV auto→bf16, util 0.5 → 51.2 GiB / 372k tok). Validation
  tok/s c1≈42 / c4≈145 / c8≈250 / c16≈358 / c32≈426 — c1 matches NVIDIA's ≈38.7 calibration.
- **CRASH (status=crash):** the full N=3 / 180s-per-stage run **deadlocked at the c32 stage** of
  pass 1. Engine went from 444 tok/s @ 32 reqs to **0.0 tok/s with 32 reqs stuck (Waiting:0)**,
  GPU wedged at 96% util / 15 W for ~29 min, no further logs. GuideLLM writes JSON only at the
  end, so c1–c16 (which ran fine) were lost with the pass. **Recovery:** `adapter down` removed
  the container and the GPU returned to idle immediately — no reboot needed.
- Implication: sustained 32-concurrency NVFP4/Marlin decode is unstable on this image; c32 (a
  required level) needs a config that survives it (lower max-num-seqs, alt backend) — and the
  harness needs a watchdog so a hang is a logged `crash`, not a 40-min stall. See next steps.

<!-- YYYYMMDD: what changed, tok/s effect, keep/discard, anomalies. Run drop_caches before each. -->
