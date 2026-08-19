# Platform: NVIDIA GB10 / DGX Spark family

> Platform-family reference, shared across any GB10 node. Per-box quirks go in
> `results/<node_fp>/node_notes.md`. Probed facts live in `node_profile.json`.
> Compiled June 2026 from primary (NVIDIA/OEM) + secondary sources; see links inline.

**Core fact:** every OEM "DGX Spark" product is the *same* NVIDIA GB10 reference board. Independent
cross-unit testing found all variants tightly grouped in vLLM with **no sustained-performance
advantage between brands** — differences are storage gen, networking, power adapter, and thermal
headroom, not compute. So when researching, **search across all vendor names**.

## GB10 superchip

| Spec | Value | Confidence |
|---|---|---|
| CPU | 20-core Arm (10× Cortex-X925 + 10× A725, Armv9.2), MediaTek co-design | NVIDIA |
| GPU | Blackwell, 5th-gen Tensor Cores; ~6,144 CUDA cores (48 SMs) | gen confirmed; counts secondary |
| **Compute capability** | **sm_121 (CC 12.1)** — same 12.x family as RTX 50-series, NOT default cross-compatible; vLLM sm_120 kernels are forward-compatible | strong |
| FP4 AI perf | **up to 1 PFLOP / ~1000 TOPS (sparse)** | NVIDIA |
| FP8 / BF16 | **not officially published — do not cite a number** | uncertain |
| Memory | **128 GB LPDDR5X unified coherent** (~121.6 GiB visible) | NVIDIA |
| **Memory bandwidth** | **273 GB/s** (256-bit, 8533 MT/s) — measured in-lab at 255 GB/s (93%); see [roofline](#memory-bandwidth-as-a-correctness-bound-roofline) | confirmed |
| NVLink-C2C | ~600 GB/s bidir ("5× PCIe Gen5") | secondary |
| Process / TDP | TSMC 3nm; ~140 W SoC, 240 W system nameplate | secondary |

## OEM variants

All units: 128 GB / 273 GB/s, DGX OS 7, Wi-Fi 7, ConnectX-7 (wired PCIe 5.0 x4 → same clustering
ceiling). **No memory exceptions anywhere.** Benchmarking-relevant deltas only:

- **Dell Pro Max w/ GB10** (this node's vendor): **280 W** adapter (vs 240 W elsewhere), runs
  warmest (~80–83 °C sustained) but **no throttling**; storage **Gen4-only** (2 TB SKU is QLC).
- **ASUS Ascent GX10**: cheapest (~$2,999); the *only* unit observed to thermally throttle in one
  multi-box test (96 W→76 W @ ~95 °C).
- HP ZGX Nano (Gen5 storage standard), GIGABYTE AI TOP ATOM, MSI EdgeXpert, Lenovo ThinkStation
  PGX, Acer Veriton GN100 — same board; storage/networking SKU differences only.

Power/storage/networking differences affect dataset & checkpoint **I/O**, not decode tok/s.

## Benchmarking quirks (READ before trusting numbers)

- **Decode is memory-bandwidth-bound:** `decode tok/s ≈ 273 GB/s ÷ resident model bytes`. Prefill
  is compute-bound and fast; single-stream decode is modest. **Batching recovers throughput**
  (decode becomes compute-bound at scale) — this is why the 1→32 concurrency curve matters and may
  plateau once bandwidth saturates. Use `scripts/kv_calc.py` to size the resident footprint. This is also a **validity check**, not
  only a performance note — see the roofline section below.
- **`nvidia-smi`:** GPU **memory usage = N/A** (unified, no framebuffer); fan speed & memory clock
  also N/A; PCIe wrongly shows "GEN1 @ 1x" (it's NVLink-C2C). **Power and temperature DO report**
  correctly via NVML — but power is **GPU-domain only**, not wall/system (use a wall meter for total).
- **Filesystem cache can occupy "visible" memory and starve CUDA.** Run `sync && echo 3 | sudo tee
  /proc/sys/vm/drop_caches` before a benchmark for clean, repeatable results.
- **CPU and GPU share the 273 GB/s pool** — quiesce/pin CPU work during a run.
- Known "GPU stuck at ~5–14 W / 0%" power-state bug — verify the GPU is active before trusting low
  numbers.
- `--gpu-memory-utilization` is a share of the **whole** pool; high values starve the OS and can
  destabilize the box (not just the GPU).

## Documented tok/s (for calibration, not targets)

NVIDIA-official (ISL 2048 / OSL 128 / batch=1): **Llama 3.1 8B NVFP4 (TRT-LLM) decode 38.7**,
Qwen3 14B NVFP4 22.7, GPT-OSS-20B MXFP4 (llama.cpp) 82.7, GPT-OSS-120B MoE 55.4. Third-party
(vLLM): Nemotron-3 120B NVFP4 decode ~22.7–23.7; gpt-oss-120B MXFP4 3.6 single → ~863 aggregate
@256 concurrent. NVIDIA forum: dense Qwen3 NVFP4 should beat the ~14 tok/s seen on MoE-Next; Marlin
W4A16 ~46–49 reported on Spark. **NVFP4 on Spark is still maturing.**

## Memory bandwidth as a correctness bound (roofline)

**273 GB/s** is the single most useful number on this platform: it is a *physical* limit, so it can
refute a benchmark result without re-running anything. It is recorded as machine-readable data in
`results/<node_fp>/node_profile.json` → `gpu.mem_bw_gbs` (written by `scripts/probe.sh`'s
`mem_bw_for_gpu()` platform table, with provenance in the sibling `gpu.mem_bw_source`), and consumed
by the roofline check in [docs/validity-contract.md](../validity-contract.md) §4. An unknown GPU gets
`null` and the check is **skipped** — never guessed.

### Is 273 GB/s real on this box? Yes — independently corroborated

| evidence | figure | % of 273 |
|---|---|---|
| NVIDIA spec (128 GB LPDDR5X, 256-bit @ 8533 MT/s) | 273 GB/s | 100% |
| **Measured in-lab**: dense Q5_K_M 27B decode, MTP off, llama.cpp, c1 (FF711 campaign 20260809) — 21.18 GB read per token × 12.03 tok/s | **255 GB/s** | **93%** |
| Same campaign, quant scaling: Q5→Q6 is +13.5% bytes, predicted −11.9% c1, measured **−11.5%** | — | — |

A single-stream decode hitting 93% of the theoretical peak, and quant-to-quant scaling that tracks
byte count to within half a point, is unusually strong evidence that the spec number is achievable
here and that decode really is bandwidth-bound. **Caveat on that 93%:** it assumes every resident
byte is read every token. Later work (unsloth Qwen3.8-27B-NVFP4, 20260818) showed that is false for
multimodal checkpoints — the vision tower is resident but never read during text decode — so the
honest utilisation for *that* model is ~84%, not the 93–97% earlier notes claimed. The bandwidth
number is solid; the *bytes-per-token* input is the part that needs care (see below).

### How to sanity-check a tok/s figure

Contract §4, with batch size `level` (one decode step reads the weights once and emits `level`
tokens):

```
ceiling(level) = SAFETY * level * (mem_bw_gbs / bytes_per_token_GB)      SAFETY = 2.0
```

With no per-model number, the harness falls back to `AHL_MIN_MODEL_GB = 1.0` GB/token, which on this
box gives a deliberately loose ceiling:

| level | c1 | c4 | c8 | c16 | c32 |
|---|---|---|---|---|---|
| ceiling @ 1.0 GB/token (fallback) | **546** | 2,184 | 4,368 | **8,736** | 17,472 |
| ceiling @ 21.18 GB/token (FF711 27B GGUF) | 25.8 | 103 | 206 | 412 | 825 |

Worked examples:

- **c1, fallback:** 546 tok/s. Every real c1 on this box is 10–45 tok/s, so the fallback bound will
  essentially never fire at c1 — that is intended. It exists to catch the impossible, not the fast.
- **c1, per-model:** the FF711 27B at 21.18 GB/token has a *naive* (SAFETY=1) ceiling of
  **12.89 tok/s**; it measured 12.03. That is how tight a real per-model bound is — and exactly why
  the harness does not use SAFETY=1 (see the spec-decode trap below).
- **c16, fallback:** 8,736 tok/s. The best chat c16 ever recorded on this node is a few hundred
  tok/s, so a healthy row clears it by more than an order of magnitude.
- **449,358 tok/s @ c16 was refutable from first principles.** That row (`20260818_mtp-n4_tuned.sh`,
  a crashed server returning instantly to 16 requests) exceeds even the loose fallback ceiling by
  **51×**. Inverted: to sustain 449,358 tok/s at c16 within a 2× safety factor, the engine would have
  to read only **19.4 MB of weights per token** — 0.1% of a 27B NVFP4 checkpoint. Without the batch
  and safety terms it is worse still: 273 GB/s ÷ 449,358 tok/s = **0.6 MB/token**. No arrangement of
  a 27B model produces that; the number is not a measurement, and the harness can now say so without
  looking at the endpoint.

### What the bound is *not*

- **Not a performance target.** Clearing it means "not physically impossible", nothing more.
- **Not tight, on purpose.** SAFETY=2.0 exists because tokens-per-weight-read can legitimately
  exceed 1: with MTP/speculative decoding one verify pass emits several accepted tokens. FF711
  measured accepted lengths of **1.78–2.69** and a net c1 of **+58.7%** over the MTP-off baseline —
  1.48× the naive roofline, which a SAFETY=1 bound would have called impossible. **Watch this:** an
  accepted length above 2.0 with a cheap draft head could in principle push a *real* run past
  SAFETY=2.0 and produce a false `over_roofline` (a fatal verdict → `status=void`). If that is ever
  observed, the fix is to raise SAFETY for spec-decode configs, not to weaken the sample-count checks.
- **Not a substitute for sample counts.** Of the three known bad rows, only one is caught here; the
  starved-stage cases are caught by `no_data`/`low_sample`.

### `bytes_per_token` — what to put in, per model family

The bound is only sound if `bytes_per_token_GB` is a **lower bound on the bytes actually read per
generated token**. Underestimate and the ceiling is merely loose (safe); overestimate and the
ceiling drops below reality and voids good rows. The unsloth 27B case is the cautionary tale: using
the full 23.42 GB checkpoint size implied 318 GB/s = **117% of peak** for a perfectly healthy run,
because the resident vision tower is never read during text decode. *When unsure, use the smaller
number.*

**Dense models** (Qwen3-8B-NVFP4, the 27B GGUFs): every weight is read every decode step, so
`bytes_per_token ≈ resident text-decode weight bytes` — checkpoint size minus anything resident but
unread (vision tower, an unused MTP head, tokenizer/embedding tied weights only read once). Quant
format sets the scale: Q5_K_M 27B ≈ 21.2 GB, Q6 ≈ 24 GB, NVFP4 27B ≈ 20–23 GB.

**MoE models** (Qwen3.6-35B-A3B, Nemotron-3-Super-120B, Qwen3-Next-80B-A3B): only the *active*
experts are read per token, which is what "A3B" names — ~3B active parameters, so a fraction of the
resident bytes. Use **active-expert bytes + shared/attention/embedding bytes**, not the checkpoint
size; that is both the physically correct number at c1 and the safe (smaller) one. Two subtleties
for a later, tighter implementation:
- at **batch > 1** different tokens route to different experts, so a decode step may touch far more
  than one token's worth of experts — the aggregate ceiling therefore does *not* scale cleanly with
  `level` for MoE. Using the c1 active-expert figure keeps the bound sound (looser), never tighter.
- **KV read grows with context and does not amortise across the batch**: each sequence reads its own
  KV every step, so true bytes/token ≈ `weights/level + kv_bytes_per_seq`. Ignoring KV keeps the
  bound loose and sound; at 100K+ context it is the dominant term and a future tighter bound must
  include it (`scripts/kv_calc.py` already sizes KV per model/context/dtype).

**Where to source the number** (guidance for whoever tightens this — not implemented today):
- **vLLM** logs the weight footprint at load; grep the serve log for the model-runner's
  `Model loading took <N> GiB` line, and `KV cache size` / `GPU blocks` for the KV term. Verify the
  exact string per version — vLLM renames these log lines often.
- **llama.cpp** logs the GGUF/tensor footprint at load (`load_tensors: ... model buffer size = <N>
  MiB`, plus the KV-cache buffer line). The GGUF file size on disk is a good first approximation.
- **Offline, without serving:** `scripts/kv_calc.py` already sums `.safetensors` sizes from the HF
  API (`weight_bytes`) and computes KV per context — the natural place to add a per-model
  `bytes_per_token` emitter that `results/<node_fp>/…` or a small model table could cache.
- A **per-model override** belongs next to the model (runbook var or a model table), not in
  `node_profile.json` — the node profile describes the *box*, and one box serves many models.

## Firmware / driver / software (shipping stack, June 2026)

- DGX OS **7.5.0** (Ubuntu 24.04 aarch64, kernel 6.17); driver **580.159.03** (R580; min 580.95.05);
  **CUDA 13.0.2** (min 13.0 for sm_121). Requires the `nvidia-open` (openrm) kernel module.
- vLLM: prebuilt containers historically failed on GB10 (sm_120-only kernels); use a **CUDA-13
  aarch64 build** (our pinned `vllm/vllm-openai:v0.22.0` is torch 2.11.0+cu130 — verified) or NGC
  `nvcr.io/nvidia/vllm`. Situation improving (June 2026 vLLM DGX Spark blog).

## Open uncertainties

FP8/BF16 throughput (no authoritative number); NVLink-C2C 600 GB/s & tensor-core count (secondary);
some OEM SSD gens/pricing conflict across sources.
