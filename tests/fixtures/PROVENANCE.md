# Fixture provenance

Every JSON under `tests/fixtures/real_*` is a **minimized copy of a real GuideLLM 0.6.0 bundle**
from this node's gitignored `results/**/data/`, produced by `tests/tools/minimize_bundle.sh`
(drops `.benchmarks[0].requests` and every `percentiles`/`pdf` block; keeps the exact field
*shape* the validity layer reads). Numbers are unmodified. Regenerate rather than hand-edit.

Source root: `/home/jk/projects/dgx-homelab/results/gb10-1988a9714b4e/`

| fixture | source bundle | why it is here |
|---|---|---|
| `real_healthy_chat/level_c1.json` | `Inferact/Qwen3.8-27B-NVFP4/data/20260816-151632-chat/level_c1.json` | healthy lean run, c1: ok=20 / inc=1 / err=0, 18.68 tok/s. Sits exactly on `MIN_SUCCESSFUL=20` — the "20 is not `< 20`" boundary, in real data. |
| `real_healthy_chat/level_c16.json` | same bundle, `level_c16.json` | healthy c16: ok=183 / inc=15 / err=0, 161.55 tok/s. Together the pair is the **false-positive guard**: a good run must come back `ok`. |
| `real_thin_coder/level_c1.json` | `Inferact/Qwen3.8-27B-NVFP4/data/20260817-201312-coder/level_c1.json` | ok=3 — below `MIN_DATA=5`. |
| `real_thin_coder/level_c32.json` | same bundle, `level_c32.json` | **contract §0 defect (a)**: the c32 figure averaged over **2** completed requests (ok=2 / inc=31), reported as 256.19 tok/s. |
| `real_dead_endpoint/level_c1.json` | `unsloth/Qwen3.8-27B-NVFP4/data/20260818-135818-chat/level_c1.json` | the healthy c1 (ok=20, 28.99 tok/s) from the same run — proves the row was not uniformly broken. |
| `real_dead_endpoint/level_c16.json` | same bundle, `level_c16.json` | **contract §0 defect (b)**: `tps_c16 = 449358.18` with ok=16 / **errored=112069** against a dead endpoint. |

Non-bundle fixtures:

| fixture | origin |
|---|---|
| `node_profile_no_bw.json` | verbatim `results/gb10-1988a9714b4e/node_profile.json` as it exists **today** — it has no `gpu.mem_bw_gbs`, so it is the live case for "roofline is skipped, not failed" (contract §4). |
| `node_profile_gb10.json` | the same file with `gpu.mem_bw_gbs = 273` added — what the probe must record after this work. |
| `legacy_results.tsv` | header + 3 verbatim rows from real committed `results.tsv` files (`unsloth/Qwen3.8-27B-NVFP4` ×2 incl. the 449358 crash row, `DavidAU/…-GGUF` ×1). 20 columns — the pre-migration schema. Notes fields contain commas, semicolons and quotes on purpose: the migration must preserve them byte-identically. |

Committed size: ~56 KB total. `results/**/data/` itself is never committed (charter rule 5).
