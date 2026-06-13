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

### 20260613 — baseline established (per-level isolation)

After adding per-level isolation (each concurrency level = its own GuideLLM call), the full 180s
baseline ran clean for both shapes — **and c32 no longer hangs.** Confirms the earlier deadlock was
a single-call `sweep` stage-transition artifact (c16→c32), not c32 load itself.

Baseline @ max_s=180, load 140s, Marlin W4A16 (`config_hash 139701ef`):

| shape | c1 | c4 | c8 | c16 | c32 |
|---|---|---|---|---|---|
| chat (512/256)  | 41.1 | 154.6 | 281 | 466.8 | **687.7** |
| coder (4096/1024) | 36.1 | 101.1 | 142.9 | 164.1 | 161.7 |

Findings:
- **chat keeps scaling** through c32 (+47% over c16) — bandwidth not yet saturated for light reqs.
- **coder saturates at c16** (c32 flat/slightly down) — heavy 4096/1024 reqs hit the 273 GB/s wall
  by c16. So c32's value is *workload-dependent*.
- Per-stream (c1) ≈ 36–41 tok/s, matching NVIDIA's Llama-3.1-8B-NVFP4 ≈38.7 calibration.

This is the **keep** baseline for the tuning loop. Tuning objective = **c16**; c1 = cheap sentinel.

### 20260613 — exp #1: native FP4 (KEEP, new best)

Delta vs baseline: removed `--linear-backend marlin` → vLLM auto-selects native NVFP4 W4A4
(FlashInferCutlass/Cutlass 12.0f). N=3, chat, c1/c16.

| config | c1 | c16 (median, n=3) | stable? |
|---|---|---|---|
| baseline (Marlin W4A16) `139701ef` | 41.1 | 466.8 (n=1) | yes |
| **native FP4 W4A4 `cddbebf8`** | 39.5 | **496.8** | **yes (3× clean)** |

**Verdict: KEEP** (+6.4% c16, >3% threshold; c1 sentinel fine; no sm_121 crash across 3 runs).
Surprising vs research: native FP4 was *expected* to be fragile on sm_121, but ran clean and beats
Marlin here — likely because per-level isolation avoids the multi-rate state that triggered earlier
hangs. Native FP4 is the **new base** for subsequent experiments.

Harness hardening this session (reproducibility controls): pinned GuideLLM `--random-seed=42`
(paired prompts across configs), added `max_s`+`seed` columns, and a GPU power/temp sidecar
(`gpu_metrics.csv` per bundle; `thermal=<maxT>C/<avgW>W` in notes).

### 20260613 — exp #2: kv-cache fp8_e4m3 (DISCARD, crash)

Delta vs native-FP4 base: `+ --kv-cache-dtype fp8_e4m3`. c1 ran (39.0) then **c16 deadlocked**
(watchdog hang@c16; thermal 71C/26W → not thermal, a genuine engine wedge). Same hang family as
the old c32 sweep. fp8 KV forces a non-FlashAttention backend on sm_121, and that combo + native
FP4 GEMM wedges under concurrency on v0.22.0. **Verdict: DISCARD.** Best stays native-FP4 (c16=496.8).
Harness fix from this: bench.sh now dumps `docker logs` → `vllm_crash.log` in the bundle before
teardown (the engine error was previously lost).

**Queue note (objective = c16):** skipping knobs that don't bind at 16 concurrency on this box —
`--max-num-seqs` (vLLM default ≥16 already > 16), `--gpu-memory-utilization` raise (KV only ~5% used
at c16/8192), `--enable-prefix-caching` (synthetic prompts have no shared prefix). These matter for
a c32 objective, not c16. Revised queue: async-scheduling → attention-backend FLASHINFER (isolate
the backend from kv-dtype) → image bump (cu130-nightly; may also fix the fp8-KV crash).

### 20260613 — exp #3: async-scheduling (DISCARD, no effect)

Delta vs native-FP4 base: `+ --async-scheduling`. Median c16=497.2 (runs 473.1/497.2/504.3) vs
base 496.8 (473.4/496.8/501.0) → **+0.09%**, indistinguishable. **Verdict: DISCARD** (simpler-is-
better tiebreak; base keeps native-FP4). c1 38.7 (≈ base, within noise).

**Noise floor:** both configs' c16 runs span ~473–504 ≈ **±3%** at N=3. So the keep threshold (>3%)
sits right at the noise floor — small gains need more N or a bigger effect to confirm. native-FP4's
+6.4% over baseline cleared it (real); async-scheduling's 0.09% did not.

<!-- YYYYMMDD: what changed, tok/s effect, keep/discard, anomalies. Run drop_caches before each. -->
