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


def fetch_gen_sampling(model: str) -> str | None:
    """Model's recommended sampling as an --override-generation-config JSON, or None."""
    try:
        from huggingface_hub import hf_hub_download
        gc = json.loads(Path(hf_hub_download(model, "generation_config.json")).read_text())
    except Exception:
        return None
    keep = {k: gc[k] for k in ("temperature", "top_p", "top_k") if k in gc and gc.get("do_sample", True)}
    return json.dumps(keep, separators=(",", ":")) if keep else None


def parser_hints(name: str) -> tuple[str, str]:
    """Best-effort (tool_call_parser, reasoning_parser) guesses from the model name — to CONFIRM
    against the model card (smoke.sh validates whatever is actually enabled)."""
    n = name.lower()
    tool = ("qwen3_coder" if "coder" in n else "glm47" if "glm" in n
            else "llama3_json" if "llama" in n else "hermes")
    reason = ("nemotron_v3" if "nemotron" in n else "deepseek_r1" if ("deepseek" in n or "-r1" in n)
              else "qwen3" if "qwen" in n else "deepseek_r1")
    return tool, reason


def write_model_card(out_dir: Path, model: str, org: str, name: str, revision: str, sampling: str | None) -> None:
    card = out_dir / f"{org}_{name}_Model_Card.md"
    if card.exists():
        return
    card.write_text(f"""# {model} — model card (autohomelab)

- HF id: {model}
- Revision (pinned): {revision}
- Type: <general | reasoning | coder>   # drives eval suite: general→gsm8k+mmlu, coder→humaneval+mbpp
- Quantization: <e.g. NVFP4 (compressed-tensors W4A4)>
- Native context: <max_position_embeddings>
- Reasoning parser: <qwen3 | deepseek_r1 | nemotron_v3 | none>
- Tool-call parser: <hermes | qwen3_coder | llama3_json | glm47 | none>
- Recommended sampling: {sampling or '<from generation_config.json>'}
- Quality reference: <recovery % / published eval scores from the HF card's Evaluation section>

## Notes
<intended use, known caveats, anything that affects the serve config>
""")


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
    sampling = fetch_gen_sampling(args.model)
    tool_hint, reason_hint = parser_hints(name)
    override_line = (f"  --override-generation-config '{sampling}'   # model-recommended sampling (generation_config.json)"
                     if sampling else "  # --override-generation-config '{{\"temperature\":...}}'   # no generation_config.json")

    out_dir = REPO_ROOT / "runbooks" / org / name
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / "baseline.sh"

    out.write_text(f"""\
#!/usr/bin/env bash
# AUTO-GENERATED baseline by scripts/gen_baseline.py — derived from the node profile.
# node_fp:   {node_fp}
# gpu:       {gpu['name']} x{tp} ({gpu['memory_kind']} memory)
# Complete reproducible unit: pinned image + model + serving flags (performance + functional).
# Tune by COPYING to <YYYYMMDD>_<change>_tuned.sh (one perf change); keep this baseline unchanged.
# Confirm the FUNCTIONAL flags below against {org}_{name}_Model_Card.md; scripts/smoke.sh validates.

MODEL="{args.model}"
MODEL_REVISION="{revision}"   # pinned for reproducibility
SERVED_NAME="{served}"

# Pinned backend image (from backends/vllm/image.lock registry). Image version is a per-model
# tuning dimension — change it here for a tuned variant if a newer image helps.
VLLM_IMAGE="{image}"
VLLM_ENTRYPOINT_SERVE={entrypoint_serve}   # image ENTRYPOINT already runs `vllm serve`

VLLM_FLAGS=(
  # --- performance (tuned by the loop) ---
  --tensor-parallel-size {tp}
  --gpu-memory-utilization {mem_util}
  --max-model-len {args.max_model_len}
  # --- functional (serving features; CONFIRM against the model card; smoke.sh validates) ---
{override_line}
  # --enable-auto-tool-choice --tool-call-parser {tool_hint}   # uncomment if the model does tools
  # --reasoning-parser {reason_hint}                            # uncomment if the model reasons
)
# Optional env passed into the container, e.g. VLLM_ENV=( "VLLM_ATTENTION_BACKEND=TRITON_ATTN" )
VLLM_ENV=()
""")
    out.chmod(0o755)
    write_model_card(out_dir, args.model, org, name, revision, sampling)
    print(out.relative_to(REPO_ROOT))


if __name__ == "__main__":
    main()
