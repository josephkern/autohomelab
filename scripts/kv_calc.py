#!/usr/bin/env python3
"""KV-cache + memory footprint calculator for serving a model on (unified-memory) NVIDIA nodes.

    uv run scripts/kv_calc.py RedHatAI/Qwen3-8B-NVFP4 \
        [--context 40960] [--concurrency 1,4,8,16,32] [--kv-dtype fp16|fp8] \
        [--pool-gb 121.6] [--overhead-gb 2]

Answers "how much of the unified pool does this config request?" — the thing that decides a safe
--gpu-memory-utilization on GB10, where the KV pool is contended with the OS/CPU.

Weights are read from the repo's actual *.safetensors sizes, so quantization (NVFP4/FP8/BF16) is
accounted for automatically. KV cache = 2(K,V) · layers · kv_heads · head_dim · kv_dtype_bytes
per token, times context × concurrency (the pool vLLM must reserve to hold that many full
sequences at once).
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DTYPE_BYTES = {"fp16": 2, "bf16": 2, "float16": 2, "fp8": 1, "fp8_e4m3": 1, "fp8_e5m2": 1, "int8": 1}
GB = 1024 ** 3


def pool_from_node_profile() -> float | None:
    for p in sorted((REPO_ROOT / "results").glob("*/node_profile.json")):
        prof = json.loads(p.read_text())
        return prof["gpu"]["effective_mem_mb"] / 1024
    return None


def fetch(model: str):
    try:
        from huggingface_hub import HfApi, hf_hub_download
    except ImportError:
        sys.exit("huggingface_hub missing — run inside `uv run`")
    cfg = json.loads(Path(hf_hub_download(model, "config.json")).read_text())
    info = HfApi().model_info(model, files_metadata=True)
    weight_bytes = sum(s.size or 0 for s in info.siblings if s.rfilename.endswith(".safetensors"))
    return cfg, weight_bytes


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("--context", type=int, default=None, help="default = model native context")
    ap.add_argument("--concurrency", default="1,4,8,16,32")
    ap.add_argument("--kv-dtype", default="fp16", choices=sorted(DTYPE_BYTES))
    ap.add_argument("--pool-gb", type=float, default=None, help="default = node profile / 128")
    ap.add_argument("--overhead-gb", type=float, default=2.0, help="activations/cudagraphs/runtime")
    args = ap.parse_args()

    cfg, weight_bytes = fetch(args.model)
    layers = cfg["num_hidden_layers"]
    n_heads = cfg["num_attention_heads"]
    kv_heads = cfg.get("num_key_value_heads", n_heads)
    head_dim = cfg.get("head_dim") or cfg["hidden_size"] // n_heads
    native_ctx = cfg.get("max_position_embeddings", 0)
    context = args.context or native_ctx
    kv_b = DTYPE_BYTES[args.kv_dtype]
    pool = args.pool_gb or pool_from_node_profile() or 128.0

    kv_per_token = 2 * layers * kv_heads * head_dim * kv_b          # bytes / token
    weights_gb = weight_bytes / GB

    print(f"model:    {args.model}")
    print(f"arch:     {layers} layers, {kv_heads} kv-heads (of {n_heads}), head_dim {head_dim}, "
          f"native ctx {native_ctx}")
    print(f"weights:  {weights_gb:.2f} GB (from safetensors; quant-aware)")
    print(f"kv/token: {kv_per_token/1024:.1f} KiB  (kv-dtype {args.kv_dtype})")
    print(f"context:  {context}    pool: {pool:.1f} GB    overhead: {args.overhead_gb:.1f} GB\n")

    print(f"{'conc':>5}  {'kv_gb':>8}  {'total_gb':>9}  {'%pool':>6}  {'util':>5}  fits")
    for c in [int(x) for x in args.concurrency.split(",")]:
        kv_gb = kv_per_token * context * c / GB
        total = weights_gb + kv_gb + args.overhead_gb
        pct = 100 * total / pool
        util = total / pool
        fits = "ok" if total <= pool else "OVER"
        print(f"{c:>5}  {kv_gb:>8.2f}  {total:>9.2f}  {pct:>5.0f}%  {util:>5.2f}  {fits}")

    print("\nNote: 'util' ≈ the --gpu-memory-utilization needed to hold conc×context full sequences."
          "\nOn unified memory keep headroom for the OS; treat util>0.85 as risky.", file=sys.stderr)


if __name__ == "__main__":
    main()
