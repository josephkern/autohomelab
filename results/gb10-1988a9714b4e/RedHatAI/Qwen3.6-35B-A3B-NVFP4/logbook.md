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
matched settings. **[RESOLVED in the 0.24 campaign below** — suite.sh now runs generative tasks
greedy + thinking-OFF, so gsm8k reads a true 96–98 instead of the config-coupled 42.]

## 20260705 — vLLM 0.23.0 → 0.24.0 transition campaign → CAMPAIGN COMPLETE (VLLM-24 promoted)

### Environment
- node `gb10-1988a9714b4e` (GB10 sm_121, aarch64, ~121.6 GiB unified, driver 580.159.03, CUDA 13.0)
- backend `vllm/vllm-openai@sha256:251eba5c…` = **vLLM 0.24.0** (torch 2.11+cu130), size 21.3 GB
- GuideLLM 0.6.0 · lm-eval (suite defaults) · model revision `e850c696e6d75f965367e816c16bc7dacd955ffa`
- runbook: `VLLM-24-RedHatAI_Qwen3.6-35B-A3B_NVFP4_final.sh` (promoted from `20260704_mtp-n2_tuned.sh`)

### Setup / capabilities-diff (0.23 → 0.24)
Pulled + pinned v0.24.0 by digest (`image.lock`). Full `--help=all` snapshot
(`capabilities/0.24.0.txt`) — **no flags removed**; `--linear-backend` gains `flashinfer_b12x` +
`flashinfer_cutedsl`; `--moe-backend` gains `flydsl`; `kv-cache-dtype` unchanged. (Also fixed a
`capabilities.sh` bug that truncated the snapshot whenever `--help=all` actually populated — it does
on 0.24, was empty on 0.22/0.23.)

### Baseline (0.24, config-identical to the VLLM-23 winner except image) — all 3 gates GREEN
Smoke PASS 4/4. Quality **up** vs 0.23 at the same config: **mmlu 78.19 → 82.82** (think-on,
LIMIT=100), gsm8k **98.0** (think-off; the old 42.0 was the sampling-bleed artifact, now fixed),
mmlu_pro **68.21**. Throughput flat (within noise): chat c1=55.5 c16=337.7 c32=473.0; coder
c16=299.6. So the version bump alone = higher accuracy, same speed, no regression.

