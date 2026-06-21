#!/usr/bin/env python3
"""Patch the nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4 cached checkpoint so vLLM keeps the MTP head
in bf16 (NOT NVFP4-quantized) — required for qwen3_next MTP spec-decode to load.

Why: the ModelOpt NVFP4 checkpoint lists `"mtp.layers.0*"` in its quant ignore/exclude lists, but
that fnmatch glob misses 4 MTP keys — `mtp.fc.weight` (a ColumnParallelLinear), `mtp.norm.weight`,
`mtp.pre_fc_norm_embedding.weight`, `mtp.pre_fc_norm_hidden.weight`. Those then get NVFP4-quantized
and fail `load_column_parallel_weight` with a 2048-vs-4096 shape AssertionError (vLLM issue #35031,
@alkari's DGX-Spark report). Adding `"mtp.*"` covers all 1553 MTP tensors.

Idempotent. Patches BOTH config.json (quantization_config.ignore) and hf_quant_config.json
(quantization.exclude_modules) in the cached snapshot for the pinned revision. Re-run after any
re-download of the model.

    uv run scripts/patch_qwen3next_mtp_ignore.py
"""
import glob, json, os, sys

REPO = "models--nvidia--Qwen3-Next-80B-A3B-Instruct-NVFP4"
REV = "8fb2682f136cf94d932a498f18cb1e428832a912"  # pinned MODEL_REVISION
PATTERN = "mtp.*"

hub = os.path.expanduser("~/.cache/huggingface/hub")
snap = os.path.join(hub, REPO, "snapshots", REV)
if not os.path.isdir(snap):
    cands = glob.glob(os.path.join(hub, REPO, "snapshots", "*"))
    snap = cands[0] if cands else None
if not snap:
    sys.exit(f"checkpoint not cached: {REPO}")

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
