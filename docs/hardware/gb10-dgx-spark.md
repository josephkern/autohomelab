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
| **Memory bandwidth** | **273 GB/s** (256-bit, 8533 MT/s) | confirmed |
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
  plateau once bandwidth saturates. Use `scripts/kv_calc.py` to size the resident footprint.
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

## Firmware / driver / software (shipping stack, June 2026)

- DGX OS **7.5.0** (Ubuntu 24.04 aarch64, kernel 6.17); driver **580.159.03** (R580; min 580.95.05);
  **CUDA 13.0.2** (min 13.0 for sm_121). Requires the `nvidia-open` (openrm) kernel module.
- vLLM: prebuilt containers historically failed on GB10 (sm_120-only kernels); use a **CUDA-13
  aarch64 build** (our pinned `vllm/vllm-openai:v0.22.0` is torch 2.11.0+cu130 — verified) or NGC
  `nvcr.io/nvidia/vllm`. Situation improving (June 2026 vLLM DGX Spark blog).

## Open uncertainties

FP8/BF16 throughput (no authoritative number); NVLink-C2C 600 GB/s & tensor-core count (secondary);
some OEM SSD gens/pricing conflict across sources.
