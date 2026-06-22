#!/usr/bin/env python3
"""Patch a cached qwen3_next NVFP4 (ModelOpt) checkpoint so vLLM keeps the MTP head in bf16 (NOT
NVFP4-quantized) — required for qwen3_next MTP spec-decode to load on GB10/sm_121.

Why: the ModelOpt NVFP4 checkpoints list `"mtp.layers.0*"` in their quant ignore/exclude lists, but
that fnmatch glob misses 4 MTP keys — `mtp.fc.weight` (a ColumnParallelLinear), `mtp.norm.weight`,
`mtp.pre_fc_norm_embedding.weight`, `mtp.pre_fc_norm_hidden.weight`. Those then get NVFP4-quantized
and fail `load_column_parallel_weight` with a 2048-vs-4096 shape AssertionError (vLLM issue #35031,
@alkari's DGX-Spark report). Adding `"mtp.*"` covers all MTP tensors.

UPSTREAM FIX: vLLM PR #46316 (open as of 2026-06-22) makes mtp.fc unquantized IN CODE for
modelopt_fp4 — once it merges and ships in a release, rebuild the image from that release and this
checkpoint-side patch is no longer needed (the gate_up_proj mapping fix #1 is also in that PR; the
DGX-Spark pynvml patch #3 remains image-side). Until then, this is required per checkpoint.

Both the Instruct and Thinking NVFP4 builds share the same `mtp.layers.0*`-misses-`mtp.fc` defect,
so this must be run once per cached checkpoint. Idempotent. Patches BOTH config.json
(quantization_config.ignore) and hf_quant_config.json (quantization.exclude_modules) in the cached
snapshot. Re-run after any re-download of the model.

    uv run scripts/patch_qwen3next_mtp_ignore.py [<HF_MODEL_ID> [<REVISION>]]
    # defaults to nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4 @ its pinned rev for back-compat;
    # e.g. uv run scripts/patch_qwen3next_mtp_ignore.py nvidia/Qwen3-Next-80B-A3B-Thinking-NVFP4
"""
import glob, json, os, sys

# argv[1] = HF model id (org/name); argv[2] = revision (optional → newest cached snapshot).
MODEL = sys.argv[1] if len(sys.argv) > 1 else "nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4"
REV = sys.argv[2] if len(sys.argv) > 2 else None
REPO = "models--" + MODEL.replace("/", "--")
PATTERN = "mtp.*"

hub = os.path.expanduser("~/.cache/huggingface/hub")
snap = os.path.join(hub, REPO, "snapshots", REV) if REV else None
if not snap or not os.path.isdir(snap):
    cands = sorted(glob.glob(os.path.join(hub, REPO, "snapshots", "*")), key=os.path.getmtime)
    snap = cands[-1] if cands else None
if not snap:
    sys.exit(f"checkpoint not cached: {REPO}" + (f" @ {REV}" if REV else ""))
print(f"patching {MODEL} → {snap}")

targets = [("config.json", ("quantization_config", "ignore")),
           ("hf_quant_config.json", ("quantization", "exclude_modules"))]
changed = 0
for fn, (sect, key) in targets:
    p = os.path.join(snap, fn)
    if not os.path.exists(p):
        print(f"  {fn}: absent, skip"); continue
    j = json.load(open(p))
    lst = j.get(sect, {}).get(key)
    if not isinstance(lst, list):
        print(f"  {fn}: no {sect}.{key} list, skip"); continue
    if PATTERN in lst:
        print(f"  {fn}: already has '{PATTERN}' (idempotent)"); continue
    lst.append(PATTERN)
    json.dump(j, open(p, "w"), indent=2)
    changed += 1
    print(f"  {fn}: added '{PATTERN}' to {sect}.{key} (now {len(lst)} entries)")
print(f"done: {changed} file(s) patched under {snap}")
