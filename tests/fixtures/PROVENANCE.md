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
| `real_dead_endpoint/level_c16.json` | same bundle, `level_c16.json` | **contract §0 defect (b)**: `tps_c16 = 449358.18` with ok=16 / **errored=112069** against a dead endpoint. Also the only real `errored_fatal` (99.99%) in the fixture set. |

**Added 20260819 — the false-positive defence used to be n=1.** One healthy bundle is not a
sample. A validity layer is switched off within a week if it flags good runs, so the healthy
fixtures now span both shapes and all three backends the repo benches with, and every rule that
must NOT fire is asserted against all of them.

| fixture | source bundle | why it is here |
|---|---|---|
| `real_healthy_coder/level_c{1,4,8,16,32}.json` | `unsloth/Qwen3.8-27B-NVFP4/data/20260818-212232-coder` | healthy **coder(4096/1024)** full sweep, vLLM: `c1:12/0/0;c4:37/3/0;c8:60/7/0;c16:79/15/0;c32:96/31/0`. The shape v1.1's request-count floor condemned by construction and A1's request floor now passes. Its c32 discards 24% — the ordinary discard band the retired `AHL_DISCARD_TOL` form would have flagged. |
| `real_healthy_sweep/level_c{1,4,8,16,32}.json` | `nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4/data/20260621-115502-chat` | healthy **chat** full sweep, vLLM: 50.8 → 127.7 → 185.3 → 266.7 → 362.5 tok/s across c1…c32. Five levels of a real monotonic curve — the adjacency rule cannot be told from pairwise-all with fewer than three. |
| `real_healthy_llamacpp/level_c{1,4,8,16}.json` | `DavidAU/…-FF711-…-GGUF/data/20260809-184854-chat` | healthy chat run on the **llama.cpp host-process** backend (`backend=llamacpp@<git-sha>`, no image digest). Structurally low request counts (`c1:12`, `c4:20`, `c8:21`) — a slow dense GGUF is where a request-count floor does its damage. |
| `real_healthy_ds4/level_c1.json` | `antirez/DeepSeek-V4-Flash/data/20260808-125135-chat` | healthy **ds4 host-process** run, `c1:13/0/0`. A one-level bundle: the host launchers bench `levels=1` only, so `promote.sh`'s level fallback and the single-run-level path are real cases, not hypotheticals. |

Non-bundle fixtures:

| fixture | origin |
|---|---|
| `node_profile_no_bw.json` | verbatim `results/gb10-1988a9714b4e/node_profile.json` as it exists **today** — it has no `gpu.mem_bw_gbs`, so it is the live case for "roofline is skipped, not failed" (contract §4). |
| `node_profile_gb10.json` | the same file with `gpu.mem_bw_gbs = 273` added — what the probe must record after this work. |
| `legacy_results.tsv` | header + 3 verbatim rows from real committed `results.tsv` files (`unsloth/Qwen3.8-27B-NVFP4` ×2 incl. the 449358 crash row, `DavidAU/…-GGUF` ×1). 20 columns — the pre-migration schema. Notes fields contain commas, semicolons and quotes on purpose: the migration must preserve them byte-identically. |

Committed size: ~195 KB total (the suite asserts it stays under 256 KB). `results/**/data/` itself is never committed (charter rule 5).
