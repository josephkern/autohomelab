#!/usr/bin/env python3
"""Generate a baseline vLLM serving runbook from a node profile.

Run via the pinned tooling env:
    uv run scripts/gen_baseline.py Qwen/Qwen3-8B [--node-fp <fp>] [--max-model-len N]

Writes runbooks/<org>/<model>/baseline.sh with hardware-derived flags and a pinned model
revision. The baseline is intentionally minimal (TP, gpu-memory-utilization, max-model-len);
the program.md tuning loop explores everything else from here.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def find_node_profile(node_fp: str | None) -> tuple[str, dict]:
    results = REPO_ROOT / "results"
    profiles = sorted(results.glob("*/node_profile.json"))
    if not profiles:
        sys.exit("no node_profile.json found — run scripts/probe.sh first")
    if node_fp:
        match = [p for p in profiles if p.parent.name == node_fp]
        if not match:
            sys.exit(f"node profile '{node_fp}' not found under results/")
        path = match[0]
    elif len(profiles) == 1:
        path = profiles[0]
    else:
        names = ", ".join(p.parent.name for p in profiles)
        sys.exit(f"multiple node profiles ({names}); pass --node-fp")
    return path.parent.name, json.loads(path.read_text())


def default_image() -> tuple[str, str]:
    """Read the default image + entrypoint behavior from the vLLM registry."""
    lock = REPO_ROOT / "backends" / "vllm" / "image.lock"
    image, serve = "vllm/vllm-openai:latest", "true"
    for line in lock.read_text().splitlines():
        s = line.strip()
        if s.startswith("AHL_VLLM_DEFAULT_IMAGE="):
            image = s.split("=", 1)[1].split("#")[0].strip().strip('"')
        elif s.startswith("AHL_VLLM_DEFAULT_ENTRYPOINT_SERVE="):
            serve = s.split("=", 1)[1].split("#")[0].strip().strip('"')
    return image, serve


def resolve_revision(model: str) -> str:
    try:
        from huggingface_hub import HfApi
    except ImportError:
        sys.exit("huggingface_hub missing — run inside `uv run`")
    info = HfApi().model_info(model)
    if not info.sha:
        sys.exit(f"could not resolve a revision for {model}")
    return info.sha


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("model", help="HF model id, e.g. Qwen/Qwen3-8B")
    ap.add_argument("--node-fp", default=None)
    ap.add_argument("--max-model-len", type=int, default=8192,
                    help="baseline context length (tunable upward later)")
    args = ap.parse_args()

    node_fp, profile = find_node_profile(args.node_fp)
    gpu = profile["gpu"]
    tp = gpu["count"]
    # Unified memory (e.g. GB10) is shared with the OS+CPU+runtime: gpu-memory-utilization is a
    # share of the WHOLE pool, so a high value can starve the OS / destabilize the box (not just
    # the GPU). Stay well back on unified; the tuning loop can push it up if stable.
    mem_util = 0.50 if gpu["memory_kind"] == "unified" else 0.90

    revision = resolve_revision(args.model)
    image, entrypoint_serve = default_image()
    org, name = (args.model.split("/", 1) if "/" in args.model else ("_", args.model))
    served = name.lower()

    out_dir = REPO_ROOT / "runbooks" / org / name
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / "baseline.sh"

    out.write_text(f"""\
#!/usr/bin/env bash
# AUTO-GENERATED baseline by scripts/gen_baseline.py — derived from the node profile.
# node_fp:   {node_fp}
# gpu:       {gpu['name']} x{tp} ({gpu['memory_kind']} memory)
# This is the complete reproducible unit: pinned image + model + serving flags.
# Tune by COPYING to <YYYYMMDD>_<change>_tuned.sh and documenting the delta in its header;
# keep this baseline unchanged.

MODEL="{args.model}"
MODEL_REVISION="{revision}"   # pinned for reproducibility
SERVED_NAME="{served}"

# Pinned backend image (from backends/vllm/image.lock registry). Image version is a per-model
# tuning dimension — change it here for a tuned variant if a newer image helps.
VLLM_IMAGE="{image}"
VLLM_ENTRYPOINT_SERVE={entrypoint_serve}   # image ENTRYPOINT already runs `vllm serve`

VLLM_FLAGS=(
  --tensor-parallel-size {tp}
  --gpu-memory-utilization {mem_util}
  --max-model-len {args.max_model_len}
)
# Optional env passed into the container, e.g. VLLM_ENV=( "VLLM_ATTENTION_BACKEND=TRITON_ATTN" )
VLLM_ENV=()
""")
    out.chmod(0o755)
    print(out.relative_to(REPO_ROOT))


if __name__ == "__main__":
    main()
