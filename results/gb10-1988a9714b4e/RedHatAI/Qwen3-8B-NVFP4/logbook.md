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

### 20260613 — exp #4: attention-backend FLASHINFER (borderline, DISCARD)

Delta vs native-FP4 base: `+ --attention-backend FLASHINFER` (was auto→FLASH_ATTN, bf16 KV).
Median c16=506.6 (479.4/506.6/507.5) vs base 496.8 → **+2.0%**, below the 3% threshold and within
the ±3% noise band (runs overlap). **Verdict: DISCARD** (don't lock in noise), but flagged to
**revisit** with the image bump — it's the top median and 2/3 runs beat the base's best.
**Diagnostic (conclusive):** FLASHINFER + bf16 KV ran clean → exp#2's crash was the **fp8 KV
dtype**, not the attention backend.

### 20260613 — campaign close: native-FP4 characterized + promoted to FINAL

Full-sweep characterization of the native-FP4 best (chat, 180s, seed 42):

| level | c1 | c4 | c8 | c16 | c32 |
|---|---|---|---|---|---|
| native-FP4 | 38.8 | 149.3 | 277.1 | 486.7 | **745.7** |
| Marlin baseline | 41.1 | — | — | 466.8 | 687.7 |

native-FP4 wins across the curve and **more at high concurrency**: c16 +5.4% (median 491.8, n=4),
**c32 +8.4% (745.7 vs 687.7)** — and stable (no c32 hang under per-level isolation). Promoted to
`VLLM-22-RedHatAI_Qwen3-8B_NVFP4_final.sh` (canonical serve config). `_tuned.sh` artifacts kept.

**Campaign verdict (Qwen3-8B-NVFP4 / GB10 / vLLM v0.22.0):** the GEMM backend (native NVFP4 W4A4 vs
Marlin W4A16) was the single real lever; everything else was noise (async-sched, FLASHINFER) or
crash (fp8 KV). Single-flag c16 space exhausted on v0.22.0; next signal would need a newer pinned
release or the research-loop candidate queue.

### 20260613 — vLLM 0.23.0 transition: re-baselined + first FULLY-VALIDATED final

Transitioned to vLLM **0.23.0** (pinned digest 6d8429e, default). Re-baselined the 8B (native NVFP4
W4A4 auto + functional flags: `--reasoning-parser qwen3`, sampling temp0.6/top_p0.95/top_k20).
**All three gates pass** → promoted `VLLM-23-RedHatAI_Qwen3-8B_NVFP4_final.sh`.

| metric | 0.22.0 native-FP4 | 0.23.0 baseline |
|---|---|---|
| smoke (functional) | n/a | **PASS 3/3** |
| gsm8k / mmlu (LIMIT=100) | 87.0 / 73.49 | **91.0 / 73.61** (within noise) |
| chat c16 / c32 tok/s | 486.7 / 745.7 | **497.0 / 770.8** (+2.1% / +3.4%) |

0.23.0 is modestly faster (c32 real +3.4%, c16 noise) and quality-preserved. Accuracy uses
`/v1/completions` (unaffected by chat parser).

**smoke.sh bug found & fixed:** initial smoke FAILED 0/3 on 0.23.0 — not a serve problem. With
`--reasoning-parser qwen3`, a reasoning model truncated at small `max_tokens` returns empty content.
Fixed smoke to be reasoning-aware: generous `max_tokens` (1024), accept content OR reasoning_content,
and the reasoning check now asserts **no `<think>` leak into content** (the real regression to catch).
Re-smoke → 3/3. Also fixed promote.sh (pipefail on version-grep miss; pass `VLLM_TAG`).

Next (held queue, now on 0.23.0): does `auto` pick b12x? re-test `--kv-cache-dtype fp8_e4m3`
(0.23.0 FP8/KV fixes — crashed on 0.22.0); `--max-num-batched-tokens 16384`.

### 20260614 — fp8-KV finalized & promoted (the campaign winner)

Overnight 0.23.0 queue → **fp8 KV (`--kv-cache-dtype fp8_e4m3`) is the winner**, the very knob that
*crashed* at c16 on 0.22.0 (0.23.0's KV/FP8-sm121 fixes un-broke it). Finalized & promoted to
`VLLM-23-RedHatAI_Qwen3-8B_NVFP4_final.sh`. All three gates:

| gate | result |
|---|---|
| functional (smoke) | PASS 3/3 |
| quality (matched LIMIT=100) | mmlu 73.25 (−0.36, **99.5% recovery**) / gsm8k 92.0 — PASS |
| throughput | c1=41.9 c4=164.3 c8=309.3 **c16=563.2 (+11%)** **c32=950.6 (+23%)** vs 0.23.0-native |

Full-eval absolute (for record): gsm8k=87.64 / mmlu=70.99 (no matched full reference yet → not a
recovery number).

**Methodology catch:** my first recovery check compared fp8-KV *full* mmlu (70.99) to a *LIMIT=100*
reference (73.49) and spuriously "FAILED" — full vs sampled are different question sets. Fixed:
recovery requires **matched eval settings** (now enforced in `recovery.py` docstring + validation.md).
The valid matched-L100 comparison passes cleanly.

**Cumulative (Qwen3-8B-NVFP4, GB10):** Marlin 0.22.0 c16 467 → native-FP4 0.22.0 487 → 0.23.0 507 →
**0.23.0 + fp8 KV 563 (c32 950.6)** = +21% c16 / well over the start at c32, quality intact.

Follow-up: a matched *full* native baseline eval would make the full-recovery rigorous (optional).

<!-- YYYYMMDD: what changed, tok/s effect, keep/discard, anomalies. Run drop_caches before each. -->

## 20260820 — live-path validation of the measurement-validity layer (issue #1 §1)

Not a tuning campaign. The validity layer (contract v1.2) was built and verified entirely against
fixtures and retained bundles — **no agent was allowed near the GPU** — so this run exists to prove
the live path works on real hardware. Config: the promoted `VLLM-23` final, unchanged.

| run | knobs | result |
|---|---|---|
| `20260820-032057-chat` | `levels=1\|16, max_s=180` | c1 **41.26** / c16 **535.62**, `req_counts=c1:29/0/0;c16:368/15/0`, `validity=ok`, exit 0 |
| `20260820-0321xx-chat` | `levels=1, max_s=20` (deliberate starvation) | c1 **63.34**, `c1:3/0/0`, `no_data@c1`, **status=void**, **exit 4** |
| `20260820-032908-eval` | gsm8k, LIMIT=20 | gsm8k **90.0**, `samples=gsm8k=20/20`, `conc=16`, `validity=ok`, exit 0 |

**The starvation run is the finding.** Same config, minutes apart: a 20-second stage drained 3
requests and reported **63.34 tok/s — 54% above the 41.26 the healthy run measured**. Before this
layer that row was written `status=measured` and was indistinguishable from a real result. It is
now `void`, exit 4, with the counts printed at the moment it happened. That is §0 defect (a)
reproduced live and caught.

Corroboration that the numbers are real, not harness artefacts:
- c1 = 41.26 against the 20260613 first-green-run reference of ≈42 (0.22.0) and 41.87 (the 0.23.0
  full sweep) — three vLLM versions and two months apart, `min_ok=29` at c1 every time.
- c16 = 535.62 vs the promoted header's recorded 563 — within this box's documented ~10%
  cross-session c16 drift; c1 is the stable column and it matched to 1.5%.
- `incomplete` at c16 was **15 = level − 1**, exactly the steady-state in-flight set that made
  contract v1.2 A2's first form (`incomplete > level`) unsatisfiable. Measured again live.

Consumers verified on these rows: `aggregate.py` hides the void row by default and shows it marked
`x` with `min_ok=3` under `--include-void`. Gate 2 recorded `samples` and `conc`, neither of which
existed before 20260820.

Teardown clean: GPU back to 0% / 4 W, no `ahl-vllm` container left.

## 20260820 — c1-vs-c32 quality, and a Gate-2 hole found on the way

Closing the repo-wide "quality has only ever been measured at c16" blind spot. Deployed config,
one serve, `gsm8k LIMIT=100 THINK=off`, `CONC=1` then `CONC=32`.

| arm | gsm8k | samples | validity | null-content items |
|---|---|---|---|---|
| `CONC=1` | 56.0 | 100/100 | ok | **17** |
| `CONC=32` | 58.0 | 100/100 | ok | **19** |

### Finding 1 — concurrency changes the TOKENS, not measurably the SCORE

A determinism probe (32 gsm8k prompts, greedy, `/v1/completions`) with prefix caching disabled:

```
CONTROL   c1 vs c1 : 32/32 byte-identical
TREATMENT c1 vs c32:  1/32 byte-identical   (31 differ)
```

So output IS batch-dependent — the mechanism the follow-up hypothesised is real and now
demonstrated. But the scored arms differ by 2.0 pts at n=100 (SE≈4.9 each), i.e. **no detectable
quality difference at this power**. The honest statement: *concurrency changes what the model
emits; we have no evidence it changes how often the model is right, and this design could not have
detected a difference smaller than ~14 pts.* A paired item-level test would be needed to say more
(see `research/review/POWER-analysis.md`).

### Finding 2 — the deployed serve is NOT run-to-run reproducible, and prefix caching is why

Same probe with the deployed config (`enable_prefix_caching=True`, `kv_cache_dtype=fp8_e4m3`):
**7/32 byte-identical on a repeated identical pass**. Disable prefix caching -> 32/32. A single
prompt repeated 5x is deterministic either way, so this is not general nondeterminism: it is
cache STATE. Where a prefix-cache hit lands varies with eviction pressure, and an fp8 KV hit
reuses quantised KV instead of recomputing it. **This is a candidate mechanism for the tracked
"mmlu drifts ~1 pt across sessions on identical config+image" follow-up**, which has been open
without one. Anything that needs bit-reproducibility must serve with `--no-enable-prefix-caching`.

### Finding 3 — THINK=off COLLAPSES this model, and Gate 2 reports `validity=ok`

Same model, same day: **think-on gsm8k = 90-92** (and 87.64 at full limit, 20260613/14);
**think-off gsm8k = 56-58**. A 34-point collapse. 17-19% of items came back with **null content**
(lm-eval substitutes `LMEVAL_MODEL_NONE_ANSWER_PLACEHOLDER` and counts them as answered), so
`samples=100/100`, the score is finite and non-zero, and the Gate-2 predicate passes it.

This is the NemotronH failure documented in AGENTS.md (`enable_thinking=false` renders a pre-closed
`<think></think>`; that model needed a per-model `AHL_THINK_OFF_KWARGS`) — appearing here PARTIALLY
rather than totally, which is worse, because a total failure scores 0 and gets noticed.

**Consequence: `suite.sh` auto-applies think-off to any runbook carrying `--reasoning-parser`.**
For this model that silently substitutes 56 for 90 as the Gate-2 result. The lab note "thinking-off
generative eval" is model-dependent, and the direction is not always the same: the 35B went 40->90
with thinking off; Qwen3-8B goes 90->56.

**The predicate gap:** `eval_validity.py` cannot see this today. `n-samples` counts placeholder-filled
items as answered. Detecting it needs the per-item outputs — i.e. `--log_samples`, which
`research/review/POWER-analysis.md` independently recommends adding for the paired McNemar test.
One flag closes both.