### Tune loop (4-candidate ablation, N=3, c1/c16; MMLU_REF=82.82)
| candidate | c16 | verdict |
|---|---|---|
| baseline (flashinfer_cutlass + fp8 KV + MTP n=1) | 339.96 | reference |
| moe-auto (`--moe-backend auto`) | 339.5 | discard −0.1% **+ mmlu 81.75 (−1.3%) QUALITY FAIL** |
| **mtp-n2 (MTP num_spec 1→2)** | **360.98** | **KEEP +6.2% c16** |
| linear-b12x (`--linear-backend flashinfer_b12x`) | — | **serve_fail** (b12x FP4 GEMM won't init on sm_121) |
| kv-nvfp4 (`--kv-cache-dtype nvfp4`) | — | **serve_fail** on sm_121 |

**Winner: mtp-n2.** Key learning: MTP `num_speculative_tokens=2` was only **+2.8% (sub-threshold)
on 0.23**, but **+6.2% on 0.24** — the 0.24 **Model-Runner-V2 Qwen-MoE spec-decode migration** is
what made n=2 scale under batching. `moe-auto` still ties cutlass (and drops mmlu); the two *new*
0.24 backends (`flashinfer_b12x` linear GEMM, `nvfp4` KV) both **serve_fail on sm_121** — same
Blackwell-kernel-init story as marlin-MoE on 0.23. flashinfer_cutlass MoE + fp8 KV remain the path.

### Finalize + promote
Standard suite on `mtp-n2` (LIMIT=100; FULL skipped — spec-decode is greedy-lossless vs n=1, so
accuracy is provably ≈ baseline): smoke PASS; mmlu **82.65** (−0.2% vs ref), gsm8k **96** (noise),
mmlu_pro **68.21** (==); full sweep **confirms the gain both shapes** — chat c16 **357.44 (+5.9%)**
c32 492.71 (+4.2%), coder c16 316.72 (+5.7%). All three gates green → promoted with `VLLM_TAG=24`
(avoids the version-derivation bug; the header carries a `v0.23.0→v0.24.0` migration string).
`image.lock` default flipped to 0.24.0; launcher regenerated (`launchers/VLLM-24-…`). VLLM-23
artifacts kept as the 0.23 record.

## 20260712 — marlin-MoE serve-probe on 0.24 (lead from an unverified external DGX-Spark report)

Trigger: a Twitter post claimed `--moe-backend marlin` serves this model family on GB10 w/ vLLM 0.24
and dramatically raises MTP draft acceptance (47%→81%). Our 0.23 record says marlin serve_fails on
sm_121. Two serve-probes against the VLLM-24 _final config (env identical: image sha256:251eba5c,
same revision/flags), production launcher stopped for the window, restored after.

| probe | delta vs _final | verdict |
|---|---|---|
| moe-marlin-024 | `--moe-backend marlin` | **serve_fail — NEW failure mode.** Target NVFP4 MoE now ACCEPTS MARLIN on 0.24 ("weight-only FP4… Marlin kernel", the 0.23 init-fail is gone); engine dies in the **MTP drafter's unquantized MoE**: `moe_backend='marlin' is not supported for unquantized MoE. Expected ['triton','flashinfer_trtllm','flashinfer_cutlass','aiter']`. |
| moe-marlin-mtp-triton | marlin **+** spec-config `"moe_backend":"triton"` (drafter override) | **SERVES** (ready 327s). Smoke **PASS 4/4**. SpecDecoding (n=2, ~2k drafted toks of ad-hoc chat traffic): **avg draft acceptance 86–95%** per window, mean acceptance length **2.7–2.9 / 3.0**, per-position ~0.93 / 0.86. |

Learnings:
1. The external report's two flags are **one coupled config**: on an MTP model, global marlin
   CANNOT serve without the drafter-side `moe_backend` override in `--speculative-config` — the
   override is a REQUIREMENT, not an optimization. (Drafter-side `moe_backend` is itself a
   previously-unknown tuning dimension for all our MTP configs.)
2. Marlin on sm_121 (0.24) = **weight-only FP4** ("no native FP4 computation" warning) → different
   numerics vs flashinfer_cutlass → any keep decision needs the mmlu reference (moe-auto −1.3%
   precedent), not just tok/s.
3. The post's "47% acceptance without marlin" does NOT obviously apply to us — no acceptance
   reference exists for the _final (cutlass-drafter) config yet. NOT MEASURED HERE: baseline
   acceptance, c1/c16 tok/s (probe only — no bench, no eval, no results.tsv row).

Follow-up (next tune session on this model): N=3 c1/c16 of marlin+triton vs _final, + acceptance
logging on BOTH, + mmlu ref. Also worth a cheap standalone probe: _final config + drafter-only
`"moe_backend":"triton"` (keep cutlass target) — isolates the drafter dimension.
Runbooks: `20260712_moe-marlin-024_tuned.sh` (fail record), `20260712_moe-marlin-mtp-triton_tuned.sh`.

### 20260712 addendum — N=3 comparison: marlin+triton vs _final → DISCARD

Ran the full N=3 (chat c1/c16, 180s/level) on both configs back-to-back, box cleared (production
launcher stopped for the window), acceptance captured via a /metrics sidecar (cumulative counters).

| config | c16 med | c1 med | drafter acceptance (cumulative, whole run) |
|---|---|---|---|
| _final (cutlass MoE, cutlass drafter) | **359.4** | 55.18 | 126461/186030 = **68.0%** |
| moe-marlin-mtp-triton (marlin MoE, triton drafter) | 362.18 | 56.93 | 126497/185604 = **68.2%** |

**DISCARD: c16 +0.8% (sub-threshold, noise floor).** Acceptance is IDENTICAL (68.0 vs 68.2%) —
the drafter MoE kernel does NOT move draft acceptance on this checkpoint; the 86–95% seen in the
earlier ad-hoc probe was a low-concurrency artifact (c≈5, identical prompts; acceptance always
drops under batching — same pattern as Puzzle 90-93% c1 → 77% c16). The external report's
"marlin doubled acceptance (47→81%)" claim is NOT reproduced; their 47% baseline likely reflects
their own broken first config, not the kernel. mmlu gate not needed (discarded on throughput).

Run notes: attempt 1 smoke-flaked (structured-JSON check, temp-1.0 sampling — consider a smoke
retry knob); attempt 2 hit the known GB10 c16 wedge (watchdog caught it, crash row 20260712-004308,
engine log saved; c1=56.18 preserved). Attempt 3 clean. _final reference (359.4) reconfirms the
promoted config on today's conditions (finalize was 357.44).
Net: `--moe-backend marlin` (0.24, sm_121) NOW SERVES with the triton drafter override but buys
nothing on this model. The drafter-side `moe_backend` spec-config knob remains a valid dimension —
it's just not a lever HERE.

## 20260712 — vLLM 0.24.0 → 0.25.0 transition test → NEUTRAL (0.24 stays _final; 0.25 validated)

v0.25.0 released; pulled + pinned `sha256:fc56161e…` (image.lock catalog, NOT default), capabilities
snapshot `0.25.0.txt` diffed vs 0.24: nothing we use removed; +moe-backend `hpc`, +spec-method
`dspark`/`bailing_hybrid_mtp`, +kv int4_per_token_head, +env `VLLM_MOE_SKIP_PADDING`. Release items
for this lab: **#46316 (our Qwen3Next NVFP4+MTP fix) SHIPPED**, #45739 NVFP4 swizzled-scale Blackwell
decode, #42890 NVFP4-KV rework, dspark first-class.

Transition baseline `20260712_v0.25.0_baseline.sh` = VLLM-24 _final, image-only delta. Same-night,
same-protocol matched pair (N=3 chat c1/c16, acceptance sidecar, mmlu LIMIT=100 greedy):

| | 0.24 _final (tonight) | 0.25 baseline | delta |
|---|---|---|---|
| chat c16 median | 359.4 | 358.86 | −0.15% (noise) |
| chat c1 median | 55.18 | 56.01 | +1.5% (noise) |
| drafter acceptance (cumulative) | 68.0% | 68.3% | == |
| smoke | 4/4 | 4/4 | == |
| mmlu (LL, LIMIT=100) | **81.72** | **81.79** | == |

**Verdict: NEUTRAL.** #45739 doesn't move this config on sm_121. No re-promote (no gain); the 35B
stays on the VLLM-24 _final. 0.25 is **serve-validated** on this model — recommended base for NEW
campaigns that need its features (Qwen3-Next MTP without the patched image; dspark), default flip
left as a user call.

**LAB LESSON — mmlu LIMIT=100 drifts ~1 pt ACROSS SESSIONS on identical config+image** (July-5 ref
82.82 vs tonight 81.72, same _final, same digest). In-loop quality gates are only valid as
SAME-SESSION matched pairs (tonight's protocol). The 0.24-campaign moe-auto fail was same-day →
still valid. Also: the structured-JSON smoke check flaked 2/7 serves tonight (temp-1.0 sampling;
`(`-prefix once, doubled `{"` once) — smoke.sh could use a 1-retry on that check.

## 20260712 — grammar-500 isolation → ROOT CAUSE: MTP × reasoning × xgrammar (0.24); 0.25 recovers

Production symptom (user report: "qwen refuses tools"): probes showed `tool_choice:"required"` and
named tool_choice → HTTP 500 on the _final serve (xgrammar `Failed to advance FSM … grammar rejected
tokens [248069, 271, 248058] … Terminating request`); `auto` always fine. Isolation matrix
(probe: required / named / json_object / auto, per serve):

| config | required | named | json_object | FSM errors |
|---|---|---|---|---|
| _final 0.24 (MTP n2 + thinking) | **500** | **500** | 200 loose (```-fenced) | fatal |
| 0.24 mtp-off (thinking on) | 200 ✓ | 200 ✓ | 200 strict-valid | none |
| 0.24 _final + AHL_THINK_OFF=1 (MTP on) | 200 ✓ | 200 ✓ | 200 strict-valid | none |
| 0.25 image-only (MTP + thinking) | 200 ✓ | 200 ✓ | 200 **invalid** | logged, non-fatal |

**Conclusion: three-way interaction.** Grammar-forced decoding + reasoning parser + MTP spec-decode
desync the xgrammar FSM at the `<think>`→content boundary (rejected tokens are the boundary tokens);
either feature alone is fine. vLLM 0.25 makes the failure non-fatal (recovers, still logs FSM error)
but json_object in that combo is still non-strict. Upstream-report candidate (same class as #35031).
Operational note: OWUI native tool calling uses `auto` → daily chat unaffected; anything forcing
tool_choice hard-fails on the 0.24 production serve. **The functional argument for moving the 35B
production serve to 0.25 is now stronger than the (neutral) perf one.** Probe scripts:
scratchpad run_grammar_isolation.sh / probe_grammar.sh; diag mtp-off runbook was scratch-only.
