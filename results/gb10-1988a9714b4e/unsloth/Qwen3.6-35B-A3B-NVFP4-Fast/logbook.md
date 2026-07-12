# Logbook — unsloth/Qwen3.6-35B-A3B-NVFP4-Fast on gb10-1988a9714b4e

Checkpoint A/B campaign: unsloth's "1.79x faster" NVFP4-Fast quant vs the reigning
RedHatAI/Qwen3.6-35B-A3B-NVFP4 champion (VLLM-24 _final). Champion-parity config (identical flags,
MTP n=2, fp8 KV, flashinfer_cutlass), image v0.25.0.

## Environment
- node `gb10-1988a9714b4e` (GB10 sm_121, aarch64, ~121.6 GiB unified, driver 580.159.03, CUDA 13.0)
- backend `vllm/vllm-openai@sha256:fc56161e…` = **vLLM 0.25.0** · GuideLLM 0.6.0 (PROCESSOR override, see below)
- model revision `1c3f884bc99aac2524f6d49bcbac8c88401afd66`; weights 23.6 GB; MTP head unquantized (`re:^mtp.*` in quant ignore)
- champion same-session references (20260712): chat c16=359.4 c1=55.18 (N=3), mmlu 81.72, gsm8k(think-off) 96–98, mmlu_pro 68.21

## 20260712 — campaign → WINNER, promoted VLLM-25 _final + production cutover

**Gate 1 smoke: PASS 4/4** (suite take 4). The structured-JSON check FAILED on 2 other serves with
the doubled-brace corruption — the KNOWN upstream xgrammar×reasoning×MTP bug (intermittent on ALL
0.25 thinking+MTP configs incl. the champion; vLLM #48228, our matrix + follow-up posted). Not a
Fast defect; not gating.

**Gate 2 quality (LIMIT=100, vs champion): TIED-OR-BETTER.**
| metric | Fast | champion |
|---|---|---|
| mmlu (LL, think-on) | 81.28 / 81.32 (2 runs) | 81.72 / 81.79 |
| gsm8k (gen, think-off) | **96.0** | 96–98 |
| mmlu_pro (gen, think-off) | **68.57** | 68.21 |

**Gate 3 throughput: WINS EVERY LEVEL, BOTH SHAPES.** N=3 medians (chat c1/c16) + full
characterization sweep:
| shape | c1 | c4 | c8 | c16 | c32 |
|---|---|---|---|---|---|
| chat Fast | **76.98** (N=3) | 174.47 | 288.36 | **404.95** (N=3) | 539.07 |
| chat champion | 55.18 | ~156 | ~237 | 359.4 | 492.71 |
| chat delta | **+39.5%** | +12% | +19% | **+12.7%** | +9.4% |
| coder Fast | 80.28 | 174.0 | 280.65 | 367.19 | 476.01 |
| coder champion | 59.84 | — | 230.23 | 316.72 | 417.57 |
| coder delta | **+34%** | — | +22% | **+16%** | +14% |

unsloth's B200 claim was 1.79x at 128-conc; on bandwidth-bound GB10 the lift is 1.09–1.40x
(largest single-stream). Mechanism per unsloth: quant calibrated on their dataset mix — and it also
drafts better? No: drafter acceptance not separately profiled this campaign (follow-up if curious).

**VERDICT: KEEP — dethrones the champion.** Promoted
`VLLM-25-unsloth_Qwen3.6-35B-A3B-NVFP4-Fast_final.sh` (VLLM_TAG=25). Production cutover same day:
launcher `launchers/VLLM-25-unsloth_Qwen3.6-35B-A3B-NVFP4-Fast-256k.sh` (max-model-len 262144, one
delta vs _final), `~/bin/homelab` qwen-256k default repointed, OWUI model rows repointed
(`researcher` base + anti-refusal base row → `qwen3.6-35b-a3b-nvfp4-fast`; old id deactivated).
Old RedHatAI container kept stopped as instant rollback (`docker start vllm-qwen3.6-35b-a3b-nvfp4`).

**Incidents / data caveats (all in results.tsv-adjacent record):**
1. **GuideLLM client hang on this repo's `--processor`** — unsloth ships a multimodal-arch config
   with no preprocessor_config.json → AutoProcessor raises → guidellm wedged in post-stage drain
   (c1=hang crash row 20260712-144815 is CLIENT-side; engine was healthy at ~74 tok/s). Fix:
   bench.sh `PROCESSOR` env override (commit 831553c) → `PROCESSOR=RedHatAI/Qwen3.6-35B-A3B-NVFP4`
   (identical tokenizer) for ALL Fast benches. Report upstream to unsloth (see follow-ups).
2. **accuracy.tsv row `20260712-150520 gsm8k=0.0 think-off` is INVALID** — two suites ran
   concurrently (operator error: suite take-2's think-off phase was still running when take-3
   launched; both share the adapter container/port). Row superseded by `gsm8k=96.0` (clean take-4).
3. One classic GB10 c16 wedge (crash row 20260712-153029; watchdog recovery, same as champion's
   20260712-004308) — retry clean, wedge is box-level not model-level.
4. Two mmlu_pro eval runs killed by operator monitor timeouts sized below the eval's real ~35 min
   runtime (LIMIT=100 generative on ~300 tok/s). Third run clean. Size monitors to the workload.

**KNOWN ISSUE carried into production** (upstream, applies to any 0.25 thinking+MTP config):
`response_format json_object` intermittently corrupted (~3/5 serves); forced tool_choice works on
0.25 xgrammar; `auto` tool calling unaffected. vLLM #48228 / #46118 / #34650; fix PR #44927 + RFC
#48197 pending. Retest grammar smoke on 0.26.
