# Logbook — RedHatAI/Qwen3.6-35B-A3B-NVFP4 on gb10-1988a9714b4e

MoE (A3B) + hybrid attention + MTP speculative head, NVFP4. Migrated from old-homelab's proven
0.22.0 serve script to vLLM 0.23.0. Data rows in `results.tsv` / `accuracy.tsv`; raw in `data/`.

## Environment
- node `gb10-1988a9714b4e` (GB10 sm_121, aarch64, ~121.6 GiB unified, driver 580.159.03, CUDA 13.0)
- backend `vllm/vllm-openai@sha256:6d8429e…` = **vLLM 0.23.0** (torch 2.11+cu130)
- model revision `e850c696e6d75f965367e816c16bc7dacd955ffa`
- weights 23.3 GB (NVFP4); served: MoE backend flashinfer_cutlass, kv fp8_e4m3, MTP (num_spec=1),
  chunked+prefix caching, tool-parser qwen3_coder, reasoning-parser qwen3, sampling temp1/top_p.95/k20/pp1.5

## 20260614 — baseline (migrated to 0.23.0)
Serves clean on 0.23.0 (~336s load). **Gate 1 smoke: PASS 4/4** (chat / JSON / tool-call / reasoning).

| shape | c1 | c4 | c8 | c16 | c32 |
|---|---|---|---|---|---|
| chat (512/256) | 56.4 | 155.6 | 237.1 | 340.6 | 470.7 |

Quality (LIMIT=100): **mmlu=78.19** (loglikelihood — trustworthy; > the 8B's ~73). **gsm8k=42.0**
⚠️ depressed: the baked chat serving sampling (`temperature 1.0` + `presence_penalty 1.5`) is
applied by the server to lm-eval's generative requests too, hurting the structured gsm8k answer
format (old-homelab flagged the same — treat gsm8k as a floor here). **mmlu is the reference.**

Notes vs the 8B: c1 is *higher* (56 vs ~40) — MTP speculative accelerates single-stream decode; but
c16/c32 are *lower* (341/471 vs 563/950) — the larger MoE + speculative overhead scales less under
batching. Migration deltas from the 0.22.0 script are in `baseline.sh` header.

## 20260614 — tune loop (6-candidate ablation) + finalize → CAMPAIGN COMPLETE
Ran `research/run-queue-35b-0.23.0.sh`: each candidate = the 0.23.0 baseline + ONE change, N=3,
c1 sentinel + c16 objective, smoke-gated, crash-safe (watchdog + per-level isolation). Re-measured
baseline median **c16=344.6** (n3 wedged at c16 once — watchdog caught it, `status=crash`, recovered;
the known GB10 sustained-load quirk). Keep rule: c16 > +3%.

| candidate | c16 | c1 | verdict |
|---|---|---|---|
| baseline (flashinfer_cutlass MoE + fp8 KV + MTP n=1) | 344.6 | 56 | reference |
| moe-auto | 342.4 | 56.4 | discard −0.6% (== cutlass); mmlu=78.44 ✓ |
| moe-marlin | — | — | **serve_fail** (marlin NVFP4-MoE won't init on sm_121) |
| mtp-off | 294.6 | 44.0 | discard **−14.5%** — MTP *helps* even at c16 |
| mtp-n2 | 354.3 | 56.4 | discard +2.8% (sub-threshold, noise floor) |
| memutil-08 | 336.3 | 55.8 | discard −2.4% (KV already fits at 0.5) |
| batched-32k-util08 | 344.0 | 56.4 | discard −0.2% (16384 already past the knee) |

**No candidate cleared >3%** → the migrated baseline config is optimal. Learnings: (1) the baseline's
`flashinfer_cutlass` MoE path is the right kernel on 0.23.0 — `auto` ties it, `marlin` fails to
serve; (2) **MTP speculative decode is a real win even under batching** (removing it −14.5% c16 and
−22% c1) — earlier "spec-decode hurts batched throughput" hypothesis was wrong; (3) the resource
knobs (mem-util, batched-tokens) are saturated already on this bandwidth-bound unified node.

**Promoted** baseline → `VLLM-23-RedHatAI_Qwen3.6-35B-A3B_NVFP4_final.sh` (winner by default).
`scripts/validate.sh` on the promoted file (cfg `2f4bbd67`): **Gate 1 smoke PASS 4/4**; **Gate 2
mmlu=77.6** (LIMIT=100) = −0.75% vs the 78.19 reference, **within ~1%** (matched settings; the
78.19/78.44/77.6 spread across runs is concurrent-serving nondeterminism). **Gate 3 throughput** =
the recorded baseline full sweep (the `_final` is byte-identical in serving flags; c1=56.4 c4=155.6
c8=237.1 c16=340.6 c32=470.7). All three gates pass → campaign done for (gb10, 35B, vLLM 0.23.0).

Gotcha: `promote.sh` derived the version as `22` from the first `vX.Y.Z` in the migration comment
(`v0.22.0 -> v0.23.0`) — overrode with `VLLM_TAG=23`. See CLAUDE.md pending follow-ups.

## Open follow-up (eval methodology)
The serving `--override-generation-config` (chat sampling) bleeds into lm-eval → depresses
generative tasks. eval.sh should pin greedy (temperature 0) for eval, or strip the override, so
accuracy isn't config-coupled. Until then, rely on mmlu (loglikelihood) + relative recovery at
matched settings.
